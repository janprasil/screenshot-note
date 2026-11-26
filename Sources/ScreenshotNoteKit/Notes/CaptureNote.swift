import AppKit
import CoreGraphics
import Darwin

struct Draft: Codable { var images: [String]; var comment: String; var title: String? = nil; var topic:Topic? = nil; var previous:PreviousSessionTarget? = nil; var imageNotes:[String:String]? = nil
 // Texty čekající cloudové úpravy, ze kterých koncept vznikl; nová úprava se na ně položí.
 var cloudBase:CloudLibrary.CloudEdit.Fields? = nil
 // Obrázek → soubor kontextu z prohlížeče v pracovní složce (`<obrázek>.context.json`, vedle něj `.har`).
 var contexts:[String:String]? = nil
 // Názvy v assets/ znovuotevřené relace, jejichž kontext uživatel odebral; smažou se po uložení.
 var removedContexts:[String]? = nil
 // Podsložka nové relace: ID (cloud) nebo relativní cesta (místní složka); nil = kořen.
 var subfolder:String? = nil
}
/// Otisk obsahu konceptu (text, popisky a bajty snímků) pro zjištění neuložené práce.
func draftSignature(_ draft:Draft,root:URL)->String {
 var parts=[draft.title?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "",draft.comment]
 for image in draft.images{parts.append(draft.imageNotes?[image] ?? "");parts.append(fileHash(root.appendingPathComponent(image)) ?? image);if let hash=fileHash(annotationSidecar(root.appendingPathComponent(image))){parts.append(hash)};if draft.contexts?[image] != nil{parts.append("context")};if let hash=fileHash(videoSidecars(root.appendingPathComponent(image))[0]){parts.append(hash)}}
 if let removed=draft.removedContexts,!removed.isEmpty{parts.append(removed.sorted().joined(separator:"/"))}
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
var destination: URL { URL(fileURLWithPath: UserDefaults.standard.string(forKey:"destination") ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/ScreenshotNote/Default").path, isDirectory:true) }
/// Dřívější výchozí složka; instalace, které ji už používají, si ji ponechají.
let legacyDestination = fm.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshot Note", isDirectory:true)
/// Stávající instalace bez uložené cesty a složek zůstane u staré výchozí složky, pokud na disku existuje.
func pinLegacyDestination(_ defaults:UserDefaults = .standard, legacy:URL = legacyDestination) {
 // Prázdný seznam složek (vše přesunuté do cloudu) je jako žádný; výchozí složka pak dál vychází z destination.
 let topics=defaults.data(forKey:"topics").flatMap{try? JSONDecoder().decode([Topic].self,from:$0)}
 guard defaults.object(forKey:"destination") == nil, defaults.data(forKey:"topics") == nil || topics?.isEmpty == true, fm.fileExists(atPath:legacy.path) else { return }
 defaults.set(legacy.path, forKey:"destination")
}
func readDraft(_ root: URL) throws -> Draft {
 let file = root.appendingPathComponent("draft.json")
 guard fm.fileExists(atPath:file.path) else { return Draft(images:[], comment:"") }
 var draft = try JSONDecoder().decode(Draft.self, from:Data(contentsOf:file))
 // Kontext bez obrázku nebo bez souboru se zahodí, snímek zůstane.
 draft.contexts=draft.contexts?.filter{draft.images.contains($0.key) && $0.value==$0.key+".context.json" && fm.fileExists(atPath:root.appendingPathComponent($0.value).path)}
 draft.removedContexts=draft.removedContexts?.filter{!$0.isEmpty && !$0.contains("/") && $0.hasSuffix(".png")}
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
 let readable=readableSessionName(draft.title ?? "",created:Date(),fallback:DefaultTitle.resolve(draft.topic))
 let markdown = previous.map{URL(fileURLWithPath:$0.path)} ?? combinedFile.map{dest.appendingPathComponent($0)} ?? dest.appendingPathComponent(uniqueName(readable){fm.fileExists(atPath:dest.appendingPathComponent($0+".md").path)}+".md")
 let name = combinedFile == nil ? markdown.deletingPathExtension().lastPathComponent:readable
 var copied:[URL] = []; var imageNames:[String] = []
 // Kontext odebraný u znovupoužitého obrázku; z assets/ se smaže až po zápisu Markdownu.
 var removedContext:[String:[URL]]=[:]
 let importedOriginals=Set(previous?.imported.values.map{$0} ?? [])
 for original in draft.removedContexts ?? [] where importedOriginals.contains(original) && !original.contains("/") {
  let stale=assetContextFiles(assets,original).filter{fm.fileExists(atPath:$0.path)};if !stale.isEmpty{removedContext[original]=stale}
 }
 do {
  // Kontext z prohlížeče jde jen do lokálních složek; u cloudových se zahodí (upload přijde později).
  let keepContext=draft.topic?.effectiveContextPolicy != nil
  func copyContext(_ image:String,as filename:String)throws{
   guard keepContext,draft.contexts?[image] != nil else{return}
   for (source,target) in zip(contextSidecars(root.appendingPathComponent(image)),assetContextFiles(assets,filename)) where fm.fileExists(atPath:source.path) && !fm.fileExists(atPath:target.path){try fm.copyItem(at:source,to:target);copied.append(target)}
   adjustContextCapture(assetContextFiles(assets,filename)[0],annotations:annotationSidecar(root.appendingPathComponent(image)))
  }
  // Video jde vždy (není to kontext z prohlížeče): `<název>.mp4` a `<název>.frames/` vedle posteru.
  func copyVideo(_ image:String,as filename:String)throws{
   let sources=videoSidecars(root.appendingPathComponent(image)),targets=assetVideoFiles(assets,filename)
   if fm.fileExists(atPath:sources[0].path) && !fm.fileExists(atPath:targets[0].path){try fm.copyItem(at:sources[0],to:targets[0]);copied.append(targets[0])}
   guard fm.fileExists(atPath:sources[1].path),!fm.fileExists(atPath:targets[1].path) else{return}
   // Záznam bez anotací (original/) ani dočasné soubory do assets/ nejdou; anotace mohou něco zakrývat.
   try fm.createDirectory(at:targets[1],withIntermediateDirectories:false);copied.append(targets[1])
   for name in try fm.contentsOfDirectory(atPath:sources[1].path) where name != "original" && !name.hasPrefix("."){try fm.copyItem(at:sources[1].appendingPathComponent(name),to:targets[1].appendingPathComponent(name))}
  }
  for (index, image) in draft.images.enumerated() {
   if let originalName=previous?.imported[image],!originalName.contains("/"),let old=try? Data(contentsOf:assets.appendingPathComponent(originalName)),old == (try? Data(contentsOf:root.appendingPathComponent(image))){
    try copyContext(image,as:originalName);try copyVideo(image,as:originalName);imageNames.append(originalName);continue
   }
   // Název musí být volný pro obrázek i pro oba soubory kontextu.
   let base=uniqueName(name+"-\(index+1)"){candidate in ["png","context.json","har","mp4","frames"].contains{fm.fileExists(atPath:assets.appendingPathComponent(candidate+"."+$0).path)}}
   let target = assets.appendingPathComponent(base+".png")
   let filename = target.lastPathComponent
   try fm.copyItem(at:root.appendingPathComponent(image), to:target); copied.append(target)
   try copyContext(image,as:filename);try copyVideo(image,as:filename);imageNames.append(filename)
  }
  // Anotace Element se vypíšou pod popisek obrázku a zůstanou v něm i pro přerenderování.
  // Bez kontextu (odebraný nebo vypnutý politikou) jdou ven jen čísla a popisy, ne data stránky.
  let captions=draft.images.map{captionWithElements(draft.imageNotes?[$0] ?? "",image:root.appendingPathComponent($0),pageData:keepContext && draft.contexts?[$0] != nil)}
  let rendered=screenshotsWithContext(imageNames,captions,assets:assets,without:Set(removedContext.keys),imageTemplate:draft.topic?.imageTemplate)
  let title=(draft.title?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false) ? draft.title!.replacingOccurrences(of:"\n",with:" ") : DefaultTitle.resolve(draft.topic)
  let template=draft.topic?.markdownTemplate ?? defaultMarkdownTemplate
  // Replace placeholders in a single pass so user content containing tokens stays literal.
  let body=renderSessionTemplate(template,title:title,screenshots:rendered.screenshots,text:draft.comment,context:rendered.context)
  var notes:[String:String]=[:];for (filename,caption) in zip(imageNames,captions){notes[filename]=caption}
  // Markdown nenese žádné skryté značky; identitu drží index a xattr.
  let content=body,index=SessionIndex.shared,length=(content as NSString).length
  var hashes:[String:String]=[:]
  for name in imageNames{hashes["assets/"+name]=fileHash(assets.appendingPathComponent(name));if removedContext[name] != nil{continue};for (file,suffix) in zip(assetContextFiles(assets,name),[".context.json",".har"]){if let hash=fileHash(file){hashes["assets/"+(name as NSString).deletingPathExtension+suffix]=hash}};if let hash=fileHash(assetVideoFiles(assets,name)[0]){hashes["assets/"+(name as NSString).deletingPathExtension+".mp4"]=hash}}
  var record=SessionRecord(id:previous?.session ?? UUID().uuidString,file:SessionIndex.key(markdown),start:0,length:length,hash:sessionFingerprint(Data(content.utf8)),heading:firstLine(content),title:title,comment:draft.comment,template:template,images:imageNames,notes:notes,combined:false,footer:"",files:hashes,seen:0)
  record.imageTemplate=draft.topic?.imageTemplate
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
   let folderText=combinedFolderText(draft.topic)
   let (header,footer)=combinedTemplateParts(draft.topic?.combinedTemplate ?? defaultCombinedTemplate,folderName:folderText.0,folderDescription:folderText.1)
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
 for file in removedContext.values.joined(){do{try fm.removeItem(at:file)}catch{NSLog("Screenshot Note: removed browser context could not be deleted: %@",error.localizedDescription)}}
 clearDraft(draft,root:root)
}

func clearDraft(_ draft:Draft,root:URL){
 // Remove the manifest first: a later cleanup error must not cause duplicate output.
 try? fm.removeItem(at:root.appendingPathComponent("draft.json"))
 for image in draft.images { removeAnnotatedImage(root.appendingPathComponent(image)) }
}


func finishSession(_ draft:Draft,root:URL,folders:[Topic]?=nil)throws {
 var draft=draft
 // Kontext podle aktuálního nastavení složky, ne podle kopie v konceptu.
 if let saved=draft.topic{draft.topic?.contextPolicy=saved.currentContextPolicy(in:folders ?? Topics.all) ?? {var off=ContextPolicy();off.enabled=false;return off}()}
 let topic=draft.topic ?? Topics.defaultTopic
 // Dřív uložené vnoření snímek neblokuje; nové vnoření se odmítá při nastavení složky.
 try Topics.validateDestination(topic,folder:draft.previous.map{URL(fileURLWithPath:$0.path).deletingLastPathComponent()} ?? topic.destination,nested:true)
 // Nová relace místní složky jde do zvolené podsložky; doplnění zůstává ve svém souboru.
 let folder=try draft.previous.map{URL(fileURLWithPath:$0.path).deletingLastPathComponent()} ?? localSubfolderDirectory(topic,draft.subfolder)
 try finish(draft,root:root,dest:folder,combinedFile:topic.combined ? topic.combinedFile:nil,previous:draft.previous)
}

let defaultMarkdownTemplate="# {title}\n\n# Screenshots\n\n{screenshots}\n\n# Description\n\n{text}\n\n{comments}\n"
// Dřívější vestavěná šablona; uložené šablony se nemění.
let legacyDefaultMarkdownTemplate="# {title}\n\n# Screenshots\n\n{screenshots}\n\n# Description\n\n{text}\n"
/// `{author}` je jméno autora cloudové relace, jinak prázdné; vestavěné šablony ho nemají.
/// `{context}` je souhrn kontextu z prohlížeče za relaci; vestavěné šablony ho nemají.
/// `{issues}` jsou odkazy cloudové relace, lokálně prázdné.
func renderSessionTemplate(_ template:String,title:String,screenshots:String,text:String,comments:String="",author:String="",context:String="",issues:String="")->String{
 let values=["{title}":title,"{screenshots}":screenshots,"{text}":text,"{comments}":comments,"{author}":author,"{context}":context,"{issues}":issues]
 let expression=try! NSRegularExpression(pattern:"\\{(?:title|screenshots|text|comments|author|context|issues)\\}")
 let source=template as NSString;var output=template
 for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[source.substring(with:match.range)]!)}
 // Bez komentářů nezůstanou na konci prázdné řádky.
 if template.contains("{comments}") && comments.isEmpty{while let last=output.last,last.isWhitespace{output.removeLast()}}
 return output.hasSuffix("\n") ? output:output+"\n"
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
/// Název a popis cloudové složky jsou data ze serveru; lokální složky zůstávají beze změny.
func combinedFolderText(_ topic:Topic?)->(String,String) {
 guard let topic else{return ("","")}
 return topic.cloudFolderID == nil ? (topic.name,topic.detail):(serverTitle(topic.name),escapeServerMarkdown(topic.detail))
}
func validCombinedTemplate(_ template:String)->Bool{template.components(separatedBy:"{sessions}").count==2 && template.count<=20000 && !template.contains("\0")}
