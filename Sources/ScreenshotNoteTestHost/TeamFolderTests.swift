import AppKit
@testable import ScreenshotNoteKit

/// Týmové složky: předpona, dva účty s různými cestami, ztráta a návrat týmu, role a {author}.
@MainActor func teamFolderTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-team-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 let cA=cloudFixtureConnection(),cB=cloudFixtureConnection(),userA=cA.ownerID!,userB=cB.ownerID!,team=UUID(),folderID=UUID(),png=cloudFixturePNG(0.3)
 let personal=[userA:UUID(),userB:UUID()],notes=[UUID(),UUID(),UUID()],authors=[userA,userB,userB],names=[userA:"Alice",userB:"Bob"]
 var conn:CloudConnection?=cA,member=[userA:true,userB:true],roles=[userA:"member",userB:"admin"],trashed=Set<UUID>(),leaveAfterMe=Set<UUID>(),leaveAfterFolders=Set<UUID>()
 var posts:[String]=[],lists:[String]=[],details=0,meCalls=0,clock=Date(timeIntervalSince1970:1_900_000_000)
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{conn},localTopics:{[]},request:{_,path,_,_ in
  let user=conn!.ownerID!
  if path=="/api/v1/me" {
   meCalls+=1;let teams:[[String:Any]]=member[user]! ? [["id":team.uuidString,"kind":"team","name":"Tým","role":roles[user]!]]:[]
   // Souběh: /me tým ještě vrátí, ale další požadavky už přístup nemají.
   if leaveAfterMe.contains(user){leaveAfterMe.remove(user);member[user]=false}
   return try cloudFixtureMe(user,teams:teams)
  }
  if path=="/api/v1/folders" {
   var list:[[String:Any]]=[["id":personal[user]!.uuidString,"name":"Bugy","revision":"1","owner_id":user.uuidString,"owner_kind":"personal","owner_name":NSNull(),"role":"owner"]]
   if member[user]!{list.append(["id":folderID.uuidString,"name":"Bugy","revision":"1","owner_id":team.uuidString,"owner_kind":"team","owner_name":"Tým","role":roles[user]!])}
   if leaveAfterFolders.contains(user){leaveAfterFolders.remove(user);member[user]=false}
   return try JSONSerialization.data(withJSONObject:["data":list])
  }
  if path.contains("/images/"){return png}
  if path.contains("?") {
   lists.append(path)
   let items=path.contains("state=trashed") || !member[user]! || !path.contains(folderID.uuidString.lowercased()) ? []:notes.enumerated().filter{!trashed.contains($0.element)}.map{["id":$0.element.uuidString,"updated_at":"t1","trashed_at":NSNull(),"author":["id":authors[$0.offset].uuidString,"name":names[authors[$0.offset]]!]] as [String:Any]}
   return try JSONSerialization.data(withJSONObject:["data":items,"pagination":["has_more":false]])
  }
  guard member[user]!,let i=notes.firstIndex(where:{path.contains($0.uuidString.lowercased())}) else{throw CloudFailure("404",status:404,code:"not_found")}
  details+=1
  return try JSONSerialization.data(withJSONObject:["data":["id":notes[i].uuidString,"title":"Bug \(i)","comment":"Text","template":"# {title}\n\nAutor: {author}\n\n{screenshots}\n\n{text}\n","captions":[""],"updated_at":"t1","created_at":"2026-04-0\(i+1)T10:00:00Z","author":["id":authors[i].uuidString,"name":names[authors[i]]!],"images":[["index":1,"path":"/api/v1/sessions/"+notes[i].uuidString.lowercased()+"/images/1"]]]])
 },send:{_,path,_,_,_ in
  posts.append(path);if let id=notes.first(where:{path.contains($0.uuidString.lowercased())}),path.hasSuffix("/trash"){trashed.insert(id)}
  return try JSONSerialization.data(withJSONObject:["data":["id":UUID().uuidString]])
 },now:{clock})
 func scan(_ seconds:Double)async{clock=clock.addingTimeInterval(seconds);await store.refresh(conn)}
 func markdowns(_ dir:URL)->[String]{((try? fm.contentsOfDirectory(atPath:dir.path)) ?? []).filter{$0.hasSuffix(".md")}.sorted()}
 func snapshot(_ dir:URL)->[String]{((fm.enumerator(atPath:dir.path)?.allObjects as? [String]) ?? []).sorted()}
 // Předpona týmu, ikona/role a pořadí osobní → týmová.
 await store.refresh(cA);assert(store.lastError==nil && store.topics.count==2)
 var teamTopic=store.topics[1]
 assert(store.topics[0].cloudTeam != true && store.topics[0].displayName=="Bugy" && teamTopic.displayName=="Tým · Bugy" && teamTopic.cloudOwnerID==team && teamTopic.cloudRole=="member" && !teamTopic.canManageCloudFolder)
 assert(teamTopic.id=="cloud:"+cA.endpoint+":"+team.uuidString+":"+folderID.uuidString)
 AppLanguage.override="en";assert(teamTopic.displayName=="Tým · Bugy");AppLanguage.override="cs"
 // Účet A: stáhne poznámky všech autorů s {author}; seznam je zúžený na library týmu.
 let dirA=root.appendingPathComponent("A Bugy"),dirB=root.appendingPathComponent("B Bugy")
 try store.setFolder(teamTopic,path:dirA.path);await store.refresh(cA);teamTopic=store.topics[1]
 assert(store.lastError==nil && markdowns(dirA).count==3 && lists.contains{$0.contains("folder_id="+folderID.uuidString.lowercased()) && $0.contains("library_id="+team.uuidString.lowercased())})
 assert(!lists.contains{$0.contains(personal[userA]!.uuidString.lowercased()) && $0.contains("library_id")})
 let first=try String(contentsOf:dirA.appendingPathComponent(markdowns(dirA)[0]),encoding:.utf8);assert(first.contains("Autor: Alice") || first.contains("Autor: Bob"))
 // Účet B na stejném Macu: vlastní adresář, kolize s adresářem A odmítnutá, stejné poznámky.
 conn=cB;await store.refresh(cB);assert(store.lastError==nil && store.topics.count==2 && store.topics[1].cloudRole=="admin" && store.topics[1].canManageCloudFolder)
 do{try store.setFolder(store.topics[1],path:dirA.path);assertionFailure("Second account reused the first account's directory")}catch{}
 try store.setFolder(store.topics[1],path:dirB.path);await store.refresh(cB)
 assert(store.lastError==nil && markdowns(dirB)==markdowns(dirA) && store.records.filter{$0.id==folderID}.count==2 && Set(store.records.filter{$0.id==folderID}.map(\.account))==[userA,userB])
 print("PASS: team folder shown as „Tým · Bugy“ after personal ones, library_id listing, {author} rendered, two accounts with different paths download the same notes")
 // Člen: cizí smazání zůstane místní s jedním upozorněním, vlastní jde do Koše.
 conn=cA;await store.refresh(cA);try store.setConfirmLocalDeletes(store.topics[1],false)
 let index=SessionIndex.shared,baseA=try Topics.checkedDestination(dirA.path)
 func fileA(_ i:Int)->URL{URL(fileURLWithPath:index.cloud(notes[i],base:baseA)!.file)}
 try fm.removeItem(at:fileA(1))
 await scan(20);await scan(20);await scan(20)
 let keptNotice="Smazání ve složce Tým · Bugy zůstává jen na tomto Macu"
 assert(posts.isEmpty && index.cloud(notes[1],base:baseA)?.keptLocal==true && store.notices.filter{$0.hasPrefix(keptNotice)}.count==1 && markdowns(dirA).count==2)
 // Přesun cizí relace do .trash také zůstane místní.
 let trashA=dirA.appendingPathComponent(".trash");try fm.createDirectory(at:trashA,withIntermediateDirectories:true)
 try fm.moveItem(at:fileA(2),to:trashA.appendingPathComponent(fileA(2).lastPathComponent));await scan(20)
 assert(posts.isEmpty && index.cloud(notes[2],base:baseA)?.keptLocal==true && store.notices.filter{$0.hasPrefix(keptNotice)}.count==2)
 try fm.removeItem(at:fileA(0));await scan(20);await scan(20)
 assert(posts==["/api/v1/sessions/"+notes[0].uuidString.lowercased()+"/trash"])
 print("PASS: member keeps deletion of another member's note local with one notice, own note goes to web Trash")
 // Člen nemění nastavení týmové složky; server se nevolá.
 do{_ = try await store.update(store.topics[1]);assertionFailure("Member updated team folder")}catch let failure as CloudFailure{assert(failure.code=="role_forbidden")}
 do{try await store.trashFolder(store.topics[1]);assertionFailure("Member trashed team folder")}catch let failure as CloudFailure{assert(failure.code=="role_forbidden")}
 assert(posts.count==1)
 // Ztráta členství: skryto, soubory i mapování zůstávají, nic se nestahuje ani nemaže.
 let before=snapshot(dirA),listed=lists.count,fetched=details;member[userA]=false
 await scan(20);await scan(20)
 assert(store.lastError==nil && store.topics.count==1 && store.topics[0].cloudTeam != true && store.deletedRemotely.isEmpty && store.isUnavailable(teamTopic))
 assert(snapshot(dirA)==before && lists.count==listed && details==fetched && posts.count==1 && store.heldFolders.isEmpty && store.deletePrompts.isEmpty)
 assert(store.records.first{$0.id==folderID && $0.account==userA}?.folder==dirA.path)
 do{try store.setFolder(store.topics[0],path:dirA.path);assertionFailure("Hidden mapping did not reserve its directory")}catch{}
 // Rozpracovaná relace v nedostupné složce přejde do výchozí s upozorněním.
 let fallback=fallbackFromHiddenFolder(Draft(images:[],comment:"x",topic:teamTopic),folders:store,defaultTopic:store.topics[0])
 assert(fallback?.topic==store.topics[0] && store.notices.contains{$0.hasPrefix("Složka Tým · Bugy už není dostupná")} && fallbackFromHiddenFolder(Draft(images:[],comment:"x",topic:store.topics[0]),folders:store)==nil)
 print("PASS: losing the team hides its folder (not remoteDeleted), keeps files and mapping, stops download/trash propagation and moves the draft to the default folder")
 // Návrat do týmu: stejné mapování a index, bez duplikátů.
 member[userA]=true;await scan(20);await scan(20)
 assert(store.lastError==nil && store.topics.count==2 && store.topics[1].folder==dirA.path && !store.isUnavailable(teamTopic))
 let after=markdowns(dirA);assert(!after.contains{$0.contains(" 2.md")} && posts.count==1)
 print("PASS: returning to the team restores mapping and session index without duplicate downloads")
 // Souběh: tým zmizí mezi /me a seznamem; 404 detailu nic nesmaže, složka se skryje.
 conn=cB;await store.refresh(cB);let beforeB=snapshot(dirB);leaveAfterFolders=[userB]
 await store.refresh(cB)
 assert(snapshot(dirB)==beforeB && store.topics.count==1 && store.records.first{$0.id==folderID && $0.account==userB}?.unavailable==true)
 // Souběh dřív: katalog už týmovou složku nemá; není to smazání na webu.
 member[userB]=true;await store.refresh(cB);assert(store.topics.count==2 && snapshot(dirB)==beforeB)
 leaveAfterMe=[userB];await store.refresh(cB)
 assert(snapshot(dirB)==beforeB && store.deletedRemotely.isEmpty && store.records.first{$0.id==folderID && $0.account==userB}?.unavailable==true)
 print("PASS: team loss racing the session list never purges local files")
 // Starší záznam bez account se načte s account = owner.
 let legacy=root.appendingPathComponent("legacy.json"),old=UUID()
 try JSONSerialization.data(withJSONObject:[["id":old.uuidString,"name":"Starý","owner":userA.uuidString,"origin":cA.endpoint,"folder":""]]).write(to:legacy)
 let migrated=CloudFolders(file:legacy,connection:{cA},localTopics:{[]});migrated.activate(cA)
 assert(migrated.records[0].account==userA && !migrated.records[0].isTeam && migrated.topics.map(\.cloudFolderID)==[old])
 do{try migrated.accept([CloudFolderRecord(id:UUID(),name:"Cizí",owner:team,origin:cA.endpoint,accountID:userA)]);assertionFailure("Team folder without /me library accepted")}catch{}
 try migrated.accept([CloudFolderRecord(id:UUID(),name:"Tým",owner:team,origin:cA.endpoint,accountID:userA)],libraries:[CloudLibraryRef(id:team,kind:"team",name:"Tým",role:"owner")])
 assert(migrated.topics.count==1 && migrated.topics[0].displayName=="Tým · Tým" && migrated.topics[0].canManageCloudFolder)
 // {author}: prázdný, když autor není známý; vestavěná šablona ho nemá a parsování ho zvládne.
 assert(!defaultMarkdownTemplate.contains("{author}") && renderSessionTemplate("# {title}\n{author}\n{screenshots}\n{text}\n",title:"T",screenshots:"S",text:"X")=="# T\n\nS\nX\n")
 assert(parsedSession("# {title}\n{author}\n{screenshots}\n{text}\n","# T\nBob\n![[assets/a.png]]\nX\n")?.1=="X")
 print("PASS: legacy folder records migrate to account = owner, team records need a /me library, {author} renders the author or nothing")
 // Člen smí upravit jen vlastní relaci týmové složky (autor z indexu), admin všechny.
 conn=cA;await store.refresh(cA);let teamA=store.topics.first{$0.cloudTeam==true}!
 assert(store.mayChange(notes[0],topic:teamA)==true || index.cloud(notes[0],base:baseA)==nil)
 let otherNote=notes.first{index.cloud($0,base:baseA)?.authorID==userB.uuidString.lowercased()}
 assert(otherNote.map{!store.mayChange($0,topic:teamA)} ?? true && !store.mayChange(UUID(),topic:teamA))
 conn=cB;await store.refresh(cB);let teamB=store.topics.first{$0.cloudTeam==true}
 assert(teamB.map{store.mayChange(UUID(),topic:$0)} ?? true)
 // Odhlášení: týmová složka nezmění na lokální (žádný reconnect), mapování zůstane a po přihlášení naváže.
 var local:[Topic]=[]
 let signout=CloudFolders(file:root.appendingPathComponent("signout.json"),connection:{conn},localTopics:{local},request:{_,_,_,_ in throw CloudFailure.invalid},storedLocal:{local},saveLocal:{local=$0})
 conn=cA;signout.activate(cA)
 let personalRecord=CloudFolderRecord(id:UUID(),name:"Moje",owner:userA,origin:cA.endpoint,folder:root.appendingPathComponent("moje").path,accountID:userA)
 var teamRecord=CloudFolderRecord(id:folderID,name:"Bugy",owner:team,origin:cA.endpoint,folder:root.appendingPathComponent("tym-a").path,accountID:userA);teamRecord.ownerKind="team"
 try signout.accept([personalRecord,teamRecord],libraries:[CloudLibraryRef(id:team,kind:"team",name:"Tým",role:"member")])
 try signout.setFolder(signout.topics[0],path:root.appendingPathComponent("moje").path);try signout.setFolder(signout.topics[1],path:root.appendingPathComponent("tym-a").path)
 signout.activate(nil);try signout.convertToLocal(owner:userA,origin:cA.endpoint)
 assert(local.count==1 && local[0].formerCloudOwnerID==userA && signout.records.count==1 && signout.records[0].owner==team)
 signout.activate(cA);assert(signout.repairCandidates.isEmpty)
 try signout.accept([teamRecord],libraries:[CloudLibraryRef(id:team,kind:"team",name:"Tým",role:"member")])
 assert(signout.topics.first{$0.cloudTeam==true}?.folder==root.appendingPathComponent("tym-a").path)
 // Smazanou týmovou složku zachovanou jako lokální mají dva účty pod různými ID.
 var teamB2=teamRecord;teamB2.accountID=userB;teamB2.folder=root.appendingPathComponent("tym-b").path
 signout.activate(cB);try signout.accept([teamB2],libraries:[CloudLibraryRef(id:team,kind:"team",name:"Tým",role:"admin")]);try signout.setFolder(signout.topics[0],path:root.appendingPathComponent("tym-b").path)
 for (c,user) in [(cA,userA),(cB,userB)] {signout.activate(c);try signout.accept([],libraries:[CloudLibraryRef(id:team,kind:"team",name:"Tým",role:"admin")]);_ = try signout.keepDeleted(folderID);assert(local.contains{$0.id=="former-cloud:"+user.uuidString.lowercased()+":"+folderID.uuidString.lowercased()})}
 assert(local.filter{$0.formerCloudFolderID==folderID}.count==2)
 print("PASS: member edits only own team sessions, sign-out keeps team mappings for sign-in without reconnect, kept deleted team folders get account-scoped IDs")
}
