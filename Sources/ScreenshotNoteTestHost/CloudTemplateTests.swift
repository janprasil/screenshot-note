import AppKit
@testable import ScreenshotNoteKit

/// Šablony: přerenderování lokální složky, výchozí šablony a jejich synchronizace.
@MainActor func templateTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-templates-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 let newSession="## {title}\n\n{text}\n\n{screenshots}\n"
 for combined in [false,true] {
  let topic=Topic(id:"t",name:"Šablony",detail:"Popis",folder:root.appendingPathComponent(combined ? "combined":"separate").path,combined:combined,combinedFile:"All.md")
  for title in ["První","Druhá"]{try Data([1]).write(to:capture.appendingPathComponent("s.png"));try finishSession(Draft(images:["s.png"],comment:title+" text",title:title,topic:topic),root:capture)}
  var changed=topic;changed.markdownTemplate=newSession;changed.combinedTemplate=combined ? "Hlavička {folderName}\n\n{sessions}\n\nKonec\n":nil
  if combined {
   let all=topic.destination.appendingPathComponent("All.md")
   let result=rerenderFolder(changed,previous:topic),text=try String(contentsOf:all,encoding:.utf8)
   assert(result.updated==2 && result.edited==0 && text.hasPrefix("Hlavička Šablony\n\n## První\n\nPrvní text") && text.hasSuffix("Konec\n") && text.contains("## Druhá"))
   assert((try! previousSessions(for:changed)).count==2)
   // Ručně upravený společný soubor se nepřepíše; nová verze jde do All_template.md.
   let edited=text+"\nMoje poznámka\n";try edited.write(to:all,atomically:true,encoding:.utf8)
   var again=changed;again.markdownTemplate="### {title}\n\n{screenshots}\n\n{text}\n"
   let second=rerenderFolder(again,previous:changed)
   assert(second.updated==0 && second.edited>=1 && (try! String(contentsOf:all,encoding:.utf8))==edited && (try! String(contentsOf:topic.destination.appendingPathComponent("All_template.md"),encoding:.utf8)).contains("### Druhá"))
  } else {
   let first=topic.destination.appendingPathComponent(readableSessionName("První",created:Date())+".md"),second=topic.destination.appendingPathComponent(readableSessionName("Druhá",created:Date())+".md")
   let edited=(try String(contentsOf:second,encoding:.utf8))+"\nRuční úprava\n";try edited.write(to:second,atomically:true,encoding:.utf8)
   let result=rerenderFolder(changed,previous:topic)
   assert(result.updated==1 && result.edited==1 && (try! String(contentsOf:first,encoding:.utf8)).hasPrefix("## První\n\nPrvní text") && (try! String(contentsOf:second,encoding:.utf8))==edited)
   assert((try! String(contentsOf:topic.destination.appendingPathComponent(readableSessionName("Druhá",created:Date())+"_template.md"),encoding:.utf8)).hasPrefix("## Druhá"))
   assert((try! previousSessions(for:changed)).contains{$0.title=="První" && $0.comment=="První text"})
  }
 }
 print("PASS: local template change re-renders separate files and combined blocks/header/footer, edited ones get _template.md")
 // Výchozí šablony: lokálně bez účtu, kopie do nové složky, konflikt na serveru, odhlášení.
 let suite="sn-test-"+UUID().uuidString,store=UserDefaults(suiteName:suite)!;defer{store.removePersistentDomain(forName:suite)}
 let c=cloudFixtureConnection();var connection:CloudConnection?=nil,remote:[String:Any]=["session_template":NSNull(),"file_template":NSNull(),"revision":"1"],puts=0
 let defaults=TemplateDefaults(store:store,connection:{connection},request:{_,_,_ in try JSONSerialization.data(withJSONObject:["data":remote])},send:{_,_,_,body in
  puts+=1;let sent=try JSONSerialization.jsonObject(with:body) as! [String:Any]
  guard sent["revision"] as? String==remote["revision"] as? String else{throw CloudFailure("409",status:409,code:"templates_conflict")}
  remote=["session_template":sent["session_template"]!,"file_template":sent["file_template"]!,"revision":String(Int(remote["revision"] as! String)!+1)]
  return try JSONSerialization.data(withJSONObject:["data":remote])
 })
 let custom="# {title}\n\n{screenshots}\n\n{text}\n\n_výchozí_\n",customFile="# {folderName}\n\n{sessions}\n\n_patička_\n"
 try await defaults.save(session:custom,file:customFile);assert(defaults.session==custom && defaults.file==customFile && puts==0)
 let fresh=defaults.newFolderTemplates;assert(fresh.0==custom && fresh.1==customFile)
 let shared=TemplateDefaults.shared;TemplateDefaults.shared=defaults;defer{TemplateDefaults.shared=shared}
 var created:[String:Any]=[:]
 let folders=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},send:{_,path,_,_,body in
  created=try JSONSerialization.jsonObject(with:body) as! [String:Any]
  return try JSONSerialization.data(withJSONObject:["data":["id":path.split(separator:"/").last!,"name":created["name"]!,"revision":"1","markdown_template":created["markdown_template"]!,"combined_template":created["combined_template"]!]])
 })
 _ = try await folders.create("Nová");assert(created["markdown_template"] as? String==custom && created["combined_template"] as? String==customFile && folders.topics.first?.markdownTemplate==custom)
 print("PASS: default templates stored locally when signed out and copied into new local and cloud folders")
 connection=c;await defaults.refresh();assert(defaults.session==nil && defaults.file==nil)
 remote=["session_template":custom,"file_template":NSNull(),"revision":"5"]
 do{try await defaults.save(session:newSession,file:defaultCombinedTemplate);assertionFailure("Conflict ignored")}catch let failure as CloudFailure{assert(failure.message==L("Změněno jinde. Načetl jsem novou verzi.") && defaults.session==custom)}
 try await defaults.save(session:newSession,file:defaultCombinedTemplate);assert(defaults.session==newSession && defaults.file==nil && remote["revision"] as? String=="6")
 defaults.forgetAccount();connection=nil;let before=puts
 assert(defaults.session==newSession)
 try await defaults.save(session:custom,file:customFile);assert(puts==before && defaults.session==custom)
 print("PASS: account default templates sync with revision conflict reload, logout keeps last values as local defaults")
}

