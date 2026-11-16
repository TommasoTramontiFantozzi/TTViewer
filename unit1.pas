unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Types, Forms, Controls, Graphics, Dialogs, ComCtrls, Buttons,
  ExtCtrls, StdCtrls, ShellCtrls, Menus, LCLType, Process, laz.VirtualTrees,
  tjpeg, exifreader, jpegworkers, thumbview, imageview, pixbufload, jpegrotate, printpreview, transcode, formutil, encoders, aboutdlg, Clipbrd, IniFiles, appconfig;

type

  { TForm1 }

  TForm1 = class(TForm)
    FoldersTree: TPanel;
    Label1: TLabel;
    Label2: TLabel;
    Label3: TLabel;
    LazVirtualStringTree1: TLazVirtualStringTree;
    MainMenu1: TMainMenu;
    MenuItem1: TMenuItem;
    MenuItem10: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    MenuItem4: TMenuItem;
    MenuItem5: TMenuItem;
    MenuItem6: TMenuItem;
    MenuItem7: TMenuItem;
    MenuItem8: TMenuItem;
    MenuItem9: TMenuItem;
    Panel1: TPanel;
    ProgressBar1: TProgressBar;
    ExifScrollBox: TScrollBox;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    Splitter3: TSplitter;
    Thumbnail: TPanel;
    Metadata: TPanel;
    Image: TPanel;
    ThumbnailsOnOff: TSpeedButton;
    OrderByNameAscDesc: TSpeedButton;
    OrderByDateAscDesc: TSpeedButton;
    Print: TSpeedButton;
    FoldersTreeOnOff: TSpeedButton;
    StatusBar1: TStatusBar;
    ToolBar1: TToolBar;
    ThumbnailsScrollbar: TTrackBar;
    TrackBar1: TTrackBar;
    TrackBar2: TTrackBar;
    ExifOnOff: TSpeedButton;
    MenuItemPrint: TMenuItem;
    MenuItemConfig: TMenuItem;
    MenuHelp, MenuAbout: TMenuItem;

    RotateLeft: TSpeedButton;
    RotateRight: TSpeedButton;
    procedure FoldersTreeOnOffClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint; var Handled: Boolean);
    procedure MetadataResize(Sender: TObject);
    procedure OrderByDateAscDescClick(Sender: TObject);
    procedure OrderByNameAscDescClick(Sender: TObject);
    procedure PrintClick(Sender: TObject);
    procedure ExifOnOffClick(Sender: TObject);
    procedure ThumbnailResize(Sender: TObject);
    procedure FormResize(Sender: TObject);
    procedure FixBottomOrder;
    procedure ThumbnailsOnOffClick(Sender: TObject);
  private
    properitesName:array of string;
    properitesExif:array of string;
    nameCpation:array of TLabel;
    valueCaption:array of TEdit;
    FThumbs: TThumbView;
    FView: TImageView;
    FMainLoader: TMainImageLoader;
    FFolder: string;
    FCfgPath: string;
    FCfgLayout, FCfgLastPos, FCfgWheelZoom: Boolean;
    FFiles: TStringList;
    FIndex: Integer;
    FCurrentFile: string;
    FExifFor: string;
    FSortByDate: Boolean;
    FNameDesc, FDateDesc: Boolean;
    FUpdatingZoom: Boolean;
    FFull: TForm;
    FRoots: array of Integer;       // kind of each root node of the folder tree
    FBookNames, FBookPaths: TStringList;   // GTK bookmarks
    FFavNames, FFavPaths: TStringList;     // file manager favorites (XApp)
    procedure LoadPlaces;
    procedure AddPlace(Names, Paths: TStringList; APath, ALabel: string);
    function FindRoot(Kind: Integer): PVirtualNode;
    procedure RotateCurrent(Clockwise: Boolean);
    procedure RotateLeftClick(Sender: TObject);
    procedure RotateRightClick(Sender: TObject);
    procedure ViewToggleFullscreen(Sender: TObject);
    procedure ViewEscape(Sender: TObject);
    procedure AsyncToggleFullscreen(Data: PtrInt);
    procedure FullscreenClosed(Sender: TObject; var CloseAction: TCloseAction);
    procedure SetupFolderTree;
    procedure TreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex;
      TextType: TVSTTextType; var CellText: String);
    procedure TreeInitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
      var InitialStates: TVirtualNodeInitStates);
    procedure TreeInitChildren(Sender: TBaseVirtualTree; Node: PVirtualNode; var ChildCount: Cardinal);
    procedure TreeFreeNode(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure TreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
    procedure NavigateTo(const Path: string);
    procedure LoadFolder(const Path: string);
    procedure SortFiles;
    procedure SelectIndex(AIndex: Integer);
    procedure ThumbSelected(Sender: TObject);
    procedure ThumbProgress(Sender: TObject; Done, Total: Integer);
    procedure ViewNavigate(Sender: TObject; Delta: Integer);
    procedure ViewZoomChanged(Sender: TObject);
    procedure ViewNeedResolution(Sender: TObject; BoxW, BoxH: Integer);
    procedure ZoomTrackChange(Sender: TObject);
    procedure ImageLoaded(Sender: TObject; Img: TLoadedImage);
    procedure ShowExif(const Img: TLoadedImage);
    procedure LayoutExif;
    procedure ExifBarChange(Sender: TObject);
    procedure UpdateSaveState;
    procedure UpdateConfigMenu;
    procedure ShowSelectedThumb(Data: PtrInt);
    procedure MenuConfigClick(Sender: TObject);
    procedure MenuAboutClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure ApplyLayout(ini: TIniFile);
    procedure StoreConfigState;
    procedure MenuOpenClick(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure MenuOpenFolderClick(Sender: TObject);
    procedure MenuExitClick(Sender: TObject);
    procedure UpdateStatus;
    procedure MenuSaveClick(Sender: TObject);
    procedure MenuTranscodeClick(Sender: TObject);
    procedure MenuCopyClick(Sender: TObject);
    procedure MenuBinClick(Sender: TObject);
    procedure MenuDeleteClick(Sender: TObject);
    procedure MenuFileClick(Sender: TObject);
    procedure RemoveFiles(Permanent: Boolean);
    procedure ReloadFolder;
  public

  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

type
  PNodeData = ^TNodeData;
  TNodeData = record
    Path: string;
    Caption: string;
    Kind: Integer;                  // 0 folder, 1 Favorites, 2 Home, 3 Computer, 4 Bookmarks
    Kids: array of string;
    KidPaths: array of string;      // only for Favorites / Bookmarks
  end;

  PFileEntry = ^TFileEntry;
  TFileEntry = record
    Path: string;
    Time: LongInt;
  end;

var
  SortDesc: Boolean;

function CompareByName(A, B: Pointer): Integer;
begin
  Result := CompareText(ExtractFileName(PFileEntry(A)^.Path), ExtractFileName(PFileEntry(B)^.Path));
  if SortDesc then Result := -Result;
end;

function CompareByDate(A, B: Pointer): Integer;
begin
  Result := Sign(Int64(PFileEntry(A)^.Time) - PFileEntry(B)^.Time);
  if Result = 0 then
    Result := CompareText(PFileEntry(A)^.Path, PFileEntry(B)^.Path);
  if SortDesc then Result := -Result;
end;

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
var
  start, lastFile: string;
  ini: TIniFile;
begin
  if not TurboJpegLoad then
  begin
    MessageDlg('TTViewer', 'libturbojpeg was not found.' + LineEnding +
      'Install it (Debian/Ubuntu: sudo apt install libturbojpeg) and start again.', mtError, [mbOK], 0);
    Halt(1);
  end;
  PixbufInit;
  FFiles := TStringList.Create;
  FBookNames := TStringList.Create;
  FBookPaths := TStringList.Create;
  FFavNames := TStringList.Create;
  FFavPaths := TStringList.Create;
  FIndex := -1;
  setLength(properitesName,0);
  setLength(properitesExif,0);
  Caption := 'TTViewer';

  ThumbnailsOnOff.Caption := 'Thumbs';
  FoldersTreeOnOff.Caption := 'Folders';
  Print.Caption := 'Print';
  ExifOnOff.Caption := 'Exif';
  ExifOnOff.OnClick := @ExifOnOffClick;
  MenuItemPrint.Caption := 'Print...';
  MenuItemPrint.ShortCut := ShortCut(VK_P, [ssCtrl]);
  MenuItemPrint.OnClick := @PrintClick;
  OrderByNameAscDesc.Caption := 'Name';
  OrderByDateAscDesc.Caption := 'Date';
  RotateLeft.Caption := '↺';
  RotateRight.Caption := '↻';
  RotateLeft.Hint := 'Rotate left';
  RotateRight.Hint := 'Rotate right';
  RotateLeft.ShowHint := True;
  RotateRight.ShowHint := True;
  RotateLeft.OnClick := @RotateLeftClick;
  RotateRight.OnClick := @RotateRightClick;
  OrderByNameAscDesc.OnClick := @OrderByNameAscDescClick;
  OrderByDateAscDesc.OnClick := @OrderByDateAscDescClick;
  MenuItem2.OnClick := @MenuOpenClick;
  MenuItem3.OnClick := @MenuOpenFolderClick;
  MenuItem6.OnClick := @MenuExitClick;
  MenuItem1.OnClick := @MenuFileClick;
  MenuItemConfig := TMenuItem.Create(Self);
  MenuItemConfig.OnClick := @MenuConfigClick;
  MenuItem1.Insert(MenuItem1.IndexOf(MenuItem6), MenuItemConfig);
  MenuHelp := TMenuItem.Create(Self);
  MenuHelp.Caption := 'Help';
  MainMenu1.Items.Add(MenuHelp);
  MenuAbout := TMenuItem.Create(Self);
  MenuAbout.Caption := 'About...';
  MenuAbout.OnClick := @MenuAboutClick;
  MenuHelp.Add(MenuAbout);
  OnClose := @FormClose;
  OnResize := @FormResize;
  FCfgPath := FindConfigFile;
  FCfgLayout := False;
  FCfgLastPos := False;
  FCfgWheelZoom := False;
  if FCfgPath <> '' then
    ReadOptions(FCfgPath, FCfgLayout, FCfgLastPos, FCfgWheelZoom);
  UpdateConfigMenu;
  MenuItem4.OnClick := @MenuSaveClick;
  MenuItem5.OnClick := @MenuTranscodeClick;
  MenuItem8.OnClick := @MenuCopyClick;
  MenuItem10.OnClick := @MenuBinClick;
  MenuItem9.OnClick := @MenuDeleteClick;
  MenuItem2.ShortCut := ShortCut(VK_O, [ssCtrl]);
  MenuItem4.ShortCut := ShortCut(VK_S, [ssCtrl]);
  MenuItem5.ShortCut := ShortCut(VK_T, [ssCtrl]);
  MenuItem8.ShortCut := ShortCut(VK_C, [ssCtrl]);
  MenuItem10.ShortCut := ShortCut(VK_DELETE, []);
  MenuItem9.ShortCut := ShortCut(VK_DELETE, [ssShift]);
  OnMouseWheel := @FormMouseWheel;
  AllowDropFiles := True;
  OnDropFiles := @FormDropFiles;

  // central image
  FView := TImageView.Create(Self);
  FView.Parent := Image;
  FView.Align := alClient;
  FView.OnNavigate := @ViewNavigate;
  FView.WheelZoom := FCfgWheelZoom;
  FView.OnToggleFullscreen := @ViewToggleFullscreen;
  FView.OnEscape := @ViewEscape;
  FView.OnZoomChanged := @ViewZoomChanged;
  FView.OnNeedResolution := @ViewNeedResolution;
  TrackBar1.Min := 5;
  TrackBar1.Max := 800;
  TrackBar1.Position := 100;
  TrackBar1.TickStyle := tsNone;
  TrackBar1.OnChange := @ZoomTrackChange;
  Label3.Caption := 'Zoom 100%';

  // thumbnails
  ThumbnailsScrollbar.Max := 1;
  FThumbs := TThumbView.Create(Self);
  FThumbs.Parent := Thumbnail;
  FThumbs.Align := alClient;
  FThumbs.Scrollbar := ThumbnailsScrollbar;
  FThumbs.OnSelect := @ThumbSelected;
  FThumbs.OnProgress := @ThumbProgress;
  ProgressBar1.Visible := False;

  // exif
  TrackBar2.TickStyle := tsNone;
  TrackBar2.OnChange := @ExifBarChange;
  ExifScrollBox.VertScrollBar.Visible := False;
  ExifScrollBox.HorzScrollBar.Visible := False;

  FMainLoader := TMainImageLoader.Create;
  FMainLoader.OnLoaded := @ImageLoaded;

  SetupFolderTree;

  if FCfgLayout then
    try
      ini := TIniFile.Create(FCfgPath);
      try
        ApplyLayout(ini);
      finally
        ini.Free;
      end;
    except
    end;

  start := ParamStr(1);
  lastFile := '';
  if (start = '') and FCfgLastPos then
    try
      ini := TIniFile.Create(FCfgPath);
      try
        start := ini.ReadString('Last', 'Folder', '');
        lastFile := ini.ReadString('Last', 'File', '');
      finally
        ini.Free;
      end;
      if (lastFile <> '') and FileExists(lastFile) then
        start := lastFile
      else if not DirectoryExists(start) then
        start := '';
    except
      start := '';
    end;
  if (start <> '') and FileExists(start) then
  begin
    NavigateTo(ExtractFilePath(ExpandFileName(start)));
    if FFiles.IndexOf(ExpandFileName(start)) >= 0 then
      FThumbs.Select(FFiles.IndexOf(ExpandFileName(start)));
  end
  else if (start <> '') and DirectoryExists(start) then
    NavigateTo(ExpandFileName(start))
  else if DirectoryExists(GetUserDir + 'Pictures') then
    NavigateTo(GetUserDir + 'Pictures')
  else
    NavigateTo(GetUserDir);
  Application.QueueAsyncCall(@ShowSelectedThumb, 0);   // the thumbnail panel is sized after creation
end;

procedure TForm1.ShowSelectedThumb(Data: PtrInt);
begin
  FThumbs.EnsureVisible(FThumbs.SelectedIndex);
end;

procedure TForm1.UpdateConfigMenu;
begin
  if FCfgPath = '' then
    MenuItemConfig.Caption := 'Create Config File'
  else
    MenuItemConfig.Caption := 'Settings...';
end;

procedure TForm1.MenuAboutClick(Sender: TObject);
begin
  ShowAbout(Self);
end;

procedure TForm1.MenuConfigClick(Sender: TObject);
var
  path, err: string;
  l, p, wz, deleted: Boolean;
begin
  if FCfgPath = '' then
  begin
    if CreateConfigFile(path, err) then
    begin
      FCfgPath := path;
      FCfgLayout := True;
      FCfgLastPos := True;
      FCfgWheelZoom := False;
      UpdateConfigMenu;
      MessageDlg('Config file', 'Configuration file created:' + LineEnding + path, mtInformation, [mbOK], 0);
    end
    else
      MessageDlg('Config file', 'Cannot create the configuration file:' + LineEnding + err, mtError, [mbOK], 0);
    Exit;
  end;
  l := FCfgLayout;
  p := FCfgLastPos;
  wz := FCfgWheelZoom;
  if EditSettings(FCfgPath, l, p, wz, deleted) then
  begin
    if deleted then
    begin
      FCfgPath := '';
      FCfgLayout := False;
      FCfgLastPos := False;
      FCfgWheelZoom := False;
    end
    else
    begin
      FCfgLayout := l;
      FCfgLastPos := p;
      FCfgWheelZoom := wz;
      try
        WriteOptions(FCfgPath, l, p, wz);
      except
        on E: Exception do
          MessageDlg('Settings', 'Cannot write ' + FCfgPath + ': ' + E.Message, mtError, [mbOK], 0);
      end;
    end;
    FView.WheelZoom := FCfgWheelZoom;
    UpdateConfigMenu;
  end;
end;

procedure TForm1.ApplyLayout(ini: TIniFile);
var
  l, t, w, h: Integer;
  r: TRect;
begin
  FoldersTree.Visible := ini.ReadBool('Layout', 'FoldersVisible', FoldersTree.Visible);
  Thumbnail.Visible := ini.ReadBool('Layout', 'ThumbsVisible', Thumbnail.Visible);
  Metadata.Visible := ini.ReadBool('Layout', 'ExifVisible', Metadata.Visible);
  FoldersTree.Width := Max(60, ini.ReadInteger('Layout', 'FoldersWidth', FoldersTree.Width));
  Thumbnail.Height := Max(60, ini.ReadInteger('Layout', 'ThumbsHeight', Thumbnail.Height));
  FixBottomOrder;
  Metadata.Width := Max(60, ini.ReadInteger('Layout', 'ExifWidth', Metadata.Width));
  w := ini.ReadInteger('Layout', 'Width', 0);
  h := ini.ReadInteger('Layout', 'Height', 0);
  if (w >= 300) and (h >= 200) then
  begin
    r := Screen.WorkAreaRect;
    w := Min(w, r.Right - r.Left);
    h := Min(h, r.Bottom - r.Top);
    l := EnsureRange(ini.ReadInteger('Layout', 'Left', Left), r.Left, Max(r.Left, r.Right - w));
    t := EnsureRange(ini.ReadInteger('Layout', 'Top', Top), r.Top, Max(r.Top, r.Bottom - h));
    Position := poDesigned;
    SetBounds(l, t, w, h);
  end;
  if ini.ReadBool('Layout', 'Maximized', False) then
    WindowState := wsMaximized;
end;

procedure TForm1.StoreConfigState;
var
  ini: TIniFile;
begin
  if (FCfgPath = '') or not (FCfgLayout or FCfgLastPos) then
    Exit;
  try
    ini := TIniFile.Create(FCfgPath);
    try
      if FCfgLayout then
      begin
        ini.WriteBool('Layout', 'Maximized', WindowState = wsMaximized);
        if WindowState = wsMaximized then
        begin
          ini.WriteInteger('Layout', 'Left', RestoredLeft);
          ini.WriteInteger('Layout', 'Top', RestoredTop);
          ini.WriteInteger('Layout', 'Width', RestoredWidth);
          ini.WriteInteger('Layout', 'Height', RestoredHeight);
        end
        else
        begin
          ini.WriteInteger('Layout', 'Left', Left);
          ini.WriteInteger('Layout', 'Top', Top);
          ini.WriteInteger('Layout', 'Width', Width);
          ini.WriteInteger('Layout', 'Height', Height);
        end;
        ini.WriteBool('Layout', 'FoldersVisible', FoldersTree.Visible);
        ini.WriteBool('Layout', 'ThumbsVisible', Thumbnail.Visible);
        ini.WriteBool('Layout', 'ExifVisible', Metadata.Visible);
        ini.WriteInteger('Layout', 'FoldersWidth', FoldersTree.Width);
        ini.WriteInteger('Layout', 'ThumbsHeight', Thumbnail.Height);
        ini.WriteInteger('Layout', 'ExifWidth', Metadata.Width);
      end;
      if FCfgLastPos and (FFolder <> '') then
      begin
        ini.WriteString('Last', 'Folder', FFolder);
        ini.WriteString('Last', 'File', FCurrentFile);
      end;
    finally
      ini.Free;
    end;
  except
    // the configuration is optional: never fail while closing
  end;
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  StoreConfigState;
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  if FMainLoader <> nil then
  begin
    FMainLoader.OnLoaded := nil;
    FMainLoader.Free;
  end;
  FFiles.Free;
  FBookNames.Free;
  FBookPaths.Free;
  FFavNames.Free;
  FFavPaths.Free;
end;

procedure TForm1.ThumbnailsOnOffClick(Sender: TObject);
begin
  Thumbnail.Visible:=not Thumbnail.Visible;
  FixBottomOrder;
end;

procedure TForm1.FoldersTreeOnOffClick(Sender: TObject);
begin
  FoldersTree.Visible:=not FoldersTree.Visible;
end;

procedure TForm1.ExifOnOffClick(Sender: TObject);
begin
  Metadata.Visible:=not Metadata.Visible;
end;

procedure TForm1.ThumbnailResize(Sender: TObject);
begin
  ThumbNail.Invalidate;
  FixBottomOrder;
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  FixBottomOrder;
end;

{ StatusBar1, Thumbnail and Splitter1 are all alBottom: LCL stacks them by Top,
  and the order is sometimes lost (status bar above the panel). From the
  bottom up it must be: status bar, thumbnails, splitter. }
procedure TForm1.FixBottomOrder;
begin
  Splitter1.Visible := Thumbnail.Visible;
  StatusBar1.Top := ClientHeight - StatusBar1.Height;
  Thumbnail.Top := StatusBar1.Top - Thumbnail.Height;
  Splitter1.Top := Thumbnail.Top - Splitter1.Height;
end;

{ Print preview of the selected photos (ctrl/shift+click in the thumbnails to select several). }
procedure TForm1.PrintClick(Sender: TObject);
var
  files: TStringList;
  dlg: TPrintPreviewForm;
begin
  files := TStringList.Create;
  try
    FThumbs.SelectedFiles(files);
    if files.Count = 0 then
    begin
      ShowMessage('Select one or more photos first.');
      Exit;
    end;
    dlg := TPrintPreviewForm.CreateWith(Self, files);
    try
      CenterOver(dlg, Self);
      dlg.ShowModal;
    finally
      dlg.Free;
    end;
  finally
    files.Free;
  end;
end;

{ ---------------- folder tree ---------------- }

function TForm1.FindRoot(Kind: Integer): PVirtualNode;
begin
  Result := LazVirtualStringTree1.GetFirst;
  while (Result <> nil) and (PNodeData(LazVirtualStringTree1.GetNodeData(Result))^.Kind <> Kind) do
    Result := LazVirtualStringTree1.GetNextSibling(Result);
end;

function UriToPath(const U: string): string;
var
  k: Integer;
  s: string;
begin
  Result := '';
  if Pos('file://', U) <> 1 then
    Exit;
  s := Copy(U, 8, MaxInt);
  k := 1;
  while k <= Length(s) do
  begin
    if (s[k] = '%') and (k + 2 <= Length(s)) then
    begin
      Result := Result + Chr(StrToIntDef('$' + Copy(s, k + 1, 2), 63));
      Inc(k, 3);
    end
    else
    begin
      Result := Result + s[k];
      Inc(k);
    end;
  end;
end;

procedure TForm1.AddPlace(Names, Paths: TStringList; APath, ALabel: string);
begin
  APath := ExcludeTrailingPathDelimiter(APath);
  if (APath = '') or not DirectoryExists(APath) or (Paths.IndexOf(APath) >= 0) then
    Exit;
  if ALabel = '' then
    ALabel := ExtractFileName(APath);
  Paths.Add(APath);
  Names.Add(ALabel);
end;

{ Favorites: the ones set in the file manager (XApp favorites, kept in dconf by Mint's Nemo).
  Bookmarks: the GTK bookmarks shared by Nemo, Nautilus, Thunar... }
procedure TForm1.LoadPlaces;
var
  f: TStringList;
  i, sp, q1, q2: Integer;
  line, outp, item, fn: string;
begin
  FBookNames.Clear;
  FBookPaths.Clear;
  FFavNames.Clear;
  FFavPaths.Clear;
  f := TStringList.Create;
  try
    for fn in [GetEnvironmentVariable('HOME') + '/.config/gtk-3.0/bookmarks',
               GetEnvironmentVariable('HOME') + '/.gtk-bookmarks'] do
      if FileExists(fn) then
      begin
        f.LoadFromFile(fn);
        Break;
      end;
    for i := 0 to f.Count - 1 do
    begin
      line := Trim(f[i]);
      sp := Pos(' ', line);
      if sp > 0 then
        AddPlace(FBookNames, FBookPaths, UriToPath(Copy(line, 1, sp - 1)), Trim(Copy(line, sp + 1, MaxInt)))
      else
        AddPlace(FBookNames, FBookPaths, UriToPath(line), '');
    end;
  finally
    f.Free;
  end;
  // dconf prints ['file:///path::inode/directory', ...]
  outp := '';
  try
    if RunCommand('dconf', ['read', '/org/x/apps/favorites/list'], outp) then
      repeat
        q1 := Pos('''', outp);
        if q1 = 0 then Break;
        Delete(outp, 1, q1);
        q2 := Pos('''', outp);
        if q2 = 0 then Break;
        item := Copy(outp, 1, q2 - 1);
        Delete(outp, 1, q2);
        sp := Pos('::', item);
        if sp > 0 then
          item := Copy(item, 1, sp - 1);
        AddPlace(FFavNames, FFavPaths, UriToPath(item), '');
      until False;
  except
  end;
end;

procedure TForm1.SetupFolderTree;
begin
  LoadPlaces;
  SetLength(FRoots, 0);
  if FFavPaths.Count > 0 then begin SetLength(FRoots, Length(FRoots) + 1); FRoots[High(FRoots)] := 1; end;
  if FBookPaths.Count > 0 then begin SetLength(FRoots, Length(FRoots) + 1); FRoots[High(FRoots)] := 4; end;
  SetLength(FRoots, Length(FRoots) + 2);
  FRoots[High(FRoots) - 1] := 2;
  FRoots[High(FRoots)] := 3;
  with LazVirtualStringTree1 do
  begin
    NodeDataSize := SizeOf(TNodeData);
    OnGetText := @TreeGetText;
    OnInitNode := @TreeInitNode;
    OnInitChildren := @TreeInitChildren;
    OnFreeNode := @TreeFreeNode;
    OnChange := @TreeChange;
    RootNodeCount := Length(FRoots);
  end;
  if FFavPaths.Count > 0 then
    LazVirtualStringTree1.Expanded[FindRoot(1)] := True;
  if FBookPaths.Count > 0 then
    LazVirtualStringTree1.Expanded[FindRoot(4)] := True;
end;

procedure TForm1.TreeGetText(Sender: TBaseVirtualTree; Node: PVirtualNode; Column: TColumnIndex;
  TextType: TVSTTextType; var CellText: String);
begin
  CellText := PNodeData(Sender.GetNodeData(Node))^.Caption;
end;

procedure TForm1.TreeInitNode(Sender: TBaseVirtualTree; ParentNode, Node: PVirtualNode;
  var InitialStates: TVirtualNodeInitStates);
var
  d, pd: PNodeData;
begin
  d := Sender.GetNodeData(Node);
  if ParentNode = nil then
  begin
    d^.Kind := FRoots[Node^.Index];
    case d^.Kind of
      1: begin d^.Path := ''; d^.Caption := 'Favorites'; end;
      4: begin d^.Path := ''; d^.Caption := 'Bookmarks'; end;
      2: begin d^.Path := ExcludeTrailingPathDelimiter(GetUserDir); d^.Caption := 'Home'; end;
    else
      begin d^.Path := '/'; d^.Caption := '/'; end;
    end;
  end
  else
  begin
    pd := Sender.GetNodeData(ParentNode);
    d^.Caption := pd^.Kids[Node^.Index];
    if pd^.Kind in [1, 4] then
      d^.Path := pd^.KidPaths[Node^.Index]
    else
      d^.Path := IncludeTrailingPathDelimiter(pd^.Path) + d^.Caption;
  end;
  Include(InitialStates, ivsHasChildren);
end;

procedure TForm1.TreeInitChildren(Sender: TBaseVirtualTree; Node: PVirtualNode; var ChildCount: Cardinal);
var
  d: PNodeData;
  sr: TSearchRec;
  l, names, paths: TStringList;
  i: Integer;
begin
  d := Sender.GetNodeData(Node);
  if d^.Kind in [1, 4] then
  begin
    if d^.Kind = 1 then begin names := FFavNames; paths := FFavPaths; end
    else begin names := FBookNames; paths := FBookPaths; end;
    SetLength(d^.Kids, names.Count);
    SetLength(d^.KidPaths, names.Count);
    for i := 0 to names.Count - 1 do
    begin
      d^.Kids[i] := names[i];
      d^.KidPaths[i] := paths[i];
    end;
    ChildCount := names.Count;
    Exit;
  end;
  l := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(d^.Path) + '*', faDirectory, sr) = 0 then
    try
      repeat
        if ((sr.Attr and faDirectory) <> 0) and (sr.Name <> '.') and (sr.Name <> '..') and
           (sr.Name[1] <> '.') and ((sr.Attr and faSymLink) = 0) then
          l.Add(sr.Name);
      until FindNext(sr) <> 0;
    finally
      FindClose(sr);
    end;
    l.CaseSensitive := False;
    l.Sort;
    SetLength(d^.Kids, l.Count);
    for i := 0 to l.Count - 1 do
      d^.Kids[i] := l[i];
    ChildCount := l.Count;
  finally
    l.Free;
  end;
end;

procedure TForm1.TreeFreeNode(Sender: TBaseVirtualTree; Node: PVirtualNode);
begin
  Finalize(PNodeData(Sender.GetNodeData(Node))^);
end;

procedure TForm1.TreeChange(Sender: TBaseVirtualTree; Node: PVirtualNode);
var
  p: string;
begin
  if Node = nil then
    Exit;
  p := PNodeData(Sender.GetNodeData(Node))^.Path;
  if p <> '' then                   // the "Favorites" header itself has no folder
    LoadFolder(p);
end;

{ Expands the tree down to Path and selects it. }
procedure TForm1.NavigateTo(const Path: string);
var
  tree: TLazVirtualStringTree;
  node, child: PVirtualNode;
  home, rest, part: string;
  parts: TStringArray;
  p: string;
begin
  tree := LazVirtualStringTree1;
  p := ExcludeTrailingPathDelimiter(Path);
  if p = '' then p := '/';
  home := ExcludeTrailingPathDelimiter(GetUserDir);
  if (p = home) or (Pos(home + '/', p) = 1) then
  begin
    node := FindRoot(2);
    rest := Copy(p, Length(home) + 1, MaxInt);
  end
  else
  begin
    node := FindRoot(3);
    rest := p;
  end;
  parts := rest.Split(['/'], TStringSplitOptions.ExcludeEmpty);
  for part in parts do
  begin
    tree.Expanded[node] := True;
    child := tree.GetFirstChild(node);
    while (child <> nil) and (PNodeData(tree.GetNodeData(child))^.Caption <> part) do
      child := tree.GetNextSibling(child);
    if child = nil then
      Break;
    node := child;
  end;
  tree.ClearSelection;
  tree.FocusedNode := node;
  tree.Selected[node] := True;
  tree.ScrollIntoView(node, True);
end;

{ ---------------- folder / file list ---------------- }

procedure TForm1.SortFiles;
var
  entries: TFPList;
  e: PFileEntry;
  i: Integer;
begin
  entries := TFPList.Create;
  try
    for i := 0 to FFiles.Count - 1 do
    begin
      New(e);
      e^.Path := FFiles[i];
      e^.Time := FileAge(FFiles[i]);
      entries.Add(e);
    end;
    if FSortByDate then
    begin
      SortDesc := FDateDesc;
      entries.Sort(@CompareByDate);
    end
    else
    begin
      SortDesc := FNameDesc;
      entries.Sort(@CompareByName);
    end;
    FFiles.Clear;
    for i := 0 to entries.Count - 1 do
    begin
      e := PFileEntry(entries[i]);
      FFiles.Add(e^.Path);
      Dispose(e);
    end;
  finally
    entries.Free;
  end;
end;

procedure TForm1.LoadFolder(const Path: string);
var
  sr: TSearchRec;
  dir: string;
begin
  dir := IncludeTrailingPathDelimiter(Path);
  if dir = FFolder then
    Exit;
  FFolder := dir;
  FFiles.Clear;
  if FindFirst(dir + '*', faAnyFile and not faDirectory, sr) = 0 then
  try
    repeat
      if IsImageFile(sr.Name) then
        FFiles.Add(dir + sr.Name);
    until FindNext(sr) <> 0;
  finally
    FindClose(sr);
  end;
  SortFiles;
  FIndex := -1;
  FCurrentFile := '';
  FThumbs.SetFiles(FFiles);
  if FFiles.Count > 0 then
    FThumbs.Select(0)
  else
  begin
    FView.ShowMessage('No images in this folder');
    ShowExif(nil);
    UpdateStatus;
  end;
end;

procedure TForm1.OrderByNameAscDescClick(Sender: TObject);
var
  cur: string;
begin
  cur := FCurrentFile;
  if FSortByDate then FSortByDate := False else FNameDesc := not FNameDesc;
  SortFiles;
  FThumbs.SetFiles(FFiles);
  FThumbs.SetSelected(FFiles.IndexOf(cur));
  FIndex := FFiles.IndexOf(cur);
  UpdateStatus;
end;

procedure TForm1.OrderByDateAscDescClick(Sender: TObject);
var
  cur: string;
begin
  cur := FCurrentFile;
  if not FSortByDate then FSortByDate := True else FDateDesc := not FDateDesc;
  SortFiles;
  FThumbs.SetFiles(FFiles);
  FThumbs.SetSelected(FFiles.IndexOf(cur));
  FIndex := FFiles.IndexOf(cur);
  UpdateStatus;
end;

{ ---------------- selection / main image ---------------- }

procedure TForm1.SelectIndex(AIndex: Integer);
begin
  if FFiles.Count = 0 then
    Exit;
  AIndex := EnsureRange(AIndex, 0, FFiles.Count - 1);
  if (AIndex = FIndex) and (FFiles[AIndex] = FCurrentFile) then
    Exit;
  FIndex := AIndex;
  FCurrentFile := FFiles[AIndex];
  if FThumbs.SelectedIndex <> AIndex then
    FThumbs.SetSelected(AIndex);
  FView.BeginLoad;
  FMainLoader.Request(FCurrentFile, FView.ClientWidth, FView.ClientHeight);
  UpdateStatus;
end;

procedure TForm1.ThumbSelected(Sender: TObject);
begin
  SelectIndex(FThumbs.SelectedIndex);
end;

procedure TForm1.ThumbProgress(Sender: TObject; Done, Total: Integer);
begin
  ProgressBar1.Max := Max(1, Total);
  ProgressBar1.Position := Done;
  ProgressBar1.Visible := (Done < Total) and Thumbnail.Visible;
end;

procedure TForm1.ViewNavigate(Sender: TObject; Delta: Integer);
begin
  if FFiles.Count = 0 then
    Exit;
  if Delta = -MaxInt then SelectIndex(0)
  else if Delta = MaxInt then SelectIndex(FFiles.Count - 1)
  else SelectIndex(FIndex + Delta);
end;

procedure TForm1.ViewZoomChanged(Sender: TObject);
begin
  FUpdatingZoom := True;
  try
    TrackBar1.Position := EnsureRange(FView.ZoomPercent, TrackBar1.Min, TrackBar1.Max);
    Label3.Caption := 'Zoom ' + IntToStr(FView.ZoomPercent) + '%';
  finally
    FUpdatingZoom := False;
  end;
end;

procedure TForm1.ZoomTrackChange(Sender: TObject);
begin
  if not FUpdatingZoom then
    FView.SetZoomCentered(TrackBar1.Position / 100);
end;

procedure TForm1.ViewNeedResolution(Sender: TObject; BoxW, BoxH: Integer);
begin
  if FCurrentFile = '' then
    Exit;
  if Odd(FView.QuarterTurns) then
    FMainLoader.Request(FCurrentFile, BoxH, BoxW)   // view rotated: the loader sees the file's axes
  else
    FMainLoader.Request(FCurrentFile, BoxW, BoxH);
end;

procedure TForm1.ImageLoaded(Sender: TObject; Img: TLoadedImage);
begin
  try
    if Img.FileName <> FCurrentFile then
      Exit;
    if Img.Pixels = nil then
    begin
      FView.ShowMessage('Cannot load ' + ExtractFileName(Img.FileName) + ': ' + Img.Error);
      ShowExif(nil);
      Exit;
    end;
    FView.SetImage(Img);
    UpdateSaveState;
    if FExifFor <> Img.FileName then
    begin
      FExifFor := Img.FileName;
      ShowExif(Img);
    end;
    UpdateStatus;
  finally
    Img.Free;
  end;
end;

procedure TForm1.UpdateStatus;
begin
  if FIndex < 0 then
    StatusBar1.SimpleText := Format('%d images', [FFiles.Count])
  else
    StatusBar1.SimpleText := Format('%d / %d    %s', [FIndex + 1, FFiles.Count, FCurrentFile]);
end;

{ ---------------- exif panel ---------------- }

procedure TForm1.ShowExif(const Img: TLoadedImage);
var
  a, n: Integer;
  e: TExifData;
  fs: Int64;
  sr: TSearchRec;
begin
  e.Orientation := 1;
  SetLength(e.Names, 0);
  SetLength(e.Values, 0);
  if Img <> nil then
  begin
    ExifAdd(e, 'File', ExtractFileName(Img.FileName));
    ExifAdd(e, 'Path', ExtractFilePath(Img.FileName));
    if FindFirst(Img.FileName, faAnyFile, sr) = 0 then
    begin
      fs := sr.Size;
      ExifAdd(e, 'File size', Format('%.2f MB', [fs / 1048576]));
      ExifAdd(e, 'Modified', FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(sr.Time)));
      FindClose(sr);
    end;
    ExifAdd(e, 'Dimensions', Format('%d x %d', [Img.OrigW, Img.OrigH]));
    n := Length(Img.Exif.Names);
    for a := 0 to n - 1 do
      ExifAdd(e, Img.Exif.Names[a], Img.Exif.Values[a]);
  end;
  properitesName := e.Names;
  properitesExif := e.Values;

  // make sure there are enough controls (they are reused between images)
  n := Length(properitesName);
  while Length(nameCpation) < n do
  begin
    a := Length(nameCpation);
    SetLength(nameCpation, a + 1);
    SetLength(valueCaption, a + 1);
    nameCpation[a] := TLabel.Create(Metadata);
    nameCpation[a].Parent := ExifScrollBox;
    nameCpation[a].Font.Style := [fsBold];
    valueCaption[a] := TEdit.Create(Metadata);
    valueCaption[a].Parent := ExifScrollBox;
    valueCaption[a].ReadOnly := True;
  end;
  for a := 0 to High(nameCpation) do
  begin
    nameCpation[a].Visible := a < n;
    valueCaption[a].Visible := a < n;
    if a < n then
    begin
      nameCpation[a].Caption := properitesName[a];
      valueCaption[a].Text := properitesExif[a];
      valueCaption[a].Hint := properitesExif[a];
      valueCaption[a].ShowHint := True;
    end;
  end;
  ExifScrollBox.VertScrollBar.Position := 0;
  LayoutExif;
end;

procedure TForm1.LayoutExif;
var
  a, y, rowH, labelW, total: Integer;
begin
  if Length(nameCpation) = 0 then
    Exit;
  rowH := valueCaption[0].Height + 4;
  labelW := ExifScrollBox.ClientWidth * 2 div 5;
  y := 2;
  for a := 0 to High(nameCpation) do
    if nameCpation[a].Visible then
    begin
      nameCpation[a].SetBounds(4, y + (valueCaption[a].Height - nameCpation[a].Height) div 2,
        labelW - 6, nameCpation[a].Height);
      valueCaption[a].SetBounds(labelW, y, ExifScrollBox.ClientWidth - labelW - 2, valueCaption[a].Height);
      Inc(y, rowH);
    end;
  total := y;
  ExifScrollBox.VertScrollBar.Range := total;
  ExifScrollBox.VertScrollBar.Page := Max(1, ExifScrollBox.ClientHeight);
  TrackBar2.Max := Max(1, total - ExifScrollBox.ClientHeight);
  TrackBar2.Enabled := total > ExifScrollBox.ClientHeight;
  TrackBar2.Position := ExifScrollBox.VertScrollBar.Position;
end;

procedure TForm1.MetadataResize(Sender: TObject);
begin
  LayoutExif;
end;

procedure TForm1.ExifBarChange(Sender: TObject);
begin
  ExifScrollBox.VertScrollBar.Position := TrackBar2.Position;
end;

procedure TForm1.FormMouseWheel(Sender: TObject; Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint; var Handled: Boolean);
var
  r: TRect;
begin
  // wheel over the Exif panel scrolls it (image and thumbnails handle their own wheel)
  r.TopLeft := Metadata.ClientToScreen(Point(0, 0));
  r.BottomRight := Metadata.ClientToScreen(Point(Metadata.Width, Metadata.Height));
  if Metadata.Visible and PtInRect(r, Mouse.CursorPos) then
  begin
    TrackBar2.Position := EnsureRange(TrackBar2.Position - Sign(WheelDelta) * 30, TrackBar2.Min, TrackBar2.Max);
    Handled := True;
  end;
end;

{ ---------------- rotation / fullscreen ---------------- }

procedure TForm1.RotateCurrent(Clockwise: Boolean);
begin
  if FCurrentFile = '' then
    Exit;
  FView.RotateView(Clockwise);    // the file is changed only by File > Save
  UpdateSaveState;
end;

procedure TForm1.UpdateSaveState;
begin
  MenuItem4.Enabled := (FCurrentFile <> '') and (FView.QuarterTurns <> 0);
end;

procedure TForm1.RotateLeftClick(Sender: TObject);
begin
  RotateCurrent(False);
end;

procedure TForm1.RotateRightClick(Sender: TObject);
begin
  RotateCurrent(True);
end;

procedure TForm1.ViewToggleFullscreen(Sender: TObject);
begin
  Application.QueueAsyncCall(@AsyncToggleFullscreen, 0);   // not while handling the click
end;

procedure TForm1.ViewEscape(Sender: TObject);
begin
  if FFull <> nil then
    Application.QueueAsyncCall(@AsyncToggleFullscreen, 0);
end;

procedure TForm1.AsyncToggleFullscreen(Data: PtrInt);
begin
  if FFull <> nil then
  begin
    FFull.Close;
    Exit;
  end;
  FFull := TForm.CreateNew(Self);
  FFull.BorderStyle := bsNone;
  FFull.Color := clBlack;
  FFull.OnClose := @FullscreenClosed;
  FView.Parent := FFull;
  FView.Align := alClient;
  FView.Color := clBlack;
  FFull.WindowState := wsFullScreen;
  FFull.Show;
  if FView.CanFocus then
    FView.SetFocus;
end;

procedure TForm1.FullscreenClosed(Sender: TObject; var CloseAction: TCloseAction);
begin
  FView.Parent := Image;
  FView.Align := alClient;
  FView.Color := $202020;
  CloseAction := caFree;
  FFull := nil;
  if FView.CanFocus then
    FView.SetFocus;
end;

{ ---------------- file / edit actions ---------------- }

procedure TForm1.ReloadFolder;
var
  cur: string;
  i: Integer;
begin
  cur := FCurrentFile;
  FFolder := '';
  LoadFolder(ExcludeTrailingPathDelimiter(ExtractFilePath(cur)));
  i := FFiles.IndexOf(cur);
  if i > 0 then
    FThumbs.Select(i);
end;

procedure TForm1.MenuFileClick(Sender: TObject);
begin
  UpdateSaveState;
  MenuItem5.Enabled := FFiles.Count > 0;
  MenuItemPrint.Enabled := FFiles.Count > 0;
end;

procedure TForm1.MenuSaveClick(Sender: TObject);
var
  fmts, exts, descs, keys, vals: TStringList;
  ext, fmt, tmp, err: string;
  i: Integer;
  s: TEncSettings;
begin
  if (FCurrentFile = '') or (FView.QuarterTurns = 0) then
    Exit;
  if IsJpegFile(FCurrentFile) then
  begin
    if MessageDlg('Save', 'Apply the rotation to ' + ExtractFileName(FCurrentFile) + '?',
         mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;
    // lossless: only the EXIF orientation of the file is rewritten
    for i := 1 to 1 + Ord(FView.QuarterTurns = 2) do
      if not RotateJpegLossless(FCurrentFile, FView.QuarterTurns <> 3, err) then
      begin
        MessageDlg('Save', 'Cannot save ' + ExtractFileName(FCurrentFile) + ': ' + err, mtError, [mbOK], 0);
        Exit;
      end;
    FExifFor := '';
    FThumbs.ReloadItem(FIndex);
    FView.BeginLoad;
    FMainLoader.Request(FCurrentFile, FView.ClientWidth, FView.ClientHeight);
    UpdateSaveState;
    Exit;
  end;
  fmts := TStringList.Create;
  exts := TStringList.Create;
  descs := TStringList.Create;
  keys := TStringList.Create;
  vals := TStringList.Create;
  try
    PixbufWritableFormats(fmts, exts, descs);
    ext := LowerCase(ExtractFileExt(FCurrentFile));
    if ext = '.tif' then ext := '.tiff';
    i := exts.IndexOf(ext);
    if i < 0 then
    begin
      MessageDlg('Save', 'The format ' + ext + ' cannot be written. Use File > Transcode to save a copy in another format.',
        mtInformation, [mbOK], 0);
      Exit;
    end;
    if MessageDlg('Save', 'Overwrite ' + ExtractFileName(FCurrentFile) + ' with the rotated image?',
         mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
      Exit;
    fmt := fmts[i];
    if fmt = 'webp' then begin keys.Add('quality'); vals.Add('95'); end;
    s.Format := fmt;
    s.Keys := keys;
    s.Values := vals;
    s.Quality := 90;
    s.Subsampling := 2;
    s.Progressive := False;
    s.KeepExif := False;
    tmp := FCurrentFile + '.ttviewer.tmp';
    if TranscodeFile(FCurrentFile, tmp, s, FView.QuarterTurns, err) and RenameFile(tmp, FCurrentFile) then
    begin
      FExifFor := '';
      FThumbs.ReloadItem(FIndex);
      FView.BeginLoad;
      FMainLoader.Request(FCurrentFile, FView.ClientWidth, FView.ClientHeight);
    end
    else
    begin
      DeleteFile(tmp);
      MessageDlg('Save', 'Cannot save: ' + err, mtError, [mbOK], 0);
    end;
  finally
    fmts.Free; exts.Free; descs.Free; keys.Free; vals.Free;
  end;
end;

procedure TForm1.MenuTranscodeClick(Sender: TObject);
var
  files: TStringList;
  dlg: TTranscodeDialog;
  outDir: string;
  n: Integer;
begin
  files := TStringList.Create;
  try
    FThumbs.SelectedFiles(files);
    if files.Count = 0 then
    begin
      ShowMessage('Select one or more images first.');
      Exit;
    end;
    dlg := TTranscodeDialog.CreateDlg(Self, files, FCurrentFile, FView.QuarterTurns);
    try
      CenterOver(dlg, Self);
      dlg.ShowModal;
      n := dlg.Converted;
      outDir := IncludeTrailingPathDelimiter(dlg.OutDir);
    finally
      dlg.Free;
    end;
    if (n > 0) and (outDir = FFolder) then
      ReloadFolder;                 // the new files are in the folder being shown
  finally
    files.Free;
  end;
end;

{ Copies the selected files for pasting into a file manager (and the image for other programs). }
procedure TForm1.MenuCopyClick(Sender: TObject);
var
  files: TStringList;
  uris, plain: string;
  i: Integer;
  ss: TStringStream;
begin
  if (ActiveControl is TCustomEdit) and (TCustomEdit(ActiveControl).SelLength > 0) then
  begin
    TCustomEdit(ActiveControl).CopyToClipboard;
    Exit;
  end;
  files := TStringList.Create;
  try
    FThumbs.SelectedFiles(files);
    if files.Count = 0 then
      Exit;
    uris := '';
    plain := '';
    for i := 0 to files.Count - 1 do
    begin
      uris := uris + 'file://' + StringReplace(files[i], ' ', '%20', [rfReplaceAll]) + #10;
      plain := plain + files[i] + LineEnding;
    end;
    Clipboard.Open;
    try
      Clipboard.Clear;
      ss := TStringStream.Create('copy' + #10 + Copy(uris, 1, Length(uris) - 1));
      try
        Clipboard.AddFormat(RegisterClipboardFormat('x-special/gnome-copied-files'), ss);
      finally
        ss.Free;
      end;
      ss := TStringStream.Create(uris);
      try
        Clipboard.AddFormat(RegisterClipboardFormat('text/uri-list'), ss);
      finally
        ss.Free;
      end;
      ss := TStringStream.Create(plain);
      try
        Clipboard.AddFormat(RegisterClipboardFormat('text/plain'), ss);
      finally
        ss.Free;
      end;
    finally
      Clipboard.Close;
    end;
    StatusBar1.SimpleText := Format('%d file(s) copied', [files.Count]);
  finally
    files.Free;
  end;
end;

procedure TForm1.RemoveFiles(Permanent: Boolean);
var
  files: TStringList;
  removed: array of Integer;
  i, k, firstIdx: Integer;
  ok: Boolean;
  outp: string;
  failed: string;
begin
  files := TStringList.Create;
  try
    FThumbs.SelectedFiles(files);
    if files.Count = 0 then
      Exit;
    if Permanent and (MessageDlg('Delete from disk',
         Format('Permanently delete %d file(s)? This cannot be undone.', [files.Count]),
         mtWarning, [mbYes, mbNo], 0) <> mrYes) then
      Exit;
    SetLength(removed, 0);
    failed := '';
    for i := 0 to files.Count - 1 do
    begin
      if Permanent then
        ok := DeleteFile(files[i])
      else
      begin
        outp := '';
        ok := RunCommand('gio', ['trash', '--', files[i]], outp);
      end;
      if ok then
      begin
        k := FFiles.IndexOf(files[i]);
        if k >= 0 then
        begin
          SetLength(removed, Length(removed) + 1);
          removed[High(removed)] := k;
        end;
      end
      else
        failed := failed + LineEnding + ExtractFileName(files[i]);
    end;
    if Length(removed) > 0 then
    begin
      // ascending order for the thumbnail list
      for i := 0 to High(removed) do
        for k := i + 1 to High(removed) do
          if removed[k] < removed[i] then
          begin
            firstIdx := removed[i]; removed[i] := removed[k]; removed[k] := firstIdx;
          end;
      firstIdx := removed[0];
      for i := High(removed) downto 0 do
        FFiles.Delete(removed[i]);
      FThumbs.RemoveIndices(removed);
      FIndex := -1;
      FCurrentFile := '';
      FExifFor := '';
      if FFiles.Count > 0 then
        FThumbs.Select(Min(firstIdx, FFiles.Count - 1))
      else
      begin
        FView.ShowMessage('No images in this folder');
        ShowExif(nil);
        UpdateStatus;
      end;
    end;
    if failed <> '' then
      MessageDlg('Remove', 'These files could not be removed:' + failed, mtError, [mbOK], 0);
  finally
    files.Free;
  end;
end;

procedure TForm1.MenuBinClick(Sender: TObject);
begin
  RemoveFiles(False);
end;

procedure TForm1.MenuDeleteClick(Sender: TObject);
begin
  RemoveFiles(True);
end;

{ ---------------- menu ---------------- }

procedure TForm1.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  i, k: Integer;
  f: string;
begin
  for i := 0 to High(FileNames) do
  begin
    f := ExpandFileName(FileNames[i]);
    if DirectoryExists(f) then
    begin
      NavigateTo(f);
      Break;
    end;
    if FileExists(f) and IsImageFile(f) then
    begin
      if ExtractFilePath(f) <> IncludeTrailingPathDelimiter(FFolder) then
        NavigateTo(ExtractFilePath(f));
      k := FFiles.IndexOf(f);
      if k >= 0 then
        FThumbs.Select(k);
      Break;
    end;
  end;
  Application.BringToFront;
end;

procedure TForm1.MenuOpenClick(Sender: TObject);
var
  dlg: TOpenDialog;
  i: Integer;
  mask: string;
begin
  dlg := TOpenDialog.Create(Self);
  try
    mask := '';
    for i := 0 to SupportedExtensions.Count - 1 do
      mask := mask + '*' + SupportedExtensions[i] + ';*' + UpperCase(SupportedExtensions[i]) + ';';
    dlg.Filter := 'Images|' + mask + '|All files|*';
    if dlg.Execute then
    begin
      NavigateTo(ExtractFilePath(dlg.FileName));
      i := FFiles.IndexOf(dlg.FileName);
      if i >= 0 then
        FThumbs.Select(i);
    end;
  finally
    dlg.Free;
  end;
end;

procedure TForm1.MenuOpenFolderClick(Sender: TObject);
var
  dlg: TSelectDirectoryDialog;
begin
  dlg := TSelectDirectoryDialog.Create(Self);
  try
    if dlg.Execute then
      NavigateTo(dlg.FileName);
  finally
    dlg.Free;
  end;
end;

procedure TForm1.MenuExitClick(Sender: TObject);
begin
  Close;
end;

end.
