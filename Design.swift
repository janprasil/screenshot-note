import AppKit

let isExportingDesign=CommandLine.arguments.contains("--design-export")
enum AppPalette {
 static func color(_ light:UInt32,_ dark:UInt32)->NSColor{NSColor(name:nil){appearance in let value=appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark:light;return NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)}}
 static let accent=color(0x6851D8,0xA18CF7)
 static let action=color(0x6851D8,0x7758E8)
 static let background=color(0xFAF9FC,0x1E1C25)
 static let paper=color(0xFFFFFF,0x292631)
 static let raised=color(0xF0EDF6,0x34303E)
 static let stroke=color(0xE4DEEC,0x433D50)
 static let canvas=color(0xF0EDF5,0x18151F)
 static let text=NSColor.labelColor
 static let secondary=NSColor.secondaryLabelColor
}
class DesignSurface:NSView {
 var fill:NSColor=AppPalette.background;var radius:CGFloat=0;var border:NSColor?
 init(frame:NSRect,fill:NSColor=AppPalette.background,radius:CGFloat=0){self.fill=fill;self.radius=radius;super.init(frame:frame)}
 required init?(coder:NSCoder){fatalError()}
 override func draw(_ dirtyRect:NSRect){let p=NSBezierPath(roundedRect:bounds.insetBy(dx:border == nil ? 0:0.5,dy:border == nil ? 0:0.5),xRadius:radius,yRadius:radius);fill.setFill();p.fill();if let border=border{border.setStroke();p.lineWidth=1;p.stroke()}}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}
