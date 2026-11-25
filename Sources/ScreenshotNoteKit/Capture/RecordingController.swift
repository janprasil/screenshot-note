import AppKit
import ScreenCaptureKit

enum RecordingTarget:String {case screen,window,region}

/// Výřez v souřadnicích displeje pro SCStreamConfiguration.sourceRect (body, počátek vlevo nahoře).
func displaySourceRect(_ rect:CGRect,screen:CGRect)->CGRect {
 CGRect(x:rect.minX-screen.minX,y:screen.maxY-rect.maxY,width:rect.width,height:rect.height).integral
}

/// Obdélník AppKit (počátek vlevo dole) v globálních bodech Quartz (počátek vlevo nahoře hlavního displeje), celé body.
func quartzRect(_ rect:CGRect,primaryHeight:CGFloat=NSScreen.screens.first?.frame.height ?? 0)->CGRect {
 CGRect(x:rect.minX,y:primaryHeight-rect.maxY,width:rect.width,height:rect.height).integral
}

/// Výběr oblasti tažením na kterémkoli displeji (překryv na každém); Escape zruší. Výřez leží na displeji, kde tažení začalo.
final class RegionSelection {
 fileprivate var windows:[RegionSelector]=[];private var completion:((CGRect?)->Void)?
 init(screens:[NSScreen],minimum:CGFloat,completion:@escaping (CGRect?)->Void) {
  self.completion=completion
  windows=screens.map{RegionSelector(screen:$0,minimum:minimum,group:self)}
  // Bez aktivace appky: cílová aplikace si nechá fokus, popovery a vzhled aktivního okna.
  for window in windows{window.orderFrontRegardless()}
  let pointer=windows.first{$0.frame.contains(NSEvent.mouseLocation)} ?? windows.first
  pointer?.makeKeyAndOrderFront(nil)
  NSCursor.crosshair.push()
 }
 /// Zrušení zvenku (zkratka během výběru): bez volání completion.
 func cancel(){guard completion != nil else{return};completion=nil;close()}
 fileprivate func finish(_ result:CGRect?){guard let done=completion else{return};completion=nil;close();done(result)}
 private func close() {
  NSCursor.pop();for window in windows{window.orderOut(nil);window.group=nil}
  // Uvolnění až po návratu z mouseUp/keyDown, které zavření vyvolaly.
  let closed=windows;windows=[]
  DispatchQueue.main.async{withExtendedLifetime(closed){}}
 }
}
final class RegionSelector:NSPanel {
 // Okna drží výběr silně, aby přežil i bez reference volajícího; close() cyklus zruší.
 private var origin:NSPoint?;fileprivate var group:RegionSelection?;private var minimum:CGFloat=40
 private let selection=CAShapeLayer()
 @discardableResult static func choose(on screens:[NSScreen]=NSScreen.screens,minimum:CGFloat=40,_ completion:@escaping (CGRect?)->Void)->RegionSelection {
  RegionSelection(screens:screens.isEmpty ? NSScreen.screens:screens,minimum:minimum,completion:completion)
 }
 fileprivate convenience init(screen:NSScreen,minimum:CGFloat,group:RegionSelection) {
  self.init(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  becomesKeyOnlyIfNeeded=false
  self.group=group;self.minimum=minimum;level = .screenSaver;isOpaque=false;backgroundColor=NSColor.black.withAlphaComponent(0.25)
  ignoresMouseEvents=false;isReleasedWhenClosed=false;collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];acceptsMouseMovedEvents=true
  let view=CrosshairView(frame:NSRect(origin:.zero,size:screen.frame.size));view.wantsLayer=true
  selection.fillColor=NSColor.white.withAlphaComponent(0.15).cgColor;selection.strokeColor=NSColor.white.cgColor;selection.lineWidth=1.5
  view.layer?.addSublayer(selection);contentView=view;setFrame(screen.frame,display:true)
  hint=overlayHint(L("Tažením vyber oblast · Esc zruší"),size:15);view.addSubview(hint)
  hint.setFrameOrigin(NSPoint(x:(view.bounds.width-hint.frame.width)/2,y:(view.bounds.height-hint.frame.height)/2))
 }
 /// Nápověda uprostřed displeje; při tažení zmizí. Esc tu obslouží i samotný panel.
 private(set) var hint=NSView()
 override var canBecomeKey:Bool{true}
 // První klik na jiném displeji okno rovnou aktivuje a začne výběr.
 override func mouseDown(with event:NSEvent){makeKey();origin=event.locationInWindow;hint.isHidden=true;NSCursor.crosshair.set()}
 override func mouseDragged(with event:NSEvent){guard let origin else{return};NSCursor.crosshair.set();selection.path=CGPath(rect:rect(origin,event.locationInWindow),transform:nil)}
 override func mouseUp(with event:NSEvent){
  guard let origin else{return};let local=rect(origin,event.locationInWindow)
  // Kliknutí bez tažení se nepočítá; malý výřez (screenshot) je v pořádku, video si limit ohlídá samo.
  group?.finish(local.width>=minimum && local.height>=minimum ? local.offsetBy(dx:frame.minX,dy:frame.minY):nil)
 }
 override func keyDown(with event:NSEvent){if event.keyCode==53{group?.finish(nil)}else{super.keyDown(with:event)}}
 private func rect(_ a:NSPoint,_ b:NSPoint)->CGRect{
  // Tažení přes okraj se ořízne na tento displej.
  let bounds=CGRect(origin:.zero,size:frame.size),c=CGPoint(x:min(max(b.x,0),bounds.width),y:min(max(b.y,0),bounds.height))
  return CGRect(x:min(a.x,c.x),y:min(a.y,c.y),width:abs(a.x-c.x),height:abs(a.y-c.y))
 }
}

