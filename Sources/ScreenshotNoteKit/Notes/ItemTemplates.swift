import Foundation

// Šablony komentáře a obrázku; stejná pravidla má web (lib/item-templates.ts), výstup se musí shodovat bajt po bajtu.
let defaultCommentTemplate="{text}\n`{name}` - `{date}`"
let defaultImageTemplate="{image}\n\n{description}\n\n{context}\n\n{comments}"
let commentPlaceholders=["date","name","text"]
let imagePlaceholders=["image","description","comments","number","context","elements"]
let itemTemplateMaxLength=5000
/// Verze vykreslení cloudových relací; zvýšení je jednou přerenderuje.
let cloudRenderVersion=2

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

/// Komentáře na konci popisku (cloudová relace) se odstraní; šablona s prázdným řádkem se nečte.
func stripCommentBlocks(_ text:String,template:String?)->String {
 let source=template ?? defaultCommentTemplate
 guard !source.contains("\n\n") else{return text}
 let token=try! NSRegularExpression(pattern:"\\{(?:text|name|date)\\}"),ns=source as NSString
 var pattern="\\A",offset=0
 for match in token.matches(in:source,range:NSRange(location:0,length:ns.length)) {
  pattern+=NSRegularExpression.escapedPattern(for:ns.substring(with:NSRange(location:offset,length:match.range.location-offset)))
  pattern+=ns.substring(with:match.range)=="{text}" ? "[\\s\\S]*":"[^\\n]*";offset=NSMaxRange(match.range)
 }
 guard let regex=try? NSRegularExpression(pattern:pattern+NSRegularExpression.escapedPattern(for:ns.substring(from:offset))+"\\z") else{return text}
 var output=text
 while !output.isEmpty {
  let current=output as NSString,at=current.range(of:"\n\n",options:.backwards)
  let last=at.location==NSNotFound ? output:current.substring(from:NSMaxRange(at))
  guard regex.firstMatch(in:last,range:NSRange(location:0,length:(last as NSString).length)) != nil else{break}
  output=at.location==NSNotFound ? "":current.substring(to:at.location)
 }
 return output
}

/// Regex odstavců šablony; odstavec jen z placeholderů může chybět, povinný je ten u {image}.
private func paragraphPattern(_ paragraphs:[String],imageAtEnd:Bool)->(pattern:String,keys:[String]) {
 let token=try! NSRegularExpression(pattern:"\\{(?:description|comments|number|context|elements)\\}")
 var pattern="",keys:[String]=[]
 let required=imageAtEnd ? paragraphs.count-1:0
 for (index,paragraph) in paragraphs.enumerated() {
  let ns=paragraph as NSString,matches=token.matches(in:paragraph,range:NSRange(location:0,length:ns.length))
  var piece="",offset=0
  for match in matches {
   piece+=NSRegularExpression.escapedPattern(for:ns.substring(with:NSRange(location:offset,length:match.range.location-offset)))
   switch ns.substring(with:match.range){
    case "{description}":piece+="([\\s\\S]*)";keys.append("description")
    case "{elements}":piece+="(- \\*\\*\\[\\d+\\][^\\n]*(?:\\n(?:- \\*\\*\\[\\d+\\]|  )[^\\n]*)*)";keys.append("elements")
    case "{number}":piece+="\\d+"
    default:piece+="[\\s\\S]*?"
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

/// Popisek obrázku podle šablony obrázku: before = text před odkazem, after = za ním.
/// Popisek bere vše, co šablona nedává jinam; komentáře cloudové relace se vynechají.
func imageCaption(_ after:String,before:String="",template:String?,next:Int?,comments:String??=nil)->String {
 func clean(_ text:String)->String {
  var value=text.trimmingCharacters(in:.newlines)
  if let comments{value=stripCommentBlocks(value,template:comments)}
  return stripContextCallout(value).trimmingCharacters(in:.newlines)
 }
 guard let template,template != defaultImageTemplate,let at=template.range(of:"{image}") else{return clean(after)}
 let prefix=String(template[..<at.lowerBound])
 var text=after.trimmingCharacters(in:.newlines)
 // Popis před obrázkem: čte se z textu před odkazem.
 if prefix.contains("{description}") || prefix.contains("{elements}") {
  let parts=paragraphPattern(prefix.components(separatedBy:"\n\n"),imageAtEnd:true)
  guard let regex=try? NSRegularExpression(pattern:parts.pattern+"\\z"),let match=regex.firstMatch(in:before,range:NSRange(location:0,length:(before as NSString).length)) else{return clean(after)}
  return joined(match,parts.keys,in:before,clean:clean)
 }
 // Konec bloku obsahuje začátek dalšího obrázku (např. nadpis s {number}).
 let head=prefix.trimmingCharacters(in:.whitespacesAndNewlines)
 if let next,!head.isEmpty {
  let rendered=head.replacingOccurrences(of:"{number}",with:String(next))
  if !rendered.contains("{"),text.hasSuffix(rendered){text=String(text.dropLast(rendered.count)).trimmingCharacters(in:.newlines)}
 }
 let parts=paragraphPattern(String(template[at.upperBound...]).components(separatedBy:"\n\n"),imageAtEnd:false)
 let source="\n\n"+text
 guard let regex=try? NSRegularExpression(pattern:"\\A(?:\\n\\n)?"+parts.pattern+"\\s*\\z"),
       let match=regex.firstMatch(in:source,range:NSRange(location:0,length:(source as NSString).length)) else{return clean(text)}
 return joined(match,parts.keys,in:source,clean:clean)
}
private func joined(_ match:NSTextCheckingResult,_ keys:[String],in source:String,clean:(String)->String)->String {
 var values:[String:String]=[:]
 for (i,key) in keys.enumerated() where match.range(at:i+1).location != NSNotFound{values[key]=(source as NSString).substring(with:match.range(at:i+1))}
 return [clean(values["description"] ?? ""),values["elements"] ?? ""].filter{!$0.isEmpty}.joined(separator:"\n\n")
}
