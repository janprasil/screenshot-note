import AppKit

/// Start appky; volá ho tenký executable.
public enum ScreenshotNoteApp {
 public static func main() throws {
 if CommandLine.arguments.contains("--language-check"){print(AppLanguage.current);exit(0)}
 // Testy jsou v testovacím hostu; starý přepínač nesmí spustit appku ani snímání.
 if CommandLine.arguments.contains(where:{$0.hasSuffix("-self-test") || $0=="--interactive-ui-tests"}){fputs("Tests run from Screenshot Note Tests.app built by build.sh.\n",stderr);exit(64)}

 // Testy a náhledy pracují s vlastním dočasným indexem.
 if CommandLine.arguments.contains(where:{($0.hasSuffix("-test") && $0 != "--preview-test") || $0=="--design-export"}){
  SessionIndex.shared=SessionIndex(file:fm.temporaryDirectory.appendingPathComponent("sn-index-"+UUID().uuidString+".json"))
  TemplateDefaults.shared=TemplateDefaults(store:UserDefaults(suiteName:"sn-test-"+UUID().uuidString)!,connection:{nil})
 }
 if let index=CommandLine.arguments.firstIndex(of:"--design-export") {
  _ = NSApplication.shared;NSApp.setActivationPolicy(.accessory);installEditingMenu()
  let path=CommandLine.arguments.count>index+1 ? CommandLine.arguments[index+1]:"/tmp/Screenshot-Note-Design"
  try exportDesignPreviews(to:URL(fileURLWithPath:path,isDirectory:true));exit(0)
 }
 let running=NSRunningApplication.runningApplications(withBundleIdentifier:"cz.janprasil.screenshotnote").filter{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier}
 if !running.isEmpty && !CommandLine.arguments.contains("--preview-test") {
  DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("cz.janprasil.screenshotnote.capture"),object:CommandLine.arguments.contains("--fullscreen") ? "full":"area",userInfo:nil,deliverImmediately:true);exit(0)
 }
 let app=NSApplication.shared;app.setActivationPolicy(.accessory)
 // NSApplication.delegate je slabý odkaz; delegát musí žít po celý běh.
 let delegate=AppDelegate();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}
 }
}
