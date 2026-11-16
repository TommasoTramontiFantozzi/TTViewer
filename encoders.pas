unit encoders;

{ Image encoding for Transcode / Save: JPEG through libjpeg-turbo, every other format
  through the writers of gdk-pixbuf. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, tjpeg, jpegworkers, pixbufload, jpegrotate;

type
  TEncSettings = record
    Format: string;                 // 'jpeg' or a gdk-pixbuf writer name ('png', 'tiff', ...)
    Quality: Integer;               // jpeg
    Subsampling: Integer;           // jpeg, TJSAMP_*
    Progressive: Boolean;           // jpeg
    KeepExif: Boolean;              // jpeg -> jpeg only
    Keys, Values: TStringList;      // gdk-pixbuf options (owned by the caller)
  end;

{ Rotates quarter turns clockwise first (0..3), then writes Dest. }
function TranscodeFile(const Src, Dest: string; const S: TEncSettings; Quarter: Integer;
  out Err: string): Boolean;

implementation

procedure FlattenOnWhite(Pix: TPixelBuffer);
var
  i: Integer;
  p: PByte;
  a: Cardinal;
begin
  p := Pix.Data;
  for i := 1 to Pix.Width * Pix.Height do
  begin
    a := p[3];
    if a < 255 then
    begin
      p[0] := (p[0] * a + 255 * (255 - a)) div 255;
      p[1] := (p[1] * a + 255 * (255 - a)) div 255;
      p[2] := (p[2] * a + 255 * (255 - a)) div 255;
      p[3] := 255;
    end;
    Inc(p, 4);
  end;
end;

procedure WriteBytes(const FileName: string; Buf: PByte; Size: Int64);
var
  fs: TFileStream;
begin
  fs := TFileStream.Create(FileName, fmCreate);
  try
    if Size > 0 then
      fs.WriteBuffer(Buf^, Size);
  finally
    fs.Free;
  end;
end;

function TranscodeFile(const Src, Dest: string; const S: TEncSettings; Quarter: Integer;
  out Err: string): Boolean;
var
  pix: TPixelBuffer;
  hasAlpha: Boolean;
  img: TLoadedImage;
  p: PByte;
  i: Integer;
  b: Byte;
  exifSeg, srcBytes, outBytes, jpg: TBytes;
  fs: TFileStream;
  tj: tjhandle;
  buf: PByte;
  sz: PtrUInt;
  flags: Integer;
begin
  Result := False;
  Err := '';
  pix := nil;
  SetLength(exifSeg, 0);
  try
    // ---- decode (oriented, RGBA byte order)
    if IsJpegFile(Src) then
    begin
      img := DecodeFile(Src, 0, 0, False);
      try
        if img.Pixels = nil then begin Err := img.Error; Exit; end;
        pix := img.Pixels;
        img.Pixels := nil;
      finally
        img.Free;
      end;
      p := pix.Data;
      for i := 1 to pix.Width * pix.Height do   // BGRX -> RGBX
      begin
        b := p[0]; p[0] := p[2]; p[2] := b;
        Inc(p, 4);
      end;
      hasAlpha := False;
      if S.KeepExif and (S.Format = 'jpeg') then
      begin
        fs := TFileStream.Create(Src, fmOpenRead or fmShareDenyNone);
        try
          SetLength(srcBytes, fs.Size);
          if fs.Size > 0 then fs.ReadBuffer(srcBytes[0], fs.Size);
        finally
          fs.Free;
        end;
        if ExtractExifSegment(srcBytes, exifSeg) then
          ResetSegmentOrientation(exifSeg);
      end;
    end
    else if not PixbufLoadRGBA(Src, pix, hasAlpha, Err) then
      Exit;

    for i := 1 to Quarter mod 4 do
      pix := RotatePixels(pix, True);

    // ---- encode
    if S.Format = 'jpeg' then
    begin
      if not Assigned(tjCompress2) then begin Err := 'libturbojpeg has no compressor'; Exit; end;
      if hasAlpha then FlattenOnWhite(pix);
      flags := TJFLAG_FASTDCT * 0;
      if S.Progressive then flags := flags or TJFLAG_PROGRESSIVE;
      tj := tjInitCompress();
      buf := nil;
      sz := 0;
      try
        if tjCompress2(tj, pix.Data, pix.Width, 0, pix.Height, TJPF_RGBX, buf, sz,
             S.Subsampling, S.Quality, flags) <> 0 then
        begin
          Err := TurboJpegError;
          Exit;
        end;
        SetLength(jpg, sz);
        Move(buf^, jpg[0], sz);
      finally
        if buf <> nil then tjFree(buf);
        tjDestroy(tj);
      end;
      if Length(exifSeg) > 0 then
        outBytes := InsertAppSegment(jpg, exifSeg)
      else
        outBytes := jpg;
      WriteBytes(Dest, @outBytes[0], Length(outBytes));
      Result := True;
    end
    else
      Result := PixbufSaveRGBA(pix, hasAlpha, Dest, S.Format, S.Keys, S.Values, Err);
  except
    on E: Exception do
    begin
      Err := E.Message;
      Result := False;
    end;
  end;
  pix.Free;
  if not Result then
    DeleteFile(Dest);
end;

end.
