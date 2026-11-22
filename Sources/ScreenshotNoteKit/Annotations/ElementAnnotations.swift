import AppKit

// Anotace Element: výběr prvku stránky z mapy elementů (PROTOCOL.md, Mapování elementů).

/// Data prvku uložená v anotaci; číslo určuje pořadí v exportu.
struct ElementInfo:Codable,Equatable {var number:Int;var selector:String;var tag:String;var name:String;var text:String}
/// Prvek mapy v souřadnicích editoru (pixely obrázku, počátek vlevo dole).
/// Rozpracovaný výběr: anotace, aktuální prvek, prvek pod prvním klikem a zda je popis potvrzený.
struct ActiveElement {var mark:Int;var target:Int;var origin:Int;var confirmed=false}
/// Číslo a text komentáře anotace: Element má popis v `text`, ostatní tvary v `comment`.
extension Mark {
 var noteNumber:Int?{tool == .element ? element?.number:number}
 var noteText:String{tool == .element ? text:(comment ?? "")}
 /// Odznak čísla: u čar u počátku, u ostatních tvarů v levém horním rohu.
 var badgeAnchor:NSPoint{[.pen,.arrow].contains(tool) ? (points.first ?? bounds.origin):NSPoint(x:bounds.minX,y:bounds.maxY)}
 var noteLabel:String{
  switch tool{case .pen:L("Kresba");case .arrow:L("Šipka");case .ellipse:L("Kruh");case .rectangle:L("Rámeček");case .text:L("Text");default:"Element"}
 }
}
/// Nejvyšší číslo anotace, které už popisek obsahuje (relace otevřená znovu).
func highestElementNumber(in caption:String)->Int{
 let expression=try! NSRegularExpression(pattern:"^- \\*\\*\\[(\\d{1,6})\\] (?:Element|Kresba|Šipka|Kruh|Rámeček|Text|Drawing|Arrow|Circle|Rectangle)\\*\\*",options:[.anchorsMatchLines]),ns=caption as NSString
 return expression.matches(in:caption,range:NSRange(location:0,length:ns.length)).compactMap{Int(ns.substring(with:$0.range(at:1)))}.max() ?? 0
}
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
/// Komentář je text uživatele; obrázkový odkaz v něm se escapuje, jinak by ho znovuotevření bralo jako snímek.
/// Víceřádkový komentář pokračuje odsazenými řádky téže položky seznamu.
private func safeNote(_ value:String)->String{
 let limited=value.count>2000 ? String(value.prefix(1999))+"…":value
 let lines=limited.components(separatedBy:.newlines).map{line->String in let text=line.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ");return imageLinks(text).isEmpty ? text:escapedMarkdown(text)}
 return lines.reduce(into:[String]()){if !($1.isEmpty && ($0.last?.isEmpty ?? true)){$0.append($1)}}.joined(separator:"\n").trimmingCharacters(in:.newlines).replacingOccurrences(of:"\n",with:"\n  ")
}
/// Řádky `- **[1] Element** `selector` „name“: popis` a `- **[2] Rámeček**: komentář` seřazené podle čísla; anotace mimo ořez vynechá.
func elementMarkdownLines(_ marks:[Mark],crop:NSRect?,pageData:Bool=true)->String{
 marks.compactMap{mark->(Int,String)? in
  if let crop,mark.bounds.intersection(crop).isNull{return nil}
  if mark.tool != .element,let number=mark.number {
   let note=safeNote(mark.comment ?? "");guard !note.isEmpty else{return nil}
   return (number,"- **[\(number)] \(mark.noteLabel)**: "+note)
  }
  guard mark.tool == .element,let info=mark.element else{return nil}
  // Selektor nesmí vypadat jako odkaz na obrázek, jinak by ho znovuotevření relace bralo jako snímek.
  var selector=flattened(info.selector,limit:300);if !imageLinks(selector).isEmpty{selector=flattened(info.tag,limit:40);if !imageLinks(selector).isEmpty{selector=""}}
  let label=flattened(info.name.isEmpty ? info.text:info.name,limit:80),note=safeNote(mark.text)
  var line="- **[\(info.number)] Element**"
  if pageData,!selector.isEmpty{line+=" "+codeSpan(selector)}
  if pageData,!label.isEmpty{line+=" „"+escapedMarkdown(label)+"“"}
  if !note.isEmpty{line+=": "+note}
  return (info.number,line)
 }.sorted{$0.0<$1.0}.map{$0.1}.joined(separator:"\n")
}
/// Popisek obrázku doplněný o řádky anotací Element z pracovní kopie anotací.
/// Bez `pageData` vynechá selektor a text stránky.
func captionWithElements(_ note:String,image:URL,pageData:Bool=true)->String{
 guard let data=try? Data(contentsOf:annotationSidecar(image)),let document=try? JSONDecoder().decode(ElementSidecar.self,from:data) else{return note}
 return [note,elementMarkdownLines(document.marks,crop:document.crop,pageData:pageData)].filter{!$0.isEmpty}.joined(separator:"\n\n")
}
/// Po ořezu v editoru přepíše `capture` v exportovaném kontextu na oříznutou část.
func adjustContextCapture(_ contextFile:URL,annotations:URL){
 guard let data=try? Data(contentsOf:annotations),let document=try? JSONDecoder().decode(ElementSidecar.self,from:data),
  let raw=try? boundedData(contextFile,max:maxContextBytes),var object=(try? JSONSerialization.jsonObject(with:raw)) as? [String:Any],let capture=CaptureGeometry(json:object["capture"]) else{return}
 let full=NSRect(x:0,y:0,width:capture.rect.width*capture.imageScale,height:capture.rect.height*capture.imageScale)
 guard abs(document.crop.minX-full.minX)>0.5 || abs(document.crop.minY-full.minY)>0.5 || abs(document.crop.width-full.width)>0.5 || abs(document.crop.height-full.height)>0.5,
  full.insetBy(dx:-0.5,dy:-0.5).contains(document.crop) else{return}
 object["capture"]=croppedCapture(capture,crop:document.crop).json
 // Nový soubor vzniká rovnou jen pro vlastníka a pak nahradí původní.
 let temporary=contextFile.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
 guard let output=try? JSONSerialization.data(withJSONObject:object),fm.createFile(atPath:temporary.path,contents:output,attributes:[.posixPermissions:0o600]) else{return}
 // replaceItemAt převezme práva původního souboru, proto se nastaví znovu.
 if (try? fm.replaceItemAt(contextFile,withItemAt:temporary)) == nil{try? fm.removeItem(at:temporary);return}
 try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:contextFile.path)
}

