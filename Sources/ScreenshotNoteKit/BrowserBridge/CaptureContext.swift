import AppKit
import CoreGraphics

// Kontext z prohlížeče ke snímku: cíl okna, souběžná žádost, soubory vedle obrázku a souhrn do Markdownu.
let chromiumBundleIDs:Set<String>=["com.google.Chrome","com.google.Chrome.beta","com.google.Chrome.canary","com.microsoft.edgemac","com.brave.Browser","company.thebrowser.Browser","org.chromium.Chromium"]
// Bundle má v rozšíření strop 16 MiB; po přeserializování může mírně narůst.
let maxContextBytes=32<<20

/// Soubory kontextu v pracovní složce: `<obrázek>.context.json` a `<obrázek>.har`.
func contextSidecars(_ image:URL)->[URL]{[image.appendingPathExtension("context.json"),image.appendingPathExtension("har")]}
/// Soubory kontextu v assets/: `<název>.context.json` a `<název>.har` vedle `<název>.png`.
func assetContextFiles(_ assets:URL,_ image:String)->[URL]{let base=(image as NSString).deletingPathExtension;return [assets.appendingPathComponent(base+".context.json"),assets.appendingPathComponent(base+".har")]}

/// Cíl pro capture.request, když je v popředí Chromium prohlížeč; jinak nil.
func browserCaptureTarget()->[String:Any]? {
 let own=ProcessInfo.processInfo.processIdentifier
 let windows=(CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
 var app=NSWorkspace.shared.frontmostApplication
 // Při otevřeném komposeru je v popředí appka sama; rozhoduje nejvyšší cizí okno.
 if app?.processIdentifier==own,let pid=windows.lazy.filter({windowNumber($0,kCGWindowLayer)==0}).compactMap({windowNumber($0,kCGWindowOwnerPID)}).first(where:{$0 != Int(own)}){app=NSRunningApplication(processIdentifier:pid_t(pid))}
 guard let app,let id=app.bundleIdentifier,chromiumBundleIDs.contains(id) else{return nil}
 return captureTarget(windows:windows,pid:app.processIdentifier)
}
private func windowNumber(_ window:[String:Any],_ key:CFString)->Int?{(window[key as String] as? NSNumber)?.intValue}
/// Nejvyšší běžné okno procesu (vrstva 0) v bodech s počátkem vlevo nahoře.
func captureTarget(windows:[[String:Any]],pid:pid_t)->[String:Any]? {
 for window in windows where windowNumber(window,kCGWindowLayer)==0 && windowNumber(window,kCGWindowOwnerPID)==Int(pid) {
  guard let raw=window[kCGWindowBounds as String] as? NSDictionary,let rect=CGRect(dictionaryRepresentation:raw as CFDictionary),rect.width>=100,rect.height>=100 else{continue}
  var target:[String:Any]=["windowBounds":["x":rect.minX,"y":rect.minY,"width":rect.width,"height":rect.height]]
  if let title=window[kCGWindowName as String] as? String,!title.isEmpty{target["windowTitle"]=title}
  return target
 }
 return nil
}

/// Bundle rozdělený na kontext bez HAR a samotný HAR.
struct CaptureContextFiles {
 let context:Data;let har:Data?
 init?(bundle:Data){
  guard bundle.count<=maxContextBytes,var object=(try? JSONSerialization.jsonObject(with:bundle)) as? [String:Any],object["format"] as? String=="screenshot-note-context",(object["version"] as? NSNumber)?.intValue==1 else{return nil}
  let har=object.removeValue(forKey:"har") as? [String:Any]
  guard let context=try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]) else{return nil}
  self.context=context;self.har=har.flatMap{try? JSONSerialization.data(withJSONObject:$0,options:[.withoutEscapingSlashes])}
 }
 /// Zapíše soubory vedle obrázku v pracovní složce, čitelné jen pro vlastníka.
 func write(besides image:URL)throws{
  let sides=contextSidecars(image)
  do{
   for (data,url) in zip([context,har],sides){guard let data else{continue};try data.write(to:url,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}
  }catch{for url in sides{try? fm.removeItem(at:url)};throw error}
 }
}

/// Kontext vyžádaný souběžně se screencapture. Bez spojení s rozšířením se nečeká vůbec.
final class PendingCaptureContext:@unchecked Sendable {
 // Výchozí politika rozšíření; F3 ji napojí na nastavení.
 static var policy:[String:Any]?{nil}
 private let lock=NSLock();private var done=false;private var files:CaptureContextFiles?
 private var waiters:[(CaptureContextFiles?)->Void]=[]
 static func start(bridge:BrowserBridge = .shared)->PendingCaptureContext?{
  guard bridge.isRunning,!bridge.clients.isEmpty,let target=browserCaptureTarget() else{return nil}
  return PendingCaptureContext(bridge:bridge,target:target)
 }
 /// Deadline pokrývá i interaktivní výběr výřezu; po snímku se čeká jen `wait(upTo:)`.
 init(bridge:BrowserBridge,target:[String:Any]?,timeout:TimeInterval=30){
  let policy=Self.policy
  Task.detached{let data=await bridge.request(policy:policy,target:target,timeout:timeout);self.finish(data.flatMap(CaptureContextFiles.init(bundle:)))}
 }
 private func finish(_ result:CaptureContextFiles?){
  lock.lock();guard !done else{lock.unlock();return}
  done=true;files=result;let pending=waiters;waiters=[];lock.unlock()
  DispatchQueue.main.async{for waiter in pending{waiter(result)}}
 }
 /// Volá se na hlavním vlákně; výsledek předá hned, nebo nejpozději po `limit` sekundách nil.
 func wait(upTo limit:TimeInterval,_ completion:@escaping (CaptureContextFiles?)->Void){
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
 if plain.count>limit{plain=String(plain.prefix(limit))+"…"}
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
func screenshotsWithContext(_ names:[String],_ captions:[String],assets:URL)->(screenshots:String,context:String) {
 var items:[(number:Int,summary:ContextSummary,base:String,har:Bool)]=[]
 let blocks=zip(names,captions).enumerated().map{(offset,pair)->String in
  var text=imageMarkdown(pair.0,offset+1)+(pair.1.isEmpty ? "":"\n\n"+pair.1)
  let files=assetContextFiles(assets,pair.0)
  if let data=try? boundedData(files[0],max:maxContextBytes),let summary=ContextSummary(data) {
   let base=(pair.0 as NSString).deletingPathExtension,har=fm.fileExists(atPath:files[1].path)
   text+="\n\n"+contextCallout(summary,base:base,har:har);items.append((offset+1,summary,base,har))
  }
  return text
 }
 return (blocks.joined(separator:"\n\n"),sessionContextMarkdown(items))
}
