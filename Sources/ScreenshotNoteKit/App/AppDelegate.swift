import AppKit
import Carbon
import CoreGraphics

final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuDelegate {
 var folderEntry:NSMenuItem?
 var parkedEntry:NSMenuItem?
 let cloudSettings=CloudSettings()
 var item:NSStatusItem!;let hotkeys=Hotkeys();var settings:SettingsController!;var composer:Composer?;var capturing=false;var browsingSavedSessions=false;var session:URL?
 private var folderTimer:Timer?;private var nextFolderRefresh=Date.distantPast
 let recording=RecordingController();var stopEntry:NSMenuItem?;var recordEntry:NSMenuItem?
 /// Okno prohlížeče v popředí při startu záznamu; kontext se po stopu žádá od něj.
 private var recordingBrowser:[String:Any]?
 func applicationDidFinishLaunching(_ notification:Notification){
  installEditingMenu()
  CloudFolders.shared.activate(CloudLibrary.shared.connection)
  CloudLibrary.shared.onEditConflict={id,fields in CloudFolders.shared.keepLocalEdit(id,fields)}
  // 401 při synchronizaci složek přepne Mac do stavu nového párování.
  CloudFolders.shared.onUnauthorized={token in CloudLibrary.shared.markRevoked(token:token)}
  SessionIndex.onWriteFailure={message in DispatchQueue.main.async{showError(message)}}
  // Záloha konceptu z minulého běhu (pád, vynucené ukončení) se vrátí jako rozpracovaná poznámka.
  do{if try restoreRecoveredDraft(){DispatchQueue.main.async{showError(L("Neuložená poznámka z minulého spuštění byla obnovena. Otevřeš ji v menu Otevřít rozpracovanou poznámku."))}}}catch{NSLog("Draft recovery failed: %@",error.localizedDescription)}
  TrashNotifier.shared.install()
  // Plné úložiště ohlásíme jednou za hodinu, ne při každém dalším pokusu.
  var quotaShown:(String,Date)?
  CloudLibrary.shared.onQuotaFailure={message in
   if let shown=quotaShown,shown.0==message,Date().timeIntervalSince(shown.1)<3600{return}
   quotaShown=(message,Date());DispatchQueue.main.async{showError(message)}
  }
  folderTimer=Timer.scheduledTimer(withTimeInterval:5,repeats:true){[weak self] _ in self?.refreshCloudFolders()}
  refreshCloudFolders()
  // Starší místní poznámky jednou přijdou o skryté značky.
  for topic in Topics.local where topic.savesLocally{migrateLegacyMarkers(in:topic.destination);migrateImageLinks(in:topic.destination)}
  NativeHostRegistration.applyStoredSetting()
  settings=SettingsController(hotkeys:hotkeys)
  item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);item.button?.image=NSImage(systemSymbolName:"camera.viewfinder",accessibilityDescription:"Screenshot Note")
  let menu=NSMenu();menu.delegate=self
  for (title,symbol,action) in [
   (L("Vyfotit oblast"),"viewfinder",#selector(area)),
   (L("Vyfotit celou obrazovku"),"display",#selector(full)),
   (L("Otevřít rozpracovanou poznámku"),"square.and.pencil",#selector(resume)),
   (L("Otevřít složku screenshotů"),"folder",#selector(openFolder)),
   (L("Cloudová knihovna…"),"icloud",#selector(openCloudSettings)),
   (L("Nastavení…"),"gearshape",#selector(preferences)),
   (L("O aplikaci Screenshot Note…"),"info.circle",#selector(aboutApp)),
   (L("Ukončit"),"power",#selector(quit))
  ] {
   if symbol=="gearshape"{menu.addItem(.separator())}
   let entry=NSMenuItem(title:title,action:action,keyEquivalent:"");entry.target=self
   let icon=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:16,weight:.regular))
   icon?.size=NSSize(width:18,height:18);icon?.isTemplate=true;entry.image=icon
   if symbol=="folder"{folderEntry=entry}
   if symbol=="square.and.pencil"{addRecordingItems(to:menu)}
   menu.addItem(entry)
   if symbol=="icloud" {
    // Odložené položky fronty jsou vidět i bez otevřeného okna cloudu.
    let parked=NSMenuItem(title:L("Odložené cloudové položky…"),action:#selector(openParked),keyEquivalent:"");parked.target=self
    let mark=NSImage(systemSymbolName:"exclamationmark.icloud",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:16,weight:.regular))
    mark?.size=NSSize(width:18,height:18);mark?.isTemplate=true;parked.image=mark;parkedEntry=parked;menu.addItem(parked)
   }
  }
  updateFolderMenu();item.menu=menu;hotkeys.callback={[weak self] id in if id == 3{self?.toggleRecording()}else{self?.capture(full:id == 2)}}
  recording.onChange={[weak self] in self?.updateRecordingState()}
  recording.onFinish={[weak self] result in self?.recordingFinished(result)}
  let errors=CommandLine.arguments.contains("--preview-test") ? [] : hotkeys.register();if !errors.isEmpty{DispatchQueue.main.async{showError(errors.joined(separator:"\n"))}}
  DistributedNotificationCenter.default().addObserver(self,selector:#selector(external(_:)),name:NSNotification.Name("cz.janprasil.screenshotnote.capture"),object:nil)
  if CommandLine.arguments.contains("--preview-test"){previewTest()}
  else if CommandLine.arguments.contains("--capture"){DispatchQueue.main.asyncAfter(deadline:.now()+0.3){self.capture(full:CommandLine.arguments.contains("--fullscreen"))}}
 }
 @objc func external(_ notification:Notification){capture(full:notification.object as? String == "full")}
 func refreshCloudFolders(){
  CloudFolders.shared.activate(CloudLibrary.shared.connection)
  guard Date()>=nextFolderRefresh,!CloudFolders.shared.syncing else{return};nextFolderRefresh=Date().addingTimeInterval(60)
  Task{@MainActor in
   let library=CloudLibrary.shared
   // Aktivní připojení se občas ověří; odvolané nebo vypršelé přejde do stavu nového párování.
   if library.connection?.ownerID != nil,!library.needsRepair{try? await library.refreshConnection()}
   if library.needsRepair{return}
   if library.pendingCount>0{await library.sync()}
   await FolderTransfers.shared.resume()
   // Po chybě složky počkají na Retry-After nebo rostoucí odstup.
   if Date()>=CloudFolders.shared.retryAt{await CloudFolders.shared.refresh(library.connection)}
   await TemplateDefaults.shared.refresh()
   if NSApp.modalWindow==nil{await FolderDialogs.resolveHeld()}
   if NSApp.modalWindow==nil{await FolderDialogs.confirmDeletes()}
   if self.composer==nil,NSApp.modalWindow==nil{FolderDialogs.resolveDeleted()}
   if self.composer==nil,NSApp.modalWindow==nil,CloudFolders.shared.lastError==nil{await FolderDialogs.offerRepair()}
   if self.composer==nil,NSApp.modalWindow==nil,CloudFolders.shared.lastError==nil{await FolderDialogs.mapUnmapped()}
   if self.composer==nil,NSApp.modalWindow==nil,CloudFolders.shared.lastError==nil,let c=CloudLibrary.shared.connection,let owner=c.ownerID,!Topics.local.isEmpty {
    let key="folder-transfer-offer:"+sessionFingerprint(Data((c.endpoint+owner.uuidString).utf8))
    if !UserDefaults.standard.bool(forKey:key) {
     let alert=NSAlert();alert.messageText=L("Přesunout lokální složky do cloudu?");alert.informativeText=L("Můžeš přesunout všechny lokální složky tohoto Macu. U shodných názvů vybereš sloučení nebo přejmenování. Místní soubory zůstanou zachované.");alert.addButton(withTitle:L("Přesunout všechny"));alert.addButton(withTitle:L("Teď ne"))
     let choice=alert.runModal();UserDefaults.standard.set(true,forKey:key)
     if choice == .alertFirstButtonReturn{await FolderDialogs.move(Topics.local)}
    }
   }
  }
 }
 @objc func area(){capture(full:false)};@objc func full(){capture(full:true)}
 /// Menu bar: Zastavit záznam (jen během záznamu) a podmenu Nahrát video s cílem a odpočtem.
 func addRecordingItems(to menu:NSMenu) {
  func icon(_ symbol:String)->NSImage?{let image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:16,weight:.regular));image?.size=NSSize(width:18,height:18);image?.isTemplate=true;return image}
  let stop=NSMenuItem(title:L("Zastavit záznam"),action:#selector(stopRecording),keyEquivalent:"");stop.target=self;stop.image=icon("stop.circle");stop.isHidden=true
  menu.insertItem(stop,at:0);stopEntry=stop
  let entry=NSMenuItem(title:L("Nahrát video"),action:nil,keyEquivalent:"");entry.image=icon("record.circle")
  let sub=NSMenu()
  for (title,target) in [(L("Celá obrazovka"),RecordingTarget.screen),(L("Okno v popředí"),.window),(L("Vybraná oblast…"),.region)] {
   let item=NSMenuItem(title:title,action:#selector(recordFromMenu(_:)),keyEquivalent:"");item.target=self;item.representedObject=target.rawValue;sub.addItem(item)
  }
  sub.addItem(.separator())
  for seconds in RecordingLimits.countdowns {
   let item=NSMenuItem(title:LF("Odpočet %d s",seconds),action:#selector(chooseCountdown(_:)),keyEquivalent:"");item.target=self;item.tag=seconds;sub.addItem(item)
  }
  entry.submenu=sub;menu.addItem(entry);recordEntry=entry
 }
 @objc func recordFromMenu(_ sender:NSMenuItem){startRecording(RecordingTarget(rawValue:sender.representedObject as? String ?? "") ?? .screen)}
 @objc func chooseCountdown(_ sender:NSMenuItem){recordingCountdown=sender.tag}
 @objc func stopRecording(){recording.stop()}
 /// Zkratka záznamu: spustí naposledy použitý cíl, během záznamu nebo odpočtu ho zastaví.
 func toggleRecording(){if recording.state != .idle{recording.stop()}else{startRecording(RecordingTarget(rawValue:UserDefaults.standard.string(forKey:"recordingTarget") ?? "") ?? .screen)}}
 func startRecording(_ target:RecordingTarget) {
  guard !capturing,!browsingSavedSessions,recording.state == .idle else{return}
  UserDefaults.standard.set(target.rawValue,forKey:"recordingTarget")
  composer?.collapseCompact()
  recordingBrowser=browserCaptureTarget()
  recording.start(target,output:fm.temporaryDirectory.appendingPathComponent("ScreenshotNote-\(UUID().uuidString).mp4"))
 }
 func updateRecordingState() {
  let active=recording.state != .idle
  stopEntry?.isHidden = !active;recordEntry?.isEnabled = !active
  if recording.state == .recording{let seconds=Int(recording.elapsed);stopEntry?.title=LF("Zastavit záznam (%@)",videoDuration(seconds*1000))}
  else{stopEntry?.title=L("Zastavit záznam")}
  let symbol=recording.state == .recording ? "record.circle.fill":active ? "timer":"camera.viewfinder"
  item.button?.image=NSImage(systemSymbolName:symbol,accessibilityDescription:"Screenshot Note")
  item.button?.contentTintColor=recording.state == .recording ? .systemRed:nil
 }
 /// Hotový záznam: poster jako obrázek položky, video a snímky vedle něj, kontext prohlížeče za celou dobu.
 func recordingFinished(_ result:Result<RecordingResult,Error>?) {
  let active=composer
  guard let result else{active?.expandCompact();return}
  let recorded:RecordingResult
  switch result{case .failure(let error):active?.expandCompact();showError(error.localizedDescription);return;case .success(let value):recorded=value}
  do {
   var draft:Draft;let root:URL
   if let active{active.snapshotFields();draft=active.draft;root=active.root}else{let copy=try workingCopy();draft=copy.0;root=copy.1}
   let poster=root.appendingPathComponent(UUID().uuidString+".png")
   do{try storeRecording(recorded,poster:poster)}catch{try? fm.removeItem(at:recorded.video);if active == nil{try? fm.removeItem(at:root)};throw error}
   let folder=draft.topic.flatMap{saved in Topics.all.first{$0.id==saved.id}}
   let window=recorded.durationMs+(recordingCountdown+5)*1000
   let browser=recordingBrowser;recordingBrowser=nil
   let context=PendingCaptureContext.start(topic:folder,windowMs:window,target:{browser})
   let deliver={(files:CaptureContextFiles?) in
    let attached=files.map{(try? $0.write(besides:poster)) != nil} ?? false
    if let active {
     guard active.appendCapturedImage(poster.lastPathComponent,context:attached) else{removeAnnotatedImage(poster);active.expandCompact();return}
     active.snapshotFields();self.autosave(active.draft,root:root);active.expandCompact();active.window.makeKeyAndOrderFront(nil)
    }else{let before=draft;draft.images.append(poster.lastPathComponent);if attached{draft.contexts=(draft.contexts ?? [:]).merging([poster.lastPathComponent:poster.lastPathComponent+".context.json"]){$1}};self.autosave(draft,root:root);self.present(draft,root:root,baseline:before)}
   }
   if let context{context.wait(upTo:1,deliver)}else{deliver(nil)}
  }catch{active?.expandCompact();showError(error.localizedDescription)}
 }
 @objc func openCloudSettings(){cloudSettings.show()}
 @objc func openParked(){Task{@MainActor in FolderDialogs.resolveParked()}}
 @objc func preferences(){settings.show()}
 @objc func aboutApp(){AboutController.shared.show()}
 func menuNeedsUpdate(_ menu:NSMenu){if menu === item?.menu{updateFolderMenu();parkedEntry?.isHidden=CloudLibrary.shared.parkedItems.isEmpty}}
 /// Ukončení aplikace (i odhlášení systému) odloží otevřenou poznámku jako rozpracovanou.
 func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
  guard let composer,let root=session else{return .terminateNow}
  composer.snapshotFields()
  if composer.hasUnsavedWork?() ?? true {
   do{try persist(composer.draft,root:root)}
   catch {
    let alert=NSAlert();alert.messageText=L("Rozpracovanou poznámku nejde uložit.");alert.informativeText=error.localizedDescription+"\n\n"+L("Po ukončení zůstane jen automatická záloha posledního snímku.")
    alert.addButton(withTitle:L("Zpět k poznámce"));alert.addButton(withTitle:L("Přesto ukončit"))
    if alert.runModal() == .alertFirstButtonReturn{composer.reveal();return .terminateCancel}
    return .terminateNow
   }
  }
  try? fm.removeItem(at:recoveryRoot);try? fm.removeItem(at:root);return .terminateNow
 }
 /// Po každém snímku se koncept zálohuje mimo dočasný adresář; po pádu se při spuštění obnoví.
 func autosave(_ draft:Draft,root:URL) {
  do{try persist(draft,root:root,to:recoveryRoot)}
  catch {
   // Poškozená předchozí záloha se nahradí novou.
   try? fm.removeItem(at:recoveryRoot)
   do{try persist(draft,root:root,to:recoveryRoot)}catch{NSLog("Draft autosave failed: %@",error.localizedDescription)}
  }
 }
 /// Záloha z minulého běhu se přesune do rozpracované poznámky; vrací true, když něco obnovila.
 @discardableResult func restoreRecoveredDraft(from recovery:URL=recoveryRoot,to storage:URL=draftRoot)throws->Bool {
  let backup=recovery.appendingPathComponent("draft.json")
  guard fm.fileExists(atPath:backup.path) else{return false}
  // Novější uložený koncept má přednost; starší záloha by ho přepsala.
  func modified(_ url:URL)->Date{(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast}
  let saved=storage.appendingPathComponent("draft.json")
  if fm.fileExists(atPath:saved.path),modified(saved)>=modified(backup){try? fm.removeItem(at:recovery);return false}
  let draft=try readDraft(recovery)
  guard !draft.images.isEmpty || !draft.comment.isEmpty || !(draft.title ?? "").isEmpty else{try? fm.removeItem(at:recovery);return false}
  try persist(draft,root:recovery,to:storage);try fm.removeItem(at:recovery);return true
 }
 func updateFolderMenu(){
  guard let entry=folderEntry else{return}
  let configurations=Topics.all.filter(\.savesLocally)
  if configurations.count<=1{
   guard let configuration=configurations.first else{entry.submenu=nil;entry.action=nil;entry.representedObject=nil;return}
   entry.submenu=nil;entry.action=#selector(openFolder);entry.target=self;entry.representedObject=configuration.folder
  }else{
   let submenu=NSMenu(title:L("Konfigurace"));submenu.autoenablesItems=false
   for configuration in configurations{
    let child=NSMenuItem(title:configuration.displayName,action:#selector(openConfigurationFolder(_:)),keyEquivalent:"");child.target=self;child.representedObject=configuration.folder;child.toolTip=configuration.folder
    child.image=NSImage(systemSymbolName:"folder",accessibilityDescription:nil);child.image?.isTemplate=true
    submenu.addItem(child)
   }
   entry.action=nil;entry.representedObject=nil;entry.submenu=submenu
  }
 }
 @objc func openFolder(){if let path=folderEntry?.representedObject as? String{openFolderPath(path)}}
 @objc func openConfigurationFolder(_ sender:NSMenuItem){guard let path=sender.representedObject as? String else{return};openFolderPath(path)}
 func openFolderPath(_ path:String){
  let folder=URL(fileURLWithPath:path,isDirectory:true)
  do{try fm.createDirectory(at:folder,withIntermediateDirectories:true);if !NSWorkspace.shared.open(folder){showError(L("Složku se nepodařilo otevřít: ")+path)}}catch{showError(error.localizedDescription)}
 }

 @objc func quit(){if composer != nil || capturing || recording.state != .idle{showError(L("Nejprve ulož nebo zavři rozpracované okno."));return};NSApp.terminate(nil)}
 func workingCopy() throws -> (Draft,URL){
  var draft=try readDraft(draftRoot)
  // Rozpracovaná relace navázaná na smazanou nebo přesunutou uloženou relaci.
  switch resolveDraftTarget(draft) {
  case .current(let resolved):if resolved.previous != draft.previous || resolved.topic != draft.topic{draft=resolved;try stage(draft,root:draftRoot)}
  case .stale(let title):
   NSApp.activate(ignoringOtherApps:true)
   let alert=NSAlert();alert.messageText=LF("Rozpracovaná relace „%@“ už neexistuje (byla smazána). Co s rozpracovanými změnami?",title)
   alert.addButton(withTitle:L("Uložit jako novou relaci"));alert.addButton(withTitle:L("Zahodit"))
   draft=try applyStaleChoice(draft,keep:alert.runModal() == .alertFirstButtonReturn,root:draftRoot)
  }
  // Složka týmu, ke kterému už přístup není, se vymění za výchozí.
  if let fallback=fallbackFromHiddenFolder(draft){draft=fallback;try stage(draft,root:draftRoot)}
  if draft.topic == nil {draft.topic=Topics.initialTopic}
  let root=fm.temporaryDirectory.appendingPathComponent("ScreenshotNote-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  do {for image in draft.images {try fm.copyItem(at:draftRoot.appendingPathComponent(image),to:root.appendingPathComponent(image));try copyAnnotationSidecar(from:draftRoot.appendingPathComponent(image),to:root.appendingPathComponent(image))}}catch{try? fm.removeItem(at:root);throw error}
  session=root;return(draft,root)
 }
 @objc func resume(){
  if let composer=composer{composer.reveal();return};guard !capturing else{return}
  do{
   let(draft,root)=try workingCopy()
   if !draft.images.isEmpty || !draft.comment.isEmpty || !(draft.title ?? "").isEmpty{present(draft,root:root);return}
   do{
    if let chosen=try chooseSavedSession(root:root){present(chosen,root:root)}else{try? fm.removeItem(at:root);session=nil}
   }catch{try? fm.removeItem(at:root);session=nil;throw error}
  }catch{showError(error.localizedDescription)}
 }
 func chooseSavedSession(root:URL)throws->Draft?{
  browsingSavedSessions=true;defer{browsingSavedSessions=false}
  var saved:[(Topic,PreviousSession)]=[]
  for configuration in Topics.all where configuration.savesLocally{saved += try previousSessions(for:configuration).map{(configuration,$0)}}
  saved.sort{$0.1.modified>$1.1.modified}
  var rows=[SessionChoice(title:L("Nová relace"),detail:L("Vytvořit novou poznámku."))]
  rows += saved.map{configuration,session in
   let assets=URL(fileURLWithPath:session.target.path).deletingLastPathComponent().appendingPathComponent("assets")
   return SessionChoice(title:session.title,detail:configuration.displayName+" · "+session.display+(session.comment.isEmpty ? "":" · "+session.comment),images:session.images.map{assets.appendingPathComponent($0)})
  }
  guard let index=SessionChoiceDialog().run(title:L("Vybrat relaci"),choices:rows) else{return nil}
  if index==0{return Draft(images:[],comment:"",topic:Topics.initialTopic)}
  return try workingDraft(from:saved[index-1].1,topic:saved[index-1].0,root:root)
 }

 func capture(full:Bool,fromComposer:Bool=false){
  let active=composer
  let fromOpenComposer = fromComposer || active != nil
  func restoreComposerSize(){if fromOpenComposer{active?.expandCompact()}}
  // Během záznamu (i jeho dokončení) se snímek nepořizuje, oba by doručily vlastní koncept.
  guard !capturing && !browsingSavedSessions && recording.state == .idle else{return}
  active?.collapseCompact()
  if !CGPreflightScreenCaptureAccess(){restoreComposerSize();_ = CGRequestScreenCaptureAccess();showError(L("Povol Screenshot Note v Nastavení systému → Soukromí a zabezpečení → Záznam obrazovky a spusť snímání znovu."));NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!);return}
  let screens=NSScreen.screens
  let pointerDisplay=screens.firstIndex{$0.frame.contains(NSEvent.mouseLocation)}
  capturePresentationScreen=pointerDisplay.map{screens[$0]} ?? NSScreen.main
  var hiddenWindows:[NSWindow]=[]
  func restoreWindows(){for window in hiddenWindows.reversed(){window.orderFront(nil)}}
  do {
   var draft:Draft;let root:URL
   if let active=active {active.snapshotFields();draft=active.draft;root=active.root}
   else {let copy=try workingCopy();draft=copy.0;root=copy.1}
   let file=root.appendingPathComponent(UUID().uuidString+".png")
   let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
   let display=full ? DisplayCaptureTarget.current(main:!fromOpenComposer):nil
   process.arguments=["-x"]+(display?.arguments ?? ["-i"])+[file.path]
   // Kontext z prohlížeče v popředí se žádá souběžně se snímkem; bez rozšíření je nil hned.
   var browser:BrowserWindow?
   let folder=draft.topic.flatMap{saved in Topics.all.first{$0.id==saved.id}}
   let context=PendingCaptureContext.start(topic:folder,target:{browser=browserCaptureWindow();return browser?.target})
   // Výřez je známý jen u celoobrazovkového snímku se zapnutou mapou; výběr oblasti mapu elementů nemá.
   let window=display != nil && context != nil && folder?.effectiveContextPolicy?.includeElements==true ? browser?.bounds:nil
   let probe=window.flatMap{bounds in browser.flatMap{WebAreaProbe(pid:$0.pid,window:bounds)}}
   capturing=true
   hiddenWindows=NSApp.orderedWindows.filter{$0.isVisible}
   for window in hiddenWindows {window.orderOut(nil)}
   process.terminationHandler={p in DispatchQueue.main.async{
    guard fm.fileExists(atPath:file.path) else{
     self.capturing=false
     if active == nil {try? fm.removeItem(at:root)}
     restoreWindows();restoreComposerSize()
     if full && p.terminationStatus != 0{showError(L("Screenshot se nepodařilo pořídit. Zkontroluj oprávnění pro záznam obrazovky."))}
     return
    }
    // Na kontext se po snímku čeká nejvýš 1 s, pak se pokračuje bez něj.
    let deliver={(files:CaptureContextFiles?) in
    self.capturing=false
    let geometry=files == nil || window == nil ? nil:display?.geometry(image:file,window:window,webAreas:probe?.result ?? [])
    let attached=files.map{(try? $0.attaching(geometry).write(besides:file)) != nil} ?? false
    if attached,geometry != nil,ElementDebug.enabled{DispatchQueue.global(qos:.utility).async{if let debug=ElementDebug.render(image:file,elements:mapElements(contextFile:contextSidecars(file)[0])){NSLog("Browser bridge element map: %@",debug.path)}}}
    if let active=active {
     guard active.appendCapturedImage(file.lastPathComponent,context:attached) else{removeAnnotatedImage(file);restoreWindows();restoreComposerSize();return}
     active.snapshotFields();self.autosave(active.draft,root:root)
     // Keep an open annotation/Markdown editor in front. Otherwise show the new thumbnail.
     if !active.childEditorOpen {active.expandCompact()}
     restoreWindows()
     if !active.childEditorOpen {active.window.makeKeyAndOrderFront(nil)}
    }else{restoreWindows();let before=draft;draft.images.append(file.lastPathComponent);if attached{draft.contexts=(draft.contexts ?? [:]).merging([file.lastPathComponent:file.lastPathComponent+".context.json"]){$1}};self.autosave(draft,root:root);self.present(draft,root:root,baseline:before)}
    }
    if let context{context.wait(upTo:1,deliver)}else{deliver(nil)}
   }}
   // Give WindowServer a frame to remove our panels before taking the screenshot.
   DispatchQueue.main.asyncAfter(deadline:.now()+0.15){
    do {try process.run()}catch{
     self.capturing=false;restoreWindows();restoreComposerSize();if active == nil{try? fm.removeItem(at:root)};showError(error.localizedDescription)
    }
   }
  }catch{capturing=false;restoreWindows();restoreComposerSize();showError(error.localizedDescription)}
 }
 func persist(_ draft:Draft,root:URL,to storage:URL=draftRoot)throws{
  try fm.createDirectory(at:storage,withIntermediateDirectories:true)
  let old=try readDraft(storage);var replacement=draft;replacement.images=[];replacement.previous?.imported=[:];replacement.imageNotes=[:];replacement.contexts=draft.contexts.map{_ in [:]};var created:[URL]=[]
  do {for image in draft.images{let name=UUID().uuidString+".png";let target=storage.appendingPathComponent(name);try fm.copyItem(at:root.appendingPathComponent(image),to:target);created.append(target);try copyAnnotationSidecar(from:root.appendingPathComponent(image),to:target);replacement.images.append(name);replacement.imageNotes?[name]=draft.imageNotes?[image];if draft.contexts?[image] != nil{replacement.contexts?[name]=name+".context.json"};if let original=draft.previous?.imported[image]{replacement.previous?.imported[name]=original}};try stage(replacement,root:storage)}catch{for url in created{removeAnnotatedImage(url)};throw error}
  for name in old.images{removeAnnotatedImage(storage.appendingPathComponent(name))}
 }
 func present(_ draft:Draft,root:URL,baseline:Draft?=nil){
  let view=Composer(draft:draft,root:root);composer=view
  // Zrušit se ptá jen tehdy, když se obsah liší od stavu, ze kterého okno vzniklo.
  let pristine=draftSignature(baseline ?? draft,root:root)
  view.hasUnsavedWork={[weak view] in view.map{draftSignature($0.draft,root:root) != pristine} ?? false}
  view.onCapture={[weak self] full in self?.capture(full:full,fromComposer:true)}
  view.complete={[weak self, weak view] result,draft in
   guard let self,let view else{return}
   let upload = result == 2 && draft.topic?.savesToCloud == true
   let cloudFolder = draft.topic?.cloudFolderID != nil
   // Cloudová složka se zapisuje jen přes stahování, i při doplnění uložené relace.
   let cloudOnly = upload && (cloudFolder || (draft.topic?.savesLocally == false && draft.previous == nil))
   do {
    if upload { try CloudLibrary.shared.requireAccount() }
    if result != 0 {
     try self.persist(draft,root:root)
     // Uložený koncept je novější než záloha; ta by ho po pádu přepsala.
     try? fm.removeItem(at:recoveryRoot)
     if result == 2 {
      let stored=try readDraft(draftRoot)
      if cloudOnly {
       if cloudFolder,let previous=stored.previous,let topic=stored.topic {
        guard let (id,shas)=CloudFolders.shared.serverImages(for:previous,topic:topic) else{throw CloudFailure(L("Relaci zatím nejde doplnit, protože její cloudová kopie není stažená. Zkus to po synchronizaci."))}
        // Cizí relace v týmové složce: text zůstane jen v místním souboru, snímky přidat nejde.
        if !CloudFolders.shared.mayChange(id,topic:topic) {
         guard stored.images.count==shas.count else{throw CloudFailure(L("Do cizí relace v týmové složce smí snímky přidat jen autor nebo správce. Ulož je jako novou relaci."))}
         CloudFolders.shared.keepLocalEdit(id,CloudLibrary.editFields(stored))
         CloudFolders.shared.notify(L("Úprava cizí relace v týmové složce zůstala jen v místním souboru."))
        } else if stored.images.count==shas.count {
         // Bez nových snímků jde jen o úpravu textu (PATCH s revizí).
         guard let (original,revision)=CloudFolders.shared.editBase(id,topic:topic) else{throw CloudFailure(L("Relaci zatím nejde doplnit, protože její cloudová kopie není stažená. Zkus to po synchronizaci."))}
         try CloudLibrary.shared.enqueueEdit(stored,root:draftRoot,sessionID:id,base:shas,original:original,revision:revision,draftBase:stored.cloudBase)
        } else {
         // Doplnění posílá aktuální šablonu složky, server ji zapíše z manifestu.
         var current=stored;if let folder=CloudFolders.shared.topics.first(where:{$0.cloudFolderID==topic.cloudFolderID}){current.topic?.markdownTemplate=folder.markdownTemplate;current.topic?.commentTemplate=folder.commentTemplate;current.topic?.imageTemplate=folder.imageTemplate}
         // Revize a texty stažené verze chrání úpravy z webu před přepsáním.
         let downloaded=CloudFolders.shared.editBase(id,topic:topic)
         try CloudLibrary.shared.enqueue(current,root:draftRoot,sessionID:id,base:shas,revision:downloaded?.1,original:downloaded?.0)
        }
       } else {try CloudLibrary.shared.enqueue(stored,root:draftRoot)}
       clearDraft(stored,root:draftRoot)
      } else {
       try finishSession(stored,root:draftRoot)
      }
     }
    }
   } catch {
    showError(L("Uložení se nepodařilo: ")+error.localizedDescription+L("\nOkno zůstává otevřené, můžeš to zkusit znovu."))
    view.window.makeKeyAndOrderFront(nil)
    return
   }
   Topics.rememberLast(draft.topic)
   if upload {
    do {
     if !cloudOnly { try CloudLibrary.shared.enqueue(draft,root:root) }
     Task { @MainActor in await CloudLibrary.shared.sync();await CloudFolders.shared.refresh(CloudLibrary.shared.connection) }
    } catch { showError(L("Poznámka je uložená lokálně. Cloudovou kopii se nepodařilo připravit.")+" "+error.localizedDescription) }
   }
   try? fm.removeItem(at:root);try? fm.removeItem(at:recoveryRoot);self.session=nil;self.composer=nil
  };view.show()
 }
 func previewTest(){
  do {let root=fm.temporaryDirectory.appendingPathComponent("ScreenshotNote-Preview-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true);session=root
   let image=NSImage(size:NSSize(width:1000,height:600));image.lockFocus();NSColor.windowBackgroundColor.setFill();NSRect(x:0,y:0,width:1000,height:600).fill();(L("Ukázkový screenshot") as NSString).draw(at:NSPoint(x:80,y:300),withAttributes:[.font:NSFont.systemFont(ofSize:36),.foregroundColor:NSColor.labelColor]);image.unlockFocus()
   let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!;try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("preview.png"))
   present(Draft(images:["preview.png"],comment:L("Poznámka k zachycenému obsahu."),title:L("Ukázková poznámka")),root:root)
  }catch{showError(error.localizedDescription)}
 }
}
