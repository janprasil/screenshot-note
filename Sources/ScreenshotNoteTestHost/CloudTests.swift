import AppKit
@testable import ScreenshotNoteKit
import CryptoKit

func cloudUnitTests() throws {
 try cloudFolderUnitTests()
 try sessionIndexTests()
 assert(CloudEndpoint("https://screenshotnote.com") != nil)
 for url in ["https://user:secret@example.test","https://example.test/a","https://example.test/?token=secret","http://remote.test","file:///tmp","https://example.test/#secret"] { assert(CloudEndpoint(url) == nil) }
 assert(CloudEndpoint("http://127.0.0.1:4567") != nil)
 assert(CloudEndpoint("http://[::1]:5173") != nil)
 assert(CloudKeychain(endpoint:CloudEndpoint("https://screenshotnote.com")!).service == "cz.janprasil.screenshotnote.device.v1")
 assert(CloudKeychain(endpoint:CloudEndpoint("http://localhost:5173")!).service != CloudKeychain(endpoint:CloudEndpoint("https://screenshotnote.com")!).service)
 assert(!CloudConnection.validToken("legacy.jwt.token"));assert(!CloudConnection.validToken("sn_device_v1_bad"))
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection()
 assert(CloudLibrary.browserURL(vault.value!)?.query == nil)
 let mismatched = CloudLibrary(vault:vault,endpoint:CloudEndpoint("https://screenshotnote.com")!)
 assert(mismatched.connection == nil && vault.value != nil)
 let root=fm.temporaryDirectory.appendingPathComponent("sn-cloud-unit-" + UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
 try cloudFixturePNG().write(to:root.appendingPathComponent("shot.png"))
 let normalized=try cloudImage(root.appendingPathComponent("shot.png"))
 assert(normalized[24] == 8 && [2,6].contains(normalized[25]) && normalized[28] == 0)
 let lib=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:CloudEndpoint("https://fixture.invalid")!)
 // Nová cloudová relace bez cloudové složky se do fronty nedostane.
 do{try lib.enqueue(Draft(images:["shot.png"],comment:"",title:"Bez složky"),root:root);assertionFailure("Folderless upload queued")}catch let failure as CloudFailure{assert(failure.code=="folder_required" && lib.pendingCount==0)}
 let fixture=vault.value!,cloudTopic=Topic(id:"cloud",name:"Cloud",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:UUID(),cloudOwnerID:fixture.ownerID,cloudOrigin:fixture.endpoint)
 let draft=Draft(images:["shot.png"],comment:"Offline note",title:"Frozen title",topic:cloudTopic)
 try lib.enqueue(draft,root:root,folders:[cloudTopic]);assert(lib.pendingCount == 1)
 let other=CloudMemoryVault();other.value=cloudFixtureConnection()
 assert(CloudLibrary(queue:root.appendingPathComponent("queue"),vault:other,endpoint:CloudEndpoint("https://fixture.invalid")!).pendingCount == 0)
 assert(CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:CloudEndpoint("https://fixture.invalid")!).pendingCount == 1)
 let old=root.appendingPathComponent("queue/legacy",isDirectory:true);try fm.createDirectory(at:old,withIntermediateDirectories:true)
 try Data("{\"project\":\"legacy\",\"session\":{}}".utf8).write(to:old.appendingPathComponent("job.json"))
 assert(lib.legacyPendingCount == 1 && lib.pendingCount == 1)
 let pending=CloudMemoryVault();pending.value=cloudFixtureConnection(owner:nil)
 do { try CloudLibrary(queue:root,vault:pending,endpoint:CloudEndpoint("https://fixture.invalid")!).enqueue(draft,root:root);assertionFailure("Pending credential admitted upload") } catch {}
 let jobDir = try fm.contentsOfDirectory(at:root.appendingPathComponent("queue"),includingPropertiesForKeys:nil).first { $0.lastPathComponent != "legacy" }!
 let jobFile = jobDir.appendingPathComponent("job.json"), originalJob = try Data(contentsOf:jobFile)
 var corrupt = try JSONSerialization.jsonObject(with:originalJob) as! [String:Any]
 var badManifest = corrupt["manifest"] as! [String:Any];badManifest["images"] = [];corrupt["manifest"] = badManifest
 try JSONSerialization.data(withJSONObject:corrupt).write(to:jobFile,options:.atomic)
 assert(lib.pendingCount == 0 && lib.legacyPendingCount == 2)
 try originalJob.write(to:jobFile,options:.atomic);assert(lib.pendingCount == 1)
 // Doplnění relace posílá původní bajty beze změny a nové snímky za ně.
 let extRoot=root.appendingPathComponent("extension");try fm.createDirectory(at:extRoot,withIntermediateDirectories:true)
 let original=cloudFixturePNG(0.6);try original.write(to:extRoot.appendingPathComponent("old.png"));try cloudFixturePNG(0.9).write(to:extRoot.appendingPathComponent("new.png"))
 let extID=UUID(),extQueue=CloudLibrary(queue:root.appendingPathComponent("ext-queue"),vault:vault,endpoint:CloudEndpoint("https://fixture.invalid")!)
 let extDraft=Draft(images:["old.png","new.png"],comment:"Doplněno",title:"Relace",imageNotes:["new.png":"Nový"])
 do{try extQueue.enqueue(Draft(images:["new.png","old.png"],comment:"",title:"X"),root:extRoot,sessionID:extID,base:[sessionFingerprint(original)]);assertionFailure("Reordered base accepted")}catch{}
 do{try extQueue.enqueue(Draft(images:["old.png"],comment:"",title:"X"),root:extRoot,sessionID:extID,base:[sessionFingerprint(original)]);assertionFailure("Extension without new image accepted")}catch{}
 try extQueue.enqueue(extDraft,root:extRoot,sessionID:extID,base:[sessionFingerprint(original)])
 assert(extQueue.pendingCount==1 && extQueue.pendingExtension(extID))
 let extJob=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("ext-queue/"+extID.uuidString.lowercased()+"/job.json"))) as! [String:Any]
 let extManifest=extJob["manifest"] as! [String:Any],extImages=extManifest["images"] as! [[String:Any]]
 assert(extManifest["base_images"] as? Int==1 && extImages.count==2 && extImages[0]["sha256"] as? String==sessionFingerprint(original))
 assert(try! Data(contentsOf:root.appendingPathComponent("ext-queue/"+extID.uuidString.lowercased()+"/1.png"))==original)
 do{try extQueue.enqueue(Draft(images:["old.png","new.png","new.png"],comment:"jiné",title:"Relace"),root:extRoot,sessionID:extID,base:[sessionFingerprint(original)]);assertionFailure("Second pending extension accepted")}catch{}
 let plain=String(data:try JSONEncoder().encode(CloudManifest(title:"a",comment:"",configuration:"",template:"",captions:[""],images:[.init(index:1,bytes:1,sha256:String(repeating:"a",count:64))])),encoding:.utf8)!
 assert(!plain.contains("base_images") && !plain.contains("folder_id"))
 print("PASS: session extension keeps original PNG bytes, requires new images in order, base_images manifest and old-job compatibility")
 vault.fail=true;do {try lib.forgetConnection();assertionFailure("Failed Keychain mutation changed state")} catch {}
 assert(lib.connection != nil && lib.pendingCount == 1)
 vault.fail=false;try lib.forgetConnection();assert(lib.connection == nil)
 print("PASS: native endpoint/token validation, RGB8 PNG normalization, persistent owner-scoped outbox, legacy preservation and Keychain failure atomicity")
}

