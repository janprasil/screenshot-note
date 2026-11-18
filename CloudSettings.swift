import AppKit

final class CloudSettings: NSObject, NSWindowDelegate {
 private(set) var window: NSWindow?
 private let status = NSTextField(wrappingLabelWithString: "")
 private let code = NSTextField(labelWithString: "")
 private var connectButton: AppButton!
 private var forget: AppButton!
 private var retry: AppButton!
 private var browser: AppButton!
 private var cancel: AppButton!
 private var timer: Timer?
 private let suppliedLibrary: CloudLibrary?
 private lazy var library = suppliedLibrary ?? CloudLibrary.shared
 init(library: CloudLibrary? = nil) { suppliedLibrary=library;super.init() }

 func show() {
  if let window { refresh(); startPolling(); presentScreenshotPanel(window); return }
  let panel = ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:580,height:360),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false)
  panel.isReleasedWhenClosed=false;panel.delegate=self;window=panel
  let view=installDesignRoot(panel,headerHeight:92)
  view.addSubview(designLabel(L("Cloudová knihovna"),NSRect(x:26,y:302,width:510,height:32),size:23,weight:.semibold))
  view.addSubview(designLabel(L("Připoj tento Mac potvrzením ve webovém prohlížeči."),NSRect(x:26,y:272,width:528,height:24),size:12,color:AppPalette.secondary))
  let explanation=NSTextField(wrappingLabelWithString:L("Na webu zkontroluj shodný kód a účet. Potvrď pouze párování, které jsi právě zahájil na tomto Macu."))
  explanation.frame=NSRect(x:26,y:207,width:528,height:50);explanation.font = .systemFont(ofSize:13);explanation.textColor=AppPalette.secondary;view.addSubview(explanation)
  code.frame=NSRect(x:26,y:162,width:528,height:32);code.font = .monospacedSystemFont(ofSize:23,weight:.semibold);code.isSelectable=true;view.addSubview(code)
  status.frame=NSRect(x:26,y:84,width:528,height:72);status.font = .systemFont(ofSize:12);status.textColor=AppPalette.secondary;view.addSubview(status)
  connectButton=styledButton(L("Připojit Mac"),role:.primary,frame:NSRect(x:364,y:26,width:190,height:32),target:self,action:#selector(connect))
  forget=styledButton(L("Zapomenout připojení"),role:.quiet,frame:NSRect(x:26,y:26,width:190,height:32),target:self,action:#selector(disconnect))
  retry=styledButton(L("Zkusit nahrát znovu"),frame:NSRect(x:354,y:26,width:200,height:32),target:self,action:#selector(sync))
  browser=styledButton(L("Otevřít web"),frame:NSRect(x:354,y:60,width:200,height:28),target:self,action:#selector(openBrowser))
  cancel=styledButton(L("Zrušit párování"),frame:NSRect(x:354,y:26,width:200,height:32),target:self,action:#selector(cancelPending))
  for b in [connectButton!,forget!,retry!,browser!,cancel!] { view.addSubview(b) }
  library.didChange={ [weak self] in self?.refresh() }
  refresh();startPolling();presentScreenshotPanel(panel)
 }
 private func startPolling() {
  timer?.invalidate()
  timer=Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in
   Task { @MainActor in
    guard let self,self.window?.isVisible == true else { return }
    if self.library.connection?.ownerID == nil {
     do { try await self.library.refreshConnection() } catch { self.library.lastError=(error as? CloudFailure)?.message ?? L("Připojení nelze ověřit. Zkus to později znovu.") }
    }
    self.refresh()
   }
  }
 }
 private func refresh() {
  guard connectButton != nil else { return }
  let c=library.connection, busy=library.syncing || library.connecting
  connectButton.isHidden=c != nil;connectButton.isEnabled = !busy && Date() >= library.retryAt
  forget.isHidden=c == nil;forget.isEnabled = !busy
  retry.isHidden=c?.ownerID == nil;retry.isEnabled = !busy && library.pendingCount > 0 && Date() >= library.retryAt
  cancel.isHidden=c == nil || c?.ownerID != nil;cancel.isEnabled = !busy
  browser.isHidden=c == nil;browser.isEnabled = !busy
  code.stringValue=c?.ownerID == nil ? c?.comparisonCode ?? "" : ""
  var text=library.lastError ?? (library.connecting ? L("Ověřuji připojení…") : c == nil ? L("Lokální poznámky nevyžadují účet. Cloud se aktivuje samostatně na webu.") : c?.ownerID == nil ? L("Čekám na potvrzení párování na webu.") : (library.signedInEmail ?? "") + " · " + LF("Čekající relace: %ld",library.pendingCount))
  if c?.ownerID != nil { text += "\n" + L("Zapomenutí smaže přístup pouze z tohoto Macu. Zařízení odvolej v nastavení webu.") }
  if library.legacyPendingCount > 0 { text += "\n" + L("Starší nebo nečitelné položky fronty zůstávají lokálně; automaticky se neodesílají.") }
  status.stringValue=text
 }
 @objc private func connect() {
  window?.makeFirstResponder(nil)
  Task { @MainActor in
   do {
    try await library.startPairing(endpoint:library.endpoint,name:Host.current().localizedName ?? "Mac")
    openBrowser()
   } catch { library.lastError=(error as? CloudFailure)?.message ?? L("Připojení se nezdařilo. Zkus to později znovu.") }
   refresh()
  }
 }
 @objc private func openBrowser() {
  guard let c=library.connection,let endpoint=CloudEndpoint(c.endpoint) else { return }
  let url=c.ownerID == nil ? CloudLibrary.browserURL(c) : endpoint.path("/settings")
  if let url { NSWorkspace.shared.open(url) }
 }
 @objc private func disconnect() { do { try library.forgetConnection() } catch { library.lastError=error.localizedDescription };refresh() }
 @objc private func cancelPending() {
  Task { @MainActor in
   do { try await library.cancelPairing() } catch { library.lastError=(error as? CloudFailure)?.message ?? L("Párování nelze zrušit. Můžeš zapomenout místní připojení; nedokončené párování vyprší.") }
   refresh()
  }
 }
 @objc private func sync() { Task { @MainActor in await library.sync() } }
 func windowWillClose(_ notification:Notification) { timer?.invalidate();timer=nil }
}
