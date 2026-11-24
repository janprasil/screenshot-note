import AppKit
@testable import ScreenshotNoteKit

/// Nahraná místní relace se po přesunu i znovupropojení nestáhne podruhé.
@MainActor func adoptedUploadTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-adopt-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let saved=CloudTransport.shared.session,config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AcceptingUploadStub.self]
 CloudTransport.shared.session=URLSession(configuration:config);defer{CloudTransport.shared.session=saved}
 for combined in [false,true] {
  AcceptingUploadStub.manifests=[]
  let c=cloudFixtureConnection(),folderID=UUID(),base=root.appendingPathComponent(combined ? "combined":"separate"),dir=base.appendingPathComponent("notes")
  AcceptingUploadStub.owner=c.ownerID!
  var local=[Topic(id:"local",name:"Poznámky",detail:"",folder:dir.path,combined:combined,combinedFile:"All.md")],connection:CloudConnection?=c,details=0
  var gone=Set<UUID>(),purged=Set<UUID>(),restoredIDs:[UUID]=[]
  weak var weakStore:CloudFolders?
  let store=CloudFolders(file:base.appendingPathComponent("folders.json"),connection:{connection},localTopics:{local.filter{!(weakStore?.migratedLocalIDs.contains($0.id) ?? false)}},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
   if path=="/api/v1/folders"{return try JSONSerialization.data(withJSONObject:["data":[["id":folderID.uuidString,"name":"Poznámky","revision":"1","combined":combined,"combined_file":"All.md"]]])}
   if path.contains("?") {
    let wanted=path.contains("state=trashed"),items=AcceptingUploadStub.manifests.filter{!purged.contains($0.0) && gone.contains($0.0)==wanted}
    return try JSONSerialization.data(withJSONObject:["data":items.map{["id":$0.0.uuidString,"updated_at":"t1","trashed_at":wanted ? "2026-03-02T00:00:00Z":NSNull()]},"pagination":["has_more":false]])
   }
   let (id,manifest)=AcceptingUploadStub.manifests.first{path.contains($0.0.uuidString.lowercased())}!
   if purged.contains(id){throw CloudFailure("404",status:404,code:"not_found")}
   if path.contains("/images/"){return try Data(contentsOf:base.appendingPathComponent("outbox-images/"+id.uuidString.lowercased()+"-"+String(path.split(separator:"/").last!)+".png"))}
   details+=1;let count=(manifest["images"] as! [Any]).count
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString,"title":manifest["title"]!,"comment":manifest["comment"]!,"template":manifest["template"]!,"captions":manifest["captions"]!,"updated_at":"t1","created_at":"2026-03-01T10:00:00Z","images":(1...count).map{["index":$0,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/\($0)"]}]])
  },send:{_,path,_,_,_ in
   let id=AcceptingUploadStub.manifests.first{path.contains($0.0.uuidString.lowercased())}!.0
   if path.hasSuffix("/restore"){gone.remove(id);restoredIDs.append(id)}else{gone.insert(id)}
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString]])
  },storedLocal:{local},saveLocal:{local=$0})
  weakStore=store
  let capture=base.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
  func save(_ title:String,_ red:CGFloat)throws{try cloudFixturePNG(red).write(to:capture.appendingPathComponent("s.png"));try finishSession(Draft(images:["s.png"],comment:title+" text",title:title,topic:local.first{$0.id != "x"}!),root:capture)}
  try save("První",0.1);try save("Druhá",0.2)
  func snapshot()->[String]{((fm.enumerator(atPath:dir.path)?.allObjects as? [String]) ?? []).filter{!$0.hasPrefix(".") && !$0.contains("/.")}.sorted()}
  let vault=CloudMemoryVault();vault.value=c
  let library=CloudLibrary(queue:base.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(c.endpoint)!),transfers=FolderTransfers(directory:base.appendingPathComponent("transfers"))
  // Serverové bajty obrázků = převod místního originálu, jako při skutečném nahrání.
  func mirrorImages()throws {
   try fm.createDirectory(at:base.appendingPathComponent("outbox-images"),withIntermediateDirectories:true)
   for session in try previousSessions(in:dir) where session.target.session.flatMap(UUID.init(uuidString:)).map({id in AcceptingUploadStub.manifests.contains{$0.0==id}})==true {
    for (i,image) in session.images.enumerated(){try cloudImage(dir.appendingPathComponent("assets/"+image)).write(to:base.appendingPathComponent("outbox-images/"+session.target.session!.lowercased()+"-\(i+1).png"))}
   }
  }
  await store.refresh(c)
  let before=snapshot()
  let moved=try await transfers.move(local[0],to:store.topics[0],library:library,folders:store)
  assert(moved && AcceptingUploadStub.manifests.count==2 && store.topics[0].folder==dir.path && AcceptingUploadStub.manifests.allSatisfy{$0.1["folder_id"] as? String==folderID.uuidString.lowercased() || $0.1["folder_id"] as? String==folderID.uuidString})
  try mirrorImages()
  await store.refresh(c);await store.refresh(c);assert(store.lastError==nil)
  assert(snapshot()==before && details==2)
  let topic=store.topics[0],found=try previousSessions(for:topic)
  assert(found.count==2 && Set(found.compactMap{$0.target.session})==Set(AcceptingUploadStub.manifests.map{$0.0.uuidString.lowercased()}) && found.allSatisfy{store.serverImages(for:$0.target,topic:topic)?.1.count==1})
  // Odhlášení, nová lokální relace a znovupropojení: opět žádná druhá kopie.
  connection=nil;store.activate(nil);try store.convertToLocal(owner:c.ownerID!,origin:c.endpoint)
  try save("Offline",0.3);let offline=snapshot()
  connection=c;await store.refresh(c);assert(store.repairCandidates.count==1)
  let repaired=try await store.repair(store.repairCandidates[0],library:library,transfers:FolderTransfers(directory:base.appendingPathComponent("transfers2")))
  assert(repaired && AcceptingUploadStub.manifests.count==3 && AcceptingUploadStub.manifests.last?.1["title"] as? String=="Offline")
  try mirrorImages()
  await store.refresh(c);await store.refresh(c);assert(store.lastError==nil)
  assert(snapshot()==offline && (try! previousSessions(for:store.topics[0])).count==3)
  print("PASS: \(combined ? "combined":"separate") uploaded local sessions are adopted in place after transfer and re-pair, no duplicate download or _cloud copy")
  // Koš u převzatých relací: obrázky jdou s relací do .trash, sdílený se jen zkopíruje.
  let trash=dir.appendingPathComponent(".trash"),assets=dir.appendingPathComponent("assets")
  func id(_ title:String)->UUID{AcceptingUploadStub.manifests.first{$0.1["title"] as? String==title}!.0}
  func exists(_ path:String)->Bool{fm.fileExists(atPath:dir.appendingPathComponent(path).path)}
  let P=readableSessionName("První",created:Date()),D=readableSessionName("Druhá",created:Date())
  try "Ruční odkaz ![[assets/\(P)-1.png]]\n".write(to:dir.appendingPathComponent("Ručně.md"),atomically:true,encoding:.utf8)
  let markdown=combined ? readableSessionName("Druhá",created:Date()):"Druha"
  gone.insert(id("První"));gone.insert(id("Druhá"));await store.refresh(c);assert(store.lastError==nil)
  assert(exists("assets/\(P)-1.png") && exists(".trash/assets/\(P)-1.png") && !exists("assets/\(D)-1.png") && exists(".trash/assets/\(D)-1.png") && exists("Ručně.md") && exists("assets"))
  if !combined{assert(!exists("\(P).md") && exists(".trash/\(P).md") && !exists("\(D).md") && exists(".trash/\(D).md"))}
  else{assert((try! fm.contentsOfDirectory(atPath:trash.path)).filter{$0.hasSuffix(".md")}.count==2)}
  // Obnova z webu vrací obrázky a maže kopii sdíleného.
  gone.remove(id("První"));await store.refresh(c)
  assert(exists("assets/\(P)-1.png") && !exists(".trash/assets/\(P)-1.png") && (combined || (exists("\(P).md") && !exists(".trash/\(P).md"))))
  // Uživatel vrátí Markdown z .trash: obnoví se i na webu a obrázek se vrátí.
  let trashedMarkdown=try fm.contentsOfDirectory(atPath:trash.path).first{$0.hasSuffix(".md") && (combined ? sessionTagIDs(trash.appendingPathComponent($0))==[id("Druhá").uuidString.lowercased()]:$0=="\(D).md")}!
  try fm.moveItem(at:trash.appendingPathComponent(trashedMarkdown),to:dir.appendingPathComponent(trashedMarkdown));await store.refresh(c)
  assert(restoredIDs.contains(id("Druhá")) && exists("assets/\(D)-1.png") && !exists(".trash/assets/\(D)-1.png"))
  _ = markdown
  // Trvalé smazání odstraní jen to, co šlo do .trash s relací.
  if combined,fm.fileExists(atPath:dir.appendingPathComponent(trashedMarkdown).path){try fm.removeItem(at:dir.appendingPathComponent(trashedMarkdown))}
  gone.insert(id("Druhá"));await store.refresh(c);assert(exists(".trash/assets/\(D)-1.png"))
  purged.insert(id("Druhá"));await store.refresh(c)
  assert(!exists(".trash/assets/\(D)-1.png") && !(try! fm.contentsOfDirectory(atPath:trash.path)).contains{$0.hasSuffix(".md") && $0.contains("Druh")} && exists("assets") && exists("Ručně.md") && fm.fileExists(atPath:dir.path))
  if !combined {
   // Uživatel přesune Markdown z kořene do .trash: jde do Koše na webu i s obrázky.
   try fm.removeItem(at:dir.appendingPathComponent("Ručně.md"));try fm.moveItem(at:dir.appendingPathComponent("\(P).md"),to:trash.appendingPathComponent("\(P).md"))
   await store.refresh(c);assert(gone.contains(id("První")) && exists(".trash/assets/\(P)-1.png") && !exists("assets/\(P)-1.png") && exists(".trash/\(P).md"))
   // Obsazený název obrázku při obnově z webu: obrázek dostane nový název a odkaz i záznam se přepíšou.
   try Data("cizí obrázek".utf8).write(to:assets.appendingPathComponent("\(P)-1.png"))
   // Video u posteru v koši se při obnově přejmenuje spolu s ním.
   let trashedVideo=assetVideoFiles(trash.appendingPathComponent("assets"),"\(P)-1.png")
   try Data([1]).write(to:trashedVideo[0]);try fm.createDirectory(at:trashedVideo[1],withIntermediateDirectories:true)
   gone.remove(id("První"));await store.refresh(c);assert(exists("\(P).md") && exists("assets/\(P)-1.png") && !exists(".trash/assets/\(P)-1.png"))
   let restoredText=try String(contentsOf:dir.appendingPathComponent("\(P).md"),encoding:.utf8),record=SessionIndex.shared.cloud(id("První"),base:try Topics.checkedDestination(dir.path))!
   assert(imageLinkNames(restoredText)==["\(P)-1 2.png"] && record.images==["\(P)-1 2.png"] && record.files["assets/\(P)-1 2.png"] != nil && exists("assets/\(P)-1 2.png") && (try! Data(contentsOf:assets.appendingPathComponent("\(P)-1.png")))==Data("cizí obrázek".utf8))
   assert(record.files["\(P).md"]==fileHash(dir.appendingPathComponent("\(P).md")))
   assert(exists("assets/\(P)-1 2.mp4") && exists("assets/\(P)-1 2.frames") && !exists(".trash/assets/\(P)-1.mp4"))
   print("PASS: web restore with an occupied image name renames the image and rewrites Markdown links and the index record")
  }
  _ = assets
  print("PASS: \(combined ? "combined":"separate") adopted session trash/restore/purge moves its images with it, copies a shared image, user restore from .trash, root and assets/ untouched")
 }
}

