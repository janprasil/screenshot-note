import AppKit
import CoreGraphics
import os

// Diagnostika kontextu: jen geometrie a důvody, žádné adresy ani titulky (NSLog by obsah skryl jako <private>).
let contextLog=Logger(subsystem:"cz.janprasil.screenshotnote",category:"context")

// Kontext z prohlížeče ke snímku: cíl okna, souběžná žádost, soubory vedle obrázku a souhrn do Markdownu.
let chromiumBundleIDs:Set<String>=["com.google.Chrome","com.google.Chrome.beta","com.google.Chrome.canary","com.microsoft.edgemac","com.brave.Browser","company.thebrowser.Browser","org.chromium.Chromium"]
// Bundle má v rozšíření strop 16 MiB; po přeserializování může mírně narůst.
let maxContextBytes=32<<20

/// Soubory kontextu v pracovní složce: `<obrázek>.context.json` a `<obrázek>.har`.
func contextSidecars(_ image:URL)->[URL]{[image.appendingPathExtension("context.json"),image.appendingPathExtension("har")]}
/// Soubory kontextu v assets/: `<název>.context.json` a `<název>.har` vedle `<název>.png`.
func assetContextFiles(_ assets:URL,_ image:String)->[URL]{let base=(image as NSString).deletingPathExtension;return [assets.appendingPathComponent(base+".context.json"),assets.appendingPathComponent(base+".har")]}

