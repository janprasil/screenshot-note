import AppKit

/// Uložené volby záznamu: cíl (celá obrazovka nebo výřez), odpočet zapnutý/vypnutý a poslední výřez.
enum RecordingPreferences {
 static var target:RecordingTarget {
  get{RecordingTarget(rawValue:UserDefaults.standard.string(forKey:"recordingTarget") ?? "") == .region ? .region:.screen}
  set{UserDefaults.standard.set(newValue.rawValue,forKey:"recordingTarget")}
 }
 /// Výchozí je odpočet zapnutý (3 s).
 static var countdownEnabled:Bool {
  get{UserDefaults.standard.object(forKey:"recordingCountdownEnabled") as? Bool ?? true}
  set{UserDefaults.standard.set(newValue,forKey:"recordingCountdownEnabled")}
 }
 static var countdown:Int{countdownEnabled ? recordingCountdown:0}
 /// Poslední výřez v globálních bodech AppKit; použije se jen, když celý leží na některém displeji.
 static var region:CGRect? {
  get{UserDefaults.standard.string(forKey:"recordingRegion").map(NSRectFromString).flatMap{rect in NSScreen.screens.contains{$0.frame.contains(rect)} && rect.width>=RecordingSetup.minimum && rect.height>=RecordingSetup.minimum ? rect:nil}}
  set{if let newValue{UserDefaults.standard.set(NSStringFromRect(newValue),forKey:"recordingRegion")}else{UserDefaults.standard.removeObject(forKey:"recordingRegion")}}
 }
}

/// Nastavení záznamu ve stylu systémového ⇧⌘5: ztmavené displeje a plovoucí lišta s cílem a odpočtem.
final class RecordingSetup {
 struct Choice{var target:RecordingTarget;var region:CGRect?;var screen:NSScreen;var countdown:Int}
 static let minimum:CGFloat=40
 private(set) var target:RecordingTarget;private(set) var region:CGRect?;private(set) var screen:NSScreen
 private var countdownEnabled:Bool;private var seconds:Int
 private var dims:[RecordingDimPanel]=[];private(set) var bar:RecordingBar!
 private var completion:((Choice?)->Void)?

 init(screens:[NSScreen]=NSScreen.screens,completion:@escaping (Choice?)->Void) {
  self.completion=completion
  target=RecordingPreferences.target;region=RecordingPreferences.region
  countdownEnabled=RecordingPreferences.countdownEnabled;seconds=recordingCountdown
  let pointer=screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main ?? screens[0]
  // Uložený výřez určí displej; jinak displej pod kurzorem.
  screen=target == .region ? region.flatMap{area in screens.first{$0.frame.contains(area)}} ?? pointer:pointer
  dims=screens.map{RecordingDimPanel(screen:$0,setup:self)}
  bar=RecordingBar(setup:self)
 }
 /// Zobrazí překryvy a lištu bez aktivace aplikace (cílová aplikace si nechá vzhled aktivního okna).
 func show() {
  for dim in dims{dim.orderFrontRegardless()}
  bar.orderFrontRegardless()
  // Klíčový je překryv pod myší: jen klíčové okno dostává pohyb myši pro kurzor.
  (dims.first{$0.frame.contains(NSEvent.mouseLocation)} ?? dims.first)?.makeKey()
  refresh()
 }
 /// Zrušení zvenku (Esc, zkratka, menu): bez volání completion.
 func cancel(){guard completion != nil else{return};completion=nil;close()}
 func dismiss(){finish(nil)}
 func confirm() {
  guard canStart else{return}
  RecordingPreferences.target=target;RecordingPreferences.countdownEnabled=countdownEnabled;recordingCountdown=seconds
  if target == .region{RecordingPreferences.region=region}
  let countdown=countdownEnabled ? seconds:0
  finish(Choice(target:target,region:target == .region ? region:nil,screen:screen,countdown:countdown))
 }
 var canStart:Bool{target == .screen || region != nil}
 var countdownSeconds:Int{seconds}
 var usesCountdown:Bool{countdownEnabled}

