import AppKit
import Carbon
import ServiceManagement

// Nonactivating panels can take keyboard input without activating the app's old Space.
final class ScreenshotPanel:NSPanel {
 override init(contentRect:NSRect,styleMask style:NSWindow.StyleMask,backing:NSWindow.BackingStoreType,defer flag:Bool){
  let mask=style.subtracting([.titled,.closable,.miniaturizable,.fullSizeContentView]).union(.nonactivatingPanel)
  super.init(contentRect:contentRect,styleMask:mask,backing:backing,defer:flag)
  isOpaque=false;backgroundColor = .clear;hasShadow=true;isMovableByWindowBackground=true
 }

 override var canBecomeKey:Bool {true}
 override var canBecomeMain:Bool {false}
}
var capturePresentationScreen:NSScreen?
func prepareScreenshotPanel(_ window:NSWindow) {
 window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
 window.level = .floating
 if let panel=window as? NSPanel {panel.hidesOnDeactivate=false;panel.isFloatingPanel=true;panel.becomesKeyOnlyIfNeeded=false}
}
func presentScreenshotPanel(_ window:NSWindow) {
 prepareScreenshotPanel(window)
 let screen=NSApp.keyWindow?.screen ?? capturePresentationScreen ?? NSScreen.screens.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? NSScreen.main
 if let frame=screen?.visibleFrame {
  window.setFrameOrigin(NSPoint(x:frame.midX-window.frame.width/2,y:frame.midY-window.frame.height/2))
 }
 if !isExportingDesign{let fresh = !window.isVisible;if fresh && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion{window.alphaValue=0};window.makeKeyAndOrderFront(nil);if fresh{animateDesign{window.animator().alphaValue=1}}}
}
// Draw semantic colors in the view's current appearance instead of freezing CGColors.
final class AdaptiveInputBackground:NSView {
 override func draw(_ dirtyRect:NSRect){let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8);AppPalette.paper.setFill();path.fill();AppPalette.stroke.setStroke();path.lineWidth=1;path.stroke()}

 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}
