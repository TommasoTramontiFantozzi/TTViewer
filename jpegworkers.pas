unit jpegworkers;

{ Background JPEG decoding (libjpeg-turbo).
  - TMainImageLoader: decodes the image shown in the central panel; latest request wins.
  - TThumbLoader: decodes thumbnails, visible ones first; it yields to the main loader. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Math, tjpeg, exifreader;

type
  { 32 bit BGRX pixels, stride = Width * 4 }
  TPixelBuffer = class
  public
    Width, Height: Integer;
    Data: PByte;
    constructor Create(AWidth, AHeight: Integer);
    destructor Destroy; override;
  end;

  TLoadedImage = class
  public
    FileName: string;
    Seq: Integer;
    Pixels: TPixelBuffer;          // nil on error
    OrigW, OrigH: Integer;         // full resolution size, orientation applied
    Denom: Integer;                // DCT scaling used (1, 2, 4, 8)
    Exif: TExifData;
    Error: string;
    destructor Destroy; override;
  end;

  TImageLoadedEvent = procedure(Sender: TObject; Img: TLoadedImage) of object;

  TMainImageLoader = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FFileName: string;
    FBoxW, FBoxH: Integer;
    FSeq: Integer;
    FHasRequest: Boolean;
    FResult: TLoadedImage;
    FOnLoaded: TImageLoadedEvent;
    procedure Deliver;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    { Decode FileName so that it can be shown at least BoxW x BoxH (0 = full resolution).
      Returns the sequence number of the request. }
    function Request(const AFileName: string; BoxW, BoxH: Integer): Integer;
    procedure Shutdown;
    property OnLoaded: TImageLoadedEvent read FOnLoaded write FOnLoaded;
  end;

  TThumbResult = class
  public
    Gen, Index, Size: Integer;     // Size: bounding box the thumbnail was made for
    Pixels: TPixelBuffer;          // nil when decoding failed
    destructor Destroy; override;
  end;

  TThumbEvent = procedure(Sender: TObject; R: TThumbResult) of object;

  TThumbLoader = class(TThread)
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FFiles: array of string;
    FDone: array of Integer;       // 0 = todo, -1 = failed, else box size already produced
    FGen: Integer;
    FFirst, FLast: Integer;
    FWant: Integer;
    FResults: TList;
    FQueued: Boolean;
    FOnThumb: TThumbEvent;
    function PickJob(out Index, Size, Gen: Integer; out FileName: string): Boolean;
    procedure Post(R: TThumbResult);
    procedure Drain;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetFiles(const Files: array of string; Gen: Integer);
    procedure SetVisible(First, Last: Integer);
    { Drops files from the list (sorted ascending), keeping what is already produced. }
    procedure RemoveIndices(const Idx: array of Integer; NewGen: Integer);
    { Forces a thumbnail to be produced again (e.g. after a rotation). }
    procedure Redo(Index: Integer);
    { Wanted thumbnail bounding box; thumbnails produced for a smaller box are redone. }
    procedure SetWantedSize(Size: Integer);
    procedure Shutdown;
    property OnThumb: TThumbEvent read FOnThumb write FOnThumb;
  end;

{ Resamples to DW x DH (box filter; does not touch Src). }
function ScalePixels(Src: TPixelBuffer; DW, DH: Integer): TPixelBuffer;

{ Synchronous decode (any supported format) so that it fits at least BoxW x BoxH
  (0 = full size); with Exact the result is resized to fit exactly in the box. }
function DecodeFile(const FileName: string; BoxW, BoxH: Integer; Exact: Boolean): TLoadedImage;

{ Rotates 90 degrees (consumes Src). }
function RotatePixels(Src: TPixelBuffer; Clockwise: Boolean): TPixelBuffer;

{ Main image loader signals "idle" here; the thumbnail thread waits for it. }
function MainLoaderIdle: TEvent;

implementation

uses
  pixbufload;

var
  GMainIdle: TEvent;

function MainLoaderIdle: TEvent;
begin
  Result := GMainIdle;
end;

{ TPixelBuffer }

constructor TPixelBuffer.Create(AWidth, AHeight: Integer);
begin
  Width := AWidth;
  Height := AHeight;
  Data := GetMem(Int64(AWidth) * AHeight * 4);
end;

destructor TPixelBuffer.Destroy;
begin
  FreeMem(Data);
  inherited Destroy;
end;

destructor TLoadedImage.Destroy;
begin
  Pixels.Free;
  inherited Destroy;
end;

destructor TThumbResult.Destroy;
begin
  Pixels.Free;
  inherited Destroy;
end;

{ ---- pixel helpers ---- }

{ Applies an EXIF orientation (1..8); returns Src when nothing to do, else frees Src. }
function ApplyOrientation(Src: TPixelBuffer; Orientation: Integer): TPixelBuffer;
var
  w, h, x, y, dx, dy: Integer;
  dw: Integer;
  s, d: PCardinal;
begin
  if (Orientation <= 1) or (Orientation > 8) then
    Exit(Src);
  w := Src.Width;
  h := Src.Height;
  if Orientation >= 5 then
    Result := TPixelBuffer.Create(h, w)
  else
    Result := TPixelBuffer.Create(w, h);
  dw := Result.Width;
  s := PCardinal(Src.Data);
  d := PCardinal(Result.Data);
  for y := 0 to h - 1 do
    for x := 0 to w - 1 do
    begin
      case Orientation of
        2: begin dx := w - 1 - x; dy := y; end;
        3: begin dx := w - 1 - x; dy := h - 1 - y; end;
        4: begin dx := x; dy := h - 1 - y; end;
        5: begin dx := y; dy := x; end;
        6: begin dx := h - 1 - y; dy := x; end;
        7: begin dx := h - 1 - y; dy := w - 1 - x; end;
      else
        begin dx := y; dy := w - 1 - x; end;
      end;
      d[dy * dw + dx] := s^;
      Inc(s);
    end;
  Src.Free;
end;

function ScalePixels(Src: TPixelBuffer; DW, DH: Integer): TPixelBuffer;
var
  dx, dy, sx, sy, x0, x1, y0, y1, n: Integer;
  sr, sg, sb: Cardinal;
  p: PByte;
  o: PByte;
begin
  Result := TPixelBuffer.Create(Max(1, DW), Max(1, DH));
  DW := Result.Width;
  DH := Result.Height;
  o := Result.Data;
  for dy := 0 to DH - 1 do
  begin
    y0 := (Int64(dy) * Src.Height) div DH;
    y1 := Max(y0 + 1, (Int64(dy + 1) * Src.Height) div DH);
    for dx := 0 to DW - 1 do
    begin
      x0 := (Int64(dx) * Src.Width) div DW;
      x1 := Max(x0 + 1, (Int64(dx + 1) * Src.Width) div DW);
      sb := 0; sg := 0; sr := 0;
      for sy := y0 to y1 - 1 do
      begin
        p := Src.Data + (Int64(sy) * Src.Width + x0) * 4;
        for sx := x0 to x1 - 1 do
        begin
          sb += p[0]; sg += p[1]; sr += p[2];
          Inc(p, 4);
        end;
      end;
      n := (x1 - x0) * (y1 - y0);
      o[0] := sb div Cardinal(n);
      o[1] := sg div Cardinal(n);
      o[2] := sr div Cardinal(n);
      o[3] := 255;
      Inc(o, 4);
    end;
  end;
end;

{ Box-filter downscale to DW x DH (never upscales); consumes Src. }
function Downscale(Src: TPixelBuffer; DW, DH: Integer): TPixelBuffer;
begin
  if (DW >= Src.Width) or (DH >= Src.Height) or (DW < 1) or (DH < 1) then
    Exit(Src);
  Result := ScalePixels(Src, DW, DH);
  Src.Free;
end;

function ReadWholeFile(const FileName: string; out Buf: TBytes): Boolean;
var
  fs: TFileStream;
begin
  Result := False;
  try
    fs := TFileStream.Create(FileName, fmOpenRead or fmShareDenyNone);
    try
      SetLength(Buf, fs.Size);
      if Length(Buf) > 0 then
        fs.ReadBuffer(Buf[0], Length(Buf));
      Result := Length(Buf) > 0;
    finally
      fs.Free;
    end;
  except
    Result := False;
  end;
end;

{ Decodes FileName; the result fits at least in BoxW x BoxH when possible and is never
  scaled by more than DCT scaling, except when Exact is set (then it is resized to fit
  exactly in the box). BoxW = 0 means full resolution. }
procedure DecodeJpeg(Tj: tjhandle; const FileName: string; BoxW, BoxH: Integer;
  Exact: Boolean; Img: TLoadedImage);
var
  buf: TBytes;
  w, h, subsamp, cs, sw, sh, d, ow, oh: Integer;
  scale: Double;
  px: TPixelBuffer;
  flags: Integer;
begin
  if not ReadWholeFile(FileName, buf) then
  begin
    Img.Error := 'Cannot read file';
    Exit;
  end;
  ReadExif(@buf[0], Length(buf), Img.Exif);
  if tjDecompressHeader3(Tj, @buf[0], Length(buf), @w, @h, @subsamp, @cs) <> 0 then
  begin
    Img.Error := TurboJpegError;
    Exit;
  end;
  if Img.Exif.Orientation >= 5 then
  begin
    ow := h; oh := w;
  end
  else
  begin
    ow := w; oh := h;
  end;
  Img.OrigW := ow;
  Img.OrigH := oh;
  if (BoxW <= 0) or (BoxH <= 0) then
    scale := 1
  else
    scale := Min(1.0, Min(BoxW / ow, BoxH / oh));
  d := TurboJpegDenom(scale);
  Img.Denom := d;
  sw := (w + d - 1) div d;
  sh := (h + d - 1) div d;
  px := TPixelBuffer.Create(sw, sh);
  flags := TJFLAG_FASTDCT;
  if Exact then
    flags := flags or TJFLAG_FASTUPSAMPLE;
  if tjDecompress2(Tj, @buf[0], Length(buf), px.Data, sw, 0, sh, TJPF_BGRX, flags) <> 0 then
  begin
    // a warning (e.g. truncated file) still leaves a usable image; real failures do not
    if Pos('Premature', TurboJpegError) = 0 then
    begin
      Img.Error := TurboJpegError;
      px.Free;
      Exit;
    end;
  end;
  px := ApplyOrientation(px, Img.Exif.Orientation);
  if Exact then
    px := Downscale(px, Max(1, Round(ow * scale)), Max(1, Round(oh * scale)));
  Img.Pixels := px;
end;

function RotatePixels(Src: TPixelBuffer; Clockwise: Boolean): TPixelBuffer;
begin
  if Clockwise then
    Result := ApplyOrientation(Src, 6)
  else
    Result := ApplyOrientation(Src, 8);
end;

{ Non-JPEG formats: full decode through gdk-pixbuf, then the same scaling contract as
  DecodeJpeg (Denom tells how much smaller than the original the result is). }
procedure DecodePixbuf(const FileName: string; BoxW, BoxH: Integer; Exact: Boolean; Img: TLoadedImage);
var
  px: TPixelBuffer;
  err: string;
  scale: Double;
  d: Integer;
begin
  if not PixbufDecode(FileName, px, err) then
  begin
    Img.Error := err;
    Exit;
  end;
  Img.OrigW := px.Width;
  Img.OrigH := px.Height;
  if (BoxW <= 0) or (BoxH <= 0) then
    scale := 1
  else
    scale := Min(1.0, Min(BoxW / px.Width, BoxH / px.Height));
  d := TurboJpegDenom(scale);
  if Exact then
  begin
    Img.Denom := d;
    px := Downscale(px, Max(1, Round(Img.OrigW * scale)), Max(1, Round(Img.OrigH * scale)));
  end
  else
  begin
    Img.Denom := d;
    if d > 1 then
      px := Downscale(px, (Img.OrigW + d - 1) div d, (Img.OrigH + d - 1) div d);
  end;
  Img.Pixels := px;
end;

procedure DecodeAny(Tj: tjhandle; const FileName: string; BoxW, BoxH: Integer;
  Exact: Boolean; Img: TLoadedImage);
begin
  if IsJpegFile(FileName) then
    DecodeJpeg(Tj, FileName, BoxW, BoxH, Exact, Img)
  else
    DecodePixbuf(FileName, BoxW, BoxH, Exact, Img);
end;

function DecodeFile(const FileName: string; BoxW, BoxH: Integer; Exact: Boolean): TLoadedImage;
var
  tj: tjhandle;
begin
  Result := TLoadedImage.Create;
  Result.FileName := FileName;
  Result.Denom := 1;
  tj := tjInitDecompress();
  try
    try
      DecodeAny(tj, FileName, BoxW, BoxH, Exact, Result);
    except
      on E: Exception do
        Result.Error := E.Message;
    end;
  finally
    tjDestroy(tj);
  end;
end;

{ ---- TMainImageLoader ---- }

constructor TMainImageLoader.Create;
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  inherited Create(False);
end;

destructor TMainImageLoader.Destroy;
begin
  Shutdown;
  WaitFor;
  FResult.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMainImageLoader.Shutdown;
begin
  Terminate;
  FWake.SetEvent;
end;

function TMainImageLoader.Request(const AFileName: string; BoxW, BoxH: Integer): Integer;
begin
  FLock.Enter;
  try
    Inc(FSeq);
    Result := FSeq;
    FFileName := AFileName;
    FBoxW := BoxW;
    FBoxH := BoxH;
    FHasRequest := True;
    GMainIdle.ResetEvent;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TMainImageLoader.Deliver;
var
  img: TLoadedImage;
begin
  FLock.Enter;
  try
    img := FResult;
    FResult := nil;
  finally
    FLock.Leave;
  end;
  if img = nil then
    Exit;
  if (Assigned(FOnLoaded)) and (img.Seq = FSeq) and not Terminated then
    FOnLoaded(Self, img)           // handler takes ownership
  else
    img.Free;
end;

procedure TMainImageLoader.Execute;
var
  tj: tjhandle;
  fn: string;
  bw, bh, seq: Integer;
  img: TLoadedImage;
  stale: TLoadedImage;
begin
  tj := tjInitDecompress();
  try
    while not Terminated do
    begin
      FWake.WaitFor(INFINITE);
      while not Terminated do
      begin
        FLock.Enter;
        try
          if not FHasRequest then
            Break;
          FHasRequest := False;
          fn := FFileName;
          bw := FBoxW;
          bh := FBoxH;
          seq := FSeq;
        finally
          FLock.Leave;
        end;
        img := TLoadedImage.Create;
        img.FileName := fn;
        img.Seq := seq;
        img.Denom := 1;
        try
          DecodeAny(tj, fn, bw, bh, False, img);
        except
          on E: Exception do
            img.Error := E.Message;
        end;
        FLock.Enter;
        try
          if seq = FSeq then
          begin
            stale := FResult;      // a previous result not yet consumed
            FResult := img;
          end
          else
            stale := img;          // superseded while decoding: drop it
        finally
          FLock.Leave;
        end;
        stale.Free;
        if stale <> img then
          Queue(@Deliver);
      end;
      if not Terminated then
      begin
        FLock.Enter;
        try
          if not FHasRequest then
            GMainIdle.SetEvent;
        finally
          FLock.Leave;
        end;
      end;
    end;
  finally
    tjDestroy(tj);
  end;
end;

{ ---- TThumbLoader ---- }

constructor TThumbLoader.Create;
begin
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FResults := TList.Create;
  FWant := 128;
  inherited Create(False);
end;

destructor TThumbLoader.Destroy;
var
  i: Integer;
begin
  Shutdown;
  WaitFor;
  for i := 0 to FResults.Count - 1 do
    TThumbResult(FResults[i]).Free;
  FResults.Free;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TThumbLoader.Shutdown;
begin
  Terminate;
  FWake.SetEvent;
end;

procedure TThumbLoader.SetFiles(const Files: array of string; Gen: Integer);
var
  i: Integer;
begin
  FLock.Enter;
  try
    FGen := Gen;
    SetLength(FFiles, Length(Files));
    SetLength(FDone, Length(Files));
    for i := 0 to High(Files) do
    begin
      FFiles[i] := Files[i];
      FDone[i] := 0;
    end;
    FFirst := 0;
    FLast := -1;
    for i := FResults.Count - 1 downto 0 do
      TThumbResult(FResults[i]).Free;
    FResults.Clear;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TThumbLoader.SetVisible(First, Last: Integer);
begin
  FLock.Enter;
  try
    FFirst := First;
    FLast := Last;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TThumbLoader.RemoveIndices(const Idx: array of Integer; NewGen: Integer);
var
  i, k, j: Integer;
  skip: Boolean;
begin
  FLock.Enter;
  try
    k := 0;
    j := 0;
    for i := 0 to High(FFiles) do
    begin
      skip := (j <= High(Idx)) and (Idx[j] = i);
      if skip then
      begin
        Inc(j);
        Continue;
      end;
      FFiles[k] := FFiles[i];
      FDone[k] := FDone[i];
      Inc(k);
    end;
    SetLength(FFiles, k);
    SetLength(FDone, k);
    FGen := NewGen;                 // results of the old numbering are dropped
    for i := FResults.Count - 1 downto 0 do
      TThumbResult(FResults[i]).Free;
    FResults.Clear;
    FFirst := 0;
    FLast := -1;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TThumbLoader.Redo(Index: Integer);
begin
  FLock.Enter;
  try
    if (Index >= 0) and (Index < Length(FDone)) then
      FDone[Index] := 0;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TThumbLoader.SetWantedSize(Size: Integer);
begin
  FLock.Enter;
  try
    FWant := Size;
  finally
    FLock.Leave;
  end;
  FWake.SetEvent;
end;

function TThumbLoader.PickJob(out Index, Size, Gen: Integer; out FileName: string): Boolean;
var
  n, i, k, f, l: Integer;

  function Todo(j: Integer): Boolean;
  begin
    Result := (j >= 0) and (j < n) and (FDone[j] <> -1) and (FDone[j] < FWant);
  end;

begin
  Result := False;
  FLock.Enter;
  try
    n := Length(FFiles);
    if n = 0 then
      Exit;
    f := EnsureRange(FFirst, 0, n - 1);
    l := EnsureRange(FLast, f, n - 1);
    Index := -1;
    for i := f to l do                 // visible thumbnails first, top to bottom
      if Todo(i) then
      begin
        Index := i;
        Break;
      end;
    if Index < 0 then
      for k := 1 to n do               // then outwards, preferring what is ahead
      begin
        if Todo(l + k) then begin Index := l + k; Break; end;
        if Todo(f - k) then begin Index := f - k; Break; end;
        if (l + k >= n) and (f - k < 0) then Break;
      end;
    if Index >= 0 then
    begin
      Size := FWant;
      Gen := FGen;
      FileName := FFiles[Index];
      Result := True;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TThumbLoader.Post(R: TThumbResult);
var
  doQueue: Boolean;
begin
  FLock.Enter;
  try
    if R.Gen <> FGen then
    begin
      R.Free;
      Exit;
    end;
    FResults.Add(R);
    doQueue := not FQueued;
    FQueued := True;
  finally
    FLock.Leave;
  end;
  if doQueue then
    Queue(@Drain);
end;

procedure TThumbLoader.Drain;
var
  batch: array of TThumbResult;
  i: Integer;
begin
  FLock.Enter;
  try
    SetLength(batch, FResults.Count);
    for i := 0 to FResults.Count - 1 do
      batch[i] := TThumbResult(FResults[i]);
    FResults.Clear;
    FQueued := False;
  finally
    FLock.Leave;
  end;
  for i := 0 to High(batch) do
    if Assigned(FOnThumb) and not Terminated then
      FOnThumb(Self, batch[i])      // handler takes ownership
    else
      batch[i].Free;
end;

procedure TThumbLoader.Execute;
var
  tj: tjhandle;
  idx, size, gen: Integer;
  fn: string;
  img: TLoadedImage;
  r: TThumbResult;
begin
  tj := tjInitDecompress();
  try
    while not Terminated do
    begin
      if not PickJob(idx, size, gen, fn) then
      begin
        FWake.WaitFor(INFINITE);
        Continue;
      end;
      // the central image has absolute priority
      while not Terminated and (GMainIdle.WaitFor(20) <> wrSignaled) do ;
      if Terminated then
        Break;
      img := TLoadedImage.Create;
      try
        try
          DecodeAny(tj, fn, size, size, True, img);
        except
          on E: Exception do
            img.Error := E.Message;
        end;
        r := TThumbResult.Create;
        r.Gen := gen;
        r.Index := idx;
        r.Size := size;
        r.Pixels := img.Pixels;
        img.Pixels := nil;
        FLock.Enter;
        try
          if gen = FGen then
            if r.Pixels = nil then FDone[idx] := -1 else FDone[idx] := size;
        finally
          FLock.Leave;
        end;
        Post(r);
      finally
        img.Free;
      end;
    end;
  finally
    tjDestroy(tj);
  end;
end;

initialization
  GMainIdle := TEvent.Create(nil, True, True, '');

finalization
  GMainIdle.Free;

end.
