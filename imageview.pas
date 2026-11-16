unit imageview;

{ Central image panel: fit / zoom (ctrl+wheel) / pan (drag); the plain wheel asks the
  owner to move to the next / previous image. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Controls, Graphics, ExtCtrls, LCLType,
  tjpeg, jpegworkers, bmputil;

type
  TNavigateEvent = procedure(Sender: TObject; Delta: Integer) of object;
  { The decoded bitmap is too coarse for the current zoom: a bigger decode is needed. }
  TNeedResolutionEvent = procedure(Sender: TObject; BoxW, BoxH: Integer) of object;

  { TImageView }

  TImageView = class(TCustomControl)
  private
    FPix: TPixelBuffer;             // decoded image (possibly DCT-scaled)
    FOrigW, FOrigH: Integer;
    FDenom: Integer;
    FRequestedDenom: Integer;
    FFit: Boolean;
    FZoom: Double;
    FOffX, FOffY: Double;
    FNewImage: Boolean;
    FMessage: string;
    FDragging: Boolean;
    FDragX, FDragY: Integer;
    FResTimer: TTimer;
    FQuarterTurns: Integer;
    FWheelZoom: Boolean;
    FHover: Boolean;                // pointer inside the view
    FArrowHot: Integer;             // -1/1: pointer over the left/right arrow, 0: none
    FOnToggleFullscreen: TNotifyEvent;
    FOnEscape: TNotifyEvent;
    FOnNavigate: TNavigateEvent;
    FOnZoomChanged: TNotifyEvent;
    FOnNeedResolution: TNeedResolutionEvent;
    function ArrowAt(X, Y: Integer): Integer;
    function ArrowRect(Dir: Integer): TRect;
    procedure DrawArrows;
    function FitZoom: Double;
    function EffectiveZoom: Double;
    procedure Layout(out Z, X, Y: Double);
    procedure ClampOffset;
    procedure ZoomAt(NewZoom: Double; Px, Py: Double);
    procedure ScheduleResolutionCheck;
    procedure ResTimer(Sender: TObject);
    procedure NotifyZoom;
    procedure SetWheelZoom(Value: Boolean);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    { A new image is about to be loaded: the next SetImage resets the zoom to "fit". }
    procedure BeginLoad;
    procedure SetImage(Img: TLoadedImage);
    procedure ShowMessage(const Msg: string);
    procedure Clear;
    procedure SetZoomCentered(Z: Double);
    function ZoomPercent: Integer;
    { View-only rotation (formats that have no lossless metadata rotation). }
    procedure RotateView(Clockwise: Boolean);
    property QuarterTurns: Integer read FQuarterTurns;
    { True: the wheel zooms (ctrl+wheel navigates) and arrows at the edges navigate. }
    property WheelZoom: Boolean read FWheelZoom write SetWheelZoom;
    property OnToggleFullscreen: TNotifyEvent read FOnToggleFullscreen write FOnToggleFullscreen;
    property OnEscape: TNotifyEvent read FOnEscape write FOnEscape;
    property OnNavigate: TNavigateEvent read FOnNavigate write FOnNavigate;
    property OnZoomChanged: TNotifyEvent read FOnZoomChanged write FOnZoomChanged;
    property OnNeedResolution: TNeedResolutionEvent read FOnNeedResolution write FOnNeedResolution;
  end;

implementation

const
  ZoomMin = 0.05;
  ZoomMax = 32.0;

constructor TImageView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  Color := $202020;
  FFit := True;
  FDenom := 1;
  FResTimer := TTimer.Create(Self);
  FResTimer.Enabled := False;
  FResTimer.Interval := 150;
  FResTimer.OnTimer := @ResTimer;
end;

destructor TImageView.Destroy;
begin
  FPix.Free;
  inherited Destroy;
end;

function TImageView.FitZoom: Double;
begin
  if (FOrigW <= 0) or (FOrigH <= 0) or (ClientWidth <= 0) or (ClientHeight <= 0) then
    Exit(1);
  Result := Min(1.0, Min(ClientWidth / FOrigW, ClientHeight / FOrigH));
end;

function TImageView.EffectiveZoom: Double;
begin
  if FFit then Result := FitZoom else Result := FZoom;
end;

procedure TImageView.ClampOffset;
var
  w, h: Double;
begin
  w := FOrigW * FZoom;
  h := FOrigH * FZoom;
  if w <= ClientWidth then FOffX := (ClientWidth - w) / 2
  else FOffX := EnsureRange(FOffX, ClientWidth - w, 0);
  if h <= ClientHeight then FOffY := (ClientHeight - h) / 2
  else FOffY := EnsureRange(FOffY, ClientHeight - h, 0);
end;

procedure TImageView.Layout(out Z, X, Y: Double);
begin
  if FFit then
  begin
    Z := FitZoom;
    FZoom := Z;
    FOffX := 0;
    FOffY := 0;
  end
  else
    Z := FZoom;
  ClampOffset;
  X := FOffX;
  Y := FOffY;
end;

procedure TImageView.NotifyZoom;
begin
  if Assigned(FOnZoomChanged) then
    FOnZoomChanged(Self);
end;

function TImageView.ZoomPercent: Integer;
begin
  Result := Round(EffectiveZoom * 100);
end;

procedure TImageView.ZoomAt(NewZoom: Double; Px, Py: Double);
var
  z0, x0, y0, ix, iy: Double;
begin
  if FPix = nil then
    Exit;
  Layout(z0, x0, y0);
  NewZoom := EnsureRange(NewZoom, ZoomMin, ZoomMax);
  ix := (Px - x0) / z0;
  iy := (Py - y0) / z0;
  if NewZoom <= FitZoom + 1e-6 then
    FFit := True
  else
  begin
    FFit := False;
    FZoom := NewZoom;
    FOffX := Px - ix * NewZoom;
    FOffY := Py - iy * NewZoom;
    ClampOffset;
  end;
  Invalidate;
  NotifyZoom;
  ScheduleResolutionCheck;
end;

procedure TImageView.SetZoomCentered(Z: Double);
begin
  ZoomAt(Z, ClientWidth / 2, ClientHeight / 2);
end;

procedure TImageView.ScheduleResolutionCheck;
begin
  FResTimer.Enabled := False;
  FResTimer.Enabled := True;
end;

procedure TImageView.ResTimer(Sender: TObject);
var
  z: Double;
  need: Integer;
begin
  FResTimer.Enabled := False;
  if (FPix = nil) or (FOrigW <= 0) then
    Exit;
  z := EffectiveZoom;
  need := TurboJpegDenom(z);
  // ask only when the current decode is too coarse and we did not already ask
  if (need < FDenom) and (need < FRequestedDenom) and Assigned(FOnNeedResolution) then
  begin
    FRequestedDenom := need;
    FOnNeedResolution(Self, Round(FOrigW * z), Round(FOrigH * z));
  end;
end;

procedure TImageView.BeginLoad;
begin
  FNewImage := True;
  FQuarterTurns := 0;
  FMessage := '';
end;

procedure TImageView.SetImage(Img: TLoadedImage);
var
  i, n: Integer;
begin
  if Img.Pixels = nil then
    Exit;
  FPix.Free;
  FPix := Img.Pixels;               // take ownership
  Img.Pixels := nil;
  FOrigW := Img.OrigW;
  FOrigH := Img.OrigH;
  for i := 1 to FQuarterTurns do
  begin
    FPix := RotatePixels(FPix, True);
    n := FOrigW; FOrigW := FOrigH; FOrigH := n;
  end;
  FDenom := Img.Denom;
  FRequestedDenom := Img.Denom;
  FMessage := '';
  if FNewImage then
  begin
    FFit := True;
    FNewImage := False;
  end;
  Invalidate;
  NotifyZoom;
  ScheduleResolutionCheck;
end;

procedure TImageView.RotateView(Clockwise: Boolean);
var
  n: Integer;
begin
  if FPix = nil then
    Exit;
  FPix := RotatePixels(FPix, Clockwise);
  n := FOrigW; FOrigW := FOrigH; FOrigH := n;
  if Clockwise then FQuarterTurns := (FQuarterTurns + 1) mod 4
  else FQuarterTurns := (FQuarterTurns + 3) mod 4;
  FFit := True;
  Invalidate;
  NotifyZoom;
  ScheduleResolutionCheck;
end;

procedure TImageView.ShowMessage(const Msg: string);
begin
  FPix.Free;
  FPix := nil;
  FOrigW := 0;
  FOrigH := 0;
  FMessage := Msg;
  FNewImage := False;
  Invalidate;
end;

procedure TImageView.Clear;
begin
  ShowMessage('');
end;

procedure TImageView.Resize;
begin
  inherited Resize;
  if FPix <> nil then
  begin
    Invalidate;
    NotifyZoom;
    ScheduleResolutionCheck;
  end;
end;

const
  ArrowW = 36;
  ArrowH = 64;
  ArrowMargin = 8;

procedure TImageView.SetWheelZoom(Value: Boolean);
begin
  if FWheelZoom = Value then
    Exit;
  FWheelZoom := Value;
  FArrowHot := 0;
  Invalidate;
end;

function TImageView.ArrowRect(Dir: Integer): TRect;
var
  t: Integer;
begin
  t := (ClientHeight - ArrowH) div 2;
  if Dir < 0 then
    Result := Rect(ArrowMargin, t, ArrowMargin + ArrowW, t + ArrowH)
  else
    Result := Rect(ClientWidth - ArrowMargin - ArrowW, t, ClientWidth - ArrowMargin, t + ArrowH);
end;

function TImageView.ArrowAt(X, Y: Integer): Integer;
begin
  Result := 0;
  if not FWheelZoom or (FPix = nil) then
    Exit;
  if PtInRect(ArrowRect(-1), Point(X, Y)) then
    Result := -1
  else if PtInRect(ArrowRect(1), Point(X, Y)) then
    Result := 1;
end;

procedure TImageView.DrawArrows;
var
  dir: Integer;
  r: TRect;
  cx, cy: Integer;
begin
  for dir := -1 to 1 do
  begin
    if dir = 0 then Continue;
    r := ArrowRect(dir);
    if FArrowHot = dir then
      Canvas.Brush.Color := $707070
    else
      Canvas.Brush.Color := $383838;
    Canvas.Pen.Color := $A0A0A0;
    Canvas.RoundRect(r, 10, 10);
    Canvas.Brush.Color := $F0F0F0;
    Canvas.Pen.Color := $F0F0F0;
    cx := (r.Left + r.Right) div 2;
    cy := (r.Top + r.Bottom) div 2;
    Canvas.Polygon([Point(cx - dir * 7, cy - 12), Point(cx + dir * 7, cy), Point(cx - dir * 7, cy + 12)]);
  end;
end;

procedure TImageView.MouseEnter;
begin
  inherited MouseEnter;
  FHover := True;
  if FWheelZoom then
    Invalidate;
end;

procedure TImageView.MouseLeave;
begin
  inherited MouseLeave;
  FHover := False;
  FArrowHot := 0;
  if FWheelZoom then
    Invalidate;
end;

procedure TImageView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then
    SetFocus;
  if (Button = mbLeft) and (ArrowAt(X, Y) <> 0) then
  begin
    if Assigned(FOnNavigate) then
      FOnNavigate(Self, ArrowAt(X, Y));
    Exit;
  end;
  if (Button = mbLeft) and (FPix <> nil) then
  begin
    FDragging := True;
    FDragX := X;
    FDragY := Y;
    if not FFit then
      Cursor := crSizeAll;
  end;
end;

procedure TImageView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  k: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if FWheelZoom then
  begin
    FHover := True;
    k := ArrowAt(X, Y);
    if k <> FArrowHot then
    begin
      FArrowHot := k;
      if k <> 0 then Cursor := crHandPoint else Cursor := crDefault;
      Invalidate;
    end;
  end;
  if FDragging and not FFit then
  begin
    FOffX += X - FDragX;
    FOffY += Y - FDragY;
    FDragX := X;
    FDragY := Y;
    ClampOffset;
    Invalidate;
  end;
end;

procedure TImageView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
  if FArrowHot = 0 then
    Cursor := crDefault;
end;

procedure TImageView.DblClick;
begin
  inherited DblClick;
  if (FPix <> nil) and (FArrowHot = 0) and Assigned(FOnToggleFullscreen) then
    FOnToggleFullscreen(Self);
end;

procedure TImageView.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if (Key = VK_ESCAPE) and Assigned(FOnEscape) then
  begin
    Key := 0;
    FOnEscape(Self);
    Exit;
  end;
  if (Key = VK_0) or (Key = VK_NUMPAD0) then begin ZoomAt(0, ClientWidth / 2, ClientHeight / 2); Key := 0; Exit; end;
  if (Key = VK_1) or (Key = VK_NUMPAD1) then begin SetZoomCentered(1.0); Key := 0; Exit; end;
  if not Assigned(FOnNavigate) then
    Exit;
  case Key of
    VK_LEFT, VK_UP, VK_PRIOR: FOnNavigate(Self, -1);
    VK_RIGHT, VK_DOWN, VK_NEXT: FOnNavigate(Self, 1);
    VK_HOME: FOnNavigate(Self, -MaxInt);
    VK_END: FOnNavigate(Self, MaxInt);
  else
    Exit;
  end;
  Key := 0;
end;

function TImageView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  Result := True;
  if (ssCtrl in Shift) <> FWheelZoom then
    ZoomAt(EffectiveZoom * Power(1.2, Sign(WheelDelta)), MousePos.X, MousePos.Y)
  else if Assigned(FOnNavigate) then
    FOnNavigate(Self, -Sign(WheelDelta));
end;

{ Software resampler: bilinear when shrinking or zooming moderately, nearest beyond 2x. }
procedure TImageView.Paint;
var
  z, x, y, k, sx, sy: Double;
  x0, x1, y0, y1, dx, dy, sw, sh, ix, iy, ix1, fx, fy: Integer;
  colX, colFx: array of Integer;
  smooth: Boolean;
  frame: TPixelBuffer;
  bmp: TBitmap;
  d, r0, r1: PByte;
  w00, w10, w01, w11: Integer;
  bg: Cardinal;
  n, tw, th: Integer;
begin
  if FPix = nil then
  begin
    Canvas.Brush.Color := Color;
    Canvas.FillRect(ClientRect);
    if FMessage <> '' then
    begin
      Canvas.Font.Color := $A0A0A0;
      Canvas.Brush.Style := bsClear;
      tw := Canvas.TextWidth(FMessage);
      th := Canvas.TextHeight(FMessage);
      Canvas.TextOut((ClientWidth - tw) div 2, (ClientHeight - th) div 2, FMessage);
    end;
    Exit;
  end;
  Layout(z, x, y);
  frame := TPixelBuffer.Create(ClientWidth, ClientHeight);
  try
    bg := Cardinal(ColorToRGB(Color));
    bg := $FF000000 or ((bg and $FF) shl 16) or (bg and $FF00) or ((bg shr 16) and $FF);
    FillDWord(frame.Data^, ClientWidth * ClientHeight, bg);
    x0 := Max(0, Floor(x));
    y0 := Max(0, Floor(y));
    x1 := Min(ClientWidth, Ceil(x + FOrigW * z));
    y1 := Min(ClientHeight, Ceil(y + FOrigH * z));
    sw := FPix.Width;
    sh := FPix.Height;
    k := sw / FOrigW;                 // pixels of the decoded bitmap per original pixel
    smooth := z < 2;
    if (x1 > x0) and (y1 > y0) then
    begin
      SetLength(colX, x1 - x0);
      SetLength(colFx, x1 - x0);
      for dx := x0 to x1 - 1 do
      begin
        sx := ((dx + 0.5 - x) / z) * k - 0.5;
        if not smooth then sx := Floor(sx + 0.5);
        ix := Floor(sx);
        colFx[dx - x0] := Round((sx - ix) * 256);
        colX[dx - x0] := EnsureRange(ix, -1, sw - 1);
      end;
      for dy := y0 to y1 - 1 do
      begin
        sy := ((dy + 0.5 - y) / z) * k - 0.5;
        if not smooth then sy := Floor(sy + 0.5);
        iy := Floor(sy);
        fy := Round((sy - iy) * 256);
        r0 := FPix.Data + Int64(EnsureRange(iy, 0, sh - 1)) * sw * 4;
        r1 := FPix.Data + Int64(EnsureRange(iy + 1, 0, sh - 1)) * sw * 4;
        d := frame.Data + (Int64(dy) * ClientWidth + x0) * 4;
        for dx := 0 to x1 - x0 - 1 do
        begin
          ix := Max(colX[dx], 0);
          ix1 := Min(colX[dx] + 1, sw - 1);
          fx := colFx[dx];
          w11 := fx * fy;
          w01 := (256 - fx) * fy;
          w10 := fx * (256 - fy);
          w00 := (256 - fx) * (256 - fy);
          for n := 0 to 2 do
            d[n] := (r0[ix * 4 + n] * w00 + r0[ix1 * 4 + n] * w10 +
                     r1[ix * 4 + n] * w01 + r1[ix1 * 4 + n] * w11 + 32768) shr 16;
          d[3] := 255;
          Inc(d, 4);
        end;
      end;
    end;
    bmp := BitmapFromPixels(frame);
    try
      Canvas.Draw(0, 0, bmp);
    finally
      bmp.Free;
    end;
    if FWheelZoom and FHover then
      DrawArrows;
  finally
    frame.Free;
  end;
end;

end.
