import AppKit
@testable import ScreenshotNoteKit

/// AI název složky: čtení a zápis přes /ai-title, uložený stav, starší server a role v týmu.
@MainActor func aiTitleFolderTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-ai-title-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let c=cloudFixtureConnection(),owner=c.ownerID!,personal=UUID(),teamFolder=UUID(),team=UUID()
 var serverEnabled=false,legacy=true,plan=true,putStatus:CloudFailure?=nil
 var sent:[(String,String,Data)]=[]
 let file=root.appendingPathComponent("folders.json")
 func folder(_ id:UUID,_ name:String,owner:UUID?=nil,role:String?=nil)->[String:Any] {
  var value:[String:Any]=["id":id.uuidString,"name":name,"revision":"1","description":"","combined":false,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":NSNull()]
  if let owner{value["owner_id"]=owner.uuidString;value["owner_kind"]="team";value["owner_name"]="Tým";value["role"]=role ?? "member"}
  if !legacy{value["ai_title"]=id==personal ? serverEnabled:false}
  return value
 }
 func setting()->Data{try! JSONSerialization.data(withJSONObject:["data":["folder_id":personal.uuidString.lowercased(),"enabled":serverEnabled,"can_change":true,"plan":plan,"used":7,"limit":1000]])}
 let store=CloudFolders(file:file,connection:{c},localTopics:{[]},request:{_,path,_,_ in
  if path=="/api/v1/me"{return try cloudFixtureMe(owner,teams:[["id":team.uuidString,"kind":"team","name":"Tým","role":"member"]])}
  if path=="/api/v1/folders"{return try JSONSerialization.data(withJSONObject:["data":[folder(personal,"Osobní"),folder(teamFolder,"Týmová",owner:team)]])}
  if path.hasSuffix("/ai-title"){if legacy{throw CloudFailure("404",status:404)};return setting()}
  throw CloudFailure("404",status:404,code:"not_found")
 },send:{_,path,method,_,body in
  sent.append((path,method,body))
  if path.hasSuffix("/ai-title"){
   if let putStatus{throw putStatus}
   let value=try JSONSerialization.jsonObject(with:body) as! [String:Any];serverEnabled=value["enabled"] as! Bool;return setting()
  }
  // Uložení nastavení složky vrací tvar bez ai_title.
  var value=folder(personal,"Přejmenovaná");value["revision"]="2";value.removeValue(forKey:"ai_title")
  return try JSONSerialization.data(withJSONObject:["data":value])
 },pending:{_ in false})
 // Starší server pole nezná: nastavení není a čtení hlásí nepodporovaný server.
 await store.refresh(c);assert(store.lastError==nil)
 let old=store.topics.first{$0.cloudFolderID==personal}!
 assert(old.aiTitle==nil)
 do{_ = try await store.aiTitle(old);assertionFailure("Legacy server accepted")}catch let failure as CloudFailure{assert(failure.status==404 && failure.message==L("Server zatím AI názvy relací nepodporuje."))}
 // Nový server: výchozí vypnuto, zapnutí pošle jen {"enabled":true} a uloží se.
 legacy=false;await store.refresh(c)
 var topic=store.topics.first{$0.cloudFolderID==personal}!
 assert(topic.aiTitle==false)
 let read=try await store.aiTitle(topic);assert(read==CloudFolders.AITitleSetting(enabled:false,can_change:true,plan:true,used:7,limit:1000) && sent.isEmpty)
 let on=try await store.aiTitle(topic,enable:true)
 let body=try JSONSerialization.jsonObject(with:sent[0].2) as! [String:Any]
 assert(on.enabled && sent[0].0=="/api/v1/folders/"+personal.uuidString.lowercased()+"/ai-title" && sent[0].1=="PUT" && body.count==1 && body["enabled"] as? Bool==true)
 assert(store.topics.first{$0.cloudFolderID==personal}!.aiTitle==true)
 let reloaded=CloudFolders(file:file,connection:{c},localTopics:{[]});reloaded.activate(c)
 assert(reloaded.topics.first{$0.cloudFolderID==personal}!.aiTitle==true)
 // Uložení ostatních nastavení stav nepřepíše, i když ho odpověď nenese.
 topic=store.topics.first{$0.cloudFolderID==personal}!;topic.name="Přejmenovaná"
 let saved=try await store.update(topic);assert(saved.aiTitle==true)
 // Chyby serveru: bez tarifu srozumitelná hláška a stav se nezmění.
 putStatus=CloudFailure("402",status:402,code:"plan_required")
 do{_ = try await store.aiTitle(saved,enable:false);assertionFailure("Plan error ignored")}catch let failure as CloudFailure{assert(failure.code=="plan_required" && failure.message==L("AI názvy relací potřebují aktivní cloudový tarif nebo zkušební období."))}
 assert(store.topics.first{$0.cloudFolderID==personal}!.aiTitle==true)
 // Člen týmu nastavení čte, ale nezmění; požadavek se vůbec nepošle.
 putStatus=nil;let count=sent.count
 let member=store.topics.first{$0.cloudFolderID==teamFolder}!
 assert(member.aiTitle==false && !member.canManageCloudFolder)
 do{_ = try await store.aiTitle(member,enable:true);assertionFailure("Member changed AI title")}catch let failure as CloudFailure{assert(failure.code=="role_forbidden")}
 assert(sent.count==count)
 print("PASS: AI title folder setting round-trip: legacy server hidden, off by default, PUT {enabled} persisted, kept on folder save, plan error, member cannot change")
}