/// Okno prohlížeče v popředí: proces, bounds a cíl pro capture.request.
struct BrowserWindow {
 let pid:pid_t,target:[String:Any]
 var bounds:CGRect?{guard let b=target["windowBounds"] as? [String:CGFloat],let x=b["x"],let y=b["y"],let width=b["width"],let height=b["height"] else{return nil};return CGRect(x:x,y:y,width:width,height:height)}
}
/// Cíl pro capture.request, když je v popředí Chromium prohlížeč; jinak nil.
func browserCaptureTarget()->[String:Any]?{browserCaptureWindow()?.target}
func browserCaptureWindow()->BrowserWindow? {
 let own=ProcessInfo.processInfo.processIdentifier
 let windows=(CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
 var app=NSWorkspace.shared.frontmostApplication
 // Při otevřeném komposeru je v popředí appka sama; rozhoduje nejvyšší cizí okno.
 if app?.processIdentifier==own,let pid=windows.lazy.filter({windowNumber($0,kCGWindowLayer)==0}).compactMap({windowNumber($0,kCGWindowOwnerPID)}).first(where:{$0 != Int(own)}){app=NSRunningApplication(processIdentifier:pid_t(pid))}
 guard let app,let id=app.bundleIdentifier,chromiumBundleIDs.contains(id) else{contextLog.notice("front app \(app?.bundleIdentifier ?? "none", privacy: .public) is not a supported browser");return nil}
 let target=captureTarget(windows:windows,pid:app.processIdentifier)
 // Diagnostika kontextu (fullscreen): jen geometrie, žádné adresy ani titulky.
 let screens=displayBounds().map{"\(Int($0.width))x\(Int($0.height))@\(Int($0.minX)),\(Int($0.minY))"}.joined(separator:" ")
 if let b=target?["windowBounds"] as? [String:CGFloat]{contextLog.notice("browser window \(Int(b["x"] ?? 0), privacy: .public),\(Int(b["y"] ?? 0), privacy: .public) \(Int(b["width"] ?? 0), privacy: .public)x\(Int(b["height"] ?? 0), privacy: .public), displays \(screens, privacy: .public)")}
 else{contextLog.notice("no browser window found for \(id, privacy: .public), displays \(screens, privacy: .public)")}
 return target.map{BrowserWindow(pid:app.processIdentifier,target:$0)}
}
private func windowNumber(_ window:[String:Any],_ key:CFString)->Int?{(window[key as String] as? NSNumber)?.intValue}
/// Displeje v souřadnicích oken (počátek vlevo nahoře hlavního displeje).
func displayBounds()->[CGRect]{
 var count:UInt32=0;guard CGGetActiveDisplayList(0,nil,&count) == .success,count>0 else{return []}
 var ids=[CGDirectDisplayID](repeating:0,count:Int(count));guard CGGetActiveDisplayList(count,&ids,&count) == .success else{return []}
 return ids.prefix(Int(count)).map{CGDisplayBounds($0)}
}
/// Nejvyšší běžné okno procesu (vrstva 0) v bodech s počátkem vlevo nahoře.
func captureTarget(windows:[[String:Any]],pid:pid_t,screens:[CGRect]=displayBounds())->[String:Any]? {
 let own=windows.filter{windowNumber($0,kCGWindowLayer)==0 && windowNumber($0,kCGWindowOwnerPID)==Int(pid)}
 func bounds(_ window:[String:Any])->CGRect?{(window[kCGWindowBounds as String] as? NSDictionary).flatMap{CGRect(dictionaryRepresentation:$0 as CFDictionary)}}
 for window in own {
  guard var rect=bounds(window),rect.width>=100,rect.height>=100 else{continue}
  // Celá obrazovka: Chrome okno rozdělí na pruhy, které pokryjí displej (nahoře může chybět pruh pod výřezem kamery); jeho okno (chrome.windows, window.screenY) je největší pruh s obsahem.
  if let screen=screens.first(where:{$0.contains(CGPoint(x:rect.midX,y:rect.midY))}) {
   let parts=own.compactMap(bounds).filter{screen.insetBy(dx:-1,dy:-1).contains($0)}
   let union=parts.reduce(CGRect.null){$0.union($1)}
   if rect.width>=screen.width-1,parts.count>1,union.minY-screen.minY<=64,union.minY>=screen.minY-1,abs(union.maxY-screen.maxY)<=1,abs(union.width-screen.width)<=1,let content=parts.max(by:{$0.width*$0.height<$1.width*$1.height}){rect=content}
  }
  var target:[String:Any]=["windowBounds":["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height]]
  if let title=window[kCGWindowName as String] as? String,!title.isEmpty{target["windowTitle"]=title}
  return target
 }
 return nil
}

/// Bundle pochází z okna s danými bounds (tolerance 8 bodů, zoom stránky přepočte měřítko geometrie).
func bundleMatches(_ data:Data,bounds:[String:CGFloat]?)->Bool {
 guard let bounds else{return true}
 guard let x=bounds["x"],let y=bounds["y"],let width=bounds["width"],let height=bounds["height"],width>0,
  let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let geometry=(object["page"] as? [String:Any])?["geometry"] as? [String:Any] else{return false}
 func value(_ key:String)->CGFloat?{(geometry[key] as? NSNumber).map{CGFloat($0.doubleValue)}}
 guard let left=value("screenX"),let top=value("screenY"),let outerWidth=value("outerWidth"),let outerHeight=value("outerHeight"),outerWidth>0 else{return false}
 let scale=width/outerWidth
 guard (0.2...5).contains(scale) else{return false}
 let ok=abs(left*scale-x)<=8 && abs(top*scale-y)<=8 && abs(outerHeight*scale-height)<=8
 if !ok{contextLog.notice("bundle geometry \(Int(left), privacy: .public),\(Int(top), privacy: .public) \(Int(outerWidth), privacy: .public)x\(Int(outerHeight), privacy: .public) does not match window \(Int(x), privacy: .public),\(Int(y), privacy: .public) \(Int(width), privacy: .public)x\(Int(height), privacy: .public)")}
 return ok
}
/// Bundle rozdělený na kontext bez HAR a samotný HAR.
struct CaptureContextFiles {
 let context:Data;let har:Data?
 init?(bundle:Data){
  guard bundle.count<=maxContextBytes,var object=(try? JSONSerialization.jsonObject(with:bundle)) as? [String:Any],object["format"] as? String=="screenshot-note-context",(object["version"] as? NSNumber)?.intValue==1 else{return nil}
  let har=object.removeValue(forKey:"har") as? [String:Any]
  // Geometrii výřezu doplňuje jen Mac, ne rozšíření.
  object.removeValue(forKey:"capture");object.removeValue(forKey:"elementsOutsideCapture")
  guard let context=try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]) else{return nil}
  self.context=context;self.har=har.flatMap{try? JSONSerialization.data(withJSONObject:$0,options:[.withoutEscapingSlashes])}
 }
 private init(context:Data,har:Data?){self.context=context;self.har=har}
 /// Jen elementy viditelné ve výřezu (mapa podle geometrie); bez geometrie nebo mapy beze změny.
 /// Pořadí zůstává, index v anotacích pak odpovídá novému seznamu.
 func restrictingElements(to capture:CaptureGeometry?)->CaptureContextFiles{
  guard let capture,var object=(try? JSONSerialization.jsonObject(with:context)) as? [String:Any],let elements=object["elements"] as? [Any],!elements.isEmpty,
   // Nejistá poloha obsahu stránky (např. DevTools bez Accessibility) není důkaz, že elementy leží mimo výřez.
   let geometry=(object["page"] as? [String:Any])?["geometry"] as? [String:Any],pageContentFrame(geometry,capture:capture) != nil else{return self}
  let visible=Set(mapElements(object,capture:capture).map(\.index))
  guard visible.count<elements.count else{return self}
  object["elements"]=elements.enumerated().filter{visible.contains($0.offset)}.map(\.element)
  // Kolik elementů leželo mimo výřez (vlastní klíč; `trimmed` znamená ořez kvůli velikosti).
  object["elementsOutsideCapture"]=elements.count-visible.count
  guard let data=try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]) else{return self}
  return CaptureContextFiles(context:data,har:har)
 }
 /// Kontext s geometrií výřezu pod klíčem `capture`. Velký objekt se znovu neparsuje, klíč se vloží na začátek.
 func attaching(_ capture:CaptureGeometry?)->CaptureContextFiles{
  // Prázdný objekt by po vložení skončil čárkou.
  guard let capture,context.first==UInt8(ascii:"{"),let body=context.dropFirst().first(where:{!" \n\r\t".utf8.contains($0)}),body != UInt8(ascii:"}"),let extra=try? JSONSerialization.data(withJSONObject:["capture":capture.json],options:[.sortedKeys]) else{return self}
  return CaptureContextFiles(context:extra.dropLast()+Data(",".utf8)+context.dropFirst(),har:har)
 }
 /// Zapíše soubory vedle obrázku v pracovní složce, čitelné jen pro vlastníka.
 func write(besides image:URL)throws{
  let sides=contextSidecars(image)
  do{
   // Soubor vzniká rovnou s 0600, ne až po zápisu.
   for (data,url) in zip([context,har],sides){guard let data else{continue};try? fm.removeItem(at:url);guard fm.createFile(atPath:url.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw CloudFailure(L("Kontext z prohlížeče se nepodařilo uložit."))}}
  }catch{for url in sides{try? fm.removeItem(at:url)};throw error}
 }
}