// MARK: Editor

extension DrawingView:NSTextFieldDelegate {
 var visibleElements:[ElementTarget]{clippedTargets(elementMap,to:viewport)}
 var nextElementNumber:Int{max(marks.compactMap{$0.noteNumber}.max() ?? 0,firstElementNumber-1)+1}
 func elementMark(_ target:ElementTarget,number:Int)->Mark{
  var mark=Mark(tool:.element,points:[target.rect.origin,NSPoint(x:target.rect.maxX,y:target.rect.maxY)],color:color,width:max(2,min(thickness,6)),text:"",bold:false,italic:false,underline:false,fontSize:fontSize)
  mark.element=ElementInfo(number:number,selector:target.selector,tag:target.tag,name:target.name,text:target.text);return mark
 }
 func renumberElements(){
  // Elementy i komentované tvary sdílejí jednu řadu čísel.
  let order=marks.indices.filter{marks[$0].noteNumber != nil}.sorted{marks[$0].noteNumber!<marks[$1].noteNumber!}
  for (number,index) in order.enumerated(){if marks[index].tool == .element{marks[index].element?.number=firstElementNumber+number}else{marks[index].number=firstElementNumber+number}}
 }
 /// Klik vybere nejmenší prvek; opakovaný klik na stejný prvek nebo s ⌥ posune výběr na rodiče.
 func elementClick(_ point:NSPoint,parent:Bool){
  let visible=visibleElements,smallest=smallestElement(at:point,in:visible)
  if let active=activeElement,marks.indices.contains(active.mark),marks[active.mark].tool == .element,let current=visible.first(where:{$0.index==active.target}),current.rect.contains(point),smallest?.index==active.origin || parent{
   if let up=parentElement(of:current,in:visible){snapshot();let number=marks[active.mark].element?.number ?? nextElementNumber,note=marks[active.mark].text;marks[active.mark]=elementMark(up,number:number);marks[active.mark].text=note;activeElement?.target=up.index;activeElement?.confirmed=false}
   choose(active.mark);startElementNote(active.mark);return
  }
  guard var target=smallest else{activeElement=nil;choose(nil);return}
  let origin=target.index
  if parent,let up=parentElement(of:target,in:visible){target=up}
  snapshot();marks.append(elementMark(target,number:nextElementNumber));activeElement=ActiveElement(mark:marks.count-1,target:target.index,origin:origin)
  choose(marks.count-1);startElementNote(marks.count-1)
 }
 /// Esc zruší rozpracovaný výběr; bez něj ukončí nástroj.
 func cancelActiveElement(){
  dropElementField()
  if let active=activeElement,!active.confirmed,marks.indices.contains(active.mark),marks[active.mark].tool == .element{snapshot();marks.remove(at:active.mark);renumberElements();choose(nil)}
  else if activeElement == nil{tool = .select}
  activeElement=nil;hoverElement=nil;needsDisplay=true;changed?()
 }
 func startElementNote(_ index:Int){
  guard marks.indices.contains(index) else{return}
  commitElementNote()
  let element=marks[index].tool == .element
  let box=NoteEditorBox(placeholder:element ? L("Popis elementu · Enter potvrdí, Esc zruší výběr"):L("Komentář k objektu · Enter potvrdí, prázdný ho odebere"),value:marks[index].noteText)
  box.field.delegate=self
  box.onConfirm={[weak self] in self?.confirmElementNote()}
  box.onCancel={[weak self] in self?.cancelNote()}
  box.onResize={[weak self] in self?.updateElementField()}
  noteButton?.removeFromSuperview();noteButton=nil
  noteBox=box;elementField=box.field;elementFieldIndex=index;addSubview(box);updateElementField();window?.makeFirstResponder(box.editor)
 }
 func updateElementField(){
  guard let box=noteBox,let i=elementFieldIndex,marks.indices.contains(i) else{return}
  let rect=noteAnchorRect(marks[i])
  let width=min(max(box.expanded ? 360:280,rect.width),max(240,bounds.width-8)),height=box.frame.height
  var y=rect.minY-height-6;if y<bounds.minY+4{y=min(rect.maxY+6,bounds.maxY-height-4)}
  box.frame=NSRect(x:max(bounds.minX+4,min(rect.minX,bounds.maxX-width-4)),y:max(bounds.minY+4,y),width:width,height:height)
 }
 func dropElementField(){
  guard elementField != nil || noteBox != nil else{return}
  closingElementNote=true;noteBox?.removeFromSuperview();noteBox=nil;elementField=nil;elementFieldIndex=nil;closingElementNote=false;window?.makeFirstResponder(self);updateNoteButton()
 }
 /// Esc: komentář tvaru jen zavře, u elementu zruší rozpracovaný výběr.
 func cancelNote(){if let i=elementFieldIndex,marks.indices.contains(i),marks[i].tool != .element{dropElementField()}else{cancelActiveElement()}}
 /// Enter potvrdí popis; výběr zůstává aktivní pro opakovaný klik na rodiče.
 func confirmElementNote(){commitElementNote();activeElement?.confirmed=true}
 /// Plocha anotace Element pro výběr: okraj a odznak, aby šlo vybrat i anotace pod ní.
 func elementHit(_ mark:Mark,at point:NSPoint,tolerance:CGFloat)->Bool{
  let rect=mark.bounds,size=max(24,mark.width*6),band=max(tolerance,mark.width)
  if hypot(point.x-rect.minX,point.y-rect.maxY)<=size/2+tolerance{return true}
  return rect.insetBy(dx:-band,dy:-band).contains(point) && !rect.insetBy(dx:band,dy:band).contains(point)
 }
 func commitElementNote(){
  guard !closingElementNote,let box=noteBox,let i=elementFieldIndex else{return}
  let value=box.value.trimmingCharacters(in:.whitespacesAndNewlines)
  dropElementField()
  if marks.indices.contains(i),marks[i].tool == .element,marks[i].text != value{snapshot();marks[i].text=value;changed?()}
  // Komentář tvaru dostane další číslo; prázdný číslo odebere a ostatní se přečíslují.
  else if marks.indices.contains(i),marks[i].tool != .element,(marks[i].comment ?? "") != value {
   snapshot()
   if value.isEmpty{marks[i].comment=nil;marks[i].number=nil;renumberElements()}
   else{if marks[i].number == nil{marks[i].number=nextElementNumber};marks[i].comment=value}
   changed?()
  }
  needsDisplay=true
 }
 func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool{
  guard control === elementField else{return false}
  if selector==#selector(NSResponder.insertNewline(_:)){confirmElementNote();return true}
  if selector==#selector(NSResponder.cancelOperation(_:)){cancelNote();return true}
  return false
 }

