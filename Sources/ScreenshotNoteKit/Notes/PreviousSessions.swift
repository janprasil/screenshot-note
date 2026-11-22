import AppKit
import CryptoKit

struct PreviousSessionTarget:Codable,Equatable {
 var path:String;var start:Int;var length:Int;var original:String;var fingerprint:String
 var imported:[String:String] = [:]
 // ID relace z indexu nebo ze starého komentáře.
 var session:String? = nil
 var id:String{path+"#"+String(start)}
 var cacheKey:String{id+"@"+fingerprint}
}
struct PreviousSession {
 var target:PreviousSessionTarget;var title:String;var comment:String;var images:[String];var modified:Date;var section:Int
 var imageNotes:[String:String] = [:]
 var display:String{title+" · "+localizedImageCount(images.count)+" · "+URL(fileURLWithPath:target.path).lastPathComponent+" · "+LF("Část %ld",section)}
}
struct SessionMetadata:Codable {var title:String;var comment:String;var images:[String];var imageNotes:[String:String];var bodyLength:Int;var bodyHash:String;var sessionID:String;var template:String}
// Soubory ze složek čteme jen do pevného limitu, obří soubor se přeskočí.
func boundedData(_ url:URL,max:Int)throws->Data{
 let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
 guard values.isRegularFile==true,let size=values.fileSize,size<=max else{throw CloudFailure(L("Soubor je příliš velký nebo není běžný soubor."))}
 return try Data(contentsOf:url,options:.mappedIfSafe)
}
func sessionFingerprint(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
func previousSessions(in folder:URL,template fallback:String?=nil)throws->[PreviousSession]{
 guard fm.fileExists(atPath:folder.path) else{return []}
 let files=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey],options:[.skipsHiddenFiles]).filter{$0.pathExtension.lowercased()=="md"}
 var result:[PreviousSession]=[]
 let heading=try NSRegularExpression(pattern:"(?m)^# ([^\\n]+)\\n\\n## Screenshot\\n\\n")
 let metadataPattern=try NSRegularExpression(pattern:"<!-- screenshot-note:v1 ([A-Za-z0-9+/=]+) -->\\n?")
 let assets=folder.appendingPathComponent("assets")
 func available(_ images:[String])->Bool{!images.isEmpty && images.allSatisfy{safeAssetName($0) && fm.fileExists(atPath:assets.appendingPathComponent($0).path)}}
 for file in files{
  guard let data=try? boundedData(file,max:20000000),let text=String(data:data,encoding:.utf8) else{continue}
  let ns=text as NSString,fingerprint=sessionFingerprint(data)
  var recognized:[NSRange]=[];var known=Set<String>()
  let date=(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
  func add(_ range:NSRange,_ id:String?,_ title:String,_ comment:String,_ images:[String],_ notes:[String:String]) {
   recognized.append(range);if let id{known.insert(id)}
   result.append(PreviousSession(target:PreviousSessionTarget(path:file.path,start:range.location,length:range.length,original:ns.substring(with:range),fingerprint:fingerprint,session:id),title:title,comment:comment,images:images,modified:date,section:recognized.count,imageNotes:notes))
  }
  // Starší soubory se značkami zůstávají čitelné.
  for match in text.contains("<!-- screenshot-note:v1 ") ? metadataPattern.matches(in:text,range:NSRange(location:0,length:ns.length)):[]{
   guard let encoded=Data(base64Encoded:ns.substring(with:match.range(at:1))),let metadata=try? JSONDecoder().decode(SessionMetadata.self,from:encoded),metadata.bodyLength>=0 else{continue}
   let prefix="<!-- screenshot-note:begin "+metadata.sessionID+" -->\n"
   let prefixRange=ns.range(of:prefix,options:.backwards,range:NSRange(location:0,length:match.range.location))
   guard prefixRange.location != NSNotFound else{continue}
   let range=NSRange(location:prefixRange.location,length:NSMaxRange(match.range)-prefixRange.location)
   let body=ns.substring(with:NSRange(location:NSMaxRange(prefixRange),length:match.range.location-NSMaxRange(prefixRange)))
   var values=(metadata.title,metadata.comment,metadata.images,metadata.imageNotes)
   if sessionFingerprint(Data(body.utf8)) != metadata.bodyHash{
    guard let parsed=parsedSession(metadata.template,body) else{continue}
    values=parsed
   }
   guard available(values.2) else{continue}
   add(range,metadata.sessionID,values.0,values.1,values.2,values.3)
  }
  // Bez komentáře: nejdřív index, pak xattr.
  let records=SessionIndex.shared.records(file:file).filter{$0.trashed != true && !known.contains($0.id)}.sorted{$0.start<$1.start}
  for record in records {
   guard let (range,values)=locateSession(record,in:ns,avoid:recognized),available(values.2) else{continue}
   add(range,record.id,values.0,values.1,values.2,values.3)
  }
  let tagged=sessionTagIDs(file).filter{!known.contains($0)}
  if records.isEmpty,!tagged.isEmpty {
   let templates=[fallback,defaultMarkdownTemplate].compactMap{$0}
   let segments=sessionSegments(ns)
   if tagged.count==1,recognized.isEmpty {
    for template in templates{if let (range,values)=fuzzyBlock(template,ns,segment:NSRange(location:0,length:ns.length),anchor:nil),available(values.2){add(range,tagged[0],values.0,values.1,values.2,values.3);break}}
   } else if tagged.count==segments.count {
    for (id,segment) in zip(tagged,segments) where !recognized.contains(where:{NSIntersectionRange($0,segment).length>0}) {
     for template in templates{if let (range,values)=fuzzyBlock(template,ns,segment:segment,anchor:nil),available(values.2){add(range,id,values.0,values.1,values.2,values.3);break}}
    }
   }
  }
  let matches=heading.matches(in:text,range:NSRange(location:0,length:ns.length))
  for(i,match) in matches.enumerated(){
   if recognized.contains(where:{NSLocationInRange(match.range.location,$0)}){continue}
   let next=i+1<matches.count ? matches[i+1].range.location:ns.length
   let end=min(next,recognized.filter{$0.location>match.range.location}.map{$0.location}.min() ?? ns.length)
   var block=ns.substring(with:NSRange(location:match.range.location,length:end-match.range.location))
   if block.hasSuffix("\n\n---\n\n"){block.removeLast("\n\n---\n\n".count)}
   guard let split=block.range(of:"\n\n## (?:Komentář|Comment)\n\n",options:.regularExpression) else{continue}
   let screenshots=String(block[..<split.lowerBound]);let screenshotNS=screenshots as NSString
   let imageNames=imageLinks(screenshots).map{linkName($0,in:screenshotNS)}
   guard !imageNames.isEmpty,imageNames.allSatisfy({!$0.contains("/") && !$0.contains("\\") && fm.fileExists(atPath:assets.appendingPathComponent($0).path)}) else{continue}
   var comment=String(block[split.upperBound...]);if comment.hasSuffix("\n"){comment.removeLast()}
   let title=ns.substring(with:match.range(at:1))
   result.append(PreviousSession(target:PreviousSessionTarget(path:file.path,start:match.range.location,length:(block as NSString).length,original:block,fingerprint:fingerprint),title:title,comment:comment,images:imageNames,modified:date,section:i+1))
  }
 }
 return result.sorted{if $0.modified != $1.modified{return $0.modified>$1.modified};return $0.target.start>$1.target.start}
}
// Čte oba formáty: Obsidian ![[assets/x]] i standardní ![alt](<assets/x>) nebo ![alt](assets/x).
private let linkExpression=try! NSRegularExpression(pattern:"!\\[\\[assets/([^]\\n]+)\\]\\]|!\\[[^\\]\\n]*\\]\\(<assets/([^>\\n]+)>\\)|!\\[[^\\]\\n]*\\]\\(assets/([^)\\s]+)\\)")
func imageLinks(_ text:String)->[NSTextCheckingResult]{linkExpression.matches(in:text,range:NSRange(location:0,length:(text as NSString).length))}
/// Název obrázku z nalezeného odkazu bez ohledu na formát.
func linkName(_ match:NSTextCheckingResult,in ns:NSString)->String{for i in 1...3 where match.range(at:i).location != NSNotFound{return ns.substring(with:match.range(at:i))};return ""}
func imageLinkNames(_ text:String)->[String]{let ns=text as NSString;return imageLinks(text).map{linkName($0,in:ns)}}
func imageLinkRanges(_ name:String,in ns:NSString)->[NSRange]{imageLinks(ns as String).filter{linkName($0,in:ns)==name}.map(\.range)}
func containsImageLink(_ text:String,_ name:String)->Bool{imageLinkNames(text).contains(name)}
/// Standardní Markdown odkaz; úhlové závorky kvůli mezerám v názvu.
func imageMarkdown(_ name:String,_ number:Int)->String{"![Screenshot \(number)](<assets/\(name)>)"}
func screenshotsMarkdown(_ names:[String],_ captions:[String])->String{zip(names,captions).enumerated().map{imageMarkdown($0.element.0,$0.offset+1)+($0.element.1.isEmpty ? "":"\n\n"+$0.element.1)}.joined(separator:"\n\n")}
/// Přepíše všechny odkazy na obrázky do standardního formátu (s volitelným přejmenováním).
func rewriteImageLinks(_ text:String,order:[String],rename:[String:String]=[:])->String {
 let ns=text as NSString;var output=text
 for match in imageLinks(text).reversed() {
  let name=linkName(match,in:ns),number=(order.firstIndex(of:name) ?? 0)+1
  output=(output as NSString).replacingCharacters(in:match.range,with:imageMarkdown(rename[name] ?? name,number))
 }
 return output
}
/// Název, komentář, obrázky a popisky z bloku podle šablony.
/// comments: vykreslené komentáře obrázků cloudové relace (z popisků se vynechají).
func parsedSession(_ template:String,_ body:String,imageTemplate:String?=nil,comments:[String:String]?=nil)->(String,String,[String],[String:String])? {
 guard let values=extractTemplateValues(template,from:body),let screenshotText=values["{screenshots}"] else{return nil}
 let source=screenshotText as NSString,matches=imageLinks(screenshotText);var images:[String]=[],notes:[String:String]=[:]
 for(i,match) in matches.enumerated(){let name=linkName(match,in:source);images.append(name);let end=i+1<matches.count ? matches[i+1].range.location:source.length;let start=i>0 ? NSMaxRange(matches[i-1].range):0
  notes[name]=imageCaption(source.substring(with:NSRange(location:NSMaxRange(match.range),length:end-NSMaxRange(match.range))),before:source.substring(with:NSRange(location:start,length:match.range.location-start)),template:imageTemplate,next:i+1<matches.count ? i+2:nil,comments:comments?[name],previous:i>0 ? comments?[images[i-1]]:nil)}
 return (values["{title}"] ?? "",values["{text}"] ?? "",images,notes)
}
private let separator="\n\n---\n\n"
/// Úseky společného souboru mezi oddělovači.
func sessionSegments(_ ns:NSString)->[NSRange] {
 var result:[NSRange]=[],start=0
 while true {
  let found=ns.range(of:separator,range:NSRange(location:start,length:ns.length-start))
  if found.location==NSNotFound{result.append(NSRange(location:start,length:ns.length-start));return result}
  result.append(NSRange(location:start,length:found.location-start));start=NSMaxRange(found)
 }
}
/// Hledá blok podle šablony; začátek i konec zkouší na hranicích řádků kolem kotvy.
func fuzzyBlock(_ template:String,_ ns:NSString,segment:NSRange,anchor:Int?,footer:String="",imageTemplate:String?=nil,comments:[String:String]?=nil)->(NSRange,(String,String,[String],[String:String]))? {
 var starts:[Int]=[]
 if let anchor {
  var position=anchor
  while starts.count<40 {
   let line=ns.range(of:"\n",options:.backwards,range:NSRange(location:segment.location,length:position-segment.location))
   if line.location==NSNotFound{starts.append(segment.location);break}
   starts.append(NSMaxRange(line));position=line.location
  }
 } else {
  var position=segment.location;starts=[position]
  while starts.count<40 {
   let line=ns.range(of:"\n",range:NSRange(location:position,length:NSMaxRange(segment)-position))
   guard line.location != NSNotFound,NSMaxRange(line)<NSMaxRange(segment) else{break}
   position=NSMaxRange(line);starts.append(position)
  }
 }
 var ends:[Int]=[NSMaxRange(segment)],position=NSMaxRange(segment)
 if !footer.isEmpty,ns.substring(with:segment).hasSuffix(footer){ends.insert(NSMaxRange(segment)-(footer as NSString).length,at:0)}
 while ends.count<40,position>segment.location {
  let line=ns.range(of:"\n",options:.backwards,range:NSRange(location:segment.location,length:position-1-segment.location+1))
  guard line.location != NSNotFound,line.location>(anchor ?? segment.location) else{break}
  position=line.location;if !ends.contains(position+1){ends.append(position+1)}
 }
 for start in starts{for end in ends where end>start {
  let range=NSRange(location:start,length:end-start)
  if let values=parsedSession(template,ns.substring(with:range),imageTemplate:imageTemplate,comments:comments){return (range,values)}
 }}
 return nil
}
/// Najde blok záznamu: přesně, posunutý podle nadpisu, nebo podle nadpisu a odkazů na obrázky.
func locateSession(_ record:SessionRecord,in ns:NSString,avoid:[NSRange])->(NSRange,(String,String,[String],[String:String]))? {
 let stored=(record.title,record.comment,record.images,record.notes)
 func free(_ range:NSRange)->Bool{!avoid.contains{NSIntersectionRange($0,range).length>0 || ($0.length==0 && NSLocationInRange($0.location,range))}}
 func exact(_ start:Int)->NSRange?{
  let range=NSRange(location:start,length:record.length)
  guard start>=0,NSMaxRange(range)<=ns.length,free(range),sessionFingerprint(Data(ns.substring(with:range).utf8))==record.hash else{return nil}
  return range
 }
 if let range=exact(record.start){return (range,stored)}
 var anchors:[Int]=[]
 if !record.heading.isEmpty {
  var position=0
  while position<ns.length {
   let found=ns.range(of:record.heading,range:NSRange(location:position,length:ns.length-position))
   guard found.location != NSNotFound else{break}
   if found.location==0 || ns.character(at:found.location-1)==10{if let range=exact(found.location){return (range,stored)};anchors.append(found.location)}
   position=found.location+1
  }
 }
 if !record.combined {
  let whole=NSRange(location:0,length:ns.length)
  guard free(whole) else{return nil}
  return fuzzyBlock(record.template,ns,segment:whole,anchor:nil,footer:record.footer,imageTemplate:record.imageTemplate,comments:record.imageComments)
 }
 for image in record.images {
  anchors+=imageLinkRanges(image,in:ns).map(\.location)
 }
 let segments=sessionSegments(ns)
 for anchor in anchors {
  guard let segment=segments.first(where:{NSLocationInRange(anchor,$0)}),let found=fuzzyBlock(record.template,ns,segment:segment,anchor:anchor,footer:record.footer,imageTemplate:record.imageTemplate,comments:record.imageComments),free(found.0),
        found.1.2.contains(where:{record.images.contains($0)}) else{continue}
  return found
 }
 return nil
}
// Cloudový společný soubor ukládá obrázky do assets/<uuid relace>/N.png.
func safeAssetName(_ name:String)->Bool{!name.contains("\\") && !name.isEmpty && name != "." && name != ".." && (!name.contains("/") || name.range(of:"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{1,2}\\.png$",options:.regularExpression) != nil)}
/// Uložené relace složky včetně stažených cloudových podsložek.
func previousSessions(for topic:Topic)throws->[PreviousSession] {
 guard topic.savesLocally else{return []}
 let template=topic.markdownTemplate ?? defaultMarkdownTemplate
 if topic.cloudFolderID==nil{migrateLegacyMarkers(in:topic.destination);migrateImageLinks(in:topic.destination)}
 var result=try previousSessions(in:topic.destination,template:template)
 if topic.cloudFolderID != nil || topic.formerCloudFolderID != nil {
  let known=Set(SessionIndex.shared.all.filter{$0.trashed != true}.map{SessionIndex.key($0.directory)})
  let children=(try? fm.contentsOfDirectory(at:topic.destination,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []
  for child in children where child.lastPathComponent.range(of:"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(-[0-9a-f]{12})?$",options:.regularExpression) != nil || known.contains(SessionIndex.key(child)) || readSessionTag(child) != nil {
   result+=(try? previousSessions(in:child,template:template)) ?? []
  }
  result.sort{if $0.modified != $1.modified{return $0.modified>$1.modified};return $0.target.start>$1.target.start}
 }
 return result
}
func checkedPreviousFile(_ target:PreviousSessionTarget)throws->String{
 let data=try boundedData(URL(fileURLWithPath:target.path),max:20000000)
 guard sessionFingerprint(data)==target.fingerprint,let string=String(data:data,encoding:.utf8),target.start>=0,target.length>=0,target.start+target.length<=(string as NSString).length,(string as NSString).substring(with:NSRange(location:target.start,length:target.length))==target.original else{
  throw NSError(domain:"ScreenshotNote",code:4,userInfo:[NSLocalizedDescriptionKey:L("Původní poznámka se mezitím změnila. Otevři výběr relací a vyber relaci znovu, aby se její nové změny nepřepsaly.")])
 }
 return string
}

/// Read edited user content using the literals surrounding the template's placeholders.
// {context} bere jen řádky souhrnu kontextu, aby nespolkl obrázky ani text vedle sebe.
private let contextSummaryLine="- Screenshot [0-9]+: [^\\n]*\\]\\(<assets/[^>\\n]+\\.context\\.json>\\)"
private let contextSummaryPattern="((?:"+contextSummaryLine+"(?:\\n"+contextSummaryLine+")*)?)"
func extractTemplateValues(_ template:String,from body:String)->[String:String]?{
 // Šablona s {comments} se zkusí i ve tvaru bez komentářů (oříznutý konec).
 if template.contains("{comments}") {
  if let values=extractTemplateValues(template.replacingOccurrences(of:"{comments}",with:"\u{0}"),from:body,comments:true){return values}
  var bare=template.replacingOccurrences(of:"{comments}",with:"");while let last=bare.last,last.isWhitespace{bare.removeLast()}
  return extractTemplateValues(bare+"\n",from:body)
 }
 return extractTemplateValues(template,from:body,comments:false)
}
private func extractTemplateValues(_ template:String,from body:String,comments:Bool)->[String:String]?{
 let template=template.replacingOccurrences(of:"\u{0}",with:"{comments}")
 let expression=try! NSRegularExpression(pattern:"\\{(?:title|screenshots|text|comments|author|context|issues)\\}")
 let source=template as NSString;let matches=expression.matches(in:template,range:NSRange(location:0,length:source.length));var pattern="\\A",offset=0;var keys:[String]=[]
 for match in matches{pattern+=NSRegularExpression.escapedPattern(for:source.substring(with:NSRange(location:offset,length:match.range.location-offset)))+(source.substring(with:match.range)=="{context}" ? contextSummaryPattern:"(.*?)");keys.append(source.substring(with:match.range));offset=NSMaxRange(match.range)}
 pattern+=NSRegularExpression.escapedPattern(for:source.substring(from:offset));if !template.hasSuffix("\n"){pattern+="\\n"};pattern+="\\z"
 guard let regex=try? NSRegularExpression(pattern:pattern,options:[.dotMatchesLineSeparators]),let match=regex.firstMatch(in:body,range:NSRange(location:0,length:(body as NSString).length)) else{return nil}
 var values:[String:String]=[:];let ns=body as NSString
 for(i,key) in keys.enumerated(){let value=ns.substring(with:match.range(at:i+1));if let existing=values[key],existing != value{return nil};values[key]=value}
 return values
}

/// Open an exported session without taking a new screenshot or touching its original assets.
func workingDraft(from session:PreviousSession,topic:Topic,root:URL,queuedEdit:(UUID)->CloudLibrary.CloudEdit.Fields? = {CloudLibrary.shared.queuedEdit($0)})throws->Draft{
 _ = try checkedPreviousFile(session.target)
 let assets=URL(fileURLWithPath:session.target.path).deletingLastPathComponent().appendingPathComponent("assets")
 var target=session.target;target.imported=[:];var images:[String]=[];var notes:[String:String]=[:];var contexts:[String:String]=[:]
 do{
  for image in session.images{
   let name=UUID().uuidString+".png"
   let destination=root.appendingPathComponent(name);try fm.copyItem(at:assets.appendingPathComponent(image),to:destination);images.append(name)
   try copyAnnotationSidecar(from:assets.appendingPathComponent(image),to:destination);target.imported[name]=image;notes[name]=session.imageNotes[image]
   if try importAssetContext(assets:assets,image:image,to:destination){contexts[name]=name+".context.json"}
  }
 }catch{for name in images{removeAnnotatedImage(root.appendingPathComponent(name))};throw error}
 var draft=Draft(images:images,comment:session.comment,title:session.title,topic:topic,previous:target,imageNotes:notes)
 if !contexts.isEmpty{draft.contexts=contexts}
 if topic.cloudFolderID != nil {
  // Cloudová relace: escapovaný text ze serveru se vrátí do původní podoby.
  draft.title=unescapeServerMarkdown(session.title);draft.comment=unescapeServerMarkdown(session.comment);draft.imageNotes=notes.mapValues(unescapeServerMarkdown)
  // Čekající úprava textu se zobrazí místo stažené verze, aby se druhou úpravou neztratila.
  if let id=target.session.flatMap(UUID.init(uuidString:)),let queued=queuedEdit(id),queued.captions.count==images.count {
   draft.title=queued.title;draft.comment=queued.comment;draft.cloudBase=queued
   for (name,caption) in zip(images,queued.captions){draft.imageNotes?[name]=caption.isEmpty ? nil:caption}
  }
 }
 return draft
}

/// Stav rozpracované relace navázané na uloženou: platná (případně s novou cestou), nebo zaniklá.
enum DraftTarget{case current(Draft),stale(String)}
/// Ověří cíl rozpracované relace přes index; po migraci cestu opraví, smazanou relaci nikdy znovu neotevře.
func resolveDraftTarget(_ draft:Draft,folders:CloudFolders = .shared)->DraftTarget {
 guard let previous=draft.previous,let topic=draft.topic else{return .current(draft)}
 let trimmed=draft.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "",title=trimmed.isEmpty ? "Screenshot":trimmed
 var current=topic
 if let folder=topic.cloudFolderID {
  // Cloudová relace musí v indexu existovat, nebýt v koši ani smazaná z disku.
  guard let live=folders.topics.first(where:{$0.cloudFolderID==folder && $0.cloudOwnerID==topic.cloudOwnerID}) ?? folders.allTopics.first(where:{$0.cloudFolderID==folder}),!live.folder.isEmpty,let base=try? Topics.checkedDestination(live.folder) else{return .stale(title)}
  current=live
  if let session=previous.session {
   guard let id=UUID(uuidString:session),let record=SessionIndex.shared.cloud(id,base:base),record.trashed != true,record.askDelete != true,record.missingSince==nil,record.held != true,fm.fileExists(atPath:record.file) else{return .stale(title)}
  }
 }
 if fm.fileExists(atPath:previous.path),(try? checkedPreviousFile(previous)) != nil{return .current(draft)}
 // Soubor se přesunul nebo změnil (migrace): relace se najde znovu podle ID.
 guard let session=previous.session,let found=(try? previousSessions(for:current))?.first(where:{$0.target.session?.lowercased()==session.lowercased()}) else{return .stale(title)}
 let old=imageLinkNames(previous.original)
 var mapping:[String:String]=[:];for (name,next) in zip(old,found.images){mapping[name]=next}
 var target=found.target;target.imported=previous.imported.mapValues{mapping[$0] ?? $0}
 var next=draft;next.previous=target;next.topic=current
 return .current(next)
}
/// Rozpracovaná relace ve skryté týmové složce (ztráta přístupu) přejde do výchozí složky s upozorněním.
func fallbackFromHiddenFolder(_ draft:Draft,folders:CloudFolders = .shared,defaultTopic:@autoclosure ()->Topic = Topics.defaultTopic)->Draft? {
 guard let topic=draft.topic,topic.cloudFolderID != nil,folders.isUnavailable(topic) else{return nil}
 var next=draft;next.topic=defaultTopic();next.previous=nil
 folders.notify(LF("Složka %@ už není dostupná. Rozpracovaná relace se uloží do výchozí složky %@.",topic.displayName,next.topic!.displayName))
 return next
}
/// Volba u zaniklé relace: uložit jako novou (bez vazby), nebo zahodit rozpracované změny.
func applyStaleChoice(_ draft:Draft,keep:Bool,root:URL)throws->Draft {
 if keep{var next=draft;next.previous=nil;try stage(next,root:root);return next}
 clearDraft(draft,root:root);return Draft(images:[],comment:"",topic:draft.topic.flatMap{$0.cloudFolderID == nil ? $0:nil})
}
/// Jednorázově přepíše odkazy ![[assets/…]] na standardní Markdown v souborech aplikace, které nikdo neupravil.
func migrateImageLinks(in folder:URL) {
 let index=SessionIndex.shared
 let files=((try? fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md"}
 index.batch {
  for file in files {
   guard let data=try? boundedData(file,max:20000000),let text=String(data:data,encoding:.utf8),text.contains("![[assets/") else{continue}
   let ns=text as NSString,records=index.records(file:file).filter{$0.trashed != true}.sorted{$0.start<$1.start}
   // Jen soubor, jehož všechny bloky přesně odpovídají indexu; upravený zůstává beze změny.
   guard !records.isEmpty,records.allSatisfy({($0.combined || ($0.start==0 && $0.length==ns.length)) && $0.start>=0 && $0.start+$0.length<=ns.length && sessionFingerprint(Data(ns.substring(with:NSRange(location:$0.start,length:$0.length)).utf8))==$0.hash}) else{continue}
   var output="",cursor=0,placed:[(SessionRecord,Int,String)]=[]
   for record in records where record.start>=cursor {
    output+=ns.substring(with:NSRange(location:cursor,length:record.start-cursor))
    let block=rewriteImageLinks(ns.substring(with:NSRange(location:record.start,length:record.length)),order:record.images)
    placed.append((record,(output as NSString).length,block));output+=block;cursor=record.start+record.length
   }
   output+=ns.substring(from:cursor)
   guard output != text,(try? Data(output.utf8).write(to:file,options:.atomic)) != nil else{continue}
   let old=sessionFingerprint(data),new=sessionFingerprint(Data(output.utf8))
   if index.generated(file)==old{index.setGenerated(file,new)}
   for (record,start,block) in placed {
    var next=record;next.start=start;next.length=(block as NSString).length;next.hash=sessionFingerprint(Data(block.utf8));next.heading=firstLine(block)
    if next.files[file.lastPathComponent] != nil{next.files[file.lastPathComponent]=new}
    index.put(next)
   }
   if placed.count==1 && !placed[0].0.combined{writeSessionTag(file,placed[0].0.id)}else{tagCombinedFile(file)}
  }
 }
}
