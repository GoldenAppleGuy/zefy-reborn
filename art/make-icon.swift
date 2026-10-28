import AppKit
func render(_ S: Int, _ path: String) {
  let k = CGFloat(S)/1024
  let ctx = CGContext(data:nil,width:S,height:S,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.scaleBy(x:k,y:k)
  let g = CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:[CGColor(red:0.14,green:0.80,blue:0.38,alpha:1),CGColor(red:0.10,green:0.66,blue:0.30,alpha:1)] as CFArray,locations:[0,1])!
  ctx.saveGState(); ctx.addPath(CGPath(roundedRect:CGRect(x:0,y:0,width:1024,height:1024),cornerWidth:229,cornerHeight:229,transform:nil)); ctx.clip()
  ctx.drawLinearGradient(g,start:CGPoint(x:0,y:1024),end:CGPoint(x:1024,y:0),options:[]); ctx.restoreGState()
  let ink = CGColor(red:1,green:1,blue:1,alpha:1)
  // Z
  let f = CTFontCreateWithName("Copperplate-Bold" as CFString, 660, nil)
  let line = CTLineCreateWithAttributedString(NSAttributedString(string:"Z",attributes:[.font:f,.foregroundColor:NSColor(cgColor:ink)!]))
  let b = CTLineGetBoundsWithOptions(line,.useGlyphPathBounds)
  ctx.textPosition = CGPoint(x:512-b.midX,y:512-b.midY); CTLineDraw(line,ctx)
  // arrow ring
  ctx.setStrokeColor(ink); ctx.setFillColor(ink); ctx.setLineCap(.butt); ctx.setLineWidth(68)
  let r: CGFloat = 385, s = CGFloat.pi*0.28, e = CGFloat.pi*1.80
  ctx.addArc(center:CGPoint(x:512,y:512),radius:r,startAngle:s,endAngle:e,clockwise:false); ctx.strokePath()
  let c = CGPoint(x:512+r*cos(e),y:512+r*sin(e)), tx = -sin(e), ty = cos(e), nx = cos(e), ny = sin(e)
  ctx.move(to:CGPoint(x:c.x+tx*120,y:c.y+ty*120)); ctx.addLine(to:CGPoint(x:c.x+nx*95,y:c.y+ny*95)); ctx.addLine(to:CGPoint(x:c.x-nx*95,y:c.y-ny*95)); ctx.closePath(); ctx.fillPath()
  let rep = NSBitmapImageRep(cgImage:ctx.makeImage()!)
  try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:path))
}
for (s,n) in [(1024,"icon-1024.png"),(180,"icon-180.png"),(87,"pref@3x.png"),(58,"pref@2x.png"),(29,"pref.png")] { render(s,n) }
