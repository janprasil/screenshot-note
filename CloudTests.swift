import AppKit
import CryptoKit

final class CloudMemoryVault: CloudCredentialStore {
 var value: CloudConnection?
 var fail = false
 func load() throws -> CloudConnection? { value }
 func save(_ value: CloudConnection?) throws { if fail { throw CloudFailure.keychain }; self.value = value }
}
private func cloudFixtureConnection(owner: UUID? = UUID()) -> CloudConnection {
 let id=UUID()
 return CloudConnection(endpoint:"https://fixture.invalid",token:"sn_device_v1_" + String(repeating:"a",count:43),id:id,
  comparisonCode:"1234ABCD",verificationURI:"https://fixture.invalid/pair-device/" + id.uuidString.lowercased(),expiresAt:"2099-01-01T00:00:00Z",ownerID:owner,email:nil)
}
/// /me pro testovací transport; s `teams` vrací i pole libraries.
func cloudFixtureMe(_ owner:UUID,teams:[[String:Any]]?=nil)throws->Data {
 var me:[String:Any]=["id":owner.uuidString,"email":"fixture@example.test"]
 if let teams{me["libraries"]=[["id":owner.uuidString,"kind":"personal","name":NSNull(),"role":"owner"]]+teams}
 return try JSONSerialization.data(withJSONObject:["data":me])
}
private func cloudFixturePNG(_ red:CGFloat=0.2) -> Data {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
 for y in 0...1 { for x in 0...1 { bitmap.setColor(NSColor(calibratedRed:red,green:0.4,blue:0.8,alpha:1),atX:x,y:y) } }
 return bitmap.representation(using:.png,properties:[:])!
}
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
 let directories=try! fm.contentsOfDirectory(at:target,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles]);assert(directories.count==1)
 let markdown=directories[0].appendingPathComponent(directories[0].lastPathComponent+".md"),image=directories[0].appendingPathComponent("assets/1.png")
 assert(!String(decoding:(try? Data(contentsOf:markdown)) ?? Data(),as:UTF8.self).contains("<!--"))
 assert(fm.fileExists(atPath:image.path));let original=try! Data(contentsOf:markdown);assert(String(decoding:original,as:UTF8.self).contains("Remote cloud fixture"))
 await store.refresh(live);assert(store.lastError==nil && (try? fm.contentsOfDirectory(atPath:target.path))?.count==1)
 let edited=original+Data("\nLocal edit".utf8);try edited.write(to:markdown)
 await store.refresh(live);assert((try? Data(contentsOf:markdown))==edited)
 try! fm.removeItem(at:image);await store.refresh(live);assert(store.lastError==nil)
 assert((try? Data(contentsOf:markdown))==edited)
 assert((try? fm.contentsOfDirectory(atPath:target.path))?.count==2)
 await store.refresh(live);assert((try? fm.contentsOfDirectory(atPath:target.path))?.count==2)
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
 var teamClock=clock
 let teamLib=CloudLibrary(queue:root.appendingPathComponent("team-queue"),vault:vault,endpoint:endpoint,now:{teamClock})
 let teamFolders=CloudFolders(file:root.appendingPathComponent("team-folders.json"),connection:{teamLib.connection},localTopics:{[]},pending:{teamLib.hasPending($0)},storedLocal:{[]},saveLocal:{_ in})
 teamLib.folderInfo={teamFolders.folderInfo($0)}
 func membership(_ value:Bool)async throws{_ = try await CloudTransport.shared.request(endpoint,"/api/v1/fixture/team",method:"POST",token:original.token,body:Data((value ? #"{"member":true}"#:#"{"member":false}"#).utf8))}
 await teamFolders.refresh(teamLib.connection);assert(teamFolders.lastError==nil)
 guard let team=teamFolders.topics.first(where:{$0.cloudTeam==true}) else{throw CloudFailure.invalid}
 assert(team.displayName==LF("%@ · %@","Fixture tým","Bugy") && team.cloudRole=="member" && !team.canManageCloudFolder && team.cloudOwnerID != original.ownerID)
 let teamDir=root.appendingPathComponent("team-dir");try teamFolders.setFolder(team,path:teamDir.path);await teamFolders.refresh(teamLib.connection)
 let teamFiles=try fm.contentsOfDirectory(atPath:teamDir.path).filter{$0.hasSuffix(".md")}
 assert(teamFolders.lastError==nil && teamFiles.count==1 && ((try? String(contentsOf:teamDir.appendingPathComponent(teamFiles[0]),encoding:.utf8)) ?? "").contains("Autor: Fixture Bob"))
 // Ztráta členství: složka skrytá, soubory zůstávají; upload skončí jednou 404 a znovu se automaticky nezkouší.
 try await membership(false);await teamFolders.refresh(teamLib.connection)
 assert(teamFolders.lastError==nil && teamFolders.topics.isEmpty && teamFolders.isUnavailable(team) && ((try? fm.contentsOfDirectory(atPath:teamDir.path)) ?? []).filter{$0.hasSuffix(".md")}==teamFiles)
 try teamLib.enqueue(Draft(images:["shot.png"],comment:"Týmová poznámka",title:"Team upload",topic:team),root:root,folders:[team])
 await teamLib.sync();assert(teamLib.pendingCount==1 && teamLib.lastError?.contains("Fixture tým · Bugy")==true)
 teamClock=teamClock.addingTimeInterval(120);await teamLib.sync();assert(teamLib.pendingCount==1 && teamLib.lastError?.contains("Bugy")==true)
 // Návrat do týmu: mapování se obnoví a ruční Nahrát teď úlohu odešle.
 try await membership(true);await teamFolders.refresh(teamLib.connection)
 assert(teamFolders.topics.first{$0.cloudTeam==true}?.folder==teamDir.path && ((try? fm.contentsOfDirectory(atPath:teamDir.path)) ?? []).filter{$0.hasSuffix(".md")}==teamFiles)
 teamClock=teamClock.addingTimeInterval(120);await teamLib.sync(manual:true);assert(teamLib.pendingCount==0 && teamLib.lastError==nil)
 print("PASS: team folder over REST: /me libraries, owner fields, library_id listing, {author}, membership loss hides the folder and blocks the upload without a retry loop, rejoin restores the mapping")
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
 print("PASS: folder transfer stays pending without confirmed uploads, stable resumable IDs, conflict/foreign target rejection and idempotent finish")
}

private func legacyMarkdown(_ id:String,_ title:String,_ comment:String,_ images:[String],template:String=defaultMarkdownTemplate)->(String,String) {
 let body=renderSessionTemplate(template,title:title,screenshots:images.map{"![[assets/\($0)]]"}.joined(separator:"\n\n"),text:comment)
 let metadata=SessionMetadata(title:title,comment:comment,images:images,imageNotes:Dictionary(uniqueKeysWithValues:images.map{($0,"")}),bodyLength:(body as NSString).length,bodyHash:sessionFingerprint(Data(body.utf8)),sessionID:id,template:template)
 return ("<!-- screenshot-note:begin "+id+" -->\n"+body+"<!-- screenshot-note:v1 "+(try! JSONEncoder().encode(metadata)).base64EncodedString()+" -->\n",body)
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
 try await staleDraftTests()
 try await markdownLinkTests()
 try await teamFolderTests()
 // Nenamapované složky dostanou podsložky podle názvu bez kolizí.
 let other=CloudFolders(file:root.appendingPathComponent("other.json"),connection:{c},localTopics:{[]});other.activate(c)
 try other.accept([CloudFolderRecord(id:UUID(),name:"Práce/Klient",owner:owner,origin:c.endpoint),CloudFolderRecord(id:UUID(),name:"Práce:Klient",owner:owner,origin:c.endpoint)])
 let parent=root.appendingPathComponent("mapped");try FolderDialogs.assign(other.topics,root:parent,folders:other)
 assert(Set(other.topics.map{URL(fileURLWithPath:$0.folder).lastPathComponent})==["Práce_Klient","Práce_Klient 2"])
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

/// Testovací server pro místní mazání: stav relací, POST trash/restore a hodiny.
@MainActor private final class DeletionFixture {
 let c=cloudFixtureConnection(),folderID=UUID(),root:URL,png=cloudFixturePNG(0.4)
 var ids:[UUID]=[],states:[UUID:String]=[:],posts:[UUID]=[],clock=Date(timeIntervalSince1970:1_800_000_000),busy=Set<UUID>()
 var store:CloudFolders!
 init(_ root:URL,count:Int,combined:Bool)throws {
  self.root=root;ids=(0..<count).map{_ in UUID()};for id in ids{states[id]="active"}
  store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{[unowned self] in self.c},localTopics:{[]},request:{[unowned self] _,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(self.c.ownerID!)}
   if path.contains("/images/"){return self.png}
   let data:Any
   if path=="/api/v1/folders"{data=["data":[["id":self.folderID.uuidString,"name":"Mazání","revision":"1","combined":combined,"combined_file":"All.md"]]]}
   else if path.contains("?") {
    let wanted=path.contains("state=trashed") ? "trashed":"active"
    data=["data":self.ids.filter{self.states[$0]==wanted}.map{["id":$0.uuidString,"updated_at":"t1","trashed_at":wanted=="trashed" ? "2026-01-01T00:00:00Z":NSNull()]},"pagination":["has_more":false]]
   } else {
    let id=self.ids.first{path.contains($0.uuidString.lowercased())}!,index=self.ids.firstIndex(of:id)!
    data=["data":["id":id.uuidString,"title":"Relace \(index)","comment":"Text \(index)","template":defaultMarkdownTemplate,"captions":[""],"updated_at":"t1","created_at":"2026-01-0\(index%9+1)T10:00:00Z","images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]
   }
   return try JSONSerialization.data(withJSONObject:data)
  },send:{[unowned self] _,path,_,_,_ in
   let id=self.ids.first{path.contains($0.uuidString.lowercased())}!
   if path.hasSuffix("/trash"){self.posts.append(id);self.states[id]="trashed"}else{self.states[id]="active"}
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString]])
  },now:{[unowned self] in self.clock},pending:{[unowned self] in self.busy.contains($0)})
 }
 var target:URL{root.appendingPathComponent("cloud")}
 func start()async throws{await store.refresh(c);try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)}
 func scan(after seconds:Double)async{clock=clock.addingTimeInterval(seconds);await store.refresh(c)}
 func directory(_ i:Int)->URL{URL(fileURLWithPath:SessionIndex.shared.cloud(ids[i],base:try! Topics.checkedDestination(target.path))!.file)}
 func markdowns()->Int{((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{$0.hasSuffix(".md")}.count}
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

/// Odpovědi pro CloudTransport bez sítě: /me a nahrávání do složky v Koši.
final class TrashedFolderStub: URLProtocol {
 static var owner=UUID()
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "",me=path=="/api/v1/me"
  let body=me ? ["data":["id":Self.owner.uuidString]]:["error":["code":"folder_trashed"]]
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:me ? 200:409,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
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
 present=false;await store.refresh(c);try store.discardDeleted(folderID);assert(recycled.map(\.path)==[dir.path] && store.records.isEmpty && local.isEmpty)
 // Smazání v aplikaci: lokální jen do Koše v macOS, cloudová i na serveru; starý server nic nesmaže.
 recycled=[];present=true;await store.refresh(c);try store.setFolder(store.topics[0],path:dir.path)
 trashStatus=CloudFailure("404",status:404);do{try await store.trashFolder(store.topics[0]);assertionFailure("Unsupported server accepted")}catch{}
 assert(recycled.isEmpty && store.topics.count==1)
 trashStatus=nil;try await store.trashFolder(store.topics[0])
 assert(sent.last=="/api/v1/folders/"+folderID.uuidString.lowercased()+"/trash" && recycled.map(\.path)==[dir.path] && store.records.isEmpty)
 let localTopic=Topic(id:"plain",name:"Lokální",detail:"",folder:base.appendingPathComponent("plain").path,combined:false,combinedFile:"N.md");try fm.createDirectory(atPath:localTopic.folder,withIntermediateDirectories:true)
 local=[localTopic];let calls=sent.count;try store.deleteLocalFolder(localTopic)
 assert(local.isEmpty && recycled.last?.path==localTopic.folder && sent.count==calls)
 print("PASS: web-deleted folder keep/restore-before-answer/delete to macOS Trash, app delete of local vs cloud folder, unsupported server keeps everything")
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

/// Server bez sítě, který nahrání hned potvrdí a zapamatuje si manifest.
final class AcceptingUploadStub: URLProtocol {
 static var owner=UUID()
 static var manifests:[(UUID,[String:Any])]=[]
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "";var body:[String:Any]
  if path=="/api/v1/me"{body=["data":["id":Self.owner.uuidString]]}
  else {
   var data=request.httpBody ?? Data()
   if data.isEmpty,let stream=request.httpBodyStream{stream.open();var buffer=[UInt8](repeating:0,count:65536);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};stream.close()}
   let id=UUID(uuidString:String(path.split(separator:"/").last!))!,manifest=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
   if !Self.manifests.contains(where:{$0.0==id}){Self.manifests.append((id,manifest))}
   let count=(manifest["images"] as? [Any])?.count ?? 1
   body=["data":["session_id":id.uuidString,"manifest_digest":String(repeating:"b",count:64),"confirmed_indices":Array(1...count),"state":"committed"]]
  }
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}
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
   gone.remove(id("První"));await store.refresh(c);assert(exists("\(P).md") && exists("assets/\(P)-1.png") && !exists(".trash/assets/\(P)-1.png"))
  }
  _ = assets
  print("PASS: \(combined ? "combined":"separate") adopted session trash/restore/purge moves its images with it, copies a shared image, user restore from .trash, root and assets/ untouched")
 }
}

