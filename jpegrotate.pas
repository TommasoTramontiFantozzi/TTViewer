unit jpegrotate;

{ Lossless JPEG rotation: only the EXIF Orientation tag is changed, the image data is
  never touched. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix;

{ Turns the image 90 degrees by updating the EXIF orientation of FileName.
  The file's modification time and permissions are preserved. }
function RotateJpegLossless(const FileName: string; Clockwise: Boolean; out Err: string): Boolean;

{ The Exif APP1 segment (marker included) of a JPEG held in memory. }
function ExtractExifSegment(const B: TBytes; out Seg: TBytes): Boolean;

{ Sets the orientation tag of such a segment to 1 (the pixels were already rotated). }
procedure ResetSegmentOrientation(var Seg: TBytes);

{ Inserts an APP segment right after SOI / JFIF. }
function InsertAppSegment(const Jpg, Seg: TBytes): TBytes;

implementation

const
  OrientCW: array[1..8] of Integer = (6, 7, 8, 5, 2, 3, 4, 1);
  OrientCCW: array[1..8] of Integer = (8, 5, 6, 7, 4, 1, 2, 3);

type
  TByteOrder = record
    Big: Boolean;
  end;

function Get16(const B: TBytes; Ofs: Integer; Big: Boolean): Integer;
begin
  if Big then Result := (B[Ofs] shl 8) or B[Ofs + 1]
  else Result := (B[Ofs + 1] shl 8) or B[Ofs];
end;

function Get32(const B: TBytes; Ofs: Integer; Big: Boolean): Cardinal;
begin
  if Big then
    Result := (Cardinal(B[Ofs]) shl 24) or (Cardinal(B[Ofs + 1]) shl 16) or (Cardinal(B[Ofs + 2]) shl 8) or B[Ofs + 3]
  else
    Result := (Cardinal(B[Ofs + 3]) shl 24) or (Cardinal(B[Ofs + 2]) shl 16) or (Cardinal(B[Ofs + 1]) shl 8) or B[Ofs];
end;

procedure Put16(var B: TBytes; Ofs, V: Integer; Big: Boolean);
begin
  if Big then begin B[Ofs] := V shr 8; B[Ofs + 1] := V and $FF; end
  else begin B[Ofs + 1] := V shr 8; B[Ofs] := V and $FF; end;
end;

procedure Put32(var B: TBytes; Ofs: Integer; V: Cardinal; Big: Boolean);
begin
  if Big then
  begin
    B[Ofs] := V shr 24; B[Ofs + 1] := (V shr 16) and $FF; B[Ofs + 2] := (V shr 8) and $FF; B[Ofs + 3] := V and $FF;
  end
  else
  begin
    B[Ofs + 3] := V shr 24; B[Ofs + 2] := (V shr 16) and $FF; B[Ofs + 1] := (V shr 8) and $FF; B[Ofs] := V and $FF;
  end;
end;

procedure Append(var Dst: TBytes; const Src: array of Byte; Count: Integer);
var
  n: Integer;
begin
  n := Length(Dst);
  SetLength(Dst, n + Count);
  if Count > 0 then
    Move(Src[0], Dst[n], Count);
end;

function ReadAll(const FileName: string; out B: TBytes): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(B, fs.Size);
      if Length(B) > 0 then
        fs.ReadBuffer(B[0], Length(B));
      Result := True;
    finally
      fs.Free;
    end;
  except
  end;
end;

function RotateJpegLossless(const FileName: string; Clockwise: Boolean; out Err: string): Boolean;
var
  b, tiff, nb, seg: TBytes;
  p, segLen, app1Pos, insertPos, base, tsize, ifd0, cnt, i, e, cur, newO, newIfd, k, outLen: Integer;
  big: Boolean;
  tag, entryOfs: Integer;
  st: Stat;
  age: LongInt;
  fs: TFileStream;
  tmp: string;
  marker: Byte;
begin
  Result := False;
  Err := '';
  if not ReadAll(FileName, b) then
  begin
    Err := 'Cannot read file';
    Exit;
  end;
  if (Length(b) < 4) or (b[0] <> $FF) or (b[1] <> $D8) then
  begin
    Err := 'Not a JPEG file';
    Exit;
  end;
  // locate the Exif APP1 segment and where a new one would go
  app1Pos := -1;
  segLen := 0;
  insertPos := 2;
  p := 2;
  while p + 4 <= Length(b) do
  begin
    if b[p] <> $FF then Break;
    marker := b[p + 1];
    if marker = $FF then begin Inc(p); Continue; end;
    if (marker = $DA) or (marker = $D9) then Break;
    segLen := (b[p + 2] shl 8) or b[p + 3];
    if (segLen < 2) or (p + 2 + segLen > Length(b)) then Break;
    if (marker = $E0) and (p = 2) then
      insertPos := p + 2 + segLen;
    if (marker = $E1) and (segLen >= 16) and (b[p + 4] = $45) and (b[p + 5] = $78) and
       (b[p + 6] = $69) and (b[p + 7] = $66) and (b[p + 8] = 0) and (b[p + 9] = 0) then
    begin
      app1Pos := p;
      Break;
    end;
    p := p + 2 + segLen;
  end;

  age := FileAge(FileName);
  cur := 1;
  big := True;

  if app1Pos < 0 then
  begin
    // no EXIF at all: insert a minimal one carrying only the orientation
    if Clockwise then newO := OrientCW[1] else newO := OrientCCW[1];
    SetLength(seg, 0);
    seg := [$FF, $E1, 0, 34, $45, $78, $69, $66, 0, 0,
      $4D, $4D, 0, $2A, 0, 0, 0, 8,
      0, 1, 1, 2, 0, 3, 0, 0, 0, 1, 0, newO, 0, 0,
      0, 0, 0, 0];
    SetLength(nb, Length(b) + Length(seg));
    Move(b[0], nb[0], insertPos);
    Move(seg[0], nb[insertPos], Length(seg));
    Move(b[insertPos], nb[insertPos + Length(seg)], Length(b) - insertPos);
  end
  else
  begin
    base := app1Pos + 10;
    tsize := segLen - 8;
    if (b[base] = $4D) and (b[base + 1] = $4D) then big := True
    else if (b[base] = $49) and (b[base + 1] = $49) then big := False
    else begin Err := 'Unreadable EXIF block'; Exit; end;
    ifd0 := Integer(Get32(b, base + 4, big));
    if (ifd0 < 8) or (ifd0 + 2 > tsize) then begin Err := 'Unreadable EXIF block'; Exit; end;
    cnt := Get16(b, base + ifd0, big);
    if ifd0 + 2 + cnt * 12 + 4 > tsize then begin Err := 'Unreadable EXIF block'; Exit; end;
    entryOfs := -1;
    for i := 0 to cnt - 1 do
    begin
      e := base + ifd0 + 2 + i * 12;
      if Get16(b, e, big) = $0112 then
      begin
        entryOfs := e;
        Break;
      end;
    end;
    if entryOfs >= 0 then
    begin
      cur := Get16(b, entryOfs + 8, big);
      if (cur < 1) or (cur > 8) then cur := 1;
      if Clockwise then newO := OrientCW[cur] else newO := OrientCCW[cur];
      // patch the 12 byte entry in place
      Put16(b, entryOfs + 2, 3, big);
      Put32(b, entryOfs + 4, 1, big);
      Put16(b, entryOfs + 8, newO, big);
      Put16(b, entryOfs + 10, 0, big);
      try
        fs := TFileStream.Create(FileName, fmOpenReadWrite or fmShareDenyNone);
        try
          fs.Position := entryOfs;
          fs.WriteBuffer(b[entryOfs], 12);
        finally
          fs.Free;
        end;
        if age <> -1 then FileSetDate(FileName, age);
        Result := True;
      except
        on E: Exception do Err := E.Message;
      end;
      Exit;
    end;
    // EXIF without orientation: append a new IFD0 (old data stays valid, offsets are absolute)
    if Clockwise then newO := OrientCW[1] else newO := OrientCCW[1];
    newIfd := (tsize + 1) and not 1;
    SetLength(tiff, newIfd + 2 + (cnt + 1) * 12 + 4);
    FillChar(tiff[0], Length(tiff), 0);
    Move(b[base], tiff[0], tsize);
    Put32(tiff, 4, newIfd, big);
    Put16(tiff, newIfd, cnt + 1, big);
    k := 0;
    e := newIfd + 2;
    for i := 0 to cnt - 1 do
    begin
      tag := Get16(b, base + ifd0 + 2 + i * 12, big);
      if (k = 0) and (tag > $0112) then
      begin
        Put16(tiff, e, $0112, big); Put16(tiff, e + 2, 3, big); Put32(tiff, e + 4, 1, big);
        Put16(tiff, e + 8, newO, big);
        Inc(e, 12);
        k := 1;
      end;
      Move(b[base + ifd0 + 2 + i * 12], tiff[e], 12);
      Inc(e, 12);
    end;
    if k = 0 then
    begin
      Put16(tiff, e, $0112, big); Put16(tiff, e + 2, 3, big); Put32(tiff, e + 4, 1, big);
      Put16(tiff, e + 8, newO, big);
      Inc(e, 12);
    end;
    Move(b[base + ifd0 + 2 + cnt * 12], tiff[e], 4);   // link to the next IFD
    outLen := 2 + 6 + Length(tiff);
    if outLen > 65535 then begin Err := 'EXIF block too large'; Exit; end;
    SetLength(nb, app1Pos + 2 + outLen + (Length(b) - (app1Pos + 2 + segLen)));
    Move(b[0], nb[0], app1Pos);
    nb[app1Pos] := $FF;
    nb[app1Pos + 1] := $E1;
    nb[app1Pos + 2] := outLen shr 8;
    nb[app1Pos + 3] := outLen and $FF;
    Move(b[app1Pos + 4], nb[app1Pos + 4], 6);          // "Exif\0\0"
    Move(tiff[0], nb[app1Pos + 10], Length(tiff));
    Move(b[app1Pos + 2 + segLen], nb[app1Pos + 2 + outLen], Length(b) - (app1Pos + 2 + segLen));
  end;

  // whole file rewritten through a temporary file
  tmp := FileName + '.ttviewer.tmp';
  try
    fs := TFileStream.Create(tmp, fmCreate);
    try
      fs.WriteBuffer(nb[0], Length(nb));
    finally
      fs.Free;
    end;
    if fpStat(FileName, st) = 0 then
      fpChmod(tmp, st.st_mode and &7777);
    if not RenameFile(tmp, FileName) then
    begin
      DeleteFile(tmp);
      Err := 'Cannot replace the file';
      Exit;
    end;
    if age <> -1 then FileSetDate(FileName, age);
    Result := True;
  except
    on E: Exception do
    begin
      DeleteFile(tmp);
      Err := E.Message;
    end;
  end;
end;

function ExtractExifSegment(const B: TBytes; out Seg: TBytes): Boolean;
var
  p, segLen: Integer;
  marker: Byte;
begin
  Result := False;
  SetLength(Seg, 0);
  if (Length(B) < 4) or (B[0] <> $FF) or (B[1] <> $D8) then
    Exit;
  p := 2;
  while p + 4 <= Length(B) do
  begin
    if B[p] <> $FF then Break;
    marker := B[p + 1];
    if marker = $FF then begin Inc(p); Continue; end;
    if (marker = $DA) or (marker = $D9) then Break;
    segLen := (B[p + 2] shl 8) or B[p + 3];
    if (segLen < 2) or (p + 2 + segLen > Length(B)) then Break;
    if (marker = $E1) and (segLen >= 16) and (B[p + 4] = $45) and (B[p + 5] = $78) and
       (B[p + 6] = $69) and (B[p + 7] = $66) then
    begin
      SetLength(Seg, segLen + 2);
      Move(B[p], Seg[0], segLen + 2);
      Exit(True);
    end;
    p := p + 2 + segLen;
  end;
end;

procedure ResetSegmentOrientation(var Seg: TBytes);
var
  base, tsize, ifd0, cnt, i, e: Integer;
  big: Boolean;
begin
  base := 10;
  tsize := Length(Seg) - 10;
  if tsize < 14 then Exit;
  if (Seg[base] = $4D) and (Seg[base + 1] = $4D) then big := True
  else if (Seg[base] = $49) and (Seg[base + 1] = $49) then big := False
  else Exit;
  ifd0 := Integer(Get32(Seg, base + 4, big));
  if (ifd0 < 8) or (ifd0 + 2 > tsize) then Exit;
  cnt := Get16(Seg, base + ifd0, big);
  for i := 0 to cnt - 1 do
  begin
    e := base + ifd0 + 2 + i * 12;
    if e + 12 > Length(Seg) then Exit;
    if Get16(Seg, e, big) = $0112 then
    begin
      Put16(Seg, e + 2, 3, big);
      Put32(Seg, e + 4, 1, big);
      Put16(Seg, e + 8, 1, big);
      Put16(Seg, e + 10, 0, big);
      Exit;
    end;
  end;
end;

function InsertAppSegment(const Jpg, Seg: TBytes): TBytes;
var
  pos, l: Integer;
begin
  pos := 2;
  if (Length(Jpg) > 6) and (Jpg[2] = $FF) and (Jpg[3] = $E0) then
  begin
    l := (Jpg[4] shl 8) or Jpg[5];
    if 4 + l <= Length(Jpg) then
      pos := 4 + l;
  end;
  SetLength(Result, Length(Jpg) + Length(Seg));
  Move(Jpg[0], Result[0], pos);
  Move(Seg[0], Result[pos], Length(Seg));
  Move(Jpg[pos], Result[pos + Length(Seg)], Length(Jpg) - pos);
end;

end.
