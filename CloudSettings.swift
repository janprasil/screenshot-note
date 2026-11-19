import AppKit
import QuartzCore

final class CloudSettings: NSObject, NSWindowDelegate {
 private enum Phase: Equatable { case disconnected, pending, connected }
 private(set) var window: NSWindow?
 private var subtitle: NSTextField!
 private let hero = NSImageView()
 private var heroTitle: NSTextField!
 private var heroDetail: NSTextField!
 private let codeBox = DesignSurface(frame: .zero, fill: AppPalette.raised, radius: 10)
 private let code = NSTextField(labelWithString: "")
 private let statusIcon = NSImageView()
 private let status = NSTextField(wrappingLabelWithString: "")
 private var footnote: NSTextField!
 private let warningIcon = NSImageView()
 private var warning: NSTextField!
 private var connectButton: AppButton!
 private var forget: AppButton!
 private var retry: AppButton!
 private var browser: AppButton!
 private var cancel: AppButton!
 private var held: AppButton!
 private var timer: Timer?
 private var lastPhase: Phase?
 private let suppliedLibrary: CloudLibrary?
 private lazy var library = suppliedLibrary ?? CloudLibrary.shared
 init(library: CloudLibrary? = nil) { suppliedLibrary=library;super.init() }

 func show() {
  if let window { refresh(); startPolling(); presentScreenshotPanel(window); return }
  let panel = ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:580,height:360),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false)
  panel.isReleasedWhenClosed=false;panel.delegate=self;window=panel
  let view=installDesignRoot(panel,headerHeight:92)
  view.addSubview(designLabel(L("Cloudová knihovna"),NSRect(x:26,y:302,width:510,height:32),size:23,weight:.semibold))
  subtitle=designLabel("",NSRect(x:26,y:272,width:528,height:24),size:12,color:AppPalette.secondary);view.addSubview(subtitle)
  hero.frame=NSRect(x:26,y:196,width:44,height:44);hero.imageScaling = .scaleProportionallyUpOrDown;hero.wantsLayer=true;view.addSubview(hero)
  heroTitle=designLabel("",NSRect(x:84,y:218,width:470,height:24),size:17,weight:.semibold);view.addSubview(heroTitle)
  heroDetail=designLabel("",NSRect(x:84,y:196,width:470,height:20),size:13,color:AppPalette.secondary);view.addSubview(heroDetail)
  codeBox.frame=NSRect(x:26,y:126,width:528,height:54);view.addSubview(codeBox)
  code.frame=NSRect(x:0,y:12,width:528,height:30);code.alignment = .center;code.isSelectable=true
  code.font = .monospacedSystemFont(ofSize:24,weight:.semibold);codeBox.addSubview(code)
  statusIcon.frame=NSRect(x:26,y:122,width:15,height:15);view.addSubview(statusIcon)
  status.frame=NSRect(x:50,y:82,width:504,height:56);status.font = .systemFont(ofSize:12);view.addSubview(status)
  warningIcon.frame=NSRect(x:26,y:99,width:16,height:16);view.addSubview(warningIcon)
  warning=designLabel(L("Potvrzuj jen párování, které jsi právě spustil na tomto Macu."),NSRect(x:50,y:97,width:504,height:20),size:13,weight:.medium,color:.systemOrange);view.addSubview(warning)
  // Ikona visí v levém okraji, text stavu i poznámka začínají na x50.
  footnote=designLabel("",NSRect(x:50,y:58,width:504,height:16),size:11,color:.tertiaryLabelColor);view.addSubview(footnote)
  connectButton=styledButton(L("Připojit Mac"),role:.primary,frame:.zero,target:self,action:#selector(connect))
  forget=styledButton(L("Odpojit Mac"),role:.quiet,frame:.zero,target:self,action:#selector(disconnect))
  retry=styledButton(L("Nahrát teď"),role:.primary,frame:.zero,target:self,action:#selector(sync))
  browser=styledButton(L("Otevřít web"),frame:.zero,target:self,action:#selector(openBrowser))
  cancel=styledButton(L("Zrušit párování"),role:.quiet,frame:.zero,target:self,action:#selector(cancelPending))
  held=styledButton(L("Zmizelé relace…"),role:.primary,frame:.zero,target:self,action:#selector(resolveHeld))
  for b in [connectButton!,forget!,retry!,browser!,cancel!,held!] { view.addSubview(b) }
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
 private func symbol(_ name:String,_ color:NSColor,_ size:CGFloat)->NSImage? {
  NSImage(systemSymbolName:name,accessibilityDescription:nil)?
   .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:size,weight:.regular).applying(.init(hierarchicalColor:color)))
 }
 private func refresh() {
  guard connectButton != nil else { return }
  let c=library.connection, busy=library.syncing || library.connecting
  let phase:Phase = c == nil ? .disconnected : c?.ownerID == nil ? .pending : .connected
  switch phase {
  case .disconnected:
   subtitle.stringValue=L("Zálohuj poznámky do cloudu a měj je i na webu.")
   hero.image=symbol("icloud",AppPalette.accent,34)
   heroTitle.stringValue=L("Mac zatím není připojený")
   heroDetail.stringValue=L("Poznámky se ukládají jen na tomto Macu.")
   footnote.stringValue=L("Lokální poznámky fungují i bez účtu.")
  case .pending:
   subtitle.stringValue=L("Dokonči připojení ve webovém prohlížeči.")
   hero.image=symbol("link.circle.fill",AppPalette.accent,34)
   heroTitle.stringValue=L("Čekám na potvrzení")
   heroDetail.stringValue=L("Na webu zkontroluj, že se kód shoduje.")
   footnote.stringValue=""
  case .connected:
   subtitle.stringValue=L("Poznámky se automaticky nahrávají do cloudu.")
   hero.image=symbol("checkmark.circle.fill",.systemGreen,34)
   heroTitle.stringValue=L("Mac je připojený")
   heroDetail.stringValue=library.signedInEmail ?? ""
   footnote.stringValue=L("Odpojení odebere přístup jen z tohoto Macu. Zařízení můžeš odvolat na webu.")
  }
  codeBox.isHidden=phase != .pending
  let raw=phase == .pending ? c?.comparisonCode ?? "" : ""
  code.stringValue=raw.count == 8 ? raw.prefix(4) + "–" + raw.suffix(4) : raw
  warning.isHidden=phase != .pending;warningIcon.isHidden=phase != .pending
  warningIcon.image=symbol("exclamationmark.triangle.fill",.systemOrange,13)
  // Při párování je místo pod kódem vyhrazené varování, stav jde níž.
  // Ikona je svisle na středu prvního řádku stavu.
  statusIcon.frame=phase == .pending ? NSRect(x:26,y:64,width:15,height:15) : NSRect(x:26,y:122,width:15,height:15)
  status.frame=phase == .pending ? NSRect(x:50,y:56,width:504,height:24) : NSRect(x:50,y:82,width:504,height:56)

  var text:String, icon:String, tint:NSColor
  if let error=library.lastError { text=error;icon="exclamationmark.triangle.fill";tint = .systemOrange }
  else if library.connecting { text=L("Ověřuji připojení…");icon="arrow.triangle.2.circlepath";tint=AppPalette.accent }
  else if phase == .connected && library.syncing { text=L("Nahrávám poznámky…");icon="arrow.up.circle";tint=AppPalette.accent }
  else if phase == .connected && library.pendingCount > 0 { text=LF("Čeká na nahrání: %ld",library.pendingCount);icon="clock";tint=AppPalette.secondary }
  else if phase == .connected { text=L("Vše je nahrané v cloudu.");icon="checkmark.icloud";tint = .systemGreen }
  else { text="";icon="";tint=AppPalette.secondary }
  if library.legacyPendingCount > 0 { text += (text.isEmpty ? "" : "\n") + L("Starší nebo nečitelné položky fronty zůstávají lokálně; automaticky se neodesílají.") }
  if let error=CloudFolders.shared.lastError { text += (text.isEmpty ? "" : "\n") + error }
  for notice in CloudFolders.shared.notices { text += (text.isEmpty ? "" : "\n") + notice }
  status.stringValue=text;status.textColor=tint == .systemGreen || tint == AppPalette.secondary ? AppPalette.secondary : tint == .systemOrange ? .systemOrange : AppPalette.text
  statusIcon.image=icon.isEmpty ? nil : symbol(icon,tint,13);statusIcon.isHidden=text.isEmpty

  let right=NSRect(x:364,y:20,width:190,height:32), middle=NSRect(x:184,y:20,width:170,height:32), left=NSRect(x:26,y:20,width:140,height:32)
  connectButton.isHidden=phase != .disconnected;connectButton.frame=right
  connectButton.isEnabled = !busy && Date() >= library.retryAt
  cancel.isHidden=phase != .pending;cancel.frame=left;cancel.isEnabled = !busy
  forget.isHidden=phase != .connected;forget.frame=left;forget.isEnabled = !busy
  let canRetry=phase == .connected && library.pendingCount > 0
  retry.isHidden = !canRetry;retry.frame=right;retry.isEnabled = !busy && Date() >= library.retryAt
  browser.isHidden=phase == .disconnected;browser.isEnabled = !busy
  browser.frame=canRetry ? middle : right;browser.role=phase == .pending ? .primary : .secondary;browser.needsDisplay=true
  // Zadržené hromadné smazání nahradí tlačítko webu.
  held.isHidden=phase != .connected || CloudFolders.shared.heldFolders.isEmpty;held.frame=browser.frame
  if !held.isHidden{browser.isHidden=true}

  if lastPhase == .pending && phase == .connected { celebrate() }
  lastPhase=phase
 }
 private func celebrate() {
  guard !isExportingDesign, let layer=window?.contentView?.layer, let heroLayer=hero.layer else { return }
  let pop=CAKeyframeAnimation(keyPath:"transform.scale");pop.values=[0.4,1.25,0.95,1];pop.keyTimes=[0,0.45,0.75,1];pop.duration=0.55
  heroLayer.anchorPoint=CGPoint(x:0.5,y:0.5);heroLayer.position=CGPoint(x:hero.frame.midX,y:hero.frame.midY);heroLayer.add(pop,forKey:"pop")
  let emitter=CAEmitterLayer();emitter.emitterPosition=CGPoint(x:layer.bounds.midX,y:layer.bounds.maxY+10)
  emitter.emitterShape = .line;emitter.emitterSize=CGSize(width:layer.bounds.width,height:1)
  let colors:[NSColor]=[.systemGreen,.systemYellow,.systemPink,.systemBlue,.systemOrange,AppPalette.accent]
  emitter.emitterCells=colors.map { color in
   let cell=CAEmitterCell();cell.birthRate=9;cell.lifetime=4;cell.velocity=160;cell.velocityRange=60
   cell.emissionLongitude = -.pi/2;cell.emissionRange = .pi/5;cell.spin=3;cell.spinRange=5;cell.yAcceleration = -180
   cell.scale=0.6;cell.scaleRange=0.3;cell.color=color.cgColor;cell.contents=confettiPiece();return cell
  }
  layer.addSublayer(emitter)
  DispatchQueue.main.asyncAfter(deadline:.now()+0.7){emitter.birthRate=0}
  DispatchQueue.main.asyncAfter(deadline:.now()+5){emitter.removeFromSuperlayer()}
 }
 private func confettiPiece()->CGImage? {
  let size=CGSize(width:12,height:7)
  guard let ctx=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
  ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(origin:.zero,size:size));return ctx.makeImage()
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
  let url=c.ownerID == nil ? CloudLibrary.browserURL(c) : endpoint.path("/library")
  if let url { NSWorkspace.shared.open(url) }
 }
 @objc private func disconnect() {
  let previous=library.connection
  do {
   try library.forgetConnection();TemplateDefaults.shared.forgetAccount()
   // Cloudové složky po odhlášení zůstávají jako lokální, nic se nemaže.
   if let owner=previous?.ownerID,let origin=previous?.endpoint{rememberMoved(try CloudFolders.shared.convertToLocal(owner:owner,origin:origin))}
  } catch { library.lastError=error.localizedDescription }
  refresh()
 }
 @objc private func cancelPending() {
  Task { @MainActor in
   do { try await library.cancelPairing() } catch { library.lastError=(error as? CloudFailure)?.message ?? L("Párování nelze zrušit. Můžeš zapomenout místní připojení; nedokončené párování vyprší.") }
   refresh()
  }
 }
 @objc private func resolveHeld() {Task { @MainActor in await FolderDialogs.resolveHeld(manual:true);refresh() }}
 @objc private func sync() { Task { @MainActor in await library.sync() } }
 func windowWillClose(_ notification:Notification) { timer?.invalidate();timer=nil }
}
