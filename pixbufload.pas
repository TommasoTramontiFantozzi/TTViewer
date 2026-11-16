unit pixbufload;

{ Decoding of every non-JPEG format through the system's gdk-pixbuf (the library the
  desktop itself uses, with all the loaders installed: PNG, GIF, BMP, TIFF, WebP, HEIC,
  AVIF, ICO, SVG, ...). Bound dynamically, no Lazarus graphic classes involved. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DynLibs, jpegworkers;

{ True when gdk-pixbuf could be loaded (otherwise only JPEG is supported). }
function PixbufInit: Boolean;

{ Extensions (lower case, with the dot) of every supported format, JPEG included. }
function SupportedExtensions: TStringList;

function IsJpegFile(const FileName: string): Boolean;
function IsImageFile(const FileName: string): Boolean;

{ Like PixbufDecode but keeps the transparency: RGBA byte order. }
function PixbufLoadRGBA(const FileName: string; out Pix: TPixelBuffer; out HasAlpha: Boolean;
  out Err: string): Boolean;

{ Formats gdk-pixbuf can write: name (e.g. 'png'), first extension and description. }
procedure PixbufWritableFormats(Names, Exts, Descs: TStrings);

{ Pixels in RGBA byte order; Keys/Values are the format options (e.g. compression=6). }
function PixbufSaveRGBA(Pix: TPixelBuffer; HasAlpha: Boolean; const FileName, FormatName: string;
  Keys, Values: TStrings; out Err: string): Boolean;

{ Decodes FileName to BGRX pixels with the embedded orientation applied. }
function PixbufDecode(const FileName: string; out Pix: TPixelBuffer; out Err: string): Boolean;

implementation

type
  PGSList = ^TGSList;
  TGSList = record
    Data: Pointer;
    Next: PGSList;
  end;
  PGError = ^TGError;
  TGError = record
    Domain: Cardinal;
    Code: Integer;
    Message: PChar;
  end;

var
  LibPb, LibGo, LibGl: TLibHandle;
  Inited: Boolean;
  Exts: TStringList;
  gdk_pixbuf_new_from_file: function(Filename: PChar; Error: PGError): Pointer; cdecl;
  gdk_pixbuf_apply_embedded_orientation: function(Pixbuf: Pointer): Pointer; cdecl;
  gdk_pixbuf_get_width: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_height: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_rowstride: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_n_channels: function(Pixbuf: Pointer): Integer; cdecl;
  gdk_pixbuf_get_pixels: function(Pixbuf: Pointer): PByte; cdecl;
  gdk_pixbuf_get_formats: function: PGSList; cdecl;
  gdk_pixbuf_format_get_extensions: function(Format: Pointer): PPChar; cdecl;
  g_object_unref: procedure(Obj: Pointer); cdecl;
  g_error_free: procedure(Error: PGError); cdecl;
  g_strfreev: procedure(Strv: PPChar); cdecl;
  g_slist_free: procedure(List: PGSList); cdecl;
  g_free: procedure(P: Pointer); cdecl;
  gdk_pixbuf_get_has_alpha: function(Pixbuf: Pointer): LongBool; cdecl;
  gdk_pixbuf_new_from_data: function(Data: PByte; Colorspace: Integer; HasAlpha: LongBool; Bits, W, H, Rowstride: Integer;
    DestroyFn, DestroyData: Pointer): Pointer; cdecl;
  gdk_pixbuf_savev: function(Pixbuf: Pointer; Filename, AType: PChar; Keys, Values: PPChar; Error: PGError): LongBool; cdecl;
  gdk_pixbuf_format_is_writable: function(Format: Pointer): LongBool; cdecl;
  gdk_pixbuf_format_get_name: function(Format: Pointer): PChar; cdecl;
  gdk_pixbuf_format_get_description: function(Format: Pointer): PChar; cdecl;

function Sym(Lib: TLibHandle; const Name: string): Pointer;
begin
  Result := GetProcedureAddress(Lib, Name);
end;

function PixbufInit: Boolean;
var
  l, p: PGSList;
  e, q: PPChar;
