unit thumbview;

{ Thumbnails grid: owns the thumbnail loader thread, scrolls (wheel / external
  scrollbar) and zooms (ctrl+wheel) like a file manager. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Controls, Graphics, ExtCtrls, ComCtrls, LCLType,
  jpegworkers, bmputil, dndutil;

type
  TThumbItem = record
    FileName: string;
    Bmp: TBitmap;
    Done: Boolean;                 // thumbnail produced or failed (counted in progress)
    Sel: Boolean;                  // part of the (multi) selection
  end;

  TThumbProgressEvent = procedure(Sender: TObject; Done, Total: Integer) of object;

  { TThumbView }

  TThumbView = class(TCustomControl)
  private
    FItems: array of TThumbItem;
    FLoader: TThumbLoader;
    FGen: Integer;
    FCell: Integer;
    FScrollY: Integer;
    FSelected: Integer;             // the item shown in the main panel
    FAnchor: Integer;               // start of shift-selections
    FDoneCount: Integer;
    FScrollbar: TTrackBar;
    FUpdatingBar: Boolean;
    FWantTimer: TTimer;
    FOnSelect: TNotifyEvent;
    FOnProgress: TThumbProgressEvent;
    FDownIdx, FDownX, FDownY: Integer;   // pending press (drag-out detection)
    FDeferSelect: Boolean;               // plain press on a multi-selection: decide on release
    function WrapName(const AName: string; W: Integer): TStringArray;
    function ColWidth: Integer;
    function RowHeight: Integer;
    function Cols: Integer;
    function TotalHeight: Integer;
    function MaxScroll: Integer;
    function BoxForCell: Integer;
    procedure SetScrollY(Value: Integer);
    procedure SyncScrollbar;
    procedure PushVisible;
    procedure ScrollbarChange(Sender: TObject);
    procedure WantTimer(Sender: TObject);
    procedure ThumbReady(Sender: TObject; R: TThumbResult);
    procedure SetScrollbar(Value: TTrackBar);
    procedure ClearItems;
    function ItemAt(X, Y: Integer): Integer;
    procedure ChangeCell(NewCell: Integer);
    procedure ClearSel;
    procedure SelectRange(A, B: Integer);
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetFiles(Files: TStrings);
    { Selects an item without firing OnSelect (use Select to fire it). }
    procedure SetSelected(Index: Integer);
    procedure Select(Index: Integer);
    procedure EnsureVisible(Index: Integer);
    { Produce the thumbnail of an item again (its file changed). }
    procedure ReloadItem(Index: Integer);
    { Removes items (indices ascending) keeping the other thumbnails. }
    procedure RemoveIndices(const Idx: array of Integer);
    function Count: Integer;
    function SelectedCount: Integer;
    { Selected files in list order; the current one alone when nothing else is selected. }
    procedure SelectedFiles(List: TStrings);
    procedure SelectAll;
    property SelectedIndex: Integer read FSelected;
    property Scrollbar: TTrackBar read FScrollbar write SetScrollbar;
    property OnSelect: TNotifyEvent read FOnSelect write FOnSelect;
    property OnProgress: TThumbProgressEvent read FOnProgress write FOnProgress;
  end;

implementation

const
  CellMin = 48;
  CellMax = 512;
  Pad = 6;
  NameLines = 2;                   // lines reserved for the file name
  BoxSizes: array[0..4] of Integer = (96, 160, 256, 384, 512);
  ColBack = $262626;
  ColSel = $8A5A2B;
  ColText = $D8D8D8;

{ TThumbView }

constructor TThumbView.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FDownIdx := -1;
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  TabStop := True;
  FCell := 128;
  FSelected := -1;
  FWantTimer := TTimer.Create(Self);
  FWantTimer.Enabled := False;
  FWantTimer.Interval := 250;
  FWantTimer.OnTimer := @WantTimer;
  FLoader := TThumbLoader.Create;
  FLoader.OnThumb := @ThumbReady;
  FLoader.SetWantedSize(BoxForCell);
end;

destructor TThumbView.Destroy;
begin
  FLoader.OnThumb := nil;
  FLoader.Free;
  ClearItems;
  inherited Destroy;
end;

procedure TThumbView.ClearItems;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Bmp.Free;
  SetLength(FItems, 0);
end;

function TThumbView.ColWidth: Integer;
begin
  Result := FCell + 2 * Pad;
end;

function TThumbView.RowHeight: Integer;
begin
  Result := FCell + 2 * Pad + NameLines * Canvas.TextHeight('Ag') + 2;
end;

function TThumbView.Cols: Integer;
begin
  Result := Max(1, ClientWidth div ColWidth);
end;

function TThumbView.TotalHeight: Integer;
begin
  Result := ((Length(FItems) + Cols - 1) div Cols) * RowHeight;
end;

function TThumbView.MaxScroll: Integer;
begin
  Result := Max(0, TotalHeight - ClientHeight);
end;

function TThumbView.BoxForCell: Integer;
var
  i: Integer;
begin
  for i := 0 to High(BoxSizes) do
    if BoxSizes[i] >= FCell then
      Exit(BoxSizes[i]);
  Result := BoxSizes[High(BoxSizes)];
end;

function TThumbView.Count: Integer;
begin
  Result := Length(FItems);
end;

procedure TThumbView.SetScrollbar(Value: TTrackBar);
begin
  FScrollbar := Value;
  if FScrollbar <> nil then
  begin
    FScrollbar.OnChange := @ScrollbarChange;
    FScrollbar.TickStyle := tsNone;
    FScrollbar.Min := 0;
    SyncScrollbar;
  end;
end;

procedure TThumbView.SyncScrollbar;
begin
  if FScrollbar = nil then
    Exit;
  FUpdatingBar := True;
  try
    FScrollbar.Max := Max(1, MaxScroll);
    FScrollbar.LineSize := Max(1, RowHeight div 4);
    FScrollbar.PageSize := Max(1, ClientHeight);
    FScrollbar.Position := FScrollY;
    FScrollbar.Enabled := MaxScroll > 0;
  finally
    FUpdatingBar := False;
  end;
end;

procedure TThumbView.ScrollbarChange(Sender: TObject);
begin
  if not FUpdatingBar then
    SetScrollY(FScrollbar.Position);
end;

procedure TThumbView.SetScrollY(Value: Integer);
begin
  Value := EnsureRange(Value, 0, MaxScroll);
  if Value = FScrollY then
    Exit;
  FScrollY := Value;
  SyncScrollbar;
  PushVisible;
  Invalidate;
end;

{ Tells the loader thread which thumbnails are on screen right now. }
procedure TThumbView.PushVisible;
var
  c, r0, r1, f, l: Integer;
begin
  if Length(FItems) = 0 then
    Exit;
  c := Cols;
  r0 := FScrollY div RowHeight;
  r1 := (FScrollY + ClientHeight - 1) div RowHeight;
  f := Min(r0 * c, High(FItems));
  l := Min((r1 + 1) * c - 1, High(FItems));
  FLoader.SetVisible(f, l);
end;

procedure TThumbView.SetFiles(Files: TStrings);
var
  i: Integer;
  names: array of string;
begin
  ClearItems;
  SetLength(FItems, Files.Count);
  SetLength(names, Files.Count);
  for i := 0 to Files.Count - 1 do
  begin
    FItems[i].FileName := Files[i];
    names[i] := Files[i];
  end;
  FSelected := -1;
  FAnchor := 0;
  FScrollY := 0;
  FDoneCount := 0;
  Inc(FGen);
  FLoader.SetFiles(names, FGen);
  SyncScrollbar;
  PushVisible;
  if Assigned(FOnProgress) then
    FOnProgress(Self, 0, Length(FItems));
  Invalidate;
end;

procedure TThumbView.ThumbReady(Sender: TObject; R: TThumbResult);
var
  c, r0, r1: Integer;
begin
  try
    if (R.Gen <> FGen) or (R.Index < 0) or (R.Index > High(FItems)) then
      Exit;
    with FItems[R.Index] do
    begin
      if R.Pixels <> nil then
      begin
        Bmp.Free;
        Bmp := BitmapFromPixels(R.Pixels);
      end;
      if not Done then
      begin
        Done := True;
        Inc(FDoneCount);
        if Assigned(FOnProgress) then
          FOnProgress(Self, FDoneCount, Length(FItems));
      end;
    end;
    c := Cols;
    r0 := FScrollY div RowHeight;
    r1 := (FScrollY + ClientHeight - 1) div RowHeight;
    if (R.Index div c >= r0) and (R.Index div c <= r1) then
      Invalidate;
  finally
    R.Free;
  end;
end;

procedure TThumbView.WantTimer(Sender: TObject);
begin
  FWantTimer.Enabled := False;
  FLoader.SetWantedSize(BoxForCell);
end;

procedure TThumbView.ChangeCell(NewCell: Integer);
var
  anchor: Integer;
begin
  NewCell := EnsureRange(NewCell, CellMin, CellMax);
  if NewCell = FCell then
    Exit;
  // keep the first visible row's first item in view
  anchor := (FScrollY div RowHeight) * Cols;
  FCell := NewCell;
  FScrollY := EnsureRange((anchor div Cols) * RowHeight, 0, MaxScroll);
  SyncScrollbar;
  PushVisible;
  FWantTimer.Enabled := False;      // restart the debounce
  FWantTimer.Enabled := True;
  Invalidate;
end;

procedure TThumbView.EnsureVisible(Index: Integer);
var
  rowTop, rowBottom: Integer;
begin
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  rowTop := (Index div Cols) * RowHeight;
  rowBottom := rowTop + RowHeight;
  if rowTop < FScrollY then
    SetScrollY(rowTop)
  else if rowBottom > FScrollY + ClientHeight then
    SetScrollY(rowBottom - ClientHeight);
end;

procedure TThumbView.ClearSel;
var
  i: Integer;
begin
  for i := 0 to High(FItems) do
    FItems[i].Sel := False;
end;

procedure TThumbView.SelectRange(A, B: Integer);
var
  i: Integer;
begin
  ClearSel;
  for i := Min(A, B) to Max(A, B) do
    if (i >= 0) and (i <= High(FItems)) then
      FItems[i].Sel := True;
end;

function TThumbView.SelectedCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(FItems) do
    if FItems[i].Sel then Inc(Result);
end;

procedure TThumbView.SelectedFiles(List: TStrings);
var
  i: Integer;
begin
  List.Clear;
  for i := 0 to High(FItems) do
    if FItems[i].Sel then
      List.Add(FItems[i].FileName);
  if (List.Count = 0) and (FSelected >= 0) then
    List.Add(FItems[FSelected].FileName);
end;

procedure TThumbView.SelectAll;
begin
  SelectRange(0, High(FItems));
  Invalidate;
end;

procedure TThumbView.RemoveIndices(const Idx: array of Integer);
var
  i, k, j: Integer;
begin
  k := 0;
  j := 0;
  for i := 0 to High(FItems) do
  begin
    if (j <= High(Idx)) and (Idx[j] = i) then
    begin
      Inc(j);
      FItems[i].Bmp.Free;
      if FItems[i].Done then Dec(FDoneCount);
      Continue;
    end;
    FItems[k] := FItems[i];
    Inc(k);
  end;
  SetLength(FItems, k);
  Inc(FGen);
  FLoader.RemoveIndices(Idx, FGen);
  FSelected := -1;
  FAnchor := 0;
  FScrollY := EnsureRange(FScrollY, 0, MaxScroll);
  SyncScrollbar;
  PushVisible;
  if Assigned(FOnProgress) then
    FOnProgress(Self, FDoneCount, Length(FItems));
  Invalidate;
end;

procedure TThumbView.ReloadItem(Index: Integer);
begin
  FLoader.Redo(Index);
end;

procedure TThumbView.SetSelected(Index: Integer);
begin
  if (Index < -1) or (Index > High(FItems)) then
    Exit;
  FSelected := Index;
  FAnchor := Index;
  ClearSel;
  if Index >= 0 then
    FItems[Index].Sel := True;
  EnsureVisible(Index);
  Invalidate;
end;

procedure TThumbView.Select(Index: Integer);
begin
  if (Index < 0) or (Index > High(FItems)) then
    Exit;
  SetSelected(Index);
  if Assigned(FOnSelect) then
    FOnSelect(Self);
end;

function TThumbView.ItemAt(X, Y: Integer): Integer;
var
  c, col, row: Integer;
begin
  Result := -1;
  c := Cols;
  col := X div ColWidth;
  if col >= c then
    Exit;
  row := (Y + FScrollY) div RowHeight;
  Result := row * c + col;
  if Result > High(FItems) then
    Result := -1;
end;

procedure TThumbView.Resize;
begin
  inherited Resize;
  FScrollY := EnsureRange(FScrollY, 0, MaxScroll);
  SyncScrollbar;
  PushVisible;
end;

procedure TThumbView.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if CanFocus then
    SetFocus;
  if Button = mbLeft then
  begin
    i := ItemAt(X, Y);
    FDownIdx := i;
    FDownX := X;
    FDownY := Y;
    FDeferSelect := False;
    if i >= 0 then
    begin
      if (Shift * [ssShift, ssCtrl] = []) and FItems[i].Sel and (SelectedCount > 1) then
        FDeferSelect := True      // may be the start of dragging the whole selection
      else if ssShift in Shift then
      begin
        SelectRange(FAnchor, i);
        FSelected := i;
        Invalidate;
        if Assigned(FOnSelect) then FOnSelect(Self);
      end
      else if ssCtrl in Shift then
      begin
        FItems[i].Sel := not FItems[i].Sel;
        FAnchor := i;
        FSelected := i;
        Invalidate;
        if Assigned(FOnSelect) then FOnSelect(Self);
      end
      else
        Select(i);
    end;
  end;
end;

procedure TThumbView.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  files: TStringList;
begin
  inherited MouseMove(Shift, X, Y);
  if (FDownIdx >= 0) and (ssLeft in Shift) and
     ((Abs(X - FDownX) > 8) or (Abs(Y - FDownY) > 8)) then
  begin
    FDownIdx := -1;
    files := TStringList.Create;
    try
      SelectedFiles(files);
      BeginFileDrag(Self, files);
    finally
      files.Free;
    end;
    FDeferSelect := False;
  end;
end;

procedure TThumbView.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and FDeferSelect and (FDownIdx >= 0) then
    Select(FDownIdx);
  FDeferSelect := False;
  FDownIdx := -1;
end;

procedure TThumbView.KeyDown(var Key: Word; Shift: TShiftState);
var
  i, c: Integer;
begin
  inherited KeyDown(Key, Shift);
  if Length(FItems) = 0 then
    Exit;
  if (Key = VK_A) and (ssCtrl in Shift) then
  begin
    SelectAll;
    Key := 0;
    Exit;
  end;
  c := Cols;
  i := Max(FSelected, 0);
  case Key of
    VK_LEFT: Dec(i);
    VK_RIGHT: Inc(i);
    VK_UP: Dec(i, c);
    VK_DOWN: Inc(i, c);
    VK_PRIOR: Dec(i, c * Max(1, ClientHeight div RowHeight));
    VK_NEXT: Inc(i, c * Max(1, ClientHeight div RowHeight));
    VK_HOME: i := 0;
    VK_END: i := High(FItems);
  else
    Exit;
  end;
  Key := 0;
  i := EnsureRange(i, 0, High(FItems));
  if ssShift in Shift then
  begin
    SelectRange(FAnchor, i);
    FSelected := i;
    EnsureVisible(i);
    Invalidate;
    if Assigned(FOnSelect) then FOnSelect(Self);
  end
  else
    Select(i);
end;

function TThumbView.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer; MousePos: TPoint): Boolean;
begin
  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then
      ChangeCell(FCell + 16)
    else
      ChangeCell(FCell - 16);
  end
  else
    SetScrollY(FScrollY - Sign(WheelDelta) * Max(1, RowHeight div 2));
  Result := True;
