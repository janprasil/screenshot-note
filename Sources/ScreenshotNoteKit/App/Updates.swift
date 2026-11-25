import AppKit
import Sparkle

/// Aktualizace přes Sparkle; bez feedu v Info.plist (lokální a testovací buildy) updater nestartuje.
final class Updates:NSObject,SPUUpdaterDelegate,SPUStandardUserDriverDelegate,NSMenuItemValidation {
 static let shared=Updates()
 /// Testovací host updater nikdy nespouští.
 static var disabled=false
 static let releaseCandidatesKey="updates.release-candidates"
 private var controller:SPUStandardUpdaterController?
 /// Plánovaná kontrola našla verzi; menu ji nabídne, okno Sparkle se nevnucuje do popředí.
 private(set) var updateWaiting=false
 var isRunning:Bool{controller != nil}

 /// Feed jen z produkčního buildu s HTTPS adresou a veřejným klíčem, nikdy v testovacích bězích.
 static func feedURL(info:[String:Any]?,arguments:[String])->URL? {
  guard info?["ScreenshotNoteEnvironment"] as? String == "production",info?["SUPublicEDKey"] is String,
        let raw=info?["SUFeedURL"] as? String,let url=URL(string:raw),url.scheme == "https",url.host != nil else{return nil}
  if arguments.dropFirst().contains(where:{$0.hasSuffix("-test") || $0 == "--design-export" || $0 == "--interactive-ui-tests"}){return nil}
  return url
 }
 static func channels(releaseCandidates:Bool)->Set<String>{releaseCandidates ? ["rc"]:[]}

 func start() {
  guard !Self.disabled,controller == nil,Self.feedURL(info:Bundle.main.infoDictionary,arguments:CommandLine.arguments) != nil else{return}
  let candidate=SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:self,userDriverDelegate:self)
  do{try candidate.updater.start();controller=candidate}catch{NSLog("Updater failed to start: %@",error.localizedDescription)}
 }
 @objc func checkForUpdates(_ sender:Any?){updateWaiting=false;NSApp.activate(ignoringOtherApps:true);controller?.checkForUpdates(sender)}
 func validateMenuItem(_ menuItem:NSMenuItem)->Bool{menuItem.action != #selector(checkForUpdates(_:)) || controller?.updater.canCheckForUpdates == true}
 var automaticChecks:Bool {
  get{controller?.updater.automaticallyChecksForUpdates ?? false}
  set{controller?.updater.automaticallyChecksForUpdates=newValue}
 }
 var releaseCandidates:Bool {
  get{UserDefaults.standard.bool(forKey:Self.releaseCandidatesKey)}
  set{UserDefaults.standard.set(newValue,forKey:Self.releaseCandidatesKey)}
 }

 // MARK: SPUUpdaterDelegate
 func allowedChannels(for updater:SPUUpdater)->Set<String>{Self.channels(releaseCandidates:releaseCandidates)}

 // MARK: SPUStandardUserDriverDelegate
 var supportsGentleScheduledUpdateReminders:Bool{true}
 func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate:Bool,forUpdate update:SUAppcastItem,state:SPUUserUpdateState) {
  if !state.userInitiated{updateWaiting=true}
 }
 func standardUserDriverWillFinishUpdateSession(){updateWaiting=false}
}
