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
 var commentTemplate:String? = nil;var imageTemplate:String? = nil
 // Server zná šablony položek; jinak se neposílají.
 var itemTemplates:Bool? = nil
 // Složka zmizela z webu a čeká na rozhodnutí uživatele.
 var remoteDeleted:Bool? = nil
 // Místní nastavení Macu, na server se neposílá.
 var confirmLocalDeletes:Bool? = nil
 // Přihlášený uživatel; owner je library (uživatel nebo tým). Starší záznamy mají account = owner.
 var accountID:UUID? = nil
 var ownerKind:String? = nil;var ownerName:String? = nil;var role:String? = nil
 // Tým zmizel z /me: složka je skrytá, mapování a soubory zůstávají.
 var unavailable:Bool? = nil
 // AI návrh názvu relace bez názvu; nastavení je na serveru, starší server ho neposílá.
 var aiTitle:Bool? = nil
 // Výchozí název relace ze serveru; nil = dědí z účtu.
 var defaultTitle:String? = nil
 var account:UUID{accountID ?? owner}
 var isTeam:Bool{owner != account || ownerKind==LibraryKind.team.rawValue}
 enum CodingKeys:String,CodingKey{case id,name,owner,origin,folder,migratedLocalIDs,revision,description,combined,combinedFile,markdownTemplate,combinedTemplate,commentTemplate,imageTemplate,itemTemplates,remoteDeleted,confirmLocalDeletes,ownerKind,ownerName,role,unavailable,aiTitle,defaultTitle;case accountID="account"}
 var topic:Topic {
  var value=Topic(id:"cloud:"+origin+":"+owner.uuidString+":"+id.uuidString,name:name,detail:description ?? "",folder:folder,combined:combined ?? false,combinedFile:combinedFile.flatMap{$0.isEmpty ? nil:$0} ?? defaultCombinedFile,markdownTemplate:markdownTemplate,cloudFolderID:id,cloudOwnerID:owner,cloudOrigin:origin,combinedTemplate:combinedTemplate);value.confirmLocalDeletes=confirmLocalDeletes;value.commentTemplate=commentTemplate;value.imageTemplate=imageTemplate
  value.aiTitle=aiTitle;value.defaultTitle=defaultTitle
  if isTeam{value.cloudTeam=true;value.cloudOwnerName=ownerName;value.cloudRole=role}
  return value
 }
}

/// Autor relace; `id` je null u smazaného uživatele.
struct CloudAuthor:Codable,Equatable{let id:UUID?;let name:String?}

struct RemoteNote:Codable,Equatable {
 let id:UUID;let title:String;let comment:String;let template:String;let captions:[String]
 struct Image:Codable,Equatable{
  let index:Int;let path:String
  /// Přílohy kontextu z prohlížeče; prázdný seznam je nil, aby se otisk relací bez kontextu nezměnil.
  /// media: video {duration_ms,width,height}, snímek {timestamp_ms}; kontext ho nemá.
  struct Attachment:Codable,Equatable{
   struct Media:Codable,Equatable{var duration_ms:Int?=nil;var width:Int?=nil;var height:Int?=nil;var timestamp_ms:Int?=nil;var started_at_ms:Int64?=nil}
   let kind:String;let bytes:Int;let sha256:String;let path:String;var media:Media?=nil
  }
  var attachments:[Attachment]? = nil
 }
 var images:[Image]
 // Komentáře z detailu; prázdný seznam je nil, aby se otisk starších relací nezměnil.
 // image_index: komentář obrázku (1-based), nil = celá relace; starší server pole neposílá.
 struct Comment:Codable,Equatable{let author_name:String?;let body:String;let created_at:String?;var image_index:Int? = nil}
 var comments:[Comment]? = nil
 // Starší server autora neposílá; nil nemění otisk relace.
 var author:CloudAuthor? = nil
 /// Odkaz na issue pro {issues}; label počítá server.
 struct Issue:Codable,Equatable{let url:String;let label:String;let title:String?}
 // Šablony položek ze složky (nil = vestavěná) a odkazy; starší server je neposílá.
 var comment_template:String? = nil;var image_template:String? = nil;var issues:[Issue]? = nil
}

