import AppKit
import QuartzCore
import ServiceManagement
import UserNotifications

/// Průvodce prvním spuštěním: oprávnění, zkratky, cloud, výchozí složka a spuštění po přihlášení.
final class Onboarding:NSObject,NSWindowDelegate {
 static let doneKey="onboardingDone",stepKey="onboardingStep"
 enum Step:Int,CaseIterable{case welcome,permissions,shortcuts,cloud,folder,finish}
 private static let width:CGFloat=680,height:CGFloat=560,header:CGFloat=116

 /// Nová instalace nebo nedokončený průvodce; stávající instalace se jen označí jako hotová.
 static func pending(_ defaults:UserDefaults = .standard)->Bool {
  if defaults.bool(forKey:doneKey){return false}
  if defaults.object(forKey:stepKey) != nil{return true}
  let existing=["topics","destination","defaultTopic","lastTopic","shortcutOnboardingDone"].contains{defaults.object(forKey:$0) != nil} || (1...3).contains{defaults.data(forKey:"shortcut\($0)") != nil}
  if existing{defaults.set(true,forKey:doneKey);return false}
  return true
 }

 private(set) var window:NSWindow?
 private(set) var step:Step = .welcome
 /// Po dokončení; true znamená, že uživatel chce hned vyfotit první snímek.
 var onFinish:((Bool)->Void)?
 var manageFolders:(()->Void)?
 private let hotkeys:Hotkeys
 private let library:CloudLibrary
 private var root:NSView!,content:NSView!,titleLabel:NSTextField!,subtitleLabel:NSTextField!
 private var back:AppButton!,next:AppButton!,secondary:AppButton!,dots:StepDots!
 private var timer:Timer?,signature="",polling=false
 private var shortcutButtons:[ShortcutButton]=[]
 private var screenRequested=false,accessibilityRequested=false
 private var notifications:UNAuthorizationStatus?
 private let bridgeSwitch=NSSwitch(),loginSwitch=NSSwitch()
 init(hotkeys:Hotkeys,library:CloudLibrary = .shared){self.hotkeys=hotkeys;self.library=library;super.init()}
 var isVisible:Bool{window?.isVisible == true}

