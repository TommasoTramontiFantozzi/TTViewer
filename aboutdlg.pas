unit aboutdlg;

{ Help > About: author, credits and the text of the GPL 3. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Graphics;

procedure ShowAbout(AParent: TCustomForm);

implementation

uses
  formutil, gplv3text;

procedure ShowAbout(AParent: TCustomForm);
var
  f: TForm;
  l: TLabel;
  m: TMemo;
  b: TButton;
  i: Integer;
  s: TStringList;

  procedure Line(Y: Integer; const ACaption, AValue: string);
  begin
    l := TLabel.Create(f);
    l.Parent := f;
    l.SetBounds(16, Y, 120, 20);
    l.Caption := ACaption;
    l.Font.Style := [fsBold];
    l := TLabel.Create(f);
    l.Parent := f;
    l.SetBounds(140, Y, 440, 20);
    l.Caption := AValue;
  end;

begin
  f := TForm.CreateNew(Application);
  try
    f.Caption := 'About TTViewer';
    f.BorderStyle := bsDialog;
    if AParent <> nil then
    begin
      f.PopupMode := pmExplicit;
      f.PopupParent := AParent;
    end;
    f.ShowInTaskBar := stNever;
    f.ClientWidth := 700;
    f.ClientHeight := 520;
    Line(14, 'Author:', 'Tommaso Tramonti Fantozzi');
    Line(38, 'Vibe coded with:', 'Claude Sonnet 5.5');
    Line(62, 'License:', 'GPL 3.0');
    m := TMemo.Create(f);
    m.Parent := f;
    m.SetBounds(16, 96, 668, 372);
    m.ReadOnly := True;
    m.ScrollBars := ssAutoBoth;
    m.WordWrap := False;
    m.Font.Name := 'Monospace';
    s := TStringList.Create;
    try
      for i := 0 to GplLineCount - 1 do
        s.Add(GplText[i]);
      m.Lines.Assign(s);
    finally
      s.Free;
    end;
    b := TButton.Create(f);
    b.Parent := f;
    b.SetBounds(604, 480, 80, 28);
    b.Caption := 'Close';
    b.ModalResult := mrCancel;
    b.Default := True;
    b.Cancel := True;
    CenterOver(f, AParent);
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