 func choose(_ target:RecordingTarget){self.target=target;if target == .region,let area=region,let owner=dims.first(where:{$0.frame.contains(area)}){screen=owner.screenRef};refresh()}
 func setCountdown(enabled:Bool,seconds value:Int?=nil){countdownEnabled=enabled;if let value,RecordingLimits.countdowns.contains(value){seconds=value};refresh()}
 /// Klik na displej v režimu celé obrazovky vybere ten displej.
 func chooseScreen(_ screen:NSScreen){guard target == .screen else{return};self.screen=screen;refresh()}
 func setRegion(_ rect:CGRect?,on screen:NSScreen){region=rect;if rect != nil{self.screen=screen};refresh()}

 func refresh() {
  for dim in dims{dim.refreshOverlay()}
  bar.refreshBar();bar.place(on:screen)
 }
 private func finish(_ choice:Choice?){guard let done=completion else{return};completion=nil;close();done(choice)}
 private func close() {
  bar.orderOut(nil);bar.setup=nil;for dim in dims{dim.orderOut(nil);dim.setup=nil}
  // Sledování myši vlastní lišta; bez něj nepřijde událost uvolněnému oknu.
  if let back=bar.contentView{for area in back.trackingAreas{back.removeTrackingArea(area)}}
  // Okna se uvolní až v dalším průchodu run loopu: zavírá se i z akce jejich tlačítka nebo klávesy.
  let windows:[NSWindow]=dims+[bar];dims=[]
  DispatchQueue.main.async{withExtendedLifetime(windows){}}
 }
}

/// Ztmavení jednoho displeje; v režimu výřezu se tu oblast táhne nebo posouvá.
final class RecordingDimPanel:NSPanel {
 fileprivate weak var setup:RecordingSetup?
 let screenRef:NSScreen
 private let view:RecordingDimView
 init(screen:NSScreen,setup:RecordingSetup) {
  screenRef=screen;self.setup=setup;view=RecordingDimView(frame:NSRect(origin:.zero,size:screen.frame.size))
  super.init(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  becomesKeyOnlyIfNeeded=false;level = .screenSaver;isOpaque=false;backgroundColor = .clear;hasShadow=false
  isReleasedWhenClosed=false;collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];acceptsMouseMovedEvents=true
  view.panel=self;contentView=view;setFrame(screen.frame,display:false)
 }
 override var canBecomeKey:Bool{true}
 func refreshOverlay(){view.needsDisplay=true;view.hint.isHidden = !(setup?.target == .region && setup?.region == nil && setup?.screen.frame == screenRef.frame);view.updateCursor()}
 override func keyDown(with event:NSEvent){if !recordingSetupKey(event,setup){super.keyDown(with:event)}}
}

/// Kurzory výřezu: přesun (čtyři šipky) a změna velikosti (úhlopříčka); na macOS 15+ systémový kurzor rohu.
enum RegionCursors {
 static let move=symbolCursor("arrow.up.and.down.and.arrow.left.and.right")
 static let resize:NSCursor={
  if #available(macOS 15,*){return NSCursor.frameResize(position:.bottomRight,directions:.all)}
  return symbolCursor("arrow.up.left.and.arrow.down.right")
 }()
 /// Černý symbol s bílým obrysem, aby byl vidět na tmavém i světlém pozadí.
 static func symbolCursor(_ name:String)->NSCursor {
  let size=NSSize(width:24,height:24)
  guard let symbol=NSImage(systemSymbolName:name,accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:15,weight:.bold)) else{return .openHand}
  let image=NSImage(size:size,flipped:false){rect in
   func tinted(_ color:NSColor)->NSImage{let copy=NSImage(size:symbol.size,flipped:false){r in symbol.draw(in:r);color.set();r.fill(using:.sourceAtop);return true};return copy}
   let glyph=NSRect(x:(rect.width-symbol.size.width)/2,y:(rect.height-symbol.size.height)/2,width:symbol.size.width,height:symbol.size.height)
   let halo=tinted(.white)
   for dx in [-1.5,0,1.5] as [CGFloat]{for dy in [-1.5,0,1.5] as [CGFloat]{halo.draw(in:glyph.offsetBy(dx:dx,dy:dy))}}
   tinted(.black).draw(in:glyph);return true
  }
  return NSCursor(image:image,hotSpot:NSPoint(x:size.width/2,y:size.height/2))
 }
}

