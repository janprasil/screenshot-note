import AppKit

final class AboutController:NSObject {
 static let shared=AboutController()
 var window:NSWindow?
 @objc func show(){
  if let existing=window{presentScreenshotPanel(existing);return}
  let panel=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:580,height:550),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.title=L("O aplikaci");panel.isReleasedWhenClosed=false;window=panel
  let view=installDesignRoot(panel,headerHeight:220)
  let icon=NSImageView(frame:NSRect(x:250,y:424,width:80,height:80));icon.image=NSImage(contentsOfFile:Bundle.main.path(forResource:"AppIcon",ofType:"icns") ?? "");view.addSubview(icon)
  let name=designLabel("Screenshot Note",NSRect(x:28,y:374,width:524,height:38),size:28,weight:.semibold);name.alignment = .center;view.addSubview(name)
  let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "4.1"
  let versionLabel=designLabel(LF("Verze %@",version),NSRect(x:28,y:346,width:524,height:24),size:12,color:AppPalette.secondary);versionLabel.alignment = .center;view.addSubview(versionLabel)
  let subtitle=designLabel(L("Snímky, souvislosti a vaše poznámky."),NSRect(x:28,y:290,width:524,height:30),size:17,weight:.medium);subtitle.alignment = .center;view.addSubview(subtitle)
  let body=NSTextField(wrappingLabelWithString:L("Screenshot Note uchovává obraz i myšlenku pohromadě. Zachyťte obrazovku, přidejte anotace a uložte relaci jako Markdown do své složky nebo Obsidianu."))
  body.frame=NSRect(x:60,y:209,width:460,height:72);body.font = .systemFont(ofSize:13);body.textColor=AppPalette.secondary;body.alignment = .center;view.addSubview(body)
  // Tři body jako jeden blok uprostřed: ikony v jednom sloupci, texty zarovnané vlevo.
  let points=[("folder",L("Soubory na vašem Macu")),("doc.plaintext",L("Otevřený formát Markdown")),("photo.on.rectangle",L("Poznámky u každého snímku"))]
  let textWidth=points.map{ceil(($0.1 as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:12)]).width)+4}.max() ?? 0
  let left=floor((view.bounds.width-(24+12+textWidth))/2)
  for(i,entry) in points.enumerated(){
   let y=CGFloat(172-i*32);let image=NSImageView(frame:NSRect(x:left,y:y-2,width:24,height:24));image.image=NSImage(systemSymbolName:entry.0,accessibilityDescription:nil)
   image.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:15,weight:.regular);image.imageAlignment = .alignCenter;image.contentTintColor=AppPalette.accent;view.addSubview(image)
   view.addSubview(designLabel(entry.1,NSRect(x:left+36,y:y,width:textWidth,height:20),size:12))
  }
  view.addSubview(DesignDivider(NSRect(x:28,y:78,width:524,height:1)))
  view.addSubview(designLabel("Swift & AppKit · macOS 13+",NSRect(x:28,y:31,width:360,height:22),size:11,color:AppPalette.secondary))
  let done=styledButton(L("Hotovo"),role:.primary,frame:NSRect(x:432,y:24,width:120,height:34),target:self,action:#selector(close));done.keyEquivalent="\r";view.addSubview(done)
  presentScreenshotPanel(panel)
 }
 @objc func close(){window?.orderOut(nil)}
}