/// Šablony: přerenderování lokální složky, výchozí šablony a jejich synchronizace.
@MainActor func templateTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-templates-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 let newSession="## {title}\n\n{text}\n\n{screenshots}\n"
 for combined in [false,true] {
  let topic=Topic(id:"t",name:"Šablony",detail:"Popis",folder:root.appendingPathComponent(combined ? "combined":"separate").path,combined:combined,combinedFile:"All.md")
  for title in ["První","Druhá"]{try Data([1]).write(to:capture.appendingPathComponent("s.png"));try finishSession(Draft(images:["s.png"],comment:title+" text",title:title,topic:topic),root:capture)}
  var changed=topic;changed.markdownTemplate=newSession;changed.combinedTemplate=combined ? "Hlavička {folderName}\n\n{sessions}\n\nKonec\n":nil
  if combined {
   let all=topic.destination.appendingPathComponent("All.md")
   let result=rerenderFolder(changed,previous:topic),text=try String(contentsOf:all,encoding:.utf8)
   assert(result.updated==2 && result.edited==0 && text.hasPrefix("Hlavička Šablony\n\n## První\n\nPrvní text") && text.hasSuffix("Konec\n") && text.contains("## Druhá"))
   assert((try! previousSessions(for:changed)).count==2)
   // Ručně upravený společný soubor se nepřepíše; nová verze jde do All_template.md.
   let edited=text+"\nMoje poznámka\n";try edited.write(to:all,atomically:true,encoding:.utf8)
   var again=changed;again.markdownTemplate="### {title}\n\n{screenshots}\n\n{text}\n"
   let second=rerenderFolder(again,previous:changed)
   assert(second.updated==0 && second.edited>=1 && (try! String(contentsOf:all,encoding:.utf8))==edited && (try! String(contentsOf:topic.destination.appendingPathComponent("All_template.md"),encoding:.utf8)).contains("### Druhá"))
  } else {
   let first=topic.destination.appendingPathComponent(readableSessionName("První",created:Date())+".md"),second=topic.destination.appendingPathComponent(readableSessionName("Druhá",created:Date())+".md")
   let edited=(try String(contentsOf:second,encoding:.utf8))+"\nRuční úprava\n";try edited.write(to:second,atomically:true,encoding:.utf8)
   let result=rerenderFolder(changed,previous:topic)
   assert(result.updated==1 && result.edited==1 && (try! String(contentsOf:first,encoding:.utf8)).hasPrefix("## První\n\nPrvní text") && (try! String(contentsOf:second,encoding:.utf8))==edited)
   assert((try! String(contentsOf:topic.destination.appendingPathComponent(readableSessionName("Druhá",created:Date())+"_template.md"),encoding:.utf8)).hasPrefix("## Druhá"))
   assert((try! previousSessions(for:changed)).contains{$0.title=="První" && $0.comment=="První text"})
  }
 }
 print("PASS: local template change re-renders separate files and combined blocks/header/footer, edited ones get _template.md")
 // Výchozí šablony: lokálně bez účtu, kopie do nové složky, konflikt na serveru, odhlášení.
 let suite="sn-test-"+UUID().uuidString,store=UserDefaults(suiteName:suite)!;defer{store.removePersistentDomain(forName:suite)}
 let c=cloudFixtureConnection();var connection:CloudConnection?=nil,remote:[String:Any]=["session_template":NSNull(),"file_template":NSNull(),"revision":"1"],puts=0
 let defaults=TemplateDefaults(store:store,connection:{connection},request:{_,_,_ in try JSONSerialization.data(withJSONObject:["data":remote])},send:{_,_,_,body in
  puts+=1;let sent=try JSONSerialization.jsonObject(with:body) as! [String:Any]
  guard sent["revision"] as? String==remote["revision"] as? String else{throw CloudFailure("409",status:409,code:"templates_conflict")}
  remote=["session_template":sent["session_template"]!,"file_template":sent["file_template"]!,"revision":String(Int(remote["revision"] as! String)!+1)]
  return try JSONSerialization.data(withJSONObject:["data":remote])
 })
 let custom="# {title}\n\n{screenshots}\n\n{text}\n\n_výchozí_\n",customFile="# {folderName}\n\n{sessions}\n\n_patička_\n"
 try await defaults.save(session:custom,file:customFile);assert(defaults.session==custom && defaults.file==customFile && puts==0)
 let fresh=defaults.newFolderTemplates;assert(fresh.0==custom && fresh.1==customFile)
 let shared=TemplateDefaults.shared;TemplateDefaults.shared=defaults;defer{TemplateDefaults.shared=shared}
 var created:[String:Any]=[:]
 let folders=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},send:{_,path,_,_,body in
  created=try JSONSerialization.jsonObject(with:body) as! [String:Any]
  return try JSONSerialization.data(withJSONObject:["data":["id":path.split(separator:"/").last!,"name":created["name"]!,"revision":"1","markdown_template":created["markdown_template"]!,"combined_template":created["combined_template"]!]])
 })
 _ = try await folders.create("Nová");assert(created["markdown_template"] as? String==custom && created["combined_template"] as? String==customFile && folders.topics.first?.markdownTemplate==custom)
 print("PASS: default templates stored locally when signed out and copied into new local and cloud folders")
 connection=c;await defaults.refresh();assert(defaults.session==nil && defaults.file==nil)
 remote=["session_template":custom,"file_template":NSNull(),"revision":"5"]
 do{try await defaults.save(session:newSession,file:defaultCombinedTemplate);assertionFailure("Conflict ignored")}catch let failure as CloudFailure{assert(failure.message==L("Změněno jinde. Načetl jsem novou verzi.") && defaults.session==custom)}
 try await defaults.save(session:newSession,file:defaultCombinedTemplate);assert(defaults.session==newSession && defaults.file==nil && remote["revision"] as? String=="6")
 defaults.forgetAccount();connection=nil;let before=puts
 assert(defaults.session==newSession)
 try await defaults.save(session:custom,file:customFile);assert(puts==before && defaults.session==custom)
 print("PASS: account default templates sync with revision conflict reload, logout keeps last values as local defaults")
}

