import AppKit
@testable import ScreenshotNoteKit

/// Testovací server s podsložkami: strom, umístění relací s revizí, přesun a založení podsložky.
@MainActor final class SubfolderFixture {
 struct Session{var title:String;var subfolder:UUID?;var location:Int;var state="active";var updated="t1"}
 let c=cloudFixtureConnection(),folderID=UUID(),root:URL,png=cloudFixturePNG(0.5)
 var tree:[(id:UUID,parent:UUID?,name:String,revision:Int)]=[],treeRevision=1,combined:Bool
 var sessions:[UUID:Session]=[:],order:[UUID]=[]
 var moves:[(UUID,[String:Any])]=[],creates:[[String:Any]]=[]
 var clock=Date(timeIntervalSince1970:1_800_000_000),role:String?=nil
 var store:CloudFolders!
 init(_ root:URL,combined:Bool=false)throws {
  self.root=root;self.combined=combined
  store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{[unowned self] in self.c},localTopics:{[]},request:{[unowned self] _,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(self.c.ownerID!)}
   if path.contains("/images/"){return self.png}
   let data:Any
   if path=="/api/v1/folders"{data=["data":[["id":self.folderID.uuidString,"name":"Projekt","revision":"1","combined":self.combined,"combined_file":"All.md","subfolders_revision":String(self.treeRevision),
    "subfolders":self.tree.map{["id":$0.id.uuidString,"folder_id":self.folderID.uuidString,"parent_id":$0.parent.map{$0.uuidString as Any} ?? NSNull(),"name":$0.name,"revision":String($0.revision)]}]]]}
   else if path.contains("?") {
    let wanted=path.contains("state=trashed") ? "trashed":"active"
    data=["data":self.order.filter{self.sessions[$0]?.state==wanted}.map{id in let s=self.sessions[id]!;return ["id":id.uuidString,"updated_at":s.updated,"trashed_at":wanted=="trashed" ? "2026-01-01T00:00:00Z":NSNull(),"subfolder_id":s.subfolder.map{$0.uuidString as Any} ?? NSNull(),"location_revision":String(s.location)] as [String:Any]},"pagination":["has_more":false]]
   } else {
    guard let id=self.order.first(where:{path.contains($0.uuidString.lowercased())}),let s=self.sessions[id],s.state != "deleted" else{throw CloudFailure("missing",status:404,code:"not_found")}
    data=["data":["id":id.uuidString,"title":s.title,"comment":"Text","template":defaultMarkdownTemplate,"captions":[""],"updated_at":s.updated,"created_at":"2026-01-02T10:00:00Z","subfolder_id":s.subfolder.map{$0.uuidString as Any} ?? NSNull(),"location_revision":String(s.location),
     "images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]
   }
   return try JSONSerialization.data(withJSONObject:data)
  },send:{[unowned self] _,path,_,_,body in
   let sent=json(body)
   if path.hasSuffix("/subfolders") {
    self.creates.append(sent)
    if self.role=="member"{throw CloudFailure("forbidden",status:403,code:"role_forbidden")}
    let id=UUID(uuidString:sent["id"] as! String)!,parent=(sent["parent_id"] as? String).flatMap(UUID.init(uuidString:)),name=sent["name"] as! String
    if self.tree.contains(where:{$0.parent==parent && subfolderNameKey($0.name)==subfolderNameKey(name) && $0.id != id}){throw CloudFailure("taken",status:409,code:"subfolder_name_taken")}
    if !self.tree.contains(where:{$0.id==id}){self.tree.append((id,parent,name,1));self.treeRevision+=1}
    return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString,"folder_id":self.folderID.uuidString,"parent_id":parent.map{$0.uuidString as Any} ?? NSNull(),"name":name,"revision":"1","subfolders_revision":String(self.treeRevision)]])
   }
   let id=self.order.first{path.contains($0.uuidString.lowercased())}!
   if path.hasSuffix("/move") {
    self.moves.append((id,sent));var s=self.sessions[id]!
    let target=(sent["subfolder_id"] as? String).flatMap(UUID.init(uuidString:))
    if sent["location_revision"] as? String != String(s.location) {
     let current:[String:Any]=["id":id.uuidString,"folder_id":self.folderID.uuidString,"subfolder_id":s.subfolder.map{$0.uuidString as Any} ?? NSNull(),"location_revision":String(s.location)]
     throw CloudFailure("conflict",status:409,code:"location_conflict",details:try JSONSerialization.data(withJSONObject:["code":"location_conflict","current":current]))
    }
    if let target,!self.tree.contains(where:{$0.id==target}){throw CloudFailure("missing",status:409,code:"subfolder_not_found")}
    if s.subfolder != target{s.subfolder=target;s.location+=1;self.sessions[id]=s}
    return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString,"folder_id":self.folderID.uuidString,"subfolder_id":s.subfolder.map{$0.uuidString as Any} ?? NSNull(),"location_revision":String(s.location),"revision":"1"]])
   }
   if path.hasSuffix("/trash"){self.sessions[id]?.state="trashed"}else{self.sessions[id]?.state="active"}
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString]])
  },now:{[unowned self] in self.clock},pending:{_ in false},recycle:{try fm.removeItem(at:$0)})
 }
 var target:URL{root.appendingPathComponent("cloud")}
 var base:URL{try! Topics.checkedDestination(target.path)}
 @discardableResult func addFolder(_ name:String,parent:UUID?=nil)->UUID{let id=UUID();tree.append((id,parent,name,1));treeRevision+=1;return id}
 @discardableResult func addSession(_ title:String,in subfolder:UUID?=nil)->UUID{let id=UUID();order.append(id);sessions[id]=Session(title:title,subfolder:subfolder,location:1);return id}
 /// Přesun na webu: jiná podsložka, posunutá revize umístění (obsah ani updated_at se nemění).
 func webMove(_ id:UUID,to subfolder:UUID?){sessions[id]!.subfolder=subfolder;sessions[id]!.location+=1}
 func start()async throws{await store.refresh(c);try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil,store.lastError ?? "")}
 func scan(after seconds:Double=20)async{clock=clock.addingTimeInterval(seconds);await store.refresh(c)}
 func record(_ id:UUID)->SessionRecord{SessionIndex.shared.cloud(id,base:base)!}
 func file(_ id:UUID)->URL{URL(fileURLWithPath:record(id).file)}
 func dir(_ relative:String)->URL{target.appendingPathComponent(relative,isDirectory:true)}
 func markdowns(_ relative:String="")->[String]{((try? fm.contentsOfDirectory(atPath:relative.isEmpty ? target.path:dir(relative).path)) ?? []).filter{$0.hasSuffix(".md")}.sorted()}
}

