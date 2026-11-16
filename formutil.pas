unit formutil;

{ Window placement helper. }

{$mode objfpc}{$H+}

interface

uses
  Classes, Forms;

{ Centers AForm over AParent (the window that opened it), kept inside the work area. }
procedure CenterOver(AForm, AParent: TCustomForm);

implementation

uses
  Math;

procedure CenterOver(AForm, AParent: TCustomForm);
var
  wa: TRect;
begin
  if (AForm = nil) or (AParent = nil) then Exit;
  wa := Screen.MonitorFromWindow(AParent.Handle).WorkareaRect;
  AForm.Position := poDesigned;
  AForm.Left := Max(wa.Left, Min(wa.Right - AForm.Width,
    AParent.Left + (AParent.Width - AForm.Width) div 2));
  AForm.Top := Max(wa.Top, Min(wa.Bottom - AForm.Height,
    AParent.Top + (AParent.Height - AForm.Height) div 2));
end;

end.