/// Klávesy překryvu a lišty: Return spustí, Esc zruší (když globální Esc není k dispozici).
func recordingSetupKey(_ event:NSEvent,_ setup:RecordingSetup?)->Bool {
 switch event.keyCode{case 36,76:setup?.confirm();return true;case 53:setup?.dismiss();return true;default:return false}
}

final class RecordingDimView:NSView {
 weak var panel:RecordingDimPanel?
 private(set) var hint=NSView()
 private enum DragMode{case draw,move,resize}
 private var drag:(start:NSPoint,original:CGRect?,mode:DragMode)?
 /// Úchyt pro změnu velikosti v pravém dolním rohu výřezu.
 static let handleSize:CGFloat=14
 private var handleRect:CGRect?{localRegion.map{CGRect(x:$0.maxX-Self.handleSize/2,y:$0.minY-Self.handleSize/2,width:Self.handleSize,height:Self.handleSize)}}
 override init(frame:NSRect) {
  super.init(frame:frame)
  hint=overlayHint(L("Tažením vyber oblast záznamu"),size:15);addSubview(hint)
  hint.setFrameOrigin(NSPoint(x:(bounds.width-hint.frame.width)/2,y:(bounds.height-hint.frame.height)/2));hint.isHidden=true
 }
 required init?(coder:NSCoder){fatalError()}
 override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
 private var setup:RecordingSetup?{panel?.setup}
 /// Výřez v souřadnicích tohoto pohledu, když na displeji leží.
 private var localRegion:CGRect? {
  guard let setup,setup.target == .region,let region=setup.region,let panel,panel.frame.intersects(region) else{return nil}
  return region.offsetBy(dx:-panel.frame.minX,dy:-panel.frame.minY)
 }
 override func draw(_ dirtyRect:NSRect) {
  guard let setup,let panel else{return}
  // Vybraný displej je v režimu celé obrazovky světlejší, ostatní tmavší.
  let chosen=setup.target == .screen && setup.screen.frame == panel.screenRef.frame
  let path=NSBezierPath(rect:bounds);path.windingRule = .evenOdd
  if let hole=localRegion{path.append(NSBezierPath(rect:hole))}
  NSColor.black.withAlphaComponent(chosen ? 0.18:0.45).setFill();path.fill()
  if let hole=localRegion {
   // Úplně průhledné pixely by kliknutí pustily do okna pod překryvem.
   NSColor.black.withAlphaComponent(0.01).setFill();hole.fill()
   NSColor.white.setStroke();let border=NSBezierPath(rect:hole.insetBy(dx:-0.75,dy:-0.75));border.lineWidth=1.5;border.stroke()
   let size="\(Int(hole.width)) × \(Int(hole.height))" as NSString
   let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.monospacedDigitSystemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.white]
   let text=size.size(withAttributes:attrs),pill=NSRect(x:hole.midX-text.width/2-8,y:max(4,hole.minY-text.height-12),width:text.width+16,height:text.height+6)
   NSColor.black.withAlphaComponent(0.7).setFill();NSBezierPath(roundedRect:pill,xRadius:pill.height/2,yRadius:pill.height/2).fill()
   size.draw(at:NSPoint(x:pill.minX+8,y:pill.minY+3),withAttributes:attrs)
   if let handle=handleRect{let knob=NSBezierPath(ovalIn:handle);NSColor.white.setFill();knob.fill();NSColor.black.withAlphaComponent(0.5).setStroke();knob.lineWidth=1;knob.stroke()}
  } else if chosen {
   NSColor.white.withAlphaComponent(0.6).setStroke();let border=NSBezierPath(rect:bounds.insetBy(dx:2,dy:2));border.lineWidth=4;border.stroke()
  }
 }
 // Panel neaktivuje aplikaci, takže cursor rects nefungují; kurzor se nastavuje přes tracking area.
 override func updateTrackingAreas() {
  super.updateTrackingAreas()
  for area in trackingAreas{removeTrackingArea(area)}
  addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.cursorUpdate,.mouseMoved,.mouseEnteredAndExited],owner:self))
 }
 private func mode(at point:NSPoint)->DragMode {
  if handleRect?.insetBy(dx:-4,dy:-4).contains(point) == true{return .resize}
  return localRegion?.contains(point) == true ? .move:.draw
 }
 private func cursor(for mode:DragMode)->NSCursor {
  guard setup?.target == .region else{return .arrow}
  switch mode{case .draw:return .crosshair;case .move:return RegionCursors.move;case .resize:return RegionCursors.resize}
 }
 func updateCursor(_ location:NSPoint?=nil) {
  // Bez události jen displej pod myší a mimo lištu.
  if location == nil{let mouse=NSEvent.mouseLocation;guard window?.frame.contains(mouse) == true,setup?.bar.frame.contains(mouse) != true else{return}}
  let point=location ?? convert(window?.mouseLocationOutsideOfEventStream ?? .zero,from:nil)
  cursor(for:drag?.mode ?? mode(at:point)).set()
 }
 override func cursorUpdate(with event:NSEvent){updateCursor(convert(event.locationInWindow,from:nil))}
 // Přechod na jiný displej převezme klíčové okno, aby kurzor dál reagoval.
 override func mouseEntered(with event:NSEvent){if window?.isKeyWindow == false{window?.makeKey()};updateCursor(convert(event.locationInWindow,from:nil))}
 override func mouseMoved(with event:NSEvent){updateCursor(convert(event.locationInWindow,from:nil))}
 override func mouseDown(with event:NSEvent) {
  guard let setup,let panel else{return}
  panel.makeKey()
  guard setup.target == .region else{setup.chooseScreen(panel.screenRef);return}
  let point=convert(event.locationInWindow,from:nil)
  // Úchyt má přednost (je i kousek vně výřezu), pak posun uvnitř, jinak nový výřez.
  drag=(point,localRegion,mode(at:point));updateCursor(point)
 }
 override func mouseDragged(with event:NSEvent) {
  guard let setup,let panel,let drag else{return}
  let point=convert(event.locationInWindow,from:nil),bounds=self.bounds
  var rect:CGRect
  if drag.mode == .resize,let original=drag.original {
   // Levý horní roh zůstává, pravý dolní jde za kurzorem.
   let x=max(min(point.x,bounds.width),original.minX+RecordingSetup.minimum),y=min(max(point.y,0),original.maxY-RecordingSetup.minimum)
   rect=CGRect(x:original.minX,y:y,width:x-original.minX,height:original.maxY-y)
  } else if drag.mode == .move,let original=drag.original {
   // Posun celé oblasti, oříznutý na displej.
   rect=original.offsetBy(dx:point.x-drag.start.x,dy:point.y-drag.start.y)
   rect.origin.x=min(max(rect.minX,0),bounds.width-rect.width);rect.origin.y=min(max(rect.minY,0),bounds.height-rect.height)
  } else {
   let end=CGPoint(x:min(max(point.x,0),bounds.width),y:min(max(point.y,0),bounds.height))
   rect=CGRect(x:min(drag.start.x,end.x),y:min(drag.start.y,end.y),width:abs(drag.start.x-end.x),height:abs(drag.start.y-end.y))
  }
  setup.setRegion(rect.integral.offsetBy(dx:panel.frame.minX,dy:panel.frame.minY),on:panel.screenRef);updateCursor(point)
 }
 override func mouseUp(with event:NSEvent) {
  guard let setup,let panel,let drag else{return};self.drag=nil
  defer{updateCursor(convert(event.locationInWindow,from:nil))}
  // Kliknutí nebo příliš malý výřez vrátí předchozí oblast.
  if let region=setup.region,region.width>=RecordingSetup.minimum,region.height>=RecordingSetup.minimum{return}
  setup.setRegion(drag.original.map{$0.offsetBy(dx:panel.frame.minX,dy:panel.frame.minY)},on:panel.screenRef)
 }
}