begin
  if Inited then
    Exit(Assigned(gdk_pixbuf_new_from_file));
  Inited := True;
  Exts := TStringList.Create;
  Exts.Sorted := True;
  Exts.Duplicates := dupIgnore;
  Exts.Add('.jpg');
  Exts.Add('.jpeg');
  Exts.Add('.jpe');
  LibPb := LoadLibrary('libgdk_pixbuf-2.0.so.0');
  LibGo := LoadLibrary('libgobject-2.0.so.0');
  LibGl := LoadLibrary('libglib-2.0.so.0');
  if (LibPb = NilHandle) or (LibGo = NilHandle) or (LibGl = NilHandle) then
    Exit(False);
  Pointer(gdk_pixbuf_new_from_file) := Sym(LibPb, 'gdk_pixbuf_new_from_file');
  Pointer(gdk_pixbuf_apply_embedded_orientation) := Sym(LibPb, 'gdk_pixbuf_apply_embedded_orientation');
  Pointer(gdk_pixbuf_get_width) := Sym(LibPb, 'gdk_pixbuf_get_width');
  Pointer(gdk_pixbuf_get_height) := Sym(LibPb, 'gdk_pixbuf_get_height');
  Pointer(gdk_pixbuf_get_rowstride) := Sym(LibPb, 'gdk_pixbuf_get_rowstride');
  Pointer(gdk_pixbuf_get_n_channels) := Sym(LibPb, 'gdk_pixbuf_get_n_channels');
  Pointer(gdk_pixbuf_get_pixels) := Sym(LibPb, 'gdk_pixbuf_get_pixels');
  Pointer(gdk_pixbuf_get_formats) := Sym(LibPb, 'gdk_pixbuf_get_formats');
  Pointer(gdk_pixbuf_format_get_extensions) := Sym(LibPb, 'gdk_pixbuf_format_get_extensions');
  Pointer(g_object_unref) := Sym(LibGo, 'g_object_unref');
  Pointer(g_error_free) := Sym(LibGl, 'g_error_free');
  Pointer(g_strfreev) := Sym(LibGl, 'g_strfreev');
  Pointer(g_slist_free) := Sym(LibGl, 'g_slist_free');
  Pointer(g_free) := Sym(LibGl, 'g_free');
  Pointer(gdk_pixbuf_get_has_alpha) := Sym(LibPb, 'gdk_pixbuf_get_has_alpha');
  Pointer(gdk_pixbuf_new_from_data) := Sym(LibPb, 'gdk_pixbuf_new_from_data');
  Pointer(gdk_pixbuf_savev) := Sym(LibPb, 'gdk_pixbuf_savev');
  Pointer(gdk_pixbuf_format_is_writable) := Sym(LibPb, 'gdk_pixbuf_format_is_writable');
  Pointer(gdk_pixbuf_format_get_name) := Sym(LibPb, 'gdk_pixbuf_format_get_name');
  Pointer(gdk_pixbuf_format_get_description) := Sym(LibPb, 'gdk_pixbuf_format_get_description');
  if not (Assigned(gdk_pixbuf_new_from_file) and Assigned(gdk_pixbuf_apply_embedded_orientation) and
     Assigned(gdk_pixbuf_get_pixels) and Assigned(gdk_pixbuf_get_formats) and
     Assigned(gdk_pixbuf_format_get_extensions) and Assigned(g_object_unref) and
     Assigned(g_error_free) and Assigned(g_strfreev) and Assigned(g_slist_free)) then
  begin
    Pointer(gdk_pixbuf_new_from_file) := nil;
    Exit(False);
  end;
  l := gdk_pixbuf_get_formats();
  p := l;
  while p <> nil do
  begin
    e := gdk_pixbuf_format_get_extensions(p^.Data);
    q := e;
    while (q <> nil) and (q^ <> nil) do
    begin
      Exts.Add('.' + LowerCase(string(q^)));
      Inc(q);
    end;
    if e <> nil then
      g_strfreev(e);
    p := p^.Next;
  end;
  g_slist_free(l);
  Result := True;
end;

function SupportedExtensions: TStringList;
begin
  PixbufInit;
  Result := Exts;
end;

function IsJpegFile(const FileName: string): Boolean;
var
  ext: string;
begin
  ext := LowerCase(ExtractFileExt(FileName));
  Result := (ext = '.jpg') or (ext = '.jpeg') or (ext = '.jpe');
end;

