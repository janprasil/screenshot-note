import Foundation

// Šablony komentáře a obrázku; stejná pravidla má web (lib/item-templates.ts), výstup se musí shodovat bajt po bajtu.
let defaultCommentTemplate="{text}\n`{name}` - `{date}`"
let defaultImageTemplate="{image}\n\n{description}\n\n{context}\n\n{comments}"
let commentPlaceholders=["date","name","text"]
let imagePlaceholders=["image","description","comments","number","context","elements"]
let itemTemplateMaxLength=5000
/// Verze vykreslení cloudových relací; zvýšení je jednou přerenderuje.
let cloudRenderVersion=3

private let monthNames=["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
/// {date}: cs `22. 11. 2026 14:05`, jinak `Nov 22, 2026, 14:05`.
func formatTemplateDate(_ date:Date,language:String=AppLanguage.current,timeZone:TimeZone = .current)->String {
 var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
 let c=calendar.dateComponents([.year,.month,.day,.hour,.minute],from:date)
 let time=String(format:"%02d:%02d",c.hour ?? 0,c.minute ?? 0)
 return language=="cs" ? "\(c.day ?? 0). \(c.month ?? 0). \(c.year ?? 0) "+time:"\(monthNames[max(0,(c.month ?? 1)-1)]) \(c.day ?? 0), \(c.year ?? 0), "+time
}

/// Odstavec jen z prázdných placeholderů se vynechá, ostatní se spojí prázdným řádkem.
func renderParagraphs(_ template:String,_ values:[String:String])->String {
 let expression=try! NSRegularExpression(pattern:"\\{(?:"+values.keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator:"|")+")\\}")
 func tokens(_ text:String)->[String]{let ns=text as NSString;return expression.matches(in:text,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range)}}
 return template.components(separatedBy:"\n\n").filter{paragraph in
  let found=tokens(paragraph)
  guard !found.isEmpty else{return true}
  let rest=expression.stringByReplacingMatches(in:paragraph,range:NSRange(location:0,length:(paragraph as NSString).length),withTemplate:"")
  if !rest.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{return true}
  return found.contains{!(values[String($0.dropFirst().dropLast())] ?? "").isEmpty}
 }.map{paragraph in
  let ns=paragraph as NSString;var output=paragraph
  for match in expression.matches(in:paragraph,range:NSRange(location:0,length:ns.length)).reversed(){output=(output as NSString).replacingCharacters(in:match.range,with:values[String(ns.substring(with:match.range).dropFirst().dropLast())] ?? "")}
  return output
 }.joined(separator:"\n\n")
}

private let elementLine=try! NSRegularExpression(pattern:"^- \\*\\*\\[\\d{1,6}\\] (?:Element|Kresba|Šipka|Kruh|Rámeček|Text|Drawing|Arrow|Circle|Rectangle)\\*\\*")
/// Řádky anotací na konci popisku; {elements} je z {description} vyjme.
func splitElements(_ caption:String)->(description:String,elements:String) {
 let ns=caption as NSString,at=ns.range(of:"\n\n",options:.backwards)
 let tail=at.location==NSNotFound ? caption:ns.substring(from:NSMaxRange(at))
 let lines=tail.components(separatedBy:"\n")
 func element(_ line:String)->Bool{elementLine.firstMatch(in:line,range:NSRange(location:0,length:(line as NSString).length)) != nil}
 guard element(lines[0]),lines.allSatisfy({element($0) || $0.hasPrefix("  ")}) else{return (caption,"")}
 return (at.location==NSNotFound ? "":ns.substring(to:at.location),tail)
}

/// Komentáře šablonou komentáře, oddělené prázdným řádkem; text je už escapovaný.
func renderCommentList(_ comments:[RemoteNote.Comment],template:String?,language:String=AppLanguage.current,timeZone:TimeZone = .current)->String {
 comments.map{comment in
  let date=parseServerDate(comment.created_at).map{formatTemplateDate($0,language:language,timeZone:timeZone)} ?? comment.created_at ?? ""
  return renderParagraphs(template ?? defaultCommentTemplate,["date":date,"name":(comment.author_name ?? "").replacingOccurrences(of:"`",with:"'"),"text":comment.body])
 }.joined(separator:"\n\n")
}

/// Jeden obrázek pro {screenshots}; popisek a komentáře jsou připravené pro Markdown.
struct ImageBlock{var name:String;var caption:String;var context:String="";var comments:String=""}
func renderImageBlocks(_ images:[ImageBlock],template:String?)->String {
 let source=template ?? defaultImageTemplate,separate=source.contains("{elements}")
 return images.enumerated().map{(offset,image) in
  let parts=separate ? splitElements(image.caption):(image.caption,"")
  return renderParagraphs(source,["image":imageMarkdown(image.name,offset+1),"description":parts.0,"comments":image.comments,"number":String(offset+1),"context":image.context,"elements":parts.1])
 }.joined(separator:"\n\n")
}