end;

{ Word-wraps a file name into at most NameLines lines of width W: breaks after
  spaces, '_', '-' and '.', or inside a word that is too wide on its own; the
  last line ends with '...' when the name does not fit. }
function TThumbView.WrapName(const AName: string; W: Integer): TStringArray;
var
  lines: array of string;
  cur, rest, piece: string;
  n, k: Integer;

  procedure Push(const L: string);
  begin
    SetLength(lines, Length(lines) + 1);
    lines[High(lines)] := L;
  end;

begin
  SetLength(lines, 0);
  rest := AName;
  while (rest <> '') and (Length(lines) < NameLines - 1) do
  begin
    if Canvas.TextWidth(rest) <= W then
      Break;
    // longest prefix that fits, preferably ending at a break character
    n := 1;
    while (n < Length(rest)) and (Canvas.TextWidth(Copy(rest, 1, n + 1)) <= W) do
      Inc(n);
    k := n;
    while (k > 1) and not (rest[k] in [' ', '_', '-', '.']) do
      Dec(k);
    if (k > 1) and (n < Length(rest)) then
      n := k;
    piece := Copy(rest, 1, n);
    Push(TrimRight(piece));
    rest := TrimLeft(Copy(rest, n + 1, MaxInt));
  end;
  cur := rest;
  if Canvas.TextWidth(cur) > W then
  begin
    while (Length(cur) > 1) and (Canvas.TextWidth(cur + '...') > W) do
      SetLength(cur, Length(cur) - 1);
    cur := cur + '...';
  end;
  Push(cur);
  Result := lines;
