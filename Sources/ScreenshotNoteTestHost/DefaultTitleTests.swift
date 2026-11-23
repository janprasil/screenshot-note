import AppKit
@testable import ScreenshotNoteKit

/// Výchozí název relace: pořadí složka → globální → „Screenshot“, prázdný název pro AI a synchronizace se serverem.
@MainActor func defaultTitleTests() async throws {
 let saved=UserDefaults.standard.string(forKey:DefaultTitle.key),pending=UserDefaults.standard.dictionary(forKey:CloudFolders.pendingDefaultTitleKey)
 defer{
  if let saved{UserDefaults.standard.set(saved,forKey:DefaultTitle.key)}else{UserDefaults.standard.removeObject(forKey:DefaultTitle.key)}
  if let pending{UserDefaults.standard.set(pending,forKey:CloudFolders.pendingDefaultTitleKey)}else{UserDefaults.standard.removeObject(forKey:CloudFolders.pendingDefaultTitleKey)}
 }
 DefaultTitle.global=nil
 var plain=Topic(id:"t",name:"Místní",detail:"",folder:"/tmp",combined:false,combinedFile:"All.md"),ai=plain;ai.aiTitle=true
 // Pravidla stejná jako na serveru.
 assert(validDefaultTitle("Bug") && !validDefaultTitle(" Bug") && !validDefaultTitle("") && !validDefaultTitle("a\nb") && !validDefaultTitle(String(repeating:"x",count:101)))
 assert(DefaultTitle.resolve(plain)==builtInSessionTitle)
 DefaultTitle.global="Globální";assert(DefaultTitle.resolve(plain)=="Globální" && DefaultTitle.resolve(nil)=="Globální")
 plain.defaultTitle="Složka";assert(DefaultTitle.resolve(plain)=="Složka")
 DefaultTitle.global="  neplatný";assert(DefaultTitle.global=="Globální")
 // Do cloudu: zadaný název, prázdný jen u nové relace v AI složce, jinak výchozí.
 assert(DefaultTitle.cloudTitle(" Můj\n", topic:ai, allowAI:true)=="Můj")
 assert(DefaultTitle.cloudTitle(nil, topic:ai, allowAI:true)=="")
 assert(DefaultTitle.cloudTitle("", topic:ai, allowAI:false)=="Globální")
 assert(DefaultTitle.cloudTitle("", topic:plain, allowAI:true)=="Složka")
 // Úprava relace v AI složce nepřepíše prázdný název na „Screenshot“.
 var draft=Draft(images:[],comment:"Text",title:"");draft.topic=ai
 assert(CloudLibrary.editFields(draft).title=="")
 draft.topic=plain;assert(CloudLibrary.editFields(draft).title=="Složka")
 // Stažená relace bez názvu: soubor i nadpis dostanou výchozí název složky.
 let created=ISO8601DateFormatter().date(from:"2026-11-23T10:00:00Z")!
 assert(readableSessionName("",created:created,fallback:"Složka").hasSuffix(" Složka") && readableSessionName("",created:created).hasSuffix(" Globální"))
 assert(readableSessionName("",created:created,fallback:"Bug/Issue").hasSuffix(" Bug_Issue") && !readableSessionName("",created:created,fallback:String(repeating:"é",count:100)).contains("/") && readableSessionName("",created:created,fallback:String(repeating:"é",count:100)).utf8.count<=131)
 let note=RemoteNote(id:UUID(),title:"",comment:"Text",template:"# {title}\n\n{screenshots}\n\n{text}\n",captions:[],images:[])
 assert(cloudSessionBody(note,images:[],fallbackTitle:"Složka").hasPrefix("# Složka") && cloudSessionBody(note,images:[]).hasPrefix("# Globální"))

 // Server: výchozí název složky ve výpisu, PUT jen pro správce, globální hodnota přes /account/default-title.
 let root=fm.temporaryDirectory.appendingPathComponent("sn-default-title-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let c=cloudFixtureConnection(),owner=c.ownerID!,personal=UUID(),teamFolder=UUID(),team=UUID()
 var folderTitle:Any=NSNull(),account:Any="Účet",sent:[(String,String,[String:Any])]=[]
 func folder(_ id:UUID,_ name:String,owner:UUID?=nil)->[String:Any] {
  var value:[String:Any]=["id":id.uuidString,"name":name,"revision":"1","description":"","combined":false,"combined_file":"All.md","markdown_template":NSNull(),"combined_template":NSNull(),"default_title":id==personal ? folderTitle:NSNull()]
  if let owner{value["owner_id"]=owner.uuidString;value["owner_kind"]="team";value["owner_name"]="Tým";value["role"]="member"}
  return value
 }
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
  if path=="/api/v1/me"{return try cloudFixtureMe(owner,teams:[["id":team.uuidString,"kind":"team","name":"Tým","role":"member"]])}
  if path=="/api/v1/folders"{return try JSONSerialization.data(withJSONObject:["data":[folder(personal,"Osobní"),folder(teamFolder,"Týmová",owner:team)]])}
  if path=="/api/v1/account/default-title"{return try JSONSerialization.data(withJSONObject:["data":["folder_id":NSNull(),"default_title":account]])}
  throw CloudFailure("404",status:404,code:"not_found")
 },send:{_,path,method,_,body in
  let value=try JSONSerialization.jsonObject(with:body) as! [String:Any];sent.append((path,method,value))
  if path=="/api/v1/account/default-title"{account=value["default_title"] ?? NSNull();return try JSONSerialization.data(withJSONObject:["data":["folder_id":NSNull(),"default_title":account]])}
  folderTitle=value["default_title"] ?? NSNull()
  return try JSONSerialization.data(withJSONObject:["data":["folder_id":personal.uuidString.lowercased(),"default_title":folderTitle]])
 },pending:{_ in false})
 // Bez místní změny platí serverová globální hodnota.
 UserDefaults.standard.removeObject(forKey:CloudFolders.pendingDefaultTitleKey)
 await store.refresh(c);await store.syncDefaultTitle(c);assert(store.lastError==nil && DefaultTitle.global=="Účet" && sent.isEmpty)
 var topic=store.topics.first{$0.cloudFolderID==personal}!
 assert(topic.defaultTitle==nil)
 try await store.setDefaultTitle(topic,"Bug")
 assert(sent.count==1 && sent[0].0=="/api/v1/folders/"+personal.uuidString.lowercased()+"/default-title" && sent[0].1=="PUT" && sent[0].2.count==1 && sent[0].2["default_title"] as? String=="Bug")
 topic=store.topics.first{$0.cloudFolderID==personal}!;assert(topic.defaultTitle=="Bug" && DefaultTitle.resolve(topic)=="Bug")
 // Vrácení na zdědění pošle null.
 try await store.setDefaultTitle(topic,nil);assert(sent[1].2["default_title"] is NSNull && store.topics.first{$0.cloudFolderID==personal}!.defaultTitle==nil)
 // Člen týmu výchozí název složky nezmění; nic se neodešle.
 let member=store.topics.first{$0.cloudFolderID==teamFolder}!
 do{try await store.setDefaultTitle(member,"X");assertionFailure("Member changed default title")}catch let failure as CloudFailure{assert(failure.code=="role_forbidden")}
 assert(sent.count==2)
 // Místní změna globálního názvu se při synchronizaci pošle na server.
 // Změna pro jiný účet se sem neposílá a hodnotu serveru nepřepíše.
 DefaultTitle.global="Jiný";UserDefaults.standard.set(["account":"https://other.invalid|x","value":"Jiný"],forKey:CloudFolders.pendingDefaultTitleKey)
 await store.syncDefaultTitle(c);assert(sent.count==2 && CloudFolders.pendingDefaultTitle?.value=="Jiný")
 // Čekající hodnota účtu se pošle, i když se globální hodnota mezitím změnila jiným účtem.
 DefaultTitle.global="Jiný účet";UserDefaults.standard.set(["account":CloudFolders.accountKey(c),"value":"Mac"],forKey:CloudFolders.pendingDefaultTitleKey)
 await store.syncDefaultTitle(c)
 assert(sent.last!.0=="/api/v1/account/default-title" && sent.last!.2["default_title"] as? String=="Mac" && CloudFolders.pendingDefaultTitle==nil && DefaultTitle.global=="Mac")
 print("PASS: default title: folder → global → Screenshot, empty title only for AI folders, folder PUT for managers, account sync both ways")
}

