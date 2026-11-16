unit printpreview;

{ Print preview: the selected photos on a page that can be portrait / landscape; every
  photo and text box can be moved and resized with the mouse. Text boxes may carry
  free text and the metadata of a photo. Positions are in millimetres. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, contnrs, Forms, Controls, Graphics, Dialogs, StdCtrls,
  ExtCtrls, CheckLst, LCLType, Printers, PrintersDlgs, jpegworkers, exifreader, bmputil, formutil, tjpeg, IntfGraphics, FPImage;

type
  TItemKind = (ikPhoto, ikText);

  TPrintItem = class
  public
    Kind: TItemKind;
    X, Y, W, H: Double;             // mm, page coordinates
    // photo
    FileName: string;
    Pix: TPixelBuffer;              // preview resolution
    Aspect: Double;
    Meta: TExifData;
    Cache: TBitmap;
    // text
    Text: string;
    FontPt: Integer;
    Source: TPrintItem;             // photo whose metadata the text may use
    destructor Destroy; override;
  end;

  TPt = record
    X, Y: Double;
  end;

  { TPageView }

  TPageView = class(TCustomControl)
  private
    FItems: TObjectList;
    FPageW, FPageH: Double;
    FScale, FOx, FOy: Double;
    FSel: TPrintItem;
    FMode: Integer;                 // 0 none, 1 move, 2 resize
    FGrabX, FGrabY: Double;
    FFixX, FFixY: Double;           // opposite corner while resizing
    FOnSelect: TNotifyEvent;
    FOnEditText: TNotifyEvent;
    procedure UpdateScale;
    function ItemRect(It: TPrintItem): TRect;
    function ToMm(X, Y: Integer): TPt;
    function HandleAt(It: TPrintItem; X, Y: Integer): Integer;
    function ItemAt(X, Y: Integer): TPrintItem;
    procedure SetSel(It: TPrintItem);
    procedure Clamp(It: TPrintItem);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure DblClick; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetPage(W, H: Double);
    procedure AddItem(It: TPrintItem);
    procedure DeleteSelected;
    procedure AutoLayout;
    property Items: TObjectList read FItems;
    property Selected: TPrintItem read FSel write SetSel;
    property PageW: Double read FPageW;
    property PageH: Double read FPageH;
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
    property OnEditText: TNotifyEvent read FOnEditText write FOnEditText;
  end;

  { TPrintPreviewForm }

  TPrintPreviewForm = class(TForm)
  private
    FView: TPageView;
    FOrient, FFont: TComboBox;
    FPaperIdx: Integer;
    FBtnEdit, FBtnDel: TButton;
    FUpdating: Boolean;
    procedure PageChanged(Sender: TObject);
    procedure SelectionChanged(Sender: TObject);
    procedure FontSizeChanged(Sender: TObject);
    procedure AddTextClick(Sender: TObject);
    procedure EditTextClick(Sender: TObject);
    procedure DeleteClick(Sender: TObject);
    procedure LayoutClick(Sender: TObject);
    procedure PrintClick(Sender: TObject);
    procedure PdfClick(Sender: TObject);
    function AskPdfPage: Boolean;
    procedure CloseClick(Sender: TObject);
    procedure FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditItem(It: TPrintItem);
    procedure ApplyPage;
  public
    constructor CreateWith(AOwner: TComponent; Files: TStrings);
    { Draws the page on any canvas (printer or bitmap); Dpi in pixels per inch. }
    procedure RenderTo(ACanvas: TCanvas; XDpi, YDpi, OffX, OffY: Integer);
    property View: TPageView read FView;
  end;

implementation

const
  Margin = 10.0;        // mm
  Gap = 4.0;
  HandlePx = 7;
  PreviewMax = 1100;
  PrintDpiMax = 300;

type
  TPaper = record
    Name: string;
    W, H: Double;
  end;

const
  Papers: array[0..9] of TPaper = (
    (Name: 'A4'; W: 210; H: 297),
    (Name: 'A3'; W: 297; H: 420),
    (Name: 'A2'; W: 420; H: 594),
    (Name: 'A5'; W: 148; H: 210),
    (Name: 'A6'; W: 105; H: 148),
    (Name: 'B5'; W: 176; H: 250),
    (Name: 'Letter'; W: 215.9; H: 279.4),
    (Name: 'Legal'; W: 215.9; H: 355.6),
    (Name: '10 x 15 cm'; W: 100; H: 150),
    (Name: '13 x 18 cm'; W: 130; H: 180));
  FontSizes: array[0..8] of Integer = (8, 10, 12, 14, 18, 24, 36, 48, 72);

destructor TPrintItem.Destroy;
begin
  Pix.Free;
  Cache.Free;
  inherited Destroy;
end;

{ ---------------- text dialog ---------------- }

type
  TTextDialog = class(TForm)
  private
    Memo: TMemo;
    List: TCheckListBox;
    ChkNames: TCheckBox;
    Meta: TExifData;
    procedure InsertClick(Sender: TObject);
  public
    constructor CreateDlg(AOwner: TComponent; const ATitle, AText: string; const AMeta: TExifData);
  end;

constructor TTextDialog.CreateDlg(AOwner: TComponent; const ATitle, AText: string; const AMeta: TExifData);
var
  lbl: TLabel;
  pnl: TPanel;
  b: TButton;
  i: Integer;
begin
  inherited CreateNew(AOwner);
  if AOwner is TCustomForm then
  begin
    PopupMode := pmExplicit;
    PopupParent := TCustomForm(AOwner);
    ShowInTaskBar := stNever;
  end;
  Meta := AMeta;
  Caption := ATitle;
  Width := 520;
  Height := 540;
  Position := poOwnerFormCenter;

  pnl := TPanel.Create(Self);
  pnl.Parent := Self;
  pnl.Align := alBottom;
  pnl.Height := 46;
  pnl.BevelOuter := bvNone;
  b := TButton.Create(Self);
  b.Parent := pnl;
  b.Caption := 'Cancel';
  b.ModalResult := mrCancel;
  b.Align := alRight;
  b.Width := 100;
  b.BorderSpacing.Around := 8;
  b := TButton.Create(Self);
  b.Parent := pnl;
  b.Caption := 'OK';
  b.Default := True;
  b.ModalResult := mrOk;
  b.Align := alRight;
  b.Width := 100;
  b.BorderSpacing.Around := 8;

  Memo := TMemo.Create(Self);
  Memo.Parent := Self;
  Memo.Align := alTop;
  Memo.Height := 170;
  Memo.ScrollBars := ssAutoVertical;
  Memo.Text := AText;
  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.Align := alTop;
  lbl.Caption := ' Text';
  lbl.Top := 0;

  if Length(Meta.Names) > 0 then
  begin
    b := TButton.Create(Self);
    b.Parent := pnl;
    b.Caption := 'Insert checked';
    b.SetBounds(8, 9, 130, 28);
    b.OnClick := @InsertClick;
    ChkNames := TCheckBox.Create(Self);
    ChkNames.Parent := pnl;
    ChkNames.Caption := 'with field names';
    ChkNames.Checked := True;
    ChkNames.SetBounds(150, 12, 140, 24);
    List := TCheckListBox.Create(Self);
    List.Parent := Self;
    List.Align := alClient;
    for i := 0 to High(Meta.Names) do
      List.Items.Add(Meta.Names[i] + ':  ' + Meta.Values[i]);
    lbl := TLabel.Create(Self);
    lbl.Parent := Self;
    lbl.Align := alTop;
    lbl.Caption := ' Metadata of the photo: check the fields to add';
    lbl.Top := Memo.Height + 1;
  end;
end;

procedure TTextDialog.InsertClick(Sender: TObject);
var
  k: Integer;
begin
  for k := 0 to List.Count - 1 do
    if List.Checked[k] then
    begin
      if ChkNames.Checked then
        Memo.Lines.Add(Meta.Names[k] + ': ' + Meta.Values[k])
      else
        Memo.Lines.Add(Meta.Values[k]);
      List.Checked[k] := False;
    end;
end;

{ ---------------- TPageView ---------------- }

constructor TPageView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  FItems := TObjectList.Create(True);
  FPageW := 210;
  FPageH := 297;
end;

destructor TPageView.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

procedure TPageView.UpdateScale;
begin
  FScale := Max(0.05, Min((ClientWidth - 32) / FPageW, (ClientHeight - 32) / FPageH));
  FOx := (ClientWidth - FPageW * FScale) / 2;
  FOy := (ClientHeight - FPageH * FScale) / 2;
end;

function TPageView.ItemRect(It: TPrintItem): TRect;
begin
  Result := Rect(Round(FOx + It.X * FScale), Round(FOy + It.Y * FScale),
    Round(FOx + (It.X + It.W) * FScale), Round(FOy + (It.Y + It.H) * FScale));
end;

function TPageView.ToMm(X, Y: Integer): TPt;
begin
  Result.X := (X - FOx) / FScale;
  Result.Y := (Y - FOy) / FScale;
end;

function TPageView.HandleAt(It: TPrintItem; X, Y: Integer): Integer;
var
  r: TRect;

  function Near(cx, cy: Integer): Boolean;
  begin
    Result := (Abs(X - cx) <= HandlePx) and (Abs(Y - cy) <= HandlePx);
  end;

begin
  Result := 0;
  if It = nil then
    Exit;
  r := ItemRect(It);
  if Near(r.Left, r.Top) then Result := 1
  else if Near(r.Right, r.Top) then Result := 2
  else if Near(r.Left, r.Bottom) then Result := 3
  else if Near(r.Right, r.Bottom) then Result := 4;
end;

function TPageView.ItemAt(X, Y: Integer): TPrintItem;
var
  i: Integer;
  r: TRect;
begin
  Result := nil;
  for i := FItems.Count - 1 downto 0 do
  begin
    r := ItemRect(TPrintItem(FItems[i]));
    if PtInRect(r, Point(X, Y)) then
      Exit(TPrintItem(FItems[i]));
  end;
end;

procedure TPageView.SetSel(It: TPrintItem);
begin
  FSel := It;
  Invalidate;
  if Assigned(FOnSelect) then
    FOnSelect(Self);
end;

procedure TPageView.Clamp(It: TPrintItem);
begin
  It.W := Min(It.W, FPageW);
  It.H := Min(It.H, FPageH);
  It.X := EnsureRange(It.X, 0, FPageW - It.W);
  It.Y := EnsureRange(It.Y, 0, FPageH - It.H);
end;

procedure TPageView.SetPage(W, H: Double);
var
  i: Integer;
  it: TPrintItem;
  sx, sy, s: Double;
begin
  sx := W / FPageW;
  sy := H / FPageH;
  s := Min(sx, sy);
  FPageW := W;
  FPageH := H;
  for i := 0 to FItems.Count - 1 do
  begin
    it := TPrintItem(FItems[i]);
    it.X := it.X * sx;
    it.Y := it.Y * sy;
    it.W := it.W * s;
    it.H := it.H * s;
    Clamp(it);
  end;
  Invalidate;
end;

procedure TPageView.AddItem(It: TPrintItem);
begin
  FItems.Add(It);
  Clamp(It);
  Invalidate;
end;

procedure TPageView.DeleteSelected;
begin
  if FSel = nil then
    Exit;
  FItems.Remove(FSel);              // owned: freed
  SetSel(nil);
end;

{ Photos in a grid; the number of columns that wastes the least space wins. }
procedure TPageView.AutoLayout;
var
  photos: TList;
  i, n, cols, rows, bestCols, c, r: Integer;
  availW, availH, cellW, cellH, score, best, w, h: Double;
  it: TPrintItem;
begin
  photos := TList.Create;
  try
    for i := 0 to FItems.Count - 1 do
      if TPrintItem(FItems[i]).Kind = ikPhoto then
        photos.Add(FItems[i]);
    n := photos.Count;
    if n = 0 then
      Exit;
    availW := FPageW - 2 * Margin;
    availH := FPageH - 2 * Margin;
    best := -1;
    bestCols := 1;
    for cols := 1 to n do
    begin
      rows := (n + cols - 1) div cols;
      cellW := (availW - (cols - 1) * Gap) / cols;
      cellH := (availH - (rows - 1) * Gap) / rows;
      score := 0;
      for i := 0 to n - 1 do
      begin
        w := Min(cellW, cellH * TPrintItem(photos[i]).Aspect);
        score += w * w / TPrintItem(photos[i]).Aspect;
      end;
      if score > best then
      begin
        best := score;
        bestCols := cols;
      end;
    end;
    cols := bestCols;
    rows := (n + cols - 1) div cols;
    cellW := (availW - (cols - 1) * Gap) / cols;
    cellH := (availH - (rows - 1) * Gap) / rows;
    for i := 0 to n - 1 do
    begin
      it := TPrintItem(photos[i]);
      c := i mod cols;
      r := i div cols;
      w := Min(cellW, cellH * it.Aspect);
      h := w / it.Aspect;
      it.W := w;
      it.H := h;
      it.X := Margin + c * (cellW + Gap) + (cellW - w) / 2;
      it.Y := Margin + r * (cellH + Gap) + (cellH - h) / 2;
    end;
  finally
    photos.Free;
  end;
  Invalidate;
end;

procedure TPageView.Resize;
begin
  inherited Resize;
  Invalidate;
end;

procedure TPageView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  h: Integer;
  p: TPt;
  it: TPrintItem;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then
    SetFocus;
  if Button <> mbLeft then
    Exit;
  UpdateScale;
  p := ToMm(X, Y);
  FMode := 0;
  h := HandleAt(FSel, X, Y);
  if h > 0 then
  begin
    FMode := 2;
    case h of
      1: begin FFixX := FSel.X + FSel.W; FFixY := FSel.Y + FSel.H; end;
      2: begin FFixX := FSel.X; FFixY := FSel.Y + FSel.H; end;
      3: begin FFixX := FSel.X + FSel.W; FFixY := FSel.Y; end;
    else
      begin FFixX := FSel.X; FFixY := FSel.Y; end;
    end;
    Exit;
  end;
  it := ItemAt(X, Y);
  SetSel(it);
  if it <> nil then
  begin
    FMode := 1;
    FGrabX := p.X - it.X;
    FGrabY := p.Y - it.Y;
    // bring to front
    FItems.Move(FItems.IndexOf(it), FItems.Count - 1);
  end;
end;

procedure TPageView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  p: TPt;
  w, h, availW, availH: Double;
begin
  inherited MouseMove(Shift, X, Y);
  UpdateScale;
  p := ToMm(X, Y);
  if (FMode = 1) and (FSel <> nil) then
  begin
    FSel.X := p.X - FGrabX;
    FSel.Y := p.Y - FGrabY;
    Clamp(FSel);
    Invalidate;
  end
  else if (FMode = 2) and (FSel <> nil) then
  begin
    if p.X >= FFixX then availW := FPageW - FFixX else availW := FFixX;
    if p.Y >= FFixY then availH := FPageH - FFixY else availH := FFixY;
    if FSel.Kind = ikPhoto then
    begin
      w := Min(Max(8, Abs(p.X - FFixX)), Min(availW, availH * FSel.Aspect));
      h := w / FSel.Aspect;
    end
    else
    begin
      w := Min(Max(8, Abs(p.X - FFixX)), availW);
      h := Min(Max(5, Abs(p.Y - FFixY)), availH);
    end;
    FSel.W := w;
    FSel.H := h;
    if p.X >= FFixX then FSel.X := FFixX else FSel.X := FFixX - w;
    if p.Y >= FFixY then FSel.Y := FFixY else FSel.Y := FFixY - h;
    Invalidate;
  end
  else
  begin
    case HandleAt(FSel, X, Y) of
      1, 4: Cursor := crSizeNWSE;
      2, 3: Cursor := crSizeNESW;
    else
      if ItemAt(X, Y) <> nil then Cursor := crSizeAll else Cursor := crDefault;
    end;
  end;
end;

procedure TPageView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FMode := 0;
end;

procedure TPageView.DblClick;
begin
  inherited DblClick;
  if (FSel <> nil) and (FSel.Kind = ikText) and Assigned(FOnEditText) then
    FOnEditText(Self);
end;

procedure TPageView.Paint;
var
  i: Integer;
  it: TPrintItem;
  r, pr: TRect;
  pw, ph: Integer;
  ts: TTextStyle;
  pxW, pxH: Integer;
  px: TPixelBuffer;

  procedure Handle(cx, cy: Integer);
  begin
    Canvas.Pen.Style := psSolid;
    Canvas.Pen.Color := $E08A2D;
    Canvas.Brush.Style := bsSolid;
    Canvas.Brush.Color := clWhite;
    Canvas.Rectangle(cx - 4, cy - 4, cx + 5, cy + 5);
  end;

begin
  UpdateScale;
  Canvas.Brush.Color := $484848;
  Canvas.FillRect(ClientRect);
  pr := Rect(Round(FOx), Round(FOy), Round(FOx + FPageW * FScale), Round(FOy + FPageH * FScale));
  Canvas.Brush.Color := $2A2A2A;
  Canvas.FillRect(pr.Left + 4, pr.Top + 4, pr.Right + 4, pr.Bottom + 4);
  Canvas.Brush.Color := clWhite;
  Canvas.FillRect(pr);
  for i := 0 to FItems.Count - 1 do
  begin
    it := TPrintItem(FItems[i]);
    r := ItemRect(it);
    pw := r.Right - r.Left;
    ph := r.Bottom - r.Top;
    if it.Kind = ikPhoto then
    begin
      if (it.Cache = nil) or (it.Cache.Width <> pw) or (it.Cache.Height <> ph) then
      begin
        it.Cache.Free;
        it.Cache := nil;
        if (pw > 0) and (ph > 0) then
        begin
          pxW := pw; pxH := ph;
          px := ScalePixels(it.Pix, pxW, pxH);
          try
            it.Cache := BitmapFromPixels(px);
          finally
            px.Free;
          end;
        end;
      end;
      if it.Cache <> nil then
        Canvas.Draw(r.Left, r.Top, it.Cache);
    end
    else
    begin
      Canvas.Font.Color := clBlack;
      Canvas.Font.Height := -Max(1, Round(it.FontPt * 25.4 / 72 * FScale));
      Canvas.Brush.Style := bsClear;
      ts := Canvas.TextStyle;
      ts.Wordbreak := True;
      ts.SingleLine := False;
      ts.Clipping := True;
      ts.Opaque := False;
      Canvas.TextRect(r, r.Left + 2, r.Top + 1, it.Text, ts);
      Canvas.Brush.Style := bsSolid;
    end;
    if it = FSel then
    begin
      Canvas.Brush.Style := bsClear;
      Canvas.Pen.Color := $E08A2D;
      Canvas.Pen.Style := psDash;
      Canvas.Rectangle(r);
      Handle(r.Left, r.Top);
      Handle(r.Right, r.Top);
      Handle(r.Left, r.Bottom);
      Handle(r.Right, r.Bottom);
    end;
  end;
end;

{ ---------------- TPrintPreviewForm ---------------- }

constructor TPrintPreviewForm.CreateWith(AOwner: TComponent; Files: TStrings);
var
  pnl: TPanel;
  x, i, landscape, portrait: Integer;
  img: TLoadedImage;
  it: TPrintItem;
  sr: TSearchRec;
  failed: string;

  function AddCtl(C: TControl; W: Integer): TControl;
  begin
    C.Parent := pnl;
    C.SetBounds(x, 8, W, 28);
    Inc(x, W + 8);
    Result := C;
  end;

  function MakeLabel(const S: string; W: Integer): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Caption := S;
    Result.Layout := tlCenter;
    AddCtl(Result, W);
  end;

  function MakeButton(const S: string; W: Integer; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Caption := S;
    Result.OnClick := AClick;
    AddCtl(Result, W);
  end;

begin
  inherited CreateNew(AOwner);
  if AOwner is TCustomForm then
  begin
    PopupMode := pmExplicit;
    PopupParent := TCustomForm(AOwner);
    ShowInTaskBar := stNever;
  end;
  Caption := 'Print preview';
  Width := 1120;
  Height := 820;
  Position := poOwnerFormCenter;
  KeyPreview := True;
  OnKeyDown := @FormKey;

  pnl := TPanel.Create(Self);
  pnl.Parent := Self;
  pnl.Align := alTop;
  pnl.Height := 44;
  pnl.BevelOuter := bvNone;
  x := 8;
  MakeLabel('Orientation', 66);
  FOrient := TComboBox.Create(Self);
  FOrient.Style := csDropDownList;
  FOrient.Items.Add('Portrait');
  FOrient.Items.Add('Landscape');
  FOrient.ItemIndex := 0;
  FOrient.OnChange := @PageChanged;
  AddCtl(FOrient, 110);
  MakeButton('Auto layout', 100, @LayoutClick);
  Inc(x, 14);
  MakeButton('Add text...', 100, @AddTextClick);
  FBtnEdit := MakeButton('Edit text...', 100, @EditTextClick);
  MakeLabel('Font size', 56);
  FFont := TComboBox.Create(Self);
  FFont.Style := csDropDownList;
  for i := 0 to High(FontSizes) do
    FFont.Items.Add(IntToStr(FontSizes[i]));
  FFont.ItemIndex := 2;
  FFont.OnChange := @FontSizeChanged;
  AddCtl(FFont, 70);
  FBtnDel := MakeButton('Remove', 80, @DeleteClick);
  Inc(x, 14);
  MakeButton('Print...', 90, @PrintClick);
  MakeButton('Save as PDF...', 110, @PdfClick);
  MakeButton('Close', 80, @CloseClick);

  FView := TPageView.Create(Self);
  FView.Parent := Self;
  FView.Align := alClient;
  FView.OnSelect := @SelectionChanged;
  FView.OnEditText := @EditTextClick;

  Screen.Cursor := crHourGlass;
  try
    failed := '';
    landscape := 0;
    portrait := 0;
    for i := 0 to Files.Count - 1 do
    begin
      img := DecodeFile(Files[i], PreviewMax, PreviewMax, False);
      if img.Pixels = nil then
      begin
        failed := failed + #10 + ExtractFileName(Files[i]);
        img.Free;
        Continue;
      end;
      it := TPrintItem.Create;
      it.Kind := ikPhoto;
      it.FileName := Files[i];
      it.Pix := img.Pixels;
      img.Pixels := nil;
      it.Aspect := img.OrigW / img.OrigH;
      if it.Aspect >= 1 then Inc(landscape) else Inc(portrait);
      ExifAdd(it.Meta, 'File', ExtractFileName(Files[i]));
      ExifAdd(it.Meta, 'Path', ExtractFilePath(Files[i]));
      if FindFirst(Files[i], faAnyFile, sr) = 0 then
      begin
        ExifAdd(it.Meta, 'File size', Format('%.2f MB', [sr.Size / 1048576]));
        ExifAdd(it.Meta, 'Modified', FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(sr.Time)));
        FindClose(sr);
      end;
      ExifAdd(it.Meta, 'Dimensions', Format('%d x %d', [img.OrigW, img.OrigH]));
      for x := 0 to High(img.Exif.Names) do
        ExifAdd(it.Meta, img.Exif.Names[x], img.Exif.Values[x]);
      it.W := 50;
      it.H := 50 / it.Aspect;
      FView.AddItem(it);
      img.Free;
    end;
  finally
    Screen.Cursor := crDefault;
  end;
  if landscape > portrait then
    FOrient.ItemIndex := 1;
  ApplyPage;
  FView.AutoLayout;
  SelectionChanged(nil);
  if failed <> '' then
    ShowMessage('These files could not be loaded:' + failed);
end;

procedure TPrintPreviewForm.ApplyPage;
var
  p: TPaper;
begin
  p := Papers[FPaperIdx];
  if FOrient.ItemIndex = 1 then
    FView.SetPage(p.H, p.W)
  else
    FView.SetPage(p.W, p.H);
end;

procedure TPrintPreviewForm.PageChanged(Sender: TObject);
begin
  ApplyPage;
end;

procedure TPrintPreviewForm.SelectionChanged(Sender: TObject);
var
  s: TPrintItem;
begin
  s := FView.Selected;
  FBtnDel.Enabled := s <> nil;
  FBtnEdit.Enabled := (s <> nil) and (s.Kind = ikText);
  FFont.Enabled := (s <> nil) and (s.Kind = ikText);
  if FFont.Enabled then
  begin
    FUpdating := True;
    try
      FFont.ItemIndex := FFont.Items.IndexOf(IntToStr(s.FontPt));
    finally
      FUpdating := False;
    end;
  end;
end;

procedure TPrintPreviewForm.FontSizeChanged(Sender: TObject);
begin
  if FUpdating or (FView.Selected = nil) or (FView.Selected.Kind <> ikText) or (FFont.ItemIndex < 0) then
    Exit;
  FView.Selected.FontPt := FontSizes[FFont.ItemIndex];
  FView.Invalidate;
end;

procedure TPrintPreviewForm.LayoutClick(Sender: TObject);
begin
  FView.AutoLayout;
end;

procedure TPrintPreviewForm.DeleteClick(Sender: TObject);
begin
  FView.DeleteSelected;
end;

procedure TPrintPreviewForm.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure TPrintPreviewForm.FormKey(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if (Key = VK_DELETE) and FView.Focused then
  begin
    FView.DeleteSelected;
    Key := 0;
  end
  else if Key = VK_ESCAPE then
  begin
    Key := 0;
    Close;
  end;
end;

procedure TPrintPreviewForm.EditItem(It: TPrintItem);
var
  dlg: TTextDialog;
  meta: TExifData;
begin
  SetLength(meta.Names, 0);
  SetLength(meta.Values, 0);
  if It.Source <> nil then
    meta := It.Source.Meta;
  dlg := TTextDialog.CreateDlg(Self, 'Text', It.Text, meta);
  try
    CenterOver(dlg, Self);
    if dlg.ShowModal = mrOk then
    begin
      It.Text := Trim(dlg.Memo.Text);
      FView.Invalidate;
    end;
  finally
    dlg.Free;
  end;
end;

procedure TPrintPreviewForm.EditTextClick(Sender: TObject);
begin
  if (FView.Selected <> nil) and (FView.Selected.Kind = ikText) then
    EditItem(FView.Selected);
end;

procedure TPrintPreviewForm.AddTextClick(Sender: TObject);
var
  src, it: TPrintItem;
  dlg: TTextDialog;
  i, lines: Integer;
  meta: TExifData;
  s: string;
begin
  // the photo the metadata come from: the selected one (or the one a selected text belongs to)
  src := FView.Selected;
  if (src <> nil) and (src.Kind = ikText) then
    src := src.Source;
  if src = nil then
    for i := 0 to FView.Items.Count - 1 do
      if TPrintItem(FView.Items[i]).Kind = ikPhoto then
      begin
        src := TPrintItem(FView.Items[i]);
        Break;
      end;
  SetLength(meta.Names, 0);
  SetLength(meta.Values, 0);
  if src <> nil then
    meta := src.Meta;
  dlg := TTextDialog.CreateDlg(Self, 'Add text', '', meta);
  try
    CenterOver(dlg, Self);
    if dlg.ShowModal <> mrOk then
      Exit;
    s := Trim(dlg.Memo.Text);
  finally
    dlg.Free;
  end;
  if s = '' then
    Exit;
  it := TPrintItem.Create;
  it.Kind := ikText;
  it.Text := s;
  it.Source := src;
  if FFont.ItemIndex >= 0 then it.FontPt := FontSizes[FFont.ItemIndex] else it.FontPt := 12;
  lines := 1;
  for i := 1 to Length(s) do
    if s[i] = #10 then Inc(lines);
  if src <> nil then
  begin
    it.W := Max(60, src.W);
    it.X := src.X;
    it.Y := src.Y + src.H + 2;
  end
  else
  begin
    it.W := 80;
    it.X := Margin;
    it.Y := Margin;
  end;
  it.W := Min(it.W, FView.PageW - 2 * Margin);
  it.H := lines * it.FontPt * 0.3528 * 1.3 + 4 + Length(s) / Max(1, it.W / (it.FontPt * 0.19)) * it.FontPt * 0.3528;
  if it.Y + it.H > FView.PageH then
    it.Y := FView.PageH - it.H - 2;
  FView.AddItem(it);
  FView.Selected := it;
end;

procedure TPrintPreviewForm.RenderTo(ACanvas: TCanvas; XDpi, YDpi, OffX, OffY: Integer);
var
  i, tw, th: Integer;
  it: TPrintItem;
  r: TRect;
  img: TLoadedImage;
  bmp: TBitmap;
  ts: TTextStyle;
  d: Integer;
begin
  d := Min(Min(XDpi, YDpi), PrintDpiMax);
  for i := 0 to FView.Items.Count - 1 do
  begin
    it := TPrintItem(FView.Items[i]);
    r := Rect(Round(it.X / 25.4 * XDpi) - OffX, Round(it.Y / 25.4 * YDpi) - OffY,
      Round((it.X + it.W) / 25.4 * XDpi) - OffX, Round((it.Y + it.H) / 25.4 * YDpi) - OffY);
    if it.Kind = ikPhoto then
    begin
      tw := Max(1, Round(it.W / 25.4 * d));
      th := Max(1, Round(it.H / 25.4 * d));
      img := DecodeFile(it.FileName, tw, th, True);
      try
        if img.Pixels <> nil then
        begin
          bmp := BitmapFromPixels(img.Pixels);
          try
            ACanvas.StretchDraw(r, bmp);
          finally
            bmp.Free;
          end;
        end;
      finally
        img.Free;
      end;
    end
    else
    begin
      ACanvas.Font.Color := clBlack;
      ACanvas.Font.Height := -Max(1, Round(it.FontPt / 72 * YDpi));
      ACanvas.Brush.Style := bsClear;
      ts := ACanvas.TextStyle;
      ts.Wordbreak := True;
      ts.SingleLine := False;
      ts.Clipping := True;
      ts.Opaque := False;
      ACanvas.TextRect(r, r.Left + 2, r.Top + 1, it.Text, ts);
    end;
  end;
end;

procedure TPrintPreviewForm.PrintClick(Sender: TObject);
var
  dlg: TPrintDialog;
  ox, oy: Integer;
  pr: TPaperRect;
begin
  if Printer.Printers.Count = 0 then
  begin
    MessageDlg('Print', 'No printer is available.', mtError, [mbOK], 0);
    Exit;
  end;
  dlg := TPrintDialog.Create(Self);
  try
    if not dlg.Execute then
      Exit;
  finally
    dlg.Free;
  end;
  Screen.Cursor := crHourGlass;
  try
    try
      if FOrient.ItemIndex = 1 then Printer.Orientation := poLandscape
      else Printer.Orientation := poPortrait;
      ox := 0;
      oy := 0;
      try
        pr := Printer.PaperSize.PaperRect;      // unprintable margins of the paper
        ox := pr.WorkRect.Left - pr.PhysicalRect.Left;
        oy := pr.WorkRect.Top - pr.PhysicalRect.Top;
      except
      end;
      Printer.Title := 'TTViewer';
      Printer.BeginDoc;
      try
        RenderTo(Printer.Canvas, Printer.XDPI, Printer.YDPI, ox, oy);
        Printer.EndDoc;
      except
        Printer.Abort;
        raise;
      end;
    except
      on E: Exception do
        MessageDlg('Print', 'Printing failed: ' + E.Message, mtError, [mbOK], 0);
    end;
  finally
    Screen.Cursor := crDefault;
  end;
end;

{ Paper size of the PDF (the orientation is the one of the preview); the page follows the choice. }
function TPrintPreviewForm.AskPdfPage: Boolean;
var
  f: TForm;
  cp: TComboBox;
  l: TLabel;
  b: TButton;
  i: Integer;
begin
  Result := False;
  f := TForm.CreateNew(Self);
  try
    f.Caption := 'Save as PDF';
    f.BorderStyle := bsDialog;
    f.PopupMode := pmExplicit;
    f.PopupParent := Self;
    f.ShowInTaskBar := stNever;
    f.Position := poOwnerFormCenter;
    f.ClientWidth := 300;
    f.ClientHeight := 90;
    l := TLabel.Create(f);
    l.Parent := f;
    l.SetBounds(16, 22, 80, 20);
    l.Caption := 'Paper size';
    cp := TComboBox.Create(f);
    cp.Parent := f;
    cp.Style := csDropDownList;
    cp.SetBounds(110, 18, 170, 28);
    for i := 0 to High(Papers) do
      cp.Items.Add(Papers[i].Name);
    cp.ItemIndex := FPaperIdx;
    b := TButton.Create(f);
    b.Parent := f;
    b.SetBounds(110, 54, 80, 28);
    b.Caption := 'OK';
    b.ModalResult := mrOk;
    b.Default := True;
    b := TButton.Create(f);
    b.Parent := f;
    b.SetBounds(200, 54, 80, 28);
    b.Caption := 'Cancel';
    b.ModalResult := mrCancel;
    b.Cancel := True;
    CenterOver(f, Self);
    if f.ShowModal <> mrOk then Exit;
    FPaperIdx := cp.ItemIndex;
    ApplyPage;
    Result := True;
  finally
    f.Free;
  end;
end;

procedure TPrintPreviewForm.PdfClick(Sender: TObject);
const
  PdfDpi = 200;
var
  dlg: TSaveDialog;
  bmp: TBitmap;
  img: TLazIntfImage;
  rgb: PByte;
  tj: tjhandle;
  jbuf: PByte;
  jsz: PtrUInt;
  x, y, w, h: Integer;
  c: TFPColor;
  fs: TFileStream;
  offs: array[1..5] of Int64;
  pw, ph: Double;

  procedure Put(const S: string);
  begin
    if S <> '' then fs.WriteBuffer(S[1], Length(S));
  end;

begin
  if not AskPdfPage then Exit;
  dlg := TSaveDialog.Create(Self);
  try
    dlg.Title := 'Save as PDF';
    dlg.Filter := 'PDF (*.pdf)|*.pdf';
    dlg.DefaultExt := 'pdf';
    dlg.Options := dlg.Options + [ofOverwritePrompt];
    if not dlg.Execute then Exit;
    if not TurboJpegLoad or not Assigned(tjCompress2) then
    begin
      MessageDlg('Save as PDF', 'libturbojpeg is not available.', mtError, [mbOK], 0);
      Exit;
    end;
    Screen.Cursor := crHourGlass;
    try
      try
        pw := FView.PageW;
        ph := FView.PageH;
        w := Round(pw / 25.4 * PdfDpi);
        h := Round(ph / 25.4 * PdfDpi);
        bmp := TBitmap.Create;
        try
          bmp.PixelFormat := pf24bit;
          bmp.SetSize(w, h);
          bmp.Canvas.Brush.Color := clWhite;
          bmp.Canvas.FillRect(0, 0, w, h);
          RenderTo(bmp.Canvas, PdfDpi, PdfDpi, 0, 0);
          img := bmp.CreateIntfImage;
          try
            GetMem(rgb, w * h * 3);
            try
              for y := 0 to h - 1 do
                for x := 0 to w - 1 do
                begin
                  c := img.Colors[x, y];
                  rgb[(y * w + x) * 3] := c.red shr 8;
                  rgb[(y * w + x) * 3 + 1] := c.green shr 8;
                  rgb[(y * w + x) * 3 + 2] := c.blue shr 8;
                end;
              jbuf := nil;
              jsz := 0;
              tj := tjInitCompress();
              try
                if tjCompress2(tj, rgb, w, 0, h, 0 {TJPF_RGB}, jbuf, jsz, TJSAMP_444, 90, 0) <> 0 then
                  raise Exception.Create(TurboJpegError);
                fs := TFileStream.Create(dlg.FileName, fmCreate);
                try
                  Put('%PDF-1.4'#10);
                  offs[1] := fs.Position;
                  Put('1 0 obj'#10'<< /Type /Catalog /Pages 2 0 R >>'#10'endobj'#10);
                  offs[2] := fs.Position;
                  Put('2 0 obj'#10'<< /Type /Pages /Kids [3 0 R] /Count 1 >>'#10'endobj'#10);
                  offs[3] := fs.Position;
                  Put(Format('3 0 obj'#10'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] ' +
                    '/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>'#10'endobj'#10,
                    [pw / 25.4 * 72, ph / 25.4 * 72], DefaultFormatSettings));
                  offs[4] := fs.Position;
                  Put(Format('4 0 obj'#10'<< /Length %d >>'#10'stream'#10, [Length(Format('q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q',
                    [pw / 25.4 * 72, ph / 25.4 * 72], DefaultFormatSettings))]));
                  Put(Format('q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q', [pw / 25.4 * 72, ph / 25.4 * 72], DefaultFormatSettings));
                  Put(#10'endstream'#10'endobj'#10);
                  offs[5] := fs.Position;
                  Put(Format('5 0 obj'#10'<< /Type /XObject /Subtype /Image /Width %d /Height %d ' +
                    '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length %d >>'#10'stream'#10,
                    [w, h, jsz]));
                  fs.WriteBuffer(jbuf^, jsz);
                  Put(#10'endstream'#10'endobj'#10);
                  y := fs.Position;
                  Put('xref'#10'0 6'#10'0000000000 65535 f '#10);
                  for x := 1 to 5 do
                    Put(Format('%.10d 00000 n '#10, [offs[x]]));
                  Put(Format('trailer'#10'<< /Size 6 /Root 1 0 R >>'#10'startxref'#10'%d'#10'%%EOF'#10, [y]));
                finally
                  fs.Free;
                end;
              finally
                if jbuf <> nil then tjFree(jbuf);
                tjDestroy(tj);
              end;
            finally
              FreeMem(rgb);
            end;
          finally
            img.Free;
          end;
        finally
          bmp.Free;
        end;
      except
        on E: Exception do
          MessageDlg('Save as PDF', 'Could not create the PDF: ' + E.Message, mtError, [mbOK], 0);
      end;
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    dlg.Free;
  end;
end;

end.
