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

final class ShortcutSettings:NSObject,NSWindowDelegate {
 var window:NSWindow!;let hotkeys:Hotkeys
 init(hotkeys:Hotkeys){self.hotkeys=hotkeys}
 func show(){
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:620,height:340),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Klávesové zkratky");window.delegate=self
  let view=installDesignRoot(window,showClose:false)
  view.addSubview(designLabel(L("Klávesové zkratky"),NSRect(x:28,y:276,width:560,height:34),size:24,weight:.semibold))
  view.addSubview(designLabel(L("Klikněte na kombinaci a stiskněte novou."),NSRect(x:28,y:248,width:560,height:22),size:12,color:AppPalette.secondary))
  for id in 1...2 {
   let y=CGFloat(id == 1 ? 174:102)
   view.addSubview(designLabel(id == 1 ? L("Vybraná oblast"):L("Celá hlavní obrazovka"),NSRect(x:28,y:y+12,width:290,height:23),size:14,weight:.medium))
   let button=ShortcutButton(frame:NSRect(x:342,y:y+4,width:250,height:38));button.shortcut=Shortcut.load(id);button.title=button.shortcut.display;button.toolTip=L("Fn může na Macu vyvolat F-klávesu; například Fn + ⌘ + F11 se zobrazí jako ⌘F11.")
   button.onChange={[weak self] candidate in
    let other=Shortcut.load(id == 1 ? 2:1)
    guard candidate.key != other.key || candidate.modifiers != other.modifiers else {showError(L("Tato kombinace už patří druhému screenshotu."));return false}
    let old=Shortcut.load(id);UserDefaults.standard.set(try? JSONEncoder().encode(candidate),forKey:"shortcut\(id)")
    if let errors=self?.hotkeys.register(),!errors.isEmpty {UserDefaults.standard.set(try? JSONEncoder().encode(old),forKey:"shortcut\(id)");_ = self?.hotkeys.register();showError(errors.joined(separator:"\n"));return false};return true
   };view.addSubview(button)
   if id==1{view.addSubview(DesignDivider(NSRect(x:28,y:158,width:564,height:1)))}
  }
  view.addSubview(designLabel(L("Escape zruší zadávání nové kombinace."),NSRect(x:28,y:28,width:390,height:22),size:11,color:AppPalette.secondary))
  let done=styledButton(L("Hotovo"),role:.primary,frame:NSRect(x:482,y:22,width:110,height:34),target:self,action:#selector(close));done.keyEquivalent="\r";view.addSubview(done)
  presentScreenshotPanel(window)
  if isExportingDesign{exportDesignWindow(window,name:"shortcuts");return}
  NSApp.runModal(for:window);window.orderOut(nil)
 }
 @objc func close(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{close();return false}
}
