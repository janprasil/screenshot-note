import AppKit
import Carbon
import ServiceManagement

final class SettingsController:NSObject {
 var window:NSWindow!;let login=NSSwitch();let browserBridge=NSSwitch()
 var hotkeys:Hotkeys
 let topicSettings=TopicSettings()
 init(hotkeys:Hotkeys){self.hotkeys=hotkeys}
 func show(){if let w=window{presentScreenshotPanel(w);return}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:660,height:512),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Nastavení");window.isReleasedWhenClosed=false
  let view=installDesignRoot(window,headerHeight:112)
  if let icon=NSImage(contentsOfFile:Bundle.main.path(forResource:"AppIcon",ofType:"icns") ?? ""){let logo=NSImageView(frame:NSRect(x:28,y:428,width:46,height:46));logo.image=icon;view.addSubview(logo)}
  view.addSubview(designLabel("Screenshot Note",NSRect(x:88,y:448,width:500,height:31),size:24,weight:.semibold))
  view.addSubview(designLabel(L("Nastavení")+" · "+(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "4.1"),NSRect(x:88,y:424,width:500,height:22),size:12,color:AppPalette.secondary))
  for (symbol,title,detail,y) in [("folder",L("Složky"),L("Složky a způsob ukládání poznámek."),CGFloat(334)),("keyboard",L("Klávesové zkratky"),L("Rychlý přístup ke snímání obrazovky."),CGFloat(252)),("power",L("Spuštění po přihlášení"),L("Ikona a zkratky budou připravené po startu."),CGFloat(170)),("globe",L("Propojení s prohlížečem"),L("Rozšíření pro Chrome přikládá ke snímku kontext stránky."),CGFloat(88))]{
   let badge=DesignSurface(frame:NSRect(x:28,y:y+4,width:38,height:38),fill:AppPalette.accent.withAlphaComponent(0.1),radius:11);view.addSubview(badge);let image=NSImageView(frame:NSRect(x:9,y:9,width:20,height:20));image.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);image.contentTintColor=AppPalette.accent;badge.addSubview(image)
   view.addSubview(designLabel(title,NSRect(x:78,y:y+24,width:325,height:23),size:14,weight:.medium))
   view.addSubview(designLabel(detail,NSRect(x:78,y:y+2,width:330,height:20),size:11,color:AppPalette.secondary))
  }
  let topics=styledButton(L("Spravovat…"),frame:NSRect(x:486,y:342,width:146,height:34),target:self,action:#selector(showTopics));view.addSubview(topics)
  let shortcuts=styledButton(L("Změnit klávesové zkratky…"),frame:NSRect(x:410,y:260,width:222,height:34),target:self,action:#selector(showShortcuts));view.addSubview(shortcuts)
  for y in [CGFloat(318),236,154]{view.addSubview(DesignDivider(NSRect(x:78,y:y,width:554,height:1)))}
  login.frame=NSRect(x:584,y:184,width:48,height:28);login.target=self;login.action=#selector(toggleLogin);login.state=SMAppService.mainApp.status == .enabled ? .on:.off;view.addSubview(login)
  browserBridge.frame=NSRect(x:584,y:102,width:48,height:28);browserBridge.target=self;browserBridge.action=#selector(toggleBrowserBridge);browserBridge.state=NativeHostRegistration.isEnabled ? .on:.off;view.addSubview(browserBridge)
  view.addSubview(designLabel(L("Zavřením okna zůstane aplikace v systémové liště."),NSRect(x:28,y:24,width:440,height:22),size:11,color:AppPalette.secondary))
  let about=styledButton(L("O aplikaci"),symbol:"info.circle",role:.quiet,frame:NSRect(x:492,y:20,width:140,height:32),target:self,action:#selector(showAbout));view.addSubview(about)
  presentScreenshotPanel(window)
 }
 @objc func showAbout(){AboutController.shared.show()}
 @objc func toggleBrowserBridge(){
  do{
   let browsers=try NativeHostRegistration.setEnabled(browserBridge.state == .on)
   if browserBridge.state == .on && browsers==0{showError(L("Nenašel jsem Chrome, Edge, Brave, Arc ani Chromium. Propojení se zapíše, až prohlížeč nainstaluješ a znovu spustíš appku."))}
  }catch{showError(error.localizedDescription)}
  browserBridge.state=NativeHostRegistration.isEnabled ? .on:.off
 }
 @objc func showShortcuts(){let dialog=ShortcutSettings(hotkeys:hotkeys);dialog.show()}
 @objc func showTopics(){topicSettings.show()}
 @objc func toggleLogin(){do {if login.state == .on{try SMAppService.mainApp.register()}else{try SMAppService.mainApp.unregister()}
   if SMAppService.mainApp.status == .requiresApproval{SMAppService.openSystemSettingsLoginItems()}
  }catch{showError(error.localizedDescription)}
  login.state=SMAppService.mainApp.status == .enabled ? .on:.off
 }
}
