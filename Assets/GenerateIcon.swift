import AppKit
let output=CommandLine.arguments[1]
let image=NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let tile=NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:218,yRadius:218)
NSGradient(starting:NSColor(srgbRed:0.37,green:0.25,blue:0.91,alpha:1),ending:NSColor(srgbRed:0.12,green:0.12,blue:0.43,alpha:1))!.draw(in:tile,angle:-60)
// Four capture corners.
NSColor.white.withAlphaComponent(0.95).setStroke()
for (x,y,sx,sy) in [(CGFloat(180),CGFloat(820),CGFloat(1),CGFloat(-1)),(844,820,-1,-1),(180,204,1,1),(844,204,-1,1)] {
 let p=NSBezierPath();p.lineWidth=30;p.lineCapStyle = .round;p.lineJoinStyle = .round
 p.move(to:NSPoint(x:x,y:y+sy*90));p.line(to:NSPoint(x:x,y:y));p.line(to:NSPoint(x:x+sx*90,y:y));p.stroke()
}
// Note sheet.
let paper=NSBezierPath(roundedRect:NSRect(x:306,y:260,width:416,height:510),xRadius:48,yRadius:48)
NSColor.white.setFill();paper.fill()
NSColor(srgbRed:0.43,green:0.39,blue:0.72,alpha:1).setStroke()
for (y,length) in [(CGFloat(660),CGFloat(222)),(564,222),(468,140)]{let p=NSBezierPath();p.lineWidth=25;p.lineCapStyle = .round;p.move(to:NSPoint(x:368,y:y));p.line(to:NSPoint(x:368+length,y:y));p.stroke()}
// Mint annotation pencil.
NSGraphicsContext.saveGraphicsState();let t=NSAffineTransform();t.translateX(by:684,yBy:310);t.rotate(byDegrees:-42);t.concat()
NSColor(srgbRed:0.24,green:0.91,blue:0.77,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:-47,y:0,width:94,height:320),xRadius:20,yRadius:20).fill()
let tip=NSBezierPath();tip.move(to:NSPoint(x:-47,y:20));tip.line(to:NSPoint(x:0,y:-65));tip.line(to:NSPoint(x:47,y:20));tip.close();NSColor(srgbRed:0.88,green:1,blue:0.96,alpha:1).setFill();tip.fill()
NSGraphicsContext.restoreGraphicsState()
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))