func drawAdaptiveSymbol(_ image:NSImage?,in rect:NSRect,color:NSColor){
 guard let image=image else{return}
 let resolved=color.usingColorSpace(.sRGB) ?? color
 let factor=min(rect.width/max(1,image.size.width),rect.height/max(1,image.size.height))
 let fitted=NSSize(width:image.size.width*factor,height:image.size.height*factor)
 let destination=NSRect(x:(rect.width-fitted.width)/2,y:(rect.height-fitted.height)/2,width:fitted.width,height:fitted.height)
 let tinted=NSImage(size:rect.size)
 tinted.lockFocus();image.draw(in:destination);resolved.setFill();NSRect(origin:.zero,size:rect.size).fill(using:.sourceIn);tinted.unlockFocus()
 tinted.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
}
func showError(_ message:String){NSApp.activate(ignoringOtherApps:true);let a=NSAlert();a.messageText="Screenshot Note";a.informativeText=message;a.runModal()}
func label(_ value:String,_ frame:NSRect)->NSTextField{let f=NSTextField(labelWithString:value);f.frame=frame;return f}
struct Shortcut:Codable {
 var key:UInt32;var modifiers:UInt32;var name:String
 func matches(_ event:NSEvent)->Bool {
  let flags=event.modifierFlags;var value:UInt32=0
  for (flag,carbon) in [(NSEvent.ModifierFlags.control,controlKey),(.option,optionKey),(.shift,shiftKey),(.command,cmdKey)] {if flags.contains(flag){value |= UInt32(carbon)}}
  return UInt32(event.keyCode)==key && value==modifiers
 }
 var display:String {
  var s="";if modifiers & UInt32(controlKey) != 0{s+="⌃"};if modifiers & UInt32(optionKey) != 0{s+="⌥"};if modifiers & UInt32(shiftKey) != 0{s+="⇧"};if modifiers & UInt32(cmdKey) != 0{s+="⌘"};return s+Self.keyName(key,fallback:name)
 }
 static func keyName(_ key:UInt32,fallback:String)->String {
  let functionKeys:[UInt32:Int]=[122:1,120:2,99:3,118:4,96:5,97:6,98:7,100:8,101:9,109:10,103:11,111:12,105:13,107:14,113:15,106:16,64:17,79:18,80:19,90:20]
  if let f=functionKeys[key]{return "F\(f)"}
  let special:[UInt32:String]=[36:"↩",48:"⇥",49:L("Mezerník"),51:"⌫",53:"Esc",76:"⌤",114:"Help",115:"Home",116:"Page Up",117:"⌦",119:"End",121:"Page Down",123:"←",124:"→",125:"↓",126:"↑"]
  return special[key] ?? fallback
 }
 static func load(_ id:Int)->Shortcut {
  if let d=UserDefaults.standard.data(forKey:"shortcut\(id)"),let s=try? JSONDecoder().decode(Shortcut.self,from:d){return s}
  return Shortcut(key:id == 1 ? 21:20,modifiers:UInt32(controlKey|optionKey|shiftKey),name:id == 1 ? "4":"3")
 }
}
final class Hotkeys {
 var refs:[EventHotKeyRef]=[];var handler:EventHandlerRef?;var callback:((Int)->Void)?
 private var monitor:Any?;private var registered=Set<Int>();private var lastTrigger:(Int,TimeInterval)?
 @discardableResult func trigger(_ id:Int,at time:TimeInterval=ProcessInfo.processInfo.systemUptime)->Bool {
  if let last=lastTrigger,last.0==id,time-last.1<0.2{return false}
  lastTrigger=(id,time);callback?(id);return true
 }
 init(){var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
  InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
   guard let context=context else{return OSStatus(eventNotHandledErr)}
   var id=EventHotKeyID();GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
   Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue().trigger(Int(id.id));return noErr
  },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
 }
 func register()->[String]{for r in refs{UnregisterEventHotKey(r)};refs=[];registered=[];if let monitor{NSEvent.removeMonitor(monitor);self.monitor=nil};var errors:[String]=[]
  for id in 1...2 {let s=Shortcut.load(id);var ref:EventHotKeyRef?;let status=RegisterEventHotKey(s.key,s.modifiers,EventHotKeyID(signature:0x53434E54,id:UInt32(id)),GetApplicationEventTarget(),0,&ref)
   if status == noErr,let ref=ref {refs.append(ref);registered.insert(id)} else {errors.append(LF("Zkratka %@ je již obsazená. Změň ji v nastavení.",s.display))}
  }
  monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
   guard let self,NSApp.keyWindow is ScreenshotPanel else{return event}
   if let button=NSApp.keyWindow?.firstResponder as? ShortcutButton,button.recording{return event}
   guard let id=(1...2).first(where:{self.registered.contains($0) && Shortcut.load($0).matches(event)}) else{return event}
   if !event.isARepeat{self.trigger(id)}
   return nil
  }
  return errors
 }
 deinit{if let monitor{NSEvent.removeMonitor(monitor)};for r in refs{UnregisterEventHotKey(r)};if let h=handler{RemoveEventHandler(h)}}
}
final class ShortcutButton:AppButton {
 var shortcut:Shortcut!;var onChange:((Shortcut)->Bool)?;var recording=false
 override var acceptsFirstResponder:Bool{true}
 override func mouseDown(with event:NSEvent){recording=true;role = .primary;title=L("Stiskni kombinaci…");window?.makeFirstResponder(self)}
 override func performKeyEquivalent(with event:NSEvent)->Bool{if recording{keyDown(with:event);return true};return super.performKeyEquivalent(with:event)}
 override func keyDown(with event:NSEvent){
  guard recording else {super.keyDown(with:event);return}
  if event.keyCode == 53 {recording=false;role = .secondary;title=shortcut.display;return}
  let flags=event.modifierFlags.intersection(.deviceIndependentFlagsMask)
  guard !flags.intersection([.command,.control,.option]).isEmpty else {title=L("Použij ⌘, ⌃ nebo ⌥");return}
  var mods:UInt32=0
  if flags.contains(.command){mods|=UInt32(cmdKey)};if flags.contains(.control){mods|=UInt32(controlKey)};if flags.contains(.option){mods|=UInt32(optionKey)};if flags.contains(.shift){mods|=UInt32(shiftKey)}
  let candidate=Shortcut(key:UInt32(event.keyCode),modifiers:mods,name:Shortcut.keyName(UInt32(event.keyCode),fallback:event.charactersIgnoringModifiers?.uppercased() ?? "\(event.keyCode)"))
  if onChange?(candidate) == true{shortcut=candidate}
  recording=false;role = .secondary;title=shortcut.display
 }
}
final class ShortcutSettings:NSObject,NSWindowDelegate {
 var window:NSWindow!;let hotkeys:Hotkeys
 init(hotkeys:Hotkeys){self.hotkeys=hotkeys}
 func show(){
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:620,height:340),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Klávesové zkratky");window.delegate=self
  let view=installDesignRoot(window,showClose:false)
  view.addSubview(designLabel(L("Klávesové zkratky"),NSRect(x:28,y:276,width:560,height:34),size:24,weight:.semibold))
  view.addSubview(designLabel(L("Klikněte na kombinaci a stiskněte novou."),NSRect(x:28,y:248,width:560,height:22),size:12,color:AppPalette.secondary))
  for id in 1...2 {
   let y=CGFloat(id == 1 ? 174:102)
   view.addSubview(designLabel(id == 1 ? L("Vybraná oblast"):L("Celá hlavní obrazovka"),NSRect(x:28,y:y+12,width:290,height:23),size:14,weight:.medium))
   let button=ShortcutButton(frame:NSRect(x:342,y:y+4,width:250,height:38));button.shortcut=Shortcut.load(id);button.title=button.shortcut.display;button.toolTip=L("Fn může na Macu vyvolat F-klávesu; například Fn + ⌘ + F11 se zobrazí jako ⌘F11.")
   button.onChange={[weak self] candidate in
    let other=Shortcut.load(id == 1 ? 2:1)
    guard candidate.key != other.key || candidate.modifiers != other.modifiers else {showError(L("Tato kombinace už patří druhému screenshotu."));return false}
    let old=Shortcut.load(id);UserDefaults.standard.set(try? JSONEncoder().encode(candidate),forKey:"shortcut\(id)")
    if let errors=self?.hotkeys.register(),!errors.isEmpty {UserDefaults.standard.set(try? JSONEncoder().encode(old),forKey:"shortcut\(id)");_ = self?.hotkeys.register();showError(errors.joined(separator:"\n"));return false};return true
   };view.addSubview(button)
   if id==1{view.addSubview(DesignDivider(NSRect(x:28,y:158,width:564,height:1)))}
  }
  view.addSubview(designLabel(L("Escape zruší zadávání nové kombinace."),NSRect(x:28,y:28,width:390,height:22),size:11,color:AppPalette.secondary))
  let done=styledButton(L("Hotovo"),role:.primary,frame:NSRect(x:482,y:22,width:110,height:34),target:self,action:#selector(close));done.keyEquivalent="\r";view.addSubview(done)
  presentScreenshotPanel(window)
  if isExportingDesign{exportDesignWindow(window,name:"shortcuts");return}
  NSApp.runModal(for:window);window.orderOut(nil)
 }
 @objc func close(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{close();return false}
}
final class SettingsController:NSObject {
 var window:NSWindow!;let login=NSSwitch()
 var hotkeys:Hotkeys
 let topicSettings=TopicSettings()
 init(hotkeys:Hotkeys){self.hotkeys=hotkeys}
 func show(){if let w=window{presentScreenshotPanel(w);return}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:660,height:430),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Nastavení");window.isReleasedWhenClosed=false
  let view=installDesignRoot(window,headerHeight:112)
  if let icon=NSImage(contentsOfFile:Bundle.main.path(forResource:"AppIcon",ofType:"icns") ?? ""){let logo=NSImageView(frame:NSRect(x:28,y:346,width:46,height:46));logo.image=icon;view.addSubview(logo)}
  view.addSubview(designLabel("Screenshot Note",NSRect(x:88,y:366,width:500,height:31),size:24,weight:.semibold))
  view.addSubview(designLabel(L("Nastavení")+" · "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "4.1"),NSRect(x:88,y:342,width:500,height:22),size:12,color:AppPalette.secondary))
  for (symbol,title,detail,y) in [("folder",L("Složky"),L("Složky a způsob ukládání poznámek."),CGFloat(252)),("keyboard",L("Klávesové zkratky"),L("Rychlý přístup ke snímání obrazovky."),CGFloat(170)),("power",L("Spuštění po přihlášení"),L("Ikona a zkratky budou připravené po startu."),CGFloat(88))]{
   let badge=DesignSurface(frame:NSRect(x:28,y:y+4,width:38,height:38),fill:AppPalette.accent.withAlphaComponent(0.1),radius:11);view.addSubview(badge);let image=NSImageView(frame:NSRect(x:9,y:9,width:20,height:20));image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);image.contentTintColor=AppPalette.accent;badge.addSubview(image)
   view.addSubview(designLabel(title,NSRect(x:78,y:y+24,width:325,height:23),size:14,weight:.medium))
   view.addSubview(designLabel(detail,NSRect(x:78,y:y+2,width:330,height:20),size:11,color:AppPalette.secondary))
  }
  let topics=styledButton(L("Spravovat…"),frame:NSRect(x:486,y:260,width:146,height:34),target:self,action:#selector(showTopics));view.addSubview(topics)
  let shortcuts=styledButton(L("Změnit klávesové zkratky…"),frame:NSRect(x:410,y:178,width:222,height:34),target:self,action:#selector(showShortcuts));view.addSubview(shortcuts)
  for y in [CGFloat(236),154]{view.addSubview(DesignDivider(NSRect(x:78,y:y,width:554,height:1)))}
  login.frame=NSRect(x:584,y:102,width:48,height:28);login.target=self;login.action=#selector(toggleLogin);login.state=SMAppService.mainApp.status == .enabled ? .on:.off;view.addSubview(login)
  view.addSubview(designLabel(L("Zavřením okna zůstane aplikace v systémové liště."),NSRect(x:28,y:24,width:440,height:22),size:11,color:AppPalette.secondary))
  let about=styledButton(L("O aplikaci"),symbol:"info.circle",role:.quiet,frame:NSRect(x:492,y:20,width:140,height:32),target:self,action:#selector(showAbout));view.addSubview(about)
  presentScreenshotPanel(window)
 }
 @objc func showAbout(){AboutController.shared.show()}
 @objc func showShortcuts(){let dialog=ShortcutSettings(hotkeys:hotkeys);dialog.show()}
 @objc func showTopics(){topicSettings.show()}
 @objc func toggleLogin(){do {if login.state == .on{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
   if SMAppService.mainApp.status == .requiresApproval{SMAppService.openSystemSettingsLoginItems()}
  }catch{showError(error.localizedDescription)}
  login.state=SMAppService.mainApp.status == .enabled ? .on:.off
 }
}
final class ThumbnailActionButton:AppButton {
 var expandedTitle=""
 var collapsedFrame=NSRect.zero
 var expandsLeft=false

 func setExpanded(_ expanded:Bool,animated:Bool){
  hovered=expanded
  title=expanded ? expandedTitle:""
  imagePosition=expanded ? .imageLeading:.imageOnly
  var target=collapsedFrame
  if expanded{
   let font=NSFont.systemFont(ofSize:13,weight:.medium)
   target.size.width=max(target.width,ceil((title as NSString).size(withAttributes:[.font:font]).width)+43)
   if expandsLeft{target.origin.x=collapsedFrame.maxX-target.width}
  }
  if animated{animateDesign{self.animator().frame=target}}else{frame=target}
  needsDisplay=true
 }
 override func mouseEntered(with event:NSEvent){setExpanded(true,animated:true)}
 override func mouseExited(with event:NSEvent){setExpanded(false,animated:true)}
 override func draw(_ dirtyRect:NSRect){
  super.draw(dirtyRect)
  if hovered{
   let outline=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8)
   AppPalette.accent.withAlphaComponent(0.12).setFill();outline.fill()
   AppPalette.accent.setStroke();outline.stroke()
  }
 }
}

final class ScreenshotThumbnailButton:NSButton {
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
  let space=NSRect(x:7,y:25,width:bounds.width-14,height:bounds.height-32)
  if let image=image{let factor=min(space.width/image.size.width,space.height/image.size.height);let size=NSSize(width:image.size.width*factor,height:image.size.height*factor);let r=NSRect(x:space.midX-size.width/2,y:space.midY-size.height/2,width:size.width,height:size.height);image.draw(in:r)}
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
 let thumbnails=NSView();let thumbnailScroll=NSScrollView();let topicLink=ContextLinkButton();let sessionLink=ContextLinkButton();let topicPicker=NSPopUpButton();let topicDescription=NSTextField(labelWithString:"")
 let laterButton=AppButton();let saveButton=AppButton();var availableTopics:[Topic]=[]
 let addShotButton=AppButton();let captureOptions=AppButton();let captureGroup=DesignSurface(frame:.zero,fill:AppPalette.raised,radius:8);var onCapture:((Bool)->Void)?
 private var screenTimer:Timer?
 private var pointerScreenFrame:NSRect?
 deinit{screenTimer?.invalidate()}
 var expandedContent:NSView?;var expandedFrame:NSRect?;var isCompact=false
 let imageCount=NSTextField(labelWithString:"")
 var childEditorOpen=false
 let sessionPicker=NSPopUpButton();var previousChoices:[PreviousSession]=[]
 var selectionText:[String:(String,String)]=[:]


 init(draft:Draft,root:URL){self.draft=draft;self.root=root;if self.draft.topic == nil{self.draft.topic=Topics.defaultTopic}}
 func show(present:Bool=true){
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:800,height:586),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title="";window.titleVisibility = .hidden;window.isReleasedWhenClosed=false;window.delegate=self
  let view=installDesignRoot(window,headerHeight:108,showClose:false)
  titleField.frame=NSRect(x:26,y:500,width:692,height:44);titleField.isBordered=false;titleField.drawsBackground=false;titleField.font = .systemFont(ofSize:27,weight:.semibold);titleField.textColor = .labelColor;titleField.placeholderString=L("Nadpis poznámky");titleField.stringValue=draft.title ?? "";view.addSubview(titleField)
  let collapse=styledButton("",symbol:"arrow.down.right.and.arrow.up.left",role:.quiet,frame:NSRect(x:736,y:506,width:36,height:34),target:self,action:#selector(toggleCompact));collapse.toolTip=L("Sbalit poznámku a prohlédnout si okno pod ní");view.addSubview(collapse)
  for (button,symbol,x,width,action) in [(topicLink,"folder",CGFloat(28),CGFloat(400),#selector(chooseConfiguration))]{
   button.role = .quiet;button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);button.imagePosition = .imageLeading;button.target=self;button.action=action;button.frame=NSRect(x:x,y:430,width:width,height:36);view.addSubview(button)
  }
  let add=addShotButton;add.title=L("Přidat výřez");add.image=NSImage(systemSymbolName:"plus.viewfinder",accessibilityDescription:nil);add.imagePosition = .imageLeading;add.target=self;add.action=#selector(addScreenshot)
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
  if let saved=draft.topic {if let i=availableTopics.firstIndex(where:{$0.id==saved.id}){availableTopics[i]=saved}else{availableTopics.append(saved)}}
  topicPicker.removeAllItems();topicPicker.addItems(withTitles:availableTopics.map{$0.name})
  if let i=availableTopics.firstIndex(where:{$0.id==draft.topic?.id}){topicPicker.selectItem(at:i)}
  changeTopic()
 }
 @objc func changeTopic(){
  let i=topicPicker.indexOfSelectedItem;guard availableTopics.indices.contains(i) else{return}
  guard draft.previous == nil || draft.topic?.id == availableTopics[i].id else{return}
  draft.topic=availableTopics[i];let topic=availableTopics[i];topicDescription.stringValue=topic.detail+(topic.detail.isEmpty ? "":" · ")+(topic.combined ? L("Jeden společný MD"):L("MD pro každou relaci"))
  topicLink.title=topic.name;topicLink.toolTip=topic.name+(topic.detail.isEmpty ? "":"\n"+topic.detail)
  refreshPreviousSessions()
 }
 @objc func refreshSavedSessions(){refreshPreviousSessions()}
 func refreshPreviousSessions(){
  do{let topic=draft.topic ?? Topics.defaultTopic;previousChoices=topic.savesLocally ? try previousSessions(in:topic.destination):[];sessionPicker.toolTip=L("Přidat k uložené relaci nebo vytvořit novou")}catch{previousChoices=[];sessionPicker.toolTip=error.localizedDescription}
  sessionPicker.removeAllItems();sessionPicker.addItem(withTitle:L("Nová relace"))
  sessionPicker.addItems(withTitles:previousChoices.map{$0.display})
  if let target=draft.previous,let index=previousChoices.firstIndex(where:{$0.target.id==target.id}){sessionPicker.selectItem(at:index+1)}else{sessionPicker.selectItem(at:0)}
  updatePreviousAvailability()
 }
 func updatePreviousAvailability(){sessionLink.title=draft.previous.flatMap{target in previousChoices.first{$0.target.id==target.id}?.title} ?? L("Nová relace");sessionLink.toolTip=sessionLink.title
  sessionLink.isEnabled=draft.topic?.savesLocally != false
  topicLink.isEnabled=draft.previous == nil;topicLink.needsDisplay=true
  topicLink.toolTip=draft.previous == nil ? draft.topic.map{$0.name+($0.detail.isEmpty ? "":"\n"+$0.detail)}:L("Konfiguraci uložené relace nelze změnit.")
  layoutContextRow()
 }
 func layoutContextRow(){
  let available=max(0,(topicLink.superview?.bounds.width ?? window?.contentView?.bounds.width ?? 800)-56)
  let cap=max(0,(available-32)/3)
  topicLink.frame=NSRect(x:28,y:430,width:topicLink.fittingWidth(maximum:cap),height:36)
  sessionLink.frame=NSRect(x:topicLink.frame.maxX+16,y:430,width:sessionLink.fittingWidth(maximum:cap),height:36)
  let trailing=28+available
  captureGroup.frame=NSRect(x:trailing-174,y:432,width:174,height:32)
  addShotButton.frame=NSRect(x:0,y:0,width:140,height:32)
  captureOptions.frame=NSRect(x:141,y:0,width:33,height:32)
 }
 @objc func chooseConfiguration(){
  guard draft.previous == nil else{return}
  childEditorOpen=true;defer{childEditorOpen=false};snapshotFields()
  let choices=Topics.all
  let picker=SessionChoiceDialog()
  if let index=picker.run(title:L("Vybrat konfiguraci"),choices:choices.map{SessionChoice(title:$0.name,detail:$0.detail+" · "+$0.folder)},current:choices.firstIndex{$0.id==draft.topic?.id} ?? 0){
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
  draft.previous=nil
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
  let fresh=draft.images;var notes=draft.imageNotes ?? [:];var reused=Set<String>()
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
   }
  }catch{for name in importedNames{removeAnnotatedImage(root.appendingPathComponent(name))};showError(error.localizedDescription);restorePreviousSelection();return}
  draft.images=importedNames+fresh;draft.imageNotes=notes;var target=chosen.target;target.imported=imported;draft.previous=target
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
   let annotated=fm.fileExists(atPath:annotationSidecar(root.appendingPathComponent(image)).path)
   let hasNote = !(draft.imageNotes?[image] ?? "").isEmpty
   let noteInHeader=annotated || hasNote
   let annotate=ThumbnailActionButton(title:"",target:self,action:#selector(edit))
   annotate.image=NSImage(systemSymbolName:"pencil.tip",accessibilityDescription:nil);annotate.imagePosition = .imageOnly
   annotate.expandedTitle=L(annotated ? "Upravit":"Anotovat");annotate.setAccessibilityLabel(annotate.expandedTitle)
   annotate.collapsedFrame=NSRect(x:noteInHeader ? 92:69,y:181,width:40,height:32)
   annotate.expandsLeft=true;annotate.frame=annotate.collapsedFrame;annotate.tag=i;button.addHoverAction(annotate)
   let note=ThumbnailActionButton(title:"",target:self,action:#selector(editImageNote))
   note.image=NSImage(systemSymbolName:hasNote ? "text.bubble.fill":"text.bubble",accessibilityDescription:nil);note.imagePosition = .imageOnly
   note.expandedTitle=L(hasNote ? "Upravit":"Poznámka");note.setAccessibilityLabel(L("Poznámka ke snímku"));note.tag=i
   note.collapsedFrame=noteInHeader ? NSRect(x:164,y:4,width:28,height:24):NSRect(x:115,y:181,width:40,height:32)
   note.expandsLeft=noteInHeader;note.frame=note.collapsedFrame
   if noteInHeader{button.addSubview(note)}else{button.addHoverAction(note)}
   let remove=styledButton("",symbol:"xmark",role:.quiet,frame:NSRect(x:CGFloat(i)*238+196,y:198,width:24,height:24),target:self,action:#selector(removeImage(_:)));remove.tag=i;remove.toolTip=L("Odebrat tento obrázek z relace");thumbnails.addSubview(remove)
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
 @discardableResult func appendCapturedImage(_ filename:String)->Bool{
  guard !draft.images.contains(filename),!filename.contains("/"),fm.fileExists(atPath:root.appendingPathComponent(filename).path) else{return false}
  draft.images.append(filename);reloadThumbnails();thumbnails.scroll(NSPoint(x:max(0,thumbnails.bounds.width-thumbnailScroll.contentSize.width),y:0));return true
 }
 @objc func removeImage(_ sender:NSButton){guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images.remove(at:sender.tag);draft.previous?.imported.removeValue(forKey:name);draft.imageNotes?.removeValue(forKey:name);removeAnnotatedImage(root.appendingPathComponent(name));reloadThumbnails()}
 @objc func expandComment(){childEditorOpen=true;defer{childEditorOpen=false};window.makeFirstResponder(nil);let editor=MarkdownEditor();if let value=editor.run(comment.markdownText){comment.markdownText=value};window.makeKeyAndOrderFront(nil)}
 @objc func edit(_ sender:NSButton){
  guard draft.images.indices.contains(sender.tag) else{return};let name=draft.images[sender.tag]
  childEditorOpen=true;defer{childEditorOpen=false};let editor=AnnotationEditor()
  if editor.run(url:root.appendingPathComponent(name)){reloadThumbnails()};window.makeKeyAndOrderFront(nil)
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
 @objc func cancel(){end(0)};@objc func later(){end(1)};@objc func save(){end(2)}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}

// Text commands are routed through the responder chain, including field editors
// and the Markdown editor's modal window.
func installEditingMenu() {
 let bar=NSMenu()
 let applicationItem=NSMenuItem();let applicationMenu=NSMenu()
 let about=NSMenuItem(title:L("O aplikaci Screenshot Note…"),action:#selector(AboutController.show),keyEquivalent:"");about.target=AboutController.shared;applicationMenu.addItem(about);applicationMenu.addItem(.separator())
 applicationMenu.addItem(withTitle:L("Ukončit Screenshot Note"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
 applicationItem.submenu=applicationMenu;bar.addItem(applicationItem)
 let item=NSMenuItem(title:L("Úpravy"),action:nil,keyEquivalent:"")
 let edit=NSMenu(title:L("Úpravy"))
 let commands:[(String,String,String,NSEvent.ModifierFlags)]=[
  (L("Zpět"),"undo:","z",.command),
  (L("Znovu"),"redo:","z",[.command,.shift]),
  (L("Vyjmout"),"cut:","x",.command),
  (L("Kopírovat"),"copy:","c",.command),
  (L("Vložit"),"paste:","v",.command),
  (L("Vybrat vše"),"selectAll:","a",.command)
 ]
 for (title,selector,key,modifiers) in commands {
  let entry=NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key)
  entry.keyEquivalentModifierMask=modifiers;entry.target=nil;edit.addItem(entry)
 }
 item.submenu=edit;bar.addItem(item);NSApp.mainMenu=bar
}
