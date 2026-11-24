import AppKit
@testable import ScreenshotNoteKit

/// Retenční smazání (#55): soubory jdou do .trash, nic se nemaže a úklid koše je přeskočí.
@MainActor func cloudRetentionTests() async throws {
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 let root=fm.temporaryDirectory.appendingPathComponent("sn-retention-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let c=cloudFixtureConnection(),folderID=UUID()
 let notes=[UUID(),UUID(),UUID(),UUID()],titles=["Aktivní","Vkoši","Upravená","Ručně"]
 let created=["2026-03-01T10:00:00Z","2026-03-02T10:00:00Z","2026-03-03T10:00:00Z","2026-03-04T10:00:00Z"]
 var states:[UUID:String]=Dictionary(uniqueKeysWithValues:notes.map{($0,"active")})
 let png=cloudFixturePNG(0.3)
 func i(_ id:UUID)->Int{notes.firstIndex(of:id)!}
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
  if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.contains("/images/"){return png}
  let data:Any
  if path=="/api/v1/folders"{data=["data":[["id":folderID.uuidString,"name":"Cloud","revision":"1","description":"","combined":false,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":NSNull()]]]}
  else if path.contains("?") {
   let wanted=path.contains("state=trashed") ? "trashed":"active"
   let trashedAt:Any=wanted=="trashed" ? "2026-03-06T00:00:00Z" as Any:NSNull()
   data=["data":notes.filter{states[$0]==wanted}.map{id->[String:Any] in ["id":id.uuidString,"deleting":false,"updated_at":"t1","trashed_at":trashedAt]},"pagination":["has_more":false]]
  } else {
   let id=notes.first{path.contains($0.uuidString.lowercased())}!
   if states[id]=="retention"{throw CloudFailure("404",status:404,code:"not_found",reason:"retention")}
   if states[id]=="purged"{throw CloudFailure("404",status:404,code:"not_found")}
   data=["data":["id":id.uuidString,"title":titles[i(id)],"comment":"Text","template":defaultMarkdownTemplate,"captions":["Popisek"],"updated_at":"t1","created_at":created[i(id)],"trashed_at":states[id]=="trashed" ? "2026-03-06T00:00:00Z" as Any:NSNull(),"images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]
  }
  return try JSONSerialization.data(withJSONObject:data)
 },send:{_,_,_,_,_ in throw CloudFailure("unexpected",status:500)})
 var retainedTopics:[String]=[];store.onRetained={retainedTopics.append($0.displayName)}
 await store.refresh(c);let target=root.appendingPathComponent("cloud"),trash=target.appendingPathComponent(".trash")
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let base=try Topics.checkedDestination(target.path)
 let names=notes.map{id->String in readableSessionName(titles[i(id)],created:parseServerDate(created[i(id)])!)}
 func exists(_ path:String)->Bool{fm.fileExists(atPath:target.appendingPathComponent(path).path)}
 assert(names.allSatisfy{exists($0+".md") && exists("assets/"+$0+"-1.png")})
 // B a D na webu v koši; C místně upravená.
 states[notes[1]]="trashed";states[notes[3]]="trashed";await store.refresh(c)
 assert(exists(".trash/"+names[1]+".md") && exists(".trash/assets/"+names[1]+"-1.png") && exists(".trash/"+names[3]+".md"))
 let edited=target.appendingPathComponent(names[2]+".md"),editedText=try String(contentsOf:edited,encoding:.utf8)+"\nMístní úprava\n"
 try editedText.write(to:edited,atomically:true,encoding:.utf8)
 // Ručně smazaná relace (bez důvodu) se z .trash uklidí jako dřív.
 states[notes[3]]="purged";await store.refresh(c)
 assert(!exists(".trash/"+names[3]+".md") && !exists(".trash/assets/"+names[3]+"-1.png") && SessionIndex.shared.cloud(notes[3],base:base)==nil && retainedTopics.isEmpty)
 assert(!store.notices.contains{$0.contains("předplatného")})
 print("PASS: retention: plain 404 without reason still purges .trash as before, no retention notice")
 // Retence: aktivní i upravená jdou do .trash, relace z koše zůstává, nic se nesmaže.
 for id in notes.prefix(3){states[id]="retention"}
 await store.refresh(c);assert(store.lastError==nil)
 assert(!exists(names[0]+".md") && exists(".trash/"+names[0]+".md") && exists(".trash/assets/"+names[0]+"-1.png") && !exists("assets/"+names[0]+"-1.png"))
 assert(exists(".trash/"+names[1]+".md") && exists(".trash/assets/"+names[1]+"-1.png"))
 assert(!exists(names[2]+".md") && (try? String(contentsOf:trash.appendingPathComponent(names[2]+".md"),encoding:.utf8))==editedText && exists(".trash/assets/"+names[2]+"-1.png"))
 assert(notes.prefix(3).allSatisfy{SessionIndex.shared.cloud($0,base:base)==nil})
 assert(retainedTopics==["Cloud"] && store.notices.filter{$0.contains("předplatného")}.count==1)
 AppLanguage.override="en";assert(L("Cloudová kopie byla smazána po konci předplatného, místní soubory jsou v koši složky %@ (.trash).").hasPrefix("The cloud copy was deleted"));AppLanguage.override="cs"
 print("PASS: retention: 404 reason retention moves active and edited sessions to .trash, keeps web-trashed files, drops index records, notifies once")
 // Další synchronizace (i obyčejné 404) retenční soubory v .trash nikdy nesmaže.
 for id in notes.prefix(3){states[id]="purged"}
 await store.refresh(c);await store.refresh(c)
 assert(names.prefix(3).allSatisfy{exists(".trash/"+$0+".md") && exists(".trash/assets/"+$0+"-1.png")} && retainedTopics.count==1)
 print("PASS: retention: later syncs and trash cleanup skip retained .trash files")
 // Transport předá error.reason z odpovědi.
 let restore=ReviewStub.install();defer{restore()}
 ReviewStub.handler={_,_,_ in (404,["error":["code":"not_found","message":"Session not found.","reason":"retention"]])}
 do{_ = try await CloudTransport.shared.request(CloudEndpoint("https://fixture.invalid")!,"/api/v1/sessions/x",token:c.token,limit:CloudTransport.jsonLimit);assertionFailure("404 accepted")}
 catch let failure as CloudFailure{assert(failure.status==404 && failure.code=="not_found" && failure.reason=="retention")}
 ReviewStub.handler={_,_,_ in (404,["error":["code":"not_found"]])}
 do{_ = try await CloudTransport.shared.request(CloudEndpoint("https://fixture.invalid")!,"/api/v1/sessions/x",token:c.token,limit:CloudTransport.jsonLimit);assertionFailure("404 accepted")}
 catch let failure as CloudFailure{assert(failure.status==404 && failure.reason==nil)}
 print("PASS: retention: transport parses error.reason, absent reason stays nil")
}
