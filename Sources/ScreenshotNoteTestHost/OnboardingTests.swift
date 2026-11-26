import Foundation
@testable import ScreenshotNoteKit

/// Průvodce prvním spuštěním: jen nová instalace nebo nedokončený průvodce, stávající instalace se označí jako hotová.
func onboardingTests() throws {
 func store()->UserDefaults{let name="sn-onboarding-"+UUID().uuidString;let d=UserDefaults(suiteName:name)!;d.removePersistentDomain(forName:name);return d}
 let fresh=store();assert(Onboarding.pending(fresh) && !fresh.bool(forKey:Onboarding.doneKey))
 for key in ["topics","destination","defaultTopic","lastTopic","shortcutOnboardingDone"] {
  let existing=store();existing.set("x",forKey:key)
  assert(!Onboarding.pending(existing) && existing.bool(forKey:Onboarding.doneKey))
 }
 let shortcut=store();shortcut.set(Data([1]),forKey:"shortcut2");assert(!Onboarding.pending(shortcut))
 // Rozpracovaný průvodce pokračuje i po uložení složky (relaunch po povolení záznamu obrazovky).
 let resumed=store();resumed.set(Onboarding.Step.permissions.rawValue,forKey:Onboarding.stepKey);resumed.set("/tmp/x",forKey:"destination");assert(Onboarding.pending(resumed))
 let done=store();done.set(true,forKey:Onboarding.doneKey);done.set(1,forKey:Onboarding.stepKey);assert(!Onboarding.pending(done))
 // Nová výchozí složka; stará zůstane jen instalaci, která ji na disku má a jinou cestu nemá uloženou.
 assert(destination.path.hasSuffix("/Documents/ScreenshotNote/Default") || UserDefaults.standard.string(forKey:"destination") != nil)
 let legacy=fm.temporaryDirectory.appendingPathComponent("sn-legacy-"+UUID().uuidString,isDirectory:true)
 let missing=store();pinLegacyDestination(missing,legacy:legacy);assert(missing.object(forKey:"destination") == nil)
 try fm.createDirectory(at:legacy,withIntermediateDirectories:true);defer{try? fm.removeItem(at:legacy)}
 let pinned=store();pinLegacyDestination(pinned,legacy:legacy);assert(pinned.string(forKey:"destination") == legacy.path)
 let custom=store();custom.set("/tmp/own",forKey:"destination");pinLegacyDestination(custom,legacy:legacy);assert(custom.string(forKey:"destination") == "/tmp/own")
 let topics=store();topics.set(Data([1]),forKey:"topics");pinLegacyDestination(topics,legacy:legacy);assert(topics.object(forKey:"destination") == nil)
}
