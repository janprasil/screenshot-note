import AppKit
import CoreGraphics
import Darwin

struct Draft: Codable { var images: [String]; var comment: String; var title: String? = nil; var topic:Topic? = nil; var previous:PreviousSessionTarget? = nil; var imageNotes:[String:String]? = nil }
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
 let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
 let name = filenameFromTitle(draft.title) ?? (df.string(from:Date()) + "_" + UUID().uuidString.prefix(6))
 let markdown = previous.map{URL(fileURLWithPath:$0.path)} ?? combinedFile.map{dest.appendingPathComponent($0)} ?? availableFile(base:name,extension:"md",in:dest)
 var copied:[URL] = []; var links:[String] = []
 do {
  for (index, image) in draft.images.enumerated() {
   let note=draft.imageNotes?[image] ?? ""
   if let originalName=previous?.imported[image],!originalName.contains("/"),let old=try? Data(contentsOf:assets.appendingPathComponent(originalName)),old == (try? Data(contentsOf:root.appendingPathComponent(image))){links.append("![[assets/\(originalName)]]"+(note.isEmpty ? "":"\n\n"+note));continue}

   let base = draft.images.count > 1 ? name + "_\(index+1)" : name
   let target = availableFile(base:base,extension:"png",in:assets)
   let filename = target.lastPathComponent
   try fm.copyItem(at:root.appendingPathComponent(image), to:target); copied.append(target)
   links.append("![[assets/\(filename)]]"+(note.isEmpty ? "":"\n\n"+note))
  }
  let title=(draft.title?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false) ? draft.title!.replacingOccurrences(of:"\n",with:" ") : "Screenshot"
  let template=draft.topic?.markdownTemplate ?? defaultMarkdownTemplate
  // Replace placeholders in a single pass so user content containing tokens stays literal.
  let body=renderSessionTemplate(template,title:title,screenshots:links.joined(separator:"\n\n"),text:draft.comment)
  let imageNames=links.compactMap{entry -> String? in guard let end=entry.range(of:"]]"),entry.hasPrefix("![[assets/") else{return nil};return String(entry[entry.index(entry.startIndex,offsetBy:10)..<end.lowerBound])}
  var notes:[String:String]=[:];for (filename,image) in zip(imageNames,draft.images){notes[filename]=draft.imageNotes?[image] ?? ""}
  let metadata=SessionMetadata(title:title,comment:draft.comment,images:imageNames,imageNotes:notes,bodyLength:(body as NSString).length,bodyHash:sessionFingerprint(Data(body.utf8)),sessionID:UUID().uuidString,template:template)
  let encoded=try JSONEncoder().encode(metadata).base64EncodedString()
  let content="<!-- screenshot-note:begin "+metadata.sessionID+" -->\n"+body+"<!-- screenshot-note:v1 "+encoded+" -->\n"

  if let previous=previous {
   let original=try checkedPreviousFile(previous)
   let updated=(original as NSString).replacingCharacters(in:NSRange(location:previous.start,length:previous.length),with:content)
   try Data(updated.utf8).write(to:markdown,options:.atomic)
  } else if combinedFile != nil {
   var data=fm.fileExists(atPath:markdown.path) ? try Data(contentsOf:markdown):Data()
   if !data.isEmpty {data.append(Data("\n\n---\n\n".utf8))}
   data.append(Data(content.utf8));try data.write(to:markdown,options:.atomic)
  } else {try Data(content.utf8).write(to:markdown,options:.withoutOverwriting)}
 } catch { for file in copied { try? fm.removeItem(at:file) }; throw error }
 // Remove the manifest first: a later cleanup error must not cause duplicate output.
 try? fm.removeItem(at:root.appendingPathComponent("draft.json"))
 for image in draft.images { removeAnnotatedImage(root.appendingPathComponent(image)) }
}


func finishSession(_ draft:Draft,root:URL)throws {
 let topic=draft.topic ?? Topics.defaultTopic
 let folder=draft.previous.map{URL(fileURLWithPath:$0.path).deletingLastPathComponent()} ?? topic.destination
 try finish(draft,root:root,dest:folder,combinedFile:topic.combined ? topic.combinedFile:nil,previous:draft.previous)
}

let defaultMarkdownTemplate="# {title}\n\n# Screenshots\n\n{screenshots}\n\n# Description\n\n{text}\n"
func renderSessionTemplate(_ template:String,title:String,screenshots:String,text:String)->String{
 let values=["{title}":title,"{screenshots}":screenshots,"{text}":text]
 let expression=try! NSRegularExpression(pattern:"\\{(?:title|screenshots|text)\\}")
 let source=template as NSString;var output=template
 for match in expression.matches(in:template,range:NSRange(location:0,length:source.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[source.substring(with:match.range)]!)}
 return output.hasSuffix("\n") ? output:output+"\n"
}
