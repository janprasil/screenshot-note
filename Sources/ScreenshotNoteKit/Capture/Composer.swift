import AppKit
import Carbon
import ServiceManagement

/// Šipka posunu snímků: klik ani hover neprojdou na snímek pod ní, ani když je vypnutá.
final class ShotArrowButton:AppButton {
 override func hitTest(_ point:NSPoint)->NSView?{isHidden ? nil:(frame.contains(point) ? self:nil)}
 override func mouseDown(with event:NSEvent){if isEnabled{super.mouseDown(with:event)}}
}

final class ScreenshotThumbnailButton:NSButton {
 /// Atributy čísla karty jednou: font vytvářený při každém kreslení se při posunu řady (macOS 26) vrátil jako nil a CoreText spadl.
 static let numberAttributes:[NSAttributedString.Key:Any]=[.font:nonNilFont(NSFont.monospacedSystemFont(ofSize:10,weight:.medium),fallback:10),.foregroundColor:AppPalette.secondary]
 let notePreview=NSTextField(labelWithString:"")
 var imageDisplayRect:NSRect{
  // Nahoře odebrání a odznaky videa či kontextu, dole číslo a poznámka.
  let space=NSRect(x:7,y:34,width:bounds.width-14,height:bounds.height-68)
  guard let image,image.size.width>0,image.size.height>0 else{return space}
  let scale=min(space.width/image.size.width,space.height/image.size.height),size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
  return NSRect(x:space.midX-size.width/2,y:space.midY-size.height/2,width:size.width,height:size.height)
 }
 private var hover=false
 private var hoverTracking:NSTrackingArea?
 override func updateTrackingAreas(){
  super.updateTrackingAreas()
  if let area=hoverTracking{removeTrackingArea(area)}
  let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.inVisibleRect,.cursorUpdate],owner:self,userInfo:nil)
  addTrackingArea(area);hoverTracking=area
 }
 // Odebraný náhled si sledování myši smaže, aby AppKit neposílal události uvolněnému objektu.
 override func viewWillMove(toWindow newWindow:NSWindow?){super.viewWillMove(toWindow:newWindow);if newWindow==nil,let area=hoverTracking{removeTrackingArea(area);hoverTracking=nil}}
 func setHovered(_ value:Bool){hover=value;needsDisplay=true}
 /// Hover jen když kurzor míří na kartu, ne na šipku nebo křížek nad ní.
 private func covered(_ event:NSEvent)->Bool{guard let content=window?.contentView,let hit=content.hitTest(content.convert(event.locationInWindow,from:nil)) else{return true};return !hit.isDescendant(of:self)}
 override func mouseEntered(with event:NSEvent){setHovered(!covered(event))}
 override func mouseMoved(with event:NSEvent){let value = !covered(event);if value != hover{setHovered(value)}}
 /// Klik otevře editor; podržení a tažení do strany posouvá řadu snímků jako skrytý posuvník.
 override func mouseDown(with event:NSEvent){
  guard let scroll=enclosingScrollView,let window else{super.mouseDown(with:event);return}
  let clip=scroll.contentView,start=event.locationInWindow.x,origin=clip.bounds.origin.x
  let limit=max(0,(scroll.documentView?.frame.width ?? 0)-clip.bounds.width);var dragging=false
  while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]){
   if next.type == .leftMouseUp{if !dragging{sendAction(action,to:target)};break}
   let dx=next.locationInWindow.x-start
   if !dragging,abs(dx)>4,limit>0{dragging=true;NSCursor.closedHand.push()}
   if dragging{clip.scroll(to:NSPoint(x:min(limit,max(0,origin-dx)),y:clip.bounds.origin.y));scroll.reflectScrolledClipView(clip)}
  }
  if dragging{NSCursor.pop()}
 }
 override func cursorUpdate(with event:NSEvent){(covered(event) ? NSCursor.arrow:NSCursor.pointingHand).set()}
 override func mouseExited(with event:NSEvent){setHovered(false)}
 override func draw(_ dirtyRect:NSRect){
  let card=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:10,yRadius:10)
  AppPalette.raised.setFill();card.fill()
  if let image{image.draw(in:imageDisplayRect)}
  (String(format:"%02d",tag+1) as NSString).draw(at:NSPoint(x:10,y:bounds.height-21),withAttributes:Self.numberAttributes)
  if hover{AppPalette.accent.withAlphaComponent(0.8).setStroke();card.lineWidth=1.5;card.stroke()}
 }

}

final class SessionCommentField:CenteredTextField {
 private var multilineSource:String?
 var onExpand:(()->Void)?
 var markdownText:String {
  get{multilineSource ?? stringValue}
  set{
   multilineSource=newValue.rangeOfCharacter(from:.newlines) == nil ? nil:newValue
   stringValue=newValue.components(separatedBy:.newlines).joined(separator:" ")
   isEditable=multilineSource == nil
   toolTip=multilineSource == nil ? nil:L("Víceřádkový komentář · kliknutím otevřít Markdown editor")
  }
 }
 override func mouseDown(with event:NSEvent){if multilineSource != nil {onExpand?()}else{super.mouseDown(with:event)}}
}

