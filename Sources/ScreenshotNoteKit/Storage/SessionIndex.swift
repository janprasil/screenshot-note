import Foundation
import Darwin

/// Záznam o relaci, kterou aplikace zapsala do Markdownu; nahrazuje dřívější skrytý komentář.
struct SessionRecord:Codable,Equatable {
 var id:String;var file:String;var start:Int;var length:Int;var hash:String;var heading:String
 var title:String;var comment:String;var template:String;var images:[String];var notes:[String:String]
 var combined:Bool;var footer:String
 // Otisky souborů: u samostatné relace vůči jejímu adresáři, u společného souboru vůči bázi.
 var files:[String:String];var seen:Double
 var base:String? = nil;var folder:String? = nil;var owner:String? = nil;var origin:String? = nil
 // Výchozí název použitý u relace bez názvu; jeho změna vynutí nové vykreslení.
 var fallback:String? = nil
 var updated:String? = nil;var created:String? = nil;var digest:String? = nil;var shas:[String]? = nil;var note:RemoteNote? = nil;var stem:String? = nil
 var trashed:Bool? = nil;var away:String? = nil;var trashNote:String? = nil;var trashHash:String? = nil;var noticed:Bool? = nil
 // Identita adresáře a stav místního smazání.
 var inode:String? = nil;var missingSince:Double? = nil;var held:Bool? = nil;var confirmed:Bool? = nil
 // Otisk naposledy zapsané cloudové verze vedle upravené kopie.
 var cloudCopy:String? = nil
 // Šablona obrázku při zápisu (čtení popisků) a verze vykreslení cloudové relace.
 var imageTemplate:String? = nil;var imageComments:[String:String]? = nil;var render:Int? = nil
 // Relace z kořene v .trash: obrázky, které se přesunuly s ní (sdílené zůstaly v assets).
 var rootMoved:[String]? = nil
 // Sdílené obrázky zkopírované do .trash, aby se poznámka v koši zobrazila.
 var trashCopies:[String]? = nil
 // Plochá relace: Markdown kdekoli ve složce, obrázky ve společném <kořen>/assets.
 var flat:Bool? = nil
 // Revize relace na serveru pro úpravy textu (PATCH).
 var revision:String? = nil
 // Smazání z disku čeká na odpověď uživatele (Přesunout do Koše / Obnovit na disku).
 var askDelete:Bool? = nil
 // Zobrazované jméno autora pro {author}.
 var author:String? = nil;var authorID:String? = nil
 // Smazání cizí relace v týmové složce zůstalo jen na tomto Macu; znovu se neposílá.
 var keptLocal:Bool? = nil
 // Umístění podle serveru: podsložka (nil = kořen složky) a její revize.
 var subfolder:String? = nil;var location:String? = nil
 var isCloud:Bool{base != nil}
 // Cloudové relace a rozpracovaná mazání se z indexu nikdy nevyřazují.
 var pinned:Bool{isCloud || trashed==true || missingSince != nil || held==true || askDelete==true || confirmed==true}
 var directory:URL{URL(fileURLWithPath:file).deletingLastPathComponent()}
}
final class SessionIndex {
 static var shared=SessionIndex()
 private struct Store:Codable{var version=1;var records:[SessionRecord]=[];var generated:[String:String]=[:];var migrated:[String]=[];var roots:[String:String]? = nil;var subfolders:[String:SubfolderLink]? = nil}
 let file:URL
 private var loaded:Store?
 private var depth=0,dirty=false
 init(file:URL=draftRoot.deletingLastPathComponent().appendingPathComponent("Session Index.json")){self.file=file}
 // Klíč cesty: existující předek se rozřeší stejně jako hotový soubor (jinak by /private/var a /var nesouhlasily).
 static func key(_ url:URL)->String {
  let standard=url.standardizedFileURL
  if fm.fileExists(atPath:standard.path) || standard.path=="/"{return standard.resolvingSymlinksInPath().path}
  let parent=key(standard.deletingLastPathComponent())
  return (parent=="/" ? "":parent)+"/"+standard.lastPathComponent
 }
 static func key(_ path:String)->String{key(URL(fileURLWithPath:path))}
 private var store:Store {
  get {
   if let loaded{return loaded}
   var value=Store()
   if let data=try? Data(contentsOf:file) {
    // Poškozený index se odloží stranou, identitu pak doplní xattr.
    if data.count<=40000000,let decoded=try? JSONDecoder().decode(Store.self,from:data){value=decoded}
    else{try? fm.moveItem(at:file,to:file.appendingPathExtension("bad-"+String(Int(Date().timeIntervalSince1970))))}
   }
   loaded=value;return value
  }
  set{loaded=newValue;dirty=true;if depth==0{flush()}}
 }
 func batch<T>(_ body:()throws->T)rethrows->T{depth+=1;defer{depth-=1;if depth==0 && dirty{flush()}};return try body()}
 private func flush() {
  guard var value=loaded else{return}
  dirty=false
  // Index má pevný strop; nejdřív mizí místní záznamy bez souborů, pak nejstarší místní.
  func evict(_ count:Int) {
   let pinned=value.records.filter(\.pinned),local=value.records.filter{!$0.pinned}.sorted{$0.seen>$1.seen}
   value.records=pinned+local.prefix(max(0,local.count-count))
  }
  if value.records.count>20000 {
   value.records.removeAll{!$0.pinned && !fm.fileExists(atPath:$0.file)}
   if value.records.count>20000{evict(value.records.count-20000)}
  }
  var data=(try? JSONEncoder.sorted.encode(value)) ?? Data()
  while data.count>30000000,value.records.contains(where:{!$0.pinned}){evict(max(1,value.records.filter{!$0.pinned}.count/10));data=(try? JSONEncoder.sorted.encode(value)) ?? Data()}
  loaded=value
  // Chyba zápisu se hlásí; data v paměti zůstávají a zapíšou se při další změně.
  do {
   try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   guard !data.isEmpty else{throw CloudFailure.invalid}
   try data.write(to:file,options:.atomic);try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
   writeError=nil
  } catch {
   dirty=true
   let message=LF("Index relací nejde uložit (%@). Synchronizace může relace zpracovat znovu.",error.localizedDescription)
   if writeError != message{writeError=message;Self.onWriteFailure?(message)}
  }
 }
 /// Poslední chyba zápisu indexu; nil po úspěšném zápisu.
 private(set) var writeError:String?
 static var onWriteFailure:((String)->Void)?
 var all:[SessionRecord]{store.records}
 func records(file url:URL)->[SessionRecord]{let path=Self.key(url);return store.records.filter{$0.file==path}}
 func cloud(_ id:UUID,base:URL)->SessionRecord?{let lower=id.uuidString.lowercased(),path=Self.key(base);return store.records.first{$0.id==lower && $0.base==path}}
 func cloudRecords(base:URL,folder:UUID)->[SessionRecord]{let path=Self.key(base),lower=folder.uuidString.lowercased();return store.records.filter{$0.base==path && $0.folder==lower}}
 func put(_ record:SessionRecord) {
  var value=store,next=record;next.seen=Date().timeIntervalSince1970
  if let i=value.records.firstIndex(where:{$0.id==next.id && ($0.isCloud ? $0.base==next.base:$0.file==next.file && !next.isCloud)}) {
   // Beze změny se index nepřepisuje.
   var same=value.records[i];same.seen=next.seen;if same==next{return}
   value.records[i]=next
  }else{value.records.append(next)}
  store=value
 }
 func remove(_ record:SessionRecord){var value=store;value.records.removeAll{$0.id==record.id && $0.base==record.base && $0.file==record.file};store=value}
 /// Po nahrazení bloku posune záznamy za ním ve stejném souboru.
 func shift(file url:URL,after start:Int,by delta:Int) {
  guard delta != 0 else{return}
  let path=Self.key(url);var value=store
  for i in value.records.indices where value.records[i].file==path && value.records[i].start>start{value.records[i].start+=delta}
  store=value
 }
 func generated(_ url:URL)->String?{store.generated[Self.key(url)]}
 var generatedFiles:[String]{Array(store.generated.keys)}
 func setGenerated(_ url:URL,_ fingerprint:String?){var value=store;value.generated[Self.key(url)]=fingerprint;store=value}
 func root(_ url:URL)->String?{store.roots?[Self.key(url)]}
 func clearRoot(_ url:URL){var value=store;guard value.roots?[Self.key(url)] != nil else{return};value.roots?[Self.key(url)]=nil;store=value}
 func setRoot(_ url:URL,_ identity:String){var value=store;var roots=value.roots ?? [:];guard roots[Self.key(url)] != identity else{return};roots[Self.key(url)]=identity;value.roots=roots;store=value}
 /// Adresář podsložky podle ID (klíč kořen|id); identita pozná přejmenování i přesun.
 func subfolderLinks(base:URL)->[UUID:SubfolderLink]{let prefix=Self.key(base)+"|";return Dictionary((store.subfolders ?? [:]).compactMap{key,value in key.hasPrefix(prefix) ? UUID(uuidString:String(key.dropFirst(prefix.count))).map{($0,value)}:nil},uniquingKeysWith:{a,_ in a})}
 func setSubfolderLink(base:URL,_ id:UUID,_ link:SubfolderLink?){var value=store;var all=value.subfolders ?? [:];let key=Self.key(base)+"|"+id.uuidString.lowercased();guard all[key] != link else{return};all[key]=link;value.subfolders=all.isEmpty ? nil:all;store=value}
 /// Přejmenovaný adresář: cesty záznamů, vygenerovaných souborů a vnořených podsložek pod ním se přepíšou.
 func movePaths(from old:String,to new:String) {
  guard old != new else{return}
  var value=store;let prefix=old+"/"
  func moved(_ path:String)->String{path==old ? new:path.hasPrefix(prefix) ? new+path.dropFirst(old.count):path}
  for i in value.records.indices{value.records[i].file=moved(value.records[i].file);value.records[i].away=value.records[i].away.map(moved);value.records[i].trashNote=value.records[i].trashNote.map(moved)}
  value.generated=Dictionary(value.generated.map{(moved($0.key),$0.value)},uniquingKeysWith:{a,_ in a})
  if let links=value.subfolders{value.subfolders=links.mapValues{SubfolderLink(path:moved($0.path),inode:$0.inode)}}
  store=value
 }
 func isMigrated(_ url:URL)->Bool{store.migrated.contains(Self.key(url))}
 func markMigrated(_ url:URL){var value=store;let key=Self.key(url);if !value.migrated.contains(key){value.migrated.append(key);if value.migrated.count>2000{value.migrated.removeFirst()}};store=value}
}

