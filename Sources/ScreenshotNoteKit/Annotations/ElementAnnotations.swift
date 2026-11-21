import AppKit

// Anotace Element: výběr prvku stránky z mapy elementů (PROTOCOL.md, Mapování elementů).

/// Data prvku uložená v anotaci; číslo určuje pořadí v exportu.
struct ElementInfo:Codable,Equatable {var number:Int;var selector:String;var tag:String;var name:String;var text:String}
/// Prvek mapy v souřadnicích editoru (pixely obrázku, počátek vlevo dole).
struct ElementTarget:Equatable {var index:Int;var selector:String;var tag:String;var name:String;var text:String;var depth:Int;var rect:NSRect}

func elementTargets(_ mapped:[MappedElement],imageHeight:CGFloat)->[ElementTarget]{
 mapped.map{ElementTarget(index:$0.index,selector:$0.selector,tag:$0.tag,name:$0.name,text:$0.text,depth:$0.depth,rect:NSRect(x:$0.rect.minX,y:imageHeight-$0.rect.maxY,width:$0.rect.width,height:$0.rect.height))}
}
/// Ořez editoru prvky ořízne, prvky mimo něj vynechá.
func clippedTargets(_ targets:[ElementTarget],to viewport:NSRect)->[ElementTarget]{
 targets.compactMap{target in let rect=target.rect.intersection(viewport);guard !rect.isNull,rect.width>=1,rect.height>=1 else{return nil};var result=target;result.rect=rect;return result}
}
private func area(_ rect:NSRect)->CGFloat{rect.width*rect.height}
/// Nejmenší prvek pod bodem; při shodě vyhrává hlubší.
func smallestElement(at point:NSPoint,in targets:[ElementTarget])->ElementTarget?{
 targets.filter{$0.rect.contains(point)}.min{area($0.rect) != area($1.rect) ? area($0.rect)<area($1.rect):$0.depth>$1.depth}
}
/// Nejbližší prvek, který obsahuje daný; shodný obdélník je rodičem jen s menší hloubkou.
func parentElement(of target:ElementTarget,in targets:[ElementTarget])->ElementTarget?{
 targets.filter{$0.index != target.index && $0.rect.insetBy(dx:-1,dy:-1).contains(target.rect) && ($0.depth<target.depth || area($0.rect)>area(target.rect)+1)}
  .min{area($0.rect) != area($1.rect) ? area($0.rect)<area($1.rect):$0.depth>$1.depth}
}
/// Posune uložený výřez snímku na oříznutou část obrázku, aby mapa seděla i po exportu.
func croppedCapture(_ capture:CaptureGeometry,crop:NSRect)->CaptureGeometry{
 let scale=capture.imageScale,height=capture.rect.height*scale
 var result=capture
 result.rect=CGRect(x:capture.rect.minX+crop.minX/scale,y:capture.rect.minY+(height-crop.maxY)/scale,width:crop.width/scale,height:crop.height/scale)
 return result
}

// MARK: Export