/// {issues}: odrážka s klíčem a odkazem, případně s názvem.
func renderIssueList(_ issues:[RemoteNote.Issue])->String {
 issues.map{issue in
  let label=serverTitle(issue.label).replacingOccurrences(of:"[",with:"\\[").replacingOccurrences(of:"]",with:"\\]")
  return "- [\(label)](<\(issue.url)>)"+(issue.title.map{$0.isEmpty ? "":" — "+serverTitle($0)} ?? "")
 }.joined(separator:"\n")
}

/// Kontrola šablony: chyba (prázdná, dlouhá, bez {image}) a neznámé placeholdery jako varování.
func checkItemTemplate(_ kind:String,_ value:String)->(valid:Bool,unknown:[String]) {
 let known=kind=="comment" ? commentPlaceholders:imagePlaceholders,ns=value as NSString
 var unknown:[String]=[]
 for match in (try! NSRegularExpression(pattern:"\\{([A-Za-z]+)\\}")).matches(in:value,range:NSRange(location:0,length:ns.length)) {
  let name=ns.substring(with:match.range(at:1));if !known.contains(name) && !unknown.contains(name){unknown.append(name)}
 }
 return (!value.isEmpty && value.count<=itemTemplateMaxLength && (kind=="comment" || value.contains("{image}")),unknown)
}

/// Vykreslené komentáře obrázků cloudové relace podle názvu obrázku; čtení popisků je přesně vynechá.
func cloudImageComments(_ note:RemoteNote,images names:[String],language:String=AppLanguage.current,timeZone:TimeZone = .current)->[String:String]? {
 let comments=(note.comments ?? []).map{RemoteNote.Comment(author_name:$0.author_name.map(serverTitle),body:escapeServerMarkdown($0.body),created_at:$0.created_at,image_index:$0.image_index)}
 var result:[String:String]=[:]
 for (offset,name) in names.enumerated() {
  let text=renderCommentList(comments.filter{$0.image_index==offset+1},template:note.comment_template,language:language,timeZone:timeZone)
  if !text.isEmpty{result[name]=text}
 }
 return result.isEmpty ? nil:result
}

/// Regex odstavců šablony; odstavec jen z placeholderů může chybět, povinný je ten u {image}.
private func paragraphPattern(_ paragraphs:[String],imageAtEnd:Bool,capture:Bool=true)->(pattern:String,keys:[String]) {
 let token=try! NSRegularExpression(pattern:"\\{(?:description|comments|number|context|elements)\\}")
 var pattern="",keys:[String]=[]
 let required=imageAtEnd ? paragraphs.count-1:0,open=capture ? "(":"(?:"
 for (index,paragraph) in paragraphs.enumerated() {
  let ns=paragraph as NSString,matches=token.matches(in:paragraph,range:NSRange(location:0,length:ns.length))
  var piece="",offset=0
  for match in matches {
   piece+=NSRegularExpression.escapedPattern(for:ns.substring(with:NSRange(location:offset,length:match.range.location-offset)))
   switch ns.substring(with:match.range){
    case "{description}":piece+=open+"[\\s\\S]*)";if capture{keys.append("description")}
    case "{elements}":piece+=open+"- \\*\\*\\[\\d+\\][^\\n]*(?:\\n(?:- \\*\\*\\[\\d+\\]|  )[^\\n]*)*)";if capture{keys.append("elements")}
    case "{context}":piece+="> \\[!bug\\]- [^\\n]*(?:\\n> [^\\n]*)*"
    case "{number}":piece+="\\d+"
    // Komentáře jsou z textu odstraněné předem.
    default:piece+=""
   }
   offset=NSMaxRange(match.range)
  }
  piece+=NSRegularExpression.escapedPattern(for:ns.substring(from:offset))
  if index==required{pattern+=piece;continue}
  let placeholderOnly = !matches.isEmpty && token.stringByReplacingMatches(in:paragraph,range:NSRange(location:0,length:ns.length),withTemplate:"").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
  let part=imageAtEnd ? piece+"\\n\\n":"\\n\\n"+piece
  pattern+=placeholderOnly ? "(?:"+part+")?":part
 }
 return (pattern,keys)
}
private func captures(_ regex:NSRegularExpression?,_ keys:[String],in text:String)->[String:String]? {
 guard let regex,let match=regex.firstMatch(in:text,range:NSRange(location:0,length:(text as NSString).length)) else{return nil}
 var values:[String:String]=[:]
 for (i,key) in keys.enumerated() where match.range(at:i+1).location != NSNotFound{values[key]=(text as NSString).substring(with:match.range(at:i+1))}
 return values
}
/// Odstraní přesně vykreslené komentáře obrázku (první výskyt) a zbylé prázdné řádky.
private func removing(_ comments:String?,from text:String)->String {
 guard let comments,!comments.isEmpty,let range=text.range(of:comments) else{return text}
 var value=text;value.removeSubrange(range)
 while value.contains("\n\n\n"){value=value.replacingOccurrences(of:"\n\n\n",with:"\n\n")}
 return value.trimmingCharacters(in:.newlines)
}