func cloudFolderUnitTests()throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-folders-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let target=root.appendingPathComponent("notes"),alias=root.appendingPathComponent("alias")
 try fm.createDirectory(at:target,withIntermediateDirectories:true);try fm.createSymbolicLink(at:alias,withDestinationURL:target)
 let first=Topic(id:"a",name:"Local",detail:"",folder:target.path,combined:false,combinedFile:"Note.md")
 var second=first;second.id="b";second.name="Cloud";second.uploadToCloud=true
 for path in [target.path,target.path+"/../notes/",alias.path] {
  second.folder=path
  do{try Topics.validateDestinations([first,second]);assertionFailure("Duplicate folder accepted")}catch{}
 }
 let missingAlias=try Topics.checkedDestination(alias.appendingPathComponent("new").path),missingTarget=try Topics.checkedDestination(target.appendingPathComponent("new").path)
 assert(Topics.sameDestination(missingAlias,missingTarget))
 second.folder=target.appendingPathComponent("nested").path;try Topics.validateDestinations([first,second])
 second.cloudOnly=true;second.folder="";try Topics.validateDestinations([first,second])
 let projected=Topics.localProjection(second);assert(!projected.savesToCloud && projected.savesLocally && second.cloudOnly==true)
 let broken=root.appendingPathComponent("broken");try fm.createSymbolicLink(at:broken,withDestinationURL:root.appendingPathComponent("absent"))
 do{_ = try Topics.checkedDestination(broken.path);assertionFailure("Broken alias accepted")}catch{}
 do{_ = try Topics.checkedDestination("relative/path");assertionFailure("Relative folder accepted")}catch{}
 let c=cloudFixtureConnection(),owner=c.ownerID!,origin=c.endpoint
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[first]});store.activate(c)
 let a=CloudFolderRecord(id:UUID(),name:"Research",owner:owner,origin:origin)
 let b=CloudFolderRecord(id:UUID(),name:"Work",owner:owner,origin:origin)
 try store.accept([a,b]);assert(store.topics.count==2 && store.topics.allSatisfy{!$0.savesLocally && $0.savesToCloud})
 do{try store.setFolder(store.topics[0],path:alias.path);assertionFailure("Local/cloud collision accepted")}catch{}
 let download=root.appendingPathComponent("download").path
 try store.setFolder(store.topics[0],path:download)
 do{try store.setFolder(store.topics[1],path:download);assertionFailure("Cloud/cloud collision accepted")}catch{}
 var renamed=a;renamed.name="Renamed";try store.accept([renamed,b])
 assert(store.topics[0].folder==download && store.topics[0].name=="Renamed")
 let restored=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[first]});restored.activate(c);assert(restored.topics==store.topics)
 let other=cloudFixtureConnection();store.activate(other);assert(store.topics.isEmpty)
 let foreign=CloudFolderRecord(id:UUID(),name:"Other account",owner:other.ownerID!,origin:other.endpoint)
 try store.accept([foreign]);do{try store.setFolder(store.topics[0],path:download);assertionFailure("Inactive account collision accepted")}catch{}
 store.activate(nil);assert(store.topics.isEmpty && store.allTopics.count==3)
 print("PASS: local/cloud destination isolation, symlinks, missing descendants, stable cloud IDs, rename persistence and account-scoped catalog")
}

