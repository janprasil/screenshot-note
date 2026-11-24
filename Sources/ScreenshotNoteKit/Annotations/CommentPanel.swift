import AppKit

// Pravý panel editoru: poznámka ke snímku, seznam komentářů anotací a úprava jednoho komentáře.

/// Kruhový odznak s číslem v barvě anotace.
final class CommentBadge:NSView {
 var number:Int?;var color:NSColor = .systemRed
 override func draw(_ dirtyRect:NSRect){
  color.setFill();NSBezierPath(ovalIn:bounds.insetBy(dx:1,dy:1)).fill()
  guard let number else{return}
  let label="\(number)" as NSString,attributes:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:bounds.height*0.5,weight:.bold),.foregroundColor:NSColor.white]
  let size=label.size(withAttributes:attributes);label.draw(at:NSPoint(x:bounds.midX-size.width/2,y:bounds.midY-size.height/2),withAttributes:attributes)
 }
}

/// Řádek seznamu: odznak, typ anotace a začátek komentáře; klik otevře komentář.
final class CommentRow:NSControl {
 private var hovered=false,area:NSTrackingArea?
 let index:Int
 init(index:Int,mark:Mark,width:CGFloat,selected:Bool){
  self.index=index
  super.init(frame:NSRect(x:0,y:0,width:width,height:58))
  wantsLayer=true;layer?.cornerRadius=8
  let badge=CommentBadge(frame:NSRect(x:8,y:29,width:22,height:22));badge.number=mark.noteNumber;badge.color=mark.color;addSubview(badge)
  addSubview(designLabel(mark.noteLabel,NSRect(x:38,y:32,width:width-46,height:18),size:12,weight:.semibold))
  let note=NoteEditorBox.oneLine(mark.noteText)
  let text=designLabel(note.isEmpty ? L("Bez komentáře"):note,NSRect(x:38,y:6,width:width-46,height:28),size:11,color:note.isEmpty ? AppPalette.secondary:.labelColor)
  text.maximumNumberOfLines=2;text.lineBreakMode = .byTruncatingTail;text.cell?.wraps=true;addSubview(text)
  setAccessibilityRole(.button);setAccessibilityLabel(mark.noteLabel+" "+(mark.noteNumber.map{"\($0)"} ?? "")+": "+note)
  self.selected=selected;updateColors()
 }
 required init?(coder:NSCoder){nil}
 var selected=false
 override func updateTrackingAreas(){super.updateTrackingAreas();if let area{removeTrackingArea(area)};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(next);area=next}
 override func viewWillMove(toWindow newWindow:NSWindow?){super.viewWillMove(toWindow:newWindow);if newWindow==nil,let area{removeTrackingArea(area);self.area=nil;hovered=false}}
 override func mouseEntered(with event:NSEvent){hovered=true;updateColors()}
 override func mouseExited(with event:NSEvent){hovered=false;updateColors()}
 override func mouseDown(with event:NSEvent){sendAction(action,to:target)}
 override func resetCursorRects(){addCursorRect(bounds,cursor:.pointingHand)}
 override func accessibilityPerformPress()->Bool{sendAction(action,to:target)}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();updateColors()}
 private func updateColors(){effectiveAppearance.performAsCurrentDrawingAppearance{self.layer?.backgroundColor=(self.selected ? AppPalette.accent.withAlphaComponent(0.16):self.hovered ? AppPalette.accent.withAlphaComponent(0.08):NSColor.clear).cgColor}}
}

/// Dokument seznamu shora dolů.
private final class FlippedView:NSView {override var isFlipped:Bool{true}}

final class AnnotationCommentPanel:NSView {
 weak var canvas:DrawingView?
 let noteView=NSTextView(frame:.zero)
 private let overview=NSView(),detail=NSView()
 private let list=FlippedView(),listScroll=NSScrollView()
 private let empty=NSTextField(wrappingLabelWithString:"")
 private let detailBadge=CommentBadge(frame:.zero)
 private var detailTitle:NSTextField!,detailText:NSTextField!,detailHint:NSTextField!
 private var back:AppButton!,done:AppButton!,remove:AppButton!,edit:AppButton!
 private let editorHost=NSView()
 private var lastRows=""

 init(frame:NSRect,note:String){
  super.init(frame:frame)
  for view in [overview,detail]{view.frame=bounds;view.autoresizingMask=[.width,.height];addSubview(view)}
  buildOverview(note:note);buildDetail();refresh()
 }
 required init?(coder:NSCoder){nil}

