import AppKit
import Carbon
import ServiceManagement

final class ThumbnailActionButton:AppButton {
 var expandedTitle=""
 var collapsedFrame=NSRect.zero
 var expandsLeft=false
 var overlayOpacity:CGFloat{hovered ? 0.76:0.48}
 func setExpanded(_ expanded:Bool,animated:Bool){hovered=expanded;needsDisplay=true}
 override func mouseEntered(with event:NSEvent){setExpanded(true,animated:false)}
 override func mouseExited(with event:NSEvent){setExpanded(false,animated:false)}
 override func draw(_ dirtyRect:NSRect){
  NSColor.black.withAlphaComponent(overlayOpacity).setFill();bounds.fill()
  let symbol=image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:17,weight:.medium))
  let font=NSFont.systemFont(ofSize:13,weight:.semibold)
  let text=expandedTitle as NSString,textWidth=text.size(withAttributes:[.font:font]).width
  let width=textWidth+27,x=(bounds.width-width)/2,y=(bounds.height-20)/2
  drawAdaptiveSymbol(symbol,in:NSRect(x:x,y:y,width:20,height:20),color:.white)
  text.draw(in:NSRect(x:x+27,y:y+2,width:textWidth+1,height:19),withAttributes:[.font:font,.foregroundColor:NSColor.white])
 }
}

