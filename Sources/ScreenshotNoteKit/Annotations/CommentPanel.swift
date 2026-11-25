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

/// Řádek seznamu: odznak s číslem a komentář, svisle na střed; klik otevře komentář.
final class CommentRow:NSControl {
 private var hovered=false,area:NSTrackingArea?
 let index:Int
 static let height:CGFloat=48
 init(index:Int,mark:Mark,width:CGFloat){
  self.index=index
  super.init(frame:NSRect(x:0,y:0,width:width,height:Self.height))
  wantsLayer=true;layer?.cornerRadius=8
  let badge=CommentBadge(frame:NSRect(x:10,y:(Self.height-22)/2,width:22,height:22));badge.number=mark.noteNumber;badge.color=mark.color;addSubview(badge)
  let note=NoteEditorBox.oneLine(mark.noteText)
  let text=designLabel(note.isEmpty ? L("Bez komentáře"):note,NSRect(x:42,y:4,width:width-50,height:Self.height-8),size:12,color:note.isEmpty ? AppPalette.secondary:.labelColor)
  text.maximumNumberOfLines=2;text.lineBreakMode = .byTruncatingTail;text.cell?.wraps=true;addSubview(text)
  setAccessibilityRole(.button);setAccessibilityLabel((mark.noteNumber.map{"\($0). "} ?? "")+note)
  updateColors()
 }
 required init?(coder:NSCoder){nil}
 override func updateTrackingAreas(){super.updateTrackingAreas();if let area{removeTrackingArea(area)};let next=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(next);area=next}
 override func viewWillMove(toWindow newWindow:NSWindow?){super.viewWillMove(toWindow:newWindow);if newWindow==nil,let area{removeTrackingArea(area);self.area=nil;hovered=false}}
 override func mouseEntered(with event:NSEvent){hovered=true;updateColors()}
 override func mouseExited(with event:NSEvent){hovered=false;updateColors()}
 override func mouseDown(with event:NSEvent){sendAction(action,to:target)}
 override func resetCursorRects(){addCursorRect(bounds,cursor:.pointingHand)}
 override func accessibilityPerformPress()->Bool{sendAction(action,to:target)}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();updateColors()}
 private func updateColors(){effectiveAppearance.performAsCurrentDrawingAppearance{self.layer?.backgroundColor=(self.hovered ? AppPalette.accent.withAlphaComponent(0.1):NSColor.clear).cgColor}}
}