function IsImageFile(const FileName: string): Boolean;
begin
  PixbufInit;
  Result := Exts.IndexOf(LowerCase(ExtractFileExt(FileName))) >= 0;
end;

function LoadOriented(const FileName: string; out Err: string): Pointer;
var
  pb, rot: Pointer;
  gerr: PGError;
begin
  Result := nil;
  if not PixbufInit or not Assigned(gdk_pixbuf_new_from_file) then
  begin
    Err := 'gdk-pixbuf not available';
    Exit;
  end;
  gerr := nil;
  pb := gdk_pixbuf_new_from_file(PChar(FileName), @gerr);
  if pb = nil then
  begin
    if gerr <> nil then
    begin
      Err := string(gerr^.Message);
      g_error_free(gerr);
    end
    else
      Err := 'Unsupported or damaged file';
    Exit;
  end;
  rot := gdk_pixbuf_apply_embedded_orientation(pb);
  if rot <> nil then
  begin
    g_object_unref(pb);
    pb := rot;
  end;
  Result := pb;
end;

function PixbufLoadRGBA(const FileName: string; out Pix: TPixelBuffer; out HasAlpha: Boolean;
  out Err: string): Boolean;
var
  pb: Pointer;
  w, h, stride, nch, x, y: Integer;
  src, s, d: PByte;
begin
  Result := False;
  Pix := nil;
  pb := LoadOriented(FileName, Err);
  if pb = nil then
    Exit;
  try
    w := gdk_pixbuf_get_width(pb);
    h := gdk_pixbuf_get_height(pb);
    stride := gdk_pixbuf_get_rowstride(pb);
    nch := gdk_pixbuf_get_n_channels(pb);
    src := gdk_pixbuf_get_pixels(pb);
    HasAlpha := nch >= 4;
    Pix := TPixelBuffer.Create(w, h);
    d := Pix.Data;
    for y := 0 to h - 1 do
    begin
      s := src + Int64(y) * stride;
      for x := 0 to w - 1 do
      begin
        if nch >= 3 then
        begin
          d[0] := s[0]; d[1] := s[1]; d[2] := s[2];
        end
        else
        begin
          d[0] := s[0]; d[1] := s[0]; d[2] := s[0];
        end;
        if nch >= 4 then d[3] := s[3] else d[3] := 255;
        Inc(s, nch);
        Inc(d, 4);
      end;
    end;
    Result := True;
  finally
    g_object_unref(pb);
  end;
end;

procedure PixbufWritableFormats(Names, Exts, Descs: TStrings);
var
  l, p: PGSList;
  e: PPChar;
  nm, ds: PChar;
begin
  Names.Clear;
  Exts.Clear;
  Descs.Clear;
  if not PixbufInit or not Assigned(gdk_pixbuf_savev) then
    Exit;
  l := gdk_pixbuf_get_formats();
  p := l;
  while p <> nil do
  begin
    if gdk_pixbuf_format_is_writable(p^.Data) then
    begin
      nm := gdk_pixbuf_format_get_name(p^.Data);
      ds := gdk_pixbuf_format_get_description(p^.Data);
      e := gdk_pixbuf_format_get_extensions(p^.Data);
      Names.Add(string(nm));
      if (e <> nil) and (e^ <> nil) then Exts.Add('.' + LowerCase(string(e^))) else Exts.Add('.' + string(nm));
      Descs.Add(string(ds));
      g_free(nm);
      g_free(ds);
      if e <> nil then g_strfreev(e);
    end;
    p := p^.Next;
  end;
  g_slist_free(l);
end;

function PixbufSaveRGBA(Pix: TPixelBuffer; HasAlpha: Boolean; const FileName, FormatName: string;
  Keys, Values: TStrings; out Err: string): Boolean;
var
  rgb: PByte;
  pb: Pointer;
  stride, x, y, i, n: Integer;
  s, d: PByte;
  gerr: PGError;
  ks, vs: array of PChar;
  ksa, vsa: array of string;