/// Tlačítko lišty: ikona nebo text, vybraný stav světlejší podložkou.
final class RecordingBarButton:NSButton {
 var selected=false{didSet{needsDisplay=true}}
 var tint:NSColor?
 /// Šipka vpravo za textem (rozbalovací výběr).
 var disclosure=false{didSet{needsDisplay=true}}
 private var hovered=false
 override func updateTrackingAreas(){super.updateTrackingAreas();for area in trackingAreas{removeTrackingArea(area)};addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self))}
 override func mouseEntered(with event:NSEvent){hovered=true;needsDisplay=true}
 override func mouseExited(with event:NSEvent){hovered=false;needsDisplay=true}
 override func acceptsFirstMouse(for event:NSEvent?)->Bool{true}
 override func draw(_ dirtyRect:NSRect) {
  let shape=NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:2),xRadius:7,yRadius:7)
  if let tint{tint.withAlphaComponent(!isEnabled ? 0.35:(isHighlighted ? 0.75:1)).setFill();shape.fill()}
  else if selected{NSColor.white.withAlphaComponent(isHighlighted ? 0.3:0.22).setFill();shape.fill()}
  else if disclosure{NSColor.white.withAlphaComponent(isHighlighted ? 0.24:(hovered ? 0.18:0.12)).setFill();shape.fill()}
  else if hovered || isHighlighted{NSColor.white.withAlphaComponent(isHighlighted ? 0.16:0.1).setFill();shape.fill()}
  let ink=NSColor.white.withAlphaComponent(isEnabled ? 1:0.4)
  let attrs:[NSAttributedString.Key:Any]=[.font:NSFont.systemFont(ofSize:13,weight:.medium),.foregroundColor:ink]
  let size=(title as NSString).size(withAttributes:attrs)
  let symbol=image != nil,text = !title.isEmpty
  let width=(text ? size.width:0)+(symbol ? 18:0)+(symbol && text ? 6:0)+(disclosure ? 18:0);var x=(bounds.width-width)/2
  if let image {drawAdaptiveSymbol(image,in:NSRect(x:x,y:bounds.midY-9,width:18,height:18),color:ink);x+=24}
  if text{(title as NSString).draw(at:NSPoint(x:x,y:bounds.midY-size.height/2),withAttributes:attrs);x+=size.width+8}
  if disclosure{drawAdaptiveSymbol(NSImage(systemSymbolName:"chevron.down",accessibilityDescription:nil),in:NSRect(x:x,y:bounds.midY-5,width:10,height:10),color:ink.withAlphaComponent(0.8))}
 }
}

