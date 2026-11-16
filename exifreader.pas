unit exifreader;

{ Minimal EXIF reader working on an in-memory JPEG. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Math;

type
  TExifData = record
    Orientation: Integer;           // 1..8, 1 when missing
    Names: array of string;
    Values: array of string;
  end;

procedure ReadExif(Buf: PByte; Size: PtrUInt; out Exif: TExifData);
procedure ExifAdd(var Exif: TExifData; const AName, AValue: string);

implementation

type
  TTiff = record
    Base: PByte;
    Size: PtrUInt;
    Big: Boolean;
  end;

function U16(const T: TTiff; Ofs: PtrUInt): Word;
begin
  if Ofs + 2 > T.Size then
    Exit(0);
  if T.Big then
    Result := (Word(T.Base[Ofs]) shl 8) or T.Base[Ofs + 1]
  else
    Result := (Word(T.Base[Ofs + 1]) shl 8) or T.Base[Ofs];
end;

function U32(const T: TTiff; Ofs: PtrUInt): Cardinal;
begin
  if Ofs + 4 > T.Size then
    Exit(0);
  if T.Big then
    Result := (Cardinal(T.Base[Ofs]) shl 24) or (Cardinal(T.Base[Ofs + 1]) shl 16) or
      (Cardinal(T.Base[Ofs + 2]) shl 8) or T.Base[Ofs + 3]
  else
    Result := (Cardinal(T.Base[Ofs + 3]) shl 24) or (Cardinal(T.Base[Ofs + 2]) shl 16) or
      (Cardinal(T.Base[Ofs + 1]) shl 8) or T.Base[Ofs];
end;

procedure ExifAdd(var Exif: TExifData; const AName, AValue: string);
var
  n: Integer;
begin
  n := Length(Exif.Names);
  SetLength(Exif.Names, n + 1);
  SetLength(Exif.Values, n + 1);
  Exif.Names[n] := AName;
  Exif.Values[n] := AValue;
end;

const
  TypeSize: array[1..12] of Integer = (1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8);

{ Offset of the value bytes of an IFD entry, or 0 when out of range. }
function ValueOfs(const T: TTiff; Entry: PtrUInt; out Typ: Word; out Count: Cardinal): PtrUInt;
var
  total: QWord;
begin
  Typ := U16(T, Entry + 2);
  Count := U32(T, Entry + 4);
  Result := 0;
  if (Typ < 1) or (Typ > 12) then
    Exit;
  total := QWord(Count) * TypeSize[Typ];
  if total <= 4 then
    Result := Entry + 8
  else
  begin
    Result := U32(T, Entry + 8);
    if Result + total > T.Size then
      Result := 0;
  end;
end;

function EntryInt(const T: TTiff; Entry: PtrUInt): Int64;
var
  typ: Word;
  cnt: Cardinal;
  o: PtrUInt;
begin
  Result := 0;
  o := ValueOfs(T, Entry, typ, cnt);
  if (o = 0) or (cnt = 0) then
    Exit;
  case typ of
    1, 7: Result := T.Base[o];
    3: Result := U16(T, o);
    4: Result := U32(T, o);
    8: Result := SmallInt(U16(T, o));
    9: Result := LongInt(U32(T, o));
  end;
end;

function EntryRational(const T: TTiff; Entry: PtrUInt; Index: Integer; out Num, Den: Int64): Boolean;
var
  typ: Word;
  cnt: Cardinal;
  o: PtrUInt;
begin
  Result := False;
  o := ValueOfs(T, Entry, typ, cnt);
  if (o = 0) or (typ <> 5) and (typ <> 10) or (Cardinal(Index) >= cnt) then
    Exit;
  o := o + PtrUInt(Index) * 8;
  if typ = 5 then
  begin
    Num := U32(T, o);
    Den := U32(T, o + 4);
  end
  else
  begin
    Num := LongInt(U32(T, o));
    Den := LongInt(U32(T, o + 4));
  end;
  Result := Den <> 0;
end;

function EntryString(const T: TTiff; Entry: PtrUInt): string;
var
  typ: Word;
  cnt: Cardinal;
  o: PtrUInt;
  i: Integer;
begin
  Result := '';
  o := ValueOfs(T, Entry, typ, cnt);
  if (o = 0) or (cnt = 0) then
    Exit;
  if cnt > 512 then
    cnt := 512;
  SetLength(Result, cnt);
  for i := 1 to cnt do
    Result[i] := Chr(T.Base[o + PtrUInt(i - 1)]);
  i := Pos(#0, Result);
  if i > 0 then
    SetLength(Result, i - 1);
  Result := Trim(Result);
end;

function FmtRat(Num, Den: Int64; Decimals: Integer): string;
begin
  Result := FloatToStrF(Num / Den, ffFixed, 15, Decimals);
end;

function GpsCoord(const T: TTiff; Entry: PtrUInt; const Ref: string): string;
var
  n, d: Int64;
  deg, mn, sec: Double;
begin
  Result := '';
  if not EntryRational(T, Entry, 0, n, d) then Exit;
  deg := n / d;
  if not EntryRational(T, Entry, 1, n, d) then Exit;
  mn := n / d;
  if not EntryRational(T, Entry, 2, n, d) then Exit;
  sec := n / d;
  Result := Format('%d° %d'' %.2f" %s', [Trunc(deg), Trunc(mn), sec, Ref]);
end;

function ExposureTimeStr(Num, Den: Int64): string;
begin
  if Num = 0 then
    Exit('0 s');
  if Num >= Den then
    Result := FmtRat(Num, Den, 1) + ' s'
  else
    Result := '1/' + IntToStr(Round(Den / Num)) + ' s';
end;

function FlashStr(V: Int64): string;
begin
  if (V and 1) <> 0 then Result := 'Fired' else Result := 'Did not fire';
end;

function MeteringStr(V: Int64): string;
begin
  case V of
    1: Result := 'Average';
    2: Result := 'Center weighted';
    3: Result := 'Spot';
    4: Result := 'Multi-spot';
    5: Result := 'Pattern';
    6: Result := 'Partial';
  else Result := IntToStr(V);
  end;
end;

function ProgramStr(V: Int64): string;
begin
  case V of
    1: Result := 'Manual';
    2: Result := 'Normal';
    3: Result := 'Aperture priority';
    4: Result := 'Shutter priority';
    5: Result := 'Creative';
    6: Result := 'Action';
    7: Result := 'Portrait';
    8: Result := 'Landscape';
  else Result := IntToStr(V);
  end;
end;

function OrientationStr(V: Int64): string;
begin
  case V of
    1: Result := 'Normal';
    2: Result := 'Mirrored';
    3: Result := 'Rotated 180°';
    4: Result := 'Flipped';
    5: Result := 'Transposed';
    6: Result := 'Rotated 90° CW';
    7: Result := 'Transversed';
    8: Result := 'Rotated 90° CCW';
  else Result := IntToStr(V);
  end;
end;

procedure ReadExifIfd(const T: TTiff; Ifd: PtrUInt; var Exif: TExifData; Depth: Integer);
var
  cnt, i: Integer;
  e: PtrUInt;
  tag: Word;
  n, d: Int64;
  s: string;
begin
  if (Ifd = 0) or (Ifd + 2 > T.Size) then
    Exit;
  cnt := U16(T, Ifd);
  for i := 0 to cnt - 1 do
  begin
    e := Ifd + 2 + PtrUInt(i) * 12;
    if e + 12 > T.Size then
      Break;
    tag := U16(T, e);
    case tag of
      $829A: if EntryRational(T, e, 0, n, d) then ExifAdd(Exif, 'Exposure time', ExposureTimeStr(n, d));
      $829D: if EntryRational(T, e, 0, n, d) then ExifAdd(Exif, 'Aperture', 'f/' + FmtRat(n, d, 1));
      $8822: ExifAdd(Exif, 'Exposure program', ProgramStr(EntryInt(T, e)));
      $8827: ExifAdd(Exif, 'ISO', IntToStr(EntryInt(T, e)));
      $9003: ExifAdd(Exif, 'Date taken', EntryString(T, e));
      $9204: if EntryRational(T, e, 0, n, d) then ExifAdd(Exif, 'Exposure bias', FmtRat(n, d, 2) + ' EV');
      $9207: ExifAdd(Exif, 'Metering', MeteringStr(EntryInt(T, e)));
      $9209: ExifAdd(Exif, 'Flash', FlashStr(EntryInt(T, e)));
      $920A: if EntryRational(T, e, 0, n, d) then ExifAdd(Exif, 'Focal length', FmtRat(n, d, 1) + ' mm');
      $A405: ExifAdd(Exif, 'Focal length (35mm)', IntToStr(EntryInt(T, e)) + ' mm');
      $A403: if EntryInt(T, e) = 0 then ExifAdd(Exif, 'White balance', 'Auto')
             else ExifAdd(Exif, 'White balance', 'Manual');
      $A434:
        begin
          s := EntryString(T, e);
          if s <> '' then ExifAdd(Exif, 'Lens', s);
        end;
    end;
  end;
end;

procedure ReadGpsIfd(const T: TTiff; Ifd: PtrUInt; var Exif: TExifData);
var
  cnt, i: Integer;
  e, eLat, eLon, eAlt: PtrUInt;
  refLat, refLon, s: string;
  altBelow: Boolean;
  n, d: Int64;
begin
  if (Ifd = 0) or (Ifd + 2 > T.Size) then
    Exit;
  eLat := 0; eLon := 0; eAlt := 0; altBelow := False;
  refLat := ''; refLon := '';
  cnt := U16(T, Ifd);
  for i := 0 to cnt - 1 do
  begin
    e := Ifd + 2 + PtrUInt(i) * 12;
    if e + 12 > T.Size then
      Break;
    case U16(T, e) of
      1: refLat := EntryString(T, e);
      2: eLat := e;
      3: refLon := EntryString(T, e);
      4: eLon := e;
      5: altBelow := EntryInt(T, e) = 1;
      6: eAlt := e;
    end;
  end;
  if (eLat <> 0) and (eLon <> 0) then
  begin
    s := GpsCoord(T, eLat, refLat);
    if s <> '' then ExifAdd(Exif, 'GPS latitude', s);
    s := GpsCoord(T, eLon, refLon);
    if s <> '' then ExifAdd(Exif, 'GPS longitude', s);
  end;
  if (eAlt <> 0) and EntryRational(T, eAlt, 0, n, d) then
  begin
    s := FmtRat(n, d, 1) + ' m';
    if altBelow then s := '-' + s;
    ExifAdd(Exif, 'GPS altitude', s);
  end;
end;

procedure ReadTiff(const T: TTiff; var Exif: TExifData);
var
  ifd0, cnt, i: Integer;
  e: PtrUInt;
  exifIfd, gpsIfd: PtrUInt;
  s: string;
begin
  exifIfd := 0;
  gpsIfd := 0;
  ifd0 := U32(T, 4);
  if (ifd0 = 0) or (PtrUInt(ifd0) + 2 > T.Size) then
    Exit;
  cnt := U16(T, ifd0);
  for i := 0 to cnt - 1 do
  begin
    e := PtrUInt(ifd0) + 2 + PtrUInt(i) * 12;
    if e + 12 > T.Size then
      Break;
    case U16(T, e) of
      $010F: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Make', s); end;
      $0110: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Model', s); end;
      $0112:
        begin
          Exif.Orientation := EntryInt(T, e);
          if (Exif.Orientation < 1) or (Exif.Orientation > 8) then
            Exif.Orientation := 1;
          ExifAdd(Exif, 'Orientation', OrientationStr(Exif.Orientation));
        end;
      $0131: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Software', s); end;
      $0132: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Date modified', s); end;
      $013B: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Artist', s); end;
      $8298: begin s := EntryString(T, e); if s <> '' then ExifAdd(Exif, 'Copyright', s); end;
      $8769: exifIfd := EntryInt(T, e);
      $8825: gpsIfd := EntryInt(T, e);
    end;
  end;
  ReadExifIfd(T, exifIfd, Exif, 0);
  ReadGpsIfd(T, gpsIfd, Exif);
end;

procedure ReadExif(Buf: PByte; Size: PtrUInt; out Exif: TExifData);
var
  p, segLen: PtrUInt;
  marker: Byte;
  t: TTiff;
begin
  Exif.Orientation := 1;
  SetLength(Exif.Names, 0);
  SetLength(Exif.Values, 0);
  if (Size < 4) or (Buf[0] <> $FF) or (Buf[1] <> $D8) then
    Exit;
  p := 2;
  while p + 4 <= Size do
  begin
    if Buf[p] <> $FF then
      Break;
    marker := Buf[p + 1];
    if marker = $FF then begin Inc(p); Continue; end;
    if (marker = $DA) or (marker = $D9) then
      Break;                          // image data: no EXIF past this point
    segLen := (PtrUInt(Buf[p + 2]) shl 8) or Buf[p + 3];
    if (segLen < 2) or (p + 2 + segLen > Size) then
      Break;
    if (marker = $E1) and (segLen >= 16) and (PCardinal(@Buf[p + 4])^ = NtoLE(Cardinal($66697845))) and
       (Buf[p + 8] = 0) and (Buf[p + 9] = 0) then
    begin
      t.Base := @Buf[p + 10];
      t.Size := segLen - 8;
      if (t.Base[0] = Ord('M')) and (t.Base[1] = Ord('M')) then
        t.Big := True
      else if (t.Base[0] = Ord('I')) and (t.Base[1] = Ord('I')) then
        t.Big := False
      else
        Exit;
      ReadTiff(t, Exif);
      Exit;
    end;
    p := p + 2 + segLen;
  end;
end;

end.
