import AppKit
import ScreenCaptureKit

enum RecordingTarget:String {case screen,window,region}

/// Výřez v souřadnicích displeje pro SCStreamConfiguration.sourceRect (body, počátek vlevo nahoře).
func displaySourceRect(_ rect:CGRect,screen:CGRect)->CGRect {
 CGRect(x:rect.minX-screen.minX,y:screen.maxY-rect.maxY,width:rect.width,height:rect.height).integral
}

/// Výběr oblasti tažením přes obrazovku pod kurzorem; Escape zruší.
final class RegionSelector:NSWindow {
 private var origin:NSPoint?;private var completion:((CGRect?)->Void)?
 private let selection=CAShapeLayer()
 @discardableResult static func choose(on screen:NSScreen,_ completion:@escaping (CGRect?)->Void)->RegionSelector {
  let window=RegionSelector(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
  window.completion=completion;window.level = .screenSaver;window.isOpaque=false;window.backgroundColor=NSColor.black.withAlphaComponent(0.25)
  window.ignoresMouseEvents=false;window.isReleasedWhenClosed=false;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let view=NSView(frame:NSRect(origin:.zero,size:screen.frame.size));view.wantsLayer=true
  window.selection.fillColor=NSColor.white.withAlphaComponent(0.15).cgColor;window.selection.strokeColor=NSColor.white.cgColor;window.selection.lineWidth=1.5
  view.layer?.addSublayer(window.selection);window.contentView=view
  window.setFrame(screen.frame,display:true);NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
  NSCursor.crosshair.push()
  return window
 }
 /// Zrušení zvenku (zkratka během výběru): bez volání completion.
 func cancel(){guard completion != nil else{return};completion=nil;NSCursor.pop();orderOut(nil)}
 override var canBecomeKey:Bool{true}
 override func mouseDown(with event:NSEvent){origin=event.locationInWindow}
 override func mouseDragged(with event:NSEvent){guard let origin else{return};selection.path=CGPath(rect:rect(origin,event.locationInWindow),transform:nil)}
 override func mouseUp(with event:NSEvent){
  guard let origin else{return};let local=rect(origin,event.locationInWindow)
  finish(local.width>=40 && local.height>=40 ? local.offsetBy(dx:frame.minX,dy:frame.minY):nil)
 }
 override func keyDown(with event:NSEvent){if event.keyCode==53{finish(nil)}else{super.keyDown(with:event)}}
 private func rect(_ a:NSPoint,_ b:NSPoint)->CGRect{CGRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))}
 private func finish(_ result:CGRect?){guard let done=completion else{return};completion=nil;NSCursor.pop();orderOut(nil);done(result)}
}

/// Odpočet uprostřed obrazovky; okno se do záznamu nedostane (filtr vynechá vlastní aplikaci).
final class CountdownOverlay {
 private var window:NSPanel?;private var timer:Timer?
 func run(seconds:Int,on screen:NSScreen,_ done:@escaping ()->Void) {
  let size=NSSize(width:180,height:180)
  let panel=NSPanel(contentRect:NSRect(x:screen.frame.midX-size.width/2,y:screen.frame.midY-size.height/2,width:size.width,height:size.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.level = .screenSaver;panel.isOpaque=false;panel.backgroundColor = .clear;panel.ignoresMouseEvents=true;panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
  let label=NSTextField(labelWithString:"\(seconds)");label.font=NSFont.monospacedDigitSystemFont(ofSize:96,weight:.bold);label.textColor = .white;label.alignment = .center
  label.frame=NSRect(x:0,y:30,width:size.width,height:120)
  let back=NSView(frame:NSRect(origin:.zero,size:size));back.wantsLayer=true;back.layer?.backgroundColor=NSColor.black.withAlphaComponent(0.6).cgColor;back.layer?.cornerRadius=36
  back.addSubview(label);panel.contentView=back;panel.orderFrontRegardless();window=panel
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
 enum State {case idle,preparing,counting,recording,finishing}
 private(set) var state:State = .idle
 private var recorder:ScreenRecorder?;private var countdown:CountdownOverlay?;private var selector:RegionSelector?;private var limit:Timer?;private var ticker:Timer?
 private(set) var startedAt:Date?
 /// Číslo pokusu; zrušený start po await nic nenastaví.
 private var attempt=0
 /// Změna stavu pro menu bar (ikona, položka Zastavit).
 var onChange:(()->Void)?
 /// Hotové video: výsledek, nebo chyba (zrušení = nil).
 var onFinish:((Result<RecordingResult,Error>?)->Void)?
 var elapsed:TimeInterval{startedAt.map{Date().timeIntervalSince($0)} ?? 0}

 func start(_ target:RecordingTarget,output:URL) {
  guard state == .idle else{return}
  if !CGPreflightScreenCaptureAccess(){_ = CGRequestScreenCaptureAccess();onFinish?(.failure(NSError(domain:"ScreenshotNote",code:44,userInfo:[NSLocalizedDescriptionKey:L("Povol Screenshot Note v Nastavení systému → Soukromí a zabezpečení → Záznam obrazovky a spusť záznam znovu.")])));return}
  let screen=NSScreen.screens.first{$0.frame.contains(NSEvent.mouseLocation)} ?? NSScreen.main ?? NSScreen.screens[0]
  // Okno v popředí se určí hned, než odpočet nebo výběr oblasti změní pořadí oken.
  let front=target == .window ? frontWindowID():nil
  attempt+=1;let current=attempt
  state = .preparing;onChange?()
  let proceed={(region:CGRect?) in
   // Zastavení během výběru oblasti už stav vrátilo.
   guard self.state == .preparing,self.attempt == current else{return}
   if target == .region && region == nil{self.reset();self.onFinish?(nil);return}
   self.state = .counting;self.onChange?()
   let overlay=CountdownOverlay();self.countdown=overlay
   overlay.run(seconds:recordingCountdown,on:screen){Task{@MainActor in await self.begin(target,screen:screen,region:region,window:front,output:output,attempt:current)}}
  }
  if target == .region{selector=RegionSelector.choose(on:screen){[weak self] region in self?.selector=nil;proceed(region)}}else{proceed(nil)}
 }

 private func begin(_ target:RecordingTarget,screen:NSScreen,region:CGRect?,window:CGWindowID?,output:URL,attempt current:Int)async {
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
  case .counting,.preparing:countdown?.close();countdown=nil;selector?.cancel();selector=nil;reset();onFinish?(nil)
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