/// Plochá složka: deduplikace názvů a zploštění starých podsložek relací.
@MainActor func flatLayoutTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-flat-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let c=cloudFixtureConnection(),folderID=UUID(),ids=(0..<4).map{_ in UUID()},png=cloudFixturePNG(0.6),created="2026-04-01T09:00:00Z"
 func note(_ id:UUID)->[String:Any]{["id":id.uuidString,"title":"Stejná","comment":"Text","template":defaultMarkdownTemplate,"captions":[""],"updated_at":"t1","created_at":created,"images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]}
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[]},request:{_,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(c.ownerID!)}
  if path.contains("/images/"){return png}
  if path=="/api/v1/folders"{return try JSONSerialization.data(withJSONObject:["data":[["id":folderID.uuidString,"name":"Plochá","revision":"1"]]])}
  if path.contains("?"){return try JSONSerialization.data(withJSONObject:["data":path.contains("state=trashed") ? []:ids.map{["id":$0.uuidString,"updated_at":"t1","trashed_at":NSNull()]},"pagination":["has_more":false]])}
  return try JSONSerialization.data(withJSONObject:["data":note(ids.first{path.contains($0.uuidString.lowercased())}!)])
 })
 await store.refresh(c)
 let target=root.appendingPathComponent("cloud"),name=readableSessionName("Stejná",created:parseServerDate(created)!)
 try fm.createDirectory(at:target,withIntermediateDirectories:true)
 let base=try Topics.checkedDestination(target.path)
 // Dvě relace ve staré podobě podsložek: netknutá a upravená.
 let digest={(id:UUID)->String in sessionFingerprint(try! JSONEncoder.sorted.encode(try! JSONDecoder().decode(RemoteNote.self,from:JSONSerialization.data(withJSONObject:note(id)))))}
 for (i,id) in ids.prefix(2).enumerated() {
  let folder=target.appendingPathComponent("Starší \(i)"),markdown=folder.appendingPathComponent("Starší \(i).md")
  try fm.createDirectory(at:folder.appendingPathComponent("assets"),withIntermediateDirectories:true);try png.write(to:folder.appendingPathComponent("assets/1.png"))
  let body=renderSessionTemplate(defaultMarkdownTemplate,title:"Stejná",screenshots:"![[assets/1.png]]",text:"Text");try body.write(to:markdown,atomically:true,encoding:.utf8)
  var record=SessionRecord(id:id.uuidString.lowercased(),file:SessionIndex.key(markdown),start:0,length:(body as NSString).length,hash:sessionFingerprint(Data(body.utf8)),heading:firstLine(body),title:"Stejná",comment:"Text",template:defaultMarkdownTemplate,images:["1.png"],notes:["1.png":""],combined:false,footer:"",files:[markdown.lastPathComponent:sessionFingerprint(Data(body.utf8)),"assets/1.png":sessionFingerprint(png)],seen:0,base:SessionIndex.key(base),folder:folderID.uuidString.lowercased(),owner:c.ownerID!.uuidString.lowercased(),origin:c.endpoint)
  record.updated="t1";record.digest=digest(id);record.shas=[sessionFingerprint(png)];record.created=created;SessionIndex.shared.put(record)
  if i==1{try Data("cizí".utf8).write(to:folder.appendingPathComponent("Moje.txt"))}
 }
 try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)
 let items=((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{!$0.hasPrefix(".")}.sorted()
 // Netknutá podsložka se zploštila, upravená zůstala; nové relace mají deduplikované názvy.
 assert(items==["Starší 0.md","Starší 1","assets",name+".md",name+" 2.md"].sorted())
 let assets=Set((try fm.contentsOfDirectory(atPath:target.appendingPathComponent("assets").path)))
 assert(assets==["Starší 0-1.png",name+"-1.png",name+" 2-1.png"] && (try! String(contentsOf:target.appendingPathComponent("Starší 0.md"),encoding:.utf8)).contains("](<assets/Starší 0-1.png>)"))
 assert(fm.fileExists(atPath:target.appendingPathComponent("Starší 1/assets/1.png").path) && (try! String(contentsOf:target.appendingPathComponent(name+" 2.md"),encoding:.utf8)).contains("](<assets/"+name+" 2-1.png>)"))
 let found=try previousSessions(for:store.topics[0]);assert(found.count==4 && found.allSatisfy{$0.target.session != nil})
 print("PASS: flat layout: YYYY-MM-DD Title.md with ' 2' dedupe, shared assets/Title-N.png, unmodified session folders flattened, modified ones untouched")
}

/// Server pro PATCH úprav: drží jednu relaci s revizí, při nesouhlasu revize vrací 409.
final class EditStub: URLProtocol {
 static var owner=UUID(),remote:[String:Any]=[:],patches:[[String:Any]]=[]
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "";var status=200,body:[String:Any]
  if path=="/api/v1/me"{body=["data":["id":Self.owner.uuidString]]}
  else if request.httpMethod=="PATCH" {
   var data=request.httpBody ?? Data()
   if data.isEmpty,let stream=request.httpBodyStream{stream.open();var buffer=[UInt8](repeating:0,count:65536);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};stream.close()}
   let sent=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:];Self.patches.append(sent)
   if sent["revision"] as? String != Self.remote["revision"] as? String{status=409;body=["error":["code":"session_changed"]]}
   else{for key in ["title","comment","captions"]{Self.remote[key]=sent[key]};Self.remote["revision"]=String(Int(Self.remote["revision"] as! String)!+1);body=["data":Self.remote]}
  } else {body=["data":Self.remote]}
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}
/// Úpravy textu cloudových relací (PATCH, sloučení, konflikt) a vykreslení {comments}.
@MainActor func editAndCommentTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-edits-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 // {comments}: výchozí šablona bez komentářů nemá na konci nic navíc.
 assert(renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:"S",text:"X")==renderSessionTemplate(legacyDefaultMarkdownTemplate,title:"T",screenshots:"S",text:"X"))
 let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone = .current;format.dateFormat="yyyy-MM-dd HH:mm"
 let first=RemoteNote.Comment(author_name:"Jan",body:"Ahoj",created_at:"2026-05-01T10:00:00Z"),second=RemoteNote.Comment(author_name:"Eva",body:"Druhý\nřádek",created_at:"2026-05-02T08:30:00.123456+00:00")
 let stamp1=format.string(from:parseServerDate(first.created_at)!),stamp2=format.string(from:parseServerDate(second.created_at)!)
 assert(renderComments([])=="" && renderComments([first])=="Ahoj\n`Jan` - `\(stamp1)`" && renderComments([first,second])=="Ahoj\n`Jan` - `\(stamp1)`\n\nDruhý\nřádek\n`Eva` - `\(stamp2)`")
 let withComments=renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:"![[assets/a.png]]",text:"X",comments:renderComments([first]))
 assert(withComments.hasSuffix("# Description\n\nX\n\nAhoj\n`Jan` - `\(stamp1)`\n"))
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

