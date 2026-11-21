import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

// Přesný výřez snímku a přepočet mapy elementů z rozšíření na pixely obrázku (PROTOCOL.md, Mapování elementů).

// Hodnoty z rozšíření se omezí, aby výpočet nepřetekl do nekonečna.
private func number(_ value:Any?)->CGFloat?{(value as? NSNumber).map{CGFloat($0.doubleValue)}.flatMap{$0.isFinite && abs($0)<=1e6 ? $0:nil}}
private func rectValue(_ value:Any?)->CGRect?{
 guard let object=value as? [String:Any],let x=number(object["x"]),let y=number(object["y"]),let width=number(object["width"]),let height=number(object["height"]),width>=0,height>=0 else{return nil}
 return CGRect(x:x,y:y,width:width,height:height)
}
private func rectJSON(_ rect:CGRect)->[String:Any]{["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height]}
private func screenScale(_ id:CGDirectDisplayID)->CGFloat?{NSScreen.screens.first{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value==id}?.backingScaleFactor}
private func activeDisplays()->[CGDirectDisplayID]{
 var count:UInt32=0;CGGetActiveDisplayList(0,nil,&count)
 var ids=[CGDirectDisplayID](repeating:0,count:Int(count));CGGetActiveDisplayList(count,&ids,&count)
 return Array(ids.prefix(Int(count)))
}

/// Výřez snímku v globálních bodech (počátek vlevo nahoře), měřítko displeje a pixely obrázku na bod.
/// `browserScale` je měřítko displeje, na kterém leží většina okna prohlížeče (podle něj má stránka devicePixelRatio).
/// `window` a `webAreas` jsou okno a kandidáti na obsah stránky v okamžiku snímku; `webAreas` jen s oprávněním Accessibility.
struct CaptureGeometry:Equatable {
 var rect:CGRect,backingScale:CGFloat,imageScale:CGFloat,browserScale:CGFloat?=nil,window:CGRect?=nil,webAreas:[CGRect]=[]
 init(rect:CGRect,backingScale:CGFloat,imageScale:CGFloat,browserScale:CGFloat?=nil,window:CGRect?=nil,webAreas:[CGRect]=[]){self.rect=rect;self.backingScale=backingScale;self.imageScale=imageScale;self.browserScale=browserScale;self.window=window;self.webAreas=webAreas}
 init?(json:Any?){
  guard let object=json as? [String:Any],let rect=rectValue(object["rect"]),rect.width>0,rect.height>0,let backing=number(object["backingScale"]),backing>0,let scale=number(object["imageScale"]),scale>0 else{return nil}
  self.init(rect:rect,backingScale:backing,imageScale:scale,browserScale:number(object["browserScale"]).flatMap{$0>0 ? $0:nil},window:rectValue(object["window"]),webAreas:((object["webAreas"] as? [Any]) ?? []).prefix(16).compactMap(rectValue))
 }
 var json:[String:Any]{
  var object:[String:Any]=["rect":rectJSON(rect),"backingScale":backingScale,"imageScale":imageScale]
  if let browserScale{object["browserScale"]=browserScale};if let window{object["window"]=rectJSON(window)};if !webAreas.isEmpty{object["webAreas"]=webAreas.map(rectJSON)}
  return object
 }
 /// Geometrie celoobrazovkového snímku; obrázek jiné velikosti než displej (jiný displej, změna rozlišení) ji nemá.
 static func display(bounds:CGRect,backingScale:CGFloat,pixelSize:CGSize,browserScale:CGFloat?=nil,window:CGRect?,webAreas:[CGRect]=[])->CaptureGeometry?{
  guard bounds.width>0,bounds.height>0,pixelSize.width>0 else{return nil}
  let scale=pixelSize.width/bounds.width
  guard abs(pixelSize.height/bounds.height-scale)<0.01 else{return nil}
  return CaptureGeometry(rect:bounds,backingScale:backingScale>0 ? backingScale:scale,imageScale:scale,browserScale:browserScale,window:window,webAreas:webAreas)
 }
 /// Displej s největším překryvem okna rozhoduje o devicePixelRatio stránky.
 static func dominant(_ window:CGRect,displays:[(bounds:CGRect,scale:CGFloat)])->CGFloat?{
  displays.map{($0.scale,$0.bounds.intersection(window))}.filter{!$0.1.isNull}.max{$0.1.width*$0.1.height<$1.1.width*$1.1.height}?.0
 }
}

/// Displej celoobrazovkového snímku: `-m` je hlavní, jinak displej pod kurzorem jako `-D n` v pořadí aktivních displejů.
struct DisplayCaptureTarget {
 let id:CGDirectDisplayID,arguments:[String]
 /// Pořadí `-D` není zdokumentované; displej stejné velikosti jako jiný se proto nedá jistě určit.
 let unambiguous:Bool
 static func current(main:Bool)->DisplayCaptureTarget{
  let ids=activeDisplays()
  if main || ids.isEmpty{return DisplayCaptureTarget(id:CGMainDisplayID(),arguments:["-m"],unambiguous:true)}
  var pointer:CGDirectDisplayID=0,found:UInt32=0
  CGGetDisplaysWithPoint(CGEvent(source:nil)?.location ?? .zero,1,&pointer,&found)
  let index=found>0 ? ids.firstIndex(of:pointer) ?? 0:0,size=CGDisplayBounds(ids[index]).size
  // Hlavní displej je v obou pořadích první.
  let unique=index==0 || ids.indices.allSatisfy{$0==index || CGDisplayBounds(ids[$0]).size != size}
  return DisplayCaptureTarget(id:ids[index],arguments:["-D",String(index+1)],unambiguous:unique)
 }
 /// Geometrie podle hotového snímku; nil, když obrázek neodpovídá displeji nebo displej není jednoznačný.
 func geometry(image:URL,window:CGRect?,webAreas:[CGRect])->CaptureGeometry?{
  guard unambiguous,let source=CGImageSourceCreateWithURL(image as CFURL,nil),let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
   let width=number(properties[kCGImagePropertyPixelWidth]),let height=number(properties[kCGImagePropertyPixelHeight]) else{return nil}
  let browserScale=window.flatMap{window in CaptureGeometry.dominant(window,displays:activeDisplays().compactMap{id in screenScale(id).map{(CGDisplayBounds(id),$0)}})}
  return .display(bounds:CGDisplayBounds(id),backingScale:screenScale(id) ?? 0,pixelSize:CGSize(width:width,height:height),browserScale:browserScale,window:window,webAreas:webAreas)
 }
}

/// Kandidáti na obsah stránky (AXWebArea s webovou adresou) v okně s danými bounds; bez oprávnění Accessibility prázdné.
/// Hledá se na pozadí s krátkým limitem; dotaz může v Chromu zapnout podporu Accessibility.
func browserWebAreas(pid:pid_t,window bounds:CGRect,deadline:DispatchTime)->[CGRect]{
 guard AXIsProcessTrusted() else{return []}
 // Limit platí pro všechny prvky vrácené aplikaci, ne jen pro samotnou appku.
 AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(),0.25)
 let app=AXUIElementCreateApplication(pid);AXUIElementSetMessagingTimeout(app,0.25)
 func value(_ element:AXUIElement,_ attribute:String)->CFTypeRef?{var result:CFTypeRef?;return AXUIElementCopyAttributeValue(element,attribute as CFString,&result) == .success ? result:nil}
 func frame(_ element:AXUIElement)->CGRect?{
  guard let position=value(element,kAXPositionAttribute),let size=value(element,kAXSizeAttribute),CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID() else{return nil}
  var point=CGPoint.zero,extent=CGSize.zero
  guard AXValueGetValue(position as! AXValue,.cgPoint,&point),AXValueGetValue(size as! AXValue,.cgSize,&extent) else{return nil}
  return CGRect(origin:point,size:extent)
 }
 func near(_ a:CGRect,_ b:CGRect)->Bool{abs(a.minX-b.minX)<=2 && abs(a.minY-b.minY)<=2 && abs(a.width-b.width)<=2 && abs(a.height-b.height)<=2}
 guard let windows=value(app,kAXWindowsAttribute) as? [AXUIElement],let window=windows.first(where:{frame($0).map{near($0,bounds)} ?? false}) else{return []}
 // Do webových oblastí se nesestupuje; DevTools, postranní panely a interní stránky mají jiné schéma.
 var queue=[window],next=0,found:[CGRect]=[]
 while next<queue.count && next<600 && found.count<16 && DispatchTime.now()<deadline {
  let element=queue[next];next+=1
  if value(element,kAXRoleAttribute) as? String=="AXWebArea" {
   let scheme=(value(element,kAXURLAttribute) as? URL)?.scheme?.lowercased() ?? ""
   if ["http","https","file","about"].contains(scheme),let rect=frame(element),rect.width>0,rect.height>0,bounds.insetBy(dx:-2,dy:-2).contains(rect){found.append(rect)}
   continue
  }
  if let children=value(element,kAXChildrenAttribute) as? [AXUIElement]{queue.append(contentsOf:children)}
 }
 return found
}
/// Hledání obsahu stránky souběžně se snímkem; po snímku se vezme, co se stihlo najít.
final class WebAreaProbe:@unchecked Sendable {
 private let lock=NSLock();private var areas:[CGRect]=[]
 init?(pid:pid_t,window:CGRect){
  guard AXIsProcessTrusted() else{return nil}
  DispatchQueue.global(qos:.userInitiated).async{let found=browserWebAreas(pid:pid,window:window,deadline:.now()+0.3);self.lock.lock();self.areas=found;self.lock.unlock()}
 }
 var result:[CGRect]{lock.lock();defer{lock.unlock()};return areas}
}

/// Element z mapy v pixelech obrázku. `index` je pořadí v `elements` bundlu.
struct MappedElement:Equatable {let index:Int,selector:String,depth:Int,rect:CGRect}

/// Obsah stránky na obrazovce (globální body) a zoom stránky; nil, když se poloha nedá spolehlivě určit.
func pageContentFrame(_ geometry:[String:Any],capture:CaptureGeometry)->(frame:CGRect,zoom:CGFloat)?{
 guard let ratio=number(geometry["devicePixelRatio"]),ratio>0,let innerWidth=number(geometry["innerWidth"]),let innerHeight=number(geometry["innerHeight"]),innerWidth>0,innerHeight>0 else{return nil}
 let zoom=ratio/(capture.browserScale ?? capture.backingScale)
 guard (0.2...5).contains(zoom) else{return nil}
 let size=CGSize(width:innerWidth*zoom,height:innerHeight*zoom)
 // Z Accessibility platí jen oblast velikosti viewportu (ne postranní panel ani jiná stránka).
 if let web=capture.webAreas.first(where:{abs($0.width-size.width)<=2 && abs($0.height-size.height)<=2}){return (CGRect(origin:web.origin,size:size),zoom)}
 if let window=capture.window {
  // Obsah leží u spodního okraje přes celou šířku okna; DevTools po straně nebo jiný panel výpočet rozbijí.
  guard abs(size.width-window.width)<=2,size.height<=window.height+2 else{return nil}
  return (CGRect(x:window.minX,y:window.maxY-size.height,width:size.width,height:size.height),zoom)
 }
 // Bez okna podle PROTOCOL.md; screenX, screenY a outerHeight jsou v CSS pixelech jako zbytek geometrie.
 guard let left=number(geometry["screenX"]),let top=number(geometry["screenY"]),let outerHeight=number(geometry["outerHeight"]) else{return nil}
 return (CGRect(x:left*zoom,y:(top+outerHeight)*zoom-size.height,width:size.width,height:size.height),zoom)
}

/// Elementy v pixelech obrázku. Prvky mimo viewport nebo výřez vynechá, přesah ořízne.
func mapElements(_ context:[String:Any],capture:CaptureGeometry)->[MappedElement]{
 guard let geometry=(context["page"] as? [String:Any])?["geometry"] as? [String:Any],let content=pageContentFrame(geometry,capture:capture) else{return []}
 let viewport=geometry["visualViewport"] as? [String:Any]
 let pinch=number(viewport?["scale"]).flatMap{$0>0 ? $0:nil} ?? 1,offsetX=number(viewport?["offsetLeft"]) ?? 0,offsetY=number(viewport?["offsetTop"]) ?? 0
 let visible=content.frame.intersection(capture.rect)
 guard !visible.isNull else{return []}
 var result:[MappedElement]=[]
 for (index,element) in ((context["elements"] as? [[String:Any]]) ?? []).enumerated() {
  guard let css=rectValue(element["rect"]),css.width>0,css.height>0 else{continue}
  let scale=pinch*content.zoom
  let screen=CGRect(x:content.frame.minX+(css.minX-offsetX)*scale,y:content.frame.minY+(css.minY-offsetY)*scale,width:css.width*scale,height:css.height*scale).intersection(visible)
  guard !screen.isNull,screen.width>=0.5,screen.height>=0.5 else{continue}
  let pixels=CGRect(x:(screen.minX-capture.rect.minX)*capture.imageScale,y:(screen.minY-capture.rect.minY)*capture.imageScale,width:screen.width*capture.imageScale,height:screen.height*capture.imageScale)
  result.append(MappedElement(index:index,selector:element["selector"] as? String ?? "",depth:(element["depth"] as? NSNumber)?.intValue ?? 0,rect:pixels))
 }
 return result
}
/// Mapa elementů ze souboru kontextu; bez uložené geometrie výřezu (výběr oblasti) je prázdná.
func mapElements(contextFile:URL)->[MappedElement]{
 guard let size=(try? fm.attributesOfItem(atPath:contextFile.path))?[.size] as? NSNumber,size.intValue<=maxContextBytes,let data=try? Data(contentsOf:contextFile),
  let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let capture=CaptureGeometry(json:object["capture"]) else{return []}
 return mapElements(object,capture:capture)
}

/// Ladicí kopie snímku s obdélníky elementů: `defaults write cz.janprasil.screenshotnote BrowserContextDebugElements -bool true`.
enum ElementDebug {
 static var enabled:Bool{UserDefaults.standard.bool(forKey:"BrowserContextDebugElements")}
 static var folder:URL{fm.temporaryDirectory.appendingPathComponent("ScreenshotNote-elements",isDirectory:true)}
 /// Vykreslí obdélníky do kopie obrázku ve `folder`; originál se nemění.
 @discardableResult static func render(image:URL,elements:[MappedElement],to folder:URL=folder)->URL?{
  guard let source=CGImageSourceCreateWithURL(image as CFURL,nil),let picture=CGImageSourceCreateImageAtIndex(source,0,nil),
   let context=CGContext(data:nil,width:picture.width,height:picture.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
  let height=CGFloat(picture.height)
  context.draw(picture,in:CGRect(x:0,y:0,width:picture.width,height:picture.height))
  context.setLineWidth(2)
  for element in elements {
   // Hloubka střídá barvy, aby šlo rozlišit vnořené prvky.
   let hue=CGFloat(element.depth%6)/6
   context.setStrokeColor(NSColor(calibratedHue:hue,saturation:0.9,brightness:0.9,alpha:0.9).cgColor)
   context.stroke(CGRect(x:element.rect.minX,y:height-element.rect.maxY,width:element.rect.width,height:element.rect.height).insetBy(dx:1,dy:1))
  }
  guard let output=context.makeImage() else{return nil}
  // Kopie snímku jsou jen pro vlastníka a po dni se mažou.
  try? fm.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try? fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:folder.path)
  for old in (try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] where ((try? old.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast)<Date(timeIntervalSinceNow:-86400){try? fm.removeItem(at:old)}
  let url=folder.appendingPathComponent(image.deletingPathExtension().lastPathComponent+"-elements.png")
  guard let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{return nil}
  CGImageDestinationAddImage(destination,output,nil)
  guard CGImageDestinationFinalize(destination) else{return nil}
  try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  return url
 }
}
