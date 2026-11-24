import AppKit
@testable import ScreenshotNoteKit

/// Testovací server pro retenci: stavy relací, odpověď 404 s důvodem a výměna tokenu uprostřed synchronizace.
@MainActor final class RetentionFixture {
 let c=cloudFixtureConnection(),folderID=UUID(),png=cloudFixturePNG(0.3)
 let notes:[UUID],titles:[String],created:[String],combined:Bool
 var states:[UUID:String]=[:],current:CloudConnection?,retentionHits=0,swapAt:Int?,restoreReason:String?
 var retained:[String]=[]
 private(set) var store:CloudFolders!
 init(root:URL,titles:[String],combined:Bool) {
  self.titles=titles;self.combined=combined;notes=titles.map{_ in UUID()}
  created=titles.indices.map{"2026-03-0\($0+1)T10:00:00Z"}
  for id in notes{states[id]="active"};current=c
  store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{[unowned self] in self.current},localTopics:{[]},request:{[unowned self] _,path,_,_ in try self.answer(path)},send:{[unowned self] _,path,_,_,_ in
   let id=self.notes.first{path.contains($0.uuidString.lowercased())}!
   if path.hasSuffix("/restore"),let reason=self.restoreReason{throw CloudFailure("404",status:404,code:"not_found",reason:reason)}
   self.states[id]="active";return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString,"updated_at":"t1"]])
  })
  store.onRetained={[unowned self] in self.retained.append($0.displayName)}
 }
 func name(_ n:Int)->String{readableSessionName(titles[n],created:parseServerDate(created[n])!)}
 private func answer(_ path:String)throws->Data {
  if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.contains("/images/"){return png}
  let data:Any
  if path=="/api/v1/folders"{data=["data":[["id":folderID.uuidString,"name":"Cloud","revision":"1","description":"","combined":combined,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":"# {folderName}\n\n{sessions}\n"]]]}
  else if path.contains("?") {
   let wanted=path.contains("state=trashed") ? "trashed":"active",trashedAt:Any=wanted=="trashed" ? "2026-03-06T00:00:00Z" as Any:NSNull()
   data=["data":notes.filter{states[$0]==wanted}.map{id->[String:Any] in ["id":id.uuidString,"deleting":false,"updated_at":"t1","trashed_at":trashedAt]},"pagination":["has_more":false]]
  } else {
   let id=notes.first{path.contains($0.uuidString.lowercased())}!,n=notes.firstIndex(of:id)!
   if states[id]=="retention" {
    retentionHits+=1
    // Odpojení během dotazu: kontrola isCurrent po něm vyhodí chybu.
    if retentionHits==swapAt{current=CloudConnection(endpoint:c.endpoint,token:"sn_device_v1_"+String(repeating:"b",count:43),id:UUID(),comparisonCode:c.comparisonCode,verificationURI:c.verificationURI,expiresAt:c.expiresAt,ownerID:c.ownerID,email:nil)}
    throw CloudFailure("404",status:404,code:"not_found",reason:"retention")
   }
   if states[id]=="purged"{throw CloudFailure("404",status:404,code:"not_found")}
   data=["data":["id":id.uuidString,"title":titles[n],"comment":"Text","template":defaultMarkdownTemplate,"captions":["Popisek"],"updated_at":"t1","created_at":created[n],"trashed_at":states[id]=="trashed" ? "2026-03-06T00:00:00Z" as Any:NSNull(),"images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]
  }
  return try JSONSerialization.data(withJSONObject:data)
 }
}

/// Retenční smazání (#55): soubory jdou do .trash, nic se nemaže a úklid koše je přeskočí.
@MainActor func cloudRetentionTests() async throws {
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 let root=fm.temporaryDirectory.appendingPathComponent("sn-retention-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let f=RetentionFixture(root:root,titles:["Aktivní","Vkoši","Upravená","Ručně","Obnova"],combined:false),store=f.store!,c=f.c,notes=f.notes
 await store.refresh(c);let target=root.appendingPathComponent("cloud"),trash=target.appendingPathComponent(".trash"),assets=target.appendingPathComponent("assets")
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let base=try Topics.checkedDestination(target.path),names=notes.indices.map(f.name)
 func exists(_ path:String)->Bool{fm.fileExists(atPath:target.appendingPathComponent(path).path)}
 func retentionNotices()->Int{store.notices.filter{$0.contains("předplatného")}.count}
 assert(names.allSatisfy{exists($0+".md") && exists("assets/"+$0+"-1.png")})
 // B, D a E na webu v koši; C místně upravená a přesunutá do podsložky.
 for n in [1,3,4]{f.states[notes[n]]="trashed"}
 let sub=target.appendingPathComponent("Podsložka");try fm.createDirectory(at:sub,withIntermediateDirectories:true)
 let editedText=try String(contentsOf:target.appendingPathComponent(names[2]+".md"),encoding:.utf8)+"\nMístní úprava\n"
 try editedText.write(to:target.appendingPathComponent(names[2]+".md"),atomically:false,encoding:.utf8)
 try fm.moveItem(at:target.appendingPathComponent(names[2]+".md"),to:sub.appendingPathComponent(names[2]+".md"))
 await store.refresh(c)
 assert([1,3,4].allSatisfy{exists(".trash/"+names[$0]+".md")} && SessionIndex.shared.cloud(notes[2],base:base)?.file.hasSuffix("/Podsložka/"+names[2]+".md")==true)
 // Ručně smazaná relace (bez důvodu) se z .trash uklidí jako dřív.
 f.states[notes[3]]="purged";await store.refresh(c)
 assert(!exists(".trash/"+names[3]+".md") && !exists(".trash/assets/"+names[3]+"-1.png") && SessionIndex.shared.cloud(notes[3],base:base)==nil && f.retained.isEmpty && retentionNotices()==0)
 print("PASS: retention: plain 404 without reason still purges .trash as before, no retention notice")
 // A má video a kontext; v .trash už leží cizí soubory se stejnými názvy.
 let a=names[0]
 for suffix in [".context.json",".har",".mp4"]{try Data(suffix.utf8).write(to:assets.appendingPathComponent(a+"-1"+suffix))}
 try fm.createDirectory(at:assets.appendingPathComponent(a+"-1.frames"),withIntermediateDirectories:true)
 try Data("cizí".utf8).write(to:trash.appendingPathComponent(a+".md"));try Data("cizí".utf8).write(to:trash.appendingPathComponent("assets/"+a+"-1.png"))
 // Selhání přesunu: záznam zůstane, nic se neoznámí a další synchronizace to zkusí znovu.
 f.states[notes[0]]="retention"
 try fm.setAttributes([.posixPermissions:0o555],ofItemAtPath:trash.appendingPathComponent("assets").path)
 await store.refresh(c)
 try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:trash.appendingPathComponent("assets").path)
 assert(exists(a+".md") && exists("assets/"+a+"-1.png") && SessionIndex.shared.cloud(notes[0],base:base) != nil && f.retained.isEmpty && retentionNotices()==0)
 print("PASS: retention: failed move keeps the index record and files, no notice")
 // Retence: aktivní, upravená i v podsložce jdou do .trash, relace z koše zůstává, nic se nesmaže.
 f.states[notes[1]]="retention";f.states[notes[2]]="retention"
 await store.refresh(c);assert(store.lastError==nil)
 assert(!exists(a+".md") && exists(".trash/"+a+" 2.md") && (try? String(contentsOf:trash.appendingPathComponent(a+".md"),encoding:.utf8))=="cizí")
 assert(["png","context.json","har","mp4","frames"].allSatisfy{exists(".trash/assets/"+a+"-1 2."+$0) && !exists("assets/"+a+"-1."+$0)} && (try? String(contentsOf:trash.appendingPathComponent("assets/"+a+"-1.png"),encoding:.utf8))=="cizí")
 assert((try! String(contentsOf:trash.appendingPathComponent(a+" 2.md"),encoding:.utf8)).contains("](<assets/"+a+"-1 2.png>)"))
 assert(exists(".trash/"+names[1]+".md") && exists(".trash/assets/"+names[1]+"-1.png"))
 assert(!fm.fileExists(atPath:sub.appendingPathComponent(names[2]+".md").path) && (try? String(contentsOf:trash.appendingPathComponent(names[2]+".md"),encoding:.utf8))==editedText && exists(".trash/assets/"+names[2]+"-1.png"))
 assert([0,1,2].allSatisfy{SessionIndex.shared.cloud(notes[$0],base:base)==nil})
 assert(f.retained==["Cloud"] && retentionNotices()==1)
 AppLanguage.override="en";assert(L("Cloudová kopie byla smazána po konci předplatného, místní soubory jsou v koši složky %@ (.trash).").hasPrefix("The cloud copy was deleted"));AppLanguage.override="cs"
 print("PASS: retention: 404 reason retention moves active, edited and subfolder sessions with video and context to .trash, renames on name clash and rewrites links, keeps web-trashed files, notifies once")
 // Další synchronizace (i obyčejné 404) retenční soubory v .trash nikdy nesmaže.
 for n in [0,1,2]{f.states[notes[n]]="purged"}
 await store.refresh(c);await store.refresh(c)
 assert([a+" 2",names[1],names[2]].allSatisfy{exists(".trash/"+$0+".md")} && exists(".trash/assets/"+a+"-1 2.png") && f.retained.count==1)
 print("PASS: retention: later syncs and trash cleanup skip retained .trash files")
 // Obnova z .trash po retenci: soubory zůstanou, záznam zmizí a uživatel se to dozví.
 try fm.moveItem(at:trash.appendingPathComponent(names[4]+".md"),to:target.appendingPathComponent(names[4]+".md"))
 f.states[notes[4]]="retention";f.restoreReason="retention";await store.refresh(c)
 assert(exists(names[4]+".md") && SessionIndex.shared.cloud(notes[4],base:base)==nil && store.notices.contains{$0.contains("nelze obnovit") && $0.contains("předplatného")})
 print("PASS: retention: user restore from .trash after retention keeps files and explains why")
 // Transport předá error.reason z odpovědi.
 let restore=ReviewStub.install();defer{restore()}
 ReviewStub.handler={_,_,_ in (404,["error":["code":"not_found","message":"Session not found.","reason":"retention"]])}
 do{_ = try await CloudTransport.shared.request(CloudEndpoint("https://fixture.invalid")!,"/api/v1/sessions/x",token:c.token,limit:CloudTransport.jsonLimit);assertionFailure("404 accepted")}
 catch let failure as CloudFailure{assert(failure.status==404 && failure.code=="not_found" && failure.reason=="retention")}
 ReviewStub.handler={_,_,_ in (404,["error":["code":"not_found"]])}
 do{_ = try await CloudTransport.shared.request(CloudEndpoint("https://fixture.invalid")!,"/api/v1/sessions/x",token:c.token,limit:CloudTransport.jsonLimit);assertionFailure("404 accepted")}
 catch let failure as CloudFailure{assert(failure.status==404 && failure.reason==nil)}
 print("PASS: retention: transport parses error.reason, absent reason stays nil")
 try await combinedRetentionTests(root.appendingPathComponent("combined"))
}

/// Společný soubor: bloky jdou do .trash jako poznámky s obrázky; chyba uprostřed smyčky oznámení nezastaví.
@MainActor func combinedRetentionTests(_ root:URL) async throws {
 try fm.createDirectory(at:root,withIntermediateDirectories:true)
 let f=RetentionFixture(root:root,titles:["První","Druhá"],combined:true),store=f.store!,c=f.c,notes=f.notes
 await store.refresh(c);let target=root.appendingPathComponent("cloud")
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let base=try Topics.checkedDestination(target.path),names=notes.indices.map(f.name)
 func exists(_ path:String)->Bool{fm.fileExists(atPath:target.appendingPathComponent(path).path)}
 assert(exists("All.md") && names.allSatisfy{exists("assets/"+$0+"-1.png")})
 // Druhá kontrola odpojí účet: první relace je přesunutá a oznámení přijde i tak.
 for id in notes{f.states[id]="retention"};f.swapAt=2
 await store.refresh(c);assert(store.lastError != nil)
 assert(notes.filter{SessionIndex.shared.cloud($0,base:base)==nil}.count==1 && f.retained==["Cloud"] && store.notices.filter{$0.contains("předplatného")}.count==1)
 print("PASS: retention: error in the middle of the check loop still notifies about sessions already moved")
 f.current=c;f.swapAt=nil;await store.refresh(c);assert(store.lastError==nil)
 assert(notes.allSatisfy{SessionIndex.shared.cloud($0,base:base)==nil} && store.notices.filter{$0.contains("předplatného")}.count==1)
 for name in names {
  assert(exists(".trash/"+name+".md") && exists(".trash/assets/"+name+"-1.png") && !exists("assets/"+name+"-1.png"))
  assert((try! String(contentsOf:target.appendingPathComponent(".trash/"+name+".md"),encoding:.utf8)).contains("](<assets/"+name+"-1.png>)"))
 }
 print("PASS: retention: combined folder blocks saved to .trash as notes with their images")
}