/// Politika kontextu lokální složky. Rozšíření z ní smí redakci jen přidat; cookies a autorizační hlavičky skryje vždy.
struct ContextPolicy:Codable,Equatable {
 var enabled=true,includeConsole=true,includeNetwork=true,includeElements=true,includeElementText=true,includeBodies=false
 var redactHeaders:[String]=[],redactQueryParams:[String]=[]
 init(){}
 // Chybějící nebo poškozené pole dostane výchozí hodnotu, aby nespadl celý seznam složek.
 init(from decoder:Decoder)throws{
  // Jiný tvar než objekt (starší nebo novější verze) znamená výchozí politiku.
  guard let c=try? decoder.container(keyedBy:CodingKeys.self) else{return}
  let d=ContextPolicy()
  func flag(_ key:CodingKeys,_ fallback:Bool)->Bool{((try? c.decodeIfPresent(Bool.self,forKey:key)) ?? nil) ?? fallback}
  func list(_ key:CodingKeys)->[String]{Self.names(((try? c.decodeIfPresent([String].self,forKey:key)) ?? nil) ?? [])}
  enabled=flag(.enabled,d.enabled);includeConsole=flag(.includeConsole,d.includeConsole);includeNetwork=flag(.includeNetwork,d.includeNetwork)
  includeElements=flag(.includeElements,d.includeElements);includeElementText=flag(.includeElementText,d.includeElementText);includeBodies=flag(.includeBodies,d.includeBodies)
  redactHeaders=list(.redactHeaders);redactQueryParams=list(.redactQueryParams)
 }
 /// Jména ze seznamu oddělená čárkou nebo řádkem; bez prázdných a duplicit, limity jako v rozšíření.
 static func names(_ values:[String])->[String]{
  var result:[String]=[]
  for value in values.flatMap({$0.components(separatedBy:CharacterSet(charactersIn:",;").union(.newlines))}) {
   let name=value.trimmingCharacters(in:.whitespaces)
   if !name.isEmpty,name.count<=200,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),!result.contains(where:{$0.caseInsensitiveCompare(name) == .orderedSame}){result.append(name)}
   if result.count==200{break}
  }
  return result
 }
 /// `CapturePolicy` pro capture.request podle PROTOCOL.md.
 var protocolJSON:[String:Any]{
  ["includeConsole":includeConsole,"includeNetwork":includeNetwork,"includeBodies":includeNetwork && includeBodies,"includeElements":includeElements,"includeElementText":includeElements && includeElementText,
   "redactCookies":true,"redactAuthHeaders":true,"redactHeaders":redactHeaders,"redactQueryParams":redactQueryParams]
 }
}
/// Politika kontextu cloudových složek uložená v UserDefaults tohoto Macu; bez záznamu je kontext vypnutý.
enum CloudContextPolicies {
 static let key="CloudContextPolicies"
 static var defaults=UserDefaults.standard
 private static func all()->[String:ContextPolicy]{defaults.data(forKey:key).flatMap{try? JSONDecoder().decode([String:ContextPolicy].self,from:$0)} ?? [:]}
 static func policy(_ folder:UUID)->ContextPolicy{all()[folder.uuidString.lowercased()] ?? {var off=ContextPolicy();off.enabled=false;return off}()}
 static func set(_ policy:ContextPolicy,for folder:UUID){var value=all();value[folder.uuidString.lowercased()]=policy;defaults.set(try? JSONEncoder().encode(value),forKey:key)}
}
extension Topic {
 /// Cloudová složka má politiku jen na tomto Macu (výchozí vypnuto); snímek draftu ji nese v `contextPolicy`.
 var effectiveContextPolicy:ContextPolicy?{let policy=contextPolicy ?? cloudFolderID.map{CloudContextPolicies.policy($0)} ?? ContextPolicy();return policy.enabled ? policy:nil}
 /// Aktuální nastavení složky ze seznamu; složka, která už neexistuje nebo se přesunula do cloudu, kontext nepřikládá.
 func currentContextPolicy(in folders:[Topic])->ContextPolicy?{folders.first{$0.id==id}?.effectiveContextPolicy}
}

