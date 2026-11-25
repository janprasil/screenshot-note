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
  // 1 oblast (⌘F11), 2 celá obrazovka (⌘F12), 3 záznam videa start/stop (⌘F10); na Macu s Fn.
  let key:[Int:(UInt32,String)]=[1:(103,"F11"),2:(111,"F12"),3:(109,"F10")]
  return Shortcut(key:key[id]?.0 ?? 109,modifiers:UInt32(cmdKey),name:key[id]?.1 ?? "F10")
 }
}

/// Zkratky jako v macOS: ⇧⌘4 výřez, ⇧⌘3 celá obrazovka, ⇧⌘5 záznam videa.
let macShortcuts:[Shortcut]=[(UInt32(21),"4"),(UInt32(20),"3"),(UInt32(23),"5")].map{Shortcut(key:$0.0,modifiers:UInt32(cmdKey|shiftKey),name:$0.1)}
func usesMacShortcuts()->Bool{(1...3).allSatisfy{let s=Shortcut.load($0),m=macShortcuts[$0-1];return s.key==m.key && s.modifiers==m.modifiers}}
let keyboardSettingsURL=URL(string:"x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

/// Systémové zkratky snímků v com.apple.symbolichotkeys: 28 ⇧⌘3, 30 ⇧⌘4, 184 ⇧⌘5.
enum SystemScreenshotShortcuts {
 static let domain="com.apple.symbolichotkeys" as CFString,key="AppleSymbolicHotKeys" as CFString
 // Výchozí parametry: ASCII znak, keycode, ⇧⌘.
 static let ids:[String:[Int]]=["28":[51,20,1179648],"30":[52,21,1179648],"184":[53,23,1179648]]
 /// Záloha původních záznamů z doby převzetí; její existence znamená, že systémové zkratky drží aplikace.
 static let backupKey="systemScreenshotShortcutsBackup"
 static var backup:[String:Any]?{UserDefaults.standard.dictionary(forKey:backupKey)}
 static var takenOver:Bool{backup != nil}
 /// Současné záznamy tří zkratek; chybějící záznam znamená výchozí stav (zapnuto).
 static func snapshot()->[String:Any] {
  let all=(CFPreferencesCopyAppValue(key,domain) as? [String:Any]) ?? [:]
  return all.filter{ids[$0.key] != nil}
 }
 /// Zapne nebo vypne systémové zkratky a hned je aplikuje; false když se to nepovede.
 @discardableResult static func set(enabled:Bool)->Bool {
  write{all in
   for (id,parameters) in ids {
    var entry=all[id] as? [String:Any] ?? ["value":["parameters":parameters,"type":"standard"]]
    entry["enabled"]=enabled;all[id]=entry
   }
  }
 }
 /// Vrátí záznamy přesně podle zálohy (chybějící se smažou, systém použije výchozí).
 @discardableResult static func restore(_ saved:[String:Any])->Bool {
  write{all in for id in ids.keys{all[id]=saved[id]}}
 }
 private static func write(_ change:(inout [String:Any])->Void)->Bool {
  var all=(CFPreferencesCopyAppValue(key,domain) as? [String:Any]) ?? [:]
  change(&all)
  CFPreferencesSetAppValue(key,all as CFDictionary,domain)
  guard CFPreferencesAppSynchronize(domain) else{return false}
  let process=Process();process.executableURL=URL(fileURLWithPath:"/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings");process.arguments=["-u"]
  do{try process.run();process.waitUntilExit();return process.terminationStatus == 0}catch{return false}
 }
}

/// Zda nastavení nabízí vrácení: aplikace drží ⇧⌘4/3/5, nebo má systémové zkratky vypnuté.
func macShortcutsTakenOver()->Bool{usesMacShortcuts() || SystemScreenshotShortcuts.takenOver}

/// Převezme zkratky macOS a systémové vypne; když to nejde, vrátí předchozí stav a vrátí false.
@MainActor @discardableResult func applyMacShortcuts(_ hotkeys:Hotkeys)->Bool{
 let defaults=UserDefaults.standard,previous=(1...3).map{defaults.data(forKey:"shortcut\($0)")}
 // Záloha jen při prvním převzetí, aby vrácení obnovilo původní nastavení uživatele.
 let original=SystemScreenshotShortcuts.backup,saved=original ?? SystemScreenshotShortcuts.snapshot()
 let systemOff=SystemScreenshotShortcuts.set(enabled:false)
 if systemOff,original == nil{defaults.set(saved,forKey:SystemScreenshotShortcuts.backupKey)}
 for id in 1...3{defaults.set(try? JSONEncoder().encode(macShortcuts[id-1]),forKey:"shortcut\(id)")}
 let errors=hotkeys.register()
 if !errors.isEmpty{
  for id in 1...3{if let d=previous[id-1]{defaults.set(d,forKey:"shortcut\(id)")}else{defaults.removeObject(forKey:"shortcut\(id)")}}
  _ = hotkeys.register()
  // Systém zpět do stavu před tímto pokusem; dřívější převzetí zůstává.
  if original == nil{SystemScreenshotShortcuts.restore(saved);defaults.removeObject(forKey:SystemScreenshotShortcuts.backupKey)}
  showError(L("Zkratky ⇧⌘4, ⇧⌘3 a ⇧⌘5 se nepodařilo převzít. Ponechali jsme předchozí zkratky."));return false
 }
 // Bez vypnutí systémových zkratek by je macOS dál chytal první; pak je musí vypnout uživatel.
 if !systemOff{
  showError(L("Systémové zkratky pro snímky se nepodařilo vypnout. Vypni je v Nastavení systému → Klávesnice → Klávesové zkratky → Snímky obrazovky; otevřeme ti je."))
  if let keyboardSettingsURL{NSWorkspace.shared.open(keyboardSettingsURL)}
 }
 return true
}

/// Vrátí výchozí zkratky aplikace a systémové zkratky podle zálohy z převzetí (bez zálohy je zapne).
@MainActor func restoreMacShortcuts(_ hotkeys:Hotkeys){
 for id in 1...3{UserDefaults.standard.removeObject(forKey:"shortcut\(id)")}
 let errors=hotkeys.register()
 if !errors.isEmpty{showError(errors.joined(separator:"\n"))}
 let restored=SystemScreenshotShortcuts.backup.map{SystemScreenshotShortcuts.restore($0)} ?? SystemScreenshotShortcuts.set(enabled:true)
 if restored{UserDefaults.standard.removeObject(forKey:SystemScreenshotShortcuts.backupKey)}
 else {
  showError(L("Systémové zkratky pro snímky se nepodařilo zapnout. Zapni je v Nastavení systému → Klávesnice → Klávesové zkratky → Snímky obrazovky; otevřeme ti je."))
  if let keyboardSettingsURL{NSWorkspace.shared.open(keyboardSettingsURL)}
 }
}

/// Při prvním spuštění nabídne převzít systémové zkratky pro snímky (⇧⌘4, ⇧⌘3, ⇧⌘5); jinak vysvětlí výchozí zkratky aplikace.
@MainActor func offerSystemShortcuts(_ hotkeys:Hotkeys){
 let done="shortcutOnboardingDone",defaults=UserDefaults.standard
 guard !defaults.bool(forKey:done) else{return}
 defaults.set(true,forKey:done)
 // Jen nová instalace: kdo už má zkratky nebo složky, dialog nedostane (i s výchozími zkratkami).
 let existing=["topics","destination","defaultTopic","lastTopic"].contains{defaults.object(forKey:$0) != nil}
 guard !existing,!(1...3).contains(where:{defaults.data(forKey:"shortcut\($0)") != nil}) else{return}
 NSApp.activate(ignoringOtherApps:true)
 let alert=NSAlert();alert.messageText=L("Nahradit systémové zkratky pro snímky?")
 alert.informativeText=L("Screenshot Note může používat ⇧⌘4 pro výřez, ⇧⌘3 pro celou obrazovku a ⇧⌘5 pro záznam videa. Systémové zkratky pro snímky přitom vypneme; vrátit je můžeš v Nastavení → Klávesové zkratky.")
 alert.addButton(withTitle:L("Nahradit"));alert.addButton(withTitle:L("Ponechat výchozí"))
 if alert.runModal() == .alertFirstButtonReturn {
  applyMacShortcuts(hotkeys)
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
