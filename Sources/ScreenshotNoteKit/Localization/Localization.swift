import Foundation

enum AppLanguage {
 // Used only by regression tests and reproducible design previews.
 static var override:String?
 static func resolve(_ preferences:[String])->String {
  for preference in preferences {let base=preference.lowercased().replacingOccurrences(of:"_",with:"-").split(separator:"-").first.map(String.init);if base=="cs" || base=="en"{return base!}}
  return "en"
 }
 static var current:String{override ?? resolve(Locale.preferredLanguages)}
 static func bundle(_ language:String)->Bundle?{guard let path=Bundle.main.path(forResource:language,ofType:"lproj") else{return nil};return Bundle(path:path)}
}
func L(_ key:String)->String {AppLanguage.bundle(AppLanguage.current)?.localizedString(forKey:key,value:key,table:nil) ?? key}
func LF(_ key:String,_ arguments:CVarArg...)->String{String(format:L(key),locale:Locale(identifier:AppLanguage.current),arguments:arguments)}
/// Český plurál podle počtu (1 / 2–4 / ostatní); anglický katalog má pro 2–4 stejný text jako pro ostatní.
func LP(_ count:Int,_ one:String,_ few:String,_ many:String,_ arguments:CVarArg...)->String {
 let key=count==1 ? one:((2...4).contains(count) ? few:many)
 return String(format:L(key),locale:Locale(identifier:AppLanguage.current),arguments:arguments)
}
func localizedImageCount(_ count:Int)->String{if AppLanguage.current=="cs"{return LF(count==1 ? "%ld snímek":((2...4).contains(count) ? "%ld snímky":"%ld snímků"),count)};return LF(count==1 ? "%ld snímek":"%ld snímků",count)}
