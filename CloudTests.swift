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
private func cloudFixturePNG() -> Data {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
 for y in 0...1 { for x in 0...1 { bitmap.setColor(NSColor(calibratedRed:0.2,green:0.4,blue:0.8,alpha:1),atX:x,y:y) } }
 return bitmap.representation(using:.png,properties:[:])!
}
func cloudUnitTests() throws {
 try cloudFolderUnitTests()
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
 let draft=Draft(images:["shot.png"],comment:"Offline note",title:"Frozen title")
 try lib.enqueue(draft,root:root);assert(lib.pendingCount == 1)
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
 let directories=try fm.contentsOfDirectory(at:target,includingPropertiesForKeys:nil);assert(directories.count==1)
 let markdown=directories[0].appendingPathComponent("Note.md"),image=directories[0].appendingPathComponent("assets/1.png")
 assert(fm.fileExists(atPath:image.path));let original=try Data(contentsOf:markdown);assert(String(decoding:original,as:UTF8.self).contains("Remote cloud fixture"))
 await store.refresh(live);assert(store.lastError==nil && (try? fm.contentsOfDirectory(atPath:target.path))?.count==1)
 let edited=original+Data("\nLocal edit".utf8);try edited.write(to:markdown)
 await store.refresh(live);assert((try? Data(contentsOf:markdown))==edited)
 try fm.removeItem(at:image);await store.refresh(live);assert(store.lastError==nil)
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
 let draft=Draft(images:["shot.png"],comment:"Native **REST** fixture",title:"Native fixture",imageNotes:["shot.png":"Caption"])
 try resumed.enqueue(draft,root:root);assert(resumed.pendingCount == 1)
 for _ in 0..<5 { await resumed.sync();if resumed.pendingCount == 0 { break };clock=clock.addingTimeInterval(120) }
 guard resumed.pendingCount == 0 else { throw CloudFailure.invalid }
 let preserved = try Data(contentsOf:root.appendingPathComponent("shot.png")); assert(preserved == png)
 try resumed.enqueue(draft,root:root)
 let drain = Task { @MainActor in await resumed.sync() }
 try await Task.sleep(nanoseconds:100_000_000)
 assert(resumed.syncing)
 try resumed.enqueue(draft,root:root);await resumed.sync();await drain.value
 assert(resumed.pendingCount == 0)
 try resumed.enqueue(draft,root:root)
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
}
