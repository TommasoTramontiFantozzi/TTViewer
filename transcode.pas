unit transcode;

{ Transcode dialog: converts the selected images to another format; every format shows
  its own parameters (quality, progressive, compression level, ...). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, ComCtrls,
  tjpeg, pixbufload, encoders;

type
  TParamKind = (pkInt, pkChoice, pkBool);

  PParamSpec = ^TParamSpec;
  TParamSpec = record
    Key: string;                    // option name (jpeg: quality, subsampling, progressive, keepexif)
    Caption: string;
    Kind: TParamKind;
    Min, Max, Def: Integer;         // pkInt range / default; for choices and bools Def is the default index
    Choices: string;                // pkChoice: 'label=value|label=value'
  end;

  TParamControl = class
  public
    Spec: TParamSpec;
    Lbl: TLabel;
    Ctl: TControl;
    ValueLbl: TLabel;
    Values: TStringList;
    destructor Destroy; override;
  end;

  { TTranscodeDialog }

  TTranscodeDialog = class(TForm)
  private
    FFiles: TStringList;
    FNames, FExts: TStringList;             // formats offered: gdk-pixbuf writers + jpeg
    FFormat: TComboBox;
    FParams: TPanel;
    FCtls: TList;
    FDest: TEdit;
    FOverwrite: TCheckBox;
    FProgress: TProgressBar;
    FStatus: TLabel;
    FGo, FClose: TButton;
    FCancel: Boolean;
    FBusy: Boolean;
    FCurrentFile: string;
    FCurrentQuarter: Integer;
    FConverted: Integer;
    procedure FormatChanged(Sender: TObject);
    procedure BuildParams;
    procedure TrackChanged(Sender: TObject);
    procedure BrowseClick(Sender: TObject);
    procedure GoClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure ClearCtls;
    function CurrentName: string;
    function CurrentExt: string;
    procedure CollectSettings(var S: TEncSettings);
    function UniqueName(const Dir, Base, Ext, Src: string): string;
    procedure DialogClosing(Sender: TObject; var CloseAction: TCloseAction);
  public
    constructor CreateDlg(AOwner: TComponent; Files: TStrings; const ACurrentFile: string;
      ACurrentQuarter: Integer);
    destructor Destroy; override;
    { Folder the files were written to (valid when Converted > 0). }
    function OutDir: string;
    property Converted: Integer read FConverted;
  end;

implementation

destructor TParamControl.Destroy;
begin
  Values.Free;
  inherited Destroy;
end;

function MakeSpec(const AKey, ACaption: string; AKind: TParamKind; AMin, AMax, ADef: Integer;
  const AChoices: string = ''): TParamSpec;
begin
  Result.Key := AKey;
  Result.Caption := ACaption;
  Result.Kind := AKind;
  Result.Min := AMin;
  Result.Max := AMax;
  Result.Def := ADef;
  Result.Choices := AChoices;
end;

{ The parameters typical of each format; the caller frees the records. }
function SpecsFor(const Fmt: string): TList;

  procedure Add(const S: TParamSpec);
  var
    p: PParamSpec;
  begin
    New(p);
    p^ := S;
    Result.Add(p);
  end;

begin
  Result := TList.Create;
  if Fmt = 'jpeg' then
  begin
    Add(MakeSpec('quality', 'Quality (1-100)', pkInt, 1, 100, 90));
    Add(MakeSpec('subsampling', 'Chroma subsampling', pkChoice, 0, 0, 2,
      '4:4:4 (best)=0|4:2:2=1|4:2:0 (smallest)=2|4:4:0=4|Grayscale=3'));
    Add(MakeSpec('progressive', 'Progressive', pkBool, 0, 1, 0));
    Add(MakeSpec('keepexif', 'Keep EXIF metadata', pkBool, 0, 1, 1));
  end
  else if Fmt = 'png' then
    Add(MakeSpec('compression', 'Compression level (0-9)', pkInt, 0, 9, 6))
  else if Fmt = 'tiff' then
    Add(MakeSpec('compression', 'Compression', pkChoice, 0, 0, 1,
      'None=1|LZW=5|Deflate=8|PackBits=32773'))
  else if Fmt = 'webp' then
  begin
    Add(MakeSpec('quality', 'Quality (0-100)', pkInt, 0, 100, 90));
    Add(MakeSpec('preset', 'Preset', pkChoice, 0, 0, 0,
      'Default=default|Picture=picture|Photo=photo|Drawing=drawing|Icon=icon|Text=text'));
    Add(MakeSpec('lossless', 'Lossless', pkBool, 0, 1, 0));
  end;
  // bmp, ico, ...: no parameters
end;

function DisplayName(const N: string): string;
begin
  if N = 'webp' then Result := 'WebP'
  else if N = 'jpeg' then Result := 'JPEG (libjpeg-turbo)'
  else Result := UpperCase(N);
end;

{ ---------------- dialog ---------------- }

constructor TTranscodeDialog.CreateDlg(AOwner: TComponent; Files: TStrings;
  const ACurrentFile: string; ACurrentQuarter: Integer);
var
  lbl: TLabel;
  b: TButton;
  i, k: Integer;
  names, exts, descs: TStringList;
begin
  inherited CreateNew(AOwner);
  if AOwner is TCustomForm then
  begin
    PopupMode := pmExplicit;
    PopupParent := TCustomForm(AOwner);
    ShowInTaskBar := stNever;
  end;
  Caption := 'Transcode';
  BorderStyle := bsDialog;
  Position := poOwnerFormCenter;
  ClientWidth := 560;
  ClientHeight := 470;
  OnClose := @DialogClosing;
  FCtls := TList.Create;
  FFiles := TStringList.Create;
  FFiles.Assign(Files);
  FCurrentFile := ACurrentFile;
  FCurrentQuarter := ACurrentQuarter;

  // formats: JPEG first, then the gdk-pixbuf writers
  FNames := TStringList.Create;
  FExts := TStringList.Create;
  FNames.Add('jpeg');
  FExts.Add('.jpg');
  names := TStringList.Create;
  exts := TStringList.Create;
  descs := TStringList.Create;
  try
    PixbufWritableFormats(names, exts, descs);
    for i := 0 to names.Count - 1 do
      if names[i] <> 'jpeg' then
      begin
        FNames.Add(names[i]);
        if names[i] = 'tiff' then FExts.Add('.tif') else FExts.Add(exts[i]);
      end;
  finally
    names.Free;
    exts.Free;
    descs.Free;
  end;

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(12, 12, 536, 20);
  if FFiles.Count = 1 then
    lbl.Caption := ExtractFileName(FFiles[0])
  else
    lbl.Caption := IntToStr(FFiles.Count) + ' images';
  lbl.Font.Style := [fsBold];

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(12, 46, 80, 20);
  lbl.Caption := 'Format';
  FFormat := TComboBox.Create(Self);
  FFormat.Parent := Self;
  FFormat.Style := csDropDownList;
  FFormat.SetBounds(100, 42, 250, 28);
  for i := 0 to FNames.Count - 1 do
    FFormat.Items.Add(DisplayName(FNames[i]));
  FFormat.ItemIndex := 0;
  // start from a format different from the first file's one
  if (FFiles.Count > 0) and IsJpegFile(FFiles[0]) and (FNames.Count > 1) then
  begin
    k := FNames.IndexOf('png');
    if k >= 0 then FFormat.ItemIndex := k;
  end;
  FFormat.OnChange := @FormatChanged;

  FParams := TPanel.Create(Self);
  FParams.Parent := Self;
  FParams.SetBounds(12, 84, 536, 176);
  FParams.BevelOuter := bvLowered;

  lbl := TLabel.Create(Self);
  lbl.Parent := Self;
  lbl.SetBounds(12, 278, 80, 20);
  lbl.Caption := 'Save in';
  FDest := TEdit.Create(Self);
  FDest.Parent := Self;
  FDest.SetBounds(100, 274, 350, 28);
  if FFiles.Count > 0 then
    FDest.Text := ExcludeTrailingPathDelimiter(ExtractFilePath(FFiles[0]));
  b := TButton.Create(Self);
  b.Parent := Self;
  b.SetBounds(458, 274, 90, 28);
  b.Caption := 'Browse...';
  b.OnClick := @BrowseClick;

  FOverwrite := TCheckBox.Create(Self);
  FOverwrite.Parent := Self;
  FOverwrite.SetBounds(100, 314, 440, 24);
  FOverwrite.Caption := 'Overwrite existing files (otherwise a number is added to the name)';

  FProgress := TProgressBar.Create(Self);
  FProgress.Parent := Self;
  FProgress.SetBounds(12, 366, 536, 18);
  FStatus := TLabel.Create(Self);
  FStatus.Parent := Self;
  FStatus.SetBounds(12, 392, 536, 20);

  FClose := TButton.Create(Self);
  FClose.Parent := Self;
  FClose.SetBounds(448, 426, 100, 30);
  FClose.Caption := 'Close';
  FClose.OnClick := @CloseClick;
  FGo := TButton.Create(Self);
  FGo.Parent := Self;
  FGo.SetBounds(338, 426, 100, 30);
  FGo.Caption := 'Transcode';
  FGo.Default := True;
  FGo.OnClick := @GoClick;

  BuildParams;
end;

destructor TTranscodeDialog.Destroy;
begin
  ClearCtls;
  FCtls.Free;
  FFiles.Free;
  FNames.Free;
  FExts.Free;
  inherited Destroy;
end;

procedure TTranscodeDialog.ClearCtls;
var
  i: Integer;
  c: TParamControl;
begin
  for i := 0 to FCtls.Count - 1 do
  begin
    c := TParamControl(FCtls[i]);
    c.Lbl.Free;
    c.Ctl.Free;
    c.ValueLbl.Free;
    c.Free;
  end;
  FCtls.Clear;
end;

function TTranscodeDialog.CurrentName: string;
begin
  Result := FNames[FFormat.ItemIndex];
end;

function TTranscodeDialog.CurrentExt: string;
begin
  Result := FExts[FFormat.ItemIndex];
end;

function TTranscodeDialog.OutDir: string;
begin
  Result := FDest.Text;
end;

procedure TTranscodeDialog.FormatChanged(Sender: TObject);
begin
  BuildParams;
end;

procedure TTranscodeDialog.BuildParams;
var
  specs: TList;
  i, k, y: Integer;
  sp: TParamSpec;
  pc: TParamControl;
  tb: TTrackBar;
  cb: TComboBox;
  ck: TCheckBox;
  parts, kv: TStringArray;
  nolbl: TLabel;
begin
  ClearCtls;
  specs := SpecsFor(CurrentName);
  try
    y := 14;
    if specs.Count = 0 then
    begin
      nolbl := TLabel.Create(Self);
      nolbl.Parent := FParams;
      nolbl.SetBounds(14, 14, 500, 20);
      nolbl.Caption := 'This format has no parameters.';
      pc := TParamControl.Create;
      pc.Lbl := nolbl;
      pc.Ctl := TLabel.Create(Self);
      pc.Ctl.Parent := FParams;
      pc.ValueLbl := TLabel.Create(Self);
      pc.ValueLbl.Parent := FParams;
      pc.Values := TStringList.Create;
      pc.Spec.Kind := pkBool;
      pc.Spec.Key := '';
      FCtls.Add(pc);
    end;
    for i := 0 to specs.Count - 1 do
    begin
      sp := PParamSpec(specs[i])^;
      pc := TParamControl.Create;
      pc.Spec := sp;
      pc.Values := TStringList.Create;
      pc.Lbl := TLabel.Create(Self);
      pc.Lbl.Parent := FParams;
      pc.ValueLbl := TLabel.Create(Self);
      pc.ValueLbl.Parent := FParams;
      case sp.Kind of
        pkInt:
          begin
            pc.Lbl.SetBounds(14, y + 4, 190, 20);
            pc.Lbl.Caption := sp.Caption;
            tb := TTrackBar.Create(Self);
            tb.Parent := FParams;
            tb.SetBounds(208, y - 2, 260, 32);
            tb.Min := sp.Min;
            tb.Max := sp.Max;
            tb.Position := sp.Def;
            tb.TickStyle := tsNone;
            tb.Tag := FCtls.Count;
            tb.OnChange := @TrackChanged;
            pc.Ctl := tb;
            pc.ValueLbl.SetBounds(476, y + 4, 50, 20);
            pc.ValueLbl.Caption := IntToStr(sp.Def);
          end;
        pkChoice:
          begin
            pc.Lbl.SetBounds(14, y + 4, 190, 20);
            pc.Lbl.Caption := sp.Caption;
            cb := TComboBox.Create(Self);
            cb.Parent := FParams;
            cb.Style := csDropDownList;
            cb.SetBounds(208, y, 260, 28);
            parts := sp.Choices.Split(['|']);
            for k := 0 to High(parts) do
            begin
              kv := parts[k].Split(['=']);
              cb.Items.Add(kv[0]);
              pc.Values.Add(kv[1]);
            end;
            cb.ItemIndex := sp.Def;
            pc.Ctl := cb;
          end;
      else
        begin
          pc.Lbl.Caption := '';
          ck := TCheckBox.Create(Self);
          ck.Parent := FParams;
          ck.SetBounds(14, y + 2, 400, 24);
          ck.Caption := sp.Caption;
          ck.Checked := sp.Def = 1;
          pc.Ctl := ck;
        end;
      end;
      FCtls.Add(pc);
      Inc(y, 38);
    end;
  finally
    for i := 0 to specs.Count - 1 do
      Dispose(PParamSpec(specs[i]));
    specs.Free;
  end;
end;

procedure TTranscodeDialog.TrackChanged(Sender: TObject);
var
  pc: TParamControl;
begin
  pc := TParamControl(FCtls[TControl(Sender).Tag]);
  pc.ValueLbl.Caption := IntToStr((Sender as TTrackBar).Position);
end;

procedure TTranscodeDialog.BrowseClick(Sender: TObject);
var
  d: TSelectDirectoryDialog;
begin
  d := TSelectDirectoryDialog.Create(Self);
  try
    d.InitialDir := FDest.Text;
    if d.Execute then
      FDest.Text := d.FileName;
  finally
    d.Free;
  end;
end;

procedure TTranscodeDialog.CollectSettings(var S: TEncSettings);
var
  i: Integer;
  pc: TParamControl;
  v: string;
begin
  S.Format := CurrentName;
  S.Quality := 90;
  S.Subsampling := TJSAMP_420;
  S.Progressive := False;
  S.KeepExif := True;
  S.Keys.Clear;
  S.Values.Clear;
  for i := 0 to FCtls.Count - 1 do
  begin
    pc := TParamControl(FCtls[i]);
    if pc.Spec.Key = '' then
      Continue;
    case pc.Spec.Kind of
      pkInt: v := IntToStr((pc.Ctl as TTrackBar).Position);
      pkChoice: v := pc.Values[(pc.Ctl as TComboBox).ItemIndex];
    else
      if (pc.Ctl as TCheckBox).Checked then v := '1' else v := '0';
    end;
    if S.Format = 'jpeg' then
    begin
      if pc.Spec.Key = 'quality' then S.Quality := StrToInt(v)
      else if pc.Spec.Key = 'subsampling' then S.Subsampling := StrToInt(v)
      else if pc.Spec.Key = 'progressive' then S.Progressive := v = '1'
      else if pc.Spec.Key = 'keepexif' then S.KeepExif := v = '1';
    end
    else if (pc.Spec.Kind <> pkBool) or (v = '1') then
    begin
      S.Keys.Add(pc.Spec.Key);
      S.Values.Add(v);
    end;
  end;
end;

{ Never overwrites the source; overwrites other files only when asked to. }
function TTranscodeDialog.UniqueName(const Dir, Base, Ext, Src: string): string;
var
  n: Integer;
begin
  Result := IncludeTrailingPathDelimiter(Dir) + Base + Ext;
  n := 0;
  while (SameFileName(ExpandFileName(Result), ExpandFileName(Src))) or
        (FileExists(Result) and not FOverwrite.Checked) do
  begin
    Inc(n);
    Result := IncludeTrailingPathDelimiter(Dir) + Base + '_' + IntToStr(n) + Ext;
  end;
end;

procedure TTranscodeDialog.GoClick(Sender: TObject);
var
  s: TEncSettings;
  i, failed, q: Integer;
  dest, err, errors: string;
begin
  if not DirectoryExists(FDest.Text) then
  begin
    MessageDlg('Transcode', 'The destination folder does not exist.', mtError, [mbOK], 0);
    Exit;
  end;
  s.Keys := TStringList.Create;
  s.Values := TStringList.Create;
  FBusy := True;
  FCancel := False;
  FGo.Enabled := False;
  FFormat.Enabled := False;
  FClose.Caption := 'Stop';
  FProgress.Max := FFiles.Count;
  FProgress.Position := 0;
  failed := 0;
  errors := '';
  FConverted := 0;
  try
    CollectSettings(s);
    for i := 0 to FFiles.Count - 1 do
    begin
      if FCancel then Break;
      FStatus.Caption := ExtractFileName(FFiles[i]);
      Application.ProcessMessages;
      dest := UniqueName(FDest.Text, ChangeFileExt(ExtractFileName(FFiles[i]), ''), CurrentExt, FFiles[i]);
      q := 0;
      if SameFileName(FFiles[i], FCurrentFile) and not IsJpegFile(FFiles[i]) then
        q := FCurrentQuarter;       // rotation applied in the viewer but not saved yet
      if TranscodeFile(FFiles[i], dest, s, q, err) then
        Inc(FConverted)
      else
      begin
        Inc(failed);
        if failed <= 4 then
          errors := errors + LineEnding + ExtractFileName(FFiles[i]) + ': ' + err;
      end;
      FProgress.Position := i + 1;
    end;
  finally
    s.Keys.Free;
    s.Values.Free;
    FBusy := False;
    FGo.Enabled := True;
    FFormat.Enabled := True;
    FClose.Caption := 'Close';
  end;
  FStatus.Caption := Format('%d converted, %d failed', [FConverted, failed]);
  if failed > 0 then
    MessageDlg('Transcode', Format('%d file(s) could not be converted:', [failed]) + errors, mtWarning, [mbOK], 0);
end;

procedure TTranscodeDialog.CloseClick(Sender: TObject);
begin
  if FBusy then
    FCancel := True
  else
    Close;
end;

procedure TTranscodeDialog.DialogClosing(Sender: TObject; var CloseAction: TCloseAction);
begin
  if FBusy then
  begin
    FCancel := True;
    CloseAction := caNone;
  end;
end;

end.