/// Standardní Markdown odkazy: vykreslení, čtení obou formátů, migrace a doplnění převedeného souboru.
@MainActor func markdownLinkTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-links-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 assert(imageMarkdown("2026-01-01 Titul-2.png",2)=="![Screenshot 2](<assets/2026-01-01 Titul-2.png>)")
 assert(screenshotsMarkdown(["a b-1.png","a b-2.png"],["","Popis"])=="![Screenshot 1](<assets/a b-1.png>)\n\n![Screenshot 2](<assets/a b-2.png>)\n\nPopis")
 assert(imageLinkNames("![[assets/x y.png]] ![S](<assets/a b.png>) ![S](assets/c.png)")==["x y.png","a b.png","c.png"])
 // Oba formáty se čtou při hledání relace podle šablony.
 for screenshots in ["![[assets/a b.png]]\n\nPopis","![Screenshot 1](<assets/a b.png>)\n\nPopis"] {
  let parsed=parsedSession(defaultMarkdownTemplate,renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:screenshots,text:"X"))
  assert(parsed?.2==["a b.png"] && parsed?.3["a b.png"]=="Popis")
 }
 // Migrace: netknutý soubor ve starém formátu se převede, upravený zůstane.
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 let topic=Topic(id:"links",name:"Odkazy",detail:"",folder:root.appendingPathComponent("local").path,combined:false,combinedFile:"N.md")
 for title in ["Čistá","Upravená"]{try Data([1]).write(to:capture.appendingPathComponent("a.png"));try finishSession(Draft(images:["a.png"],comment:"Text",title:title,topic:topic),root:capture)}
 let clean=topic.destination.appendingPathComponent(readableSessionName("Čistá",created:Date())+".md"),edited=topic.destination.appendingPathComponent(readableSessionName("Upravená",created:Date())+".md")
 assert((try! String(contentsOf:clean,encoding:.utf8)).contains("![Screenshot 1](<assets/"))
 // Simulace starších souborů: wikiodkazy, index odpovídá zapsanému obsahu.
 for file in [clean,edited] {
  let old=(try String(contentsOf:file,encoding:.utf8)).replacingOccurrences(of:"![Screenshot 1](<assets/",with:"![[assets/").replacingOccurrences(of:".png>)",with:".png]]")
  try old.write(to:file,atomically:true,encoding:.utf8)
  var record=SessionIndex.shared.records(file:file)[0];record.length=(old as NSString).length;record.hash=sessionFingerprint(Data(old.utf8));SessionIndex.shared.put(record)
 }
 let editedText=(try String(contentsOf:edited,encoding:.utf8))+"\nRuční úprava\n";try editedText.write(to:edited,atomically:true,encoding:.utf8)
 migrateImageLinks(in:topic.destination)
 let migrated=try String(contentsOf:clean,encoding:.utf8)
 assert(migrated.contains("![Screenshot 1](<assets/") && !migrated.contains("![[assets/") && (try! String(contentsOf:edited,encoding:.utf8))==editedText)
 migrateImageLinks(in:topic.destination);assert((try! String(contentsOf:clean,encoding:.utf8))==migrated)
 // Znovu otevřít převedenou relaci a doplnit snímek.
 let found=try previousSessions(for:topic);assert(found.count==2)
 let session=found.first{$0.title=="Čistá"}!;assert((try? checkedPreviousFile(session.target)) != nil)
 let reopen=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopen,withIntermediateDirectories:true)
 var draft=try workingDraft(from:session,topic:topic,root:reopen);try Data([2]).write(to:reopen.appendingPathComponent("n.png"));draft.images.append("n.png")
 try finishSession(draft,root:reopen)
 let appended=try String(contentsOf:clean,encoding:.utf8)
 assert(appended.contains("![Screenshot 1](<assets/") && appended.contains("![Screenshot 2](<assets/") && (try! previousSessions(for:topic)).contains{$0.title=="Čistá" && $0.images.count==2})
 print("PASS: standard Markdown image links: rendering, both formats parsed, migration of unmodified files only, reopen and append on a migrated file")
}

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
}
