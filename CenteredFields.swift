import AppKit

/// The text and the shared field editor use the same, vertically centered line box.
final class CenteredTextFieldCell:NSTextFieldCell {
 override func drawingRect(forBounds rect:NSRect)->NSRect {
  var drawing=super.drawingRect(forBounds:rect)
  let height=min(drawing.height,super.cellSize(forBounds:NSRect(x:0,y:0,width:rect.width,height:CGFloat.greatestFiniteMagnitude)).height)
  drawing.origin.y=rect.midY-height/2;drawing.size.height=height
  return drawing
 }
 override func edit(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,event:NSEvent?){super.edit(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,event:event)}
 override func select(withFrame rect:NSRect,in controlView:NSView,editor:NSText,delegate:Any?,start selStart:Int,length selLength:Int){super.select(withFrame:drawingRect(forBounds:rect),in:controlView,editor:editor,delegate:delegate,start:selStart,length:selLength)}
}
class CenteredTextField:NSTextField {
 override init(frame:NSRect){super.init(frame:frame);focusRingType = .none;cell?.focusRingType = .none}
 required init?(coder:NSCoder){super.init(coder:coder);focusRingType = .none;cell?.focusRingType = .none}
 override class var cellClass:AnyClass? {get{CenteredTextFieldCell.self}set{super.cellClass=newValue}}
}
final class WindowChromeActions:NSObject {
 static let shared=WindowChromeActions()
 @objc func close(_ sender:NSButton){
  guard let window=sender.window else{return}
  if let shouldClose=window.delegate?.windowShouldClose?(window),!shouldClose{return}
  window.close()
 }
}