/// Popisek obrázku podle šablony obrázku: before = text před odkazem (od předchozího odkazu), after = za ním.
/// comments = vykreslené komentáře tohoto obrázku (cloud), z popisku se vynechají.
/// previous = komentáře předchozího obrázku, které mohou ležet v before.
func imageCaption(_ after:String,before:String="",template:String?,next:Int?,comments:String?=nil,previous:String?=nil,first:Bool=true)->String {
 let after=removing(comments,from:after.trimmingCharacters(in:.newlines)),before=removing(previous,from:removing(comments,from:before.trimmingCharacters(in:.newlines)))
 guard let template,template != defaultImageTemplate,let at=template.range(of:"{image}") else{return stripContextCallout(after).trimmingCharacters(in:.newlines)}
 let prefix=String(template[..<at.lowerBound]),suffix=String(template[at.upperBound...])
 var values:[String:String]=[:]
 // Pole před obrázkem: od konce předchozího obrázku (jeho generované odstavce se přeskočí).
 if prefix.contains("{description}") || prefix.contains("{elements}") {
  let previous=paragraphPattern(suffix.components(separatedBy:"\n\n"),imageAtEnd:false,capture:false)
  let own=paragraphPattern(prefix.components(separatedBy:"\n\n"),imageAtEnd:true)
  // Text před odkazem končí tím, čím šablona před {image} (prázdné řádky jsou oříznuté).
  let source=before+String(prefix.reversed().prefix{$0=="\n"})
  let regex=try? NSRegularExpression(pattern:"\\A(?:"+previous.pattern+"\\n\\n)?"+own.pattern+"\\z")
  // Oříznutý začátek: generované odstavce předchozího obrázku začínají prázdným řádkem.
  // První obrázek žádný předchozí nemá; text před ním patří celý jemu.
  if first{values.merge(captures(try? NSRegularExpression(pattern:"\\A"+own.pattern+"\\z"),own.keys,in:source) ?? [:]){a,_ in a}}
  else{values.merge(captures(regex,own.keys,in:"\n\n"+source) ?? captures(regex,own.keys,in:source) ?? captures(try? NSRegularExpression(pattern:own.pattern+"\\z"),own.keys,in:source) ?? [:]){a,_ in a}}
 }
 // Pole za obrázkem; konec bloku obsahuje začátek dalšího obrázku (např. nadpis s {number}).
 var text=after
 let head=prefix.trimmingCharacters(in:.whitespacesAndNewlines)
 if let next,!head.isEmpty,!prefix.contains("{description}"),!prefix.contains("{elements}") {
  let rendered=head.replacingOccurrences(of:"{number}",with:String(next))
  if !rendered.contains("{"),text.hasSuffix(rendered){text=String(text.dropLast(rendered.count)).trimmingCharacters(in:.newlines)}
 }
 if suffix.contains("{description}") || suffix.contains("{elements}") {
  let own=paragraphPattern(suffix.components(separatedBy:"\n\n"),imageAtEnd:false)
  // Popis před obrázkem: za polem tohoto obrázku následuje popis dalšího.
  let rest=prefix.contains("{description}") || prefix.contains("{elements}") ? "(?:\\n\\n[\\s\\S]*)?":""
  guard let found=captures(try? NSRegularExpression(pattern:"\\A(?:\\n\\n)?"+own.pattern+rest+"\\s*\\z"),own.keys,in:"\n\n"+text) else{
   return values.isEmpty ? stripContextCallout(text).trimmingCharacters(in:.newlines):join(values)
  }
  values.merge(found){a,_ in a}
 }
 return join(values)
}
private func join(_ values:[String:String])->String {
 [stripContextCallout(values["description"] ?? "").trimmingCharacters(in:.newlines),values["elements"] ?? ""].filter{!$0.isEmpty}.joined(separator:"\n\n")
}