/// Markdown v textu: s ním se pole zamkne a úpravy jdou přes Markdown editor.
func containsMarkdown(_ text:String)->Bool{
 text.range(of:#"(^|\n)[ \t]*(#{1,6}[ \t]|[-*+][ \t]|>|\d+\.[ \t]|```)|\*\*|__|`|~~|\[[^\]\n]*\]\([^)\n]*\)|(^|\s)[*_][^*_\s][^*_\n]*[*_](\s|$)"#,options:.regularExpression) != nil
}

/// Čtyřřádkové pole s tlačítkem ≡ pro Markdown editor, jako komentář relace v okně snímků.
/// Text s Markdownem je jen ke čtení; klik otevře Markdown editor.
final class MarkdownTextArea:NSView {
 let textView:NSTextView
 private let scroll=NSScrollView()
 private var expand:AppButton!
 static let height:CGFloat=4*17+20
 var onEdited:(()->Void)?
 init(frame:NSRect,textView:NSTextView=NoteTextView(frame:.zero)){
  self.textView=textView
  super.init(frame:frame)
  let shell=AdaptiveInputBackground(frame:bounds);shell.autoresizingMask=[.width,.height];addSubview(shell)
  scroll.frame=NSRect(x:8,y:6,width:bounds.width-46,height:bounds.height-12);scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false;scroll.scrollerStyle = .overlay
  textView.frame=NSRect(origin:.zero,size:scroll.contentSize);textView.isRichText=false;textView.allowsUndo=true;textView.drawsBackground=false;textView.font = .systemFont(ofSize:13);textView.textColor = .textColor
  textView.isAutomaticQuoteSubstitutionEnabled=false;textView.isAutomaticDashSubstitutionEnabled=false;textView.isVerticallyResizable=true;textView.isHorizontallyResizable=false;textView.autoresizingMask=[.width]
  textView.textContainer?.widthTracksTextView=true;textView.textContainerInset=NSSize(width:0,height:2);scroll.documentView=textView;shell.addSubview(scroll)
  (textView as? NoteTextView)?.onLockedClick={[weak self] in self?.openEditor()}
  expand=styledButton("",symbol:"line.3.horizontal",role:.quiet,frame:NSRect(x:bounds.width-36,y:bounds.height-34,width:30,height:28),target:self,action:#selector(openEditor))
  expand.autoresizingMask=[.minXMargin,.minYMargin];expand.toolTip=L("Otevřít Markdown editor");expand.setAccessibilityLabel(L("Otevřít Markdown editor"));shell.addSubview(expand)
 }
 required init?(coder:NSCoder){nil}
 var string:String{
  get{textView.string}
  set{textView.string=newValue;updateLock()}
 }
 private func updateLock(){
  let locked=containsMarkdown(textView.string)
  textView.isEditable = !locked;textView.isSelectable = !locked
  textView.textColor=locked ? .secondaryLabelColor:.textColor
  toolTip=locked ? L("Text obsahuje Markdown · kliknutím otevřít Markdown editor"):nil
  window?.invalidateCursorRects(for:textView)
 }
 @objc func openEditor(){
  let parent=window;parent?.makeFirstResponder(nil)
  if let value=MarkdownEditor().run(textView.string){string=value;onEdited?()}
  parent?.makeKeyAndOrderFront(nil)
  if textView.isEditable{parent?.makeFirstResponder(textView)}
 }
}

/// Dokument seznamu shora dolů.
private final class FlippedView:NSView {override var isFlipped:Bool{true}}

final class AnnotationCommentPanel:NSView {
 weak var canvas:DrawingView?
 let noteArea:MarkdownTextArea
 var noteView:NSTextView{noteArea.textView}
 private let overview=NSView(),detail=NSView()
 private let list=FlippedView(),listScroll=NSScrollView()
 private let empty=NSTextField(wrappingLabelWithString:"")
 private let detailBadge=CommentBadge(frame:.zero)
 private var detailTitle:NSTextField!,detailText:NSTextField!
 private var back:ContextLinkButton!,save:AppButton!,edit:AppButton!
 private let editorHost=NSView()
 private var lastRows=""
 /// Odsazení obsahu od záhlaví okna.
 static let inset:CGFloat=18

 init(frame:NSRect,note:String){
  noteArea=MarkdownTextArea(frame:NSRect(x:0,y:0,width:frame.width,height:MarkdownTextArea.height))
  super.init(frame:frame)
  for view in [overview,detail]{view.frame=bounds;view.autoresizingMask=[.width,.height];addSubview(view)}
  buildOverview(note:note);buildDetail();refresh()
 }
 required init?(coder:NSCoder){nil}

 private func buildOverview(note:String){
  let w=bounds.width,top=bounds.height-Self.inset
  let title=designLabel(L("Poznámka ke snímku"),NSRect(x:0,y:top-22,width:w,height:22),size:13,weight:.semibold);title.autoresizingMask=[.width,.minYMargin];overview.addSubview(title)
  noteArea.frame=NSRect(x:0,y:top-30-MarkdownTextArea.height,width:w,height:MarkdownTextArea.height);noteArea.autoresizingMask=[.width,.minYMargin];overview.addSubview(noteArea)
  noteArea.string=note;noteView.setAccessibilityLabel(L("Poznámka ke snímku"))
  let below=top-30-MarkdownTextArea.height
  let divider=DesignDivider(NSRect(x:0,y:below-18,width:w,height:1));divider.autoresizingMask=[.width,.minYMargin];overview.addSubview(divider)
  let comments=designLabel(L("Komentáře k anotacím"),NSRect(x:0,y:below-52,width:w,height:22),size:13,weight:.semibold);comments.autoresizingMask=[.width,.minYMargin];overview.addSubview(comments)
  listScroll.frame=NSRect(x:0,y:0,width:w,height:max(0,below-60));listScroll.autoresizingMask=[.width,.height];listScroll.drawsBackground=false;listScroll.hasVerticalScroller=true;listScroll.autohidesScrollers=true;listScroll.scrollerStyle = .overlay
  list.frame=NSRect(x:0,y:0,width:w,height:0);list.autoresizingMask=[.width];listScroll.documentView=list;overview.addSubview(listScroll)
  empty.stringValue=L("Zatím žádné komentáře. Vyber tvar nástrojem Výběr a v panelu přidej komentář.");empty.font = .systemFont(ofSize:11);empty.textColor=AppPalette.secondary
  empty.frame=NSRect(x:0,y:below-108,width:w,height:48);empty.autoresizingMask=[.width,.minYMargin];overview.addSubview(empty)
 }

 private func buildDetail(){
  let w=bounds.width,top=bounds.height-Self.inset
  back=ContextLinkButton(frame:NSRect(x:-8,y:top-26,width:200,height:26));back.title=L("Všechny komentáře");back.image=NSImage(systemSymbolName:"chevron.left",accessibilityDescription:nil)
  back.target=self;back.action=#selector(goBack);back.frame.size.width=back.fittingWidth(maximum:w+8);back.autoresizingMask=[.minYMargin];detail.addSubview(back)
  detailBadge.frame=NSRect(x:0,y:top-66,width:26,height:26);detailBadge.autoresizingMask=[.minYMargin];detail.addSubview(detailBadge)
  detailTitle=designLabel(L("Komentář k anotaci"),NSRect(x:36,y:top-64,width:w-36,height:22),size:14,weight:.semibold);detailTitle.autoresizingMask=[.width,.minYMargin];detail.addSubview(detailTitle)
  let field=top-78-MarkdownTextArea.height
  editorHost.frame=NSRect(x:0,y:field,width:w,height:MarkdownTextArea.height);editorHost.autoresizingMask=[.width,.minYMargin];detail.addSubview(editorHost)
  detailText=NSTextField(wrappingLabelWithString:"");detailText.font = .systemFont(ofSize:13);detailText.isSelectable=true;detailText.maximumNumberOfLines=8
  detailText.frame=NSRect(x:0,y:top-80-150,width:w,height:150);detailText.autoresizingMask=[.width,.minYMargin];detail.addSubview(detailText)
  // Uložit hned pod polem: komentář se potvrdí a panel se vrátí na přehled.
  save=styledButton(L("Uložit"),symbol:"checkmark",role:.primary,frame:NSRect(x:w-120,y:field-46,width:120,height:34),target:self,action:#selector(finish))
  save.autoresizingMask=[.minXMargin,.minYMargin];save.toolTip=L("Uložit komentář (⌘Enter)");detail.addSubview(save)
  edit=styledButton(L("Přidat komentář"),symbol:"text.bubble",role:.primary,frame:NSRect(x:0,y:top-122,width:w,height:34),target:self,action:#selector(startEdit));edit.autoresizingMask=[.width,.minYMargin];detail.addSubview(edit)
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
   detailTitle.frame.origin.x=mark.noteNumber == nil ? 0:36
   detailTitle.stringValue=mark.tool == .element ? L("Popis elementu"):L("Komentář k anotaci")
   detailText.stringValue=mark.noteText;detailText.isHidden=editing || mark.noteText.isEmpty
   // Výška textu podle obsahu, tlačítko hned pod ním.
   let top=bounds.height-Self.inset,size=detailText.cell?.cellSize(forBounds:NSRect(x:0,y:0,width:bounds.width,height:150)) ?? .zero,height=min(150,ceil(size.height))
   detailText.frame=NSRect(x:0,y:top-80-height,width:bounds.width,height:height)
   editorHost.isHidden = !editing;save.isHidden = !editing;edit.isHidden=editing
   edit.frame.origin.y=mark.noteText.isEmpty ? top-122:detailText.frame.minY-46
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
  for (index,mark) in marks{let row=CommentRow(index:index,mark:mark,width:width);row.frame.origin=NSPoint(x:0,y:y);row.autoresizingMask=[.width];row.target=self;row.action=#selector(openRow(_:));list.addSubview(row);y+=CommentRow.height+4}
  list.frame=NSRect(x:0,y:0,width:width,height:max(y,listScroll.contentSize.height))
 }
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);if canvas != nil{refresh()}}

 @objc private func openRow(_ sender:CommentRow){
  guard let canvas,canvas.marks.indices.contains(sender.index) else{return}
  canvas.finishText();canvas.tool = .select;canvas.choose(sender.index);canvas.startElementNote(sender.index)
 }
 @objc private func startEdit(){if let canvas,let i=focused{canvas.startElementNote(i)}}
 /// Uložit: komentář se potvrdí a panel se vrátí na přehled.
 @objc private func finish(){goBack()}
 /// Zpět na přehled: rozepsaný komentář se uloží, výběr zruší.
 @objc private func goBack(){
  guard let canvas else{return}
  canvas.confirmElementNote();canvas.activeElement=nil;canvas.choose(nil);canvas.window?.makeFirstResponder(canvas);refresh()
 }
}
