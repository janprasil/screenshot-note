import Foundation

/// Vestavěný název relace, když uživatel ani nastavení nic neurčí.
let builtInSessionTitle = "Screenshot"

/// Stejná pravidla jako server: jeden řádek bez okrajových mezer, 1–100 znaků.
func validDefaultTitle(_ value:String)->Bool {
 value==value.trimmingCharacters(in:.whitespacesAndNewlines) && (1...100).contains(value.unicodeScalars.count) && value.utf8.count<=400
  && !value.unicodeScalars.contains{CharacterSet.controlCharacters.contains($0)}
}

/// Výchozí název relace bez názvu: složka, pak globální nastavení, pak „Screenshot“.
enum DefaultTitle {
 static let key="defaultSessionTitle"
 static let changed=Notification.Name("ScreenshotNoteDefaultTitleChanged")
 static var global:String? {
  get{UserDefaults.standard.string(forKey:key).flatMap{validDefaultTitle($0) ? $0:nil}}
  set{
   // Neplatná hodnota se ignoruje; nil vrací vestavěný název.
   if let newValue,!validDefaultTitle(newValue){return}
   let value=newValue
   guard value != global else{return}
   if let value{UserDefaults.standard.set(value,forKey:key)}else{UserDefaults.standard.removeObject(forKey:key)}
   NotificationCenter.default.post(name:changed,object:nil)
  }
 }
 static func resolve(_ topic:Topic?)->String {
  topic?.defaultTitle.flatMap{validDefaultTitle($0) ? $0:nil} ?? global ?? builtInSessionTitle
 }
 /// Název odesílaný do cloudu: zadaný, prázdný pro AI návrh, jinak výchozí.
 static func cloudTitle(_ typed:String?,topic:Topic?,allowAI:Bool)->String {
  let text=(typed ?? "").trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\n",with:" ")
  if !text.isEmpty{return text}
  return allowAI && topic?.aiTitle==true ? "":resolve(topic)
 }
}