final class ScreenshotThumbnailButton:NSButton {
 let notePreview=NSTextField(labelWithString:"")
 var imageDisplayRect:NSRect{
  let space=NSRect(x:7,y:39,width:bounds.width-14,height:bounds.height-46)
  guard let image,image.size.width>0,image.size.height>0 else{return space}
  let scale=min(space.width/image.size.width,space.height/image.size.height),size=NSSize(width:image.size.width*scale,height:image.size.height*scale)
  return NSRect(x:space.midX-size.width/2,y:space.midY-size.height/2,width:size.width,height:size.height)
 }
 private var hover=false
 private var hoverActions:[NSButton]=[]
 private var hoverTracking:NSTrackingArea?
 override func resetCursorRects(){super.resetCursorRects();addCursorRect(bounds,cursor:.pointingHand)}
 override func updateTrackingAreas(){
  super.updateTrackingAreas()
  if let area=hoverTracking{removeTrackingArea(area)}
  let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
  addTrackingArea(area);hoverTracking=area
 }
 func addHoverAction(_ action:NSButton){action.isHidden = !hover;hoverActions.append(action);addSubview(action)}
 func setHovered(_ value:Bool){
  hover=value
  for action in hoverActions{
   if !value{(action as? ThumbnailActionButton)?.setExpanded(false,animated:false)}
   action.isHidden = !value
  }
  needsDisplay=true
 }
 override func mouseEntered(with event:NSEvent){setHovered(true)}
 override func mouseExited(with event:NSEvent){setHovered(false)}
 override func draw(_ dirtyRect:NSRect){
  let card=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:10,yRadius:10)
  AppPalette.raised.setFill();card.fill()
  if let image{image.draw(in:imageDisplayRect)}
  (String(format:"%02d",tag+1) as NSString).draw(at:NSPoint(x:10,y:7),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.medium),.foregroundColor:AppPalette.secondary])
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
 let thumbnails=NSView();let thumbnailScroll=NSScrollView();let topicLink=ContextLinkButton();let sessionLink=ContextLinkButton();let topicPicker=NSPopUpButton();let topicDescription=NSTextField(labelWithString:"")
 let laterButton=AppButton();let saveButton=AppButton();var availableTopics:[Topic]=[]
 let copyLinkButton=AppButton();var sharing=false;private var shareFeedback:DispatchWorkItem?
 let addShotButton=AppButton();let captureOptions=AppButton();let captureGroup=DesignSurface(frame:.zero,fill:AppPalette.raised,radius:8);var onCapture:((Bool)->Void)?
 private var screenTimer:Timer?
 private var pointerScreenFrame:NSRect?
 deinit{screenTimer?.invalidate()}
 var expandedContent:NSView?;var expandedFrame:NSRect?;var isCompact=false
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
  refreshTopics()
  thumbnailScroll.frame=NSRect(x:28,y:180,width:744,height:244);thumbnailScroll.hasHorizontalScroller=true;thumbnailScroll.autohidesScrollers=true;thumbnailScroll.drawsBackground=false;thumbnailScroll.documentView=thumbnails;view.addSubview(thumbnailScroll)
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
 }
 func shareableSessionID()->UUID?{CloudLibrary.shared.shareableSessionID(draft,index:SessionIndex.shared,serverImages:CloudFolders.shared.serverImages)}
 func copyLinkWidth(maximum:CGFloat)->CGFloat{min(maximum,ceil((copyLinkButton.title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)+47)}
 // Jediné místo, kde se mění vzhled tlačítka Kopírovat odkaz.
 func setCopyLinkState(copied:Bool){
  let title=copied ? L("Odkaz zkopírován"):L("Kopírovat odkaz")
  copyLinkButton.title=title;copyLinkButton.image=NSImage(systemSymbolName:copied ? "checkmark":"link",accessibilityDescription:nil);copyLinkButton.imagePosition = .imageLeading
  copyLinkButton.role=copied ? .success:.quiet;copyLinkButton.toolTip=L("Zkopírovat veřejný odkaz na relaci do schránky");copyLinkButton.setAccessibilityLabel(title)
  copyLinkButton.needsDisplay=true;layoutContextRow()
 }
 @objc func copyLink(){
  guard !sharing,let id=shareableSessionID() else{return}
  sharing=true;copyLinkButton.isEnabled=false;shareFeedback?.cancel()
  Task{@MainActor [weak self] in
   do{
    let url=try await CloudLibrary.shared.shareLink(id)
    // Odkaz patří do schránky, i když se okno mezitím zavřelo.
    copyShareLink(url);guard let self else{return}
    self.sharing=false;self.copyLinkButton.isEnabled=true;self.setCopyLinkState(copied:true)
    NSAccessibility.post(element:self.copyLinkButton,notification:.announcementRequested,userInfo:[.announcement:L("Odkaz zkopírován"),.priority:NSAccessibilityPriorityLevel.medium.rawValue])
    let reset=DispatchWorkItem{[weak self] in self?.setCopyLinkState(copied:false)};self.shareFeedback=reset;DispatchQueue.main.asyncAfter(deadline:.now()+2,execute:reset)
   }catch{
    guard let self else{return}
    self.sharing=false;self.copyLinkButton.isEnabled=true
    self.childEditorOpen=true;showError(error.localizedDescription);self.childEditorOpen=false;self.window.makeKeyAndOrderFront(nil)
   }
  }
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
   let button=ScreenshotThumbnailButton(frame:NSRect(x:CGFloat(i)*238,y:0,width:224,height:226));button.image=NSImage(contentsOf:root.appendingPathComponent(image));button.imageScaling = .scaleProportionallyUpOrDown;button.imagePosition = .imageOnly;button.tag=i;button.target=self;button.action=#selector(edit);button.toolTip=L("Kliknutím zvětšit a upravit");thumbnails.addSubview(button);buttons.append(button)
   let text=draft.imageNotes?[image] ?? ""
   let preview=button.notePreview;preview.stringValue=text.components(separatedBy:.newlines).joined(separator:" ");preview.toolTip=text
   preview.frame=NSRect(x:34,y:5,width:180,height:23);preview.font = .systemFont(ofSize:11);preview.textColor=AppPalette.secondary;preview.usesSingleLineMode=true;preview.maximumNumberOfLines=1;preview.lineBreakMode = .byTruncatingTail;button.addSubview(preview)
   let area=button.imageDisplayRect
   let annotate=ThumbnailActionButton(title:"",target:self,action:#selector(edit));annotate.image=NSImage(systemSymbolName:"pencil.tip",accessibilityDescription:nil)
   annotate.expandedTitle=L("Anotace");annotate.setAccessibilityLabel(annotate.expandedTitle);annotate.tag=i
   annotate.frame=NSRect(x:area.minX,y:area.midY,width:area.width,height:area.height/2);annotate.collapsedFrame=annotate.frame;button.addHoverAction(annotate)
   let note=ThumbnailActionButton(title:"",target:self,action:#selector(editImageNote));note.image=NSImage(systemSymbolName:text.isEmpty ? "text.bubble":"text.bubble.fill",accessibilityDescription:nil)
   note.expandedTitle=L("Poznámka");note.setAccessibilityLabel(L("Poznámka ke snímku"));note.tag=i
   note.frame=NSRect(x:area.minX,y:area.minY,width:area.width,height:area.height/2);note.collapsedFrame=note.frame;button.addHoverAction(note)
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
  laterButton.isEnabled=true;saveButton.isEnabled = !draft.images.isEmpty;addShotButton.isEnabled=true;updatePreviousAvailability()
 }
 func snapshotFields(){guard window != nil else{return};window.makeFirstResponder(nil);draft.title=titleField.stringValue;draft.comment=comment.markdownText}
 @objc func addScreenshot(){captureScreenshot(full:false)}
 @objc func addFullscreenScreenshot(){captureScreenshot(full:true)}
 @objc func showCaptureOptions(){
  let menu=NSMenu()
  let fullscreen=NSMenuItem(title:L("Přidat snímek celé obrazovky"),action:#selector(addFullscreenScreenshot),keyEquivalent:"")
  fullscreen.target=self;fullscreen.image=NSImage(systemSymbolName:"display",accessibilityDescription:nil);menu.addItem(fullscreen)
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
  let compact=DesignSurface(frame:NSRect(x:0,y:0,width:230,height:42))
  let restore=styledButton(L("Rozbalit poznámku"),symbol:"arrow.up.left.and.arrow.down.right",role:.quiet,frame:NSRect(x:6,y:5,width:218,height:32),target:self,action:#selector(toggleCompact));restore.toolTip=L("Vrátit snímky, nadpis a komentář");compact.addSubview(restore)
  let old=window.frame;window.contentView=compact;let size=window.frameRect(forContentRect:NSRect(x:0,y:0,width:230,height:42)).size
  let frame=NSRect(x:old.maxX-size.width,y:old.maxY-size.height,width:size.width,height:size.height)
  window.setFrame(frame,display:true,animate:window.isVisible && !isExportingDesign && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion);isCompact=true
 }
 func expandCompact(){guard isCompact,let content=expandedContent,let frame=expandedFrame else{return};let visible=window.isVisible;let current=window.frame;let destination=NSRect(x:current.maxX-frame.width,y:current.maxY-frame.height,width:frame.width,height:frame.height);window.contentView=content;window.setFrame(destination,display:true,animate:visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !isExportingDesign);isCompact=false;expandedContent=nil;expandedFrame=nil;if visible{window.makeKeyAndOrderFront(nil)}}
 func reveal(){expandCompact();presentScreenshotPanel(window)}
 @discardableResult func appendCapturedImage(_ filename:String,context:Bool=false)->Bool{
  guard !draft.images.contains(filename),!filename.contains("/"),fm.fileExists(atPath:root.appendingPathComponent(filename).path) else{return false}
  draft.images.append(filename);if context{draft.contexts=(draft.contexts ?? [:]).merging([filename:filename+".context.json"]){$1}};reloadThumbnails();thumbnails.scroll(NSPoint(x:max(0,thumbnails.bounds.width-thumbnailScroll.contentSize.width),y:0));return true
 }
 @objc func removeImage(_ sender:NSButton){guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images.remove(at:sender.tag);draft.previous?.imported.removeValue(forKey:name);draft.imageNotes?.removeValue(forKey:name);draft.contexts?.removeValue(forKey:name);contextSummaries[name]=nil;removeAnnotatedImage(root.appendingPathComponent(name));reloadThumbnails()}
 /// Odznak kontextu z prohlížeče: počet chyb a selhaných requestů, kliknutím nabídka s odebráním.
 @objc func playVideo(_ sender:NSButton){guard draft.images.indices.contains(sender.tag) else{return};NSWorkspace.shared.open(videoSidecars(root.appendingPathComponent(draft.images[sender.tag]))[0])}
 private func contextBadge(_ image:String,index:Int,maxWidth:CGFloat=188)->AppButton {
  if contextSummaries[image]==nil{contextSummaries[image]=(try? boundedData(root.appendingPathComponent(image).appendingPathExtension("context.json"),max:maxContextBytes)).flatMap(ContextSummary.init)}
  let summary=contextSummaries[image] ?? nil
  let title=summary.map(contextBadgeTitle) ?? L("Kontext")
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
  if editor.run(url:root.appendingPathComponent(name),caption:draft.imageNotes?[name] ?? ""){reloadThumbnails()};window.makeKeyAndOrderFront(nil)
 }

 @objc func editImageNote(_ sender:NSButton){
  guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images[sender.tag]
  childEditorOpen=true;defer{childEditorOpen=false};window.makeFirstResponder(nil)
  let editor=ImageNoteEditor()
  if let value=editor.run(draft.imageNotes?[name] ?? "",image:root.appendingPathComponent(name)){setImageNote(value,for:name)}
  window.makeKeyAndOrderFront(nil)
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
 func requestedCancel(confirm:()->CancelChoice)->Int? {
  snapshotFields()
  guard hasUnsavedWork?() ?? false else{return 0}
  switch confirm(){case .discard:return 0;case .later:return 1;case .keep:return nil}
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