begin
  Result := False;
  Err := '';
  if not PixbufInit or not Assigned(gdk_pixbuf_savev) then
  begin
    Err := 'gdk-pixbuf not available';
    Exit;
  end;
  if HasAlpha then
  begin
    stride := Pix.Width * 4;
    rgb := Pix.Data;                  // already RGBA
  end
  else
  begin
    stride := Pix.Width * 3;
    rgb := GetMem(Int64(stride) * Pix.Height);
    for y := 0 to Pix.Height - 1 do
    begin
      s := Pix.Data + Int64(y) * Pix.Width * 4;
      d := rgb + Int64(y) * stride;
      for x := 0 to Pix.Width - 1 do
      begin
        d[0] := s[0]; d[1] := s[1]; d[2] := s[2];
        Inc(s, 4);
        Inc(d, 3);
      end;
    end;
  end;
  try
    pb := gdk_pixbuf_new_from_data(rgb, 0, HasAlpha, 8, Pix.Width, Pix.Height, stride, nil, nil);
    if pb = nil then
    begin
      Err := 'Cannot create the image';
      Exit;
    end;
    try
      n := 0;
      if Keys <> nil then n := Keys.Count;
      SetLength(ksa, n);
      SetLength(vsa, n);
      SetLength(ks, n + 1);
      SetLength(vs, n + 1);
      for i := 0 to n - 1 do
      begin
        ksa[i] := Keys[i];
        vsa[i] := Values[i];
        ks[i] := PChar(ksa[i]);
        vs[i] := PChar(vsa[i]);
      end;
      ks[n] := nil;
      vs[n] := nil;
      gerr := nil;
      if n > 0 then
        Result := gdk_pixbuf_savev(pb, PChar(FileName), PChar(FormatName), @ks[0], @vs[0], @gerr)
      else
        Result := gdk_pixbuf_savev(pb, PChar(FileName), PChar(FormatName), nil, nil, @gerr);
      if not Result then
      begin
        if gerr <> nil then
        begin
          Err := string(gerr^.Message);
          g_error_free(gerr);
        end
        else
          Err := 'Cannot write the file';
      end;
    finally
      g_object_unref(pb);
    end;
  finally
    if not HasAlpha then
      FreeMem(rgb);
  end;
end;

function PixbufDecode(const FileName: string; out Pix: TPixelBuffer; out Err: string): Boolean;
var
  pb, rot: Pointer;
  gerr: PGError;
  w, h, stride, nch, x, y: Integer;
  src, s: PByte;
  d: PByte;
  a, bg: Cardinal;
begin
  Result := False;
  Pix := nil;
  if not PixbufInit or not Assigned(gdk_pixbuf_new_from_file) then
  begin
    Err := 'gdk-pixbuf not available';
    Exit;
  end;
  gerr := nil;
  pb := gdk_pixbuf_new_from_file(PChar(FileName), @gerr);
  if pb = nil then
  begin
    if gerr <> nil then
    begin
      Err := string(gerr^.Message);
      g_error_free(gerr);
    end
    else
      Err := 'Unsupported or damaged file';
    Exit;
  end;
  rot := gdk_pixbuf_apply_embedded_orientation(pb);
  if rot <> nil then
  begin
    g_object_unref(pb);
    pb := rot;
  end;
  try
    w := gdk_pixbuf_get_width(pb);
    h := gdk_pixbuf_get_height(pb);
    stride := gdk_pixbuf_get_rowstride(pb);
    nch := gdk_pixbuf_get_n_channels(pb);
    src := gdk_pixbuf_get_pixels(pb);
    Pix := TPixelBuffer.Create(w, h);
    d := Pix.Data;
    bg := $30;                        // transparent areas are blended over dark grey
    for y := 0 to h - 1 do
    begin
      s := src + Int64(y) * stride;
      for x := 0 to w - 1 do
      begin
        if nch >= 4 then
        begin
          a := s[3];
          d[0] := (s[2] * a + bg * (255 - a)) div 255;
          d[1] := (s[1] * a + bg * (255 - a)) div 255;
          d[2] := (s[0] * a + bg * (255 - a)) div 255;
        end
        else if nch >= 3 then
        begin
          d[0] := s[2]; d[1] := s[1]; d[2] := s[0];
        end
        else
        begin
          d[0] := s[0]; d[1] := s[0]; d[2] := s[0];
        end;
        d[3] := 255;
        Inc(s, nch);
        Inc(d, 4);
      end;
    end;
    Result := True;
  finally
    g_object_unref(pb);
  end;
end;

end.
