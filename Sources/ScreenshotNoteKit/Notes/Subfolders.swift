import AppKit

/// Podsložka cloudové složky ze serveru; parent nil = první úroveň, nejvýš dvě úrovně.
struct CloudSubfolder:Codable,Equatable{let id:UUID;var parent:UUID?;var name:String;var revision:String}

/// Podsložka v odpovědi API (revize jako řetězec nebo číslo).
struct RemoteSubfolder:Decodable {
 let id:UUID;let parent_id:UUID?;let name:String;let revision:FlexibleString
 var value:CloudSubfolder{CloudSubfolder(id:id,parent:parent_id,name:name,revision:revision.value)}
}

let maxSubfolders=500

/// Pravidla názvu stejná jako na serveru (web/lib/subfolder-model.ts).
/// Vstup od uživatele se před kontrolou převede do NFC a ořízne.
func cleanSubfolderName(_ value:String)->String{value.precomposedStringWithCanonicalMapping.trimmingCharacters(in:.whitespacesAndNewlines)}
func validSubfolderName(_ name:String)->Bool {
 let forbidden=CharacterSet(charactersIn:"/\\:*?\"<>|").union(.controlCharacters)
 return (1...100).contains(name.unicodeScalars.count) && name.utf8.count<=255 && name.unicodeScalars.elementsEqual(name.precomposedStringWithCanonicalMapping.unicodeScalars)
  && !name.hasPrefix(" ") && !name.hasSuffix(" ") && !name.unicodeScalars.contains(where:{forbidden.contains($0)})
  && !name.hasPrefix(".") && name.lowercased() != "assets"
}
/// Porovnání názvů jako výchozí svazek macOS (bez ohledu na velikost písmen a skládání znaků).
func subfolderNameKey(_ name:String)->String{name.precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:nil)}

/// Platná část stromu: známý rodič první úrovně, platné a v rodiči unikátní názvy; zbytek se zahodí.
func validSubfolderTree(_ list:[CloudSubfolder])->[CloudSubfolder] {
 var seen=Set<UUID>(),names=Set<String>(),result:[CloudSubfolder]=[]
 let top=list.filter{$0.parent==nil},firstLevel=Set(top.map(\.id))
 for item in top+list.filter({$0.parent != nil}) where result.count<maxSubfolders && !seen.contains(item.id) && validSubfolderName(item.name) && (item.parent==nil || (firstLevel.contains(item.parent!) && seen.contains(item.parent!))) {
  let key=(item.parent?.uuidString ?? "")+"/"+subfolderNameKey(item.name)
  guard !names.contains(key),item.revision.count<=40 else{continue}
  seen.insert(item.id);names.insert(key);result.append(item)
 }
 return result
}
/// Strom v pořadí zobrazení: první úroveň podle názvu, pod každou její děti.
func orderedSubfolders(_ list:[CloudSubfolder])->[(CloudSubfolder,Int)] {
 func sorted(_ items:[CloudSubfolder])->[CloudSubfolder]{items.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}}
 return sorted(list.filter{$0.parent==nil}).flatMap{top in [(top,0)]+sorted(list.filter{$0.parent==top.id}).map{($0,1)}}
}

/// Volba podsložky pro snímání: klíč je ID (cloud) nebo relativní cesta (místní složka).
struct SubfolderChoice:Equatable{let key:String;let name:String;let depth:Int;let parent:String?}

/// Místní podsložky do hloubky 2 (bez assets a skrytých položek).
func localSubfolders(_ base:URL)->[SubfolderChoice] {
 func children(_ url:URL)->[URL] {
  let list=(try? fm.contentsOfDirectory(at:url,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:[.skipsHiddenFiles])) ?? []
  return list.filter{child in let values=try? child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]);return values?.isDirectory==true && values?.isSymbolicLink != true && validSubfolderName(child.lastPathComponent) && !child.lastPathComponent.hasSuffix(".frames")}
   .sorted{$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}
 }
 var result:[SubfolderChoice]=[]
 for top in children(base).prefix(maxSubfolders) {
  result.append(SubfolderChoice(key:top.lastPathComponent,name:top.lastPathComponent,depth:0,parent:nil))
  for child in children(top).prefix(maxSubfolders){result.append(SubfolderChoice(key:top.lastPathComponent+"/"+child.lastPathComponent,name:child.lastPathComponent,depth:1,parent:top.lastPathComponent))}
 }
 return Array(result.prefix(maxSubfolders))
}

/// Podsložky složky pro výběr ve snímání.
func subfolderChoices(_ topic:Topic)->[SubfolderChoice] {
 if topic.cloudFolderID != nil{return orderedSubfolders(topic.subfolders ?? []).map{SubfolderChoice(key:$0.0.id.uuidString.lowercased(),name:$0.0.name,depth:$0.1,parent:$0.0.parent?.uuidString.lowercased())}}
 guard topic.savesLocally,!topic.folder.isEmpty,let base=try? Topics.checkedDestination(topic.folder) else{return []}
 return localSubfolders(base)
}

/// Čitelná cesta podsložky „Rodič › Dítě“; neznámý klíč je nil.
func subfolderPath(_ key:String?,in topic:Topic)->String? {
 guard let key,let choice=subfolderChoices(topic).first(where:{$0.key==key}) else{return nil}
 let parent=choice.parent.flatMap{p in subfolderChoices(topic).first{$0.key==p}?.name}
 return [parent,choice.name].compactMap{$0}.joined(separator:" › ")
}

/// Relativní cesta místní podsložky: jen platné názvy, nejvýš dvě úrovně, bez `..`.
func validLocalSubfolderPath(_ path:String)->Bool {
 let parts=path.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
 return (1...2).contains(parts.count) && parts.allSatisfy(validSubfolderName)
}

/// Adresář, kam se uloží nová relace místní složky; podsložka se v případě potřeby vytvoří.
func localSubfolderDirectory(_ topic:Topic,_ key:String?)throws->URL {
 guard let key,topic.cloudFolderID==nil else{return topic.destination}
 guard validLocalSubfolderPath(key) else{throw CloudFailure(L("Neplatný název podsložky."))}
 let url=topic.destination.appendingPathComponent(key,isDirectory:true)
 try fm.createDirectory(at:url,withIntermediateDirectories:true)
 return url
}

/// Naposledy zvolená podsložka podle složky.
enum LastSubfolder {
 static let key="lastSubfolder"
 static func get(_ topic:Topic)->String?{(UserDefaults.standard.dictionary(forKey:key) as? [String:String])?[topic.id]}
 static func set(_ topic:Topic,_ value:String?) {
  guard !isExportingDesign else{return}
  var all=(UserDefaults.standard.dictionary(forKey:key) as? [String:String]) ?? [:];all[topic.id]=value
  UserDefaults.standard.set(all,forKey:key)
 }
}