/// Nitkový kříž nad celým překryvem; aplikace není aktivní, proto bez cursor rects, jen přes tracking area.
final class CrosshairView:NSView {
 override func updateTrackingAreas() {
  super.updateTrackingAreas()
  for area in trackingAreas{removeTrackingArea(area)}
  addTrackingArea(NSTrackingArea(rect:.zero,options:[.activeAlways,.inVisibleRect,.cursorUpdate,.mouseMoved,.mouseEnteredAndExited],owner:self))
 }
 override func cursorUpdate(with event:NSEvent){NSCursor.crosshair.set()}
 // Přechod na jiný displej převezme klíčové okno (pohyb myši dostává jen klíčové okno).
 override func mouseEntered(with event:NSEvent){if window?.isKeyWindow == false{window?.makeKey()};NSCursor.crosshair.set()}
 override func mouseMoved(with event:NSEvent){NSCursor.crosshair.set()}
}

/// Štítek nepřebírá kliknutí; tažení může začít i na něm.
final class PassthroughView:NSView {override func hitTest(_ point:NSPoint)->NSView?{nil}}

/// Tmavý štítek s textem pro překryvy výběru a odpočtu.
func overlayHint(_ text:String,size:CGFloat)->NSView {
 let label=NSTextField(labelWithString:text);label.font = .systemFont(ofSize:size,weight:.medium);label.textColor = .white;label.alignment = .center
 label.sizeToFit()
 let padding=NSSize(width:18,height:10)
 let pill=PassthroughView(frame:NSRect(x:0,y:0,width:ceil(label.frame.width)+padding.width*2,height:ceil(label.frame.height)+padding.height*2))
 pill.wantsLayer=true;pill.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.7).cgColor;pill.layer?.cornerRadius=pill.frame.height/2
 label.frame.origin=NSPoint(x:padding.width,y:padding.height);pill.addSubview(label)
 pill.setAccessibilityElement(true);pill.setAccessibilityRole(.staticText);pill.setAccessibilityLabel(text)
 return pill
}

