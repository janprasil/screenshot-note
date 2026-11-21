import AppKit

extension Mark {
 var corners:[NSPoint]{let r=bounds;return [NSPoint(x:r.minX,y:r.minY),NSPoint(x:r.maxX,y:r.minY),NSPoint(x:r.maxX,y:r.maxY),NSPoint(x:r.minX,y:r.maxY)]}
 func rotatedPoint(_ point:NSPoint,angle:CGFloat)->NSPoint{
  let r=bounds,dx=point.x-r.midX,dy=point.y-r.midY
  return NSPoint(x:r.midX+dx*cos(angle)-dy*sin(angle),y:r.midY+dx*sin(angle)+dy*cos(angle))
 }
 func rotatedPoint(_ point:NSPoint)->NSPoint{rotatedPoint(point,angle:rotation)}
 func unrotatedPoint(_ point:NSPoint)->NSPoint{rotatedPoint(point,angle:-rotation)}
 func resized(by factor:CGFloat,fixedCorner:Int)->Mark{
  let anchor=corners[fixedCorner],worldAnchor=rotatedPoint(anchor)
  var result=self
  result.points=points.map{NSPoint(x:anchor.x+($0.x-anchor.x)*factor,y:anchor.y+($0.y-anchor.y)*factor)}
  result.width=max(0.5,width*factor)
  return result.anchored(at:worldAnchor,corner:fixedCorner)
 }
 func resizingText(by delta:NSPoint)->Mark{
  var result=self
  result.textWidth=max(24,bounds.width+delta.x)
  if abs(delta.y)>0.001{result.textHeight=max(0,bounds.height-delta.y)}
  return result.anchored(at:rotatedPoint(corners[3]),corner:3)
 }
 private func anchored(at worldAnchor:NSPoint,corner:Int)->Mark{
  var result=self
  let movedAnchor=rotatedPoint(corners[corner])
  result.points=result.points.map{NSPoint(x:$0.x+worldAnchor.x-movedAnchor.x,y:$0.y+worldAnchor.y-movedAnchor.y)}
  return result
 }
}
private enum TransformCursors {
 static let resize=(0..<4).map{step in
  make{path in
   let angle=CGFloat(step) * .pi/4
   func point(_ x:CGFloat,_ y:CGFloat)->NSPoint{
    NSPoint(x:12+x*cos(angle)-y*sin(angle),y:12+x*sin(angle)+y*cos(angle))
   }
   path.move(to:point(-8,0));path.line(to:point(8,0))
   for direction:CGFloat in [-1,1]{
    path.move(to:point(4*direction,4));path.line(to:point(8*direction,0));path.line(to:point(4*direction,-4))
   }
  }
 }
 static let rotate=make{path in
  path.appendArc(withCenter:NSPoint(x:12,y:12),radius:7,startAngle:145,endAngle:-140,clockwise:true)
  let tip=path.currentPoint
  path.move(to:NSPoint(x:tip.x-1,y:tip.y-5));path.line(to:tip);path.line(to:NSPoint(x:tip.x+5,y:tip.y))
 }
 private static func make(_ draw:(NSBezierPath)->Void)->NSCursor{
  let size=NSSize(width:24,height:24)
  let image=NSImage(size:size);image.lockFocus()
  let path=NSBezierPath();path.lineCapStyle = .round;path.lineJoinStyle = .round
  draw(path)
  path.lineWidth=3.5;NSColor.white.setStroke();path.stroke()
  path.lineWidth=1.7;NSColor.black.setStroke();path.stroke()
  image.unlockFocus()
  return NSCursor(image:image,hotSpot:NSPoint(x:12,y:12))
 }
}