end;

procedure TThumbView.Paint;
var
  c, r0, r1, row, col, i, x, y, bw, bh, box: Integer;
  cellR, imgR: TRect;
  s: Double;
  lines: TStringArray;
  li, lh: Integer;
begin
  Canvas.Brush.Color := ColBack;
  Canvas.FillRect(ClientRect);
  if Length(FItems) = 0 then
    Exit;
  c := Cols;
  r0 := FScrollY div RowHeight;
  r1 := (FScrollY + ClientHeight - 1) div RowHeight;
  box := FCell;
  Canvas.Font.Color := ColText;
  for row := r0 to r1 do
    for col := 0 to c - 1 do
    begin
      i := row * c + col;
      if i > High(FItems) then
        Break;
      x := col * ColWidth;
      y := row * RowHeight - FScrollY;
      cellR := Rect(x + 2, y + 2, x + ColWidth - 2, y + RowHeight - 2);
      if FItems[i].Sel or (i = FSelected) then
      begin
        Canvas.Brush.Color := ColSel;
        Canvas.FillRect(cellR);
      end;
      if i = FSelected then
      begin
        Canvas.Brush.Style := bsClear;
        Canvas.Pen.Color := $F0F0F0;
        Canvas.Rectangle(cellR);
      end;
      Canvas.Brush.Style := bsClear;
      if FItems[i].Bmp <> nil then
      begin
        bw := FItems[i].Bmp.Width;
        bh := FItems[i].Bmp.Height;
        s := Min(box / bw, box / bh);
        imgR.Left := x + Pad + (box - Round(bw * s)) div 2;
        imgR.Top := y + Pad + (box - Round(bh * s)) div 2;
        imgR.Right := imgR.Left + Round(bw * s);
        imgR.Bottom := imgR.Top + Round(bh * s);
        Canvas.CopyRect(imgR, FItems[i].Bmp.Canvas, Rect(0, 0, bw, bh));
      end
      else
      begin
        Canvas.Pen.Color := $484848;
        Canvas.Rectangle(x + Pad, y + Pad, x + Pad + box, y + Pad + box);
      end;
      lh := Canvas.TextHeight('Ag');
      lines := WrapName(ExtractFileName(FItems[i].FileName), ColWidth - 6);
      for li := 0 to High(lines) do
        Canvas.TextOut(x + (ColWidth - Canvas.TextWidth(lines[li])) div 2,
          y + Pad + box + 2 + li * lh, lines[li]);
      Canvas.Brush.Style := bsSolid;
    end;
end;

end.