/// Podsložky na Macu (#76): strom podle identity, přesuny z webu i z Finderu, konflikty, místní složky.
@MainActor func subfolderTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-subfolders-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 func read(_ url:URL)->String{(try? String(contentsOf:url,encoding:.utf8)) ?? ""}
 // Pravidla názvu stejná jako server.
 for good in ["Sprint 1","Bugy","Ž","a.b"]{assert(validSubfolderName(good),good)}
 for bad in [""," Sprint","Sprint ",".skryté","assets","ASSETS","a/b","a\\b","a:b","a*b","a?b","a\"b","a<b","a>b","a|b","a\u{7}b","Rodic\u{30C}",String(repeating:"x",count:101),String(repeating:"ž",count:128)]{assert(!validSubfolderName(bad),bad)}
 assert(cleanSubfolderName(" Rodic\u{30C} ")=="Rodič" && subfolderNameKey("SPRINT")==subfolderNameKey("sprint"))
 let a1=UUID(),a2=UUID(),deep=UUID()
 let tree=validSubfolderTree([CloudSubfolder(id:a1,parent:nil,name:"A",revision:"1"),CloudSubfolder(id:a2,parent:a1,name:"B",revision:"1"),CloudSubfolder(id:deep,parent:a2,name:"C",revision:"1"),CloudSubfolder(id:UUID(),parent:nil,name:"a",revision:"1"),CloudSubfolder(id:UUID(),parent:nil,name:"assets",revision:"1")])
 assert(tree.map(\.name)==["A","B"] && orderedSubfolders(tree).map{$0.1}==[0,1])
 print("PASS: subfolder names follow the server rules (NFC, forbidden characters, dot, assets, length); tree keeps two levels and unique names")

 // Strom ze serveru: adresáře podle ID, nová relace rovnou do podsložky s vlastním assets/.
 let f=try SubfolderFixture(root.appendingPathComponent("tree"))
 let sprint=f.addFolder("Sprint"),bugs=f.addFolder("Bugy",parent:sprint),archive=f.addFolder("Archiv")
 let s1=f.addSession("V podsložce",in:bugs),s2=f.addSession("V kořeni"),s3=f.addSession("Ke kopírování",in:sprint)
 try await f.start()
 assert(fm.fileExists(atPath:f.dir("Sprint/Bugy").path) && fm.fileExists(atPath:f.dir("Archiv").path))
 assert(f.markdowns("Sprint/Bugy").count==1 && f.markdowns().count==1 && f.markdowns("Sprint").count==1)
 assert(f.file(s1).deletingLastPathComponent().lastPathComponent=="Bugy" && f.record(s1).subfolder==bugs.uuidString.lowercased() && f.record(s1).location=="1")
 assert(fm.fileExists(atPath:f.dir("Sprint/Bugy/assets").appendingPathComponent(f.record(s1).images[0]).path))
 assert((try? previousSessions(in:f.dir("Sprint/Bugy")))?.count==1)
 let topic=f.store.topics[0]
 assert(subfolderChoices(topic).map(\.name)==["Archiv","Sprint","Bugy"] && subfolderPath(bugs.uuidString.lowercased(),in:topic)=="Sprint › Bugy")
 let listed=try previousSessions(for:topic)
 assert(listed.count==3 && listed.contains{$0.place=="Projekt › Sprint › Bugy" && $0.display.contains("Projekt › Sprint › Bugy")} && listed.contains{$0.place==nil})
 print("PASS: server tree becomes directories, new sessions download straight into their subfolder with its own assets/, session picker shows Folder › Subfolder")

 // Přejmenování na webu: adresář se přejmenuje podle identity, relace v něm zůstanou bez nového stažení.
 let inode=itemIdentity(f.dir("Sprint"))
 f.tree=f.tree.map{$0.id==sprint ? ($0.id,$0.parent,"Sprint 2",$0.revision+1):$0};f.treeRevision+=1
 try "# Moje\n".write(to:f.dir("Sprint").appendingPathComponent("moje.txt"),atomically:true,encoding:.utf8)
 await f.scan()
 assert(!fm.fileExists(atPath:f.dir("Sprint").path) && itemIdentity(f.dir("Sprint 2"))==inode && fm.fileExists(atPath:f.dir("Sprint 2/moje.txt").path))
 assert(f.file(s1).path.hasSuffix("/Sprint 2/Bugy/"+f.file(s1).lastPathComponent) && fm.fileExists(atPath:f.file(s1).path) && f.markdowns("Sprint 2/Bugy").count==1 && f.markdowns("Sprint 2").count==1)
 // Cizí adresář se stejným názvem se neslučuje: podsložka dostane příponu.
 try fm.createDirectory(at:f.dir("Nová"),withIntermediateDirectories:true);try "cizí\n".write(to:f.dir("Nová").appendingPathComponent("cizi.md"),atomically:true,encoding:.utf8)
 let fresh=f.addFolder("Nová");await f.scan()
 assert(fm.fileExists(atPath:f.dir("Nová 2").path) && f.store.subfolderDirectory(f.store.topics[0],fresh)?.lastPathComponent=="Nová 2" && f.markdowns("Nová")==["cizi.md"])
 // Přejmenování ve Finderu server přebije, adresář se vrátí na název z cloudu.
 try fm.moveItem(at:f.dir("Archiv"),to:f.dir("Archiv přejmenovaný"));await f.scan()
 assert(fm.fileExists(atPath:f.dir("Archiv").path) && !fm.fileExists(atPath:f.dir("Archiv přejmenovaný").path))
 print("PASS: web rename renames the local directory by identity (sessions keep their files), a foreign directory with the same name gets a suffix, Finder rename is reverted")

 // Přesun na webu: soubory relace jdou za serverem; souběžná místní úprava zůstává.
 let edited=f.file(s2);try (try String(contentsOf:edited,encoding:.utf8)+"\nMoje místní úprava\n").write(to:edited,atomically:true,encoding:.utf8)
 f.webMove(s2,to:archive);await f.scan()
 let movedFile=f.file(s2)
 assert(movedFile.deletingLastPathComponent().lastPathComponent=="Archiv" && !fm.fileExists(atPath:edited.path) && read(movedFile).contains("Moje místní úprava"))
 assert(fm.fileExists(atPath:f.dir("Archiv/assets").appendingPathComponent(f.record(s2).images[0]).path) && f.record(s2).location=="2" && f.moves.isEmpty)
 assert(!fm.fileExists(atPath:f.target.appendingPathComponent(movedFile.deletingPathExtension().lastPathComponent+"_cloud.md").path) && f.markdowns().isEmpty)
 // Úprava textu jde dál podle ID relace, ne podle cesty.
 assert(f.store.editBase(s2,topic:f.store.topics[0]) != nil)
 print("PASS: web move moves the session files to the new subfolder (server wins on location), a concurrent local edit is kept, edits follow the session id")

 // Přesun ve Finderu do známé podsložky: move_session s poslední revizí, obrázky jdou za Markdownem.
 let local=f.file(s1),target=f.dir("Archiv").appendingPathComponent(local.lastPathComponent)
 try fm.moveItem(at:local,to:target);await f.scan()
 assert(f.moves.count==1 && f.moves[0].0==s1 && f.moves[0].1["subfolder_id"] as? String==archive.uuidString.lowercased() && f.moves[0].1["location_revision"] as? String=="1")
 assert(f.sessions[s1]!.subfolder==archive && f.record(s1).subfolder==archive.uuidString.lowercased() && f.record(s1).location=="2" && f.file(s1).lastPathComponent==target.lastPathComponent && f.file(s1).deletingLastPathComponent().lastPathComponent=="Archiv")
 assert(fm.fileExists(atPath:f.dir("Archiv/assets").appendingPathComponent(f.record(s1).images[0]).path) && !fm.fileExists(atPath:f.dir("Sprint 2/Bugy/assets").appendingPathComponent(f.record(s1).images[0]).path))
 await f.scan();assert(f.moves.count==1 && f.file(s1).deletingLastPathComponent().lastPathComponent=="Archiv")
 // Do kořene: subfolder_id null.
 try fm.moveItem(at:f.file(s1),to:f.target.appendingPathComponent(f.file(s1).lastPathComponent));await f.scan()
 assert(f.moves.count==2 && f.moves[1].1["subfolder_id"] is NSNull && f.sessions[s1]!.subfolder==nil && f.file(s1).deletingLastPathComponent().lastPathComponent=="cloud" && fm.fileExists(atPath:f.target.appendingPathComponent("assets/"+f.record(s1).images[0]).path))
 print("PASS: Finder move into a known subfolder (or the root) calls move_session with the last location revision and takes the images along")

 // Zastaralá revize: web mezitím přesunul jinam, soubory jdou tam, kde je má cloud.
 f.webMove(s1,to:fresh)
 try fm.moveItem(at:f.file(s1),to:f.dir("Archiv").appendingPathComponent(f.file(s1).lastPathComponent));await f.scan()
 assert(f.moves.count==3 && f.sessions[s1]!.subfolder==fresh && f.file(s1).deletingLastPathComponent().lastPathComponent=="Nová 2" && f.record(s1).subfolder==fresh.uuidString.lowercased())
 assert(fm.fileExists(atPath:f.dir("Nová 2/assets").appendingPathComponent(f.record(s1).images[0]).path) && f.store.notices.contains{$0.contains("mezitím přesunul někdo jiný")})
 print("PASS: stale Finder move (location_conflict) moves the files to where the server has the session and says so")

 // Adresář vytvořený ve Finderu se nesynchronizuje: relace se vrátí, žádná podsložka ani přesun na serveru.
 let creates=f.creates.count,movesBefore=f.moves.count,treeBefore=f.tree.count
 try fm.createDirectory(at:f.dir("Z Finderu"),withIntermediateDirectories:true)
 let s3file=f.file(s3);try fm.moveItem(at:s3file,to:f.dir("Z Finderu").appendingPathComponent(s3file.lastPathComponent));await f.scan()
 assert(f.creates.count==creates && f.moves.count==movesBefore && f.tree.count==treeBefore && f.markdowns("Z Finderu").isEmpty && f.file(s3).deletingLastPathComponent().lastPathComponent=="Sprint 2" && fm.fileExists(atPath:f.file(s3).path))
 assert(f.store.notices.contains("Adresář Z Finderu není podsložka v cloudu. Vytvoř ji v aplikaci nebo na webu.") && fm.fileExists(atPath:f.dir("Z Finderu").path))
 print("PASS: a directory created in Finder is not synced: no server call, the moved session goes back and the app explains why")

 // Nová podsložka z aplikace: nejdřív server, pak adresář s mapováním; opakování se stejným ID neduplikuje.
 let made=try await f.store.createSubfolder(f.store.topics[0],name:" Rodic\u{30C} ",parent:archive)
 assert(f.creates.last?["name"] as? String=="Rodič" && f.creates.last?["parent_id"] as? String==archive.uuidString.lowercased() && fm.fileExists(atPath:f.dir("Archiv/Rodič").path))
 assert(f.store.topics[0].subfolders?.contains{$0.id==made.id}==true && f.store.subfolderDirectory(f.store.topics[0],made.id)?.lastPathComponent=="Rodič")
 do{_ = try await f.store.createSubfolder(f.store.topics[0],name:"rodič",parent:archive);assertionFailure("Duplicate name must fail")}catch{assert(error.localizedDescription=="Podsložka s tímto názvem už existuje.")}
 do{_ = try await f.store.createSubfolder(f.store.topics[0],name:"assets",parent:nil);assertionFailure("Invalid name must fail")}catch{assert((error as? CloudFailure)?.code=="invalid_subfolder_name")}
 _ = try await f.store.createSubfolder(f.store.topics[0],name:"Rodič",parent:archive,id:made.id);assert(f.tree.filter{$0.id==made.id}.count==1)
 print("PASS: New subfolder… creates it on the server first (own id, NFC name), then the directory; duplicates and invalid names are refused")

 // Podsložka smazaná na webu i s relacemi: relace do .trash, prázdný adresář zmizí.
 let doomed=f.addFolder("Pryč"),gone=f.addSession("Do koše",in:doomed);await f.scan()
 assert(f.markdowns("Pryč").count==1)
 f.sessions[gone]!.state="trashed";f.tree.removeAll{$0.id==doomed};f.treeRevision+=1;await f.scan()
 assert(!fm.fileExists(atPath:f.dir("Pryč").path) && f.record(gone).trashed==true && f.record(gone).file.contains("/.trash/"))
 // Místně upravená relace zůstává, adresář s ní také a aplikace to oznámí.
 f.sessions[s2]!.state="trashed";f.tree.removeAll{$0.id==archive || $0.parent==archive};f.treeRevision+=1;await f.scan()
 assert(fm.fileExists(atPath:f.file(s2).path) && f.record(s2).trashed != true && f.store.notices.contains("Podsložka Archiv už v cloudu není. Místní soubory v ní zůstaly.") && !fm.fileExists(atPath:f.dir("Archiv/Rodič").path))
 print("PASS: subfolder trashed on the web with its sessions: sessions go to .trash and the empty directory is removed; an edited session and its directory stay with a notice")

 // Upload nové relace do podsložky nese subfolder_id; doplnění ani neznámá podsložka ne.
 var manifest=CloudManifest(title:"t",comment:"",configuration:"c",template:"t",captions:[""],images:[.init(index:1,bytes:1,sha256:String(repeating:"a",count:64))],folder_id:UUID())
 manifest.subfolder_id=UUID();assert(manifest.valid);manifest.base_images=0;assert(!manifest.valid)
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection();let pairing=vault.value!,queue=root.appendingPathComponent("queue")
 let library=CloudLibrary(queue:queue,vault:vault,endpoint:CloudEndpoint("https://fixture.invalid")!),shots=root.appendingPathComponent("shots")
 try fm.createDirectory(at:shots,withIntermediateDirectories:true);try cloudFixturePNG(0.3).write(to:shots.appendingPathComponent("a.png"))
 var cloudTopic=Topic(id:"cloud-sub",name:"Cloud",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:UUID(),cloudOwnerID:pairing.ownerID,cloudOrigin:pairing.endpoint)
 let known=UUID();cloudTopic.subfolders=[CloudSubfolder(id:known,parent:nil,name:"Sprint",revision:"1")]
 func queued(_ subfolder:String?)throws->[String:Any]{var d=Draft(images:["a.png"],comment:"",title:"Do podsložky",topic:cloudTopic);d.subfolder=subfolder;let id=try library.enqueue(d,root:shots,folders:[cloudTopic]);return (json(try Data(contentsOf:queue.appendingPathComponent(id.uuidString.lowercased()+"/job.json")))["manifest"] as? [String:Any]) ?? [:]}
 let chosen=try queued(known.uuidString.lowercased()),unknown=try queued(UUID().uuidString),none=try queued(nil)
 assert((chosen["subfolder_id"] as? String)?.lowercased()==known.uuidString.lowercased() && unknown["subfolder_id"]==nil && none["subfolder_id"]==nil)
 print("PASS: upload manifest carries subfolder_id only for a new session in a cloud folder")

 // Společný soubor: jeden na podsložku, přesun na webu přesune blok i obrázky.
 let g=try SubfolderFixture(root.appendingPathComponent("combined"),combined:true)
 let team=g.addFolder("Tým"),c1=g.addSession("Kořenová"),c2=g.addSession("Týmová",in:team)
 try await g.start();await g.scan()
 let rootFile=g.target.appendingPathComponent("All.md"),teamFile=g.dir("Tým").appendingPathComponent("All.md")
 assert(read(rootFile).contains("Kořenová") && !read(rootFile).contains("Týmová"))
 assert(read(teamFile).contains("Týmová") && fm.fileExists(atPath:g.dir("Tým/assets").appendingPathComponent(g.record(c2).images[0]).path))
 g.webMove(c1,to:team);await g.scan()
 let teamText=try String(contentsOf:teamFile,encoding:.utf8)
 assert(teamText.contains("Kořenová") && teamText.contains("Týmová") && !read(rootFile).contains("Kořenová"))
 assert(fm.fileExists(atPath:g.dir("Tým/assets").appendingPathComponent(g.record(c1).images[0]).path) && g.record(c1).file==SessionIndex.key(teamFile))
 print("PASS: combined-file folder writes one combined file per subfolder; a web move moves the block and its images")

 // Místní složka: podsložky jsou adresáře do hloubky 2, nová relace jde do zvolené, výběr relací je najde.
 let localRoot=root.appendingPathComponent("local");try fm.createDirectory(at:localRoot.appendingPathComponent("Projekt/Detail/Příliš hluboko"),withIntermediateDirectories:true)
 try fm.createDirectory(at:localRoot.appendingPathComponent("assets"),withIntermediateDirectories:true)
 let localTopic=Topic(id:"local-sub",name:"Místní",detail:"",folder:localRoot.path,combined:false,combinedFile:"Notes.md")
 assert(subfolderChoices(localTopic).map(\.key)==["Projekt","Projekt/Detail"])
 let work=root.appendingPathComponent("draft");try fm.createDirectory(at:work,withIntermediateDirectories:true);try cloudFixturePNG().write(to:work.appendingPathComponent("shot.png"))
 var draft=Draft(images:["shot.png"],comment:"Komentář",title:"Lokální v podsložce",topic:localTopic);draft.subfolder="Projekt/Detail"
 try finishSession(draft,root:work,folders:[localTopic])
 assert(((try? fm.contentsOfDirectory(atPath:localRoot.appendingPathComponent("Projekt/Detail").path)) ?? []).contains{$0.hasSuffix("Lokální v podsložce.md")} && fm.fileExists(atPath:localRoot.appendingPathComponent("Projekt/Detail/assets").path))
 let found=try previousSessions(for:localTopic)
 assert(found.count==1 && found[0].place=="Místní › Projekt › Detail")
 draft.subfolder="../venku";do{_ = try localSubfolderDirectory(localTopic,draft.subfolder);assertionFailure("Path escape must fail")}catch{}
 print("PASS: local-only folder: subfolders are plain directories up to depth 2, a new session saves into the chosen one and the picker finds it")
}
