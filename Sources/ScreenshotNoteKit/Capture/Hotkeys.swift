import AppKit
import Carbon
import ServiceManagement

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
  // 1 oblast (⌃⌥⇧4), 2 celá obrazovka (⌃⌥⇧3), 3 záznam videa start/stop (⌃⌥⇧5).
  let key:[Int:(UInt32,String)]=[1:(21,"4"),2:(20,"3"),3:(23,"5")]
  return Shortcut(key:key[id]?.0 ?? 23,modifiers:UInt32(controlKey|optionKey|shiftKey),name:key[id]?.1 ?? "5")
 }
}

/// Při prvním spuštění nabídne převzít systémové zkratky pro snímky (⇧⌘4, ⇧⌘3, ⇧⌘5); jinak vysvětlí výchozí zkratky aplikace.
@MainActor func offerSystemShortcuts(_ hotkeys:Hotkeys){
 let done="shortcutOnboardingDone",defaults=UserDefaults.standard
 guard !defaults.bool(forKey:done) else{return}
 defaults.set(true,forKey:done)
 // Kdo už si zkratky nastavil, dialog nedostane.
 guard !(1...3).contains(where:{defaults.data(forKey:"shortcut\($0)") != nil}) else{return}
 NSApp.activate(ignoringOtherApps:true)
 let alert=NSAlert();alert.messageText=L("Nahradit systémové zkratky pro snímky?")
 alert.informativeText=L("Screenshot Note může používat ⇧⌘4 pro výřez, ⇧⌘3 pro celou obrazovku a ⇧⌘5 pro záznam videa. Systémové zkratky pak vypni v Nastavení systému → Klávesnice → Klávesové zkratky → Snímky obrazovky; otevřeme ti je.")
 alert.addButton(withTitle:L("Nahradit"));alert.addButton(withTitle:L("Ponechat výchozí"))
 if alert.runModal() == .alertFirstButtonReturn {
  let mods=UInt32(cmdKey|shiftKey)
  for (id,key,name) in [(1,UInt32(21),"4"),(2,UInt32(20),"3"),(3,UInt32(23),"5")]{defaults.set(try? JSONEncoder().encode(Shortcut(key:key,modifiers:mods,name:name)),forKey:"shortcut\(id)")}
  let errors=hotkeys.register();if !errors.isEmpty{showError(errors.joined(separator:"\n"))}
  if let url=URL(string:"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"){NSWorkspace.shared.open(url)}
 } else {
  let info=NSAlert();info.messageText=L("Výchozí zkratky Screenshot Note")
  info.informativeText=LF("%@ výřez, %@ celá obrazovka, %@ záznam videa. Změníš je v Nastavení → Klávesové zkratky.",Shortcut.load(1).display,Shortcut.load(2).display,Shortcut.load(3).display)
  info.addButton(withTitle:L("Rozumím"));info.runModal()
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
  for id in 1...3 {let s=Shortcut.load(id)
   // Výchozí zkratka videa, kterou už má uživatel u screenshotu, se jen neregistruje.
   if id == 3,UserDefaults.standard.data(forKey:"shortcut3") == nil,(1...2).map(Shortcut.load).contains(where:{$0.key==s.key && $0.modifiers==s.modifiers}){continue}
   var ref:EventHotKeyRef?;let status=RegisterEventHotKey(s.key,s.modifiers,EventHotKeyID(signature:0x53434E54,id:UInt32(id)),GetApplicationEventTarget(),0,&ref)
   // Nenastavená výchozí zkratka videa chybu nehlásí (jinak by blokovala i změny screenshotů).
   if status == noErr,let ref=ref {refs.append(ref);registered.insert(id)} else if id == 3,UserDefaults.standard.data(forKey:"shortcut3") == nil {continue} else {errors.append(LF("Zkratka %@ je již obsazená. Změň ji v nastavení.",s.display))}
  }
  monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown){[weak self] event in
   guard let self,NSApp.keyWindow is ScreenshotPanel else{return event}
   if let button=NSApp.keyWindow?.firstResponder as? ShortcutButton,button.recording{return event}
   guard let id=(1...3).first(where:{self.registered.contains($0) && Shortcut.load($0).matches(event)}) else{return event}
   if !event.isARepeat{self.trigger(id)}
   return nil
  }
  return errors
 }
 /// Dočasná zkratka Esc (id 4) během výběru oblasti, odpočtu a záznamu; register() ji nemaže.
 static let escapeID=4
 private var escapeRef:EventHotKeyRef?
 var escapeActive:Bool{escapeRef != nil}
 @discardableResult func setEscape(_ on:Bool)->Bool {
  if on == escapeActive{return true}
  if !on{if let ref=escapeRef{UnregisterEventHotKey(ref)};escapeRef=nil;return true}
  var ref:EventHotKeyRef?
  let status=RegisterEventHotKey(53,0,EventHotKeyID(signature:0x53434E54,id:UInt32(Self.escapeID)),GetApplicationEventTarget(),0,&ref)
  if status == noErr{escapeRef=ref}
  return escapeActive
 }
 deinit{setEscape(false);if let monitor{NSEvent.removeMonitor(monitor)};for r in refs{UnregisterEventHotKey(r)};if let h=handler{RemoveEventHandler(h)}}
}