/// Kontext vyžádaný souběžně se screencapture. Bez spojení s rozšířením se nečeká vůbec.
final class PendingCaptureContext:@unchecked Sendable {
 private let lock=NSLock();private var done=false;private var files:CaptureContextFiles?
 private var waiters:[(CaptureContextFiles?)->Void]=[]
 /// Složka s vypnutým kontextem request vůbec nepošle.
 /// `windowMs` u videa pokryje celou dobu záznamu; mapa elementů k videu nepatří.
 static func start(topic:Topic?,bridge:BrowserBridge = .shared,windowMs:Int?=nil,target:()->[String:Any]? = browserCaptureTarget)->PendingCaptureContext?{
  guard let policy=topic?.effectiveContextPolicy else{contextLog.notice("skipped: \(topic == nil ? "no folder" : "context off in folder", privacy: .public)");return nil}
  guard bridge.isRunning,!bridge.clients.isEmpty else{contextLog.notice("skipped: no browser extension connected");return nil}
  guard let target=target() else{return nil}
  var json=policy.protocolJSON
  if let windowMs{json["windowMs"]=windowMs;json["includeElements"]=false}
  return PendingCaptureContext(bridge:bridge,target:target,policy:json,timeout:windowMs == nil ? 30:5)
 }
 /// Deadline pokrývá i interaktivní výběr výřezu; po snímku se čeká jen `wait(upTo:)`.
 init(bridge:BrowserBridge,target:[String:Any]?,policy:[String:Any]?=nil,timeout:TimeInterval=30){
  // Víc prohlížečů odpovídá souběžně; platí jen bundle z cílového okna.
  let bounds=target?["windowBounds"] as? [String:CGFloat]
  Task.detached{let data=await bridge.request(policy:policy,target:target,timeout:timeout,accept:{bundleMatches($0,bounds:bounds)});if data==nil{contextLog.notice("no matching bundle from the extension")};self.finish(data.flatMap(CaptureContextFiles.init(bundle:)))}
 }
 private func finish(_ result:CaptureContextFiles?){
  lock.lock();guard !done else{lock.unlock();return}
  done=true;files=result;let pending=waiters;waiters=[];lock.unlock()
  DispatchQueue.main.async{for waiter in pending{waiter(result)}}
 }
 /// Volá se na hlavním vlákně; výsledek předá hned, nebo nejpozději po `limit` sekundách nil.
 func wait(upTo limit:TimeInterval,_ completion:@escaping (CaptureContextFiles?)->Void){
  dispatchPrecondition(condition:.onQueue(.main))
  var called=false
  let once:(CaptureContextFiles?)->Void={if !called{called=true;completion($0)}}
  lock.lock()
  if done{let result=files;lock.unlock();once(result);return}
  waiters.append(once);lock.unlock()
  DispatchQueue.main.asyncAfter(deadline:.now()+limit){once(nil)}
 }
}

