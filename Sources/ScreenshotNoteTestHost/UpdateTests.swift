import Foundation
@testable import ScreenshotNoteKit

/// Updater startuje jen s produkčním HTTPS feedem a klíčem; testy a náhledy feed nikdy nečtou.
func updateTests() throws {
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 let release:[String:Any]=["ScreenshotNoteEnvironment":"production","SUFeedURL":"https://example.invalid/appcast.xml","SUPublicEDKey":"key"]
 let app=["/Applications/Screenshot Note.app/Contents/MacOS/ScreenshotNote"]
 try check(Updates.feedURL(info:release,arguments:app)?.absoluteString == "https://example.invalid/appcast.xml","release build reads its feed")
 try check(Updates.feedURL(info:release,arguments:app+["--capture","--fullscreen"]) != nil,"command line capture keeps updates")
 for flag in ["--self-test","--preview-test","--folder-sync-self-test","--design-export","--interactive-ui-tests"] {
  try check(Updates.feedURL(info:release,arguments:app+[flag]) == nil,"\(flag) must not contact the feed")
 }
 var local=release;local["ScreenshotNoteEnvironment"]="local";try check(Updates.feedURL(info:local,arguments:app) == nil,"local build has no updates")
 var test=release;test["ScreenshotNoteEnvironment"]="test";try check(Updates.feedURL(info:test,arguments:app) == nil,"test build has no updates")
 var plain=release;plain["SUFeedURL"]="http://example.invalid/appcast.xml";try check(Updates.feedURL(info:plain,arguments:app) == nil,"HTTP feed is rejected")
 var keyless=release;keyless.removeValue(forKey:"SUPublicEDKey");try check(Updates.feedURL(info:keyless,arguments:app) == nil,"feed without public key is rejected")
 var feedless=release;feedless.removeValue(forKey:"SUFeedURL");try check(Updates.feedURL(info:feedless,arguments:app) == nil,"build without feed has no updates")
 try check(Updates.feedURL(info:nil,arguments:app) == nil,"missing Info.plist has no updates")
 try check(Updates.channels(releaseCandidates:false).isEmpty && Updates.channels(releaseCandidates:true) == ["rc"],"release candidates are opt-in")
 // Testovací host updater vypíná, i kdyby bundle feed měl.
 Updates.shared.start();try check(!Updates.shared.isRunning,"updater stays off in the test host")
}
