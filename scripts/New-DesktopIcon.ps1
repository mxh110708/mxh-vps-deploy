[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$frames=[Collections.Generic.List[byte[]]]::new()
foreach($size in @(16,32,48,64,128,256)){
 $bitmap=[Drawing.Bitmap]::new($size,$size)
 $graphics=[Drawing.Graphics]::FromImage($bitmap)
 $graphics.SmoothingMode='AntiAlias';$graphics.Clear([Drawing.Color]::Transparent)
 $scale=$size/256.0;$graphics.ScaleTransform($scale,$scale)
 $panel=[Drawing.Drawing2D.GraphicsPath]::new()
 $panel.AddArc(4,4,72,72,180,90);$panel.AddArc(180,4,72,72,270,90);$panel.AddArc(180,180,72,72,0,90);$panel.AddArc(4,180,72,72,90,90);$panel.CloseFigure()
 $dark=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#202630'))
 $blue=[Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml('#acd0e7'))
 $stroke=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml('#acd0e7'),13)
 $stroke.StartCap='Round';$stroke.EndCap='Round';$stroke.LineJoin='Round'
 try{
  $graphics.FillPath($dark,$panel)
  $graphics.DrawRectangle($stroke,58,65,140,48);$graphics.DrawRectangle($stroke,58,143,140,48)
  $graphics.FillEllipse($blue,77,80,17,17);$graphics.FillEllipse($blue,77,158,17,17)
  $graphics.DrawLine($stroke,124,89,176,89);$graphics.DrawLine($stroke,124,167,176,167)
  $stream=[IO.MemoryStream]::new();try{$bitmap.Save($stream,[Drawing.Imaging.ImageFormat]::Png);$frames.Add($stream.ToArray())}finally{$stream.Dispose()}
 }finally{$stroke.Dispose();$dark.Dispose();$blue.Dispose();$panel.Dispose();$graphics.Dispose();$bitmap.Dispose()}
}
$stream=[IO.File]::Create([IO.Path]::GetFullPath($Destination));$writer=[IO.BinaryWriter]::new($stream)
try{
 $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
 $offset=6+16*$frames.Count;$sizes=@(16,32,48,64,128,256)
 for($i=0;$i -lt $frames.Count;$i++){
  $width=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
  $writer.Write([byte]$width);$writer.Write([byte]$width);$writer.Write([byte]0);$writer.Write([byte]0)
  $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frames[$i].Length);$writer.Write([uint32]$offset);$offset+=$frames[$i].Length
 }
 foreach($frame in $frames){$writer.Write($frame)}
}finally{$writer.Dispose();$stream.Dispose()}