/// Místní adresář podsložky: poslední cesta a identita.
struct SubfolderLink:Codable,Equatable{var path:String;var inode:String?}

// Sekundární identita v rozšířeném atributu; editory ho mohou zahodit.
let sessionTagName="cz.janprasil.screenshotnote.session"
func readSessionTag(_ url:URL)->String? {
 let size=getxattr(url.path,sessionTagName,nil,0,0,XATTR_NOFOLLOW)
 guard size>0,size<=65536 else{return nil}
 var buffer=[UInt8](repeating:0,count:size)
 guard getxattr(url.path,sessionTagName,&buffer,size,0,XATTR_NOFOLLOW)==size else{return nil}
 return String(bytes:buffer,encoding:.utf8)
}
func writeSessionTag(_ url:URL,_ value:String){let bytes=Array(value.utf8);guard bytes.count<=65536 else{return};_ = setxattr(url.path,sessionTagName,bytes,bytes.count,0,XATTR_NOFOLLOW)}
func removeSessionTag(_ url:URL){_ = removexattr(url.path,sessionTagName,XATTR_NOFOLLOW)}
func sessionTagIDs(_ url:URL)->[String] {
 guard let value=readSessionTag(url) else{return []}
 if value.hasPrefix("["){return (try? JSONDecoder().decode([String].self,from:Data(value.utf8))) ?? []}
 return value.isEmpty ? []:[value]
}
/// Společný soubor nese seznam ID svých relací.
func tagCombinedFile(_ url:URL) {
 let ids=SessionIndex.shared.records(file:url).sorted{$0.start<$1.start}.map(\.id)
 if let data=try? JSONEncoder().encode(ids),let text=String(data:data,encoding:.utf8){writeSessionTag(url,text)}
}