/// Odpočet uprostřed obrazovky; okno se do záznamu nedostane (filtr vynechá vlastní aplikaci).
final class CountdownOverlay {
 private var window:NSPanel?;private var timer:Timer?
 func run(seconds:Int,on screen:NSScreen,escape:Bool=true,_ done:@escaping ()->Void) {
  let size=NSSize(width:180,height:180)
  let panel=NSPanel(contentRect:NSRect(x:screen.frame.midX-size.width/2,y:screen.frame.midY-size.height/2,width:size.width,height:size.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.level = .screenSaver;panel.isOpaque=false;panel.backgroundColor = .clear;panel.ignoresMouseEvents=true;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let label=NSTextField(labelWithString:"\(seconds)");label.font=NSFont.monospacedDigitSystemFont(ofSize:96,weight:.bold);label.textColor = .white;label.alignment = .center
  label.frame=NSRect(x:0,y:42,width:size.width,height:120)
  let hint=NSTextField(labelWithString:L("Esc zruší"));hint.font = .systemFont(ofSize:13,weight:.medium);hint.textColor=NSColor.white.withAlphaComponent(0.8);hint.alignment = .center
  hint.frame=NSRect(x:0,y:22,width:size.width,height:18)
  let back=NSView(frame:NSRect(origin:.zero,size:size));back.wantsLayer=true;back.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.6).cgColor;back.layer?.cornerRadius=36
  back.addSubview(label);if escape{back.addSubview(hint)};panel.contentView=back;panel.orderFrontRegardless();window=panel
  back.setAccessibilityLabel(LF("Záznam začne za %d s",seconds))
  var left=seconds
  let tick=Timer(timeInterval:1,repeats:true){[weak self] timer in
   left-=1
   if left>0{label.stringValue="\(left)";return}
   timer.invalidate();self?.close();done()
  }
  // Odpočet běží i při otevřeném menu baru.
  RunLoop.main.add(tick,forMode:.common);timer=tick
 }
 func close(){timer?.invalidate();timer=nil;window?.orderOut(nil);window=nil}
}

/// Záznam: výběr cíle, odpočet, start a stop (zkratkou, z menu baru nebo po 60 s).
/// Volá se jen z hlavního vlákna (menu, zkratka, časovače).
final class RecordingController {
 enum State {
  case idle,preparing,counting,recording,finishing
  /// Stavy, které Esc zruší nebo zastaví.
  var stopsOnEscape:Bool{self == .preparing || self == .counting || self == .recording}
 }
 private(set) var state:State = .idle
 private var recorder:ScreenRecorder?;private var countdown:CountdownOverlay?;private var setup:RecordingSetup?;private var limit:Timer?;private var ticker:Timer?
 private(set) var startedAt:Date?
 /// Odpočet posledního záznamu v sekundách (0 = spuštěno hned).
 private(set) var countdownSeconds=0
 /// Číslo pokusu; zrušený start po await nic nenastaví.
 private var attempt=0
 /// Změna stavu pro menu bar (ikona, položka Zastavit).
 var onChange:(()->Void)?
 /// Zda je zkratka Esc zaregistrovaná; jinak nápovědy Esc nezmiňují.
 var escapeAvailable:()->Bool={false}
 /// Hotové video: výsledek, nebo chyba (zrušení = nil).
 var onFinish:((Result<RecordingResult,Error>?)->Void)?
 var elapsed:TimeInterval{startedAt.map{Date().timeIntervalSince($0)} ?? 0}

 /// Zobrazí nastavení záznamu (cíl a odpočet); po potvrzení odpočítá a začne nahrávat.
 func start(output:URL) {
  guard state == .idle else{return}
  if !CGPreflightScreenCaptureAccess(){_ = CGRequestScreenCaptureAccess();onFinish?(.failure(NSError(domain:"ScreenshotNote",code:44,userInfo:[NSLocalizedDescriptionKey:L("Povol Screenshot Note v Nastavení systému → Soukromí a zabezpečení → Záznam obrazovky a spusť záznam znovu.")])));return}
  attempt+=1;let current=attempt
  state = .preparing;onChange?()
  let setup=RecordingSetup{[weak self] choice in
   // Zastavení během nastavení už stav vrátilo.
   guard let self,self.state == .preparing,self.attempt == current else{return}
   self.setup=nil
   guard let choice else{self.reset();self.onFinish?(nil);return}
   self.countdownSeconds=choice.countdown
   self.state = .counting;self.onChange?()
   let begin={Task{@MainActor in await self.begin(choice.target,screen:choice.screen,region:choice.region,window:nil,output:output,attempt:current)}}
   if choice.countdown == 0{_ = begin();return}
   let overlay=CountdownOverlay();self.countdown=overlay
   overlay.run(seconds:choice.countdown,on:choice.screen,escape:self.escapeAvailable()){_ = begin()}
  }
  self.setup=setup;setup.show()
 }

