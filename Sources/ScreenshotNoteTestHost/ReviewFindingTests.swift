import AppKit
@testable import ScreenshotNoteKit

/// Regrese nálezů review: odložené položky, revize doplnění, limity, fronta, timeouty, úpravy, mazání, index.
@MainActor func reviewFindingTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-review-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let restore=ReviewStub.install();defer{restore()}
 typealias Fields=CloudLibrary.CloudEdit.Fields
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection();let c=vault.value!,owner=c.ownerID!
 var clock=Date()
 func library(_ name:String,_ store:CloudCredentialStore=vault)->CloudLibrary{CloudLibrary(queue:root.appendingPathComponent(name),vault:store,endpoint:CloudEndpoint(c.endpoint)!,now:{clock},recycle:{try fm.removeItem(at:$0)})}
 let shots=root.appendingPathComponent("shots");try fm.createDirectory(at:shots,withIntermediateDirectories:true)
 let original=cloudFixturePNG(0.6);try original.write(to:shots.appendingPathComponent("old.png"));try cloudFixturePNG(0.9).write(to:shots.appendingPathComponent("new.png"))
 let topic=Topic(id:"cloud",name:"Cloud",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:UUID(),cloudOwnerID:owner,cloudOrigin:c.endpoint)

 // Server nahrávání: manifest, obrázky a commit; chování jednotlivých relací řídí refuse.
 var manifests:[String:[String:Any]]=[:],committed:[String:[String:Any]]=[:],refuse:[String:(Int,String)]=[:]
 var remote:[String:Any]=[:],remoteID=""
 func upload(_ method:String,_ path:String,_ body:Data)->(Int,Any)? {
  let parts=path.split(separator:"/").map(String.init)
  if path=="/api/v1/me"{return (200,["data":["id":owner.uuidString]])}
  guard parts.count>=4,parts[2]=="uploads" else{return nil}
  let id=parts[3]
  if let (status,code)=refuse[id]{return (status,["error":["code":code]])}
  if parts.count==4 && method=="PUT" {
   let manifest=json(body)
   if manifest["base_images"] != nil,id==remoteID,manifest["revision"] as? String != remote["revision"] as? String{return (409,["error":["code":"session_changed"]])}
   manifests[id]=manifest
  }
  let manifest=manifests[id] ?? [:],count=(manifest["images"] as? [Any])?.count ?? 1,base=manifest["base_images"] as? Int ?? 0
  let done=parts.last=="commit";if done{committed[id]=manifest}
  if parts.count==6{return (200,["data":[:]])}
  return (200,["data":["session_id":id,"state":done ? "committed":"uploading","manifest_digest":sessionFingerprint(JSONSerialization.isValidJSONObject(manifest) ? (try! JSONSerialization.data(withJSONObject:manifest,options:.sortedKeys)):Data()),"confirmed_indices":done ? Array(1...count):(base>0 ? Array(1...base):[])]])
 }
 ReviewStub.handler={method,path,body in
  if let reply=upload(method,path,body){return reply}
  if path=="/api/v1/sessions/"+remoteID {return (200,["data":remote])}
  if path=="/api/v1/sessions/"+remoteID+"/images/1"{return (200,original)}
  return (404,["error":["code":"not_found"]])
 }

 // 4 + 1: vadná úloha neblokuje ostatní, po třech trvalých chybách se odloží a zobrazí; Uložit lokálně, Zkusit znovu, Zahodit.
 let queue=library("queue")
 let bad=try queue.enqueue(Draft(images:["new.png"],comment:"Vadná",title:"Vadná relace",topic:topic,imageNotes:["new.png":"Popisek"]),root:shots,folders:[topic])
 let good=try queue.enqueue(Draft(images:["old.png"],comment:"Dobrá",title:"Dobrá relace",topic:topic),root:shots,folders:[topic])
 refuse[bad.uuidString.lowercased()]=(415,"invalid_image")
 await queue.sync()
 assert(committed[good.uuidString.lowercased()] != nil && queue.pendingCount==1 && queue.failureCount(bad)==1 && queue.lastError != nil && queue.parkedItems.isEmpty)
 for _ in 0..<2{clock=clock.addingTimeInterval(4000);await queue.sync()}
 let parked=queue.parkedItems
 assert(queue.pendingCount==0 && parked.count==1 && parked[0].sessionID==bad && parked[0].kind == .upload && parked[0].retryable && !parked[0].stranded && parked[0].reason?.contains("Vadná relace")==true)
 let saveTo=root.appendingPathComponent("saved-locally")
 try queue.saveParkedLocally(parked[0],to:saveTo)
 let savedSessions=try previousSessions(in:saveTo)
 assert(queue.parkedItems.isEmpty && savedSessions.count==1 && savedSessions[0].title=="Vadná relace" && savedSessions[0].images.count==1 && savedSessions[0].imageNotes.values.contains("Popisek"))
 let conflict=try queue.enqueue(Draft(images:["old.png"],comment:"",title:"Konflikt",topic:topic),root:shots,folders:[topic])
 refuse[conflict.uuidString.lowercased()]=(409,"job_conflict");clock=clock.addingTimeInterval(4000);await queue.sync()
 assert(queue.parkedItems.count==1 && queue.pendingCount==0)
 try queue.retryParked(queue.parkedItems[0]);assert(queue.parkedItems.isEmpty && queue.pendingCount==1)
 refuse[conflict.uuidString.lowercased()]=nil;await queue.sync();assert(queue.pendingCount==0 && committed[conflict.uuidString.lowercased()] != nil)
 let dropped=try queue.enqueue(Draft(images:["old.png"],comment:"",title:"Zahodit",topic:topic),root:shots,folders:[topic])
 refuse[dropped.uuidString.lowercased()]=(409,"job_conflict");clock=clock.addingTimeInterval(4000);await queue.sync()
 try queue.discardParked(queue.parkedItems[0]);assert(queue.parkedItems.isEmpty && queue.pendingCount==0)
 assert(CloudLibrary.classify(URLError(.timedOut)) == .timeout && CloudLibrary.classify(CloudFailure("x",status:413,code:"billing_storage_limit")) == .stop && CloudLibrary.classify(CloudFailure("x",status:413,code:"resource_limit")) == .permanent && CloudLibrary.classify(CloudFailure("x",status:413)) == .permanent && CloudLibrary.classify(CloudFailure("x",status:415)) == .permanent && CloudLibrary.classify(CloudFailure("x",status:503)) == .transient && CloudLibrary.classify(CloudFailure("x",status:429)) == .stop && CloudLibrary.classify(CloudFailure.invalid) == .permanent)
 // Jen výpadek připojení zastaví celou frontu, ostatní síťové chyby jsou chybou úlohy.
 assert([URLError.Code.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed,.internationalRoamingOff,.dataNotAllowed].allSatisfy{CloudLibrary.classify(URLError($0)) == .stop})
 assert(CloudLibrary.classify(URLError(.badServerResponse)) == .transient && CloudLibrary.classify(URLError(.secureConnectionFailed)) == .transient)
 print("PASS: a failing job no longer blocks later jobs, permanent failures back off and park after 3 tries, parked items save locally / retry / discard")
 // 413 je kvóta účtu: celá fronta stojí s dlouhým odstupem, nic se neodkládá a po uvolnění místa se nahraje samo.
 let quota=library("quota");var quotaMessages=0;quota.onQuotaFailure={_ in quotaMessages+=1}
 let quotaFirst=UUID(uuidString:"00000000-0000-4000-8000-000000000001")!,quotaLater=UUID(uuidString:"ffffffff-ffff-4fff-8fff-ffffffffffff")!
 try quota.enqueue(Draft(images:["old.png"],comment:"",title:"Plno 1",topic:topic),root:shots,sessionID:quotaFirst,folders:[topic])
 try quota.enqueue(Draft(images:["old.png"],comment:"",title:"Plno 2",topic:topic),root:shots,sessionID:quotaLater,folders:[topic])
 refuse[quotaFirst.uuidString.lowercased()]=(413,"billing_storage_limit")
 for _ in 0..<4 {
  clock=clock.addingTimeInterval(1000);ReviewStub.log=[];await quota.sync()
  assert(!ReviewStub.log.contains{$0.1.contains(quotaLater.uuidString.lowercased())} && quota.retryAt>=clock.addingTimeInterval(890) && quota.parkedItems.isEmpty && quota.pendingCount==2)
 }
 assert(quotaMessages==4)
 refuse[quotaFirst.uuidString.lowercased()]=nil;clock=clock.addingTimeInterval(1000);await quota.sync()
 assert(quota.pendingCount==0 && committed[quotaFirst.uuidString.lowercased()] != nil && committed[quotaLater.uuidString.lowercased()] != nil)
 print("PASS: 413 account quota stops the whole queue with a long backoff, never parks, and uploads automatically once space is freed")
 // 413 resource_limit: příliš velký požadavek se odloží hned, ostatní úlohy pokračují, žádné hlášení o plném úložišti.
 let tooBig=UUID(uuidString:"00000000-0000-4000-8000-000000000002")!,afterBig=UUID(uuidString:"ffffffff-ffff-4fff-8fff-fffffffffffe")!
 try quota.enqueue(Draft(images:["old.png"],comment:"",title:"Příliš velká",topic:topic),root:shots,sessionID:tooBig,folders:[topic])
 try quota.enqueue(Draft(images:["old.png"],comment:"",title:"Další",topic:topic),root:shots,sessionID:afterBig,folders:[topic])
 refuse[tooBig.uuidString.lowercased()]=(413,"resource_limit");clock=clock.addingTimeInterval(1000);await quota.sync()
 let bigParked=quota.parkedItems
 assert(quotaMessages==4 && committed[afterBig.uuidString.lowercased()] != nil && quota.pendingCount==0 && bigParked.count==1 && bigParked[0].sessionID==tooBig && bigParked[0].reason?.contains("Příliš velká")==true && bigParked[0].reason?.contains(L("Požadavek je pro cloud příliš velký (překračuje limit serveru). Opakování nepomůže; poznámka zůstává uložená lokálně."))==true && quota.lastError?.contains("nezbývá místo") != true)
 try quota.discardParked(bigParked[0])
 print("PASS: 413 resource_limit parks only that job at once with a too-large reason, other jobs proceed, no storage-full alert")
 // Po odpojení nebo pod jiným účtem fronta nezmizí: položky jsou viditelné jako osiřelé a jdou uložit lokálně.
 let waiting=try queue.enqueue(Draft(images:["old.png"],comment:"",title:"Čeká",topic:topic),root:shots,folders:[topic])
 let otherVault=CloudMemoryVault();otherVault.value=cloudFixtureConnection()
 let other=library("queue",otherVault),signedOut=library("queue",CloudMemoryVault())
 for view in [other,signedOut]{let items=view.parkedItems;assert(view.pendingCount==0 && items.count==1 && items[0].sessionID==waiting && items[0].stranded && !items[0].retryable)}
 try signedOut.saveParkedLocally(signedOut.parkedItems[0],to:saveTo);assert(queue.pendingCount==0 && (try! previousSessions(in:saveTo)).count==2)
 print("PASS: queued jobs of another account or after disconnect stay visible as stranded items and can be saved locally")

 // 2: doplnění posílá revizi; session_changed načte relaci, sloučí texty a pošle novou revizi.
 let ext=UUID();remoteID=ext.uuidString.lowercased()
 remote=["id":remoteID,"title":"Původní","comment":"Web komentář","captions":["Web popisek"],"revision":"5","images":[["index":1,"path":"/api/v1/sessions/"+remoteID+"/images/1"]]]
 let downloaded=Fields(title:"Původní",comment:"Původní komentář",captions:[""])
 let extDraft=Draft(images:["old.png","new.png"],comment:"Původní komentář",title:"Můj nadpis",imageNotes:["new.png":"Nový"])
 ReviewStub.log=[]
 try queue.enqueue(extDraft,root:shots,sessionID:ext,base:[sessionFingerprint(original)],revision:"3",original:downloaded)
 clock=clock.addingTimeInterval(4000);await queue.sync()
 let first=ReviewStub.log.first{$0.0=="PUT" && $0.1.hasSuffix("/uploads/"+remoteID)}.map{json($0.2)} ?? [:]
 let sent=committed[remoteID] ?? [:]
 assert(first["revision"] as? String=="3" && queue.pendingCount==0 && sent["revision"] as? String=="5" && sent["title"] as? String=="Můj nadpis" && sent["comment"] as? String=="Web komentář" && (sent["captions"] as? [String])==["Web popisek","Nový"] && sent["base_images"] as? Int==1)
 // Stejné pole změněné na webu i lokálně: doplnění se odloží a nepřepíše web.
 let clash=UUID();remoteID=clash.uuidString.lowercased()
 remote=["id":remoteID,"title":"Web nadpis","comment":"Původní komentář","captions":[""],"revision":"8","images":[["index":1,"path":"/api/v1/sessions/"+remoteID+"/images/1"]]]
 try queue.enqueue(extDraft,root:shots,sessionID:clash,base:[sessionFingerprint(original)],revision:"3",original:downloaded)
 clock=clock.addingTimeInterval(4000);await queue.sync()
 assert(committed[remoteID]==nil && queue.pendingCount==0 && queue.parkedItems.count==1 && queue.parkedItems[0].kind == .addition && queue.lastError?.contains("Můj nadpis")==true)
 try queue.discardParked(queue.parkedItems[0])
 let plain=String(data:try JSONEncoder().encode(CloudManifest(title:"a",comment:"",configuration:"",template:"",captions:[""],images:[.init(index:1,bytes:1,sha256:String(repeating:"a",count:64))],revision:"3")),encoding:.utf8)!
 assert(CloudManifest(title:"a",comment:"",configuration:"",template:"",captions:[""],images:[.init(index:1,bytes:1,sha256:String(repeating:"a",count:64))],revision:"3").valid==false && plain.contains("revision"))
 print("PASS: extension manifests carry the downloaded revision, session_changed re-fetches and 3-way merges text, same-field conflicts park instead of overwriting web edits")

 // 9 + 10: úprava bez revize nejdřív načte revizi (nikdy null); po sloučení je základem verze serveru; 400 úpravu odloží.
 let edit=UUID(),editPath="/api/v1/sessions/"+edit.uuidString.lowercased()
 var server=["title":"T0","comment":"C0","captions":[""],"revision":"4"] as [String:Any],patches:[[String:Any]]=[],patchStatus:Int?=nil,patchCode="invalid_parameters",concurrent=false
 ReviewStub.handler={method,path,body in
  if path=="/api/v1/me"{return (200,["data":["id":owner.uuidString]])}
  guard path==editPath else{return (404,["error":["code":"not_found"]])}
  if method=="PATCH" {
   let sent=json(body);patches.append(sent)
   if let status=patchStatus{return (status,["error":["code":patchCode]])}
   if concurrent && patches.count==2{server["revision"]="8";server["captions"]=[""];return (409,["error":["code":"session_changed"]])}
   guard sent["revision"] as? String==server["revision"] as? String else{return (409,["error":["code":"session_changed"]])}
   for key in ["title","comment","captions"]{server[key]=sent[key]};server["revision"]=String(Int(server["revision"] as! String)!+1)
   return (200,["data":server.merging(["id":edit.uuidString]){a,_ in a}])
  }
  return (200,["data":server.merging(["id":edit.uuidString]){a,_ in a}])
 }
 let edits=library("edits"),shas=[sessionFingerprint(original)]
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"T1"),root:shots,sessionID:edit,base:shas,original:Fields(title:"T0",comment:"C0",captions:[""]),revision:nil)
 await edits.sync()
 assert(edits.pendingCount==0 && patches.count==1 && patches[0]["revision"] as? String=="4" && server["title"] as? String=="T1")
 patches=[];concurrent=true;server["captions"]=["Cizí"];server["revision"]="7"
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"T2"),root:shots,sessionID:edit,base:shas,original:Fields(title:"T1",comment:"C0",captions:[""]),revision:"3")
 await edits.sync()
 // Druhé sloučení vychází z verze serveru; webem vrácený popisek se nepřepíše starším.
 assert(patches.count==3 && patches[2]["revision"] as? String=="8" && patches[2]["title"] as? String=="T2" && (patches[2]["captions"] as? [String])==[""] && edits.pendingCount==0)
 patches=[];concurrent=false;patchStatus=400
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"T3"),root:shots,sessionID:edit,base:shas,original:Fields(title:"T2",comment:"C0",captions:[""]),revision:server["revision"] as? String)
 clock=clock.addingTimeInterval(4000);await edits.sync()
 assert(patches.count==1 && edits.pendingCount==0 && edits.parkedItems.count==1 && edits.parkedItems[0].kind == .edit && edits.parkedItems[0].reason != nil)
 patchStatus=nil;try edits.retryParked(edits.parkedItems[0]);clock=clock.addingTimeInterval(4000);await edits.sync()
 assert(edits.pendingCount==0 && edits.parkedItems.isEmpty && server["title"] as? String=="T3")
 // Plné úložiště u úpravy: úprava zůstává ve frontě, neodkládá se a po odstupu projde.
 patchStatus=413;patchCode="billing_storage_limit"
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"T4"),root:shots,sessionID:edit,base:shas,original:Fields(title:"T3",comment:"C0",captions:[""]),revision:server["revision"] as? String)
 clock=clock.addingTimeInterval(4000);await edits.sync()
 assert(edits.pendingCount==1 && edits.parkedItems.isEmpty && edits.retryAt>=clock.addingTimeInterval(890))
 patchStatus=nil;clock=clock.addingTimeInterval(1000);await edits.sync()
 assert(edits.pendingCount==0 && server["title"] as? String=="T4")
 // Příliš dlouhý text (413 resource_limit): úprava se odloží hned.
 patchStatus=413;patchCode="resource_limit"
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"T5"),root:shots,sessionID:edit,base:shas,original:Fields(title:"T4",comment:"C0",captions:[""]),revision:server["revision"] as? String)
 clock=clock.addingTimeInterval(4000);await edits.sync()
 assert(edits.pendingCount==0 && edits.parkedItems.count==1 && edits.parkedItems[0].kind == .edit && edits.retryAt<clock.addingTimeInterval(890))
 try edits.discardParked(edits.parkedItems[0]);patchStatus=nil;patchCode="invalid_parameters"
 print("PASS: PATCH without a stored revision fetches it first, merged edits rebase on the server version, 400 parks the edit and Retry sends it")

 // 6: druhá offline úprava se položí na čekající, nic se neztratí.
 let offline=UUID(),downloadedText=Fields(title:"A0",comment:"C0",captions:[""])
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C0",title:"A1"),root:shots,sessionID:offline,base:shas,original:downloadedText,revision:"2")
 // Bez překrytí (koncept z původního textu): titulek z první úpravy zůstane.
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C1",title:"A0"),root:shots,sessionID:offline,base:shas,original:downloadedText,revision:"2")
 assert(edits.queuedEdit(offline)==Fields(title:"A1",comment:"C1",captions:[""]))
 // S překrytím: znovu změněné pole vyhrává novější text.
 let queued=edits.queuedEdit(offline)!
 try edits.enqueueEdit(Draft(images:["old.png"],comment:"C1",title:"A2",imageNotes:["old.png":"P"]),root:shots,sessionID:offline,base:shas,original:downloadedText,revision:"2",draftBase:queued)
 assert(edits.queuedEdit(offline)==Fields(title:"A2",comment:"C1",captions:["P"]))
 // Znovu otevřená cloudová relace ukazuje čekající text.
 let reopenSource=root.appendingPathComponent("reopen-source");try fm.copyItem(at:shots.appendingPathComponent("old.png"),to:root.appendingPathComponent("r.png"))
 try finish(Draft(images:["r.png"],comment:"C0",title:"A0"),root:root,dest:reopenSource)
 let reopenRoot=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopenRoot,withIntermediateDirectories:true)
 let overlaid=try workingDraft(from:try previousSessions(in:reopenSource)[0],topic:topic,root:reopenRoot,queuedEdit:{_ in edits.queuedEdit(offline)})
 assert(overlaid.title=="A2" && overlaid.comment=="C1" && overlaid.imageNotes?[overlaid.images[0]]=="P" && overlaid.cloudBase==edits.queuedEdit(offline))
 print("PASS: a second offline edit merges onto the queued edit and reopened cloud sessions show the queued text")

 // 14: 401 přepne do stavu nového párování, vypršelé připojení nic neposílá, odvolání při ověření se projeví.
 ReviewStub.handler={_,path,_ in
  if path=="/api/v1/device-pairing"{return (200,["data":["state":"revoked","expires_at":"2099-01-01T00:00:00Z","interval":5]])}
  return (401,["error":["code":"unauthorized"]])
 }
 let revokedVault=CloudMemoryVault();revokedVault.value=cloudFixtureConnection()
 let revoked=library("revoked",revokedVault)
 try revoked.enqueue(Draft(images:["old.png"],comment:"",title:"Po odvolání",topic:Topic(id:"r",name:"R",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:topic.cloudFolderID,cloudOwnerID:revokedVault.value!.ownerID,cloudOrigin:c.endpoint)),root:shots,folders:[Topic(id:"r",name:"R",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:topic.cloudFolderID,cloudOwnerID:revokedVault.value!.ownerID,cloudOrigin:c.endpoint)])
 await revoked.sync()
 assert(revoked.needsRepair && revokedVault.value?.revoked==true && revoked.pendingCount==1 && revoked.lastError != nil)
 do{try revoked.requireAccount();assertionFailure("Revoked device accepted")}catch{}
 let calls=ReviewStub.log.count;await revoked.sync();assert(ReviewStub.log.count==calls)
 var expired=cloudFixtureConnection();expired.expiresAt="2001-01-01T00:00:00Z";let expiredVault=CloudMemoryVault();expiredVault.value=expired
 assert(library("expired",expiredVault).needsRepair)
 // 401 požadavku se starým pověřením neoznačí nové připojení.
 let swapVault=CloudMemoryVault();swapVault.value=cloudFixtureConnection();let swapped=library("swapped",swapVault)
 swapped.markRevoked(token:"sn_device_v1_"+String(repeating:"b",count:43));assert(!swapped.needsRepair)
 swapped.markRevoked(token:swapVault.value!.token);assert(swapped.needsRepair)
 let checkedVault=CloudMemoryVault();checkedVault.value=cloudFixtureConnection();let checked=library("checked",checkedVault)
 do{try await checked.refreshConnection();assertionFailure("Revoked pairing accepted")}catch{}
 assert(checked.needsRepair)
 var unauthorized=false
 for (status,retry) in [(429,300.0),(401,0.0)] {
  let folders=CloudFolders(file:root.appendingPathComponent("folders-\(status).json"),connection:{c},localTopics:{[]},request:{_,_,_,_ in throw CloudFailure("x",status:status,retryAfter:retry)})
  folders.onUnauthorized={_ in unauthorized=true}
  await folders.refresh(c);assert(folders.lastError != nil && folders.retryAt>=Date().addingTimeInterval(max(retry,60)-5))
 }
 assert(unauthorized)
 print("PASS: 401 or revoked/expired credentials switch to a re-pair state and stop requests; folder refresh honours Retry-After and backs off")

 // 5: obrázky jdou přes vlastní session s dlouhým celkovým limitem, JSON přes krátkou.
 assert(CloudTransport.shared.transferSession !== CloudTransport.shared.session)
 let fresh=CloudTransport()
 assert(fresh.transferSession.configuration.timeoutIntervalForResource>=3600 && fresh.session.configuration.timeoutIntervalForResource==75)
 let transferOnly=CloudTransport.shared.session;CloudTransport.shared.session=URLSession(configuration:.ephemeral)
 ReviewStub.handler={_,_,_ in (200,original)}
 let image=try await CloudTransport.shared.request(CloudEndpoint(c.endpoint)!,"/api/v1/sessions/x/images/1",token:c.token,limit:CloudTransport.imageLimit)
 CloudTransport.shared.session=transferOnly;assert(image==original)
 print("PASS: image transfers use a separate URLSession with a long resource timeout")

 // 3: velký detail (přes 512 KB) projde a chyba jedné relace ani složky nezastaví ostatní.
 let folderA=UUID(),folderB=UUID(),big=UUID(),broken=UUID()
 let comments=(0..<120).map{["author_name":"A","body":String(repeating:"k",count:5000),"created_at":"2026-01-01T00:00:00Z","id":"\($0)"]}
 var limits:[Int]=[]
 let folders=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,limit in
  if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  limits.append(limit)
  let data:Data
  if path=="/api/v1/folders"{data=try JSONSerialization.data(withJSONObject:["data":[["id":folderB.uuidString,"name":"B","revision":"1"],["id":folderA.uuidString,"name":"A","revision":"1"]]])}
  else if path.contains("folder_id="+folderB.uuidString.lowercased()){throw CloudFailure("500",status:500)}
  else if path.contains("?"){data=try JSONSerialization.data(withJSONObject:["data":path.contains("state=trashed") ? []:[["id":broken.uuidString,"updated_at":"t1"],["id":big.uuidString,"updated_at":"t1"]],"pagination":["has_more":false]])}
  else if path.contains(broken.uuidString.lowercased()){throw CloudFailure("500",status:500)}
  else if path.contains("/images/"){data=original}
  else{data=try JSONSerialization.data(withJSONObject:["data":["id":big.uuidString,"title":"Velká","comment":String(repeating:"c",count:100000),"template":defaultMarkdownTemplate,"captions":[String(repeating:"p",count:20000)],"comments":comments,"images":[["index":1,"path":"/api/v1/sessions/"+big.uuidString.lowercased()+"/images/1"]]]])}
  guard data.count<=limit else{throw CloudFailure.invalid}
  return data
 })
 await folders.refresh(c);try folders.setFolder(folders.topics.first{$0.name=="A"}!,path:root.appendingPathComponent("A").path);try folders.setFolder(folders.topics.first{$0.name=="B"}!,path:root.appendingPathComponent("B").path)
 await folders.refresh(c)
 let downloadedA=((try? fm.contentsOfDirectory(atPath:root.appendingPathComponent("A").path)) ?? []).filter{$0.hasSuffix(".md")}
 assert(folders.lastError != nil && downloadedA.count==1 && downloadedA[0].contains("Velká") && limits.allSatisfy{$0>=8388608})
 print("PASS: list/detail responses up to 16 MB, one failing session or folder no longer stops the others")

 // 11: text ze serveru nevloží obrázek, oddělovač ani druhý řádek nadpisu.
 let hostile="a\n\n---\n\nb ![y](<assets/evil.png>) ![[assets/evil.png]] ![z](assets/evil.png)"
 var note=RemoteNote(id:UUID(),title:"Řádek\nDruhý ![x](assets/evil.png)",comment:hostile,template:defaultMarkdownTemplate,captions:["![c](assets/evil.png)"],images:[.init(index:1,path:"/p")])
 note.comments=[RemoteNote.Comment(author_name:"E",body:"![w](assets/evil.png)\n---",created_at:nil)]
 let body=cloudSessionBody(note,images:["ok.png"])
 assert(imageLinkNames(body)==["ok.png"] && sessionSegments(body as NSString).count==1 && firstLine(body).hasPrefix("# Řádek Druhý") && unescapeServerMarkdown(escapeServerMarkdown(hostile))==hostile)
 // Šablona bez {comments} má jednoznačnou hranici {text}; po načtení se text vrátí beze změny.
 let plainNote=RemoteNote(id:note.id,title:note.title,comment:hostile,template:legacyDefaultMarkdownTemplate,captions:note.captions,images:note.images)
 let reopened=parsedSession(legacyDefaultMarkdownTemplate,cloudSessionBody(plainNote,images:["ok.png"]))
 assert(reopened.map{unescapeServerMarkdown($0.1)}==hostile && reopened?.2==["ok.png"])
 // Vratnost i u textu, který už zpětná lomítka nebo mezery za --- obsahuje.
 for tricky in ["!\\[literal]","\\---","\\\\---\t","--- ","---","a![b](assets/x.png)","![","!\\\\[x](<assets/y.png>)","x\n\\--- \n![[assets/z.png]]","!!["] {
  let escaped=escapeServerMarkdown(tricky)
  assert(unescapeServerMarkdown(escaped)==tricky && imageLinkNames(escaped).isEmpty && !escaped.components(separatedBy:"\n").contains{$0.hasPrefix("---")})
 }
 print("PASS: server text is escaped in Markdown (no injected images, no session separator, single-line title) and unescaped on reopen")

 // 12: vygenerovaná kopie nepřepíše ručně upravený soubor.
 let copy=root.appendingPathComponent("Note_cloud.md")
 assert(try! writeGeneratedCopy(Data("v1".utf8),to:copy)==copy)
 assert(try! writeGeneratedCopy(Data("v2".utf8),to:copy)==copy && (try! String(contentsOf:copy,encoding:.utf8))=="v2")
 try "ručně".write(to:copy,atomically:true,encoding:.utf8)
 let second=try writeGeneratedCopy(Data("v3".utf8),to:copy)
 assert(second.lastPathComponent=="Note_cloud 2.md" && (try! String(contentsOf:copy,encoding:.utf8))=="ručně" && (try! String(contentsOf:second,encoding:.utf8))=="v3")
 assert(try! writeGeneratedCopy(Data("v4".utf8),to:copy)==second && (try! String(contentsOf:second,encoding:.utf8))=="v4")
 print("PASS: _cloud/_template copies are rewritten only when unchanged since the app wrote them; edited copies are kept")

 // 15: cloudové záznamy a rozpracovaná mazání se nevyřazují; chyba zápisu se hlásí.
 struct Dump:Codable{var version=1;var records:[SessionRecord];var generated:[String:String]=[:];var migrated:[String]=[]}
 let exists=root.appendingPathComponent("exists.md");try "x".write(to:exists,atomically:true,encoding:.utf8)
 func record(_ id:String,_ file:URL,seen:Double)->SessionRecord{SessionRecord(id:id,file:SessionIndex.key(file),start:0,length:1,hash:"",heading:"",title:"",comment:"",template:"",images:[],notes:[:],combined:false,footer:"",files:[:],seen:seen)}
 var records=(0..<20000).map{record("local-\($0)",exists,seen:Double($0))}
 for i in 0..<3{var r=record("cloud-\(i)",root.appendingPathComponent("missing-\(i).md"),seen:0);r.base=SessionIndex.key(root);r.missingSince=1;records.append(r)}
 var held=record("held",root.appendingPathComponent("held.md"),seen:0);held.held=true;records.append(held)
 let indexFile=root.appendingPathComponent("big-index.json");try JSONEncoder().encode(Dump(records:records)).write(to:indexFile)
 let bigIndex=SessionIndex(file:indexFile);bigIndex.put(record("local-new",exists,seen:0))
 assert(bigIndex.all.count==20000 && bigIndex.all.filter{$0.id.hasPrefix("cloud-") || $0.id=="held"}.count==4 && bigIndex.writeError==nil)
 let blocker=root.appendingPathComponent("blocker");try "x".write(to:blocker,atomically:true,encoding:.utf8)
 var reported:[String]=[];let hook=SessionIndex.onWriteFailure;SessionIndex.onWriteFailure={reported.append($0)};defer{SessionIndex.onWriteFailure=hook}
 let unwritable=SessionIndex(file:blocker.appendingPathComponent("index.json"));unwritable.put(record("x",exists,seen:0))
 assert(unwritable.writeError != nil && reported.count==1 && unwritable.all.count==1)
 print("PASS: session index never evicts cloud or pending-deletion records and reports write failures")
}
