import AppKit
import CoreGraphics
import Darwin

struct Draft: Codable { var images: [String]; var comment: String; var title: String? = nil; var topic:Topic? = nil; var previous:PreviousSessionTarget? = nil; var imageNotes:[String:String]? = nil
 // Texty čekající cloudové úpravy, ze kterých koncept vznikl; nová úprava se na ně položí.
 var cloudBase:CloudLibrary.CloudEdit.Fields? = nil
}
/// Otisk obsahu konceptu (text, popisky a bajty snímků) pro zjištění neuložené práce.
func draftSignature(_ draft:Draft,root:URL)->String {
 var parts=[draft.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "",draft.comment]
 for image in draft.images{parts.append(draft.imageNotes?[image] ?? "");parts.append(fileHash(root.appendingPathComponent(image)) ?? image)}
 return sessionFingerprint(Data(parts.joined(separator:"\u{0}").utf8))
}
let recoveryRoot = draftRoot.deletingLastPathComponent().appendingPathComponent("Draft Recovery", isDirectory: true)
/// Text ze serveru nesmí v Markdownu vytvořit obrázek ani oddělovač relací.
/// Escapování je vratné: před `[` za `!` a před `---` na samostatném řádku přibude vždy jedno zpětné lomítko.
func escapeServerMarkdown(_ text:String)->String {
 text.replacingOccurrences(of:"!(\\\\*)\\[",with:"!$1\\\\[",options:.regularExpression)
  .replacingOccurrences(of:"(?m)^(\\\\*)(---[ \\t]*)$",with:"$1\\\\$2",options:.regularExpression)
}
func unescapeServerMarkdown(_ text:String)->String {
 text.replacingOccurrences(of:"!(\\\\*)\\\\\\[",with:"!$1[",options:.regularExpression)
  .replacingOccurrences(of:"(?m)^(\\\\*)\\\\(---[ \\t]*)$",with:"$1$2",options:.regularExpression)
}
/// Název ze serveru je vždy jeden řádek a nevloží obrázek.
func serverTitle(_ title:String)->String {
 escapeServerMarkdown(title.replacingOccurrences(of:"\r\n",with:" ").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" "))
}
let fm = FileManager.default
let draftRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screenshot Note/Draft", isDirectory: true)
var destination: URL { URL(fileURLWithPath: UserDefaults.standard.string(forKey:"destination") ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshot Note").path, isDirectory:true) }
func readDraft(_ root: URL) throws -> Draft {
 let file = root.appendingPathComponent("draft.json")
 guard fm.fileExists(atPath:file.path) else { return Draft(images:[], comment:"") }
 let draft = try JSONDecoder().decode(Draft.self, from:Data(contentsOf:file))
 guard draft.images.allSatisfy({ !$0.contains("/") && fm.fileExists(atPath:root.appendingPathComponent($0).path) }) else {
  throw NSError(domain:"ScreenshotNote", code:1, userInfo:[NSLocalizedDescriptionKey:L("Rozpracovaný záznam má chybějící snímky.")])
 }
 return draft
}
func stage(_ draft: Draft, root: URL) throws {
 try JSONEncoder().encode(draft).write(to:root.appendingPathComponent("draft.json"), options:.atomic)
}
func filenameFromTitle(_ title:String?) -> String? {
 guard let title=title?.trimmingCharacters(in:.whitespacesAndNewlines),!title.isEmpty else{return nil}
 let plain=title.folding(options:.diacriticInsensitive,locale:Locale(identifier:"cs_CZ"))
 let forbidden=CharacterSet(charactersIn:"/\\:?*\"<>|[]#^").union(.controlCharacters)
 var safe=plain.unicodeScalars.map{forbidden.contains($0) ? "_":String($0)}.joined().trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:".")))
 while safe.utf8.count>180 {safe.removeLast()}
 return safe.isEmpty ? nil:safe
}
func availableFile(base:String,extension ext:String,in directory:URL)->URL {
 var n=1
 while true {
  let suffix=n == 1 ? "":"_\(n)"
  let candidate=directory.appendingPathComponent(base+suffix+"."+ext)
  if !fm.fileExists(atPath:candidate.path){return candidate}
  n+=1
 }
}
func finish(_ draft: Draft, root: URL, dest: URL, combinedFile:String? = nil, previous:PreviousSessionTarget? = nil) throws {
 guard !draft.images.isEmpty else {throw NSError(domain:"ScreenshotNote",code:2,userInfo:[NSLocalizedDescriptionKey:L("Přidej alespoň jeden screenshot, nebo zvol Pokračovat v relaci.")])}
 if let file=combinedFile, URL(fileURLWithPath:file).lastPathComponent != file {throw NSError(domain:"ScreenshotNote",code:3,userInfo:[NSLocalizedDescriptionKey:L("Neplatný název společného Markdown souboru.")])}
 if let previous=previous{_ = try checkedPreviousFile(previous)}
 let assets = dest.appendingPathComponent("assets", isDirectory:true)
 try fm.createDirectory(at:assets, withIntermediateDirectories:true)
 // Plochá složka: „YYYY-MM-DD Název.md“ v kořeni a obrázky „YYYY-MM-DD Název-N.png“ ve společném assets/.
 let readable=readableSessionName(draft.title ?? "",created:Date())
 let markdown = previous.map{URL(fileURLWithPath:$0.path)} ?? combinedFile.map{dest.appendingPathComponent($0)} ?? dest.appendingPathComponent(uniqueName(readable){fm.fileExists(atPath:dest.appendingPathComponent($0+".md").path)}+".md")
 let name = combinedFile == nil ? markdown.deletingPathExtension().lastPathComponent:readable
 var copied:[URL] = []; var links:[String] = []; var imageNames:[String] = []
 do {
  for (index, image) in draft.images.enumerated() {
   let note=draft.imageNotes?[image] ?? ""
   if let originalName=previous?.imported[image],!originalName.contains("/"),let old=try? Data(contentsOf:assets.appendingPathComponent(originalName)),old == (try? Data(contentsOf:root.appendingPathComponent(image))){imageNames.append(originalName);links.append(imageMarkdown(originalName,index+1)+(note.isEmpty ? "":"\n\n"+note));continue}

   let target = assets.appendingPathComponent(uniqueName(name+"-\(index+1)"){fm.fileExists(atPath:assets.appendingPathComponent($0+".png").path)}+".png")
   let filename = target.lastPathComponent
   try fm.copyItem(at:root.appendingPathComponent(image), to:target); copied.append(target)
   imageNames.append(filename);links.append(imageMarkdown(filename,index+1)+(note.isEmpty ? "":"\n\n"+note))
  }
  let title=(draft.title?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false) ? draft.title!.replacingOccurrences(of:"\n",with:" ") : "Screenshot"
  let template=draft.topic?.markdownTemplate ?? defaultMarkdownTemplate
  // Replace placeholders in a single pass so user content containing tokens stays literal.
  let body=renderSessionTemplate(template,title:title,screenshots:links.joined(separator:"\n\n"),text:draft.comment)
  var notes:[String:String]=[:];for (filename,image) in zip(imageNames,draft.images){notes[filename]=draft.imageNotes?[image] ?? ""}
  // Markdown nenese žádné skryté značky; identitu drží index a xattr.
  let content=body,index=SessionIndex.shared,length=(content as NSString).length
  var hashes:[String:String]=[:];for name in imageNames{hashes["assets/"+name]=fileHash(assets.appendingPathComponent(name))}
  var record=SessionRecord(id:previous?.session ?? UUID().uuidString,file:SessionIndex.key(markdown),start:0,length:length,hash:sessionFingerprint(Data(content.utf8)),heading:firstLine(content),title:title,comment:draft.comment,template:template,images:imageNames,notes:notes,combined:false,footer:"",files:hashes,seen:0)
  if let previous=previous {
   let original=try checkedPreviousFile(previous)
   let updated=(original as NSString).replacingCharacters(in:NSRange(location:previous.start,length:previous.length),with:content)
   try Data(updated.utf8).write(to:markdown,options:.atomic)
   let old=index.records(file:markdown).first{$0.id==record.id}
   record.start=previous.start;record.footer=old?.footer ?? ""
   record.combined=old?.combined ?? !(previous.start==0 && previous.length==(original as NSString).length)
   index.batch{if let old{index.remove(old)};index.shift(file:markdown,after:previous.start,by:length-previous.length);index.put(record)}
   if record.combined{tagCombinedFile(markdown)}else{writeSessionTag(markdown,record.id)}
  } else if combinedFile != nil {
   let (header,footer)=combinedTemplateParts(draft.topic?.combinedTemplate ?? defaultCombinedTemplate,folderName:draft.topic?.name ?? "",folderDescription:draft.topic?.detail ?? "")
   var data:Data,head:Data
   record.combined=true
   if fm.fileExists(atPath:markdown.path) {
    data=try Data(contentsOf:markdown);let tail=Data(footer.utf8)
    // Nová relace patří před patičku šablony, pokud jí soubor pořád končí.
    if !tail.isEmpty,data.count>=tail.count,data.suffix(tail.count)==tail {
     head=Data(data.prefix(data.count-tail.count));if !head.isEmpty{head.append(Data("\n\n---\n\n".utf8))}
     data=head+Data(content.utf8)+tail;record.footer=footer
    } else {head=data;if !head.isEmpty{head.append(Data("\n\n---\n\n".utf8))};data=head+Data(content.utf8)}
   } else {head=Data(header.utf8);data=Data((header+content+footer).utf8);record.footer=footer}
   record.start=(String(decoding:head,as:UTF8.self) as NSString).length
   try data.write(to:markdown,options:.atomic)
   index.put(record);tagCombinedFile(markdown)
  } else {try Data(content.utf8).write(to:markdown,options:.withoutOverwriting);index.put(record);writeSessionTag(markdown,record.id)}
 } catch { for file in copied { try? fm.removeItem(at:file) }; throw error }
 clearDraft(draft,root:root)
}

