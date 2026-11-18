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
 assert(CloudEndpoint("https://screenshotnote.com") != nil)
 for url in ["https://user:secret@example.test","https://example.test/a","https://example.test/?token=secret","http://remote.test","file:///tmp","https://example.test/#secret"] { assert(CloudEndpoint(url) == nil) }
 assert(CloudEndpoint("http://127.0.0.1:4567") != nil)
 assert(!CloudConnection.validToken("legacy.jwt.token"));assert(!CloudConnection.validToken("sn_device_v1_bad"))
 let vault=CloudMemoryVault();vault.value=cloudFixtureConnection()
 assert(CloudLibrary.browserURL(vault.value!)?.query == nil)
 let root=fm.temporaryDirectory.appendingPathComponent("sn-cloud-unit-" + UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
 try cloudFixturePNG().write(to:root.appendingPathComponent("shot.png"))
 let normalized=try cloudImage(root.appendingPathComponent("shot.png"))
 assert(normalized[24] == 8 && [2,6].contains(normalized[25]) && normalized[28] == 0)
 let lib=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault)
 let draft=Draft(images:["shot.png"],comment:"Offline note",title:"Frozen title")
 try lib.enqueue(draft,root:root);assert(lib.pendingCount == 1)
 let other=CloudMemoryVault();other.value=cloudFixtureConnection()
 assert(CloudLibrary(queue:root.appendingPathComponent("queue"),vault:other).pendingCount == 0)
 assert(CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault).pendingCount == 1)
 let old=root.appendingPathComponent("queue/legacy",isDirectory:true);try fm.createDirectory(at:old,withIntermediateDirectories:true)
 try Data("{\"project\":\"legacy\",\"session\":{}}".utf8).write(to:old.appendingPathComponent("job.json"))
 assert(lib.legacyPendingCount == 1 && lib.pendingCount == 1)
 let pending=CloudMemoryVault();pending.value=cloudFixtureConnection(owner:nil)
 do { try CloudLibrary(queue:root,vault:pending).enqueue(draft,root:root);assertionFailure("Pending credential admitted upload") } catch {}
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

@MainActor func cloudIntegrationTest() async throws {
 guard let raw=ProcessInfo.processInfo.environment["SCREENSHOT_NOTE_TEST_URL"],let endpoint=CloudEndpoint(raw),
       ["localhost","127.0.0.1"].contains(endpoint.url.host ?? "") else { throw CloudFailure.invalid }
 let root=fm.temporaryDirectory.appendingPathComponent("sn-native-rest-" + UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer {try? fm.removeItem(at:root)}
 let vault=CloudMemoryVault();var clock=Date()
 let failed=CloudLibrary(queue:root.appendingPathComponent("failed"),vault:vault,now:{clock});vault.fail=true
 do {try await failed.startPairing(endpoint:endpoint,name:"Failed vault");assertionFailure("Keychain failure ignored")} catch {}
 assert(failed.connection == nil && vault.value == nil);vault.fail=false
 let lib=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,now:{clock})
 try await lib.startPairing(endpoint:endpoint,name:"Native fixture");assert(vault.value?.ownerID == nil && lib.connection != nil)
 let resumed=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,now:{clock})
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
 let switched=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,now:{clock});assert(switched.pendingCount == 0)
 await switched.sync();assert(switched.lastError != nil)
 try vault.save(original);let restored=CloudLibrary(queue:root.appendingPathComponent("queue"),vault:vault,now:{clock});assert(restored.pendingCount == 1)
 try restored.forgetConnection();assert(restored.connection == nil)
 let unsafe=CloudLibrary(queue:root.appendingPathComponent("unsafe"),vault:vault,now:{clock})
 do {try await unsafe.startPairing(endpoint:endpoint,name:"Unsafe URI");assertionFailure("Foreign browser URI accepted")} catch {}
 assert(unsafe.connection == nil && vault.value == nil)
 let cancel=CloudLibrary(queue:root.appendingPathComponent("cancel"),vault:vault,now:{clock})
 try await cancel.startPairing(endpoint:endpoint,name:"Cancel fixture");try await cancel.cancelPairing()
 assert(cancel.connection == nil && vault.value == nil)
 let limited=CloudLibrary(queue:root.appendingPathComponent("limited"),vault:vault,now:{clock})
 do {try await limited.startPairing(endpoint:endpoint,name:"Rate fixture");assertionFailure("Rate limit ignored")} catch {}
 assert(limited.retryAt >= clock.addingTimeInterval(60))
 do {try await limited.startPairing(endpoint:endpoint,name:"Rate fixture");assertionFailure("Rate limit retried early")} catch {}
 print("PASS: native REST pairing/vault/restart, owner identity, streamed PNG, lost manifest/image/commit responses, stable upload UUID/digest and account-switch isolation")
}