 private func buildOverview(note:String){
  let w=bounds.width,h=bounds.height
  let title=designLabel(L("Poznámka ke snímku"),NSRect(x:0,y:h-22,width:w,height:22),size:13,weight:.semibold);title.autoresizingMask=[.width,.minYMargin];overview.addSubview(title)
  let shell=AdaptiveInputBackground(frame:NSRect(x:0,y:h-170,width:w,height:142));shell.autoresizingMask=[.width,.minYMargin];overview.addSubview(shell)
  let scroll=NSScrollView(frame:shell.bounds.insetBy(dx:8,dy:8));scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
  noteView.frame=NSRect(origin:.zero,size:scroll.contentSize);noteView.isRichText=false;noteView.allowsUndo=true;noteView.drawsBackground=false;noteView.font = .systemFont(ofSize:13);noteView.textColor = .textColor
  noteView.isAutomaticQuoteSubstitutionEnabled=false;noteView.isAutomaticDashSubstitutionEnabled=false;noteView.isVerticallyResizable=true;noteView.autoresizingMask=[.width];noteView.textContainer?.widthTracksTextView=true
  noteView.string=note;noteView.setAccessibilityLabel(L("Poznámka ke snímku"));scroll.documentView=noteView;shell.addSubview(scroll)
  let divider=DesignDivider(NSRect(x:0,y:h-188,width:w,height:1));divider.autoresizingMask=[.width,.minYMargin];overview.addSubview(divider)
  let comments=designLabel(L("Komentáře k anotacím"),NSRect(x:0,y:h-222,width:w,height:22),size:13,weight:.semibold);comments.autoresizingMask=[.width,.minYMargin];overview.addSubview(comments)
  listScroll.frame=NSRect(x:0,y:0,width:w,height:h-230);listScroll.autoresizingMask=[.width,.height];listScroll.drawsBackground=false;listScroll.hasVerticalScroller=true;listScroll.autohidesScrollers=true;listScroll.scrollerStyle = .overlay
  list.frame=NSRect(x:0,y:0,width:w,height:0);list.autoresizingMask=[.width];listScroll.documentView=list;overview.addSubview(listScroll)
  empty.stringValue=L("Zatím žádné komentáře. Vyber tvar nástrojem Výběr a v panelu přidej komentář.");empty.font = .systemFont(ofSize:11);empty.textColor=AppPalette.secondary
  empty.frame=NSRect(x:0,y:h-280,width:w,height:48);empty.autoresizingMask=[.width,.minYMargin];overview.addSubview(empty)
 }