/// Revize jako řetězec, i když ji server pošle jako číslo.
struct FlexibleString:Decodable {
 let value:String
 init(from decoder:Decoder)throws{let c=try decoder.singleValueContainer();if let text=try? c.decode(String.self){value=text}else{value=String(try c.decode(Int64.self))}}
}

/// Markdown cloudové relace bez skrytých značek; obrázky podle zadaných názvů v assets/.
/// Vykreslení je stejné jako webový export (lib/markdown.ts), navíc s kontextem z prohlížeče.
/// assets: s ním se video, které se teď nestáhlo (video.keep), vykreslí jen při existujícím místním MP4.
func cloudSessionBody(_ note:RemoteNote,images names:[String],contexts:[Int:[String:Data]]=[:],assets:URL?=nil,language:String=AppLanguage.current,timeZone:TimeZone = .current,fallbackTitle:String?=nil)->String {
 let comments=(note.comments ?? []).map{RemoteNote.Comment(author_name:$0.author_name.map(serverTitle),body:escapeServerMarkdown($0.body),created_at:$0.created_at,image_index:$0.image_index)}
 func list(_ items:[RemoteNote.Comment])->String{renderCommentList(items,template:note.comment_template,language:language,timeZone:timeZone)}
 // Stažený kontext dostane stejný callout s odkazy do assets/ jako lokální export.
 var items:[(number:Int,summary:ContextSummary,base:String,har:Bool)]=[]
 let blocks=zip(names,note.captions.map(escapeServerMarkdown)).enumerated().map{(offset,pair)->ImageBlock in
  var block=ImageBlock(name:pair.0,caption:pair.1,comments:list(comments.filter{$0.image_index==offset+1}))
  // Video se staženými metadaty (video.json z contextAttachments nebo z disku).
  let kept=contexts[offset+1]?["video.keep"] != nil && assets.map{fm.fileExists(atPath:assetVideoFiles($0,pair.0)[0].path)} == true
  if contexts[offset+1]?["video"] != nil || kept,let json=contexts[offset+1]?["video.json"],let info=try? JSONDecoder().decode(VideoInfo.self,from:json){block.videoMs=info.durationMs}
  if let side=contexts[offset+1],let data=side["context"],let summary=ContextSummary(data) {
   let base=(pair.0 as NSString).deletingPathExtension,har=side["har"] != nil
   block.context=contextCallout(summary,base:base,har:har);items.append((offset+1,summary,base,har))
  }
  return block
 }
 // Komentář obrázku mimo rozsah obrázků (starší data) zůstane u relace.
 let sessionComments=list(comments.filter{($0.image_index ?? 0)<1 || ($0.image_index ?? 0)>names.count})
 return renderSessionTemplate(note.template,title:serverTitle(note.title.isEmpty ? (fallbackTitle ?? DefaultTitle.global ?? builtInSessionTitle):note.title),screenshots:renderImageBlocks(blocks,template:note.image_template),text:escapeServerMarkdown(note.comment),
  comments:sessionComments,author:serverTitle(note.author?.name ?? ""),context:sessionContextMarkdown(items),issues:renderIssueList(note.issues ?? []))
}

/// Kontext uložený v assets/ podle čísla snímku (pro společný soubor, kde se skládá z disku).
func diskContexts(_ names:[String],assets:URL)->[Int:[String:Data]] {
 var result:[Int:[String:Data]]=[:]
 for (offset,name) in names.enumerated() {
  let files=assetContextFiles(assets,name),video=assetVideoFiles(assets,name)
  // Video jen jako značka s metadaty; MP4 se do paměti nečte.
  if fm.fileExists(atPath:video[0].path),let info=readVideoInfo(video[1]),let json=try? JSONEncoder().encode(info){result[offset+1,default:[:]]["video"]=Data();result[offset+1,default:[:]]["video.json"]=json}
  guard let context=try? boundedData(files[0],max:maxContextBytes) else{continue}
  result[offset+1,default:[:]].merge(["context":context].merging((try? boundedData(files[1],max:maxContextBytes)).map{["har":$0]} ?? [:]){a,_ in a}){a,_ in a}
 }
 return result
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