 /// Pravé tlačítko na anotaci: komentář i u textu, kde dvojklik upravuje samotný text.
 override func menu(for event:NSEvent)->NSMenu?{
  guard tool == .select,imageRect.contains(convert(event.locationInWindow,from:nil)),let index=hit(point(event)) else{return nil}
  finishText();choose(index);let menu=NSMenu()
  let edit=NSMenuItem(title:L("Komentář…"),action:#selector(editNoteFromMenu(_:)),keyEquivalent:"");edit.target=self;edit.tag=index;menu.addItem(edit)
  if marks[index].tool != .element,marks[index].number != nil{let remove=NSMenuItem(title:L("Odebrat komentář"),action:#selector(removeNoteFromMenu(_:)),keyEquivalent:"");remove.target=self;remove.tag=index;menu.addItem(remove)}
  return menu
 }
 @objc func editNoteFromMenu(_ sender:NSMenuItem){startElementNote(sender.tag)}
 @objc func removeNoteFromMenu(_ sender:NSMenuItem){
  guard marks.indices.contains(sender.tag),marks[sender.tag].tool != .element else{return}
  snapshot();marks[sender.tag].comment=nil;marks[sender.tag].number=nil;renumberElements();needsDisplay=true;changed?()
 }
 /// Přerušovaný obdélník a číselný odznak; obojí zůstává uvnitř ořezu.
 func paintElement(_ mark:Mark){
  let rect=mark.bounds.intersection(viewport);guard !rect.isNull else{return}
  let path=NSBezierPath(rect:rect.insetBy(dx:mark.width/2,dy:mark.width/2));path.lineWidth=mark.width;path.setLineDash([mark.width*3,mark.width*2],count:2,phase:0);mark.color.setStroke();path.stroke()
  guard let number=mark.element?.number else{return}
  paintBadge(number,at:NSPoint(x:rect.minX,y:rect.maxY),mark:mark)
 }
 /// Kruhový odznak s číslem anotace, vždy celý uvnitř ořezu.
 func paintBadge(_ number:Int,at anchor:NSPoint,mark:Mark){
  let size=max(24,mark.width*6),x=max(viewport.minX+size/2,min(viewport.maxX-size/2,anchor.x)),y=max(viewport.minY+size/2,min(viewport.maxY-size/2,anchor.y))
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
