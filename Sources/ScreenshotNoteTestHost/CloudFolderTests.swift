import AppKit
@testable import ScreenshotNoteKit

@MainActor func cloudMaterializationTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-materialize-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let c=cloudFixtureConnection(),owner=c.ownerID!,folderID=UUID(),noteA=UUID(),noteB=UUID()
 let pngs=[cloudFixturePNG(0.1),cloudFixturePNG(0.5),cloudFixturePNG(0.8)]
 var combined=false,revision="1",folderName="Cloud",imageCount=1,updated="t1",title="Remote",details=0,conflict=true
 var states:[UUID:String]=[noteA:"active"],restored:[UUID]=[]
 var sent:[(String,String,[String:Any])]=[]
 let createdA="2026-03-04T10:00:00.123456+00:00",createdB="2026-03-05T10:00:00Z"
 func note(_ id:UUID,_ count:Int,_ title:String)->[String:Any]{["id":id.uuidString,"title":title,"comment":"Text","template":defaultMarkdownTemplate,"captions":Array(repeating:"Popisek",count:count),"updated_at":updated,"created_at":id==noteA ? createdA:createdB,"trashed_at":states[id]=="trashed" ? "2026-03-06T00:00:00Z":NSNull(),"images":(1...count).map{["index":$0,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/\($0)"]}]}
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if let range=path.range(of:"/images/"){return pngs[Int(path[range.upperBound...])!-1]}
  let data:Any
  if path=="/api/v1/folders"{data=["data":[["id":folderID.uuidString,"name":folderName,"revision":revision,"description":"Popis","combined":combined,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":"# {folderName}\n\n{sessions}\n"]]]}
  else if path.contains("?") {
   let wanted=path.contains("state=trashed") ? "trashed":"active"
   let items=([noteA]+(combined ? [noteB]:[])).filter{states[$0,default:"active"]==wanted}.map{id->[String:Any] in ["id":id.uuidString,"deleting":false,"updated_at":updated,"trashed_at":wanted=="trashed" ? "2026-03-06T00:00:00Z":NSNull()]}
   data=["data":items,"pagination":["has_more":false]]
  }
  else {
   let id=path.contains(noteA.uuidString.lowercased()) ? noteA:noteB
   if states[id]=="purged"{throw CloudFailure("404",status:404,code:"not_found")}
   details+=1;data=["data":id==noteA ? note(noteA,imageCount,title):note(noteB,1,"Druhá")]
  }
  return try JSONSerialization.data(withJSONObject:data)
 },send:{_,path,method,_,body in
  if path.hasSuffix("/restore") {
   let id=path.contains(noteA.uuidString.lowercased()) ? noteA:noteB;restored.append(id);states[id]="active"
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString,"updated_at":updated]])
  }
  sent.append((path,method,try JSONSerialization.jsonObject(with:body) as! [String:Any]))
  if conflict{conflict=false;revision="2";folderName="Jinde";throw CloudFailure("409",status:409,code:"folder_conflict")}
  let request=try JSONSerialization.jsonObject(with:body) as! [String:Any];revision="3"
  return try JSONSerialization.data(withJSONObject:["data":["id":folderID.uuidString,"name":request["name"]!,"revision":"3","description":request["description"]!,"combined":request["combined"]!,"combined_file":request["combined_file"]!,"markdown_template":request["markdown_template"]!,"combined_template":request["combined_template"]!]])
 })
 await store.refresh(c);assert(store.lastError==nil && store.topics.count==1 && store.topics[0].detail=="Popis" && store.topics[0].combinedFile=="All.md")
 let target=root.appendingPathComponent("cloud"),trash=target.appendingPathComponent(".trash")
 // Cizí obsah koše (např. Obsidian) se nikdy nemění.
 try fm.createDirectory(at:trash.appendingPathComponent("Cizí složka"),withIntermediateDirectories:true);try Data("cizí".utf8).write(to:trash.appendingPathComponent("Cizí.md"))
 func visible()->[String]{((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()}
 func trashed()->[String]{((try? fm.contentsOfDirectory(atPath:trash.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()}
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let nameA=readableSessionName("Remote",created:parseServerDate(createdA)!),markdownA=target.appendingPathComponent(nameA+".md"),assetsDir=target.appendingPathComponent("assets")
 func markdowns()->[String]{visible().filter{$0.hasSuffix(".md")}}
 func trashedMarkdowns()->[String]{trashed().filter{$0.hasSuffix(".md")}}
 assert(visible()==["assets",nameA+".md"].sorted() && fm.fileExists(atPath:assetsDir.appendingPathComponent(nameA+"-1.png").path) && readSessionTag(markdownA)==noteA.uuidString.lowercased())
 let firstText=try! String(contentsOf:markdownA,encoding:.utf8);assert(!firstText.contains("<!--") && firstText.contains("](<assets/"+nameA+"-1.png>)"))
 var topic=store.topics[0]
 var found=try previousSessions(for:topic);assert(found.count==1 && found[0].images==[nameA+"-1.png"] && found[0].target.session==noteA.uuidString.lowercased())
 assert(store.serverImages(for:found[0].target,topic:topic)?.1==[sessionFingerprint(pngs[0])])
 // Nezměněné updated_at nestahuje detail znovu.
 let before=details;await store.refresh(c);assert(details==before)
 // Rozšířená relace s netknutou kopií se nahradí na místě a nový snímek dostane další -N.
 imageCount=2;updated="t2";await store.refresh(c);assert(store.lastError==nil)
 assert(markdowns()==[nameA+".md"] && fm.fileExists(atPath:assetsDir.appendingPathComponent(nameA+"-2.png").path) && (try! String(contentsOf:markdownA,encoding:.utf8)).contains("](<assets/"+nameA+"-2.png>)"))
 found=try previousSessions(for:topic);assert(found.count==1 && found[0].images.count==2 && store.serverImages(for:found[0].target,topic:topic)?.1.count==2)
 // Místně upravená kopie zůstává, cloudová verze jde vedle jako _cloud.md.
 let pristineA=try Data(contentsOf:markdownA),edited=pristineA+Data("\nMístní úprava".utf8);try edited.write(to:markdownA)
 title="Změna";updated="t3";await store.refresh(c)
 let cloudCopy=target.appendingPathComponent(nameA+"_cloud.md")
 assert(try! Data(contentsOf:markdownA)==edited && markdowns()==[nameA+".md",nameA+"_cloud.md"].sorted() && (try! String(contentsOf:cloudCopy,encoding:.utf8)).contains("# Změna"))
 let foundEdited=try! previousSessions(for:topic)
 assert(store.serverImages(for:foundEdited.first{$0.target.path.hasSuffix("/"+nameA+".md")}!.target,topic:topic)?.1.count==2)
 try pristineA.write(to:markdownA);try fm.removeItem(at:cloudCopy)
 print("PASS: flat separate cloud sessions (YYYY-MM-DD Title.md + shared assets/Title-N.png), updated_at skip, in-place extension and edited-copy protection")
 // Koš: web → .trash, obnova z webu, obnova uživatelem, upravená kopie zůstává, trvalé smazání.
 let base=try Topics.checkedDestination(target.path)
 states[noteA]="trashed";await store.refresh(c);assert(store.lastError==nil)
 assert(markdowns().isEmpty && trashedMarkdowns()==["Cizí.md",nameA+".md"].sorted() && fm.fileExists(atPath:trash.appendingPathComponent("assets/"+nameA+"-2.png").path) && !fm.fileExists(atPath:assetsDir.appendingPathComponent(nameA+"-1.png").path) && trashed().contains("Cizí složka"))
 states[noteA]="active";await store.refresh(c);assert(markdowns()==[nameA+".md"] && trashedMarkdowns()==["Cizí.md"] && fm.fileExists(atPath:assetsDir.appendingPathComponent(nameA+"-1.png").path))
 states[noteA]="trashed";await store.refresh(c);assert(trashedMarkdowns().contains(nameA+".md"))
 try fm.moveItem(at:trash.appendingPathComponent(nameA+".md"),to:markdownA);await store.refresh(c)
 assert(restored==[noteA] && states[noteA]=="active" && markdowns()==[nameA+".md"] && fm.fileExists(atPath:assetsDir.appendingPathComponent(nameA+"-2.png").path) && SessionIndex.shared.cloud(noteA,base:base)?.trashed==false)
 let pristine=try Data(contentsOf:markdownA);try (pristine+Data("\nÚprava".utf8)).write(to:markdownA)
 states[noteA]="trashed";await store.refresh(c);await store.refresh(c)
 assert(markdowns()==[nameA+".md"] && store.notices.count==1 && !trashedMarkdowns().contains(nameA+".md"))
 try pristine.write(to:markdownA);await store.refresh(c);assert(trashedMarkdowns().contains(nameA+".md"))
 states[noteA]="purged";await store.refresh(c)
 assert(trashedMarkdowns()==["Cizí.md"] && !fm.fileExists(atPath:trash.appendingPathComponent("assets/"+nameA+"-1.png").path) && SessionIndex.shared.cloud(noteA,base:base)==nil && markdowns().isEmpty && fm.fileExists(atPath:assetsDir.path))
 print("PASS: separate trash flows: web trash, web restore, user restore via POST, modified copy kept with one notice, purge, unknown .trash entries untouched")
 states[noteA]="active"
 // Úprava nastavení: konflikt načte novou verzi, další pokus projde s revizí.
 var changed=topic;changed.name="Nový název";changed.combined=true
 do{_ = try await store.update(changed);assertionFailure("Conflict ignored")}catch let failure as CloudFailure{assert(failure.code=="folder_conflict")}
 assert(store.topics[0].name=="Jinde" && sent[0].1=="PUT" && sent[0].0=="/api/v1/folders/"+folderID.uuidString.lowercased() && sent[0].2["revision"] as? String=="1" && sent[0].2["markdown_template"] is NSNull)
 changed=store.topics[0];changed.name="Nový název"
 let saved=try await store.update(changed);assert(saved.name=="Nový název" && store.records[0].revision=="3" && sent[1].2["revision"] as? String=="2" && store.topics[0].folder==target.path)
 // Společný soubor se skládá ze všech relací; ruční úprava se nepřepíše.
 combined=true;folderName="Nový název";updated="t4";topic=store.topics[0];states[noteB]="active"
 await store.refresh(c);assert(store.lastError==nil)
 let all=target.appendingPathComponent("All.md"),stemB=readableSessionName("Druhá",created:parseServerDate(createdB)!)
 var text=try String(contentsOf:all,encoding:.utf8)
 assert(text.hasPrefix("# Nový název\n\n# Změna") && !text.contains("<!--") && text.contains("](<assets/"+stemB+"-1.png>)") && text.range(of:"Změna")!.lowerBound<text.range(of:"Druhá")!.lowerBound)
 topic=store.topics[0];let combinedSessions=try previousSessions(for:topic).filter{$0.target.path.hasSuffix("/cloud/All.md")}
 let stemA=readableSessionName("Změna",created:parseServerDate(createdA)!)
 assert(combinedSessions.count==2 && combinedSessions.contains{$0.images.count==2 && $0.images.allSatisfy{$0.hasPrefix(stemA)}})
 assert(store.serverImages(for:combinedSessions.first{$0.title=="Druhá"}!.target,topic:topic)?.0==noteB)
 // Koš ve společném režimu: blok zmizí a v koši je samostatná poznámka.
 let imageB=target.appendingPathComponent("assets/"+stemB+"-1.png"),trashedB=trash.appendingPathComponent(stemB+".md")
 states[noteB]="trashed";await store.refresh(c);text=try String(contentsOf:all,encoding:.utf8)
 assert(!text.contains("Druhá") && fm.fileExists(atPath:trashedB.path) && fm.fileExists(atPath:trash.appendingPathComponent("assets/"+stemB+"-1.png").path) && !fm.fileExists(atPath:imageB.path))
 assert((try! String(contentsOf:trashedB,encoding:.utf8)).contains("](<assets/"+stemB+"-1.png>)"))
 states[noteB]="active";await store.refresh(c);text=try String(contentsOf:all,encoding:.utf8)
 assert(text.range(of:"Změna")!.lowerBound<text.range(of:"Druhá")!.lowerBound && !fm.fileExists(atPath:trashedB.path) && fm.fileExists(atPath:imageB.path))
 states[noteB]="trashed";await store.refresh(c);restored=[]
 try fm.moveItem(at:trashedB,to:target.appendingPathComponent(stemB+".md"));await store.refresh(c);text=try String(contentsOf:all,encoding:.utf8)
 assert(restored==[noteB] && text.contains("Druhá") && fm.fileExists(atPath:imageB.path) && !fm.fileExists(atPath:target.appendingPathComponent(stemB+".md").path))
 states[noteB]="trashed";await store.refresh(c);states[noteB]="purged";await store.refresh(c)
 assert(!fm.fileExists(atPath:trashedB.path) && !fm.fileExists(atPath:trash.appendingPathComponent("assets/"+stemB+"-1.png").path) && !(try! String(contentsOf:all,encoding:.utf8)).contains("Druhá") && trashed().contains("Cizí.md"))
 print("PASS: combined trash flows: block removed and saved to .trash, web restore in created order, user restore via POST, purge")
 states[noteB]="active";updated="t5";await store.refresh(c);text=try! String(contentsOf:all,encoding:.utf8);assert(text.contains("Druhá"))
 try (text+"\nRuční poznámka\n").write(to:all,atomically:true,encoding:.utf8)
 title="Další";updated="t6";await store.refresh(c)
 assert(try! String(contentsOf:all,encoding:.utf8).hasSuffix("Ruční poznámka\n") && (try! String(contentsOf:target.appendingPathComponent("All_cloud.md"),encoding:.utf8)).contains("Další"))
 print("PASS: folder PUT with revision and conflict reload, combined file with readable asset names, discovery and local-edit protection")
 try await cloudLegacyMigrationTests()
 try await localDeletionTests()
 try await folderLifecycleTests()
 try await adoptedUploadTests()
 try await templateTests()
 try await flatLayoutTests()
 try await editAndCommentTests()
 try itemTemplateTests()
 try videoRecordingTests()
 try videoAnnotationTests()
 try await staleDraftTests()
 try await markdownLinkTests()
 try await teamFolderTests()
 // Nenamapované složky dostanou podsložky podle názvu bez kolizí.
 let other=CloudFolders(file:root.appendingPathComponent("other.json"),connection:{c},localTopics:{[]});other.activate(c)
 try other.accept([CloudFolderRecord(id:UUID(),name:"Práce/Klient",owner:owner,origin:c.endpoint),CloudFolderRecord(id:UUID(),name:"Práce:Klient",owner:owner,origin:c.endpoint)])
 let parent=root.appendingPathComponent("mapped");try FolderDialogs.assign(other.topics,root:parent,folders:other)
 assert(Set(other.topics.map{URL(fileURLWithPath:$0.folder).lastPathComponent})==["Práce_Klient","Práce_Klient 2"])
 // Existující neprázdný adresář se nepřebírá; prázdný ano.
 let busy=CloudFolders(file:root.appendingPathComponent("busy.json"),connection:{c},localTopics:{[]});busy.activate(c)
 try busy.accept([CloudFolderRecord(id:UUID(),name:"Plný",owner:owner,origin:c.endpoint),CloudFolderRecord(id:UUID(),name:"Prázdný",owner:owner,origin:c.endpoint)])
 let busyRoot=root.appendingPathComponent("busy");try fm.createDirectory(at:busyRoot.appendingPathComponent("Plný"),withIntermediateDirectories:true);try fm.createDirectory(at:busyRoot.appendingPathComponent("Prázdný"),withIntermediateDirectories:true)
 try "cizí".write(to:busyRoot.appendingPathComponent("Plný/Cizí.txt"),atomically:true,encoding:.utf8)
 try FolderDialogs.assign(busy.topics,root:busyRoot,folders:busy)
 assert(Set(busy.topics.map{URL(fileURLWithPath:$0.folder).lastPathComponent})==["Plný 2","Prázdný"])
 print("PASS: unmapped cloud folders map to sanitized, deduplicated subfolders")
}

/// Starší stažení s GUID názvy a značkami se převedou na čitelné názvy, upravená zůstanou.
@MainActor func cloudLegacyMigrationTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-legacy-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let c=cloudFixtureConnection(),owner=c.ownerID!,folderID=UUID(),clean=UUID(),dirty=UUID(),joined=UUID(),png=cloudFixturePNG(0.3)
 var combined=false
 let titles=[clean:"Čistá",dirty:"Upravená",joined:"Společná"],created="2026-02-01T08:00:00Z"
 func note(_ id:UUID)->[String:Any]{["id":id.uuidString,"title":titles[id]!,"comment":"Text","template":defaultMarkdownTemplate,"captions":["Popisek"],"updated_at":"t1","created_at":created,"trashed_at":NSNull(),"images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]}
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.contains("/images/"){return png}
  let data:Any
  if path=="/api/v1/folders"{data=["data":[["id":folderID.uuidString,"name":"Legacy","revision":"1","combined":combined,"combined_file":"All.md"]]]}
  else if path.contains("?"){data=["data":path.contains("state=trashed") ? []:(combined ? [joined]:[clean,dirty]).map{["id":$0.uuidString,"updated_at":"t1","trashed_at":NSNull()]},"pagination":["has_more":false]]}
  else{data=["data":note([clean,dirty,joined].first{path.contains($0.uuidString.lowercased())}!)]}
  return try JSONSerialization.data(withJSONObject:data)
 })
 await store.refresh(c)
 let target=root.appendingPathComponent("legacy");try fm.createDirectory(at:target,withIntermediateDirectories:true)
 let base=try Topics.checkedDestination(target.path)
 func receipt(_ id:UUID,_ kind:String,_ value:[String:Any])throws {
  let url=root.appendingPathComponent("Cloud Downloads").appendingPathComponent(sessionFingerprint(Data((CloudEndpoint(c.endpoint)!.url.absoluteString+owner.uuidString+base.path+id.uuidString+kind).utf8)))
  try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:value).write(to:url)
 }
 func digest(_ id:UUID)->String{sessionFingerprint(try! JSONEncoder.sorted.encode(try! JSONDecoder().decode(RemoteNote.self,from:JSONSerialization.data(withJSONObject:note(id)))))}
 for id in [clean,dirty] {
  let lower=id.uuidString.lowercased(),directory=target.appendingPathComponent(lower)
  try fm.createDirectory(at:directory.appendingPathComponent("assets"),withIntermediateDirectories:true);try png.write(to:directory.appendingPathComponent("assets/1.png"))
  let markdown=Data(legacyMarkdown(lower,titles[id]!,"Text",["1.png"]).0.utf8);try markdown.write(to:directory.appendingPathComponent("Note.md"))
  try receipt(id,"",["fingerprint":digest(id),"name":lower,"updated":"t1","shas":[sessionFingerprint(png)],"files":["Note.md":sessionFingerprint(markdown),"assets/1.png":sessionFingerprint(png)]])
  if id==dirty{try (markdown+Data("\nÚprava".utf8)).write(to:directory.appendingPathComponent("Note.md"))}
 }
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let readable=readableSessionName("Čistá",created:parseServerDate(created)!),names=((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()
 // Netknutá GUID složka se přejmenuje a zploští do kořene, upravená zůstává.
 assert(names==[dirty.uuidString.lowercased(),"assets",readable+".md"].sorted())
 let migrated=try String(contentsOf:target.appendingPathComponent(readable+".md"),encoding:.utf8)
 assert(!migrated.contains("<!--") && migrated.contains("](<assets/"+readable+"-1.png>)") && fm.fileExists(atPath:target.appendingPathComponent("assets/"+readable+"-1.png").path) && !fm.fileExists(atPath:target.appendingPathComponent(readable).path) && (try! String(contentsOf:target.appendingPathComponent(dirty.uuidString.lowercased()+"/Note.md"),encoding:.utf8)).hasSuffix("Úprava"))
 let found=try previousSessions(for:store.topics[0]);assert(found.count==2 && Set(found.compactMap(\.target.session))==Set([clean,dirty].map{$0.uuidString.lowercased()}))
 assert(store.serverImages(for:found.first{$0.title=="Čistá"}!.target,topic:store.topics[0])?.1==[sessionFingerprint(png)])
 // Společný režim: assets/<uuid>/N.png a starý soubor se značkami.
 combined=true;let lower=joined.uuidString.lowercased()
 try fm.createDirectory(at:target.appendingPathComponent("assets/"+lower),withIntermediateDirectories:true);try png.write(to:target.appendingPathComponent("assets/"+lower+"/1.png"))
 try receipt(joined,"combined",["fingerprint":digest(joined),"name":"","updated":"t1","shas":[sessionFingerprint(png)],"files":["1.png":sessionFingerprint(png)],"note":note(joined)])
 let old=Data(("# Legacy\n\n"+legacyMarkdown(lower,"Společná","Text",[lower+"/1.png"]).0).utf8);try old.write(to:target.appendingPathComponent("All.md"))
 try receipt(folderID,"combined-file:All.md",["fingerprint":sessionFingerprint(old),"name":"All.md"])
 await store.refresh(c);assert(store.lastError==nil)
 let stem=readableSessionName("Společná",created:parseServerDate(created)!),text=try String(contentsOf:target.appendingPathComponent("All.md"),encoding:.utf8)
 assert(!fm.fileExists(atPath:target.appendingPathComponent("assets/"+lower).path) && fm.fileExists(atPath:target.appendingPathComponent("assets/"+stem+"-1.png").path))
 assert(!text.contains("<!--") && text.contains("](<assets/"+stem+"-1.png>)") && !fm.fileExists(atPath:target.appendingPathComponent("All_cloud.md").path))
 print("PASS: legacy GUID downloads migrate to readable names when unmodified, edited ones stay, combined assets/<uuid> renamed")
}

@MainActor func localDeletionTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-deletion-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let f=try DeletionFixture(root.appendingPathComponent("separate"),count:5,combined:false);try await f.start()
 // Přejmenování a přesun uvnitř složky nejsou smazání.
 // Plochá složka: relace je její Markdown, obrázky leží ve společném assets/.
 assert(f.markdowns()==5 && f.directory(0).deletingLastPathComponent().lastPathComponent=="cloud")
 let renamed=f.target.appendingPathComponent("Přejmenováno.md"),moved=f.target.appendingPathComponent("Podsložka/Hluboko.md")
 try fm.moveItem(at:f.directory(0),to:renamed)
 try fm.createDirectory(at:moved.deletingLastPathComponent(),withIntermediateDirectories:true);try fm.moveItem(at:f.directory(1),to:moved)
 await f.scan(after:20);await f.scan(after:20)
 assert(f.posts.isEmpty && f.directory(0).lastPathComponent=="Přejmenováno.md" && f.directory(1).path.hasSuffix("Podsložka/Hluboko.md") && f.markdowns()==4)
 // Přesun do .trash se pošle hned a položka v .trash zůstává.
 let trash=f.target.appendingPathComponent(".trash");try fm.createDirectory(at:trash,withIntermediateDirectories:true)
 let image2=SessionIndex.shared.cloud(f.ids[2],base:try Topics.checkedDestination(f.target.path))!.images[0]
 let trashed=trash.appendingPathComponent(f.directory(2).lastPathComponent);try fm.moveItem(at:f.directory(2),to:trashed)
 await f.scan(after:5);assert(f.posts==[f.ids[2]] && fm.fileExists(atPath:trashed.path) && f.store.notices.last?.contains("Relace 2")==true)
 assert(fm.fileExists(atPath:trash.appendingPathComponent("assets/"+image2).path) && !fm.fileExists(atPath:f.target.appendingPathComponent("assets/"+image2).path))
 await f.scan(after:20);assert(fm.fileExists(atPath:trashed.path) && f.posts.count==1)
 // Přesun do .trash se nikdy neptá.
 assert(f.store.deletePrompts.isEmpty)
 // Smazání ve Finderu až po dvou průchodech alespoň 10 s od sebe; nejdřív dotaz.
 let deleted=f.directory(3);try fm.removeItem(at:deleted)
 await f.scan(after:20);assert(f.posts.count==1 && !fm.fileExists(atPath:deleted.path))
 await f.scan(after:5);assert(f.posts.count==1 && f.store.deletePrompts.isEmpty)
 await f.scan(after:10);assert(f.posts==[f.ids[2]] && !fm.fileExists(atPath:deleted.path) && f.store.deletePrompts.first?.1.map(\.id)==[f.ids[3].uuidString.lowercased()])
 await f.scan(after:20);assert(f.posts.count==1 && !fm.fileExists(atPath:deleted.path))
 // Přesunout do Koše + Příště se neptat: odešle se a další smazání už jde bez dotazu.
 var quiet:[String]=[];f.store.onTrashedQuietly={record,_ in quiet.append(record.id)}
 f.store.resolveDeletePrompt(f.store.topics[0],trash:true,suppress:true);await f.scan(after:5)
 assert(f.posts==[f.ids[2],f.ids[3]] && f.store.topics[0].confirmLocalDeletes==false && f.store.deletePrompts.isEmpty && quiet.isEmpty)
 // Neodeslané doplnění relace blokuje mazání.
 f.busy=[f.ids[4]];let busy=f.directory(4);try fm.removeItem(at:busy)
 await f.scan(after:20);await f.scan(after:20);assert(f.posts.count==2)
 assert(!fm.fileExists(atPath:busy.path));f.busy=[];await f.scan(after:20);assert(f.posts.count==3 && quiet==[f.ids[4].uuidString.lowercased()])
 // Zapnutí dotazu znovu (nastavení složky).
 try f.store.setConfirmLocalDeletes(f.store.topics[0],true);assert(f.store.topics[0].confirmLocalDeletes==nil)
 // Jiná složka se dál ptá; Obnovit na disku relaci znovu stáhne a nic neodešle.
 let o=try DeletionFixture(root.appendingPathComponent("ask"),count:5,combined:false);try await o.start()
 let lost=o.directory(0);try fm.removeItem(at:lost)
 await o.scan(after:20);await o.scan(after:20);assert(o.posts.isEmpty && o.store.deletePrompts.count==1 && o.markdowns()==4)
 o.store.resolveDeletePrompt(o.store.topics[0],trash:false,suppress:false);await o.scan(after:5)
 assert(o.posts.isEmpty && o.store.deletePrompts.isEmpty && o.markdowns()==5 && o.store.topics[0].confirmLocalDeletes==nil)
 // Dvě smazané relace najednou: jeden dotaz pro celou dávku.
 for i in 1..<3{try fm.removeItem(at:o.directory(i))}
 await o.scan(after:20);await o.scan(after:20);assert(o.store.deletePrompts.count==1 && o.store.deletePrompts[0].1.count==2 && o.posts.isEmpty)
 print("PASS: local rename/move inside folder keeps session, move to .trash trashes on web at once, Finder delete after two scans, pending upload blocks")
 // Chybějící kořen: nic se neposílá ani nevytváří.
 let g=try DeletionFixture(root.appendingPathComponent("rootless"),count:3,combined:false);try await g.start()
 let away=g.root.appendingPathComponent("away");try fm.moveItem(at:g.target,to:away)
 await g.scan(after:20);await g.scan(after:20);assert(g.posts.isEmpty && !fm.fileExists(atPath:g.target.path))
 try! fm.moveItem(at:away,to:g.target);await g.scan(after:20);assert(g.posts.isEmpty)
 // Vyměněný prázdný kořen se nebere jako smazání všech relací.
 try fm.moveItem(at:g.target,to:away);try fm.createDirectory(at:g.target,withIntermediateDirectories:true)
 await g.scan(after:20);await g.scan(after:20);await g.scan(after:20);assert(g.posts.isEmpty && g.store.heldFolders.isEmpty && g.markdowns()==3)
 // Hromadné zmizení se zadrží a pošle až po potvrzení.
 let h=try DeletionFixture(root.appendingPathComponent("mass"),count:7,combined:false);try await h.start()
 for i in 0..<6{try fm.removeItem(at:h.directory(i))}
 await h.scan(after:20);await h.scan(after:20);await h.scan(after:20)
 assert(h.posts.isEmpty && h.store.notices.filter{$0.contains("zmizelo 6")}.count==1 && h.store.heldFolders.first?.1==6 && h.store.deletePrompts.isEmpty)
 assert(h.markdowns()==1)
 h.store.resolveHeld(h.store.topics[0],trash:true);await h.scan(after:5);assert(Set(h.posts)==Set(h.ids.prefix(6)) && h.store.heldFolders.isEmpty)
 // Po vyřešení dávky upozornění zmizí.
 assert(!h.store.notices.contains{$0.contains("6")})
 let language=AppLanguage.override;defer{AppLanguage.override=language}
 let forms=("Ve složce %@ zmizela %ld relace. Přesunout ji do Koše na webu? Lze ji obnovit 30 dní.","Ve složce %@ zmizely %ld relace. Přesunout je do Koše na webu? Lze je obnovit 30 dní.","Ve složce %@ zmizelo %ld relací. Přesunout je do Koše na webu? Lze je obnovit 30 dní.")
 AppLanguage.override="cs"
 assert(LP(1,forms.0,forms.1,forms.2,"X",1).hasPrefix("Ve složce X zmizela 1 relace.") && LP(3,forms.0,forms.1,forms.2,"X",3).hasPrefix("Ve složce X zmizely 3 relace.") && LP(5,forms.0,forms.1,forms.2,"X",5).hasPrefix("Ve složce X zmizelo 5 relací.") && LP(0,forms.0,forms.1,forms.2,"X",0).contains("zmizelo 0 relací"))
 AppLanguage.override="en"
 assert(LP(1,forms.0,forms.1,forms.2,"X",1).hasPrefix("1 session disappeared from folder X.") && LP(3,forms.0,forms.1,forms.2,"X",3).hasPrefix("3 sessions disappeared"))
 AppLanguage.override=language
 // Znovu stáhnout: dávka se zruší a soubory se vrátí.
 let k2=try DeletionFixture(root.appendingPathComponent("mass-restore"),count:3,combined:false);try await k2.start()
 for i in 0..<3{try fm.removeItem(at:k2.directory(i))}
 await k2.scan(after:20);await k2.scan(after:20);assert(k2.store.heldFolders.first?.1==3 && k2.store.notices.count==1)
 k2.store.resolveHeld(k2.store.topics[0],trash:false);await k2.scan(after:5)
 assert(k2.posts.isEmpty && k2.store.heldFolders.isEmpty && k2.store.notices.isEmpty && k2.markdowns()==3)
 print("PASS: missing or swapped root does nothing, mass deletion is held with one warning until confirmed")
 // Společný soubor: odebraný blok jde do Koše, smazaný celý soubor se jen obnoví.
 let k=try DeletionFixture(root.appendingPathComponent("combined"),count:3,combined:true);try await k.start();try k.store.setConfirmLocalDeletes(k.store.topics[0],false)
 let all=k.target.appendingPathComponent("All.md");var text=try String(contentsOf:all,encoding:.utf8)
 let block=SessionIndex.shared.cloud(k.ids[1],base:try Topics.checkedDestination(k.target.path))!
 let range=NSRange(location:block.start,length:block.length);text=(text as NSString).replacingCharacters(in:range,with:"")
 try text.replacingOccurrences(of:"\n\n---\n\n\n\n---\n\n",with:"\n\n---\n\n").write(to:all,atomically:true,encoding:.utf8)
 await k.scan(after:20);assert(k.posts.isEmpty);await k.scan(after:20);assert(k.posts==[k.ids[1]])
 await k.scan(after:20);assert(fm.fileExists(atPath:k.target.appendingPathComponent(".trash/"+block.stem!+".md").path))
 let l=try DeletionFixture(root.appendingPathComponent("regenerate"),count:3,combined:true);try await l.start()
 let regenerated=l.target.appendingPathComponent("All.md");try fm.removeItem(at:regenerated)
 await l.scan(after:20);await l.scan(after:20);assert(l.posts.isEmpty && fm.fileExists(atPath:regenerated.path) && (try! String(contentsOf:regenerated,encoding:.utf8)).contains("Relace 2"))
 print("PASS: combined block removal trashes the session after two scans, deleted combined file is regenerated without trashing")
}

/// Životní cyklus složek: odhlášení, znovupropojení, smazání na webu a v aplikaci.
@MainActor func folderLifecycleTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-lifecycle-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 for combined in [false,true] {
  let c=cloudFixtureConnection(),owner=c.ownerID!,folderID=UUID(),a=UUID(),b=UUID(),extra=UUID(),png=cloudFixturePNG(0.7),base=root.appendingPathComponent(combined ? "combined":"separate")
  var listed=[a,b],titles=[a:"Stejná",b:"Rozdílná",extra:"Jen v cloudu"],local:[Topic]=[],recycled:[URL]=[],connection:CloudConnection?=c
  let store=CloudFolders(file:base.appendingPathComponent("folders.json"),connection:{connection},localTopics:{local},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
   if path.contains("/images/"){return png}
   let data:Any
   if path=="/api/v1/folders"{data=["data":[["id":folderID.uuidString,"name":"Projekt","revision":"1","description":"Popis","combined":combined,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":NSNull()]]]}
   else if path.contains("?"){data=["data":path.contains("state=trashed") ? []:listed.map{["id":$0.uuidString,"updated_at":"t1","trashed_at":NSNull()]},"pagination":["has_more":false]]}
   else{let id=[a,b,extra].first{path.contains($0.uuidString.lowercased())}!;data=["data":["id":id.uuidString,"title":titles[id]!,"comment":"Text","template":defaultMarkdownTemplate,"captions":[""],"updated_at":"t1","created_at":"2026-02-0\(listed.firstIndex(of:id).map{$0+1} ?? 1)T10:00:00Z","images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]}
   return try JSONSerialization.data(withJSONObject:data)
  },storedLocal:{local},saveLocal:{local=$0},recycle:{recycled.append($0)})
  let target=base.appendingPathComponent("cloud")
  await store.refresh(c);try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
  let checked=try Topics.checkedDestination(target.path),recordB=SessionIndex.shared.cloud(b,base:checked)!
  // Odhlášení: složka zůstane lokální se stejným nastavením a soubory.
  let before=try fm.contentsOfDirectory(atPath:target.path).sorted()
  connection=nil;store.activate(nil)
  let mapping=try store.convertToLocal(owner:owner,origin:c.endpoint)
  assert(local.count==1 && local[0].folder==target.path && local[0].combined==combined && local[0].detail=="Popis" && local[0].formerCloudFolderID==folderID && local[0].formerCloudOwnerID==owner && local[0].formerCloudOrigin==c.endpoint)
  assert(store.records.isEmpty && mapping.values.contains(local[0].id) && (try! fm.contentsOfDirectory(atPath:target.path)).sorted()==before && SessionIndex.shared.cloud(b,base:checked)?.folder==folderID.uuidString.lowercased())
  // Mezitím: lokální úprava, nová lokální relace a nová relace v cloudu.
  if combined {
   let all=target.appendingPathComponent("All.md");try (try String(contentsOf:all,encoding:.utf8)).replacingOccurrences(of:"# Rozdílná",with:"# Rozdílná místně").write(to:all,atomically:true,encoding:.utf8)
  } else {try (try String(contentsOf:URL(fileURLWithPath:recordB.file),encoding:.utf8)+"\nMístní úprava\n").write(toFile:recordB.file,atomically:true,encoding:.utf8)}
  let capture=base.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true);try png.write(to:capture.appendingPathComponent("n.png"))
  try finishSession(Draft(images:["n.png"],comment:"Offline",title:"Jen lokálně",topic:local[0]),root:capture)
  listed.append(extra)
  // Znovupřihlášení: nabídka jen pro stejného vlastníka a origin.
  var foreign=local[0];foreign.id="foreign";foreign.folder=base.appendingPathComponent("foreign").path;foreign.formerCloudOwnerID=UUID();local.append(foreign)
  connection=c;await store.refresh(c);assert(store.lastError==nil && store.repairCandidates.map(\.id)==[local[0].id])
  let vault=CloudMemoryVault();vault.value=c
  let library=CloudLibrary(queue:base.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(c.endpoint)!)
  let done=try await store.repair(local[0],library:library,transfers:FolderTransfers(directory:base.appendingPathComponent("transfers")))
  // Nahrává se jen lokální relace, vždy se složkou.
  assert(!done && library.pendingCount==1)
  let job=try fm.contentsOfDirectory(at:base.appendingPathComponent("outbox"),includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])[0]
  let manifest=(try JSONSerialization.jsonObject(with:Data(contentsOf:job.appendingPathComponent("job.json"))) as! [String:Any])["manifest"] as! [String:Any]
  assert(manifest["folder_id"] as? String==folderID.uuidString.lowercased() || manifest["folder_id"] as? String==folderID.uuidString)
  assert(manifest["title"] as? String=="Jen lokálně")
  try store.finishTransfer(local[0],to:store.topics[0]);assert(store.topics[0].folder==target.path && store.repairCandidates.isEmpty)
  await store.refresh(c);assert(store.lastError==nil)
  if combined {
   let main=try String(contentsOf:target.appendingPathComponent("All.md"),encoding:.utf8),copy=try String(contentsOf:target.appendingPathComponent("All_cloud.md"),encoding:.utf8)
   assert(main.contains("# Rozdílná místně") && main.contains("Jen lokálně") && !main.contains("Jen v cloudu") && copy.contains("# Rozdílná\n") && copy.contains("Jen v cloudu"))
  } else {
   let directory=URL(fileURLWithPath:recordB.file).deletingLastPathComponent(),name=(URL(fileURLWithPath:recordB.file).lastPathComponent as NSString).deletingPathExtension
   let recordA=SessionIndex.shared.cloud(a,base:checked)!
   assert((try! String(contentsOf:URL(fileURLWithPath:recordB.file),encoding:.utf8)).hasSuffix("Místní úprava\n") && fm.fileExists(atPath:directory.appendingPathComponent(name+"_cloud.md").path))
   assert(!fm.fileExists(atPath:recordA.directory.appendingPathComponent((URL(fileURLWithPath:recordA.file).lastPathComponent as NSString).deletingPathExtension+"_cloud.md").path))
   assert(SessionIndex.shared.cloud(extra,base:checked) != nil && fm.fileExists(atPath:SessionIndex.shared.cloud(extra,base:checked)!.file))
  }
  print("PASS: \(combined ? "combined":"separate") logout → local conversion keeps settings/files/index, re-pair offer per owner/origin, reconciliation uploads only local sessions with folder_id, cloud-only downloaded, identical untouched, differing → _cloud.md")
 }
 // Složka smazaná na webu: zachovat, obnovit před odpovědí, smazat; mazání v aplikaci.
 let c=cloudFixtureConnection(),owner=c.ownerID!,folderID=UUID();var present=true,local:[Topic]=[],recycled:[URL]=[],sent:[String]=[],trashStatus:CloudFailure?=nil
 let base=root.appendingPathComponent("deleted"),dir=base.appendingPathComponent("dir");try fm.createDirectory(at:dir,withIntermediateDirectories:true);try Data("cizí".utf8).write(to:dir.appendingPathComponent("Moje.md"))
 let store=CloudFolders(file:base.appendingPathComponent("folders.json"),connection:{c},localTopics:{local},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.hasPrefix("/api/v1/folders"){return try JSONSerialization.data(withJSONObject:["data":present ? [["id":folderID.uuidString,"name":"Web","revision":"1"]]:[]])}
  return try JSONSerialization.data(withJSONObject:["data":[],"pagination":["has_more":false]])
 },send:{_,path,_,_,_ in sent.append(path);if let failure=trashStatus{throw failure};return try JSONSerialization.data(withJSONObject:["data":["id":folderID.uuidString]])},storedLocal:{local},saveLocal:{local=$0},recycle:{recycled.append($0)})
 await store.refresh(c);try store.setFolder(store.topics[0],path:dir.path)
 present=false;await store.refresh(c);assert(store.topics.isEmpty && store.deletedRemotely.count==1 && store.hasUnknownFiles(dir.path))
 present=true;await store.refresh(c);assert(store.deletedRemotely.isEmpty && store.topics[0].folder==dir.path)
 present=false;await store.refresh(c);try store.keepDeleted(folderID)
 assert(local.count==1 && local[0].folder==dir.path && store.records.isEmpty && recycled.isEmpty && fm.fileExists(atPath:dir.appendingPathComponent("Moje.md").path))
 local=[];present=true;await store.refresh(c);try store.setFolder(store.topics[0],path:dir.path)
 // Adresář s cizím souborem a bez relací: do Koše nejde nic, cizí soubor zůstává.
 present=false;await store.refresh(c);try store.discardDeleted(folderID);assert(recycled.isEmpty && store.records.isEmpty && local.isEmpty && fm.fileExists(atPath:dir.appendingPathComponent("Moje.md").path))
 // Smazání v aplikaci: lokální jen do Koše v macOS, cloudová i na serveru; starý server nic nesmaže.
 recycled=[];present=true;await store.refresh(c);try store.setFolder(store.topics[0],path:dir.path)
 trashStatus=CloudFailure("404",status:404);do{try await store.trashFolder(store.topics[0]);assertionFailure("Unsupported server accepted")}catch{}
 assert(recycled.isEmpty && store.topics.count==1)
 // Známá relace v adresáři s cizím souborem: do Koše jde jen její Markdown a obrázek, ne celý adresář.
 let known=dir.appendingPathComponent("Relace.md"),knownImage=dir.appendingPathComponent("assets/Relace-1.png")
 try fm.createDirectory(at:knownImage.deletingLastPathComponent(),withIntermediateDirectories:true);try "# Relace\n".write(to:known,atomically:true,encoding:.utf8);try cloudFixturePNG().write(to:knownImage)
 SessionIndex.shared.put(SessionRecord(id:UUID().uuidString.lowercased(),file:SessionIndex.key(known),start:0,length:9,hash:"",heading:"# Relace",title:"Relace",comment:"",template:defaultMarkdownTemplate,images:["Relace-1.png"],notes:[:],combined:false,footer:"",files:[:],seen:0,base:SessionIndex.key(dir),folder:folderID.uuidString.lowercased(),owner:owner.uuidString.lowercased(),origin:c.endpoint))
 assert(store.hasUnknownFiles(dir.path))
 trashStatus=nil;try await store.trashFolder(store.topics[0])
 assert(sent.last=="/api/v1/folders/"+folderID.uuidString.lowercased()+"/trash" && Set(recycled.map{SessionIndex.key($0)})==Set([SessionIndex.key(known),SessionIndex.key(knownImage)]) && store.records.isEmpty)
 // Bez cizích souborů jde do Koše celý adresář jako dřív.
 try fm.removeItem(at:dir.appendingPathComponent("Moje.md"));assert(!store.hasUnknownFiles(dir.path))
 recycled=[];present=true;await store.refresh(c);try store.setFolder(store.topics[0],path:dir.path);try await store.trashFolder(store.topics[0]);assert(recycled.map(\.path)==[dir.path])
 let localTopic=Topic(id:"plain",name:"Lokální",detail:"",folder:base.appendingPathComponent("plain").path,combined:false,combinedFile:"N.md");try fm.createDirectory(atPath:localTopic.folder,withIntermediateDirectories:true)
 local=[localTopic];let calls=sent.count;try store.deleteLocalFolder(localTopic)
 assert(local.isEmpty && recycled.last?.path==localTopic.folder && sent.count==calls)
 print("PASS: web-deleted folder keep/restore-before-answer/delete to macOS Trash, app delete of local vs cloud folder, unsupported server keeps everything")
 print("PASS: folder delete moves only indexed notes/images when the directory holds foreign files, whole directory otherwise")
 // Starší podsložka relace: známé jsou jen její Markdown a assets/<obrázek>; cizí soubor uvnitř ji nedovolí smazat celou.
 let tree=base.appendingPathComponent("tree"),sub=tree.appendingPathComponent("Starší"),subMarkdown=sub.appendingPathComponent("Starší.md"),subImage=sub.appendingPathComponent("assets/1.png")
 try fm.createDirectory(at:subImage.deletingLastPathComponent(),withIntermediateDirectories:true);try "# Starší\n".write(to:subMarkdown,atomically:true,encoding:.utf8);try cloudFixturePNG().write(to:subImage)
 SessionIndex.shared.put(SessionRecord(id:UUID().uuidString.lowercased(),file:SessionIndex.key(subMarkdown),start:0,length:10,hash:"",heading:"# Starší",title:"Starší",comment:"",template:defaultMarkdownTemplate,images:["1.png"],notes:[:],combined:false,footer:"",files:["Starší.md":"","assets/1.png":""],seen:0,base:SessionIndex.key(tree),folder:UUID().uuidString.lowercased()))
 assert(!store.hasUnknownFiles(tree.path) && store.knownItems(tree).map{SessionIndex.key($0)}==[SessionIndex.key(sub)])
 try "cizí".write(to:tree.appendingPathComponent("Kořen.txt"),atomically:true,encoding:.utf8)
 assert(store.hasUnknownFiles(tree.path) && store.knownItems(tree).map{SessionIndex.key($0)}==[SessionIndex.key(sub)])
 try "cizí".write(to:sub.appendingPathComponent("Poznámka.txt"),atomically:true,encoding:.utf8);try "cizí".write(to:sub.appendingPathComponent("assets/2.png"),atomically:true,encoding:.utf8)
 assert(store.hasUnknownFiles(tree.path) && Set(store.knownItems(tree).map{SessionIndex.key($0)})==Set([SessionIndex.key(subMarkdown),SessionIndex.key(subImage)]))
 try fm.removeItem(at:tree.appendingPathComponent("Kořen.txt"));assert(store.hasUnknownFiles(tree.path))
 print("PASS: session subfolders count as known only when they hold nothing but the session's Markdown and assets; unknown files are checked recursively")
 // Nahrávání do složky v Koši se odloží s jasnou zprávou.
 let vault=CloudMemoryVault();var conn=cloudFixtureConnection();conn.expiresAt="2099-01-01T00:00:00Z";vault.value=conn;TrashedFolderStub.owner=conn.ownerID!
 let library=CloudLibrary(queue:base.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(conn.endpoint)!)
 let cloudTopic=Topic(id:"t",name:"T",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:UUID(),cloudOwnerID:conn.ownerID,cloudOrigin:conn.endpoint)
 let shots=base.appendingPathComponent("shots");try fm.createDirectory(at:shots,withIntermediateDirectories:true);try cloudFixturePNG().write(to:shots.appendingPathComponent("s.png"))
 try library.enqueue(Draft(images:["s.png"],comment:"",title:"Do koše",topic:cloudTopic),root:shots,folders:[cloudTopic])
 let saved=CloudTransport.shared.session,config=URLSessionConfiguration.ephemeral;config.protocolClasses=[TrashedFolderStub.self]
 CloudTransport.shared.session=URLSession(configuration:config);defer{CloudTransport.shared.session=saved}
 await library.sync()
 let parked=(try? fm.contentsOfDirectory(atPath:base.appendingPathComponent("outbox/.conflicts").path)) ?? []
 assert(library.pendingCount==0 && parked.count==1 && library.lastError?.contains("Koši")==true)
 print("PASS: upload into a trashed cloud folder is parked with a clear message")
}