final class DesignDivider:DesignSurface {
 init(_ frame:NSRect){super.init(frame:frame,fill:AppPalette.stroke)}
 required init?(coder:NSCoder){fatalError()}
}
class AppButton:NSButton {
 enum Role{case primary,secondary,quiet}
 var role:Role = .secondary
 var hovered=false;private var tracking:NSTrackingArea?
 override func updateTrackingAreas(){super.updateTrackingAreas();if let area=tracking{removeTrackingArea(area)};let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);tracking=area;addTrackingArea(area)}
 override func resetCursorRects(){super.resetCursorRects();if isEnabled{addCursorRect(bounds,cursor:.pointingHand)}}
 override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
 override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
 override func draw(_ dirtyRect:NSRect){
  let active=role == .primary;let r=bounds.insetBy(dx:0.5,dy:0.5);let p=NSBezierPath(roundedRect:r,xRadius:8,yRadius:8)
  if active{AppPalette.action.withAlphaComponent(isEnabled ? (isHighlighted ? 0.75:1):0.35).setFill();p.fill()}
  else if role == .secondary || hovered || isHighlighted{AppPalette.raised.withAlphaComponent(isHighlighted ? 0.6:1).setFill();p.fill()}
  let ink: NSColor = !isEnabled ? .tertiaryLabelColor:(active ? NSColor.white:AppPalette.text)
  let font=NSFont.systemFont(ofSize:13,weight:.medium);let attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:ink]
  let textSize=(title as NSString).size(withAttributes:attrs)
  let hasImage=image != nil && imagePosition != .noImage;let hasText = !title.isEmpty && imagePosition != .imageOnly
  let width=(hasText ? textSize.width:0)+(hasImage ? 16:0)+(hasText && hasImage ? 7:0);var x=(bounds.width-width)/2
  if hasImage{drawAdaptiveSymbol(image,in:NSRect(x:x,y:bounds.midY-8,width:16,height:16),color:ink);x+=23}
  if hasText{(title as NSString).draw(at:NSPoint(x:x,y:bounds.midY-textSize.height/2),withAttributes:attrs)}
  if window?.firstResponder === self{AppPalette.accent.setStroke();let focus=NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:6,yRadius:6);focus.lineWidth=1.5;focus.stroke()}
 }
}
@discardableResult func styledButton(_ title:String,symbol:String?=nil,role:AppButton.Role = .secondary,frame:NSRect,target:AnyObject?,action:Selector)->AppButton{
 let button=AppButton(title:title,target:target,action:action);button.frame=frame;button.role=role
 if let symbol=symbol{button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.imagePosition=title.isEmpty ? .imageOnly:.imageLeading}
 return button
}
func configureButton(_ button:NSButton,role:AppButton.Role = .secondary){button.font = .systemFont(ofSize:13,weight:.medium);if let styled=button as? AppButton{styled.role=role};button.needsDisplay=true}
@discardableResult func designLabel(_ value:String,_ frame:NSRect,size:CGFloat=13,weight:NSFont.Weight = .regular,color:NSColor = .labelColor)->NSTextField{let f=CenteredTextField(labelWithString:value);f.frame=frame;f.font = .systemFont(ofSize:size,weight:weight);f.textColor=color;f.lineBreakMode = .byTruncatingTail;f.usesSingleLineMode=true;f.maximumNumberOfLines=1;return f}
func sectionLabel(_ value:String,_ frame:NSRect)->NSTextField{
 let f=designLabel(value.uppercased(),frame,size:10,weight:.semibold,color:AppPalette.secondary)
 f.attributedStringValue=NSAttributedString(string:value.uppercased(),attributes:[.font:NSFont.systemFont(ofSize:10,weight:.semibold),.foregroundColor:AppPalette.secondary,.kern:0.8]);return f
}
final class DesignRootSurface:DesignSurface {
 var closeControl:NSView?
 let headerHeight:CGFloat
 init(frame:NSRect,headerHeight:CGFloat){self.headerHeight=headerHeight;super.init(frame:frame)}
 required init?(coder:NSCoder){fatalError()}
 override func didAddSubview(_ subview:NSView){super.didAddSubview(subview);if let close=closeControl,subview !== close{addSubview(close,positioned:.above,relativeTo:nil)}}
 override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect);AppPalette.accent.withAlphaComponent(0.075).setFill();NSRect(x:0,y:bounds.maxY-headerHeight,width:bounds.width,height:headerHeight).fill()}
}
func installDesignRoot(_ window:NSWindow,headerHeight:CGFloat=106,showClose:Bool=true)->DesignSurface{
 window.backgroundColor = .clear;window.isOpaque=false;window.hasShadow=true
 let root=DesignRootSurface(frame:window.contentView!.bounds,headerHeight:headerHeight);root.autoresizingMask=[.width,.height];root.wantsLayer=true;root.layer?.cornerRadius=16;root.layer?.masksToBounds=true;window.contentView=root
 if showClose{let close=styledButton("",symbol:"xmark",role:.quiet,frame:NSRect(x:root.bounds.width-44,y:root.bounds.height-42,width:28,height:28),target:WindowChromeActions.shared,action:#selector(WindowChromeActions.close(_:)));close.autoresizingMask=[.minXMargin,.minYMargin];close.toolTip=L("Zavřít okno");close.setAccessibilityLabel(L("Zavřít okno"));root.closeControl=close;root.addSubview(close)}
 return root
}
@discardableResult func inputShell(_ field:NSView,frame:NSRect,in parent:NSView)->AdaptiveInputBackground{
 let shell=AdaptiveInputBackground(frame:frame)
 field.frame=NSRect(x:11,y:6,width:frame.width-22,height:frame.height-12)
 if let f=field as? NSTextField{f.isBordered=false;f.drawsBackground=false;f.font = .systemFont(ofSize:13);f.textColor = .textColor;f.usesSingleLineMode=true;f.lineBreakMode = .byTruncatingMiddle}
 if let f=field as? NSPopUpButton{f.isBordered=false;f.font = .systemFont(ofSize:13)}
 shell.addSubview(field);parent.addSubview(shell);return shell
}
func animateDesign(_ block:()->Void){NSAnimationContext.runAnimationGroup{context in context.duration=NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0:0.16;context.allowsImplicitAnimation=true;block()}}
final class DesignTopicRow:NSTableRowView {
 override func drawSelection(in dirtyRect:NSRect){if isSelected{AppPalette.accent.withAlphaComponent(0.14).setFill();NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:2),xRadius:8,yRadius:8).fill()}}
}

final class ContextLinkButton:AppButton {
 func fittingWidth(maximum:CGFloat)->CGFloat{min(maximum,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)+40)}
 override func draw(_ dirtyRect:NSRect){
  let ink=isEnabled ? AppPalette.accent:NSColor.tertiaryLabelColor
  drawAdaptiveSymbol(image,in:NSRect(x:8,y:bounds.midY-8,width:16,height:16),color:ink)
  let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
  let font=NSFont.systemFont(ofSize:13,weight:.medium);var attrs:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:ink,.paragraphStyle:paragraph]
  if isEnabled && (hovered || isHighlighted || window?.firstResponder === self){attrs[.underlineStyle]=NSUnderlineStyle.single.rawValue}
  let height=(title as NSString).size(withAttributes:attrs).height
  (title as NSString).draw(in:NSRect(x:32,y:bounds.midY-height/2,width:max(0,bounds.width-40),height:height),withAttributes:attrs)
 }
}