 private func buildDetail(){
  let w=bounds.width,h=bounds.height
  back=styledButton(L("Všechny komentáře"),symbol:"chevron.left",role:.quiet,frame:NSRect(x:0,y:h-32,width:min(w,190),height:30),target:self,action:#selector(goBack));back.autoresizingMask=[.minYMargin];detail.addSubview(back)
  detailBadge.frame=NSRect(x:0,y:h-70,width:26,height:26);detailBadge.autoresizingMask=[.minYMargin];detail.addSubview(detailBadge)
  detailTitle=designLabel("",NSRect(x:34,y:h-68,width:w-34,height:22),size:14,weight:.semibold);detailTitle.autoresizingMask=[.width,.minYMargin];detail.addSubview(detailTitle)
  detailHint=designLabel("",NSRect(x:0,y:h-92,width:w,height:18),size:11,color:AppPalette.secondary);detailHint.autoresizingMask=[.width,.minYMargin];detail.addSubview(detailHint)
  editorHost.frame=NSRect(x:0,y:50,width:w,height:h-150);editorHost.autoresizingMask=[.width,.height];detail.addSubview(editorHost)
  detailText=NSTextField(wrappingLabelWithString:"");detailText.font = .systemFont(ofSize:13);detailText.isSelectable=true
  detailText.frame=NSRect(x:0,y:h-260,width:w,height:160);detailText.autoresizingMask=[.width,.minYMargin];detail.addSubview(detailText)
  edit=styledButton(L("Přidat komentář"),symbol:"text.bubble",role:.primary,frame:NSRect(x:0,y:8,width:w,height:34),target:self,action:#selector(startEdit));edit.autoresizingMask=[.width,.maxYMargin];detail.addSubview(edit)
  remove=styledButton(L("Odebrat"),symbol:"trash",role:.quiet,frame:NSRect(x:0,y:8,width:100,height:34),target:self,action:#selector(removeComment));remove.autoresizingMask=[.maxYMargin];detail.addSubview(remove)
  done=styledButton(L("Hotovo"),symbol:"checkmark",role:.primary,frame:NSRect(x:w-110,y:8,width:110,height:34),target:self,action:#selector(finish));done.autoresizingMask=[.minXMargin,.maxYMargin];done.toolTip=L("Potvrdit komentář (⌘Enter)");detail.addSubview(done)
 }

 /// Pole komentáře z plátna se vloží do panelu.
 func attach(_ box:NoteEditorBox){box.frame=editorHost.bounds;box.autoresizingMask=[.width,.height];editorHost.addSubview(box);refresh()}

 /// Index anotace v detailu: upravovaná, jinak vybraná v nástroji Výběr.
 private var focused:Int?{
  guard let canvas else{return nil}
  if let i=canvas.elementFieldIndex,canvas.noteBox != nil,canvas.marks.indices.contains(i){return i}
  if canvas.tool == .select,canvas.editingIndex == nil,let i=canvas.selected,canvas.marks.indices.contains(i){return i}
  return nil
 }

 func refresh(){
  guard let canvas else{return}
  if let i=focused{
   let mark=canvas.marks[i],editing=canvas.noteBox != nil
   overview.isHidden=true;detail.isHidden=false
   detailBadge.number=mark.noteNumber;detailBadge.color=mark.color;detailBadge.isHidden=mark.noteNumber == nil;detailBadge.needsDisplay=true
   detailTitle.frame.origin.x=mark.noteNumber == nil ? 0:34
   detailTitle.stringValue=mark.noteLabel
   detailHint.stringValue=editing ? (mark.tool == .element ? L("Popis elementu · ⌘Enter potvrdí, Esc zruší výběr"):L("Markdown · ⌘Enter potvrdí, Esc zavře")):(mark.noteText.isEmpty ? L("Tvar zatím nemá komentář."):"")
   detailText.stringValue=mark.noteText;detailText.isHidden=editing || mark.noteText.isEmpty
   editorHost.isHidden = !editing;done.isHidden = !editing;edit.isHidden=editing
   remove.isHidden = !editing || mark.noteText.isEmpty
   edit.title=mark.noteText.isEmpty ? (mark.tool == .element ? L("Přidat popis"):L("Přidat komentář")):L("Upravit komentář")
   return
  }
  overview.isHidden=false;detail.isHidden=true
  // Seznam se přestaví jen při změně obsahu, jinak by blikal.
  let marks=canvas.marks.enumerated().filter{$0.element.noteNumber != nil}.sorted{$0.element.noteNumber!<$1.element.noteNumber!}
  let key=marks.map{"\($0.offset):\($0.element.noteNumber!):\($0.element.noteText):\($0.element.color.description)"}.joined(separator:"|")+"#\(Int(listScroll.contentSize.width))"
  empty.isHidden = !marks.isEmpty
  guard key != lastRows else{return}
  lastRows=key
  list.subviews.forEach{$0.removeFromSuperview()}
  let width=listScroll.contentSize.width;var y:CGFloat=0
  for (index,mark) in marks{let row=CommentRow(index:index,mark:mark,width:width,selected:false);row.frame.origin=NSPoint(x:0,y:y);row.autoresizingMask=[.width];row.target=self;row.action=#selector(openRow(_:));list.addSubview(row);y+=62}
  list.frame=NSRect(x:0,y:0,width:width,height:max(y,listScroll.contentSize.height))
 }
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);if canvas != nil{refresh()}}

 @objc private func openRow(_ sender:CommentRow){
  guard let canvas,canvas.marks.indices.contains(sender.index) else{return}
  canvas.finishText();canvas.tool = .select;canvas.choose(sender.index);canvas.startElementNote(sender.index)
 }
 @objc private func startEdit(){if let canvas,let i=focused{canvas.startElementNote(i)}}
 @objc private func finish(){canvas?.confirmElementNote();canvas?.window?.makeFirstResponder(canvas)}
 /// Zpět na přehled: rozepsaný komentář se uloží, výběr zruší.
 @objc private func goBack(){
  guard let canvas else{return}
  canvas.confirmElementNote();canvas.activeElement=nil;canvas.choose(nil);canvas.window?.makeFirstResponder(canvas);refresh()
 }
 @objc private func removeComment(){
  guard let canvas,let i=focused else{return}
  canvas.dropElementField()
  if canvas.marks[i].tool == .element{canvas.snapshot();canvas.marks[i].text=""}
  else{canvas.snapshot();canvas.marks[i].comment=nil;canvas.marks[i].number=nil;canvas.renumberElements()}
  canvas.needsDisplay=true;canvas.changed?();refresh()
 }
}