/// Text ze stránky jako jednořádkový kód; nevytvoří odkaz ani formátování.
func inlineCode(_ text:String,limit:Int=200)->String {
 var plain=text.components(separatedBy:CharacterSet.controlCharacters.union(.newlines)).joined(separator:" ").replacingOccurrences(of:"`",with:"'").trimmingCharacters(in:.whitespaces)
 // Limit platí i pro skalární hodnoty, aby kombinující znaky nenafoukly řádek.
 if plain.count>limit || plain.unicodeScalars.count>limit*4{var scalars=String.UnicodeScalarView();scalars.append(contentsOf:plain.unicodeScalars.prefix(limit*4));plain=String(String(scalars).prefix(limit))+"…"}
 return "`"+(plain.isEmpty ? "?":plain)+"`"
}
/// Souhrn kontextu pro callout a {context}. `summary` z rozšíření popisuje vždy celá data.
struct ContextSummary {
 var url="",errors=0,failedCount=0;var failed:[String]=[],messages:[String]=[];var trimmed:String?
 init?(_ data:Data){
  guard let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],object["format"] as? String=="screenshot-note-context" else{return nil}
  func int(_ value:Any?)->Int{max(0,(value as? NSNumber)?.intValue ?? 0)}
  let summary=object["summary"] as? [String:Any] ?? [:]
  url=(object["page"] as? [String:Any])?["url"] as? String ?? ""
  errors=int(summary["consoleErrors"])+int(summary["uncaughtErrors"])
  let requests=summary["failedRequests"] as? [[String:Any]] ?? []
  failedCount=requests.count
  failed=requests.prefix(3).map{request in
   let raw=request["url"] as? String ?? "",path=URLComponents(string:raw)?.path ?? ""
   let result=(request["status"] as? NSNumber).map{String($0.intValue)} ?? inlineCode(request["error"] as? String ?? "?",limit:80)
   return inlineCode((request["method"] as? String ?? "?")+" "+(path.isEmpty ? raw:path))+" → "+result
  }
  let entries=(object["console"] as? [[String:Any]] ?? []).compactMap{entry->String? in
   if entry["kind"] as? String=="error"{return entry["message"] as? String ?? ""}
   if entry["kind"] as? String=="console",entry["level"] as? String=="error"{return (entry["args"] as? [String] ?? []).joined(separator:" ")}
   return nil
  }
  messages=entries.suffix(3).map{inlineCode($0)}
  if let cut=object["trimmed"] as? [String:Any] {
   var parts:[String]=[]
   if cut["bodies"] as? Bool==true{parts.append(L("bez těl"))}
   if int(cut["network"])>0{parts.append(LP(int(cut["network"]),"%ld request","%ld requesty","%ld requestů",int(cut["network"])))}
   if int(cut["console"])>0{parts.append(LP(int(cut["console"]),"%ld záznam konzole","%ld záznamy konzole","%ld záznamů konzole",int(cut["console"])))}
   if int(cut["elements"])>0{parts.append(LP(int(cut["elements"]),"%ld element","%ld elementy","%ld elementů",int(cut["elements"])))}
   trimmed=L("Zmenšeno kvůli velikosti")+(parts.isEmpty ? "":": "+parts.joined(separator:", "))
  }
 }
 var counts:String {
  let parts=[errors>0 ? LP(errors,"%ld chyba","%ld chyby","%ld chyb",errors):nil,failedCount>0 ? LP(failedCount,"%ld selhaný request","%ld selhané requesty","%ld selhaných requestů",failedCount):nil].compactMap{$0}
  return parts.isEmpty ? L("bez chyb"):parts.joined(separator:", ")
 }
}
/// Krátký titulek odznaku v komposeru.
func contextBadgeTitle(_ summary:ContextSummary)->String {
 let parts=[summary.errors>0 ? LP(summary.errors,"%ld chyba","%ld chyby","%ld chyb",summary.errors):nil,summary.failedCount>0 ? LP(summary.failedCount,"%ld selhaný","%ld selhané","%ld selhaných",summary.failedCount):nil].compactMap{$0}
 return parts.isEmpty ? L("Kontext"):parts.joined(separator:" · ")
}
/// Odkazy na exportované soubory kontextu.
func contextLinks(_ base:String,har:Bool)->String{((har ? ["[HAR](<assets/\(base).har>)"]:[])+["["+L("konzole")+"](<assets/\(base).context.json>)"]).joined(separator:" · ")}
/// Sbalitelný callout pod obrázkem podle PROTOCOL.md.
func contextCallout(_ summary:ContextSummary,base:String,har:Bool)->String {
 var lines=["> [!bug]- "+L("Kontext")+": "+inlineCode(summary.url)+" ("+summary.counts+")"]
 lines+=summary.failed.map{"> - "+$0}
 if summary.failedCount>summary.failed.count{lines.append("> - "+LF("… a další selhané requesty: %ld",summary.failedCount-summary.failed.count))}
 lines+=summary.messages.map{"> - "+$0}
 if let trimmed=summary.trimmed{lines.append("> - "+trimmed)}
 lines.append("> - "+contextLinks(base,har:har))
 return lines.joined(separator:"\n")
}
/// Placeholder {context}: jeden řádek za každý snímek s kontextem.
func sessionContextMarkdown(_ items:[(number:Int,summary:ContextSummary,base:String,har:Bool)])->String {
 items.map{"- Screenshot \($0.number): "+inlineCode($0.summary.url)+" ("+$0.summary.counts+") · "+contextLinks($0.base,har:$0.har)}.joined(separator:"\n")
}
// Callout na konci popisku obrázku; při čtení uložené relace se z popisku odstraní.
private let calloutExpression=try! NSRegularExpression(pattern:"(?:\\A|\\n\\n)> \\[!bug\\]- [^\\n]*(?:\\n> [^\\n]*)*?\\n> - [^\\n]*\\]\\(<assets/[^>\\n]+\\.context\\.json>\\)\\s*\\z")
func stripContextCallout(_ note:String)->String {
 guard let match=calloutExpression.firstMatch(in:note,range:NSRange(location:0,length:(note as NSString).length)) else{return note}
 return (note as NSString).substring(to:match.range.location)
}
/// Zkopíruje kontext exportovaného obrázku z assets/ do pracovní složky. Vrací true, když kontext existoval.
func importAssetContext(assets:URL,image:String,to destination:URL)throws->Bool {
 let sources=assetContextFiles(assets,image),targets=contextSidecars(destination)
 guard (try? boundedData(sources[0],max:maxContextBytes)) != nil else{return false}
 do{for (source,target) in zip(sources,targets) where (try? source.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile==true{try fm.copyItem(at:source,to:target)}}
 catch{for url in targets{try? fm.removeItem(at:url)};throw error}
 return true
}
/// {screenshots} s callouty pod obrázky a {context} podle souborů kontextu v assets/.
/// Obrázky se vykreslí šablonou obrázku složky (nil = vestavěná).
func screenshotsWithContext(_ names:[String],_ captions:[String],assets:URL,without excluded:Set<String> = [],imageTemplate:String?=nil)->(screenshots:String,context:String) {
 var items:[(number:Int,summary:ContextSummary,base:String,har:Bool)]=[]
 let blocks=zip(names,captions).enumerated().map{(offset,pair)->ImageBlock in
  var block=ImageBlock(name:pair.0,caption:pair.1)
  let video=assetVideoFiles(assets,pair.0)
  if fm.fileExists(atPath:video[0].path),let info=readVideoInfo(video[1]){block.videoMs=info.durationMs}
  let files=assetContextFiles(assets,pair.0)
  if !excluded.contains(pair.0),let data=try? boundedData(files[0],max:maxContextBytes),let summary=ContextSummary(data) {
   let base=(pair.0 as NSString).deletingPathExtension,har=fm.fileExists(atPath:files[1].path)
   block.context=contextCallout(summary,base:base,har:har);items.append((offset+1,summary,base,har))
  }
  return block
 }
 return (renderImageBlocks(blocks,template:imageTemplate),sessionContextMarkdown(items))
}