/// Plovoucí lišta: zavřít | celá obrazovka, výřez | odpočet ▾ (okamžitě, 3/5/10 s) | Nahrát.
final class RecordingBar:NSPanel {
 fileprivate weak var setup:RecordingSetup?
 private var screenButton:RecordingBarButton!,regionButton:RecordingBarButton!,countdownButton:RecordingBarButton!,recordButton:RecordingBarButton!
 init(setup:RecordingSetup) {
  self.setup=setup
  super.init(contentRect:NSRect(x:0,y:0,width:100,height:52),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  becomesKeyOnlyIfNeeded=false;level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+1);isOpaque=false;backgroundColor = .clear;hasShadow=true
  isReleasedWhenClosed=false;collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];appearance=NSAppearance(named:.darkAqua)
  // Tmavá podložka pod rozmazáním: lišta je čitelná i nad světlým obsahem.
  let back=NSView();back.wantsLayer=true;back.layer?.cornerRadius=14;back.layer?.masksToBounds=true
  back.layer?.backgroundColor=NSColor(white:0.1,alpha:0.82).cgColor;back.layer?.borderWidth=1;back.layer?.borderColor=NSColor.white.withAlphaComponent(0.12).cgColor
  let blur=NSVisualEffectView();blur.material = .hudWindow;blur.blendingMode = .behindWindow;blur.state = .active;blur.autoresizingMask=[.width,.height];back.addSubview(blur)
  func button(_ title:String,symbol:String?=nil,tip:String,action:Selector)->RecordingBarButton {
   let b=RecordingBarButton(title:title,target:self,action:action);b.isBordered=false
   if let symbol{b.image=NSImage(systemSymbolName:symbol,accessibilityDescription:tip)}
   b.toolTip=tip;b.setAccessibilityLabel(tip);return b
  }
  let close=button("",symbol:"xmark",tip:L("Zrušit záznam"),action:#selector(closeBar))
  screenButton=button("",symbol:"display",tip:L("Nahrát celou obrazovku"),action:#selector(chooseScreen))
  regionButton=button("",symbol:"rectangle.dashed",tip:L("Nahrát vybranou oblast"),action:#selector(chooseRegion))
  countdownButton=button("",tip:L("Délka odpočtu"),action:#selector(showCountdownMenu));countdownButton.disclosure=true
  recordButton=button(L("Nahrát"),symbol:"record.circle",tip:L("Nahrát"),action:#selector(record));recordButton.tint = .systemRed
  // Šířky textových tlačítek podle nejdelšího textu, aby lišta při přepnutí neposkakovala.
  let font=NSFont.systemFont(ofSize:13,weight:.medium)
  func width(_ texts:[String],extra:CGFloat=0)->CGFloat{ceil(texts.map{($0 as NSString).size(withAttributes:[.font:font]).width}.max() ?? 0)+24+extra}
  let items:[(NSView,CGFloat)]=[(close,34),(separator(),9),(screenButton,46),(regionButton,46),(separator(),9),(countdownButton,width([L("Okamžitě")]+RecordingLimits.countdowns.map{LF("S odpočtem %d s",$0)},extra:18)),(separator(),9),(recordButton,width([recordButton.title],extra:24))]
  var x:CGFloat=8
  for (view,w) in items{view.frame=NSRect(x:x,y:view is RecordingBarButton ? 8:14,width:w,height:view is RecordingBarButton ? 36:24);back.addSubview(view);x+=w+(view is RecordingBarButton ? 2:0)}
  setContentSize(NSSize(width:x+6,height:52));back.frame=NSRect(x:0,y:0,width:x+6,height:52);blur.frame=back.bounds;contentView=back
  back.addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.cursorUpdate,.mouseMoved,.mouseEnteredAndExited],owner:self))
 }
 private func separator()->NSView{let line=NSBox(frame:.zero);line.boxType = .custom;line.borderWidth=0;line.fillColor=NSColor.white.withAlphaComponent(0.2);line.contentViewMargins = .zero;let holder=NSView();holder.addSubview(line);line.frame=NSRect(x:4,y:0,width:1,height:24);return holder}
 // Lišta klíčová není: klávesy a kurzor obsluhuje překryv pod ní.
 override var canBecomeKey:Bool{false}
 // Nad lištou běžná šipka (překryv pod ní by jinak nechal křížek).
 override func mouseEntered(with event:NSEvent){NSCursor.arrow.set()}
 override func mouseMoved(with event:NSEvent){NSCursor.arrow.set()}
 override func cursorUpdate(with event:NSEvent){NSCursor.arrow.set()}
 func refreshBar() {
  guard let setup else{return}
  screenButton.selected=setup.target == .screen;regionButton.selected=setup.target == .region
  countdownButton.title=setup.usesCountdown ? LF("S odpočtem %d s",setup.countdownSeconds):L("Okamžitě")
  recordButton.isEnabled=setup.canStart
  recordButton.toolTip=setup.canStart ? L("Nahrát"):L("Nejdřív tažením vyber oblast.")
 }
 /// Lišta dole uprostřed vybraného displeje.
 func place(on screen:NSScreen) {
  let area=screen.visibleFrame
  setFrameOrigin(NSPoint(x:(area.midX-frame.width/2).rounded(),y:area.minY+48))
 }
 @objc private func closeBar(){setup?.dismiss()}
 @objc private func chooseScreen(){setup?.choose(.screen)}
 @objc private func chooseRegion(){setup?.choose(.region)}
 @objc private func record(){setup?.confirm()}
 @objc private func showCountdownMenu() {
  guard let setup else{return}
  let menu=NSMenu();menu.autoenablesItems=false;menu.appearance=NSAppearance(named:.darkAqua)
  // Tag 0 = okamžitě, jinak délka odpočtu v sekundách.
  for seconds in [0]+RecordingLimits.countdowns {
   let item=NSMenuItem(title:seconds == 0 ? L("Okamžitě"):LF("%d s",seconds),action:#selector(pickCountdown(_:)),keyEquivalent:"");item.target=self;item.tag=seconds
   item.state=(seconds == 0 ? !setup.usesCountdown:setup.usesCountdown && setup.countdownSeconds == seconds) ? .on:.off;menu.addItem(item)
   if seconds == 0{menu.addItem(.separator())}
  }
  menu.popUp(positioning:nil,at:NSPoint(x:0,y:countdownButton.bounds.maxY+6),in:countdownButton)
 }
 @objc private func pickCountdown(_ sender:NSMenuItem){setup?.setCountdown(enabled:sender.tag != 0,seconds:sender.tag == 0 ? nil:sender.tag)}
}