/// Čitelný název „YYYY-MM-DD Název“ podle místního data vytvoření.
func readableSessionName(_ title:String,created:Date,fallback:String?=nil)->String {
 let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone = .current;format.dateFormat="yyyy-MM-dd"
 let forbidden=CharacterSet(charactersIn:"/\\:?*\"<>|[]#^").union(.controlCharacters).union(.newlines)
 // Výchozí název prochází stejnou úpravou jako zadaný, aby nevznikla cesta ani příliš dlouhé jméno.
 func clean(_ text:String)->String {
  var safe=text.precomposedStringWithCanonicalMapping.unicodeScalars.map{forbidden.contains($0) ? "_":String($0)}.joined()
  safe=safe.split(whereSeparator:{$0==" " || $0=="\t"}).joined(separator:" ").trimmingCharacters(in:CharacterSet.whitespaces.union(CharacterSet(charactersIn:".")))
  while safe.utf8.count>120{safe.removeLast()}
  return safe
 }
 let name=[title,fallback ?? DefaultTitle.global ?? builtInSessionTitle,builtInSessionTitle].lazy.map(clean).first{!$0.isEmpty} ?? builtInSessionTitle
 return format.string(from:created)+" "+name
}
func uniqueName(_ name:String,taken:(String)->Bool)->String {
 var n=1
 while true{let candidate=n==1 ? name:name+" \(n)";if !taken(candidate){return candidate};n+=1}
}
/// Název při sloučení podsložek: obsazený dostane „ (n)“ s nejnižším volným n ≥ 1.
func mergedName(_ name:String,taken:(String)->Bool)->String {
 if !taken(name){return name}
 var n=1
 while taken(name+" (\(n))"){n+=1}
 return name+" (\(n))"
}
func parseServerDate(_ raw:String?)->Date? {
 guard var value=raw?.trimmingCharacters(in:.whitespaces),!value.isEmpty else{return nil}
 value=value.replacingOccurrences(of:" ",with:"T").replacingOccurrences(of:"\\.[0-9]+",with:"",options:.regularExpression)
 if value.range(of:"[+-][0-9]{2}$",options:.regularExpression) != nil{value+=":00"}
 let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime]
 return parser.date(from:value)
}
func firstLine(_ text:String)->String{String(text.prefix{$0 != "\n"})}
func fileHash(_ url:URL)->String?{(try? boundedData(url,max:52428800)).map(sessionFingerprint)}
/// Adresář odpovídá zapsaným souborům a nic dalšího v něm není.
func directoryUnmodified(_ directory:URL,_ files:[String:String])->Bool {
 guard !files.isEmpty,let walker=fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else{return false}
 var found=Set<String>()
 for case let url as URL in walker where (try? url.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile==true {
  found.insert(url.pathComponents.suffix(walker.level).joined(separator:"/"));if found.count>200{return false}
 }
 return found==Set(files.keys) && files.allSatisfy{fileHash(directory.appendingPathComponent($0.key))==$0.value}
}

/// Odstraní staré značky z bloků, které nikdo neupravil, a zapíše je do indexu.
func migrateLegacyMarkers(in folder:URL,skip:Set<String> = []) {
 let index=SessionIndex.shared
 guard !index.isMigrated(folder),fm.fileExists(atPath:folder.path) else{return}
 let files=((try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md" && !skip.contains($0.lastPathComponent)}
 let pattern=try! NSRegularExpression(pattern:"<!-- screenshot-note:v1 ([A-Za-z0-9+/=]+) -->\\n?")
 index.batch {
  for file in files {
   guard let data=try? boundedData(file,max:20000000),let text=String(data:data,encoding:.utf8),text.contains("<!-- screenshot-note:") else{continue}
   let ns=text as NSString
   var strips:[(NSRange,NSRange,SessionMetadata)]=[]
   for match in pattern.matches(in:text,range:NSRange(location:0,length:ns.length)) {
    guard let encoded=Data(base64Encoded:ns.substring(with:match.range(at:1))),let metadata=try? JSONDecoder().decode(SessionMetadata.self,from:encoded) else{continue}
    let prefix=ns.range(of:"<!-- screenshot-note:begin "+metadata.sessionID+" -->\n",options:.backwards,range:NSRange(location:0,length:match.range.location))
    guard prefix.location != NSNotFound,!strips.contains(where:{NSMaxRange($0.1)>prefix.location}) else{continue}
    let body=ns.substring(with:NSRange(location:NSMaxRange(prefix),length:match.range.location-NSMaxRange(prefix)))
    if sessionFingerprint(Data(body.utf8))==metadata.bodyHash{strips.append((prefix,match.range,metadata))}
   }
   guard !strips.isEmpty else{continue}
   var output="",cursor=0;var placed:[(Int,Int,SessionMetadata,String)]=[]
   for (prefix,suffix,metadata) in strips {
    output+=ns.substring(with:NSRange(location:cursor,length:prefix.location-cursor))
    let body=ns.substring(with:NSRange(location:NSMaxRange(prefix),length:suffix.location-NSMaxRange(prefix)))
    placed.append(((output as NSString).length,(body as NSString).length,metadata,body));output+=body;cursor=NSMaxRange(suffix)
   }
   output+=ns.substring(from:cursor)
   guard (try? Data(output.utf8).write(to:file,options:.atomic)) != nil else{continue}
   let total=(output as NSString).length,assets=folder.appendingPathComponent("assets")
   for (start,length,metadata,body) in placed {
    var hashes:[String:String]=[:];for image in metadata.images{hashes["assets/"+image]=fileHash(assets.appendingPathComponent(image))}
    index.put(SessionRecord(id:metadata.sessionID,file:SessionIndex.key(file),start:start,length:length,hash:metadata.bodyHash,heading:firstLine(body),title:metadata.title,comment:metadata.comment,template:metadata.template,images:metadata.images,notes:metadata.imageNotes,combined:!(start==0 && length==total),footer:"",files:hashes,seen:0))
   }
   if placed.count==1 && placed[0].0==0 && placed[0].1==total{writeSessionTag(file,placed[0].2.sessionID)}else{tagCombinedFile(file)}
  }
  index.markMigrated(folder)
 }
}
/// Svazek a inode položky; pro rozpoznání přejmenování a výměny kořene.
func itemIdentity(_ url:URL)->String? {
 guard let attributes=try? fm.attributesOfItem(atPath:url.path),let inode=attributes[.systemFileNumber] as? NSNumber else{return nil}
 let volume=(try? url.resourceValues(forKeys:[.volumeUUIDStringKey]))?.volumeUUIDString ?? (attributes[.systemNumber] as? NSNumber)?.stringValue ?? ""
 return volume+":"+inode.stringValue
}
