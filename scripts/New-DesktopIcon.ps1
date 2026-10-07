[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$Destination,
 [string]$Source=(Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/gui/app.svg'),
 [string]$PreviewDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
[xml]$design=Get-Content -Raw -LiteralPath $Source
if($design.svg.viewBox -ne '0 0 256 256'){throw '图标母版需要 256 像素坐标系。'}

function Get-IconNumber([string]$Value){[single]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture)}
function New-IconBrush([string]$Fill){
 if($Fill -notmatch '^url\(#([A-Za-z][A-Za-z0-9_-]*)\)$'){
  return [Drawing.SolidBrush]::new([Drawing.ColorTranslator]::FromHtml($Fill))
 }
 $gradient=$design.svg.SelectSingleNode("*[local-name()='defs']/*[local-name()='linearGradient'][@id='$($Matches[1])']")
 if(-not $gradient -or $gradient.GetAttribute('gradientUnits') -ne 'userSpaceOnUse'){throw '图标渐变需要明确的母版坐标。'}
 $start=[Drawing.PointF]::new((Get-IconNumber $gradient.GetAttribute('x1')),(Get-IconNumber $gradient.GetAttribute('y1')))
 $end=[Drawing.PointF]::new((Get-IconNumber $gradient.GetAttribute('x2')),(Get-IconNumber $gradient.GetAttribute('y2')))
 $brush=[Drawing.Drawing2D.LinearGradientBrush]::new($start,$end,[Drawing.Color]::Black,[Drawing.Color]::White)
 try{
  $stops=@($gradient.SelectNodes("*[local-name()='stop']"));$blend=[Drawing.Drawing2D.ColorBlend]::new($stops.Count)
  $blend.Positions=[single[]]@($stops|ForEach-Object{Get-IconNumber $_.GetAttribute('offset')})
  $blend.Colors=[Drawing.Color[]]@($stops|ForEach-Object{[Drawing.ColorTranslator]::FromHtml($_.GetAttribute('stop-color'))})
  $brush.InterpolationColors=$blend;$brush.WrapMode=[Drawing.Drawing2D.WrapMode]::TileFlipXY
  return $brush
 }catch{$brush.Dispose();throw}
}
function New-IconPath([string]$Data){
 $tokens=@([regex]::Matches($Data,'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+)')|ForEach-Object Value)
 $path=[Drawing.Drawing2D.GraphicsPath]::new();$cursor=0;$x=[single]0;$y=[single]0
 try{
  while($cursor -lt $tokens.Count){
   $command=$tokens[$cursor++];$length=switch($command){M{2}L{2}H{1}C{6}Z{0}default{throw '图标母版含不支持的路径指令。'}}
   if($cursor+$length -gt $tokens.Count){throw '图标路径坐标不完整。'}
   $values=@(for($i=0;$i -lt $length;$i++){Get-IconNumber $tokens[$cursor++]})
   switch($command){
    M{$path.StartFigure();$x=$values[0];$y=$values[1]}
    L{$path.AddLine($x,$y,$values[0],$values[1]);$x=$values[0];$y=$values[1]}
    H{$path.AddLine($x,$y,$values[0],$y);$x=$values[0]}
    C{$path.AddBezier($x,$y,$values[0],$values[1],$values[2],$values[3],$values[4],$values[5]);$x=$values[4];$y=$values[5]}
    Z{$path.CloseFigure()}
   }
  }
  return $path
 }catch{$path.Dispose();throw}
}

$sizes=@(16,20,24,32,40,48,64,96,128,256)
$frames=[Collections.Generic.List[byte[]]]::new()
if($PreviewDirectory){[IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($PreviewDirectory))|Out-Null}
foreach($size in $sizes){
 $large=[Drawing.Bitmap]::new($size*4,$size*4);$graphics=[Drawing.Graphics]::FromImage($large)
 try{
  $graphics.SmoothingMode='AntiAlias';$graphics.Clear([Drawing.Color]::Transparent)
  $graphics.ScaleTransform($size*4/256.0,$size*4/256.0)
  foreach($shape in $design.svg.ChildNodes){
   if($shape.LocalName -in @('title','desc','defs') -or $shape.NodeType -ne [Xml.XmlNodeType]::Element){continue}
   $path=[Drawing.Drawing2D.GraphicsPath]::new()
   try{
    switch($shape.LocalName){
     rect{
      $x=Get-IconNumber $shape.GetAttribute('x');$y=Get-IconNumber $shape.GetAttribute('y')
      $width=Get-IconNumber $shape.GetAttribute('width');$height=Get-IconNumber $shape.GetAttribute('height');$radius=Get-IconNumber $shape.GetAttribute('rx');$arc=2*$radius
      $path.AddArc($x,$y,$arc,$arc,180,90);$path.AddArc($x+$width-$arc,$y,$arc,$arc,270,90)
      $path.AddArc($x+$width-$arc,$y+$height-$arc,$arc,$arc,0,90);$path.AddArc($x,$y+$height-$arc,$arc,$arc,90,90);$path.CloseFigure()
     }
     circle{$r=Get-IconNumber $shape.GetAttribute('r');$x=Get-IconNumber $shape.GetAttribute('cx');$y=Get-IconNumber $shape.GetAttribute('cy');$path.AddEllipse($x-$r,$y-$r,2*$r,2*$r)}
     path{$path.Dispose();$path=New-IconPath $shape.GetAttribute('d')}
     default{throw '图标母版含不支持的形状。'}
    }
    $fill=$shape.GetAttribute('fill')
    if($fill -and $fill -ne 'none'){$brush=New-IconBrush $fill;try{$graphics.FillPath($brush,$path)}finally{$brush.Dispose()}}
    $stroke=$shape.GetAttribute('stroke')
    if($stroke){
     $weight=Get-IconNumber $shape.GetAttribute('stroke-width');if($size -le 24 -and $weight -eq 12){$weight=14}
     $pen=[Drawing.Pen]::new([Drawing.ColorTranslator]::FromHtml($stroke),$weight);$pen.StartCap='Round';$pen.EndCap='Round';$pen.LineJoin='Round'
     try{$graphics.DrawPath($pen,$path)}finally{$pen.Dispose()}
    }
   }finally{$path.Dispose()}
  }
  $bitmap=[Drawing.Bitmap]::new($size,$size);$down=[Drawing.Graphics]::FromImage($bitmap)
  try{
   $down.CompositingMode='SourceCopy';$down.InterpolationMode='HighQualityBicubic';$down.PixelOffsetMode='HighQuality';$down.DrawImage($large,0,0,$size,$size)
   $memory=[IO.MemoryStream]::new()
   try{$bitmap.Save($memory,[Drawing.Imaging.ImageFormat]::Png);$frames.Add($memory.ToArray())}finally{$memory.Dispose()}
   if($PreviewDirectory){$bitmap.Save((Join-Path $PreviewDirectory ("icon-$size.png")),[Drawing.Imaging.ImageFormat]::Png)}
  }finally{$down.Dispose();$bitmap.Dispose()}
 }finally{$graphics.Dispose();$large.Dispose()}
}
$destinationPath=[IO.Path]::GetFullPath($Destination)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationPath))|Out-Null
$stream=[IO.File]::Create($destinationPath);$writer=[IO.BinaryWriter]::new($stream)
try{
 $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
 $offset=6+16*$frames.Count
 for($i=0;$i -lt $frames.Count;$i++){
  $width=if($sizes[$i] -eq 256){0}else{$sizes[$i]}
  $writer.Write([byte]$width);$writer.Write([byte]$width);$writer.Write([byte]0);$writer.Write([byte]0)
  $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frames[$i].Length);$writer.Write([uint32]$offset);$offset+=$frames[$i].Length
 }
 foreach($frame in $frames){$writer.Write($frame)}
}finally{$writer.Dispose();$stream.Dispose()}