 /// Na hlavním vlákně: stav, menu bar i chybové hlášky; await se vrací sem.
 @MainActor private func begin(_ target:RecordingTarget,screen:NSScreen,region:CGRect?,window:CGWindowID?,output:URL,attempt current:Int)async {
  guard state == .counting,attempt == current else{return}
  countdown=nil
  let live={self.state == .counting && self.attempt == current}
  do {
   let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
   let own=content.applications.filter{$0.processID==ProcessInfo.processInfo.processIdentifier}
   let displayID=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
   let scale=Double(screen.backingScaleFactor)
   let filter:SCContentFilter;var points:CGSize;var source:CGRect?
   if target == .window {
    guard let id=window,let scWindow=content.windows.first(where:{$0.windowID==id}) else{throw recordingError(L("Okno v popředí se nepodařilo najít."))}
    filter=SCContentFilter(desktopIndependentWindow:scWindow);points=scWindow.frame.size
   } else {
    guard let display=content.displays.first(where:{$0.displayID==displayID}) ?? content.displays.first else{throw recordingError(L("Obrazovku se nepodařilo najít."))}
    filter=SCContentFilter(display:display,excludingApplications:own,exceptingWindows:[])
    points=CGSize(width:display.width,height:display.height)
    if let region{source=displaySourceRect(region,screen:screen.frame);points=region.size}
   }
   let size=recordingSize(width:points.width*scale,height:points.height*scale)
   let recorder=try ScreenRecorder(output:output,width:size.width,height:size.height)
   recorder.onFailure={[weak self] _ in Task{@MainActor in self?.stop()}}
   try await recorder.begin(filter:filter,sourceRect:source)
   guard live() else{recorder.cancel();return}
   self.recorder=recorder;state = .recording;startedAt=Date();onChange?()
   // Běžné režimy run loopu: časovače běží i při otevřeném menu baru.
   let limit=Timer(timeInterval:RecordingLimits.maxDuration,repeats:false){[weak self] _ in Task{@MainActor in self?.stop()}}
   let ticker=Timer(timeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in self?.onChange?()}}
   for timer in [limit,ticker]{RunLoop.main.add(timer,forMode:.common)}
   self.limit=limit;self.ticker=ticker
  } catch {guard live() else{return};reset();onFinish?(.failure(error))}
 }

 /// Zastaví záznam nebo zruší odpočet.
 func stop() {
  switch state {
  case .counting,.preparing:countdown?.close();countdown=nil;setup?.cancel();setup=nil;reset();onFinish?(nil)
  case .recording:
   guard let recorder else{reset();return}
   // Další stop během dokončení se ignoruje; nový záznam jde až po doručení výsledku.
   self.recorder=nil;state = .finishing;limit?.invalidate();ticker?.invalidate();onChange?()
   Task{@MainActor in
    let result=await Result{try await recorder.finish()}
    self.reset();self.onFinish?(result)
   }
  case .idle,.finishing:break
  }
 }
 private func reset(){attempt+=1;state = .idle;startedAt=nil;limit?.invalidate();ticker?.invalidate();limit=nil;ticker=nil;onChange?()}
 private func recordingError(_ message:String)->NSError{NSError(domain:"ScreenshotNote",code:45,userInfo:[NSLocalizedDescriptionKey:message])}
}

extension Result where Failure == Error {
 init(_ body:() async throws->Success) async {do{self = .success(try await body())}catch{self = .failure(error)}}
}

/// Nejvyšší normální okno jiné aplikace (pořadí CGWindowList je odpředu).
func frontWindowID()->CGWindowID? {
 let own=Int(ProcessInfo.processInfo.processIdentifier)
 let windows=(CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
 for window in windows {
  guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue==0,(window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue != own,
   let bounds=(window[kCGWindowBounds as String] as? NSDictionary).flatMap({CGRect(dictionaryRepresentation:$0 as CFDictionary)}),bounds.width>=100,bounds.height>=100,
   let number=(window[kCGWindowNumber as String] as? NSNumber)?.uint32Value else{continue}
  return number
 }
 return nil
}