private struct ElementSidecar:Decodable{var marks:[Mark];var crop:NSRect}
private func flattened(_ value:String,limit:Int)->String{
 let words=value.split(whereSeparator:{$0.isWhitespace || $0.isNewline}).joined(separator:" ")
 return words.count>limit ? String(words.prefix(limit-1))+"…":words
}
private func escapedMarkdown(_ value:String)->String{
 var result="";for c in value{if "\\`*_[]()<>!#|~".contains(c){result.append("\\")};result.append(c)};return result
}
private func codeSpan(_ value:String)->String{
 var run=0,longest=0;for c in value{run=c=="`" ? run+1:0;longest=max(longest,run)}
 let fence=String(repeating:"`",count:longest+1),pad=value.hasPrefix("`") || value.hasSuffix("`") ? " ":""
 return fence+pad+value+pad+fence
}
/// Řádky `- **[1] Element** `selector` „name“: popis` seřazené podle čísla; prvky mimo ořez vynechá.
func elementMarkdownLines(_ marks:[Mark],crop:NSRect?)->String{
 marks.compactMap{mark->(Int,String)? in
  guard mark.tool == .element,let info=mark.element else{return nil}
  if let crop,mark.bounds.intersection(crop).isNull{return nil}
  // Selektor nesmí vypadat jako odkaz na obrázek, jinak by ho znovuotevření relace bralo jako snímek.
  var selector=flattened(info.selector,limit:300);if !imageLinks(selector).isEmpty{selector=flattened(info.tag,limit:40)}
  let label=flattened(info.name.isEmpty ? info.text:info.name,limit:80),note=flattened(mark.text,limit:2000)
  var line="- **[\(info.number)] Element**"
  if !selector.isEmpty{line+=" "+codeSpan(selector)}
  if !label.isEmpty{line+=" „"+escapedMarkdown(label)+"“"}
  if !note.isEmpty{line+=": "+note}
  return (info.number,line)
 }.sorted{$0.0<$1.0}.map{$0.1}.joined(separator:"\n")
}
/// Popisek obrázku doplněný o řádky anotací Element z pracovní kopie anotací.
func captionWithElements(_ note:String,image:URL)->String{
 guard let data=try? Data(contentsOf:annotationSidecar(image)),let document=try? JSONDecoder().decode(ElementSidecar.self,from:data) else{return note}
 return [note,elementMarkdownLines(document.marks,crop:document.crop)].filter{!$0.isEmpty}.joined(separator:"\n\n")
}
/// Po ořezu v editoru přepíše `capture` v exportovaném kontextu na oříznutou část.
func adjustContextCapture(_ contextFile:URL,annotations:URL){
 guard let data=try? Data(contentsOf:annotations),let document=try? JSONDecoder().decode(ElementSidecar.self,from:data),
  let raw=try? boundedData(contextFile,max:maxContextBytes),var object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],let capture=CaptureGeometry(json:object["capture"]) else{return}
 let full=NSRect(x:0,y:0,width:capture.rect.width*capture.imageScale,height:capture.rect.height*capture.imageScale)
 guard abs(document.crop.minX-full.minX)>0.5 || abs(document.crop.minY-full.minY)>0.5 || abs(document.crop.width-full.width)>0.5 || abs(document.crop.height-full.height)>0.5,
  full.insetBy(dx:-0.5,dy:-0.5).contains(document.crop) else{return}
 object["capture"]=croppedCapture(capture,crop:document.crop).json
 guard let output=try? JSONSerialization.data(withJSONObject:object) else{return}
 try? output.write(to:contextFile,options:.atomic);try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:contextFile.path)
}

// MARK: Editor

extension DrawingView:NSTextFieldDelegate {
 var visibleElements:[ElementTarget]{clippedTargets(elementMap,to:viewport)}
 var nextElementNumber:Int{(marks.compactMap{$0.element?.number}.max() ?? 0)+1}
 func elementMark(_ target:ElementTarget,number:Int)->Mark{
  var mark=Mark(tool:.element,points:[target.rect.origin,NSPoint(x:target.rect.maxX,y:target.rect.maxY)],color:color,width:max(2,min(thickness,6)),text:"",bold:false,italic:false,underline:false,fontSize:fontSize)
  mark.element=ElementInfo(number:number,selector:target.selector,tag:target.tag,name:target.name,text:target.text);return mark
 }
 func renumberElements(){
  let order=marks.indices.filter{marks[$0].element != nil}.sorted{marks[$0].element!.number<marks[$1].element!.number}
  for (number,index) in order.enumerated(){marks[index].element?.number=number+1}
 }
 /// Klik vybere nejmenší prvek; klik do právě vybraného nebo s ⌥ posune výběr na rodiče.
 func elementClick(_ point:NSPoint,parent:Bool){
  let visible=visibleElements
  if let active=activeElement,marks.indices.contains(active.mark),marks[active.mark].tool == .element,let current=visible.first(where:{$0.index==active.target}),current.rect.contains(point){
   if let up=parentElement(of:current,in:visible){snapshot();let number=marks[active.mark].element?.number ?? nextElementNumber,note=marks[active.mark].text;marks[active.mark]=elementMark(up,number:number);marks[active.mark].text=note;activeElement=(active.mark,up.index)}
   choose(active.mark);startElementNote(active.mark);return
  }
  guard var target=smallestElement(at:point,in:visible) else{activeElement=nil;choose(nil);return}
  if parent,let up=parentElement(of:target,in:visible){target=up}
  snapshot();marks.append(elementMark(target,number:nextElementNumber));activeElement=(marks.count-1,target.index)
  choose(marks.count-1);startElementNote(marks.count-1)
 }
 /// Esc zruší rozpracovaný výběr; bez něj ukončí nástroj.
 func cancelActiveElement(){
  dropElementField()
  if let active=activeElement,marks.indices.contains(active.mark),marks[active.mark].tool == .element{snapshot();marks.remove(at:active.mark);renumberElements();choose(nil)}
  else if activeElement == nil{tool = .select}
  activeElement=nil;hoverElement=nil;needsDisplay=true;changed?()
 }
 func startElementNote(_ index:Int){
  guard marks.indices.contains(index),marks[index].tool == .element else{return}
  commitElementNote()
  let field=NSTextField(frame:.zero);field.placeholderString=L("Popis elementu · Enter potvrdí, Esc zruší výběr");field.stringValue=marks[index].text;field.font = .systemFont(ofSize:13);field.focusRingType = .none;field.bezelStyle = .roundedBezel;field.delegate=self
  elementField=field;elementFieldIndex=index;addSubview(field);updateElementField();window?.makeFirstResponder(field)
 }
 func updateElementField(){
  guard let field=elementField,let i=elementFieldIndex,marks.indices.contains(i) else{return}
  let rect=displayRect(marks[i].bounds.intersection(viewport).isNull ? marks[i].bounds:marks[i].bounds.intersection(viewport)),width=min(max(220,rect.width),max(220,bounds.width-8))
  var y=rect.minY-30;if y<bounds.minY+4{y=min(rect.maxY+6,bounds.maxY-30)}
  field.frame=NSRect(x:max(bounds.minX+4,min(rect.minX,bounds.maxX-width-4)),y:y,width:width,height:24)
 }
 func dropElementField(){
  guard let field=elementField else{return}
  closingElementNote=true;field.removeFromSuperview();elementField=nil;elementFieldIndex=nil;closingElementNote=false;window?.makeFirstResponder(self)
 }
 func commitElementNote(){
  guard !closingElementNote,let field=elementField,let i=elementFieldIndex else{return}
  let value=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
  dropElementField()
  if marks.indices.contains(i),marks[i].tool == .element,marks[i].text != value{marks[i].text=value;changed?()}
  needsDisplay=true
 }
 func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool{
  guard control === elementField else{return false}
  if selector==#selector(NSResponder.insertNewline(_:)){commitElementNote();activeElement=nil;return true}
  if selector==#selector(NSResponder.cancelOperation(_:)){cancelActiveElement();return true}
  return false
 }
 func controlTextDidEndEditing(_ notification:Notification){if (notification.object as AnyObject?) === elementField{commitElementNote()}}