/// Plochá složka: deduplikace názvů a zploštění starých podsložek relací.
@MainActor func flatLayoutTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-flat-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let c=cloudFixtureConnection(),folderID=UUID(),ids=(0..<4).map{_ in UUID()},png=cloudFixturePNG(0.6),created="2026-04-01T09:00:00Z"
 func note(_ id:UUID)->[String:Any]{["id":id.uuidString,"title":"Stejná","comment":"Text","template":defaultMarkdownTemplate,"captions":[""],"updated_at":"t1","created_at":created,"images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]}
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.contains("/images/"){return png}
  if path=="/api/v1/folders"{return try JSONSerialization.data(withJSONObject:["data":[["id":folderID.uuidString,"name":"Plochá","revision":"1"]]])}
  if path.contains("?"){return try JSONSerialization.data(withJSONObject:["data":path.contains("state=trashed") ? []:ids.map{["id":$0.uuidString,"updated_at":"t1","trashed_at":NSNull()]},"pagination":["has_more":false]])}
  return try JSONSerialization.data(withJSONObject:["data":note(ids.first{path.contains($0.uuidString.lowercased())}!)])
 })
 await store.refresh(c)
 let target=root.appendingPathComponent("cloud"),name=readableSessionName("Stejná",created:parseServerDate(created)!)
 try fm.createDirectory(at:target,withIntermediateDirectories:true)
 let base=try Topics.checkedDestination(target.path)
 // Dvě relace ve staré podobě podsložek: netknutá a upravená.
 let digest={(id:UUID)->String in sessionFingerprint(try! JSONEncoder.sorted.encode(try! JSONDecoder().decode(RemoteNote.self,from:JSONSerialization.data(withJSONObject:note(id)))))}
 for (i,id) in ids.prefix(2).enumerated() {
  let folder=target.appendingPathComponent("Starší \(i)"),markdown=folder.appendingPathComponent("Starší \(i).md")
  try fm.createDirectory(at:folder.appendingPathComponent("assets"),withIntermediateDirectories:true);try png.write(to:folder.appendingPathComponent("assets/1.png"))
  let body=renderSessionTemplate(defaultMarkdownTemplate,title:"Stejná",screenshots:"![[assets/1.png]]",text:"Text");try body.write(to:markdown,atomically:true,encoding:.utf8)
  var record=SessionRecord(id:id.uuidString.lowercased(),file:SessionIndex.key(markdown),start:0,length:(body as NSString).length,hash:sessionFingerprint(Data(body.utf8)),heading:firstLine(body),title:"Stejná",comment:"Text",template:defaultMarkdownTemplate,images:["1.png"],notes:["1.png":""],combined:false,footer:"",files:[markdown.lastPathComponent:sessionFingerprint(Data(body.utf8)),"assets/1.png":sessionFingerprint(png)],seen:0,base:SessionIndex.key(base),folder:folderID.uuidString.lowercased(),owner:c.ownerID!.uuidString.lowercased(),origin:c.endpoint)
  record.updated="t1";record.digest=digest(id);record.shas=[sessionFingerprint(png)];record.created=created;SessionIndex.shared.put(record)
  if i==1{try Data("cizí".utf8).write(to:folder.appendingPathComponent("Moje.txt"))}
 }
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let items=((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()
 // Netknutá podsložka se zploštila, upravená zůstala; nové relace mají deduplikované názvy.
 assert(items==["Starší 0.md","Starší 1","assets",name+".md",name+" 2.md"].sorted())
 let assets=Set((try fm.contentsOfDirectory(atPath:target.appendingPathComponent("assets").path)))
 assert(assets==["Starší 0-1.png",name+"-1.png",name+" 2-1.png"] && (try! String(contentsOf:target.appendingPathComponent("Starší 0.md"),encoding:.utf8)).contains("](<assets/Starší 0-1.png>)"))
 assert(fm.fileExists(atPath:target.appendingPathComponent("Starší 1/assets/1.png").path) && (try! String(contentsOf:target.appendingPathComponent(name+" 2.md"),encoding:.utf8)).contains("](<assets/"+name+" 2-1.png>)"))
 let found=try previousSessions(for:store.topics[0]);assert(found.count==4 && found.allSatisfy{$0.target.session != nil})
 print("PASS: flat layout: YYYY-MM-DD Title.md with ' 2' dedupe, shared assets/Title-N.png, unmodified session folders flattened, modified ones untouched")
}

/// Standardní Markdown odkazy: vykreslení, čtení obou formátů, migrace a doplnění převedeného souboru.
@MainActor func markdownLinkTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-links-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 assert(imageMarkdown("2026-01-01 Titul-2.png",2)=="![Screenshot 2](<assets/2026-01-01 Titul-2.png>)")
 assert(screenshotsMarkdown(["a b-1.png","a b-2.png"],["","Popis"])=="![Screenshot 1](<assets/a b-1.png>)\n\n![Screenshot 2](<assets/a b-2.png>)\n\nPopis")
 assert(imageLinkNames("![[assets/x y.png]] ![S](<assets/a b.png>) ![S](assets/c.png)")==["x y.png","a b.png","c.png"])
 // Oba formáty se čtou při hledání relace podle šablony.
 for screenshots in ["![[assets/a b.png]]\n\nPopis","![Screenshot 1](<assets/a b.png>)\n\nPopis"] {
  let parsed=parsedSession(defaultMarkdownTemplate,renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:screenshots,text:"X"))
  assert(parsed?.2==["a b.png"] && parsed?.3["a b.png"]=="Popis")
 }
 // Migrace: netknutý soubor ve starém formátu se převede, upravený zůstane.
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 let topic=Topic(id:"links",name:"Odkazy",detail:"",folder:root.appendingPathComponent("local").path,combined:false,combinedFile:"N.md")
 for title in ["Čistá","Upravená"]{try Data([1]).write(to:capture.appendingPathComponent("a.png"));try finishSession(Draft(images:["a.png"],comment:"Text",title:title,topic:topic),root:capture)}
 let clean=topic.destination.appendingPathComponent(readableSessionName("Čistá",created:Date())+".md"),edited=topic.destination.appendingPathComponent(readableSessionName("Upravená",created:Date())+".md")
 assert((try! String(contentsOf:clean,encoding:.utf8)).contains("![Screenshot 1](<assets/"))
 // Simulace starších souborů: wikiodkazy, index odpovídá zapsanému obsahu.
 for file in [clean,edited] {
  let old=(try String(contentsOf:file,encoding:.utf8)).replacingOccurrences(of:"![Screenshot 1](<assets/",with:"![[assets/").replacingOccurrences(of:".png>)",with:".png]]")
  try old.write(to:file,atomically:true,encoding:.utf8)
  var record=SessionIndex.shared.records(file:file)[0];record.length=(old as NSString).length;record.hash=sessionFingerprint(Data(old.utf8));SessionIndex.shared.put(record)
 }
 let editedText=(try String(contentsOf:edited,encoding:.utf8))+"\nRuční úprava\n";try editedText.write(to:edited,atomically:true,encoding:.utf8)
 migrateImageLinks(in:topic.destination)
 let migrated=try String(contentsOf:clean,encoding:.utf8)
 assert(migrated.contains("![Screenshot 1](<assets/") && !migrated.contains("![[assets/") && (try! String(contentsOf:edited,encoding:.utf8))==editedText)
 migrateImageLinks(in:topic.destination);assert((try! String(contentsOf:clean,encoding:.utf8))==migrated)
 // Znovu otevřít převedenou relaci a doplnit snímek.
 let found=try previousSessions(for:topic);assert(found.count==2)
 let session=found.first{$0.title=="Čistá"}!;assert((try? checkedPreviousFile(session.target)) != nil)
 let reopen=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopen,withIntermediateDirectories:true)
 var draft=try workingDraft(from:session,topic:topic,root:reopen);try Data([2]).write(to:reopen.appendingPathComponent("n.png"));draft.images.append("n.png")
 try finishSession(draft,root:reopen)
 let appended=try String(contentsOf:clean,encoding:.utf8)
 assert(appended.contains("![Screenshot 1](<assets/") && appended.contains("![Screenshot 2](<assets/") && (try! previousSessions(for:topic)).contains{$0.title=="Čistá" && $0.images.count==2})
 print("PASS: standard Markdown image links: rendering, both formats parsed, migration of unmodified files only, reopen and append on a migrated file")
}