@MainActor func cloudFolderSyncTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-folder-sync-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let c=cloudFixtureConnection(),folder=UUID(),note=UUID(),png=cloudFixturePNG()
 for mode in ["disconnect","mapping"] {
  var connection:CloudConnection?=c;var store:CloudFolders!
  var invalidate=false
  store=CloudFolders(file:root.appendingPathComponent(mode+".json"),connection:{connection},localTopics:{[]},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
   if path.hasSuffix("/images/1") {
    await Task.yield()
    if invalidate {if mode=="disconnect"{connection=nil}else{try store.setFolder(store.topics[0],path:root.appendingPathComponent("changed").path)}}
    return png
   }
   let data:Any
   if path=="/api/v1/folders"{data=["data":[["id":folder.uuidString,"name":"Cloud","revision":"1"]]]}
   else if path.contains("?"){data=["data":[["id":note.uuidString,"deleting":false]],"pagination":["has_more":false]]}
   else{data=["data":["id":note.uuidString,"title":"Remote note","comment":"Text","template":defaultMarkdownTemplate,"captions":["Caption"],"images":[["index":1,"path":"/api/v1/sessions/"+note.uuidString.lowercased()+"/images/1"]]]]}
   return try JSONSerialization.data(withJSONObject:data)
  })
  await store.refresh(c);assert(store.topics.count==1)
  let target=root.appendingPathComponent(mode)
  try store.setFolder(store.topics[0],path:target.path);invalidate=true
  await store.refresh(c)
  assert(store.lastError != nil)
  let directories=(try? fm.contentsOfDirectory(atPath:target.path)) ?? []
  assert(directories.isEmpty)
 }
 print("PASS: asynchronous download aborts after disconnect or a changed local mapping before publishing files")

 let env=ProcessInfo.processInfo.environment
 guard let raw=env["SCREENSHOT_NOTE_TEST_URL"],let endpoint=CloudEndpoint(raw),["127.0.0.1","localhost"].contains(endpoint.url.host ?? ""),
       let token=env["SCREENSHOT_NOTE_TEST_TOKEN"],CloudConnection.validToken(token),let owner=env["SCREENSHOT_NOTE_TEST_OWNER"].flatMap(UUID.init(uuidString:)) else{return}
 let id=UUID()
 let live=CloudConnection(endpoint:raw,token:token,id:id,comparisonCode:"AABBCCDD",verificationURI:raw+"/pair-device/"+id.uuidString.lowercased(),expiresAt:"2099-01-01T00:00:00Z",ownerID:owner)
 let store=CloudFolders(file:root.appendingPathComponent("live.json"),connection:{live},localTopics:{[]})
 await store.refresh(live);assert(store.lastError==nil && !store.topics.isEmpty)
 let target=root.appendingPathComponent("downloaded")
 try store.setFolder(store.topics[0],path:target.path)
 await store.refresh(live);assert(store.lastError==nil)
 // Plochá struktura: „YYYY-MM-DD Název.md“ v kořeni, obrázky ve společném assets/.
 func entries()->[String]{((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()}
 let notes=entries().filter{$0.hasSuffix(".md")};assert(notes.count==1 && entries().contains("assets"))
 let markdown=target.appendingPathComponent(notes[0]),stem=(notes[0] as NSString).deletingPathExtension,image=target.appendingPathComponent("assets/"+stem+"-1.png")
 assert(!String(decoding:(try? Data(contentsOf:markdown)) ?? Data(),as:UTF8.self).contains("<!--"))
 assert(fm.fileExists(atPath:image.path));let original=try! Data(contentsOf:markdown);assert(String(decoding:original,as:UTF8.self).contains("Remote cloud fixture"))
 await store.refresh(live);assert(store.lastError==nil && entries().count==2)
 let edited=original+Data("\nLocal edit".utf8);try edited.write(to:markdown)
 await store.refresh(live);assert((try? Data(contentsOf:markdown))==edited)
 // Chybějící obrázek upravené relace se doplní a cloudová verze jde vedle jako _cloud.md.
 try! fm.removeItem(at:image);await store.refresh(live);assert(store.lastError==nil)
 assert((try? Data(contentsOf:markdown))==edited && fm.fileExists(atPath:image.path) && entries()==[notes[0],stem+"_cloud.md","assets"].sorted())
 await store.refresh(live);assert(entries()==[notes[0],stem+"_cloud.md","assets"].sorted())
 print("PASS: native client downloads real Next cloud folder metadata/PNG/Markdown, deduplicates refreshes and preserves edited files")
}

@MainActor func cloudIntegrationTest() async throws {
 guard let raw=ProcessInfo.processInfo.environment["SCREENSHOT_NOTE_TEST_URL"],let endpoint=CloudEndpoint(raw),
       ["localhost","127.0.0.1"].contains(endpoint.url.host ?? "") else { throw CloudFailure.invalid }
 let root=fm.temporaryDirectory.appendingPathComponent("sn-native-rest-" + UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
 let vault=CloudMemoryVault();var clock=Date()
 let failed=CloudLibrary(queue:root.appendingPathComponent("failed"),vault:vault,endpoint:endpoint,now:{clock});vault.fail=true
 do {try await failed.startPairing(endpoint:endpoint,name:"Failed vault");assertionFailure("Keychain failure ignored")} catch {}
 assert(failed.connection == nil && vault.value == nil);vault.fail=false
 let lib=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:endpoint,now:{clock})
 try await lib.startPairing(endpoint:endpoint,name:"Native fixture");assert(vault.value?.ownerID == nil && lib.connection != nil)
 let resumed=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:endpoint,now:{clock})
 try await resumed.refreshConnection();assert(resumed.connection?.ownerID != nil)
 let original=resumed.connection!
 let png=cloudFixturePNG();try png.write(to:root.appendingPathComponent("shot.png"))
 // Nová cloudová relace musí mít cloudovou složku.
 let folder=UUID(),cloudTopic=Topic(id:"cloud",name:"Cloud",detail:"",folder:"",combined:false,combinedFile:"N.md",cloudFolderID:folder,cloudOwnerID:original.ownerID,cloudOrigin:original.endpoint)
 let draft=Draft(images:["shot.png"],comment:"Native **REST** fixture",title:"Native fixture",topic:cloudTopic,imageNotes:["shot.png":"Caption"])
 let shared=try resumed.enqueue(draft,root:root,folders:[cloudTopic]);assert(resumed.pendingCount == 1)
 for _ in 0..<5 { await resumed.sync();if resumed.pendingCount == 0 { break };clock=clock.addingTimeInterval(120) }
 guard resumed.pendingCount == 0 else { throw CloudFailure.invalid }
 // Kopírovat odkaz: commitnutá relace, bearer token, stejná URL i při opakování.
 assert(resumed.isCommitted(shared,folder:folder))
 let sharer=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:endpoint,now:{clock})
 func target(_ id:UUID)->PreviousSessionTarget{PreviousSessionTarget(path:"/fixture.md",start:0,length:0,original:"",fingerprint:"",session:id.uuidString)}
 let index=SessionIndex(file:root.appendingPathComponent("index.json")),none:(PreviousSessionTarget,Topic)->(UUID,[String])? = {_,_ in nil}
 let sharedDraft=Draft(images:[],comment:"",topic:cloudTopic,previous:target(shared))
 assert(sharer.shareableSessionID(sharedDraft,index:index,serverImages:none)==shared)
 assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:cloudTopic),index:index,serverImages:none)==nil)
 let downloaded=UUID();assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:cloudTopic,previous:target(downloaded)),index:index,serverImages:{_,_ in (downloaded,[])})==downloaded)
 assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:cloudTopic,previous:target(UUID())),index:index,serverImages:none)==nil)
 var foreignOwner=cloudTopic;foreignOwner.cloudOwnerID=UUID();assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:foreignOwner,previous:target(shared)),index:index,serverImages:none)==nil)
 var foreignOrigin=cloudTopic;foreignOrigin.cloudOrigin="https://other.test";assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:foreignOrigin,previous:target(shared)),index:index,serverImages:none)==nil)
 var localTopic=cloudTopic;localTopic.cloudFolderID=nil;assert(sharer.shareableSessionID(Draft(images:[],comment:"",topic:localTopic,previous:target(shared)),index:index,serverImages:none)==nil)
 // Relace v koši podle indexu se nesdílí, i když existuje účtenka o nahrání.
 index.put(SessionRecord(id:shared.uuidString.lowercased(),file:"",start:0,length:0,hash:"",heading:"",title:"",comment:"",template:"",images:[],notes:[:],combined:false,footer:"",files:[:],seen:0,folder:folder.uuidString.lowercased(),trashed:true))
 assert(sharer.isCommitted(shared,folder:folder) && sharer.shareableSessionID(sharedDraft,index:index,serverImages:none)==nil)
 let link=try await sharer.shareLink(shared),again=try await sharer.shareLink(shared)
 assert(link==again && link.absoluteString.hasPrefix(raw+"/s/sn_share_v1_"))
 let board=NSPasteboard(name:NSPasteboard.Name("sn-share-test-"+UUID().uuidString));defer{board.releaseGlobally()}
 copyShareLink(link,to:board);assert(board.string(forType:.string)==link.absoluteString)
 func shareFailure(_ id:String)async->CloudFailure?{do{_ = try await sharer.shareLink(UUID(uuidString:id)!);return nil}catch{return error as? CloudFailure}}
 let missing=await shareFailure(UUID().uuidString);assert(missing?.status==404)
 let trashed=await shareFailure("00000000-0000-4000-8000-000000000409");assert(trashed?.status==409 && trashed?.code=="session_trashed")
 let teamLink=await shareFailure("00000000-0000-4000-8000-000000000410");assert(teamLink?.status==409 && teamLink?.code=="link_exists" && teamLink?.message==L("Relace už má týmový odkaz. Zkopíruj ho nebo ho změň na webu."))
 let forbidden=await shareFailure("00000000-0000-4000-8000-000000000403");assert(forbidden?.status==403)
 let full=await shareFailure("00000000-0000-4000-8000-000000000413");assert(full?.status==413 && full?.message==L("Je dosažen limit sdílených odkazů. Odvolej nepotřebný odkaz na webu a zkus to znovu."))
 let down=await shareFailure("00000000-0000-4000-8000-000000000503");assert(down?.status==503 && down?.message==L("Sdílení je teď dočasně nedostupné. Zkus to znovu za chvíli."))
 let bad=await shareFailure("00000000-0000-4000-8000-000000000401");assert(bad?.status==400 && bad?.message==LF("Odkaz se nepodařilo vytvořit (HTTP %ld).",400))
 let foreign=await shareFailure("00000000-0000-4000-8000-000000000400");assert(foreign != nil && foreign?.status==0)
 let throttled=await shareFailure("00000000-0000-4000-8000-000000000429");assert(throttled?.status==429 && sharer.shareRetryAt >= clock.addingTimeInterval(60))
 // Během Retry-After klient na server vůbec nejde.
 let early=await shareFailure(shared.uuidString);assert(early?.status==429)
 clock=clock.addingTimeInterval(61);let later=try await sharer.shareLink(shared);assert(later==link)
 // 429 bez Retry-After čeká 30 s; po odpojení účtu se zámek nepoužije.
 let bare=await shareFailure("00000000-0000-4000-8000-000000000430");assert(bare?.status==429 && abs(sharer.shareRetryAt.timeIntervalSince(clock)-30)<1)
 try sharer.forgetConnection();assert(sharer.shareRetryAt == .distantPast);try vault.save(original)
 // Týmová složka proti fixture: /me libraries, owner pole, library_id, author, ztráta a návrat týmu.
 // Vlastní hodiny: sdílené hodiny testu hlídají platnost párování fixture.
 var teamClock=clock,recycled:[URL]=[]
 let teamLib=CloudLibrary(queue:root.appendingPathComponent("team-queue"),vault:vault,endpoint:endpoint,now:{teamClock},recycle:{recycled.append($0);try fm.removeItem(at:$0)})
 let teamFolders=CloudFolders(file:root.appendingPathComponent("team-folders.json"),connection:{teamLib.connection},localTopics:{[]},pending:{teamLib.hasPending($0)},storedLocal:{[]},saveLocal:{_ in})
 teamLib.folderInfo={teamFolders.folderInfo($0)}
 func membership(_ value:Bool,leaveAfterFolders:Bool=false)async throws{_ = try await CloudTransport.shared.request(endpoint,"/api/v1/fixture/team",method:"POST",token:original.token,body:JSONSerialization.data(withJSONObject:["member":value,"leave_after_folders":leaveAfterFolders]))}
 await teamFolders.refresh(teamLib.connection);assert(teamFolders.lastError==nil)
 guard let team=teamFolders.topics.first(where:{$0.cloudTeam==true}) else{throw CloudFailure.invalid}
 assert(team.displayName==LF("%@ · %@","Fixture tým","Bugy") && team.cloudRole=="member" && !team.canManageCloudFolder && team.cloudOwnerID != original.ownerID)
 let teamDir=root.appendingPathComponent("team-dir");try teamFolders.setFolder(team,path:teamDir.path);await teamFolders.refresh(teamLib.connection)
 let teamFiles=try fm.contentsOfDirectory(atPath:teamDir.path).filter{$0.hasSuffix(".md")}
 assert(teamFolders.lastError==nil && teamFiles.count==1 && ((try? String(contentsOf:teamDir.appendingPathComponent(teamFiles[0]),encoding:.utf8)) ?? "").contains("Autor: Fixture Bob"))
 // Ztráta členství: složka skrytá, soubory zůstávají; upload skončí jednou 404 a odloží se (Odložené…), bez opakování.
 try await membership(false);await teamFolders.refresh(teamLib.connection)
 assert(teamFolders.lastError==nil && teamFolders.topics.isEmpty && teamFolders.isUnavailable(team) && ((try? fm.contentsOfDirectory(atPath:teamDir.path)) ?? []).filter{$0.hasSuffix(".md")}==teamFiles)
 try teamLib.enqueue(Draft(images:["shot.png"],comment:"Týmová poznámka",title:"Team upload",topic:team),root:root,folders:[team])
 await teamLib.sync();assert(teamLib.pendingCount==0 && teamLib.lastError?.contains("Fixture tým · Bugy")==true)
 assert(teamLib.parkedItems.count==1 && teamLib.parkedItems[0].retryable && teamLib.parkedItems[0].reason?.contains("Fixture tým · Bugy")==true)
 teamClock=teamClock.addingTimeInterval(120);await teamLib.sync();assert(teamLib.pendingCount==0 && teamLib.parkedItems.count==1 && teamLib.lastError==nil)
 // Návrat do týmu: mapování se obnoví a Odložené… → Zkusit znovu úlohu odešle.
 try await membership(true);await teamFolders.refresh(teamLib.connection)
 assert(teamFolders.topics.first{$0.cloudTeam==true}?.folder==teamDir.path && ((try? fm.contentsOfDirectory(atPath:teamDir.path)) ?? []).filter{$0.hasSuffix(".md")}==teamFiles)
 try teamLib.retryParked(teamLib.parkedItems[0]);teamClock=teamClock.addingTimeInterval(120);await teamLib.sync()
 assert(teamLib.pendingCount==0 && teamLib.parkedItems.isEmpty && teamLib.lastError==nil)
 // Souběh: přístup zmizí po katalogu; prázdný seznam a 404 detailu nic nesmažou, /me se ověří znovu a složka se skryje.
 try await membership(true,leaveAfterFolders:true);await teamFolders.refresh(teamLib.connection)
 assert(teamFolders.isUnavailable(team) && ((try? fm.contentsOfDirectory(atPath:teamDir.path)) ?? []).filter{$0.hasSuffix(".md")}==teamFiles)
 // Odloženou úlohu lze výslovně zahodit (Koš v macOS).
 try await membership(false);try teamLib.enqueue(Draft(images:["shot.png"],comment:"Zahodit",title:"Discard",topic:team),root:root,folders:[team])
 teamClock=teamClock.addingTimeInterval(120);await teamLib.sync();assert(teamLib.parkedItems.count==1)
 try teamLib.discardParked(teamLib.parkedItems[0]);assert(recycled.count==1 && teamLib.pendingCount==0 && teamLib.parkedItems.isEmpty)
 try await membership(true)
 print("PASS: team folder over REST: /me libraries, owner fields, library_id listing, {author}, membership loss hides the folder and parks the upload without a retry loop, rejoin restores the mapping")
 let token="sn_share_v1_"+String(repeating:"a",count:43)
 assert(CloudLibrary.shareURL("https://evil.test/s/"+token,endpoint:endpoint)==nil)
 assert(CloudLibrary.shareURL(raw+"/s/short",endpoint:endpoint)==nil && CloudLibrary.shareURL(raw+"/s/"+token+"?x=1",endpoint:endpoint)==nil && CloudLibrary.shareURL(raw+"/s/"+token+"a",endpoint:endpoint)==nil)
 assert(CloudLibrary.shareURL(raw.replacingOccurrences(of:"127.0.0.1",with:"localhost")+"/s/"+token,endpoint:endpoint)==nil)
 let production=CloudEndpoint("https://screenshotnote.com")!
 assert(CloudLibrary.shareURL("https://ScreenshotNote.com:443/s/"+token,endpoint:production) != nil && CloudLibrary.shareURL("http://screenshotnote.com/s/"+token,endpoint:production)==nil)
 assert(CloudLibrary.shareURL("https://screenshotnote.com:8443/s/"+token,endpoint:production)==nil && CloudLibrary.shareURL("https://screenshotnote.com/s/sn_share_v2_"+String(repeating:"a",count:43),endpoint:production)==nil)
 let preserved = try Data(contentsOf:root.appendingPathComponent("shot.png")); assert(preserved == png)
 try resumed.enqueue(draft,root:root,folders:[cloudTopic])
 let drain = Task { @MainActor in await resumed.sync() }
 try await Task.sleep(nanoseconds:100_000_000)
 assert(resumed.syncing)
 try resumed.enqueue(draft,root:root,folders:[cloudTopic]);await resumed.sync();await drain.value
 assert(resumed.pendingCount == 0)
 try resumed.enqueue(draft,root:root,folders:[cloudTopic])
 var wrong=original;wrong.ownerID=UUID();try vault.save(wrong)
 let switched=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:endpoint,now:{clock});assert(switched.pendingCount == 0)
 await switched.sync();assert(switched.lastError != nil)
 try vault.save(original);let restored=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,endpoint:endpoint,now:{clock});assert(restored.pendingCount == 1)
 try restored.forgetConnection();assert(restored.connection == nil)
 let unsafe=CloudLibrary(queue:root.appendingPathComponent("unsafe"),vault:vault,endpoint:endpoint,now:{clock})
 do {try await unsafe.startPairing(endpoint:endpoint,name:"Unsafe URI");assertionFailure("Foreign browser URI accepted")} catch {}
 assert(unsafe.connection == nil && vault.value == nil)
 let cancel=CloudLibrary(queue:root.appendingPathComponent("cancel"),vault:vault,endpoint:endpoint,now:{clock})
 try await cancel.startPairing(endpoint:endpoint,name:"Cancel fixture");try await cancel.cancelPairing()
 assert(cancel.connection == nil && vault.value == nil)
 let limited=CloudLibrary(queue:root.appendingPathComponent("limited"),vault:vault,endpoint:endpoint,now:{clock})
 do {try await limited.startPairing(endpoint:endpoint,name:"Rate fixture");assertionFailure("Rate limit ignored")} catch {}
 assert(limited.retryAt >= clock.addingTimeInterval(60))
 do {try await limited.startPairing(endpoint:endpoint,name:"Rate fixture");assertionFailure("Rate limit retried early")} catch {}
 print("PASS: native REST pairing/vault/restart, owner identity, streamed PNG, lost manifest/image/commit responses, stable upload UUID/digest and account-switch isolation")
 print("PASS: copy link posts public share with bearer token, idempotent URL, pasteboard text, shareable-session gating (owner/origin/index trash), 403/404/409/413/503/400 messages, Retry-After and 30 s default gate reset on disconnect, normalized origin and exact token")
}