func clearDraft(_ draft:Draft,root:URL){
 // Remove the manifest first: a later cleanup error must not cause duplicate output.
 try? fm.removeItem(at:root.appendingPathComponent("draft.json"))
 for image in draft.images { removeAnnotatedImage(root.appendingPathComponent(image)) }
}


func finishSession(_ draft:Draft,root:URL)throws {
 let topic=draft.topic ?? Topics.defaultTopic
 let folder=draft.previous.map{URL(fileURLWithPath:$0.path).deletingLastPathComponent()} ?? topic.destination
 try Topics.validateDestination(topic,folder:folder)
 try finish(draft,root:root,dest:folder,combinedFile:topic.combined ? topic.combinedFile:nil,previous:draft.previous)
}

let defaultMarkdownTemplate="# {title}\n\n# Screenshots\n\n{screenshots}\n\n# Description\n\n{text}\n\n{comments}\n"
// Dřívější vestavěná šablona; uložené šablony se nemění.
let legacyDefaultMarkdownTemplate="# {title}\n\n# Screenshots\n\n{screenshots}\n\n# Description\n\n{text}\n"
/// `{author}` je jméno autora cloudové relace, jinak prázdné; vestavěné šablony ho nemají.
func renderSessionTemplate(_ template:String,title:String,screenshots:String,text:String,comments:String="",author:String="")->String{
 let values=["{title}":title,"{screenshots}":screenshots,"{text}":text,"{comments}":comments,"{author}":author]
 let expression=try! NSRegularExpression(pattern:"\\{(?:title|screenshots|text|comments|author)\\}")
 let source=template as NSString;var output=template
 for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[source.substring(with:match.range)]!)}
 // Bez komentářů nezůstanou na konci prázdné řádky.
 if template.contains("{comments}") && comments.isEmpty{while let last=output.last,last.isWhitespace{output.removeLast()}}
 return output.hasSuffix("\n") ? output:output+"\n"
}
/// Komentáře pro {comments}: text, pod ním autor a místní čas, oddělené prázdným řádkem.
func renderComments(_ comments:[RemoteNote.Comment])->String {
 let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone = .current;format.dateFormat="yyyy-MM-dd HH:mm"
 return comments.map{$0.body+"\n`"+($0.author_name ?? "")+"` - `"+(parseServerDate($0.created_at).map(format.string) ?? $0.created_at ?? "")+"`"}.joined(separator:"\n\n")
}
func fillPlaceholders(_ template:String,_ values:[String:String])->String {
 let expression=try! NSRegularExpression(pattern:values.keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator:"|"))
 let source=template as NSString;var output=template
 for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[source.substring(with:match.range)]!)}
 return output
}
/// Hlavička a patička společného souboru podle šablony s {sessions}.
func combinedTemplateParts(_ template:String,folderName:String,folderDescription:String)->(String,String) {
 let pieces=template.components(separatedBy:"{sessions}");guard pieces.count==2 else{return ("","")}
 let values=["{folderName}":folderName,"{folderDescription}":folderDescription]
 var header=fillPlaceholders(pieces[0],values)
 while header.contains("\n\n\n"){header=header.replacingOccurrences(of:"\n\n\n",with:"\n\n")}
 return (header,fillPlaceholders(pieces[1],values))
}
func validCombinedTemplate(_ template:String)->Bool{template.components(separatedBy:"{sessions}").count==2 && template.count<=20000 && !template.contains("\0")}
