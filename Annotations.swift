import AppKit

enum Tool:Int,Codable {case pen,arrow,ellipse,rectangle,text,select,crop}
struct Mark:Codable {
 var tool:Tool;var points:[NSPoint];var color:NSColor;var width:CGFloat;var text:String;var bold:Bool;var italic:Bool;var underline:Bool;var fontSize:CGFloat;var rotation:CGFloat = 0;var textWidth:CGFloat?;var textHeight:CGFloat?
 enum CodingKeys:String,CodingKey {case tool,points,rgba,width,text,bold,italic,underline,fontSize,rotation,textWidth,textHeight}
 init(tool:Tool,points:[NSPoint],color:NSColor,width:CGFloat,text:String,bold:Bool,italic:Bool,underline:Bool,fontSize:CGFloat,rotation:CGFloat=0){self.rotation=rotation;self.tool=tool;self.points=points;self.color=color;self.width=width;self.text=text;self.bold=bold;self.italic=italic;self.underline=underline;self.fontSize=fontSize}
 init(from decoder:Decoder)throws{let c=try decoder.container(keyedBy:CodingKeys.self);tool=try c.decode(Tool.self,forKey:.tool);points=try c.decode([NSPoint].self,forKey:.points);let v=try c.decode([CGFloat].self,forKey:.rgba);guard v.count==4 else{throw DecodingError.dataCorruptedError(forKey:.rgba,in:c,debugDescription:"Invalid color")};color=NSColor(srgbRed:v[0],green:v[1],blue:v[2],alpha:v[3]);width=try c.decode(CGFloat.self,forKey:.width);text=try c.decode(String.self,forKey:.text);bold=try c.decode(Bool.self,forKey:.bold);italic=try c.decode(Bool.self,forKey:.italic);underline=try c.decode(Bool.self,forKey:.underline);fontSize=try c.decode(CGFloat.self,forKey:.fontSize);rotation=try c.decodeIfPresent(CGFloat.self,forKey:.rotation) ?? 0;textWidth=try c.decodeIfPresent(CGFloat.self,forKey:.textWidth);textHeight=try c.decodeIfPresent(CGFloat.self,forKey:.textHeight)}
 func encode(to encoder:Encoder)throws{var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(tool,forKey:.tool);try c.encode(points,forKey:.points);let v=color.usingColorSpace(.sRGB) ?? .red;try c.encode([v.redComponent,v.greenComponent,v.blueComponent,v.alphaComponent],forKey:.rgba);try c.encode(width,forKey:.width);try c.encode(text,forKey:.text);try c.encode(bold,forKey:.bold);try c.encode(italic,forKey:.italic);try c.encode(underline,forKey:.underline);try c.encode(fontSize,forKey:.fontSize);try c.encode(rotation,forKey:.rotation);try c.encodeIfPresent(textWidth,forKey:.textWidth);try c.encodeIfPresent(textHeight,forKey:.textHeight)}
 var font:NSFont{var f=NSFont.systemFont(ofSize:fontSize,weight:bold ? .bold:.regular);if italic{f=NSFontManager.shared.convert(f,toHaveTrait:.italicFontMask)};return f}
 var attributes:[NSAttributedString.Key:Any]{var a:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:color];if underline{a[.underlineStyle]=NSUnderlineStyle.single.rawValue};return a}
 var textContentSize:NSSize{
  let value=(text.isEmpty ? "Text":text) as NSString
  if let textWidth{
   let height=value.boundingRect(with:NSSize(width:textWidth,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin],attributes:attributes).height
   return NSSize(width:textWidth,height:ceil(height))
  }
  let size=value.size(withAttributes:attributes)
  return NSSize(width:max(30,size.width),height:size.height)
 }
 var bounds:NSRect{guard let first=points.first else{return .zero};if tool == .text {
  let size=textContentSize
  return NSRect(origin:first,size:NSSize(width:size.width,height:max(size.height,textHeight ?? 0)))
 };let xs=points.map{$0.x},ys=points.map{$0.y};return NSRect(x:xs.min()!,y:ys.min()!,width:max(1,xs.max()!-xs.min()!),height:max(1,ys.max()!-ys.min()!))}
}
struct AnnotationDocument:Codable{var base:Data;var marks:[Mark];var crop:NSRect}
func annotationSidecar(_ image:URL)->URL{image.appendingPathExtension("annotations.json")}
func copyAnnotationSidecar(from:URL,to:URL)throws{let side=annotationSidecar(from);if FileManager.default.fileExists(atPath:side.path){try FileManager.default.copyItem(at:side,to:annotationSidecar(to))}}
func removeAnnotatedImage(_ image:URL){try? FileManager.default.removeItem(at:image);try? FileManager.default.removeItem(at:annotationSidecar(image))}