 /// Přerušovaný obdélník a číselný odznak; obojí zůstává uvnitř ořezu.
 func paintElement(_ mark:Mark){
  let rect=mark.bounds.intersection(viewport);guard !rect.isNull else{return}
  let path=NSBezierPath(rect:rect.insetBy(dx:mark.width/2,dy:mark.width/2));path.lineWidth=mark.width;path.setLineDash([mark.width*3,mark.width*2],count:2,phase:0);mark.color.setStroke();path.stroke()
  guard let number=mark.element?.number else{return}
  let size=max(24,mark.width*6),x=max(viewport.minX+size/2,min(viewport.maxX-size/2,rect.minX)),y=max(viewport.minY+size/2,min(viewport.maxY-size/2,rect.maxY))
  let badge=NSRect(x:x-size/2,y:y-size/2,width:size,height:size);mark.color.setFill();NSBezierPath(ovalIn:badge).fill()
  let label="\(number)" as NSString,attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:size*0.55,weight:.bold),.foregroundColor:NSColor.white]
  let text=label.size(withAttributes:attributes);label.draw(at:NSPoint(x:badge.midX-text.width/2,y:badge.midY-text.height/2),withAttributes:attributes)
 }
 func drawElementHover(){
  guard tool == .element,let index=hoverElement,let target=visibleElements.first(where:{$0.index==index}) else{return}
  let rect=displayRect(target.rect);AppPalette.accent.withAlphaComponent(0.14).setFill();rect.fill()
  let outline=NSBezierPath(rect:rect.insetBy(dx:0.75,dy:0.75));outline.lineWidth=1.5;AppPalette.accent.setStroke();outline.stroke()
  let title=flattened([target.tag,target.name.isEmpty ? target.text:target.name].filter{!$0.isEmpty}.joined(separator:" · "),limit:60) as NSString
  guard title.length>0 else{return}
  let attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white],size=title.size(withAttributes:attributes)
  var origin=NSPoint(x:max(bounds.minX+2,min(rect.minX,bounds.maxX-size.width-10)),y:rect.maxY+3);if origin.y+size.height+4>bounds.maxY{origin.y=max(bounds.minY+2,rect.maxY-size.height-7)}
  let background=NSRect(x:origin.x,y:origin.y,width:size.width+8,height:size.height+4);AppPalette.accent.setFill();NSBezierPath(roundedRect:background,xRadius:4,yRadius:4).fill()
  title.draw(at:NSPoint(x:origin.x+4,y:origin.y+2),withAttributes:attributes)
 }
}
