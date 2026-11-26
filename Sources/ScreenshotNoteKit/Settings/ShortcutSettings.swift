import AppKit
import Carbon
import ServiceManagement

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

/// Uloží zkratku, když nekoliduje s ostatními a jde zaregistrovat; jinak ukáže chybu a vrátí false.
func assignShortcut(_ id:Int,_ candidate:Shortcut,hotkeys:Hotkeys)->Bool {
 let others=(1...3).filter{$0 != id}.map(Shortcut.load)
 guard !others.contains(where:{candidate.key == $0.key && candidate.modifiers == $0.modifiers}) else {showError(L("Tato kombinace už patří jiné zkratce."));return false}
 let old=Shortcut.load(id);UserDefaults.standard.set(try? JSONEncoder().encode(candidate),forKey:"shortcut\(id)")
 let errors=hotkeys.register()
 if !errors.isEmpty {UserDefaults.standard.set(try? JSONEncoder().encode(old),forKey:"shortcut\(id)");_ = hotkeys.register();showError(errors.joined(separator:"\n"));return false}
 return true
}

final class ShortcutSettings:NSObject,NSWindowDelegate {
 var window:NSWindow!;let hotkeys:Hotkeys
 private var shortcutButtons:[ShortcutButton]=[];private var macButton:AppButton!;private var macHint:NSTextField!
 init(hotkeys:Hotkeys){self.hotkeys=hotkeys}
 func show(){
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:620,height:500),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Klávesové zkratky");window.delegate=self
  let view=installDesignRoot(window,showClose:false)
  view.addSubview(designLabel(L("Klávesové zkratky"),NSRect(x:28,y:436,width:560,height:34),size:24,weight:.semibold))
  view.addSubview(designLabel(L("Klikněte na kombinaci a stiskněte novou."),NSRect(x:28,y:408,width:560,height:22),size:12,color:AppPalette.secondary))
  shortcutButtons=[]
  for id in 1...3 {
   let y=CGFloat(334-(id-1)*72)
   view.addSubview(designLabel([L("Vybraná oblast"),L("Celá hlavní obrazovka"),L("Záznam videa (start/stop)")][id-1],NSRect(x:28,y:y+12,width:290,height:23),size:14,weight:.medium))
   let button=ShortcutButton(frame:NSRect(x:342,y:y+4,width:250,height:38));button.shortcut=Shortcut.load(id);button.title=button.shortcut.display;button.toolTip=L("Fn může na Macu vyvolat F-klávesu; například Fn + ⌘ + F11 se zobrazí jako ⌘F11.")
   button.onChange={[weak self] candidate in
    guard let self,assignShortcut(id,candidate,hotkeys:self.hotkeys) else{return false}
    DispatchQueue.main.async{self.refresh()};return true
   };view.addSubview(button);shortcutButtons.append(button)
   view.addSubview(DesignDivider(NSRect(x:28,y:y-16,width:564,height:1)))
  }
  // Přepínač mezi zkratkami macOS (⇧⌘4/3/5) a výchozími zkratkami aplikace.
  view.addSubview(designLabel(L("Zkratky macOS"),NSRect(x:28,y:118,width:290,height:23),size:14,weight:.medium))
  macHint=designLabel("",NSRect(x:28,y:72,width:300,height:44),size:11,color:AppPalette.secondary);macHint.usesSingleLineMode=false;macHint.lineBreakMode = .byWordWrapping;macHint.maximumNumberOfLines=3;view.addSubview(macHint)
  macButton=styledButton("",role:.secondary,frame:NSRect(x:342,y:94,width:250,height:38),target:self,action:#selector(toggleMacShortcuts));view.addSubview(macButton)
  refresh()
  view.addSubview(designLabel(L("Escape zruší zadávání nové kombinace."),NSRect(x:28,y:28,width:390,height:22),size:11,color:AppPalette.secondary))
  let done=styledButton(L("Hotovo"),role:.primary,frame:NSRect(x:482,y:22,width:110,height:34),target:self,action:#selector(close));done.keyEquivalent="\r";view.addSubview(done)
  presentAppWindow(window)
  if isExportingDesign{exportDesignWindow(window,name:"shortcuts");return}
  NSApp.runModal(for:window);window.orderOut(nil)
 }
 private func refresh(){
  for (i,button) in shortcutButtons.enumerated() where !button.recording{button.shortcut=Shortcut.load(i+1);button.title=button.shortcut.display}
  let mac=macShortcutsTakenOver()
  macButton.title=mac ? L("Vrátit zkratky macOS") : L("Nahradit zkratky macOS")
  macHint.stringValue=mac ? L("⇧⌘4, ⇧⌘3 a ⇧⌘5 teď patří Screenshot Note. Vrácením se zapnou systémové zkratky a aplikace použije výchozí.") : L("Screenshot Note převezme ⇧⌘4, ⇧⌘3 a ⇧⌘5 a systémové zkratky pro snímky vypne.")
 }
 @MainActor @objc func toggleMacShortcuts(){
  if macShortcutsTakenOver(){restoreMacShortcuts(hotkeys)}else{applyMacShortcuts(hotkeys)}
  refresh();window.makeKeyAndOrderFront(nil)
 }
 @objc func close(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{close();return false}
}