final class AnnotationTextView:NSTextView {
 override var mouseDownCanMoveWindow:Bool{false}
 override func resetCursorRects(){addCursorRect(bounds,cursor:.iBeam)}
}
final class DrawingView:NSView,NSTextViewDelegate {
 let image:NSImage
 var marks:[Mark]=[];var pending:Mark?;var selected:Int?;var viewport:NSRect
 var tool:Tool = .select{didSet{window?.invalidateCursorRects(for:self)}};var color:NSColor = .systemRed;var thickness:CGFloat=4
 var bold=false;var italic=false;var underline=false;var fontSize:CGFloat=28
 var changed:(()->Void)?;var dragStart:NSPoint?;var dragOriginal:[NSPoint]?;var cropStart:NSPoint?;var cropPreview:NSRect?
 var history:[([Mark],NSRect)]=[];var inline:NSTextView?;var editingIndex:Int?;var closingText=false;var transformDrag:AnnotationTransformDrag?
 override var acceptsFirstResponder:Bool{true}
 override var mouseDownCanMoveWindow:Bool{false}
 var toolCursor:NSCursor{tool == .text ? .iBeam:(tool == .select ? .arrow:.crosshair)}
 override func resetCursorRects(){
  super.resetCursorRects()
  if let drag=transformDrag{addCursorRect(bounds,cursor:drag.kind.cursor(for:drag.original));return}
  addCursorRect(imageRect,cursor:toolCursor);installTransformCursors()
 }
 override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
 init(image:NSImage,frame:NSRect){self.image=image;viewport=NSRect(origin:.zero,size:image.size);super.init(frame:frame)}
 required init?(coder:NSCoder){fatalError()}
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);updateInline();needsDisplay=true;window?.invalidateCursorRects(for:self)}
 var imageRect:NSRect{let scale=min(bounds.width/viewport.width,bounds.height/viewport.height);let size=NSSize(width:viewport.width*scale,height:viewport.height*scale);return NSRect(x:(bounds.width-size.width)/2,y:(bounds.height-size.height)/2,width:size.width,height:size.height)}
 var scale:CGFloat{imageRect.width/viewport.width}
 func point(_ event:NSEvent)->NSPoint{let p=convert(event.locationInWindow,from:nil),r=imageRect;return NSPoint(x:max(viewport.minX,min(viewport.maxX,(p.x-r.minX)/scale+viewport.minX)),y:max(viewport.minY,min(viewport.maxY,(p.y-r.minY)/scale+viewport.minY)))}
 func displayRect(_ rect:NSRect)->NSRect{let r=imageRect;return NSRect(x:r.minX+(rect.minX-viewport.minX)*scale,y:r.minY+(rect.minY-viewport.minY)*scale,width:rect.width*scale,height:rect.height*scale)}
 func snapshot(){history.append((marks,viewport));if history.count>40{history.removeFirst()}}
 func undoChange(){finishText();guard let last=history.popLast() else{return};marks=last.0;viewport=last.1;selected=nil;needsDisplay=true;changed?()}
 func paint(_ mark:Mark){guard let first=mark.points.first,let last=mark.points.last else{return}
  NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()}
  if mark.rotation != 0{let center=mark.bounds;let transform=NSAffineTransform();transform.translateX(by:center.midX,yBy:center.midY);transform.rotate(byRadians:mark.rotation);transform.translateX(by:-center.midX,yBy:-center.midY);transform.concat()}
  mark.color.setStroke();mark.color.setFill();let p=NSBezierPath();p.lineWidth=mark.width;p.lineCapStyle = .round;p.lineJoinStyle = .round
  switch mark.tool{
  case .pen:p.move(to:first);for q in mark.points.dropFirst(){p.line(to:q)};p.stroke()
  case .arrow:p.move(to:first);p.line(to:last);let angle=atan2(last.y-first.y,last.x-first.x),length=max(15,mark.width*4);for offset in [-CGFloat.pi/6,CGFloat.pi/6]{p.move(to:last);p.line(to:NSPoint(x:last.x-length*cos(angle+offset),y:last.y-length*sin(angle+offset)))};p.stroke()
  case .ellipse:let shape=NSBezierPath(ovalIn:mark.bounds);shape.lineWidth=mark.width;shape.stroke()
  case .rectangle:p.appendRect(mark.bounds);p.stroke()
  case .text:
   if mark.textWidth != nil{
    let content=mark.textContentSize
    let rect=NSRect(x:first.x,y:mark.bounds.maxY-content.height,width:content.width,height:content.height)
    (mark.text as NSString).draw(with:rect,options:[.usesLineFragmentOrigin],attributes:mark.attributes)
   }else{(mark.text as NSString).draw(at:first,withAttributes:mark.attributes)}
  default:break
  }
 }
 override func draw(_ dirtyRect:NSRect){AppPalette.canvas.setFill();bounds.fill();let r=imageRect;NSGraphicsContext.saveGraphicsState();r.clip();let t=NSAffineTransform();t.translateX(by:r.minX,yBy:r.minY);t.scale(by:scale);t.translateX(by:-viewport.minX,yBy:-viewport.minY);t.concat();image.draw(in:NSRect(origin:.zero,size:image.size));for(i,mark) in marks.enumerated(){if i != editingIndex{paint(mark)}};if let mark=pending{paint(mark)};NSGraphicsContext.restoreGraphicsState()
  drawSelectionHandles()
  if let rect=cropPreview{AppPalette.accent.setStroke();let p=NSBezierPath(rect:displayRect(rect));p.lineWidth=2;p.stroke()}
 }
 func hit(_ p:NSPoint)->Int?{let tolerance=max(6/scale,3);return marks.indices.reversed().first{index in let mark=marks[index],r=mark.bounds;let p=mark.unrotatedPoint(p);if mark.tool == .text{return r.insetBy(dx:-tolerance,dy:-tolerance).contains(p)}
   if mark.tool == .ellipse {let rx=max(1,r.width/2),ry=max(1,r.height/2);let value=pow((p.x-r.midX)/rx,2)+pow((p.y-r.midY)/ry,2);return abs(sqrt(value)-1)<=max(tolerance,mark.width)/min(rx,ry)}
   if mark.tool == .rectangle {return r.insetBy(dx:-tolerance,dy:-tolerance).contains(p) && !r.insetBy(dx:tolerance,dy:tolerance).contains(p)}
   for j in 1..<mark.points.count{let a=mark.points[j-1],b=mark.points[j],dx=b.x-a.x,dy=b.y-a.y;let t=max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/max(0.001,dx*dx+dy*dy)));if hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)<=max(tolerance,mark.width){return true}};return false
  }}
 func choose(_ index:Int?){selected=index;if let i=index{let m=marks[i];color=m.color;thickness=m.width;fontSize=m.fontSize;bold=m.bold;italic=m.italic;underline=m.underline};needsDisplay=true;window?.invalidateCursorRects(for:self);changed?()}
 override func mouseDown(with event:NSEvent){finishText();window?.makeFirstResponder(self);if tool == .select && beginTransform(with:event){return};guard imageRect.contains(convert(event.locationInWindow,from:nil)) else{choose(nil);return};let p=point(event)
  if tool == .select {let index=hit(p);choose(index);if let i=index{if event.clickCount==2 && marks[i].tool == .text{startText(i);return};dragStart=p;dragOriginal=marks[i].points;snapshot()};return}
  if tool == .crop {cropStart=p;return}
  if tool == .text {if let i=hit(p),marks[i].tool == .text{choose(i);startText(i)}else{snapshot();var mark=Mark(tool:.text,points:[p],color:color,width:thickness,text:"",bold:bold,italic:italic,underline:underline,fontSize:fontSize);mark.points[0].y=max(viewport.minY,p.y-mark.bounds.height);marks.append(mark);choose(marks.count-1);startText(marks.count-1)};return}
  snapshot();choose(nil);pending=Mark(tool:tool,points:[p,p],color:color,width:thickness,text:"",bold:bold,italic:italic,underline:underline,fontSize:fontSize)
 }
 override func mouseDragged(with event:NSEvent){if updateTransform(with:event){return};let p=point(event)
  if let start=cropStart{cropPreview=NSRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y));needsDisplay=true;return}
  if let i=selected,let start=dragStart,let original=dragOriginal{marks[i].points=original.map{NSPoint(x:$0.x+p.x-start.x,y:$0.y+p.y-start.y)};needsDisplay=true;return}
  guard var mark=pending else{return};if mark.tool == .pen{mark.points.append(p)}else{mark.points[1]=p};pending=mark;needsDisplay=true
 }
 override func mouseUp(with event:NSEvent){if let mark=pending{marks.append(mark);pending=nil;tool = .select;choose(marks.count-1)};if let rect=cropPreview{applyCrop(rect)};cropStart=nil;cropPreview=nil;dragStart=nil;dragOriginal=nil
  if transformDrag != nil {
   transformDrag=nil
   let p=convert(event.locationInWindow,from:nil)
   if bounds.contains(p),let i=selected,marks.indices.contains(i){
    let mark=marks[i]
    (transformHandle(at:p,for:mark)?.cursor(for:mark) ?? toolCursor).set()
   }else{NSCursor.arrow.set()}
  }
  needsDisplay=true;window?.invalidateCursorRects(for:self)
 }
 func applyCrop(_ rect:NSRect){let clipped=viewport.intersection(rect).integral.intersection(viewport);guard clipped.width>=8 && clipped.height>=8 else{return};snapshot();viewport=clipped;choose(nil);tool = .select;changed?()}
 @objc func delete(_ sender:Any?){finishText();if let index=selected,marks.indices.contains(index){snapshot();marks.remove(at:index);choose(nil)}}
 override func keyDown(with event:NSEvent){if event.keyCode==51 || event.keyCode==117{delete(nil)}else{super.keyDown(with:event)}}
 func updateSelected(){if let i=selected,marks.indices.contains(i){snapshot();marks[i].color=color;marks[i].width=thickness;marks[i].fontSize=fontSize;marks[i].bold=bold;marks[i].italic=italic;marks[i].underline=underline;updateInline()};needsDisplay=true}
 func startText(_ index:Int){
  guard marks.indices.contains(index),marks[index].tool == .text else{return}
  snapshot();editingIndex=index
  let edit=AnnotationTextView(frame:.zero);edit.isRichText=false;edit.allowsUndo=true;edit.drawsBackground=false;edit.backgroundColor = .clear;edit.focusRingType = .none
  edit.textContainerInset = .zero;edit.textContainer?.lineFragmentPadding=0;edit.textContainer?.widthTracksTextView=false;edit.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
  edit.isHorizontallyResizable=false;edit.isVerticallyResizable=false;edit.isAutomaticQuoteSubstitutionEnabled=false;edit.isAutomaticDashSubstitutionEnabled=false
  edit.string=marks[index].text;edit.delegate=self;inline=edit;addSubview(edit);updateInline();window?.makeFirstResponder(edit);needsDisplay=true;changed?()
 }
 func updateInline(){
  guard let edit=inline,let i=editingIndex,marks.indices.contains(i) else{return}
  let mark=marks[i];let frame=displayRect(mark.bounds)
  edit.frameRotation=0
  let origin=displayPoint(mark.rotatedPoint(mark.bounds.origin))
  edit.frame=NSRect(x:origin.x,y:origin.y,width:max(8,frame.width+(mark.textWidth == nil ? 2:0)),height:frame.height)
  edit.textContainer?.containerSize=NSSize(width:mark.textWidth ?? .greatestFiniteMagnitude,height:.greatestFiniteMagnitude)
  // Scale the text view's coordinate system, keeping the exact same font metrics as export.
  // Recreating a smaller system font changes optical sizing and makes the text jump.
  edit.bounds=NSRect(x:0,y:0,width:edit.frame.width/scale,height:edit.frame.height/scale)
  edit.frameRotation=mark.rotation*180 / .pi
  let font=mark.font
  var attrs=mark.attributes;attrs[.font]=font
  let selection=edit.selectedRange();edit.font=font;edit.textColor=mark.color;edit.insertionPointColor=mark.color;edit.typingAttributes=attrs
  edit.textStorage?.setAttributes(attrs,range:NSRange(location:0,length:(edit.string as NSString).length));edit.setSelectedRange(NSRange(location:min(selection.location,(edit.string as NSString).length),length:min(selection.length,max(0,(edit.string as NSString).length-selection.location))))
  edit.needsDisplay=true
 }
 func textDidChange(_ notification:Notification){guard let edit=inline,let i=editingIndex else{return};marks[i].text=edit.string;updateInline();needsDisplay=true}
 func textView(_ textView:NSTextView,doCommandBy selector:Selector)->Bool{if selector==#selector(NSResponder.insertNewline(_:)) || selector==#selector(NSResponder.cancelOperation(_:)){finishText();return true};return false}
 func finishText(){guard !closingText,let i=editingIndex else{return};closingText=true;marks[i].text=inline?.string ?? marks[i].text;inline?.removeFromSuperview();inline=nil;editingIndex=nil;if marks[i].text.isEmpty{marks.remove(at:i);selected=nil};window?.makeFirstResponder(self);closingText=false;tool = .select;needsDisplay=true;changed?()}
 func png()->Data?{let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(viewport.width),pixelsHigh:Int(viewport.height),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep);let t=NSAffineTransform();t.translateX(by:-viewport.minX,yBy:-viewport.minY);t.concat();image.draw(in:NSRect(origin:.zero,size:image.size));for mark in marks{paint(mark)};NSGraphicsContext.restoreGraphicsState();return rep.representation(using:.png,properties:[:])}
}