@MainActor func folderTransferTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-folder-transfer-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let c=cloudFixtureConnection(),owner=c.ownerID!,vault=CloudMemoryVault();vault.value=c
 let sourceFolder=root.appendingPathComponent("local"),capture=root.appendingPathComponent("capture")
 try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 try cloudFixturePNG().write(to:capture.appendingPathComponent("shot.png"))
 try finish(Draft(images:["shot.png"],comment:"Přenášená poznámka",title:"Přesun"),root:capture,dest:sourceFolder)
 let source=Topic(id:"local-source",name:"Lokální",detail:"",folder:sourceFolder.path,combined:false,combinedFile:"Notes.md")
 let library=CloudLibrary(queue:root.appendingPathComponent("outbox"),vault:vault,endpoint:CloudEndpoint(c.endpoint)!)
 let folders=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[source]});folders.activate(c)
 let a=CloudFolderRecord(id:UUID(),name:"Cíl",owner:owner,origin:c.endpoint),b=CloudFolderRecord(id:UUID(),name:"Jiný",owner:owner,origin:c.endpoint)
 try folders.accept([a,b]);let target=folders.topics[0],other=folders.topics[1]
 let transfers=FolderTransfers(directory:root.appendingPathComponent("transfers"))
 // Unreachable cloud keeps the transfer pending and the local folder visible.
 let pending=try await transfers.move(source,to:target,library:library,folders:folders)
 assert(!pending && library.pendingCount==1 && folders.migratedLocalIDs.isEmpty)
 let plans=try! fm.contentsOfDirectory(at:root.appendingPathComponent("transfers"),includingPropertiesForKeys:nil);assert(plans.count==1)
 func entries()throws->String{let plan=try JSONSerialization.jsonObject(with:Data(contentsOf:plans[0])) as! [String:Any];return "\(plan["entries"]!)"}
 let firstPlan=try entries()
 // Retrying reuses the persisted session IDs instead of queueing duplicates.
 let retried=try await transfers.move(source,to:target,library:library,folders:folders),secondPlan=try entries()
 assert(!retried && library.pendingCount==1 && secondPlan==firstPlan)
 do{_ = try await transfers.move(source,to:other,library:library,folders:folders);assertionFailure("Conflicting transfer accepted")}catch{}
 assert(library.pendingCount==1 && !transfers.busy)
 var foreign=target;foreign.cloudOwnerID=UUID()
 do{_ = try await transfers.move(source,to:foreign,library:library,folders:folders);assertionFailure("Foreign target accepted")}catch{}
 // Finishing hides the local folder, keeps its files and adopts its directory.
 try folders.finishTransfer(source,to:target)
 assert(folders.migratedLocalIDs==[source.id] && folders.topics[0].folder==sourceFolder.path)
 let kept=try previousSessions(in:sourceFolder);assert(kept.count==1)
 try folders.finishTransfer(source,to:target);assert(folders.records.first{$0.id==a.id}?.migratedLocalIDs==[source.id])
 try await cloudMaterializationTests()
 try await reviewFindingTests()
 try await aiTitleFolderTests()
 try await defaultTitleTests()
 try await aiTitleUploadTests()
 print("PASS: folder transfer stays pending without confirmed uploads, stable resumable IDs, conflict/foreign target rejection and idempotent finish")
}

