import AppKit

// Komentář anotace: plovoucí pole nad tvarem, rozbalitelné na víceřádkový Markdown.

/// Text view rozbaleného komentáře: ⌘Enter potvrdí, Esc zruší, Enter vloží řádek.
final class NoteTextView:NSTextView {
 var onConfirm:(()->Void)?;var onCancel:(()->Void)?
 override func keyDown(with event:NSEvent){
  if (event.keyCode==36 || event.keyCode==76),event.modifierFlags.contains(.command){onConfirm?();return}
  if event.keyCode==53{onCancel?();return}
  super.keyDown(with:event)
 }
}

/// Plovoucí editor komentáře: ikona, pole, rozbalení na Markdown a potvrzení.
final class NoteEditorBox:NSView {
 static let collapsedHeight:CGFloat=34,expandedHeight:CGFloat=150
 let field=NSTextField(frame:.zero)
 let scroll=NSScrollView(frame:.zero)
 let textView=NoteTextView(frame:.zero)
 let icon=NSImageView(frame:.zero)
 let expandButton=NSButton(frame:.zero)
 let doneButton=NSButton(frame:.zero)
 private(set) var expanded=false
 var onConfirm:(()->Void)?{didSet{textView.onConfirm=onConfirm}}
 var onCancel:(()->Void)?{didSet{textView.onCancel=onCancel}}
 var onResize:(()->Void)?

 init(placeholder:String,value:String){
  super.init(frame:NSRect(x:0,y:0,width:280,height:Self.collapsedHeight))
  wantsLayer=true;layer?.cornerRadius=9;layer?.borderWidth=1
  shadow=NSShadow();layer?.shadowOpacity=0.25;layer?.shadowRadius=8;layer?.shadowOffset=NSSize(width:0,height:-2)
  icon.image=NSImage(systemSymbolName:"text.bubble.fill",accessibilityDescription:nil);icon.contentTintColor=AppPalette.accent;addSubview(icon)
  field.placeholderString=placeholder;field.isBordered=false;field.drawsBackground=false;field.focusRingType = .none;field.font = .systemFont(ofSize:13);field.lineBreakMode = .byTruncatingTail;addSubview(field)
  textView.isRichText=false;textView.font = .monospacedSystemFont(ofSize:12,weight:.regular);textView.drawsBackground=false;textView.isAutomaticQuoteSubstitutionEnabled=false;textView.allowsUndo=true
  textView.textContainerInset=NSSize(width:2,height:4);textView.isVerticallyResizable=true;textView.autoresizingMask=[.width];textView.textContainer?.widthTracksTextView=true
  scroll.documentView=textView;scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.borderType = .noBorder;scroll.isHidden=true;addSubview(scroll)
  for (button,symbol,help,action) in [(expandButton,"arrow.up.left.and.arrow.down.right",L("Rozbalit na víceřádkový Markdown"),#selector(toggleExpanded)),(doneButton,"checkmark.circle.fill",L("Potvrdit komentář (Enter, v rozbaleném ⌘Enter)"),#selector(confirm))] as [(NSButton,String,String,Selector)] {
   button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:help);button.isBordered=false;button.toolTip=help;button.target=self;button.action=action;button.contentTintColor=AppPalette.accent;addSubview(button)
  }
  field.stringValue=value
  if value.contains("\n"){setExpanded(true)}
  updateColors();layoutParts()
 }
 required init?(coder:NSCoder){nil}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();updateColors()}
 private func updateColors(){effectiveAppearance.performAsCurrentDrawingAppearance{self.layer?.backgroundColor=AppPalette.paper.cgColor;self.layer?.borderColor=AppPalette.accent.withAlphaComponent(0.55).cgColor}}
 /// Text rozbaleného editoru; mimo okno se drží stranou (NSTextView bez okna sahá na vstupní metody).
 private var detachedText=""
 var markdown:String{
  get{window == nil ? detachedText:textView.string}
  set{detachedText=newValue;if window != nil{textView.string=newValue}}
 }
 override func viewDidMoveToWindow(){super.viewDidMoveToWindow();if window != nil,expanded,textView.string != detachedText{textView.string=detachedText}}
 /// Aktuální text: z rozbaleného editoru, jinak z jednořádkového pole.
 var value:String{expanded ? markdown:field.stringValue}
 var editor:NSView{expanded ? textView:field}
 @objc func toggleExpanded(){setExpanded(!expanded);window?.makeFirstResponder(editor);onResize?()}
 @objc func confirm(){onConfirm?()}
 func setExpanded(_ value:Bool){
  if value==expanded{return}
  if value{markdown=field.stringValue}else{field.stringValue=markdown.components(separatedBy:.newlines).joined(separator:" ")}
  expanded=value;field.isHidden=value;scroll.isHidden = !value
  expandButton.image=NSImage(systemSymbolName:value ? "arrow.down.right.and.arrow.up.left":"arrow.up.left.and.arrow.down.right",accessibilityDescription:nil)
  expandButton.toolTip=value ? L("Sbalit na jeden řádek"):L("Rozbalit na víceřádkový Markdown")
  setFrameSize(NSSize(width:frame.width,height:value ? Self.expandedHeight:Self.collapsedHeight))
 }
 override func setFrameSize(_ newSize:NSSize){super.setFrameSize(newSize);layoutParts()}
 private func layoutParts(){
  let h=bounds.height,w=bounds.width,top=h-Self.collapsedHeight
  icon.frame=NSRect(x:9,y:top+8,width:18,height:18)
  doneButton.frame=NSRect(x:w-30,y:top+6,width:22,height:22)
  expandButton.frame=NSRect(x:w-54,y:top+6,width:22,height:22)
  field.frame=NSRect(x:32,y:top+8,width:max(40,w-92),height:18)
  scroll.frame=NSRect(x:8,y:8,width:w-16,height:max(20,h-Self.collapsedHeight-4))
  if expanded{field.frame.size.width=0}
 }
}