/// Nahrání: bez názvu v AI složce jde prázdný název a Mac hned požádá o AI název; jinde jde výchozí název.
@MainActor func aiTitleUploadTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-ai-upload-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let saved=CloudTransport.shared.session,config=URLSessionConfiguration.ephemeral;config.protocolClasses=[AcceptingUploadStub.self]
 CloudTransport.shared.session=URLSession(configuration:config);defer{CloudTransport.shared.session=saved}
 let previousGlobal=UserDefaults.standard.string(forKey:DefaultTitle.key);defer{if let previousGlobal{UserDefaults.standard.set(previousGlobal,forKey:DefaultTitle.key)}else{UserDefaults.standard.removeObject(forKey:DefaultTitle.key)}}
 DefaultTitle.global=nil
 AcceptingUploadStub.manifests=[];AcceptingUploadStub.aiTitleCalls=[]
 let c=cloudFixtureConnection();AcceptingUploadStub.owner=c.ownerID!
 let vault=CloudMemoryVault();vault.value=c
 let library=CloudLibrary(queue:root.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(c.endpoint)!)
 var topic=Topic(id:"cloud",name:"AI",detail:"",folder:"",combined:false,combinedFile:"All.md")
 topic.cloudFolderID=UUID();topic.cloudOwnerID=c.ownerID;topic.cloudOrigin=c.endpoint;topic.aiTitle=true
 var plain=topic;plain.aiTitle=nil;plain.defaultTitle="Bug"
 let draftRoot=root.appendingPathComponent("draft");try fm.createDirectory(at:draftRoot,withIntermediateDirectories:true)
 try cloudFixturePNG().write(to:draftRoot.appendingPathComponent("a.png"))
 var draft=Draft(images:["a.png"],comment:"Text",title:"");draft.topic=topic
 let ai=try library.enqueue(draft,root:draftRoot,folders:[topic])
 draft.topic=plain
 let named=try library.enqueue(draft,root:draftRoot,folders:[plain])
 await library.sync()
 let titles=Dictionary(uniqueKeysWithValues:AcceptingUploadStub.manifests.map{($0.0,$0.1["title"] as? String)})
 assert(titles[ai] == .some("") && titles[named] == .some("Bug") && AcceptingUploadStub.aiTitleCalls==[ai] && library.pendingCount==0)
 print("PASS: AI title upload: empty title and immediate /ai-title only for AI folders, default title elsewhere")
}
