unit tjpeg;

{ Dynamic binding to libturbojpeg (libjpeg-turbo TurboJPEG API, decompression only). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, DynLibs;

const
  TJPF_RGBX = 2;
  TJPF_BGRX = 3;
  TJFLAG_PROGRESSIVE = 16384;
  TJSAMP_444 = 0;
  TJSAMP_422 = 1;
  TJSAMP_420 = 2;
  TJSAMP_GRAY = 3;
  TJSAMP_440 = 4;
  TJFLAG_FASTUPSAMPLE = 256;
  TJFLAG_FASTDCT = 2048;

type
  tjhandle = Pointer;

var
  tjInitDecompress: function: tjhandle; cdecl;
  tjDestroy: function(handle: tjhandle): Integer; cdecl;
  tjDecompressHeader3: function(handle: tjhandle; jpegBuf: PByte; jpegSize: PtrUInt;
    width, height, jpegSubsamp, jpegColorspace: PInteger): Integer; cdecl;
  tjDecompress2: function(handle: tjhandle; jpegBuf: PByte; jpegSize: PtrUInt;
    dstBuf: PByte; width, pitch, height, pixelFormat, flags: Integer): Integer; cdecl;
  tjGetErrorStr: function: PChar; cdecl;
  tjInitCompress: function: tjhandle; cdecl;
  tjCompress2: function(handle: tjhandle; srcBuf: PByte; width, pitch, height, pixelFormat: Integer;
    var jpegBuf: PByte; var jpegSize: PtrUInt; jpegSubsamp, jpegQual, flags: Integer): Integer; cdecl;
  tjFree: procedure(buffer: PByte); cdecl;

{ Loads the library; returns False if it (or one of its symbols) is missing. }
function TurboJpegLoad: Boolean;
function TurboJpegError: string;

{ Largest denominator d in (8, 4, 2, 1) such that a 1/d DCT-scaled decode is still
  at least as large as Scale (display pixels per source pixel). }
function TurboJpegDenom(Scale: Double): Integer;

implementation

var
  Lib: TLibHandle = NilHandle;
  Loaded: Boolean = False;

function TurboJpegLoad: Boolean;
const
  Names: array[0..2] of string = ('libturbojpeg.so.0', 'libturbojpeg.so', 'libturbojpeg.so.0.2.0');
var
  i: Integer;
begin
  if Loaded then
    Exit(True);
  for i := Low(Names) to High(Names) do
  begin
    Lib := LoadLibrary(Names[i]);
    if Lib <> NilHandle then
      Break;
  end;
  if Lib = NilHandle then
    Exit(False);
  Pointer(tjInitDecompress) := GetProcedureAddress(Lib, 'tjInitDecompress');
  Pointer(tjDestroy) := GetProcedureAddress(Lib, 'tjDestroy');
  Pointer(tjDecompressHeader3) := GetProcedureAddress(Lib, 'tjDecompressHeader3');
  Pointer(tjDecompress2) := GetProcedureAddress(Lib, 'tjDecompress2');
  Pointer(tjGetErrorStr) := GetProcedureAddress(Lib, 'tjGetErrorStr');
  Pointer(tjInitCompress) := GetProcedureAddress(Lib, 'tjInitCompress');
  Pointer(tjCompress2) := GetProcedureAddress(Lib, 'tjCompress2');
  Pointer(tjFree) := GetProcedureAddress(Lib, 'tjFree');
  Loaded := Assigned(tjInitDecompress) and Assigned(tjDestroy) and
    Assigned(tjDecompressHeader3) and Assigned(tjDecompress2) and Assigned(tjGetErrorStr);
  Result := Loaded;
end;

function TurboJpegError: string;
begin
  if Assigned(tjGetErrorStr) then
    Result := string(tjGetErrorStr())
  else
    Result := 'libturbojpeg not loaded';
end;

function TurboJpegDenom(Scale: Double): Integer;
begin
  if Scale <= 0 then
    Exit(8);
  if Scale <= 1 / 8 then Result := 8
  else if Scale <= 1 / 4 then Result := 4
  else if Scale <= 1 / 2 then Result := 2
  else Result := 1;
end;

end.