extension DrawingView {
 /// Bod odznaku čísla anotace v souřadnicích obrázku.
 func badgeCenter(_ mark:Mark)->NSPoint?{
  guard let number=mark.noteNumber,number>0 else{return nil}
  let anchor=mark.tool == .element ? NSPoint(x:mark.bounds.intersection(viewport).minX,y:mark.bounds.intersection(viewport).maxY):mark.badgeAnchor
  let size=max(24,mark.width*6)
  return NSPoint(x:max(viewport.minX+size/2,min(viewport.maxX-size/2,anchor.x)),y:max(viewport.minY+size/2,min(viewport.maxY-size/2,anchor.y)))
 }
 /// Ikona komentáře u odznaku; jen v editoru, export obsahuje samotné číslo.
 func drawNoteIndicators(){
  guard let symbol=NSImage(systemSymbolName:"text.bubble.fill",accessibilityDescription:nil) else{return}
  for (index,mark) in marks.enumerated() where index != editingIndex && !mark.noteText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
   guard let center=badgeCenter(mark) else{continue}
   let size=max(24,mark.width*6)*scale,point=displayRect(NSRect(origin:center,size:.zero)).origin
   let rect=NSRect(x:point.x+size/2-2,y:point.y+size/2-8,width:18,height:16)
   AppPalette.paper.setFill();NSBezierPath(roundedRect:rect.insetBy(dx:-2,dy:-2),xRadius:5,yRadius:5).fill()
   drawAdaptiveSymbol(symbol,in:rect,color:mark.color)
  }
 }
 /// Tlačítko „Komentář“ u vybraného tvaru v nástroji Výběr.
 func updateNoteButton(){
  // Bez okna (testy, export) se tlačítko nevytváří.
  guard window != nil,tool == .select,elementField == nil,editingIndex == nil,let i=selected,marks.indices.contains(i) else{noteButton?.removeFromSuperview();noteButton=nil;return}
  let button=noteButton ?? {
   let b=NSButton(title:"",target:self,action:#selector(noteButtonPressed));b.bezelStyle = .rounded;b.controlSize = .small;b.imagePosition = .imageLeading;b.font = .systemFont(ofSize:11,weight:.medium)
   b.image=NSImage(systemSymbolName:"text.bubble",accessibilityDescription:nil);b.contentTintColor=AppPalette.accent;addSubview(b);noteButton=b;return b
  }()
  button.title=noteButtonTitle(marks[i]);button.sizeToFit()
  let rect=noteAnchorRect(marks[i])
  var origin=NSPoint(x:rect.maxX-button.frame.width,y:rect.minY-button.frame.height-6)
  if origin.y<bounds.minY+4{origin.y=min(rect.maxY+6,bounds.maxY-button.frame.height-4)}
  origin.x=max(bounds.minX+4,min(origin.x,bounds.maxX-button.frame.width-4))
  button.setFrameOrigin(origin)
 }
 /// Obrys anotace na obrazovce včetně otočení; tlačítko ani pole ho nepřekryjí.
 func noteAnchorRect(_ mark:Mark)->NSRect{
  let corners=selectionCorners(mark),xs=corners.map(\.x),ys=corners.map(\.y)
  return NSRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!).intersection(bounds)
 }
 func noteButtonTitle(_ mark:Mark)->String{mark.noteText.isEmpty ? L("Přidat komentář"):L("Upravit komentář")}
 @objc func noteButtonPressed(){if let i=selected{startElementNote(i)}}
}