/// Úpravy textu cloudových relací (PATCH, sloučení, konflikt) a vykreslení {comments}.
@MainActor func editAndCommentTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-edits-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 // {comments}: výchozí šablona bez komentářů nemá na konci nic navíc.
 assert(renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:"S",text:"X")==renderSessionTemplate(legacyDefaultMarkdownTemplate,title:"T",screenshots:"S",text:"X"))
 let first=RemoteNote.Comment(author_name:"Jan",body:"Ahoj",created_at:"2026-05-01T10:00:00Z"),second=RemoteNote.Comment(author_name:"Eva",body:"Druhý\nřádek",created_at:"2026-05-02T08:30:00.123456+00:00")
 let stamp1=formatTemplateDate(parseServerDate(first.created_at)!),stamp2=formatTemplateDate(parseServerDate(second.created_at)!)
 assert(renderCommentList([],template:nil)=="" && renderCommentList([first],template:nil)=="Ahoj\n\n`Jan` - `\(stamp1)`" && renderCommentList([first,second],template:nil)=="Ahoj\n\n`Jan` - `\(stamp1)`\n\nDruhý\nřádek\n\n`Eva` - `\(stamp2)`")
 // JSON bez pole image_index dekóduje nil.
 let imageComment=try JSONDecoder().decode(RemoteNote.Comment.self,from:Data(#"{"author_name":"A","body":"b","created_at":null,"image_index":3}"#.utf8))
 let sessionComment=try JSONDecoder().decode(RemoteNote.Comment.self,from:Data(#"{"body":"b"}"#.utf8))
 assert(imageComment.image_index==3 && sessionComment.image_index==nil)
 let withComments=renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:"![[assets/a.png]]",text:"X",comments:renderCommentList([first],template:nil))
 assert(withComments.hasSuffix("# Description\n\nX\n\nAhoj\n\n`Jan` - `\(stamp1)`\n"))
 assert(parsedSession(defaultMarkdownTemplate,withComments)?.1=="X" && parsedSession(defaultMarkdownTemplate,renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:"![[assets/a.png]]",text:"X"))?.1=="X")
 var note=RemoteNote(id:UUID(),title:"T",comment:"X",template:defaultMarkdownTemplate,captions:[""],images:[.init(index:1,path:"/p")]);note.comments=[first]
 assert(cloudSessionBody(note,images:["a.png"]).contains("`Jan` - `"))
 print("PASS: {comments} rendering for 0/1/N comments in local time, default template without trailing junk, parsing with and without comments")
 // Úprava jen textu jde PATCHem s revizí.
 let saved=CloudTransport.shared.session,config=URLSessionConfiguration.ephemeral;config.protocolClasses=[EditStub.self]
 CloudTransport.shared.session=URLSession(configuration:config);defer{CloudTransport.shared.session=saved}
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection();EditStub.owner=vault.value!.ownerID!;EditStub.patches=[]
 let library=CloudLibrary(queue:root.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(vault.value!.endpoint)!)
 var conflicts:[UUID]=[];library.onEditConflict={id,_ in conflicts.append(id)}
 let shots=root.appendingPathComponent("shots");try fm.createDirectory(at:shots,withIntermediateDirectories:true)
 let png=cloudFixturePNG(0.4);try png.write(to:shots.appendingPathComponent("s.png"));let shas=[sessionFingerprint(png)],id=UUID()
 typealias Fields=CloudLibrary.CloudEdit.Fields
 EditStub.remote=["id":id.uuidString,"title":"Původní","comment":"Text","captions":[""],"revision":"3"]
 let unchanged=try library.enqueueEdit(Draft(images:["s.png"],comment:"Text",title:"Původní"),root:shots,sessionID:id,base:shas,original:Fields(title:"Původní",comment:"Text",captions:[""]),revision:"3");assert(!unchanged)
 try library.enqueueEdit(Draft(images:["s.png"],comment:"Text",title:"Nový"),root:shots,sessionID:id,base:shas,original:Fields(title:"Původní",comment:"Text",captions:[""]),revision:"3")
 assert(library.pendingCount==1 && library.hasPending(id));await library.sync()
 assert(library.pendingCount==0 && EditStub.patches.count==1 && EditStub.patches[0]["revision"] as? String=="3" && EditStub.remote["title"] as? String=="Nový" && EditStub.remote["revision"] as? String=="4")
 // Změna jinde v jiném poli: sloučí se a pošle znovu s novou revizí.
 EditStub.remote["captions"]=["Cizí popisek"];EditStub.remote["revision"]="7"
 try library.enqueueEdit(Draft(images:["s.png"],comment:"Upravený text",title:"Nový"),root:shots,sessionID:id,base:shas,original:Fields(title:"Nový",comment:"Text",captions:[""]),revision:"4")
 await library.sync()
 assert(EditStub.patches.count==3 && EditStub.patches[2]["revision"] as? String=="7" && EditStub.remote["comment"] as? String=="Upravený text" && (EditStub.remote["captions"] as? [String])==["Cizí popisek"] && library.pendingCount==0 && conflicts.isEmpty)
 // Stejné pole změněné jinde: úprava se odloží, místní text zůstane v souboru.
 EditStub.remote["title"]="Jinde";EditStub.remote["revision"]="9"
 try library.enqueueEdit(Draft(images:["s.png"],comment:"Upravený text",title:"Můj"),root:shots,sessionID:id,base:shas,original:Fields(title:"Nový",comment:"Upravený text",captions:["Cizí popisek"]),revision:"8")
 await library.sync()
 let parked=((try? fm.contentsOfDirectory(atPath:root.appendingPathComponent("outbox/.conflicts").path)) ?? []).filter{$0.hasPrefix("edit-")}
 assert(conflicts==[id] && parked.count==1 && library.pendingCount==0 && EditStub.remote["title"] as? String=="Jinde" && library.lastError?.contains("Můj")==true)
 // Cizí týmová relace: 403 role_forbidden se odloží jednou, text zůstane místní a znovu se neposílá.
 EditStub.forbidden=true;defer{EditStub.forbidden=false};let foreign=UUID(),sentBefore=EditStub.patches.count
 let member=CloudLibrary(queue:root.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(vault.value!.endpoint)!);member.onEditConflict={id,_ in conflicts.append(id)}
 try member.enqueueEdit(Draft(images:["s.png"],comment:"Cizí text",title:"Cizí"),root:shots,sessionID:foreign,base:shas,original:Fields(title:"Původní",comment:"Text",captions:[""]),revision:"1")
 await member.sync()
 assert(EditStub.patches.count==sentBefore+1 && member.pendingCount==0 && !member.hasPending(foreign) && conflicts.last==foreign && member.lastError?.contains("Cizí")==true)
 // Změněný obrázek se úpravou textu poslat nedá.
 try cloudFixturePNG(0.9).write(to:shots.appendingPathComponent("s.png"))
 do{try library.enqueueEdit(Draft(images:["s.png"],comment:"x",title:"y"),root:shots,sessionID:id,base:shas,original:Fields(title:"a",comment:"b",captions:[""]),revision:nil);assertionFailure("Changed image accepted")}catch{}
 // Konflikt přepíše jen netknutý soubor relace místním textem; stahování pak zapíše _cloud.md.
 let dir=root.appendingPathComponent("cloud"),file=dir.appendingPathComponent("Relace.md");try fm.createDirectory(at:dir,withIntermediateDirectories:true)
 let body=renderSessionTemplate(defaultMarkdownTemplate,title:"Nový",screenshots:"![[assets/Relace-1.png]]",text:"Text");try body.write(to:file,atomically:true,encoding:.utf8)
 var record=SessionRecord(id:id.uuidString.lowercased(),file:SessionIndex.key(file),start:0,length:(body as NSString).length,hash:sessionFingerprint(Data(body.utf8)),heading:"# Nový",title:"Nový",comment:"Text",template:defaultMarkdownTemplate,images:["Relace-1.png"],notes:["Relace-1.png":""],combined:false,footer:"",files:["Relace.md":sessionFingerprint(Data(body.utf8))],seen:0,base:SessionIndex.key(dir),folder:UUID().uuidString.lowercased())
 record.revision="9";SessionIndex.shared.put(record)
 let folders=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{nil},localTopics:{[]})
 folders.keepLocalEdit(id,Fields(title:"Můj",comment:"Text",captions:["Můj popisek"]))
 let kept=try String(contentsOf:file,encoding:.utf8);assert(kept.hasPrefix("# Můj") && kept.contains("Můj popisek"))
 print("PASS: text-only cloud edit goes via PATCH with revision, session_changed rebases per field, same-field conflict parks and keeps local text, changed image rejected")
}