/// Identita relací bez skrytých značek: index, xattr, nadpis a migrace.
func sessionIndexTests()throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-index-tests-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let created=parseServerDate("2026-01-02T12:30:00.123456+00:00")!
 assert(readableSessionName("  A/B: *test*.  ",created:created).hasSuffix(" A_B_ _test_") && readableSessionName("",created:created).hasSuffix(" Screenshot"))
 assert(readableSessionName("x",created:created).range(of:"^2026-01-0[23] x$",options:.regularExpression) != nil && parseServerDate("2026-01-02 10:00:00+00") != nil)
 assert(uniqueName("X"){["X","X 2"].contains($0)}=="X 3")
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 func shot(_ name:String,_ byte:UInt8)throws{try Data([byte]).write(to:capture.appendingPathComponent(name))}
 // Samostatná relace: bez komentáře, znovuotevření přes index.
 let topic=Topic(id:"idx",name:"Idx",detail:"",folder:root.appendingPathComponent("local").path,combined:false,combinedFile:"N.md")
 try shot("a.png",1);try finishSession(Draft(images:["a.png"],comment:"Komentář",title:"Index",topic:topic),root:capture)
 let markdown=root.appendingPathComponent("local/"+readableSessionName("Index",created:Date())+".md"),text=try String(contentsOf:markdown,encoding:.utf8)
 assert(!text.contains("<!--") && readSessionTag(markdown) != nil)
 var found=try previousSessions(for:topic);assert(found.count==1 && found[0].target.session==readSessionTag(markdown) && found[0].comment=="Komentář")
 let reopenRoot=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopenRoot,withIntermediateDirectories:true)
 var reopened=try workingDraft(from:found[0],topic:topic,root:reopenRoot);try Data([2]).write(to:reopenRoot.appendingPathComponent("b.png"));reopened.images.append("b.png");reopened.comment="Doplněno"
 try finishSession(reopened,root:reopenRoot)
 found=try previousSessions(for:topic);assert(found.count==1 && found[0].images.count==2 && found[0].comment=="Doplněno" && found[0].target.session==readSessionTag(markdown))
 // Po ztrátě indexu stačí xattr.
 SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("lost.json"))
 found=try previousSessions(for:topic);assert(found.count==1 && found[0].title=="Index" && found[0].images.count==2 && found[0].target.session==readSessionTag(markdown))
 print("PASS: readable names and dedupe, Markdown without metadata comment, reopen and precise update via index, reopen via xattr after index loss")
 // Společný soubor upravený v editoru: posunutý a změněný blok se najde podle nadpisu.
 SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("combined.json"))
 var shared=topic;shared.id="shared";shared.folder=root.appendingPathComponent("combined").path;shared.combined=true;shared.combinedFile="All.md"
 for (i,name) in ["První","Druhá"].enumerated(){try shot("c.png",UInt8(10+i));try finishSession(Draft(images:["c.png"],comment:name+" komentář",title:name,topic:shared),root:capture)}
 let all=root.appendingPathComponent("combined/All.md")
 let edited=("Úvod z Obsidianu\n\n"+(try String(contentsOf:all,encoding:.utf8))).replacingOccurrences(of:"Druhá komentář",with:"Upravený komentář")
 try edited.write(to:all,atomically:true,encoding:.utf8)
 found=try previousSessions(for:shared);assert(found.count==2 && found.allSatisfy{$0.target.session != nil} && found.contains{$0.title=="Druhá" && $0.comment=="Upravený komentář"} && found.contains{$0.title=="První" && $0.comment=="První komentář"})
 var second=try workingDraft(from:found.first{$0.title=="Druhá"}!,topic:shared,root:reopenRoot);second.comment="Nový komentář"
 try finishSession(second,root:reopenRoot)
 let after=try! String(contentsOf:all,encoding:.utf8);assert(after.hasPrefix("Úvod z Obsidianu\n\n") && after.contains("Nový komentář") && after.contains("První komentář") && !after.contains("Upravený"))
 found=try previousSessions(for:shared);assert(found.count==2 && found.contains{$0.comment=="Nový komentář"})
 print("PASS: heading fallback for edited and shifted blocks in shared Markdown, precise update keeps foreign text")
 // Migrace starých souborů: netknutý blok přijde o značky, upravený je zachovaný.
 let legacy=root.appendingPathComponent("legacy");try fm.createDirectory(at:legacy.appendingPathComponent("assets"),withIntermediateDirectories:true)
 try Data([5]).write(to:legacy.appendingPathComponent("assets/l1.png"));try Data([6]).write(to:legacy.appendingPathComponent("assets/l2.png"))
 let (clean,cleanBody)=legacyMarkdown("CLEAN-ID","Čistá","Text",["l1.png"]),(dirty,_)=legacyMarkdown("DIRTY-ID","Upravená","Text",["l2.png"])
 try clean.write(to:legacy.appendingPathComponent("Clean.md"),atomically:true,encoding:.utf8)
 try dirty.replacingOccurrences(of:"\nText\n",with:"\nText upravený\n").write(to:legacy.appendingPathComponent("Dirty.md"),atomically:true,encoding:.utf8)
 var legacyTopic=topic;legacyTopic.id="legacy";legacyTopic.folder=legacy.path
 found=try previousSessions(for:legacyTopic)
 let cleanNew=rewriteImageLinks(cleanBody,order:["l1.png"])
 assert(cleanNew.contains("![Screenshot 1](<assets/l1.png>)") && (try! String(contentsOf:legacy.appendingPathComponent("Clean.md"),encoding:.utf8))==cleanNew && (try! String(contentsOf:legacy.appendingPathComponent("Dirty.md"),encoding:.utf8)).contains("<!-- screenshot-note:v1") && (try! String(contentsOf:legacy.appendingPathComponent("Dirty.md"),encoding:.utf8)).contains("![[assets/l2.png]]"))
 assert(found.count==2 && found.contains{$0.title=="Čistá" && $0.target.session=="CLEAN-ID"} && found.contains{$0.comment=="Text upravený" && $0.target.session=="DIRTY-ID"})
 migrateLegacyMarkers(in:legacy);assert(try! String(contentsOf:legacy.appendingPathComponent("Clean.md"),encoding:.utf8)==cleanNew && SessionIndex.shared.records(file:legacy.appendingPathComponent("Clean.md")).count==1)
 print("PASS: legacy comment migration strips only unmodified blocks, records them once and keeps reading edited ones")
}
