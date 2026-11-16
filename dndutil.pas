unit dndutil;

{$mode objfpc}{$H+}

{ Starts a GTK2 drag-and-drop of files (text/uri-list, copy action) out of a
  control, so a file manager or the desktop receives copies of them. }

interface

uses
  Classes, SysUtils, Controls, glib2, gdk2, gtk2;

{ Call from a mouse-move handler while the left button is held down. }
function BeginFileDrag(AControl: TWinControl; Files: TStrings): Boolean;

implementation

var
  DragFiles: TStringList = nil;
  DataGetId: gulong = 0;
  EndId: gulong = 0;
  DragWidget: PGtkWidget = nil;

procedure DragDataGet(Widget: PGtkWidget; Context: PGdkDragContext;
  Data: PGtkSelectionData; Info, Time: guint; UserData: gpointer); cdecl;
var
  uris: array of Pgchar;
  i, n: Integer;
begin
  if DragFiles = nil then
    Exit;
  SetLength(uris, DragFiles.Count + 1);
  n := 0;
  for i := 0 to DragFiles.Count - 1 do
  begin
    uris[n] := g_filename_to_uri(PChar(DragFiles[i]), nil, nil);
    if uris[n] <> nil then
      Inc(n);
  end;
  uris[n] := nil;
  gtk_selection_data_set_uris(Data, @uris[0]);
  for i := 0 to n - 1 do
    g_free(uris[i]);
end;

procedure DragEnded(Widget: PGtkWidget; Context: PGdkDragContext; UserData: gpointer); cdecl;
begin
  if DragWidget <> nil then
  begin
    g_signal_handler_disconnect(DragWidget, DataGetId);
    g_signal_handler_disconnect(DragWidget, EndId);
    DragWidget := nil;
  end;
  FreeAndNil(DragFiles);
end;

function BeginFileDrag(AControl: TWinControl; Files: TStrings): Boolean;
var
  target: TGtkTargetEntry;
  tl: PGtkTargetList;
  ev: PGdkEvent;
  w: PGtkWidget;
  ctx: PGdkDragContext;
begin
  Result := False;
  if (DragWidget <> nil) or (Files.Count = 0) or not AControl.HandleAllocated then
    Exit;
  w := PGtkWidget(AControl.Handle);
  ev := gtk_get_current_event;
  if ev = nil then
    Exit;
  DragFiles := TStringList.Create;
  DragFiles.Assign(Files);
  DragWidget := w;
  DataGetId := g_signal_connect(w, 'drag-data-get', TGCallback(@DragDataGet), nil);
  EndId := g_signal_connect(w, 'drag-end', TGCallback(@DragEnded), nil);
  target.target := 'text/uri-list';
  target.flags := 0;
  target.info := 0;
  tl := gtk_target_list_new(@target, 1);
  ctx := gtk_drag_begin(w, tl, GDK_ACTION_COPY, 1, ev);
  gtk_target_list_unref(tl);
  gdk_event_free(ev);
  Result := ctx <> nil;
  if not Result then
    DragEnded(w, nil, nil);
end;

end.
