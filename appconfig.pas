unit appconfig;

{$mode objfpc}{$H+}

{ Optional configuration file (ttviewer.ini): next to the executable when that
  folder is writable, otherwise in ~/.local/share/. }

interface

uses
  Classes, SysUtils, IniFiles, Forms, Controls, StdCtrls, ExtCtrls, Dialogs, formutil;

const
  ConfigName = 'ttviewer.ini';

{ Path of an existing config file, '' when there is none. }
function FindConfigFile: string;
{ Creates a config file with the default options; Err is set on failure. }
function CreateConfigFile(out Path, Err: string): Boolean;
procedure ReadOptions(const Path: string; out SaveLayout, SaveLastPos, WheelZoom: Boolean);
procedure WriteOptions(const Path: string; SaveLayout, SaveLastPos, WheelZoom: Boolean);

{ Settings dialog. Returns True when OK was pressed; Deleted is set when the
  user removed the config file. }
function EditSettings(const Path: string; var SaveLayout, SaveLastPos, WheelZoom: Boolean;
  out Deleted: Boolean): Boolean;

implementation

function ExeDirFile: string;
begin
  Result := ExtractFilePath(ExpandFileName(ParamStr(0))) + ConfigName;
end;

function HomeFile: string;
begin
  Result := IncludeTrailingPathDelimiter(GetUserDir) + '.local/share/' + ConfigName;
end;

function FindConfigFile: string;
begin
  if FileExists(ExeDirFile) then
    Result := ExeDirFile
  else if FileExists(HomeFile) then
    Result := HomeFile
  else
    Result := '';
end;

function TryWrite(const Path: string; out Err: string): Boolean;
begin
  Result := False;
  try
    ForceDirectories(ExtractFilePath(Path));
    WriteOptions(Path, True, True, False);
    Result := FileExists(Path);
    if not Result then
      Err := 'the file was not created';
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

function CreateConfigFile(out Path, Err: string): Boolean;
var
  e1, e2: string;
begin
  e1 := '';
  e2 := '';
  Path := ExeDirFile;
  Result := TryWrite(Path, e1);
  if Result then
    Exit;
  Path := HomeFile;
  Result := TryWrite(Path, e2);
  if not Result then
  begin
    Path := '';
    Err := ExeDirFile + ': ' + e1 + LineEnding + HomeFile + ': ' + e2;
  end;
end;

procedure ReadOptions(const Path: string; out SaveLayout, SaveLastPos, WheelZoom: Boolean);
var
  ini: TIniFile;
begin
  SaveLayout := True;
  SaveLastPos := True;
  WheelZoom := False;
  try
    ini := TIniFile.Create(Path);
    try
      SaveLayout := ini.ReadBool('General', 'SaveLayout', True);
      SaveLastPos := ini.ReadBool('General', 'SaveLastPosition', True);
      WheelZoom := ini.ReadBool('General', 'WheelZoom', False);
    finally
      ini.Free;
    end;
  except
  end;
end;

procedure WriteOptions(const Path: string; SaveLayout, SaveLastPos, WheelZoom: Boolean);
var
  ini: TIniFile;
begin
  ini := TIniFile.Create(Path);
  try
    ini.WriteBool('General', 'SaveLayout', SaveLayout);
    ini.WriteBool('General', 'SaveLastPosition', SaveLastPos);
    ini.WriteBool('General', 'WheelZoom', WheelZoom);
    if not SaveLayout then
      ini.EraseSection('Layout');
    if not SaveLastPos then
      ini.EraseSection('Last');
  finally
    ini.Free;
  end;
end;

function EditSettings(const Path: string; var SaveLayout, SaveLastPos, WheelZoom: Boolean;
  out Deleted: Boolean): Boolean;
var
  f: TForm;
  cbL, cbP: TCheckBox;
  rg: TRadioGroup;
  lb: TLabel;
  bOk, bCancel, bDel: TButton;
  r: Integer;
begin
  Deleted := False;
  Result := False;
  f := TForm.CreateNew(Application);
  try
    if Application.MainForm <> nil then
    begin
      f.PopupMode := pmExplicit;
      f.PopupParent := Application.MainForm;
      f.ShowInTaskBar := stNever;
    end;
    f.Caption := 'Settings';
    f.Position := poOwnerFormCenter;
    f.BorderStyle := bsDialog;
    f.ClientWidth := 480;
    f.ClientHeight := 250;

    cbL := TCheckBox.Create(f);
    cbL.Parent := f;
    cbL.SetBounds(16, 16, 440, 24);
    cbL.Caption := 'Save the window layout (size, position, panels)';
    cbL.Checked := SaveLayout;

    cbP := TCheckBox.Create(f);
    cbP.Parent := f;
    cbP.SetBounds(16, 48, 440, 24);
    cbP.Caption := 'Save the last opened position (folder and image)';
    cbP.Checked := SaveLastPos;

    rg := TRadioGroup.Create(f);
    rg.Parent := f;
    rg.SetBounds(16, 84, 448, 76);
    rg.Caption := 'Mouse wheel';
    rg.Items.Add('Scroll through the photos');
    rg.Items.Add('Zoom (arrows at the photo edges scroll the photos)');
    rg.ItemIndex := Ord(WheelZoom);

    lb := TLabel.Create(f);
    lb.Parent := f;
    lb.SetBounds(16, 168, 448, 20);
    lb.AutoSize := False;
    if Length(Path) > 52 then
      lb.Caption := 'Config file: ...' + Copy(Path, Length(Path) - 48, 49)
    else
      lb.Caption := 'Config file: ' + Path;
    lb.ShowHint := True;
    lb.Hint := Path;

    bDel := TButton.Create(f);
    bDel.Parent := f;
    bDel.SetBounds(16, 204, 170, 30);
    bDel.Caption := 'Delete config file';
    bDel.ModalResult := mrAbort;

    bOk := TButton.Create(f);
    bOk.Parent := f;
    bOk.SetBounds(296, 204, 80, 30);
    bOk.Caption := 'OK';
    bOk.ModalResult := mrOk;
    bOk.Default := True;

    bCancel := TButton.Create(f);
    bCancel.Parent := f;
    bCancel.SetBounds(384, 204, 80, 30);
    bCancel.Caption := 'Cancel';
    bCancel.ModalResult := mrCancel;
    bCancel.Cancel := True;

    CenterOver(f, Application.MainForm);
    r := f.ShowModal;
    if r = mrOk then
    begin
      SaveLayout := cbL.Checked;
      SaveLastPos := cbP.Checked;
      WheelZoom := rg.ItemIndex = 1;
      Result := True;
    end
    else if r = mrAbort then
    begin
      if MessageDlg('Settings', 'Delete the configuration file?' + LineEnding + Path,
           mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      begin
        if DeleteFile(Path) then
        begin
          Deleted := True;
          Result := True;
        end
        else
          MessageDlg('Settings', 'Cannot delete ' + Path, mtError, [mbOK], 0);
      end;
    end;
  finally
    f.Free;
  end;
end;

end.
