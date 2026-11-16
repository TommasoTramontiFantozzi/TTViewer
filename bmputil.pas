unit bmputil;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, GraphType, IntfGraphics, jpegworkers;

{ Builds a TBitmap from decoded BGRX pixels (main thread only). }
function BitmapFromPixels(Pixels: TPixelBuffer): TBitmap;

implementation

function BitmapFromPixels(Pixels: TPixelBuffer): TBitmap;
var
  ri: TRawImage;
begin
  ri.Init;
  ri.Description.Init_BPP32_B8G8R8A8_BIO_TTB(Pixels.Width, Pixels.Height);
  ri.Data := Pixels.Data;
  ri.DataSize := Int64(Pixels.Width) * Pixels.Height * 4;
  Result := TBitmap.Create;
  Result.LoadFromRawImage(ri, False);   // copies the pixels
end;

end.