final class Composer:NSObject,NSWindowDelegate {
 var window:NSWindow!;var draft:Draft;let root:URL;var complete:((Int,Draft)->Void)?
 let titleField=CenteredTextField();let comment=SessionCommentField();var buttons:[NSButton]=[]
 // Souhrn kontextu podle obrázku; čte se jednou, soubor může mít desítky MiB.
 private var contextSummaries:[String:ContextSummary?]=[:]
 let thumbnails=NSView();let thumbnailScroll=NSScrollView();let previousShots=ShotArrowButton();let nextShots=ShotArrowButton();let topicLink=ContextLinkButton();let sessionLink=ContextLinkButton();let topicPicker=NSPopUpButton();let topicDescription=NSTextField(labelWithString:"")
 let laterButton=AppButton();let saveButton=AppButton();var availableTopics:[Topic]=[]
 let copyLinkButton=AppButton();var sharing=false
 let addShotButton=AppButton();let captureOptions=AppButton();let captureGroup=DesignSurface(frame:.zero,fill:AppPalette.raised,radius:8);var onCapture:((Bool)->Void)?
 private var screenTimer:Timer?
 private var pointerScreenFrame:NSRect?
 deinit{screenTimer?.invalidate()}
 var expandedContent:NSView?;var expandedFrame:NSRect?;var isCompact=false
 /// Během záznamu: místo snímání tlačítko Zastavit (i ve sbaleném okně); zastavení obslouží AppDelegate.
 var onStopRecording:(()->Void)?
 private(set) var recordingState:RecordingController.State = .idle
 let stopRecordingButton=AppButton()
 let imageCount=NSTextField(labelWithString:"")
 var childEditorOpen=false
 let sessionPicker=NSPopUpButton();var previousChoices:[PreviousSession]=[]
 var selectionText:[String:(String,String)]=[:]


