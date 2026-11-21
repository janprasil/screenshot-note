import AppKit
@testable import ScreenshotNoteKit

/// F6: přílohy kontextu v cloudové frontě, stažení, odebrání a limity.
@MainActor func cloudAttachmentTests() throws {
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 let suite="ScreenshotNoteTests.\(UUID().uuidString)",previousDefaults=CloudContextPolicies.defaults
 CloudContextPolicies.defaults=UserDefaults(suiteName:suite)!;defer{CloudContextPolicies.defaults.removePersistentDomain(forName:suite);CloudContextPolicies.defaults=previousDefaults}
 let root=fm.temporaryDirectory.appendingPathComponent("sn-cloud-attach-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 try cloudFixturePNG(0.2).write(to:root.appendingPathComponent("a.png"));try cloudFixturePNG(0.6).write(to:root.appendingPathComponent("b.png"))
 let bundle=Data(#"{"format":"screenshot-note-context","version":1,"page":{"url":"https://app.test/x"}}"#.utf8),har=Data(#"{"log":{"entries":[]}}"#.utf8)
 let sides=contextSidecars(root.appendingPathComponent("b.png"))
 try bundle.write(to:sides[0]);try har.write(to:sides[1])
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection();let fixture=vault.value!,folder=UUID()
 let topic=Topic(id:"cloud",name:"Cloud",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:folder,cloudOwnerID:fixture.ownerID,cloudOrigin:fixture.endpoint)
 let queue=root.appendingPathComponent("queue"),lib=CloudLibrary(queue:queue,vault:vault,endpoint:CloudEndpoint("https://fixture.invalid")!)
 func job(_ id:UUID)throws->(URL,[String:Any]){
  let dir=queue.appendingPathComponent(id.uuidString.lowercased())
  return (dir,try JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("job.json"))) as? [String:Any] ?? [:])
 }

 // Výchozí stav cloudové složky: bez příloh, popisky Element bez dat stránky.
 let off=try lib.enqueue(Draft(images:["a.png","b.png"],comment:"",title:"Off",topic:topic),root:root,folders:[topic])
 let (offDir,offJob)=try job(off)
 try check(offJob["attachments"]==nil && !fm.fileExists(atPath:offDir.appendingPathComponent("2.context.json").path),"disabled cloud folder queues no attachments")

 // Zapnutý kontext: přílohy jen u snímku s kontextem, hashe a velikosti odpovídají souborům jobu.
 CloudContextPolicies.set(ContextPolicy(),for:folder)
 let on=try lib.enqueue(Draft(images:["a.png","b.png"],comment:"",title:"On",topic:topic),root:root,folders:[topic])
 let (onDir,onJob)=try job(on)
 let items=try JSONDecoder().decode([CloudAttachment].self,from:JSONSerialization.data(withJSONObject:onJob["attachments"] ?? []))
 try check(items.map(\.index)==[2,2] && Set(items.map(\.kind))==["context","har"],"attachments belong to the screenshot with context")
 for item in items {
  let data=try Data(contentsOf:onDir.appendingPathComponent(item.filename))
  try check(data.count==item.bytes && sessionFingerprint(data)==item.sha256 && data==(item.kind=="har" ? har:bundle),"attachment hash in the job matches the staged file")
 }
 // Starý job bez pole attachments se načte dál.
 try check(lib.pendingCount==2,"job without attachments still decodes")

 // Doplnění relace: původní snímky přílohy znovu neposílají, odebraný kontext jde do fronty mazání.
 let shaA=sessionFingerprint(try Data(contentsOf:root.appendingPathComponent("a.png")))
 try bundle.write(to:contextSidecars(root.appendingPathComponent("a.png"))[0])
 var extended=Draft(images:["a.png","b.png"],comment:"",title:"Ext",topic:topic)
 extended.previous=PreviousSessionTarget(path:"/x.md",start:0,length:1,original:"",fingerprint:"",imported:["a.png":"Old-1.png"])
 extended.removedContexts=["Old-1.png"]
 try check(CloudLibrary.removedAttachmentIndices(extended)==[1],"removed context maps to the cloud image index")
 let ext=try lib.enqueue(extended,root:root,sessionID:UUID(),folders:[topic],base:[shaA])
 let extItems=try JSONDecoder().decode([CloudAttachment].self,from:JSONSerialization.data(withJSONObject:try job(ext).1["attachments"] ?? []))
 try check(extItems.allSatisfy{$0.index==2},"extension uploads attachments only for new screenshots")
 let removal=queue.appendingPathComponent(".attachment-removals").appendingPathComponent(ext.uuidString.lowercased()+".json")
 let removed=try JSONSerialization.jsonObject(with:Data(contentsOf:removal)) as? [String:Any]
 try check(removed?["indices"] as? [Int]==[1],"attachment removal is queued for the session")
 try check(lib.pendingCount==4,"queued removal keeps the sync loop running")
 try fm.removeItem(at:contextSidecars(root.appendingPathComponent("a.png"))[0])

 // Limit 16 MiB: větší příloha se vynechá, relace se uloží bez ní.
 try Data(count:CloudAttachment.limit+1).write(to:sides[1])
 let big=try lib.enqueue(Draft(images:["b.png"],comment:"",title:"Big",topic:topic),root:root,folders:[topic])
 let bigItems=try JSONDecoder().decode([CloudAttachment].self,from:JSONSerialization.data(withJSONObject:try job(big).1["attachments"] ?? []))
 try check(bigItems.map(\.kind)==["context"],"oversized attachment is skipped, the session still queues")
 try har.write(to:sides[1])
 // Vlastní redakce cílové složky, kterou kontext nepokrývá: přílohy se vynechají, relace se uloží.
 var strict=ContextPolicy();strict.redactHeaders=["X-Tenant"];CloudContextPolicies.set(strict,for:folder)
 let strictJob=try lib.enqueue(Draft(images:["b.png"],comment:"",title:"Strict",topic:topic),root:root,folders:[topic])
 try check(try job(strictJob).1["attachments"]==nil,"context without the folder's custom redaction is not uploaded")
 CloudContextPolicies.set(ContextPolicy(),for:folder)

 // Stažení: neplatné záznamy se zahodí, relace bez příloh má stejný otisk jako dřív.
 let path="/api/v1/sessions/"+on.uuidString.lowercased()
 typealias A=RemoteNote.Image.Attachment
 let sha=sessionFingerprint(bundle)
 let note=RemoteNote(id:on,title:"T",comment:"",template:"",captions:["",""],images:[
  RemoteNote.Image(index:1,path:path+"/images/1",attachments:[]),
  RemoteNote.Image(index:2,path:path+"/images/2",attachments:[A(kind:"context",bytes:bundle.count,sha256:sha,path:path+"/attachments/2/context"),
   A(kind:"evil",bytes:1,sha256:sha,path:path+"/attachments/2/evil"),A(kind:"har",bytes:1,sha256:sha,path:"/elsewhere"),
   A(kind:"har",bytes:CloudAttachment.limit+1,sha256:sha,path:path+"/attachments/2/har")])])
 let normalized=CloudFolders.normalizedAttachments(note,path:path)
 try check(normalized.images[0].attachments==nil && normalized.images[1].attachments?.map(\.kind)==["context"],"invalid attachment entries are dropped")
 let plain=RemoteNote(id:on,title:"T",comment:"",template:"",captions:[""],images:[RemoteNote.Image(index:1,path:path+"/images/1")])
 try check(try JSONEncoder.sorted.encode(CloudFolders.normalizedAttachments(plain,path:path))==JSONEncoder.sorted.encode(plain),"old sessions keep their fingerprint")

 // Zápis do assets/: příloha vedle obrázku, odebraná na serveru zmizí jen pokud přišla z cloudu.
 let assets=root.appendingPathComponent("assets");try fm.createDirectory(at:assets,withIntermediateDirectories:true)
 let files=try CloudFolders.shared.writeContextAttachments([2:["context":bundle,"har":har]],names:["S-1.png","S-2.png"],assets:assets)
 try check(files.keys.sorted()==["assets/S-2.context.json","assets/S-2.har"] && (try? Data(contentsOf:assets.appendingPathComponent("S-2.har")))==har,"downloaded attachments land next to the image")
 let mode=(try fm.attributesOfItem(atPath:assets.appendingPathComponent("S-2.har").path)[.posixPermissions] as? NSNumber)?.intValue
 try check(mode==0o600,"downloaded attachments stay private")
 try Data("local".utf8).write(to:assets.appendingPathComponent("S-1.har"))
 let after=try CloudFolders.shared.writeContextAttachments([2:["context":bundle]],names:["S-1.png","S-2.png"],assets:assets,previous:files)
 try check(after.keys.sorted()==["assets/S-2.context.json"] && !fm.fileExists(atPath:assets.appendingPathComponent("S-2.har").path)
  && fm.fileExists(atPath:assets.appendingPathComponent("S-1.har").path),"removed cloud attachments are deleted, local files stay")
}

