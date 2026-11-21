import AppKit
import Carbon
import ServiceManagement

// Draw semantic colors in the view's current appearance instead of freezing CGColors.
final class AdaptiveInputBackground:NSView {
 override func draw(_ dirtyRect:NSRect){let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8);AppPalette.paper.setFill();path.fill();AppPalette.stroke.setStroke();path.lineWidth=1;path.stroke()}

 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}

func drawAdaptiveSymbol(_ image:NSImage?,in rect:NSRect,color:NSColor){
 guard let image=image else{return}
 let resolved=color.usingColorSpace(.sRGB) ?? color
 let factor=min(rect.width/max(1,image.size.width),rect.height/max(1,image.size.height))
 let fitted=NSSize(width:image.size.width*factor,height:image.size.height*factor)
 let destination=NSRect(x:(rect.width-fitted.width)/2,y:(rect.height-fitted.height)/2,width:fitted.width,height:fitted.height)
 let tinted=NSImage(size:rect.size)
 tinted.lockFocus();image.draw(in:destination);resolved.setFill();NSRect(origin:.zero,size:rect.size).fill(using:.sourceIn);tinted.unlockFocus()
 tinted.draw(in:rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
}

func showError(_ message:String){NSApp.activate(ignoringOtherApps:true);let a=NSAlert();a.messageText="Screenshot Note";a.informativeText=message;a.runModal()}

func label(_ value:String,_ frame:NSRect)->NSTextField{let f=NSTextField(labelWithString:value);f.frame=frame;return f}

// Text commands are routed through the responder chain, including field editors
// and the Markdown editor's modal window.
func installEditingMenu() {
 let bar=NSMenu()
 let applicationItem=NSMenuItem();let applicationMenu=NSMenu()
 let about=NSMenuItem(title:L("O aplikaci Screenshot Note…"),action:#selector(AboutController.show),keyEquivalent:"");about.target=AboutController.shared;applicationMenu.addItem(about);applicationMenu.addItem(.separator())
 applicationMenu.addItem(withTitle:L("Ukončit Screenshot Note"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
 applicationItem.submenu=applicationMenu;bar.addItem(applicationItem)
 let item=NSMenuItem(title:L("Úpravy"),action:nil,keyEquivalent:"")
 let edit=NSMenu(title:L("Úpravy"))
 let commands:[(String,String,String,NSEvent.ModifierFlags)]=[
  (L("Zpět"),"undo:","z",.command),
  (L("Znovu"),"redo:","z",[.command,.shift]),
  (L("Vyjmout"),"cut:","x",.command),
  (L("Kopírovat"),"copy:","c",.command),
  (L("Vložit"),"paste:","v",.command),
  (L("Vybrat vše"),"selectAll:","a",.command)
 ]
 for (title,selector,key,modifiers) in commands {
  let entry=NSMenuItem(title:title,action:NSSelectorFromString(selector),keyEquivalent:key)
  entry.keyEquivalentModifierMask=modifiers;entry.target=nil;edit.addItem(entry)
 }
 item.submenu=edit;bar.addItem(item);NSApp.mainMenu=bar
}