 init(draft:Draft,root:URL){self.draft=draft;self.root=root;if self.draft.topic == nil{self.draft.topic=Topics.initialTopic}}
 func show(present:Bool=true){
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:800,height:586),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title="";window.titleVisibility = .hidden;window.isReleasedWhenClosed=false;window.delegate=self
  let view=installDesignRoot(window,headerHeight:108,showClose:false)
  titleField.frame=NSRect(x:26,y:500,width:692,height:44);titleField.isBordered=false;titleField.drawsBackground=false;titleField.font = .systemFont(ofSize:27,weight:.semibold);titleField.textColor = .labelColor;titleField.placeholderString=L("Nadpis poznámky");titleField.stringValue=draft.title ?? "";view.addSubview(titleField)
  let collapse=styledButton("",symbol:"arrow.down.right.and.arrow.up.left",role:.quiet,frame:NSRect(x:736,y:506,width:36,height:34),target:self,action:#selector(toggleCompact));collapse.toolTip=L("Sbalit poznámku a prohlédnout si okno pod ní");view.addSubview(collapse)
  for (button,symbol,x,width,action) in [(topicLink,"folder",CGFloat(28),CGFloat(400),#selector(chooseConfiguration))]{
   button.role = .quiet;button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.imagePosition = .imageLeading;button.target=self;button.action=action;button.frame=NSRect(x:x,y:430,width:width,height:36);view.addSubview(button)
  }
  let add=addShotButton;add.title=L("Přidat výřez");add.image=NSImage(systemSymbolName:"plus.viewfinder",accessibilityDescription:nil);add.imagePosition = .imageLeading;add.target=self;add.action=#selector(addScreenshot)
  let share=copyLinkButton;share.role = .quiet;share.target=self;share.action=#selector(copyLink);share.isHidden=true;view.addSubview(share);setCopyLinkState(copied:false)
  view.addSubview(captureGroup)
  add.role = .quiet;captureGroup.addSubview(add)
  captureGroup.addSubview(DesignDivider(NSRect(x:140,y:7,width:1,height:18)))
  captureOptions.role = .quiet
  captureOptions.image=NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil);captureOptions.imagePosition = .imageOnly
  captureOptions.target=self;captureOptions.action=#selector(showCaptureOptions);captureOptions.toolTip=L("Další možnosti snímání");captureOptions.setAccessibilityLabel(L("Další možnosti snímání"));captureGroup.addSubview(captureOptions)
  configureStopButton(stopRecordingButton);view.addSubview(stopRecordingButton);updateRecordingControls()
  refreshTopics()
  // Snímky se posouvají šipkami (po stránkách, plynule); posuvník je skrytý. Vrstva zrychlí kreslení při posunu.
  thumbnailScroll.frame=NSRect(x:28,y:180,width:744,height:244);thumbnailScroll.hasHorizontalScroller=false;thumbnailScroll.drawsBackground=false;thumbnailScroll.wantsLayer=true;thumbnailScroll.documentView=thumbnails;view.addSubview(thumbnailScroll)
  thumbnailScroll.contentView.postsBoundsChangedNotifications=true
  NotificationCenter.default.addObserver(self,selector:#selector(updateShotArrows),name:NSView.boundsDidChangeNotification,object:thumbnailScroll.contentView)
  for (arrow,symbol,label,x) in [(previousShots,"chevron.left",L("Předchozí snímky"),CGFloat(14)),(nextShots,"chevron.right",L("Další snímky"),CGFloat(750))]{
   arrow.frame=NSRect(x:x,y:276,width:36,height:36);arrow.role = .secondary;arrow.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);arrow.imagePosition = .imageOnly
   arrow.target=self;arrow.action=#selector(scrollShots(_:));arrow.toolTip=label;arrow.setAccessibilityLabel(label);view.addSubview(arrow)
  }
  let input=AdaptiveInputBackground(frame:NSRect(x:28,y:98,width:744,height:40));view.addSubview(input)
  comment.frame=NSRect(x:12,y:8,width:682,height:24);comment.isBordered=false;comment.drawsBackground=false;comment.textColor = .textColor;comment.font = .systemFont(ofSize:14);comment.usesSingleLineMode=true;comment.lineBreakMode = .byTruncatingTail;comment.placeholderString=L("Přidat komentář…");comment.markdownText=draft.comment;comment.onExpand={[weak self] in self?.expandComment()};input.addSubview(comment)
  let expand=styledButton("",symbol:"line.3.horizontal",role:.quiet,frame:NSRect(x:702,y:4,width:34,height:32),target:self,action:#selector(expandComment));expand.toolTip=L("Otevřít Markdown editor");input.addSubview(expand)
  view.addSubview(DesignDivider(NSRect(x:28,y:78,width:744,height:1)))
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:28,y:22,width:90,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";view.addSubview(cancel)
  let save=saveButton;save.title=L("Uložit");save.image=NSImage(systemSymbolName:"checkmark",accessibilityDescription:nil);save.imagePosition = .imageLeading;save.role = .primary;save.target=self;save.action=#selector(self.save);save.frame=NSRect(x:644,y:22,width:128,height:34);save.keyEquivalent="\r";view.addSubview(save)
  reloadThumbnails();if present{presentScreenshotPanel(window)};window.makeFirstResponder(titleField)
  if present && !isExportingDesign{
   pointerScreenFrame=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)}?.frame
   let timer=Timer(timeInterval:0.12,repeats:true){[weak self] _ in self?.followPointerScreen()}
   screenTimer=timer;RunLoop.main.add(timer,forMode:.default)
  }
 }
 func refreshTopics(){
  availableTopics=Topics.all
  if let fallback=fallbackFromHiddenFolder(draft){draft=fallback}
  if let saved=draft.topic {if let i=availableTopics.firstIndex(where:{$0.id==saved.id}){availableTopics[i]=saved}else{availableTopics.append(saved)}}
  topicPicker.removeAllItems();topicPicker.addItems(withTitles:availableTopics.map{$0.displayName})
  // Týmová složka má ikonu týmu.
  for (item,topic) in zip(topicPicker.itemArray,availableTopics) where topic.cloudTeam==true{item.image=NSImage(systemSymbolName:"person.2",accessibilityDescription:L("Týmová složka"));item.image?.isTemplate=true}
  if let i=availableTopics.firstIndex(where:{$0.id==draft.topic?.id}){topicPicker.selectItem(at:i)}
  changeTopic()
 }
 @objc func changeTopic(){
  let i=topicPicker.indexOfSelectedItem;guard availableTopics.indices.contains(i) else{return}
  guard draft.previous == nil || draft.topic?.id == availableTopics[i].id else{return}
  draft.topic=availableTopics[i];let topic=availableTopics[i];topicDescription.stringValue=topic.detail+(topic.detail.isEmpty ? "":" · ")+(topic.combined ? L("Jeden společný MD"):L("MD pro každou relaci"))
  topicLink.title=topic.displayName;topicLink.toolTip=topic.displayName+(topic.detail.isEmpty ? "":"\n"+topic.detail)
  refreshPreviousSessions()
 }
 @objc func refreshSavedSessions(){refreshPreviousSessions()}
 func refreshPreviousSessions(){
  do{let topic=draft.topic ?? Topics.defaultTopic;previousChoices=try previousSessions(for:topic);sessionPicker.toolTip=L("Přidat k uložené relaci nebo vytvořit novou")}catch{previousChoices=[];sessionPicker.toolTip=error.localizedDescription}
  sessionPicker.removeAllItems();sessionPicker.addItem(withTitle:L("Nová relace"))
  sessionPicker.addItems(withTitles:previousChoices.map{$0.display})
  if let target=draft.previous,let index=previousChoices.firstIndex(where:{$0.target.id==target.id}){sessionPicker.selectItem(at:index+1)}else{sessionPicker.selectItem(at:0)}
  updatePreviousAvailability()
 }
 func updatePreviousAvailability(){sessionLink.title=draft.previous.flatMap{target in previousChoices.first{$0.target.id==target.id}?.title} ?? L("Nová relace");sessionLink.toolTip=sessionLink.title
  sessionLink.isEnabled=draft.topic?.savesLocally != false
  topicLink.isEnabled=draft.previous == nil;topicLink.needsDisplay=true
  topicLink.toolTip=draft.previous == nil ? draft.topic.map{$0.displayName+($0.detail.isEmpty ? "":"\n"+$0.detail)}:L("Konfiguraci uložené relace nelze změnit.")
  copyLinkButton.isHidden=shareableSessionID()==nil
  layoutContextRow()
 }
 func layoutContextRow(){
  let available=max(0,(topicLink.superview?.bounds.width ?? window?.contentView?.bounds.width ?? 800)-56)
  let cap=max(0,(available-32)/3)
  topicLink.frame=NSRect(x:28,y:430,width:topicLink.fittingWidth(maximum:cap),height:36)
  sessionLink.frame=NSRect(x:topicLink.frame.maxX+16,y:430,width:sessionLink.fittingWidth(maximum:cap),height:36)
  // Odkaz relace se v okně nezobrazuje; kdyby ano, tlačítko jde až za něj.
  let anchor=sessionLink.superview == nil || sessionLink.isHidden ? topicLink.frame.maxX:sessionLink.frame.maxX
  copyLinkButton.frame=NSRect(x:anchor+8,y:432,width:copyLinkWidth(maximum:cap),height:32)
  let trailing=28+available
  captureGroup.frame=NSRect(x:trailing-174,y:432,width:174,height:32)
  addShotButton.frame=NSRect(x:0,y:0,width:140,height:32)
  captureOptions.frame=NSRect(x:141,y:0,width:33,height:32)
  stopRecordingButton.frame=captureGroup.frame
 }
 private func configureStopButton(_ button:AppButton){button.role = .primary;button.image=NSImage(systemSymbolName:"stop.circle",accessibilityDescription:nil);button.imagePosition = .imageLeading;button.target=self;button.action=#selector(stopRecording)}
 @objc func stopRecording(){onStopRecording?()}
 /// Stav záznamu z AppDelegate: snímání se skryje, místo něj Zastavit (při nastavení a odpočtu Zrušit).
 func setRecordingState(_ state:RecordingController.State){recordingState=state;updateRecordingControls()}
 private var stopTitle:String{recordingState == .recording ? L("Zastavit záznam"):L("Zrušit záznam")}
 private func updateRecordingControls() {
  let active=recordingState != .idle
  captureGroup.isHidden=active;stopRecordingButton.isHidden = !active
  stopRecordingButton.title=stopTitle;stopRecordingButton.isEnabled=recordingState != .finishing;stopRecordingButton.needsDisplay=true
  if isCompact,let window{layoutCompact(window,animate:false)}
 }
 func shareableSessionID()->UUID?{CloudLibrary.shared.shareableSessionID(draft,index:SessionIndex.shared,serverImages:CloudFolders.shared.serverImages)}
 func copyLinkWidth(maximum:CGFloat)->CGFloat{min(maximum,ceil((copyLinkButton.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)+47)}
 // Jediné místo, kde se mění vzhled tlačítka Sdílet odkaz.
 func setCopyLinkState(copied:Bool){
  let title=L("Sdílet odkaz…")
  copyLinkButton.title=title;copyLinkButton.image=NSImage(systemSymbolName:"link",accessibilityDescription:nil);copyLinkButton.imagePosition = .imageLeading
  copyLinkButton.role = .quiet;copyLinkButton.toolTip=L("Nastavit a zkopírovat odkaz na relaci");copyLinkButton.setAccessibilityLabel(title)
  copyLinkButton.needsDisplay=true;layoutContextRow()
 }
 // Sdílet odkaz otevře dialog jako na webu: publikum, adresa, kopírování a zrušení.
 @objc func copyLink(){
  guard !sharing,let id=shareableSessionID() else{return}
  sharing=true;defer{sharing=false}
  childEditorOpen=true;defer{childEditorOpen=false};snapshotFields()
  let title=draft.title ?? "",team=draft.topic?.cloudTeam==true
  MainActor.assumeIsolated{ShareDialog().run(id:id,title:title,team:team)}
  window.makeKeyAndOrderFront(nil)
 }
 @objc func chooseConfiguration(){
  guard draft.previous == nil else{return}
  childEditorOpen=true;defer{childEditorOpen=false};snapshotFields()
  let choices=Topics.all
  let picker=SessionChoiceDialog()
  if let index=picker.run(title:L("Vybrat konfiguraci"),choices:choices.map{SessionChoice(title:$0.displayName,detail:$0.detail+" · "+$0.folder)},current:choices.firstIndex{$0.id==draft.topic?.id} ?? 0){
   if draft.previous != nil && draft.topic?.id != choices[index].id{switchToNewSession()}
   draft.topic=choices[index];refreshTopics()
  };window.makeKeyAndOrderFront(nil)
 }
 @objc func chooseSession(){
  guard draft.topic?.savesLocally != false else{return}
  childEditorOpen=true;defer{childEditorOpen=false};snapshotFields();refreshPreviousSessions()
  var rows=[SessionChoice(title:L("Nová relace"),detail:L("Vytvořit novou poznámku z aktuálních snímků."))]
  rows+=previousChoices.map{session in let assets=URL(fileURLWithPath:session.target.path).deletingLastPathComponent().appendingPathComponent("assets");return SessionChoice(title:session.title,detail:session.display+(session.comment.isEmpty ? "":" · "+session.comment),images:session.images.map{assets.appendingPathComponent($0)})}
  let picker=SessionChoiceDialog()
  if let index=picker.run(title:L("Vybrat relaci"),choices:rows,current:sessionPicker.indexOfSelectedItem){
   let id=index==0 ? nil:previousChoices[index-1].target.id
   if id != draft.previous?.id && !draft.images.isEmpty{
    let alert=NSAlert();alert.messageText=L("Přesunout všechny snímky do vybrané relace?");alert.informativeText=L("Aktuální snímky se přidají do vybrané relace. Změny se zapíší až po uložení.");alert.addButton(withTitle:L("Přesunout snímky"));alert.addButton(withTitle:L("Zrušit"))
    guard alert.runModal() == .alertFirstButtonReturn else{window.makeKeyAndOrderFront(nil);return}
   }
   sessionPicker.selectItem(at:index);changePreviousSession()
  };window.makeKeyAndOrderFront(nil)
 }
 func switchToNewSession(){
  snapshotFields();if let target=draft.previous{selectionText[target.cacheKey]=(draft.title ?? "",draft.comment)}
  draft.previous=nil;draft.removedContexts=nil
  let text=selectionText["new"] ?? (draft.title ?? "",draft.comment);draft.title=text.0;draft.comment=text.1;titleField.stringValue=text.0;comment.markdownText=text.1
  sessionPicker.selectItem(at:0);reloadThumbnails()
 }
 @objc func changePreviousSession(){
  let selected=sessionPicker.indexOfSelectedItem
  if selected==0{if draft.previous != nil{switchToNewSession()};return}
  guard previousChoices.indices.contains(selected-1) else{return}
  let chosen=previousChoices[selected-1]
  if chosen.target.id==draft.previous?.id && chosen.target.fingerprint==draft.previous?.fingerprint{return}
  snapshotFields();selectionText[draft.previous?.cacheKey ?? "new"]=(draft.title ?? "",draft.comment)
  let fresh=draft.images;var notes=draft.imageNotes ?? [:];var reused=Set<String>();var contexts=draft.contexts ?? [:]
  var imported:[String:String]=[:];var importedNames:[String]=[]
  do{
   _ = try checkedPreviousFile(chosen.target)
   let assets=URL(fileURLWithPath:chosen.target.path).deletingLastPathComponent().appendingPathComponent("assets")
   for image in chosen.images{
    let source=assets.appendingPathComponent(image);let data=try Data(contentsOf:source)
    if let existing=fresh.first(where:{!reused.contains($0) && (try? Data(contentsOf:root.appendingPathComponent($0)))==data}){
     reused.insert(existing);imported[existing]=image;if notes[existing]==nil{notes[existing]=chosen.imageNotes[image]};continue
    }
    let name=UUID().uuidString+".png";let target=root.appendingPathComponent(name);try data.write(to:target,options:.withoutOverwriting);importedNames.append(name);try copyAnnotationSidecar(from:source,to:target);imported[name]=image;notes[name]=chosen.imageNotes[image]
    if try importAssetContext(assets:assets,image:image,to:target){contexts[name]=name+".context.json"}
    // Video zůstane u položky i po úpravě posteru.
    try importAssetVideo(assets:assets,image:image,to:target)
   }
  }catch{for name in importedNames{removeAnnotatedImage(root.appendingPathComponent(name))};showError(error.localizedDescription);restorePreviousSelection();return}
  draft.images=importedNames+fresh;draft.imageNotes=notes;draft.contexts=contexts.isEmpty ? nil:contexts;var target=chosen.target;target.imported=imported;draft.previous=target;draft.removedContexts=nil
  let addedComment=draft.comment
  let text=selectionText[target.cacheKey] ?? (chosen.title,chosen.comment+(addedComment.isEmpty || addedComment==chosen.comment ? "":"\n\n"+addedComment))
  draft.title=text.0;draft.comment=text.1;titleField.stringValue=text.0;comment.markdownText=text.1
  reloadThumbnails()
 }
 func restorePreviousSelection(){if let previous=draft.previous,let i=previousChoices.firstIndex(where:{$0.target.id==previous.id}){sessionPicker.selectItem(at:i+1)}else{sessionPicker.selectItem(at:0)}}
 func reloadThumbnails(){
  for view in thumbnails.subviews{view.removeFromSuperview()};buttons=[]
  thumbnails.frame=NSRect(x:0,y:0,width:max(744,CGFloat(draft.images.count)*238-14),height:226)
  for(i,image) in draft.images.enumerated(){
   let button=ScreenshotThumbnailButton(frame:NSRect(x:CGFloat(i)*238,y:0,width:224,height:226));button.image=thumbnailImage(root.appendingPathComponent(image));button.imageScaling = .scaleProportionallyUpOrDown;button.imagePosition = .imageOnly;button.tag=i;button.target=self;button.action=#selector(edit);button.toolTip=L("Kliknutím zvětšit a upravit");thumbnails.addSubview(button);buttons.append(button)
   let text=draft.imageNotes?[image] ?? ""
   let preview=button.notePreview;preview.stringValue=text.components(separatedBy:.newlines).joined(separator:" ");preview.toolTip=text
   preview.frame=NSRect(x:34,y:button.bounds.height-24,width:180,height:18);preview.font = .systemFont(ofSize:11);preview.textColor=AppPalette.secondary;preview.usesSingleLineMode=true;preview.maximumNumberOfLines=1;preview.lineBreakMode = .byTruncatingTail;button.addSubview(preview)
   // Klik na kartu otevře editor anotací a poznámky; hover jen ohraničí kartu.
   button.setAccessibilityLabel(LF("Snímek %ld · anotace a poznámka",i+1))
   let remove=styledButton("",symbol:"xmark",role:.quiet,frame:NSRect(x:CGFloat(i)*238+196,y:198,width:24,height:24),target:self,action:#selector(removeImage(_:)));remove.tag=i;remove.toolTip=L("Odebrat tento obrázek z relace");thumbnails.addSubview(remove)
   let video=videoSidecars(root.appendingPathComponent(image)),info=fm.fileExists(atPath:video[0].path) ? readVideoInfo(video[1]):nil
   // S videem dostane odznak kontextu užší místo, přehrání má vždy 84 bodů.
   let context=draft.contexts?[image] != nil ? contextBadge(image,index:i,maxWidth:info == nil ? 188:96):nil
   if let context{thumbnails.addSubview(context)}
   if let info {
    let x=CGFloat(i)*238+4+(context.map{$0.frame.width+6} ?? 0)
    let badge=styledButton(videoDuration(info.durationMs),symbol:"play.rectangle",frame:NSRect(x:x,y:198,width:84,height:24),target:self,action:#selector(playVideo(_:)))
    badge.tag=i;badge.toolTip=LF("Video %@ – přehrát",videoDuration(info.durationMs));badge.setAccessibilityLabel(badge.toolTip);thumbnails.addSubview(badge)
   }
  }
  if draft.images.isEmpty{thumbnails.addSubview(label(L("Žádný obrázek. Přidej výřez nebo snímek celé obrazovky."),NSRect(x:8,y:102,width:720,height:24)))}
  laterButton.isEnabled=true;saveButton.isEnabled = !draft.images.isEmpty;addShotButton.isEnabled=true;updatePreviousAvailability();updateShotArrows()
 }
 /// Šipky jen když se snímky nevejdou; levá je na začátku vypnutá, pravá na konci.
 @objc func updateShotArrows(){
  let offset=thumbnailScroll.contentView.bounds.origin.x,visible=thumbnailScroll.contentView.bounds.width,total=thumbnails.frame.width
  let overflow=total>visible+1
  previousShots.isHidden = !overflow;nextShots.isHidden = !overflow
  previousShots.isEnabled=offset>1;nextShots.isEnabled=offset+visible<total-1
  previousShots.needsDisplay=true;nextShots.needsDisplay=true
 }
 /// Posun o tolik celých snímků, kolik se vejde do okna, s krátkou animací.
 @objc func scrollShots(_ sender:NSButton){
  let clip=thumbnailScroll.contentView,step=max(238,floor(clip.bounds.width/238)*238)
  let maxX=max(0,thumbnails.frame.width-clip.bounds.width)
  let target=min(maxX,max(0,(sender === previousShots ? clip.bounds.origin.x-step:clip.bounds.origin.x+step)))
  NSAnimationContext.runAnimationGroup({context in context.duration=0.25;context.allowsImplicitAnimation=true;clip.animator().setBoundsOrigin(NSPoint(x:target,y:0))},completionHandler:{[weak self] in guard let self else{return};MainActor.assumeIsolated{self.thumbnailScroll.reflectScrolledClipView(clip);self.updateShotArrows()}})
 }
 func snapshotFields(){guard window != nil else{return};window.makeFirstResponder(nil);draft.title=titleField.stringValue;draft.comment=comment.markdownText}
 @objc func addScreenshot(){captureScreenshot(full:false)}
 @objc func addFullscreenScreenshot(){captureScreenshot(full:true)}
 /// Spuštění záznamu videa z panelu (otevře nastavení záznamu).
 var onRecord:(()->Void)?
 /// Zda jde záznam právě spustit (neběží jiný záznam ani snímání).
 var recordingAvailable:()->Bool={true}
 /// Menu pod Přidat výřez: snímek celé obrazovky a záznam videa.
 func captureOptionsMenu()->NSMenu {
  let menu=NSMenu();menu.autoenablesItems=false
  let fullscreen=NSMenuItem(title:L("Přidat snímek celé obrazovky"),action:#selector(addFullscreenScreenshot),keyEquivalent:"")
  fullscreen.target=self;fullscreen.image=NSImage(systemSymbolName:"display",accessibilityDescription:nil);menu.addItem(fullscreen)
  let record=NSMenuItem(title:L("Nahrát video…"),action:#selector(recordVideo),keyEquivalent:"");record.target=self;record.image=NSImage(systemSymbolName:"record.circle",accessibilityDescription:nil)
  record.isEnabled=onRecord != nil && recordingAvailable();menu.addItem(record)
  return menu
 }
 @objc func recordVideo(){onRecord?()}
 @objc func showCaptureOptions(){
  let menu=captureOptionsMenu()
  menu.popUp(positioning:nil,at:NSPoint(x:0,y:captureOptions.isFlipped ? captureOptions.bounds.maxY+4:captureOptions.bounds.minY-4),in:captureOptions)
 }
 private func captureScreenshot(full:Bool){
  guard let onCapture else{return}
  collapseCompact();onCapture(full)
 }
 private func followPointerScreen(){
  guard let window,window.isVisible,!childEditorOpen,NSApp.modalWindow == nil,NSEvent.pressedMouseButtons == 0,
        let screen=NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) else{return}
  guard screen.frame != pointerScreenFrame else{return}
  pointerScreenFrame=screen.frame
  guard window.screen?.frame != screen.frame else{return}
  let size=expandedFrame?.size ?? window.frame.size
  let visible=screen.visibleFrame
  let origin=NSPoint(x:max(visible.minX,visible.midX-size.width/2),y:min(visible.maxY-size.height,max(visible.minY,visible.midY-size.height/2)))
  let destination=isCompact ? NSPoint(x:origin.x+size.width-window.frame.width,y:origin.y+size.height-window.frame.height):origin
  window.setFrameOrigin(destination)
 }
 @objc func toggleCompact(){if isCompact{expandCompact()}else{collapseCompact()}}
 func collapseCompact(){
  guard !isCompact,let window=window else{return};snapshotFields();expandedFrame=window.frame;expandedContent=window.contentView
  isCompact=true;layoutCompact(window,animate:window.isVisible && !isExportingDesign && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
  // Sbalené okno se nesdílí do snímků obrazovky (záznam vlastní aplikaci vynechává i tak).
  window.sharingType = .none
 }
 /// Obsah sbaleného okna: Rozbalit, během záznamu navíc Zastavit; pravý horní roh zůstává na místě.
 private func layoutCompact(_ window:NSWindow,animate:Bool) {
  let recording=recordingState != .idle,width:CGFloat=recording ? 230+150:230
  let compact=DesignSurface(frame:NSRect(x:0,y:0,width:width,height:42))
  let restore=styledButton(L("Rozbalit poznámku"),symbol:"arrow.up.left.and.arrow.down.right",role:.quiet,frame:NSRect(x:6,y:5,width:218,height:32),target:self,action:#selector(toggleCompact));restore.toolTip=L("Vrátit snímky, nadpis a komentář");compact.addSubview(restore)
  if recording{let stop=AppButton(title:stopTitle,target:nil,action:nil);configureStopButton(stop);stop.frame=NSRect(x:230,y:5,width:144,height:32);stop.isEnabled=recordingState != .finishing;compact.addSubview(stop)}
  let old=window.frame;window.contentView=compact;let size=window.frameRect(forContentRect:NSRect(x:0,y:0,width:width,height:42)).size
  window.setFrame(NSRect(x:old.maxX-size.width,y:old.maxY-size.height,width:size.width,height:size.height),display:true,animate:animate)
 }
 func expandCompact(){guard isCompact,let content=expandedContent,let frame=expandedFrame else{return};window.sharingType = .readOnly;let visible=window.isVisible;let current=window.frame;let destination=NSRect(x:current.maxX-frame.width,y:current.maxY-frame.height,width:frame.width,height:frame.height);window.contentView=content;window.setFrame(destination,display:true,animate:visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !isExportingDesign);isCompact=false;expandedContent=nil;expandedFrame=nil;if visible{window.makeKeyAndOrderFront(nil)}}
 func reveal(){expandCompact();presentScreenshotPanel(window)}
 @discardableResult func appendCapturedImage(_ filename:String,context:Bool=false)->Bool{
  guard !draft.images.contains(filename),!filename.contains("/"),fm.fileExists(atPath:root.appendingPathComponent(filename).path) else{return false}
  draft.images.append(filename);if context{draft.contexts=(draft.contexts ?? [:]).merging([filename:filename+".context.json"]){$1}};reloadThumbnails();thumbnails.scroll(NSPoint(x:max(0,thumbnails.bounds.width-thumbnailScroll.contentSize.width),y:0));return true
 }
 @objc func removeImage(_ sender:NSButton){guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images.remove(at:sender.tag);draft.previous?.imported.removeValue(forKey:name);draft.imageNotes?.removeValue(forKey:name);draft.contexts?.removeValue(forKey:name);contextSummaries[name]=nil;removeAnnotatedImage(root.appendingPathComponent(name));reloadThumbnails()}
 /// Odznak kontextu z prohlížeče: jen „Kontext“, počty chyb v tooltipu, kliknutím nabídka s odebráním.
 @objc func playVideo(_ sender:NSButton){guard draft.images.indices.contains(sender.tag) else{return};NSWorkspace.shared.open(videoSidecars(root.appendingPathComponent(draft.images[sender.tag]))[0])}
 private func contextBadge(_ image:String,index:Int,maxWidth:CGFloat=188)->AppButton {
  if contextSummaries[image]==nil{contextSummaries[image]=(try? boundedData(root.appendingPathComponent(image).appendingPathExtension("context.json"),max:maxContextBytes)).flatMap(ContextSummary.init)}
  let summary=contextSummaries[image] ?? nil
  let title=L("Kontext")
  let width=min(maxWidth,(title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width+39)
  let badge=styledButton(title,symbol:"ladybug",frame:NSRect(x:CGFloat(index)*238+4,y:198,width:width,height:24),target:self,action:#selector(showContextMenu(_:)));badge.tag=index
  badge.toolTip=L("Kontext z prohlížeče")+(summary.map{": "+$0.counts} ?? "");badge.setAccessibilityLabel(badge.toolTip)
  return badge
 }
 @objc func showContextMenu(_ sender:NSButton){
  guard draft.images.indices.contains(sender.tag) else{return}
  let menu=NSMenu();menu.autoenablesItems=false
  if let summary=contextSummaries[draft.images[sender.tag]] ?? nil {
   let info=NSMenuItem(title:(summary.url.isEmpty ? L("Kontext z prohlížeče"):summary.url),action:nil,keyEquivalent:"");info.isEnabled=false;info.toolTip=summary.counts;menu.addItem(info);menu.addItem(.separator())
  }
  let remove=NSMenuItem(title:L("Odebrat kontext"),action:#selector(removeContext(_:)),keyEquivalent:"");remove.target=self;remove.tag=sender.tag;remove.image=NSImage(systemSymbolName:"trash",accessibilityDescription:nil);menu.addItem(remove)
  menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.isFlipped ? sender.bounds.maxY+4:sender.bounds.minY-4),in:sender)
 }
 @objc func removeContext(_ sender:NSMenuItem){guard draft.images.indices.contains(sender.tag) else{return};removeImageContext(draft.images[sender.tag])}
 /// Smaže soubory kontextu v pracovní složce; u znovuotevřené relace je finish smaže i z assets/.
 func removeImageContext(_ image:String){dropImageContext(image);reloadThumbnails()}
 func dropImageContext(_ image:String){
  // U obrázku z uložené relace si draft pamatuje původní název, aby export smazal i soubory v assets/.
  if let original=draft.previous?.imported[image],draft.removedContexts?.contains(original) != true{draft.removedContexts=(draft.removedContexts ?? [])+[original]}
  draft.contexts?.removeValue(forKey:image);if draft.contexts?.isEmpty==true{draft.contexts=nil};contextSummaries[image]=nil
  for url in contextSidecars(root.appendingPathComponent(image)){try? fm.removeItem(at:url)}
 }
 @objc func expandComment(){childEditorOpen=true;defer{childEditorOpen=false};window.makeFirstResponder(nil);let editor=MarkdownEditor();if let value=editor.run(comment.markdownText){comment.markdownText=value};window.makeKeyAndOrderFront(nil)}
 @objc func edit(_ sender:NSButton){
  guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images[sender.tag]
  childEditorOpen=true;defer{childEditorOpen=false};let editor=AnnotationEditor()
  // Editor ukáže vpravo i poznámku ke snímku; změněná poznámka se uloží spolu s anotacemi.
  if editor.run(url:root.appendingPathComponent(name),caption:draft.imageNotes?[name] ?? "",note:true){
   if let note=editor.noteResult{setImageNote(note,for:name)}else{reloadThumbnails()}
  };window.makeKeyAndOrderFront(nil)
 }

 func setImageNote(_ value:String,for image:String){
  guard draft.images.contains(image) else{return}
  if draft.imageNotes == nil{draft.imageNotes=[:]}
  if value.isEmpty{draft.imageNotes?.removeValue(forKey:image)}else{draft.imageNotes?[image]=value}
  reloadThumbnails()
 }

 func end(_ result:Int){snapshotFields();window.orderOut(nil);complete?(result,draft)}
 // Vrací true, když by Zrušit ztratilo neuloženou práci.
 var hasUnsavedWork:(()->Bool)?
 enum CancelChoice{case keep,later,discard}
 /// Zrušit s neuloženou prací se nejdřív zeptá; nil znamená pokračovat v úpravách.
 /// 0 zavře bez změn a odložený koncept nechá, 3 ho výslovně zahodí.
 func requestedCancel(confirm:()->CancelChoice)->Int? {
  snapshotFields()
  guard hasUnsavedWork?() ?? false else{return 0}
  switch confirm(){case .discard:return 3;case .later:return 1;case .keep:return nil}
 }
 static func confirmDiscard()->CancelChoice {
  let alert=NSAlert();alert.messageText=L("Zahodit rozpracovanou poznámku?");alert.informativeText=L("Neuložené snímky a text se ztratí. Můžeš je odložit a později otevřít z menu.")
  alert.addButton(withTitle:L("Odložit na později"));let discard=alert.addButton(withTitle:L("Zahodit"));discard.hasDestructiveAction=true
  let keep=alert.addButton(withTitle:L("Pokračovat v úpravách"));keep.keyEquivalent="\u{1b}"
  alert.window.level = .modalPanel
  switch alert.runModal(){case .alertFirstButtonReturn:return .later;case .alertSecondButtonReturn:return .discard;default:return .keep}
 }
 @objc func cancel(){if let result=requestedCancel(confirm:Self.confirmDiscard){end(result)}};@objc func later(){end(1)};@objc func save(){end(2)}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}

/// Zmenšená kopie snímku pro pruh náhledů; velké PNG by při posunu zpomalovaly kreslení.
func thumbnailImage(_ url:URL,maxPixel:Int=480)->NSImage?{
 guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),
       let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maxPixel,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary)
 else{return NSImage(contentsOf:url)}
 return NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
}

/// Systémové API fontů je anotované jako nenulové, ale může vrátit nil; nil ve slovníku atributů shodí CoreText.
func nonNilFont(_ font:NSFont,fallback size:CGFloat)->NSFont{
 unsafeBitCast(font,to:Int.self) == 0 ? (NSFont(name:"Menlo",size:size) ?? NSFont.systemFont(ofSize:size)):font
}