/// Politika cílové složky ořízne přílohy pořízené pro jinou složku.
func cloudAttachmentPolicyTests() throws {
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 let dir=fm.temporaryDirectory.appendingPathComponent("sn-restrict-"+UUID().uuidString);try fm.createDirectory(at:dir,withIntermediateDirectories:true);defer{try? fm.removeItem(at:dir)}
 let context=dir.appendingPathComponent("c.json"),har=dir.appendingPathComponent("h.har")
 try Data(#"{"format":"screenshot-note-context","version":1,"console":[{"kind":"error","message":"x"}],"summary":{"failedRequests":[{"url":"https://s/t"}]},"elements":[{"selector":"a","name":"secret","text":"t"}]}"#.utf8).write(to:context)
 try Data(#"{"log":{"entries":[{"request":{"postData":{"text":"pw"}},"response":{"content":{"text":"body","size":4}}}]}}"#.utf8).write(to:har)
 var policy=ContextPolicy();policy.includeConsole=false;policy.includeElementText=false;policy.includeBodies=false
 try check(restrictContextFile(context,har:false,policy:policy) && restrictContextFile(har,har:true,policy:policy),"restricted files stay")
 let c=String(decoding:try Data(contentsOf:context),as:UTF8.self),h=String(decoding:try Data(contentsOf:har),as:UTF8.self)
 try check(!c.contains("\"message\"") && !c.contains("secret") && c.contains("\"selector\""),"console and element texts are stripped")
 try check(!h.contains("pw") && !h.contains("body") && h.contains("\"size\""),"HAR bodies are stripped")
 policy.includeNetwork=false
 try check(!restrictContextFile(har,har:true,policy:policy),"HAR is skipped without network")
 // Vlastní hlavičky a parametry cílové složky musí být v politice pořízení (bez ohledu na velikost písmen).
 let bundle=dir.appendingPathComponent("p.json")
 try Data(#"{"format":"screenshot-note-context","version":1,"policy":{"redactHeaders":["x-tenant"],"redactQueryParams":["token","email"]}}"#.utf8).write(to:bundle)
 var custom=ContextPolicy();try check(contextRedactionCovers(bundle,policy:custom),"no custom lists always pass")
 custom.redactHeaders=["X-Tenant"];custom.redactQueryParams=["Email"];try check(contextRedactionCovers(bundle,policy:custom),"covered lists pass")
 custom.redactQueryParams=["phone"];try check(!contextRedactionCovers(bundle,policy:custom),"missing query param blocks the context")
 try check(!contextRedactionCovers(context,policy:custom),"bundle without policy is blocked when custom lists exist")
}