 func show(at start:Step?=nil) {
  step=start ?? Step(rawValue:UserDefaults.standard.integer(forKey:Self.stepKey)) ?? .welcome
  if window == nil{build()}
  render();presentAppWindow(window!)
  guard !isExportingDesign else{return}
  NSApp.activate(ignoringOtherApps:true)
  timer?.invalidate()
  timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in self?.tick()}
  tick()
 }

 private func build() {
  let w=Self.width,h=Self.height
  let panel=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:w,height:h),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false)
  panel.isReleasedWhenClosed=false;panel.delegate=self;window=panel
  root=installDesignRoot(panel,headerHeight:Self.header)
  if let icon=NSImage(contentsOfFile:Bundle.main.path(forResource:"AppIcon",ofType:"icns") ?? ""){let logo=NSImageView(frame:NSRect(x:28,y:h-86,width:52,height:52));logo.image=icon;root.addSubview(logo)}
  titleLabel=designLabel("",NSRect(x:94,y:h-62,width:w-160,height:32),size:23,weight:.semibold);root.addSubview(titleLabel)
  subtitleLabel=designLabel("",NSRect(x:94,y:h-88,width:w-130,height:22),size:12,color:AppPalette.secondary);root.addSubview(subtitleLabel)
  content=NSView(frame:NSRect(x:0,y:76,width:w,height:h-Self.header-76));root.addSubview(content)
  root.addSubview(DesignDivider(NSRect(x:28,y:68,width:w-56,height:1)))
  back=styledButton(L("Zpět na předchozí krok"),symbol:"chevron.left",role:.quiet,frame:NSRect(x:28,y:18,width:96,height:34),target:self,action:#selector(goBack));root.addSubview(back)
  dots=StepDots(frame:NSRect(x:w/2-70,y:30,width:140,height:10),count:Step.allCases.count);root.addSubview(dots)
  next=styledButton("",role:.primary,frame:.zero,target:self,action:#selector(goNext));next.keyEquivalent="\r";root.addSubview(next)
  secondary=styledButton(L("Hotovo"),frame:.zero,target:self,action:#selector(finishWithoutCapture));root.addSubview(secondary)
  bridgeSwitch.target=self;bridgeSwitch.action=#selector(toggleBridge)
  loginSwitch.target=self;loginSwitch.action=#selector(toggleLogin)
 }

 // MARK: Kroky

 private func render() {
  if !isExportingDesign{UserDefaults.standard.set(step.rawValue,forKey:Self.stepKey)}
  content.subviews.forEach{$0.removeFromSuperview()};shortcutButtons=[]
  switch step {
  case .welcome:welcome()
  case .permissions:permissions()
  case .shortcuts:shortcuts()
  case .cloud:cloud()
  case .folder:folder()
  case .finish:finish()
  }
  back.isHidden=step == .welcome
  dots.current=step.rawValue;dots.isHidden=step == .finish
  let title:String
  switch step {
  case .welcome:title=L("Začít")
  case .cloud:title=connected ? L("Pokračovat"):L("Přeskočit")
  case .finish:title=L("Začít používat")
  default:title=L("Pokračovat")
  }
  next.title=title
  // Přeskočení cloudu je vedlejší akce; hlavní je přihlášení v obsahu kroku.
  next.role=step == .cloud && !connected ? .secondary:.primary
  let width=max(150,ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.medium)]).width)+48)
  next.frame=NSRect(x:Self.width-28-width,y:18,width:width,height:34);next.needsDisplay=true
  secondary.isHidden=true;secondary.frame=NSRect(x:next.frame.minX-130,y:18,width:120,height:34)
  signature=currentSignature()
 }
 private func header(_ title:String,_ subtitle:String){titleLabel.stringValue=title;subtitleLabel.stringValue=subtitle}

 private func welcome() {
  header(L("Vítej ve Screenshot Note"),L("Za minutu nastavíme vše, co appka potřebuje."))
  row("camera.viewfinder",L("Snímky a videa s poznámkou"),L("Výřez, celá obrazovka nebo video a k tomu text pro každý snímek."),y:262,width:560)
  row("pencil.and.outline",L("Anotace přímo ve snímku"),L("Šipky, rámečky, texty a číslované komentáře."),y:184,width:560)
  row("folder",L("Složky na disku i v cloudu"),L("Markdown se snímky na Macu, volitelně záloha, web a týmy."),y:106,width:560)
  content.addSubview(designLabel(L("Všechno později změníš v Nastavení."),NSRect(x:28,y:28,width:560,height:20),size:12,color:AppPalette.secondary))
 }

 private func permissions() {
  applyRecommendedDefaults()
  header(L("Oprávnění"),L("Bez záznamu obrazovky appka nic nevyfotí. Ostatní je volitelné."))
  let screen=CGPreflightScreenCaptureAccess()
  row("rectangle.dashed",L("Záznam obrazovky"),L("Snímky a videa obrazovky."),y:300,tag:L("Nutné"),required:true)
  accessory(granted:screen,title:screenRequested ? L("Otevřít Nastavení…"):L("Povolit…"),y:300,action:#selector(requestScreen))
  divider(y:294)
  row("hand.point.up.left",L("Zpřístupnění"),L("Najde obsah stránky v okně prohlížeče."),y:236,tag:L("Volitelné"))
  accessory(granted:AXIsProcessTrusted(),title:accessibilityRequested ? L("Otevřít Nastavení…"):L("Povolit…"),y:236,action:#selector(requestAccessibility))
  divider(y:230)
  row("bell",L("Oznámení"),L("Upozorní na přesun starých relací a mazání."),y:172,tag:L("Volitelné"))
  let allowed=notifications == .authorized || notifications == .provisional
  accessory(granted:allowed,title:notifications == .denied ? L("Otevřít Nastavení…"):L("Povolit…"),y:172,action:#selector(requestNotifications))
  divider(y:166)
  row("globe",L("Propojení s prohlížečem"),L("Rozšíření pro Chrome přidá adresu a kontext stránky."),y:108,tag:L("Volitelné"))
  bridgeSwitch.frame=NSRect(x:Self.width-34-48,y:115,width:48,height:28);bridgeSwitch.state=NativeHostRegistration.isEnabled ? .on:.off;content.addSubview(bridgeSwitch)
  divider(y:102)
  row("power",L("Spuštění po přihlášení"),L("Ikona a zkratky budou připravené po startu."),y:44,tag:L("Doporučeno"))
  loginSwitch.frame=NSRect(x:Self.width-34-48,y:51,width:48,height:28);loginSwitch.state=SMAppService.mainApp.status == .enabled ? .on:.off;content.addSubview(loginSwitch)
  if screenRequested && !screen {
   let note=NSTextField(wrappingLabelWithString:L("Po povolení může macOS appku zavřít a znovu otevřít. Průvodce pak pokračuje tady."))
   note.font = .systemFont(ofSize:11);note.textColor=AppPalette.secondary;note.frame=NSRect(x:28,y:2,width:420,height:30);content.addSubview(note)
   content.addSubview(styledButton(L("Restartovat appku"),symbol:"arrow.clockwise",role:.quiet,frame:NSRect(x:Self.width-28-170,y:2,width:170,height:30),target:self,action:#selector(relaunch)))
  }
 }

 private func shortcuts() {
  header(L("Klávesové zkratky"),L("Snímej odkudkoli. Kliknutím na zkratku ji změníš."))
  for (i,(symbol,title,detail)) in [("viewfinder",L("Vybraná oblast"),L("Myší vybereš část obrazovky.")),("display",L("Celá hlavní obrazovka"),L("Vyfotí celou obrazovku najednou.")),("record.circle",L("Záznam videa (start/stop)"),L("První stisk připraví záznam, další ho zastaví."))].enumerated() {
   let id=i+1,y=CGFloat(284-i*72)
   row(symbol,title,detail,y:y)
   let button=ShortcutButton(frame:NSRect(x:Self.width-28-200,y:y+5,width:200,height:36));button.shortcut=Shortcut.load(id);button.title=button.shortcut.display
   button.onChange={[weak self] candidate in
    guard let self,assignShortcut(id,candidate,hotkeys:self.hotkeys) else{return false}
    DispatchQueue.main.async{self.render()};return true
   }
   content.addSubview(button);shortcutButtons.append(button)
   if i<2{divider(y:y-10)}
  }
  let box=DesignSurface(frame:NSRect(x:28,y:8,width:Self.width-56,height:84),fill:AppPalette.raised,radius:12);content.addSubview(box)
  let mac=macShortcutsTakenOver()
  box.addSubview(designLabel(L("Zkratky macOS"),NSRect(x:16,y:50,width:330,height:20),size:14,weight:.medium))
  let hint=designLabel(mac ? L("⇧⌘4, ⇧⌘3 a ⇧⌘5 teď patří Screenshot Note. Vrácením se zapnou systémové zkratky a aplikace použije výchozí."):L("Screenshot Note převezme ⇧⌘4, ⇧⌘3 a ⇧⌘5 a systémové zkratky pro snímky vypne."),NSRect(x:16,y:10,width:370,height:40),size:11,color:AppPalette.secondary)
  hint.usesSingleLineMode=false;hint.lineBreakMode = .byWordWrapping;hint.maximumNumberOfLines=3;box.addSubview(hint)
  box.addSubview(styledButton(mac ? L("Vrátit zkratky macOS"):L("Nahradit zkratky macOS"),role:mac ? .selected:.primary,frame:NSRect(x:box.bounds.width-16-214,y:25,width:214,height:34),target:self,action:#selector(toggleMacShortcuts)))
 }

 private var connected:Bool{library.connection?.ownerID != nil && !library.needsRepair}
 private func cloud() {
  header(L("Cloudová knihovna"),L("Volitelné. Bez účtu se vše ukládá jen na tomto Macu."))
  let c=library.connection,pending=c != nil && c?.ownerID == nil,expired=c?.ownerID != nil && library.needsRepair
  func hero(_ symbol:String,_ tint:NSColor,_ title:String,_ detail:String) {
   let image=NSImageView(frame:NSRect(x:28,y:298,width:44,height:44));image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:34,weight:.regular).applying(.init(hierarchicalColor:tint)));content.addSubview(image)
   content.addSubview(designLabel(title,NSRect(x:86,y:320,width:Self.width-120,height:24),size:17,weight:.semibold))
   content.addSubview(designLabel(detail,NSRect(x:86,y:298,width:Self.width-120,height:20),size:13,color:AppPalette.secondary))
  }
  if connected {
   hero("checkmark.circle.fill",.systemGreen,L("Mac je připojený"),library.signedInEmail ?? "")
   let synced=designLabel(L("Poznámky se automaticky nahrávají do cloudu."),NSRect(x:28,y:230,width:Self.width-56,height:20),size:13);synced.alignment = .center;content.addSubview(synced)
   content.addSubview(styledButton(L("Otevřít web"),symbol:"safari",frame:NSRect(x:Self.width/2-85,y:180,width:170,height:34),target:self,action:#selector(openWeb)))
  } else if pending {
   hero("link.circle.fill",AppPalette.accent,L("Čekám na potvrzení"),L("Na webu zkontroluj, že se kód shoduje."))
   let box=DesignSurface(frame:NSRect(x:28,y:214,width:Self.width-56,height:58),fill:AppPalette.raised,radius:10);content.addSubview(box)
   let raw=c?.comparisonCode ?? ""
   let code=NSTextField(labelWithString:raw.count == 8 ? raw.prefix(4)+"–"+raw.suffix(4):raw);code.frame=NSRect(x:0,y:13,width:box.bounds.width,height:32);code.alignment = .center;code.isSelectable=true;code.font = .monospacedSystemFont(ofSize:26,weight:.semibold);box.addSubview(code)
   let warning=NSImageView();warning.image=NSImage(systemSymbolName:"exclamationmark.triangle.fill",accessibilityDescription:nil)?.withSymbolConfiguration(.init(hierarchicalColor:.systemOrange))
   centeredLine(warning,L("Potvrzuj jen párování, které jsi právě spustil na tomto Macu."),y:182,size:13,weight:.medium,color:.systemOrange)
   let spinner=NSProgressIndicator();spinner.style = .spinning;spinner.controlSize = .small;if !isExportingDesign{spinner.startAnimation(nil)}
   centeredLine(spinner,L("Čekám na potvrzení v prohlížeči…"),y:148,size:12,color:AppPalette.secondary)
   content.addSubview(styledButton(L("Otevřít web"),symbol:"safari",frame:NSRect(x:Self.width/2-176,y:88,width:170,height:34),target:self,action:#selector(openWeb)))
   content.addSubview(styledButton(L("Zrušit párování"),role:.quiet,frame:NSRect(x:Self.width/2+6,y:88,width:170,height:34),target:self,action:#selector(cancelPairing)))
  } else {
   hero(expired ? "exclamationmark.icloud.fill":"icloud",expired ? .systemOrange:AppPalette.accent,expired ? L("Připojení vypršelo nebo bylo odvoláno"):L("Mac zatím není připojený"),L("Lokální poznámky fungují i bez účtu."))
   // Výhody jako tři karty přes celou šířku, pod nimi vycentrovaná hlavní akce.
   let gap:CGFloat=12,cardWidth=(Self.width-56-2*gap)/3
   for (i,(symbol,title,detail)) in [("icloud.and.arrow.up",L("Záloha a web"),L("Poznámky v bezpečí a dostupné odkudkoli.")),("link",L("Sdílení odkazem"),L("Relaci pošleš komukoli jedním odkazem.")),("person.2",L("Týmové složky"),L("Společné složky a komentáře s kolegy."))].enumerated() {
    let card=DesignSurface(frame:NSRect(x:28+CGFloat(i)*(cardWidth+gap),y:142,width:cardWidth,height:124),fill:AppPalette.paper,radius:12);card.border=AppPalette.stroke;content.addSubview(card)
    let badge=DesignSurface(frame:NSRect(x:cardWidth/2-16,y:78,width:32,height:32),fill:AppPalette.accent.withAlphaComponent(0.1),radius:9);card.addSubview(badge)
    let image=NSImageView(frame:NSRect(x:7,y:7,width:18,height:18));image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);image.contentTintColor=AppPalette.accent;badge.addSubview(image)
    let heading=designLabel(title,NSRect(x:12,y:50,width:cardWidth-24,height:20),size:13,weight:.semibold);heading.alignment = .center;card.addSubview(heading)
    let text=NSTextField(wrappingLabelWithString:detail);text.font = .systemFont(ofSize:11);text.textColor=AppPalette.secondary;text.alignment = .center;text.frame=NSRect(x:12,y:12,width:cardWidth-24,height:32);card.addSubview(text)
   }
   let connect=styledButton(expired ? L("Připojit znovu"):L("Přihlásit se a připojit Mac"),symbol:"person.crop.circle",role:.primary,frame:NSRect(x:Self.width/2-170,y:74,width:340,height:40),target:self,action:#selector(connectCloud))
   connect.isEnabled = !library.connecting && (expired || Date()>=library.retryAt);content.addSubview(connect)
   let hint=designLabel(L("Otevře se prohlížeč, kde se přihlásíš nebo založíš účet."),NSRect(x:28,y:46,width:Self.width-56,height:20),size:11,color:AppPalette.secondary);hint.alignment = .center;content.addSubview(hint)
  }
  if let error=library.lastError {
   let text=NSTextField(wrappingLabelWithString:error);text.font = .systemFont(ofSize:12);text.textColor = .systemOrange;text.alignment = .center;text.frame=NSRect(x:28,y:4,width:Self.width-56,height:34);content.addSubview(text)
  }
 }

 private func folder() {
  header(L("Kam ukládat poznámky"),L("Každá relace je Markdown se snímky ve složce na disku."))
  if UserDefaults.standard.object(forKey:"topics") == nil {
   row("folder",L("Výchozí složka"),(destination.path as NSString).abbreviatingWithTildeInPath,y:270)
   content.addSubview(styledButton(L("Změnit…"),frame:NSRect(x:Self.width-28-150,y:277,width:150,height:32),target:self,action:#selector(chooseFolder)))
  } else {
   let topic=Topics.defaultTopic
   row(topic.storageSymbol,topic.displayName,topic.savesLocally ? (topic.folder as NSString).abbreviatingWithTildeInPath:topic.storageKind,y:270)
   content.addSubview(styledButton(L("Spravovat…"),frame:NSRect(x:Self.width-28-150,y:277,width:150,height:32),target:self,action:#selector(openFolders)))
  }
  divider(y:260)
  row("doc.richtext",L("Co se do ní ukládá"),L("Markdown soubor pro každou relaci, snímky leží vedle ve složce assets."),y:190,width:560)
  row("plus.rectangle.on.folder",L("Další složky"),L("Projekty a týmy přidáš kdykoli v Nastavení → Složky."),y:116,width:560)
  if connected{row("icloud",L("Cloudové složky"),L("Po dokončení se zeptáme, kam na Macu ukládat složky z účtu."),y:42,width:560)}
 }

 private func finish() {
  header(L("Hotovo"),L("Screenshot Note je připravený a čeká v liště nahoře vpravo."))
  let mark=NSImageView(frame:NSRect(x:Self.width/2-36,y:262,width:72,height:72))
  mark.image=NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:60,weight:.regular).applying(.init(paletteColors:[.white,.systemGreen])));content.addSubview(mark)
  let title=designLabel(L("Vše je připravené"),NSRect(x:28,y:222,width:Self.width-56,height:30),size:22,weight:.semibold);title.alignment = .center;content.addSubview(title)
  let hint=designLabel(L("Začni třeba snímkem celé obrazovky. Stiskni:"),NSRect(x:28,y:190,width:Self.width-56,height:20),size:13,color:AppPalette.secondary);hint.alignment = .center;content.addSubview(hint)
  // Zkratka jako klávesa; výřez a video drobně pod ní.
  let keys=Shortcut.load(2).display,font=NSFont.monospacedSystemFont(ofSize:26,weight:.semibold)
  let keyWidth=ceil((keys as NSString).size(withAttributes:[.font:font]).width)+48
  let cap=DesignSurface(frame:NSRect(x:(Self.width-keyWidth)/2,y:118,width:keyWidth,height:56),fill:AppPalette.paper,radius:12);cap.border=AppPalette.stroke;content.addSubview(cap)
  let label=NSTextField(labelWithString:keys);label.font=font;label.alignment = .center;label.frame=NSRect(x:0,y:12,width:keyWidth,height:32);cap.addSubview(label)
  let others=designLabel(LF("%@ výřez · %@ video",Shortcut.load(1).display,Shortcut.load(3).display),NSRect(x:28,y:82,width:Self.width-56,height:20),size:12,color:AppPalette.secondary);others.alignment = .center;content.addSubview(others)
  let again=designLabel(L("Průvodce znovu spustíš v Nastavení."),NSRect(x:28,y:20,width:Self.width-56,height:18),size:11,color:.tertiaryLabelColor);again.alignment = .center;content.addSubview(again)
  if !isExportingDesign{DispatchQueue.main.async{self.celebrate()}}
 }
 /// Krátké konfety při dokončení; Reduce Motion je vynechá.
 private func celebrate() {
  guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,let layer=root.layer else{return}
  let emitter=CAEmitterLayer();emitter.emitterPosition=CGPoint(x:layer.bounds.midX,y:layer.bounds.maxY+10)
  emitter.emitterShape = .line;emitter.emitterSize=CGSize(width:layer.bounds.width,height:1)
  let piece:CGImage?={let ctx=CGContext(data:nil,width:12,height:7,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue);ctx?.setFillColor(NSColor.white.cgColor);ctx?.fill(CGRect(x:0,y:0,width:12,height:7));return ctx?.makeImage()}()
  emitter.emitterCells=[NSColor.systemGreen,.systemYellow,.systemPink,.systemBlue,.systemOrange,AppPalette.accent].map{color in
   let cell=CAEmitterCell();cell.birthRate=9;cell.lifetime=4;cell.velocity=160;cell.velocityRange=60
   cell.emissionLongitude = -.pi/2;cell.emissionRange = .pi/5;cell.spin=3;cell.spinRange=5;cell.yAcceleration = -180
   cell.scale=0.6;cell.scaleRange=0.3;cell.color=color.cgColor;cell.contents=piece;return cell
  }
  layer.addSublayer(emitter)
  DispatchQueue.main.asyncAfter(deadline:.now()+0.7){emitter.birthRate=0}
  DispatchQueue.main.asyncAfter(deadline:.now()+5){emitter.removeFromSuperlayer()}
 }

 /// Propojení s prohlížečem a spuštění po přihlášení zapne jednou za instalaci; pozdější vypnutí uživatelem zůstane.
 private func applyRecommendedDefaults() {
  let key="onboardingDefaultsApplied",defaults=UserDefaults.standard
  guard !isExportingDesign,!defaults.bool(forKey:key) else{return}
  defaults.set(true,forKey:key)
  if !NativeHostRegistration.isEnabled{do{_ = try NativeHostRegistration.setEnabled(true)}catch{NSLog("Browser bridge default failed: %@",error.localizedDescription)}}
  if SMAppService.mainApp.status != .enabled{do{try SMAppService.mainApp.register()}catch{NSLog("Login item default failed: %@",error.localizedDescription)}}
 }

 // MARK: Stavební prvky

 private func row(_ symbol:String,_ title:String,_ detail:String,y:CGFloat,width:CGFloat=380,tag:String?=nil,required:Bool=false) {
  let badge=DesignSurface(frame:NSRect(x:28,y:y+4,width:38,height:38),fill:AppPalette.accent.withAlphaComponent(0.1),radius:11);content.addSubview(badge)
  let image=NSImageView(frame:NSRect(x:9,y:9,width:20,height:20));image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);image.contentTintColor=AppPalette.accent;badge.addSubview(image)
  content.addSubview(designLabel(title,NSRect(x:80,y:y+24,width:width,height:21),size:14,weight:.medium))
  if let tag {
   let titleWidth=ceil((title as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:14,weight:.medium)]).width)
   let font=NSFont.systemFont(ofSize:10,weight:.semibold),tagWidth=ceil((tag as NSString).size(withAttributes:[.font:font]).width)+12
   let pill=DesignSurface(frame:NSRect(x:80+titleWidth+8,y:y+26,width:tagWidth,height:17),fill:required ? AppPalette.accent.withAlphaComponent(0.14):AppPalette.raised,radius:5);content.addSubview(pill)
   let text=designLabel(tag,NSRect(x:0,y:1,width:tagWidth,height:14),size:10,weight:.semibold,color:required ? AppPalette.accent:AppPalette.secondary);text.alignment = .center;pill.addSubview(text)
  }
  content.addSubview(designLabel(detail,NSRect(x:80,y:y+4,width:width,height:18),size:11,color:AppPalette.secondary))
 }
 /// Ikona a jednořádkový text vycentrované jako celek.
 private func centeredLine(_ icon:NSView,_ text:String,y:CGFloat,size:CGFloat,weight:NSFont.Weight = .regular,color:NSColor) {
  let width=min(Self.width-80,ceil((text as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight)]).width)+4)
  let x=(Self.width-(16+8+width))/2
  icon.frame=NSRect(x:x,y:y+2,width:16,height:16);content.addSubview(icon)
  content.addSubview(designLabel(text,NSRect(x:x+24,y:y,width:width,height:20),size:size,weight:weight,color:color))
 }
 private func divider(y:CGFloat){content.addSubview(DesignDivider(NSRect(x:80,y:y,width:Self.width-108,height:1)))}
 private func accessory(granted:Bool,title:String,y:CGFloat,action:Selector) {
  let right=Self.width-28
  if granted {
   let mark=NSImageView(frame:NSRect(x:right-88,y:y+15,width:16,height:16));mark.image=NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:nil);mark.contentTintColor=AppPalette.success;content.addSubview(mark)
   content.addSubview(designLabel(L("Povoleno"),NSRect(x:right-66,y:y+13,width:66,height:20),size:13,weight:.medium,color:AppPalette.success))
  } else {
   content.addSubview(styledButton(title,frame:NSRect(x:right-170,y:y+7,width:170,height:32),target:self,action:action))
  }
 }

 // MARK: Stav

 private func currentSignature()->String {
  switch step {
  case .permissions:return "\(CGPreflightScreenCaptureAccess())|\(AXIsProcessTrusted())|\(notifications?.rawValue ?? -1)|\(NativeHostRegistration.isEnabled)|\(SMAppService.mainApp.status.rawValue)"
  case .cloud:let c=library.connection;return "\(c == nil)|\(c?.ownerID != nil)|\(library.needsRepair)|\(c?.comparisonCode ?? "")|\(library.lastError ?? "")|\(library.connecting)|\(Date()>=library.retryAt)"
  case .folder:return destination.path+"|\(connected)"
  default:return ""
  }
 }
 /// Sekundový takt: oprávnění z Nastavení systému a potvrzení párování z prohlížeče se projeví hned.
 private func tick() {
  guard isVisible else{return}
  if step == .permissions {
   UNUserNotificationCenter.current().getNotificationSettings{settings in DispatchQueue.main.async{self.notifications=settings.authorizationStatus;self.refreshIfChanged()}}
  }
  if step == .cloud,let c=library.connection,c.ownerID == nil,!polling {
   polling=true
   Task{@MainActor in
    do{try await self.library.refreshConnection()}catch{self.library.lastError=(error as? CloudFailure)?.message ?? L("Připojení nelze ověřit. Zkus to později znovu.")}
    self.polling=false;self.refreshIfChanged()
   }
  }
  refreshIfChanged()
 }
 private func refreshIfChanged() {
  guard isVisible,!shortcutButtons.contains(where:\.recording),currentSignature() != signature else{return}
  render()
 }

 // MARK: Akce

 @objc private func goNext(){if step == .finish{complete(capture:false);return};step=Step(rawValue:step.rawValue+1) ?? .finish;render()}
 @objc private func goBack(){step=Step(rawValue:step.rawValue-1) ?? .welcome;render()}
 @objc private func finishWithoutCapture(){complete(capture:false)}
 func windowShouldClose(_ sender:NSWindow)->Bool{complete(capture:false);return false}
 private func complete(capture:Bool) {
  if !isExportingDesign {
   let defaults=UserDefaults.standard
   defaults.set(true,forKey:Self.doneKey);defaults.set(true,forKey:"shortcutOnboardingDone");defaults.removeObject(forKey:Self.stepKey)
  }
  timer?.invalidate();timer=nil;window?.orderOut(nil)
  onFinish?(capture)
 }
 private func openSettingsPane(_ url:String){if let url=URL(string:url){NSWorkspace.shared.open(url)}}
 @objc private func requestScreen() {
  // První klik vyvolá systémový dotaz, další otevře Nastavení systému.
  if screenRequested{openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")}else{screenRequested=true;_ = CGRequestScreenCaptureAccess()}
  render()
 }
 @objc private func requestAccessibility() {
  if accessibilityRequested{openSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")}
  else{accessibilityRequested=true;_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)}
  render()
 }
 @objc private func requestNotifications() {
  if notifications == .denied{openSettingsPane("x-apple.systempreferences:com.apple.preference.notifications");return}
  UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]){_,_ in DispatchQueue.main.async{self.tick()}}
 }
 @objc private func toggleBridge() {
  do {
   let browsers=try NativeHostRegistration.setEnabled(bridgeSwitch.state == .on)
   if bridgeSwitch.state == .on && browsers==0{showError(L("Nenašel jsem Chrome, Edge, Brave, Arc ani Chromium. Propojení se zapíše, až prohlížeč nainstaluješ a znovu spustíš appku."))}
  }catch{showError(error.localizedDescription)}
  render()
 }
 @objc private func relaunch() {
  // Nová instance se spustí až po ukončení této; jinak by jen předala snímání běžící appce.
  let task=Process();task.executableURL=URL(fileURLWithPath:"/bin/sh");task.arguments=["-c","sleep 1; /usr/bin/open \"$0\"",Bundle.main.bundlePath]
  do{try task.run();NSApp.terminate(nil)}catch{showError(error.localizedDescription)}
 }
 @objc private func toggleMacShortcuts() {
  MainActor.assumeIsolated{if macShortcutsTakenOver(){restoreMacShortcuts(hotkeys)}else{applyMacShortcuts(hotkeys)}}
  render();window?.makeKeyAndOrderFront(nil)
 }
 @objc private func connectCloud() {
  window?.makeFirstResponder(nil)
  Task{@MainActor in
   do {
    if library.needsRepair{try library.forgetConnection()}
    try await library.startPairing(endpoint:library.endpoint,name:Host.current().localizedName ?? "Mac")
    openWeb()
   }catch{library.lastError=(error as? CloudFailure)?.message ?? L("Připojení se nezdařilo. Zkus to později znovu.")}
   render()
  }
 }
 @objc private func openWeb() {
  guard let c=library.connection,let endpoint=CloudEndpoint(c.endpoint) else{return}
  if let url=c.ownerID == nil ? CloudLibrary.browserURL(c):endpoint.path("/library"){NSWorkspace.shared.open(url)}
 }
 @objc private func cancelPairing() {
  Task{@MainActor in
   do{try await library.cancelPairing()}catch{library.lastError=(error as? CloudFailure)?.message ?? L("Párování nelze zrušit. Můžeš zapomenout místní připojení; nedokončené párování vyprší.")}
   render()
  }
 }
 @objc private func chooseFolder() {
  let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L("Vybrat")
  panel.directoryURL=destination.deletingLastPathComponent()
  guard panel.runModal() == .OK,let url=panel.url else{return}
  do {
   // Bez uložených složek čte výchozí složka cestu z klíče destination.
   var topic=Topics.storedLocal[0];topic.folder=try Topics.checkedDestination(url.path).path
   try Topics.validateDestinations([topic]+CloudFolders.shared.allTopics)
   UserDefaults.standard.set(topic.folder,forKey:"destination")
  }catch{showError((error as? CloudFailure)?.message ?? error.localizedDescription)}
  render()
 }
 @objc private func openFolders(){manageFolders?()}
 @objc private func toggleLogin() {
  do {
   if loginSwitch.state == .on{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
   if SMAppService.mainApp.status == .requiresApproval{SMAppService.openSystemSettingsLoginItems()}
  }catch{showError(error.localizedDescription)}
  render()
 }
}

/// Ukazatel kroků průvodce: aktuální krok jako protáhlá tečka.
final class StepDots:NSView {
 let count:Int
 var current=0{didSet{needsDisplay=true;setAccessibilityLabel(LF("Krok %ld z %ld",current+1,count))}}
 init(frame:NSRect,count:Int){self.count=count;super.init(frame:frame);setAccessibilityRole(.staticText)}
 required init?(coder:NSCoder){fatalError()}
 override func draw(_ dirtyRect:NSRect) {
  let gap:CGFloat=7,dot:CGFloat=7,active:CGFloat=22
  var x=(bounds.width-(CGFloat(count-1)*(dot+gap)+active))/2
  for i in 0..<count {
   let width=i == current ? active:dot
   (i == current ? AppPalette.accent:i<current ? AppPalette.accent.withAlphaComponent(0.4):AppPalette.stroke).setFill()
   NSBezierPath(roundedRect:NSRect(x:x,y:bounds.midY-dot/2,width:width,height:dot),xRadius:dot/2,yRadius:dot/2).fill()
   x+=width+gap
  }
 }
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}