/// Rozpracovaná relace navázaná na smazanou nebo přesunutou uloženou relaci.
@MainActor func staleDraftTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-stale-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 let local=Topic(id:"l",name:"Lokální",detail:"",folder:root.appendingPathComponent("local").path,combined:false,combinedFile:"N.md")
 try Data([1]).write(to:capture.appendingPathComponent("a.png"));try finishSession(Draft(images:["a.png"],comment:"Text",title:"Uložená",topic:local),root:capture)
 let savedList=try previousSessions(for:local);let saved=savedList[0]
 let reopen=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopen,withIntermediateDirectories:true)
 var draft=try workingDraft(from:saved,topic:local,root:reopen);draft.comment="Rozepsáno"
 guard case .current(let same)=resolveDraftTarget(draft),same.previous==draft.previous else{throw CloudFailure.invalid}
 // Přesunutý soubor (migrace) se najde přes index a cíl se opraví včetně mapování obrázků.
 let old=URL(fileURLWithPath:saved.target.path),moved=old.deletingLastPathComponent().appendingPathComponent("Přesunuto.md")
 try fm.moveItem(at:old,to:moved)
 var record=SessionIndex.shared.records(file:old)[0];SessionIndex.shared.remove(record);record.file=SessionIndex.key(moved);SessionIndex.shared.put(record)
 guard case .current(let fixed)=resolveDraftTarget(draft) else{throw CloudFailure.invalid}
 assert(fixed.previous?.path.hasSuffix("Přesunuto.md")==true && fixed.previous?.imported.values.sorted()==draft.previous?.imported.values.sorted() && (try? checkedPreviousFile(fixed.previous!)) != nil)
 // Smazaný soubor bez náhrady: zaniklá relace.
 try fm.removeItem(at:moved)
 guard case .stale(let title)=resolveDraftTarget(draft),title=="Uložená" else{throw CloudFailure.invalid}
 // Cloudová relace v koši na webu se nikdy znovu neotevře a nedoplní.
 let c=cloudFixtureConnection(),folderID=UUID(),sessionID=UUID(),dir=root.appendingPathComponent("cloud")
 try fm.createDirectory(at:dir,withIntermediateDirectories:true)
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]});store.activate(c)
 try store.accept([CloudFolderRecord(id:folderID,name:"Cloud",owner:c.ownerID!,origin:c.endpoint)]);try store.setFolder(store.topics[0],path:dir.path)
 let file=dir.appendingPathComponent("Relace.md");try "x\n".write(to:file,atomically:true,encoding:.utf8)
 var cloudRecord=SessionRecord(id:sessionID.uuidString.lowercased(),file:SessionIndex.key(file),start:0,length:2,hash:sessionFingerprint(Data("x\n".utf8)),heading:"x",title:"test2",comment:"",template:defaultMarkdownTemplate,images:[],notes:[:],combined:false,footer:"",files:[:],seen:0,base:SessionIndex.key(try Topics.checkedDestination(dir.path)),folder:folderID.uuidString.lowercased())
 cloudRecord.shas=["a"];cloudRecord.trashed=true;SessionIndex.shared.put(cloudRecord)
 var cloudDraft=Draft(images:["a.png"],comment:"Upraveno",title:"test2",topic:store.topics[0])
 cloudDraft.previous=PreviousSessionTarget(path:file.path,start:0,length:2,original:"x\n",fingerprint:sessionFingerprint(Data("x\n".utf8)),imported:["a.png":"1.png"],session:sessionID.uuidString.lowercased())
 guard case .stale(let cloudTitle)=resolveDraftTarget(cloudDraft,folders:store),cloudTitle=="test2" else{throw CloudFailure.invalid}
 assert(store.serverImages(for:cloudDraft.previous!,topic:store.topics[0])==nil)
 // Uložit jako novou: snímky a text zůstanou, vazba zmizí. Zahodit: koncept se smaže.
 let draftRoot=root.appendingPathComponent("draft");try fm.createDirectory(at:draftRoot,withIntermediateDirectories:true);try Data([3]).write(to:draftRoot.appendingPathComponent("a.png"))
 try stage(cloudDraft,root:draftRoot)
 let kept=try applyStaleChoice(cloudDraft,keep:true,root:draftRoot)
 assert(kept.previous==nil && kept.images==["a.png"] && kept.comment=="Upraveno" && kept.topic==store.topics[0] && (try! readDraft(draftRoot)).previous==nil)
 let dropped=try applyStaleChoice(kept,keep:false,root:draftRoot)
 assert(dropped.images.isEmpty && dropped.previous==nil && !fm.fileExists(atPath:draftRoot.appendingPathComponent("draft.json").path) && !fm.fileExists(atPath:draftRoot.appendingPathComponent("a.png").path))
 print("PASS: stale draft: migrated path re-resolved via index, missing file and web-trashed session detected, never extended, keep-as-new and discard branches")
}
