import AppKit
import CryptoKit

let defaultCombinedTemplate="# {folderName}\n\n{folderDescription}\n\n{sessions}\n"

var defaultCombinedFile:String{AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md"}

struct CloudFolderRecord:Codable {
 let id:UUID;var name:String;let owner:UUID;let origin:String
 var folder:String=""
 var migratedLocalIDs:[String]? = nil
 // Nastavení ze serveru; starší soubory je nemají.
 var revision:String? = nil;var description:String? = nil;var combined:Bool? = nil;var combinedFile:String? = nil
 var markdownTemplate:String? = nil;var combinedTemplate:String? = nil
 // Složka zmizela z webu a čeká na rozhodnutí uživatele.
 var remoteDeleted:Bool? = nil
 // Místní nastavení Macu, na server se neposílá.
 var confirmLocalDeletes:Bool? = nil
 // Přihlášený uživatel; owner je library (uživatel nebo tým). Starší záznamy mají account = owner.
 var accountID:UUID? = nil
 var ownerKind:String? = nil;var ownerName:String? = nil;var role:String? = nil
 // Tým zmizel z /me: složka je skrytá, mapování a soubory zůstávají.
 var unavailable:Bool? = nil
 var account:UUID{accountID ?? owner}
 var isTeam:Bool{owner != account || ownerKind==LibraryKind.team.rawValue}
 enum CodingKeys:String,CodingKey{case id,name,owner,origin,folder,migratedLocalIDs,revision,description,combined,combinedFile,markdownTemplate,combinedTemplate,remoteDeleted,confirmLocalDeletes,ownerKind,ownerName,role,unavailable;case accountID="account"}
 var topic:Topic {
  var value=Topic(id:"cloud:"+origin+":"+owner.uuidString+":"+id.uuidString,name:name,detail:description ?? "",folder:folder,combined:combined ?? false,combinedFile:combinedFile.flatMap{$0.isEmpty ? nil:$0} ?? defaultCombinedFile,markdownTemplate:markdownTemplate,cloudFolderID:id,cloudOwnerID:owner,cloudOrigin:origin,combinedTemplate:combinedTemplate);value.confirmLocalDeletes=confirmLocalDeletes
  if isTeam{value.cloudTeam=true;value.cloudOwnerName=ownerName;value.cloudRole=role}
  return value
 }
}

/// Autor relace; `id` je null u smazaného uživatele.
struct CloudAuthor:Codable,Equatable{let id:UUID?;let name:String?}

struct RemoteNote:Codable,Equatable {
 let id:UUID;let title:String;let comment:String;let template:String;let captions:[String]
 struct Image:Codable,Equatable{let index:Int;let path:String}
 let images:[Image]
 // Komentáře z detailu; prázdný seznam je nil, aby se otisk starších relací nezměnil.
 struct Comment:Codable,Equatable{let author_name:String?;let body:String;let created_at:String?}
 var comments:[Comment]? = nil
 // Starší server autora neposílá; nil nemění otisk relace.
 var author:CloudAuthor? = nil
}

/// Revize jako řetězec, i když ji server pošle jako číslo.
struct FlexibleString:Decodable {
 let value:String
 init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if let text=try? c.decode(String.self){value=text}else{value=String(try c.decode(Int64.self))}}
}

/// Markdown cloudové relace bez skrytých značek; obrázky podle zadaných názvů v assets/.
func cloudSessionBody(_ note:RemoteNote,images names:[String])->String {
 let screenshots=screenshotsMarkdown(names,note.captions.map(escapeServerMarkdown))
 let comments=(note.comments ?? []).map{RemoteNote.Comment(author_name:$0.author_name.map(serverTitle),body:escapeServerMarkdown($0.body),created_at:$0.created_at)}
  return renderSessionTemplate(note.template,title:serverTitle(note.title),screenshots:screenshots,text:escapeServerMarkdown(note.comment),comments:renderComments(comments),author:serverTitle(note.author?.name ?? ""))
}

/// Tělo a metadata starého staženého souboru se značkami.
func legacyCloudBody(_ text:String)->(String,SessionMetadata)? {
 let expression=try! NSRegularExpression(pattern:"\\A<!-- screenshot-note:begin [^ \\n]+ -->\\n([\\s\\S]*)<!-- screenshot-note:v1 ([A-Za-z0-9+/=]+) -->\\n?")
 let ns=text as NSString
 guard let match=expression.firstMatch(in:text,range:NSRange(location:0,length:ns.length)),let encoded=Data(base64Encoded:ns.substring(with:match.range(at:2))),
       let metadata=try? JSONDecoder().decode(SessionMetadata.self,from:encoded) else{return nil}
 return (ns.substring(with:match.range(at:1)),metadata)
}

/// ID cloudové relace ze začátku uloženého bloku.
func cloudSessionID(_ original:String)->UUID? {
 let prefix="<!-- screenshot-note:begin "
 guard original.hasPrefix(prefix) else{return nil}
 return UUID(uuidString:String(original.dropFirst(prefix.count).prefix(36)))
}

/// Zapíše vygenerovanou kopii (_cloud, _template); ručně upravený soubor se nepřepíše a kopie dostane další volný název.
@discardableResult func writeGeneratedCopy(_ data:Data,to url:URL)throws->URL {
 let index=SessionIndex.shared,hash=sessionFingerprint(data),parent=url.deletingLastPathComponent(),ext=url.pathExtension
 let stem=uniqueName(url.deletingPathExtension().lastPathComponent){candidate in
  let file=parent.appendingPathComponent(candidate+"."+ext)
  guard let current=fileHash(file) else{return false}
  return current != hash && current != index.generated(file)
 }
 let target=parent.appendingPathComponent(stem+"."+ext)
 if fileHash(target) != hash{try data.write(to:target,options:.atomic)}
 index.setGenerated(target,hash);return target
}

func validCombinedFile(_ name:String)->Bool{!name.isEmpty && URL(fileURLWithPath:name).lastPathComponent==name && !name.hasPrefix(".") && name.lowercased().hasSuffix(".md") && !name.contains("\0") && name.utf8.count<=200}

func renderCombinedTemplate(_ template:String,folderName:String,folderDescription:String,sessions:String)->String {
 let values=["{folderName}":folderName,"{folderDescription}":folderDescription,"{sessions}":sessions]
 let expression=try! NSRegularExpression(pattern:"\\{(?:folderName|folderDescription|sessions)\\}")
 let source=template as NSString;var output=template
 for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[source.substring(with:match.range)]!)}
 return output.hasSuffix("\n") ? output:output+"\n"
}

extension JSONEncoder{static var sorted:JSONEncoder{let value=JSONEncoder();value.outputFormatting = .sortedKeys;return value}}

extension Notification.Name{static let cloudFoldersChanged=Notification.Name("ScreenshotNoteCloudFoldersChanged")}