struct AnnotationTransformDrag {
 enum Kind{
  case resize(Int),rotate
  func cursor(for mark:Mark)->NSCursor{
   switch self{
   case .rotate:return TransformCursors.rotate
   case .resize(let corner):
    let from=mark.rotatedPoint(mark.corners[(corner+2)%4]),to=mark.rotatedPoint(mark.corners[corner])
    let angle=mark.tool == .text ? mark.rotation - .pi/4:atan2(to.y-from.y,to.x-from.x)
    let step=Int((angle.truncatingRemainder(dividingBy:.pi)/(.pi/4)).rounded())
    return TransformCursors.resize[(step+4)%4]
   }
  }
 }
 var index:Int;var original:Mark;var start:NSPoint;var kind:Kind
}
extension DrawingView {
 func displayPoint(_ p:NSPoint)->NSPoint{let r=imageRect;return NSPoint(x:r.minX+(p.x-viewport.minX)*scale,y:r.minY+(p.y-viewport.minY)*scale)}
 func imagePoint(_ p:NSPoint)->NSPoint{let r=imageRect;return NSPoint(x:(p.x-r.minX)/scale+viewport.minX,y:(p.y-r.minY)/scale+viewport.minY)}
 func selectionCorners(_ mark:Mark)->[NSPoint]{
  let r=mark.bounds.insetBy(dx:-4/scale,dy:-4/scale)
  return [NSPoint(x:r.minX,y:r.minY),NSPoint(x:r.maxX,y:r.minY),NSPoint(x:r.maxX,y:r.maxY),NSPoint(x:r.minX,y:r.maxY)].map{displayPoint(mark.rotatedPoint($0))}
 }
 func resizeCornerIndices(_ mark:Mark)->[Int]{mark.tool == .element ? []:(mark.tool == .text ? [1]:[0,1,2,3])}
 func rotationHandle(_ mark:Mark)->NSPoint{
  let p=displayPoint(mark.rotatedPoint(NSPoint(x:mark.bounds.midX,y:mark.bounds.maxY+28/scale)))
  return NSPoint(x:max(9,min(bounds.maxX-9,p.x)),y:max(9,min(bounds.maxY-9,p.y)))
 }
 func drawSelectionHandles(){
  guard let i=selected,marks.indices.contains(i) else{return}
  let mark=marks[i],corners=selectionCorners(mark);let path=NSBezierPath();path.move(to:corners[0]);for p in corners.dropFirst(){path.line(to:p)};path.close();path.lineWidth=1.25;path.setLineDash([5,3],count:2,phase:0);AppPalette.accent.setStroke();path.stroke()
  guard editingIndex == nil,mark.tool != .element else{return}
  for corner in resizeCornerIndices(mark){let p=corners[corner];let rect=NSRect(x:p.x-4,y:p.y-4,width:8,height:8);AppPalette.paper.setFill();NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2).fill();let outline=NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2);outline.lineWidth=1.25;AppPalette.accent.setStroke();outline.stroke()}
  let handle=rotationHandle(mark);let line=NSBezierPath();line.move(to:NSPoint(x:(corners[2].x+corners[3].x)/2,y:(corners[2].y+corners[3].y)/2));line.line(to:handle);line.lineWidth=1;line.stroke()
  let circle=NSBezierPath(ovalIn:NSRect(x:handle.x-8,y:handle.y-8,width:16,height:16));AppPalette.paper.setFill();circle.fill();AppPalette.accent.setStroke();circle.lineWidth=1;circle.stroke()
  drawAdaptiveSymbol(NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:nil),in:NSRect(x:handle.x-5,y:handle.y-5,width:10,height:10),color:AppPalette.accent)
 }
 func installTransformCursors(){
  guard tool == .select,editingIndex == nil,let i=selected,marks.indices.contains(i),marks[i].tool != .element else{return}
  let mark=marks[i]
  let corners=selectionCorners(mark)
  for corner in resizeCornerIndices(mark){
   let p=corners[corner]
   addCursorRect(NSRect(x:p.x-9,y:p.y-9,width:18,height:18),cursor:AnnotationTransformDrag.Kind.resize(corner).cursor(for:mark))
  }
  let p=rotationHandle(mark)
  addCursorRect(NSRect(x:p.x-10,y:p.y-10,width:20,height:20),cursor:TransformCursors.rotate)
 }
 func transformHandle(at p:NSPoint,for mark:Mark)->AnnotationTransformDrag.Kind?{
  let rotation=rotationHandle(mark)
  if hypot(p.x-rotation.x,p.y-rotation.y)<=10{return .rotate}
  let corners=selectionCorners(mark)
  func distance(_ index:Int)->CGFloat{hypot(corners[index].x-p.x,corners[index].y-p.y)}
  if let corner=resizeCornerIndices(mark).min(by:{distance($0)<distance($1)}),distance(corner)<=9{return .resize(corner)}
  return nil
 }
 func beginTransform(with event:NSEvent)->Bool{
  guard let i=selected,marks.indices.contains(i),editingIndex == nil,marks[i].tool != .element else{return false}
  let p=convert(event.locationInWindow,from:nil),mark=marks[i]
  guard let kind=transformHandle(at:p,for:mark) else{return false}
  snapshot();transformDrag=AnnotationTransformDrag(index:i,original:mark,start:imagePoint(p),kind:kind)
  window?.invalidateCursorRects(for:self)
  kind.cursor(for:mark).set()
  return true
 }
 func updateTransform(with event:NSEvent)->Bool{
  guard let drag=transformDrag,marks.indices.contains(drag.index) else{return false}
  let p=imagePoint(convert(event.locationInWindow,from:nil));let original=drag.original
  switch drag.kind{
  case .resize(let corner):
   let fixed=(corner+2)%4
   if original.tool == .text {
    let start=original.unrotatedPoint(drag.start),end=original.unrotatedPoint(p)
    marks[drag.index]=original.resizingText(by:NSPoint(x:end.x-start.x,y:end.y-start.y))
    break
   }
   let anchor=original.rotatedPoint(original.corners[fixed]),moving=original.rotatedPoint(original.corners[corner]);let dx=moving.x-anchor.x,dy=moving.y-anchor.y
   let factor=max(0.05,min(20,1+((p.x-drag.start.x)*dx+(p.y-drag.start.y)*dy)/max(1,dx*dx+dy*dy)))
   marks[drag.index]=original.resized(by:factor,fixedCorner:fixed)
  case .rotate:
   let r=original.bounds;var angle=original.rotation+atan2(p.y-r.midY,p.x-r.midX)-atan2(drag.start.y-r.midY,drag.start.x-r.midX)
   if event.modifierFlags.contains(.shift){angle=(angle / (.pi/12)).rounded()*(.pi/12)}
   marks[drag.index].rotation=angle
  }
  choose(drag.index);drag.kind.cursor(for:original).set();return true
 }
}