// Explicit modal support is required by the editor's modal event loop.
final class ModalColorWell:NSColorWell {
 override func activate(_ exclusive:Bool) {
  let panel=NSColorPanel.shared
  panel.worksWhenModal=true
  prepareScreenshotPanel(panel)
  super.activate(exclusive)
  panel.orderFrontRegardless()
 }
}
final class AnnotationToolButton:NSButton {
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
 override func draw(_ dirtyRect:NSRect) {
  let active=state == .on
  let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:6,yRadius:6)
  (active ? AppPalette.action:AppPalette.raised).setFill();path.fill()
  let color=active ? NSColor.white:NSColor.labelColor
  let glyph=NSRect(x:bounds.midX-10,y:bounds.midY-10,width:20,height:20)
  drawAdaptiveSymbol(image,in:glyph,color:color)
 }
}
func annotationWindowSize(image:NSSize,available:NSSize)->NSSize {
 let maxW=max(400,available.width-60),maxH=max(300,available.height-85)
 let factor=min(1,(maxW-32)/image.width,(maxH-122)/image.height)
 return NSSize(width:min(maxW,max(740,image.width*factor+32)),height:min(maxH,max(340,image.height*factor+122)))
}

final class AnnotationEditor:NSObject,NSWindowDelegate {
 var window:NSWindow!;var canvas:DrawingView!;var accepted=false;var baseData=Data();var workingURL:URL?;var initialMarks:Data?;var initialCrop:NSRect?
 let tools:[Tool]=[.select,.pen,.arrow,.ellipse,.rectangle,.text,.crop];var toolButtons:[NSButton]=[]
 var onValuePickerPresented:((NSWindow,[NSButton])->Void)?
 let colors=ModalColorWell();var width:NSButton!;var size:NSButton!;var textControls:[NSView]=[];var styleButtons:[NSButton]=[]
 func icon(_ symbol:String,_ help:String,_ action:Selector,_ frame:NSRect)->NSButton{let b=AnnotationToolButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:help) ?? NSImage(),target:self,action:action);b.frame=frame;b.toolTip=help;b.bezelStyle = .texturedRounded;b.autoresizingMask=[.minYMargin];window.contentView!.addSubview(b);return b}
 func run(url:URL)->Bool{
  workingURL=url
  do{baseData=try Data(contentsOf:url)}catch{return false}
  var document:AnnotationDocument?
  if FileManager.default.fileExists(atPath:annotationSidecar(url).path){do{document=try JSONDecoder().decode(AnnotationDocument.self,from:Data(contentsOf:annotationSidecar(url)));baseData=document!.base}catch{showError(L("Nelze načíst editovatelné anotace: ")+error.localizedDescription);return false}}
  guard let image=NSImage(data:baseData) else{return false};if let rep=image.representations.first{image.size=NSSize(width:rep.pixelsWide,height:rep.pixelsHigh)}
  let screen=NSApp.keyWindow?.screen?.visibleFrame ?? capturePresentationScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:850)
  let dimensions=annotationWindowSize(image:document?.crop.size ?? image.size,available:screen.size),w=dimensions.width,h=dimensions.height
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:w,height:h),styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Upravit screenshot");window.delegate=self;window.minSize=NSSize(width:min(740,w),height:min(340,h))
  _ = installDesignRoot(window,headerHeight:62,showClose:false)
  let symbols=["cursorarrow","pencil.tip","arrow.up.right","circle","rectangle","textformat","crop"],helps=[L("Výběr · tažením přesunout, dvojklikem upravit text"),L("Kreslení"),L("Šipka"),L("Kruh / elipsa"),L("Rámeček"),L("Text přímo do obrázku"),L("Oříznout · tažením označ zachovanou oblast")]
  _ = icon("arrow.counterclockwise",L("Vrátit poslední úpravu"),#selector(undoMark),NSRect(x:16,y:h-48,width:36,height:34))
  for x in [CGFloat(64),390]{let divider=DesignDivider(NSRect(x:x,y:h-43,width:1,height:24));divider.autoresizingMask=[.minYMargin];window.contentView!.addSubview(divider)}
  for i in tools.indices{let b=icon(symbols[i],helps[i],#selector(selectTool(_:)),NSRect(x:78+CGFloat(i)*44,y:h-48,width:36,height:34));b.tag=i;b.setButtonType(.toggle);toolButtons.append(b)}
  colors.frame=NSRect(x:406,y:h-48,width:38,height:34);colors.toolTip=L("Barva vybraného objektu nebo nového tahu");colors.color = .systemRed;colors.target=self;colors.action=#selector(changeColor);colors.autoresizingMask=[.minYMargin];window.contentView!.addSubview(colors)
  width=icon("lineweight",L("Tloušťka čáry"),#selector(widthMenu),NSRect(x:460,y:h-48,width:36,height:34))
  size=icon("textformat.size",L("Velikost textu"),#selector(sizeMenu),NSRect(x:460,y:h-48,width:36,height:34));textControls.append(size)
  for(i,pair) in [("bold",L("Tučné písmo")),("italic",L("Kurzíva")),("underline",L("Podtržení"))].enumerated(){let b=icon(pair.0,pair.1,#selector(changeText(_:)),NSRect(x:504+CGFloat(i)*44,y:h-48,width:36,height:34));b.setButtonType(.toggle);b.tag=i;styleButtons.append(b);textControls.append(b)}
  let close=icon("xmark",L("Zavřít okno"),#selector(cancel),NSRect(x:w-56,y:h-48,width:36,height:34));close.autoresizingMask=[.minXMargin,.minYMargin]
  canvas=DrawingView(image:image,frame:NSRect(x:16,y:65,width:w-32,height:h-122));canvas.autoresizingMask=[.width,.height];if let doc=document{canvas.marks=doc.marks;canvas.viewport=doc.crop};canvas.changed={[weak self] in self?.sync()};window.contentView!.addSubview(canvas)
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:20,y:18,width:100,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";window.contentView!.addSubview(cancel)
  let apply=styledButton(L("Použít úpravy"),symbol:"checkmark",role:.primary,frame:NSRect(x:w-190,y:18,width:170,height:34),target:self,action:#selector(apply));apply.autoresizingMask=[.minXMargin];apply.keyEquivalent="\r";window.contentView!.addSubview(apply)
  recordInitialState()
  sync();presentScreenshotPanel(window);window.makeFirstResponder(canvas);if isExportingDesign{exportDesignWindow(window,name:"annotations");return false};NSApp.runModal(for:window);window.orderOut(nil)
  return accepted
 }
 func encodedMarks()throws->Data{let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return try encoder.encode(canvas.marks)}
 func recordInitialState(){initialMarks=try? encodedMarks();initialCrop=canvas.viewport}
 var hasUnsavedChanges:Bool{initialMarks != (try? encodedMarks()) || initialCrop != canvas.viewport}
 func requestedCloseChoice(confirm:()->AnnotationCloseChoice)->AnnotationCloseChoice{hasUnsavedChanges ? confirm():.discard}
 func saveWorkingImage()throws{
  guard hasUnsavedChanges else{return}
  guard let url=workingURL,let data=canvas.png() else{throw NSError(domain:"ScreenshotNote",code:6,userInfo:[NSLocalizedDescriptionKey:L("Anotace se nepodařilo uložit.")])}
  let side=try JSONEncoder().encode(AnnotationDocument(base:baseData,marks:canvas.marks,crop:canvas.viewport)),old=try Data(contentsOf:url)
  try data.write(to:url,options:.atomic)
  do{try side.write(to:annotationSidecar(url),options:.atomic)}catch{try? old.write(to:url,options:.atomic);throw error}
 }

 func sync(){
  guard canvas != nil else{return}
  for(i,b) in toolButtons.enumerated(){b.state=tools[i]==canvas.tool ? .on:.off;b.needsDisplay=true}
  let selectedTool=canvas.selected.flatMap{canvas.marks.indices.contains($0) ? canvas.marks[$0].tool:nil}
  let context=canvas.editingIndex != nil ? Tool.text:(canvas.tool == .select ? selectedTool:canvas.tool)
  let text=context == .text
  colors.isHidden = ![Tool.pen,.arrow,.ellipse,.rectangle,.text].contains(where:{$0==context})
  width.isHidden = ![Tool.pen,.arrow,.ellipse,.rectangle].contains(where:{$0==context})
  for control in textControls{control.isHidden = !text}
  colors.color=canvas.color;width.toolTip=LF("Tloušťka čáry · %ld px",Int(canvas.thickness));size.toolTip=LF("Velikost textu · %ld pt",Int(canvas.fontSize))
  for(i,value) in [canvas.bold,canvas.italic,canvas.underline].enumerated(){styleButtons[i].state=value ? .on:.off;styleButtons[i].needsDisplay=true}
 }

 @objc func selectTool(_ sender:NSButton){canvas.finishText();canvas.tool=tools[sender.tag];if canvas.tool != .select{canvas.choose(nil)};sync()}
 @objc func changeColor(){canvas.color=colors.color;canvas.updateSelected()}
 @objc func widthMenu(){
  if let value=AnnotationValuePicker().run(values:[1,2,4,6,10,16],unit:"px",title:L("Tloušťka čáry"),current:canvas.thickness,anchor:width,onPresented:onValuePickerPresented){canvas.thickness=value;canvas.updateSelected();sync()};window?.makeKeyAndOrderFront(nil)
 }
 @objc func sizeMenu(){
  if let value=AnnotationValuePicker().run(values:[16,24,28,36,48,64],unit:"pt",title:L("Velikost textu"),current:canvas.fontSize,anchor:size,onPresented:onValuePickerPresented){canvas.fontSize=value;canvas.updateSelected();sync()};window?.makeKeyAndOrderFront(nil)
 }
 @objc func changeText(_ sender:NSButton){
  switch sender.tag{case 0:canvas.bold.toggle();case 1:canvas.italic.toggle();default:canvas.underline.toggle()}
  canvas.updateSelected();sync()
 }
 @objc func undoMark(){canvas.undoChange()};@objc func deleteMark(){canvas.delete(nil)}

 @objc func apply(){
  window.makeFirstResponder(nil);canvas.finishText()
  do{try saveWorkingImage()}catch{showError(error.localizedDescription);return}
  colors.deactivate();NSColorPanel.shared.orderOut(nil);accepted=true;NSApp.stopModal()
 }
 @objc func cancel(){
  canvas.finishText()
  switch requestedCloseChoice(confirm:{AnnotationCloseDialog().run()}){
  case .save:apply()
  case .discard:colors.deactivate();NSColorPanel.shared.orderOut(nil);accepted=false;NSApp.stopModal()
  case .cancel:window.makeKeyAndOrderFront(nil)
  }
 }

 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}

/// Use a nested modal panel: NSMenu action dispatch is unreliable inside the annotation modal loop.
final class AnnotationValuePicker:NSObject,NSWindowDelegate {
 var window:NSWindow!;var values:[CGFloat]=[];var chosen:CGFloat?
 func run(values:[CGFloat],unit:String,title:String,current:CGFloat,anchor:NSView,onPresented:((NSWindow,[NSButton])->Void)?=nil)->CGFloat?{
  self.values=values
  let width=CGFloat(values.count)*62+18
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:width,height:88),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);window.delegate=self;window.isReleasedWhenClosed=false
  let root=installDesignRoot(window,headerHeight:0,showClose:false)
  root.addSubview(designLabel(title,NSRect(x:12,y:54,width:width-60,height:22),size:12,weight:.medium))
  let cancel=styledButton("",symbol:"xmark",role:.quiet,frame:NSRect(x:width-38,y:52,width:26,height:26),target:self,action:#selector(close));cancel.keyEquivalent="\u{1b}";cancel.toolTip=L("Zavřít okno");root.addSubview(cancel)
  var buttons:[NSButton]=[]
  for(i,value) in values.enumerated(){let button=styledButton("\(Int(value)) \(unit)",role:value==current ? .primary:.secondary,frame:NSRect(x:12+CGFloat(i)*62,y:12,width:56,height:32),target:self,action:#selector(selectValue(_:)));button.tag=i;if value==current{button.keyEquivalent="\r"};root.addSubview(button);buttons.append(button)}
  let frame=anchor.window?.convertToScreen(anchor.convert(anchor.bounds,to:nil)) ?? .zero
  let visible=anchor.window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
  window.setFrameOrigin(NSPoint(x:max(visible.minX,min(frame.minX,visible.maxX-width)),y:max(visible.minY,frame.minY-94)))
  prepareScreenshotPanel(window)
  onPresented?(window,buttons)
  NSApp.runModal(for:window);window.orderOut(nil);return chosen
 }
 @objc func selectValue(_ sender:NSButton){guard values.indices.contains(sender.tag) else{return};chosen=values[sender.tag];NSApp.stopModal()}
 @objc func close(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{close();return false}
}

enum AnnotationCloseChoice{case save,discard,cancel}
final class AnnotationCloseDialog:NSObject,NSWindowDelegate {
 var window:NSWindow!;var choice=AnnotationCloseChoice.cancel
 func run()->AnnotationCloseChoice{
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:510,height:200),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);window.delegate=self
  let root=installDesignRoot(window,headerHeight:0,showClose:false)
  root.addSubview(designLabel(L("Uložit změny anotací?"),NSRect(x:28,y:140,width:454,height:32),size:20,weight:.semibold))
  root.addSubview(designLabel(L("Anotace nebo ořez ještě nejsou uložené."),NSRect(x:28,y:98,width:454,height:28),size:12,color:AppPalette.secondary))
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:28,y:24,width:100,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";root.addSubview(cancel)
  root.addSubview(styledButton(L("Zahodit změny"),frame:NSRect(x:174,y:24,width:172,height:34),target:self,action:#selector(discard)))
  let save=styledButton(L("Uložit"),role:.primary,frame:NSRect(x:362,y:24,width:120,height:34),target:self,action:#selector(save));save.keyEquivalent="\r";root.addSubview(save)
  presentScreenshotPanel(window)
  if isExportingDesign{exportDesignWindow(window,name:"annotation-close");return .cancel}
  NSApp.runModal(for:window);window.orderOut(nil);return choice
 }
 @objc func save(){choice = .save;NSApp.stopModal()}
 @objc func discard(){choice = .discard;NSApp.stopModal()}
 @objc func cancel(){choice = .cancel;NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}
