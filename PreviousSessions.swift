import AppKit
import CryptoKit

struct PreviousSessionTarget:Codable {
 var path:String;var start:Int;var length:Int;var original:String;var fingerprint:String
 var imported:[String:String] = [:]
 var id:String{path+"#"+String(start)}
 var cacheKey:String{id+"@"+fingerprint}
}
struct PreviousSession {
 var target:PreviousSessionTarget;var title:String;var comment:String;var images:[String];var modified:Date;var section:Int
 var imageNotes:[String:String] = [:]
 var display:String{title+" · "+localizedImageCount(images.count)+" · "+URL(fileURLWithPath:target.path).lastPathComponent+" · "+LF("Část %ld",section)}
}
struct SessionMetadata:Codable {var title:String;var comment:String;var images:[String];var imageNotes:[String:String];var bodyLength:Int;var bodyHash:String;var sessionID:String;var template:String}
func sessionFingerprint(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
func previousSessions(in folder:URL)throws->[PreviousSession]{
 guard fm.fileExists(atPath:folder.path) else{return []}
 let files=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:[.contentModificationDateKey,.isRegularFileKey],options:[.skipsHiddenFiles]).filter{$0.pathExtension.lowercased()=="md"}
 var result:[PreviousSession]=[]
 let heading=try NSRegularExpression(pattern:"(?m)^# ([^\\n]+)\\n\\n## Screenshot\\n\\n")
 let links=try NSRegularExpression(pattern:"!\\[\\[assets/([^]\\n]+)\\]\\]")
 for file in files{
  guard let data=try? Data(contentsOf:file),let text=String(data:data,encoding:.utf8) else{continue}
  let ns=text as NSString
  let metadataPattern=try NSRegularExpression(pattern:"<!-- screenshot-note:v1 ([A-Za-z0-9+/=]+) -->\\n?")
  var recognized:[NSRange]=[]
  let date=(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
  for match in metadataPattern.matches(in:text,range:NSRange(location:0,length:ns.length)){
   guard let encoded=Data(base64Encoded:ns.substring(with:match.range(at:1))),let metadata=try? JSONDecoder().decode(SessionMetadata.self,from:encoded),metadata.bodyLength>=0 else{continue}
   let prefix="<!-- screenshot-note:begin "+metadata.sessionID+" -->\n"
   let prefixRange=ns.range(of:prefix,options:.backwards,range:NSRange(location:0,length:match.range.location))
   guard prefixRange.location != NSNotFound else{continue}
   let range=NSRange(location:prefixRange.location,length:NSMaxRange(match.range)-prefixRange.location)
   let body=ns.substring(with:NSRange(location:NSMaxRange(prefixRange),length:match.range.location-NSMaxRange(prefixRange)))
   var title=metadata.title,comment=metadata.comment,images=metadata.images,notes=metadata.imageNotes
   if sessionFingerprint(Data(body.utf8)) != metadata.bodyHash{
    guard let values=extractTemplateValues(metadata.template,from:body),let screenshotText=values["{screenshots}"] else{continue}
    title=values["{title}"] ?? title;comment=values["{text}"] ?? comment
    let source=screenshotText as NSString;let imageMatches=links.matches(in:screenshotText,range:NSRange(location:0,length:source.length));images=[];notes=[:]
    for(i,imageMatch) in imageMatches.enumerated(){let filename=source.substring(with:imageMatch.range(at:1));images.append(filename);let end=i+1<imageMatches.count ? imageMatches[i+1].range.location:source.length;notes[filename]=source.substring(with:NSRange(location:NSMaxRange(imageMatch.range),length:end-NSMaxRange(imageMatch.range))).trimmingCharacters(in:.newlines)}
   }
   guard !images.isEmpty,images.allSatisfy({!$0.contains("/") && !$0.contains("\\") && fm.fileExists(atPath:folder.appendingPathComponent("assets").appendingPathComponent($0).path)}) else{continue}
   let original=ns.substring(with:range);recognized.append(range)
   result.append(PreviousSession(target:PreviousSessionTarget(path:file.path,start:range.location,length:range.length,original:original,fingerprint:sessionFingerprint(data)),title:title,comment:comment,images:images,modified:date,section:recognized.count,imageNotes:notes))
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
   let imageNames=links.matches(in:screenshots,range:NSRange(location:0,length:screenshotNS.length)).map{screenshotNS.substring(with:$0.range(at:1))}
   guard !imageNames.isEmpty,imageNames.allSatisfy({!$0.contains("/") && !$0.contains("\\") && fm.fileExists(atPath:folder.appendingPathComponent("assets").appendingPathComponent($0).path)}) else{continue}
   var comment=String(block[split.upperBound...]);if comment.hasSuffix("\n"){comment.removeLast()}
   let title=ns.substring(with:match.range(at:1));let date=(try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
   result.append(PreviousSession(target:PreviousSessionTarget(path:file.path,start:match.range.location,length:(block as NSString).length,original:block,fingerprint:sessionFingerprint(data)),title:title,comment:comment,images:imageNames,modified:date,section:i+1))
  }
 }
 return result.sorted{if $0.modified != $1.modified{return $0.modified>$1.modified};return $0.target.start>$1.target.start}
}
func checkedPreviousFile(_ target:PreviousSessionTarget)throws->String{
 let data=try Data(contentsOf:URL(fileURLWithPath:target.path))
 guard sessionFingerprint(data)==target.fingerprint,let string=String(data:data,encoding:.utf8),target.start>=0,target.length>=0,target.start+target.length<=(string as NSString).length,(string as NSString).substring(with:NSRange(location:target.start,length:target.length))==target.original else{
  throw NSError(domain:"ScreenshotNote",code:4,userInfo:[NSLocalizedDescriptionKey:L("Původní poznámka se mezitím změnila. Otevři výběr relací a vyber relaci znovu, aby se její nové změny nepřepsaly.")])
 }
 return string
}

/// Read edited user content using the literals surrounding the template's placeholders.
func extractTemplateValues(_ template:String,from body:String)->[String:String]?{
 let expression=try! NSRegularExpression(pattern:"\\{(?:title|screenshots|text)\\}")
 let source=template as NSString;let matches=expression.matches(in:template,range:NSRange(location:0,length:source.length));var pattern="\\A",offset=0;var keys:[String]=[]
 for match in matches{pattern+=NSRegularExpression.escapedPattern(for:source.substring(with:NSRange(location:offset,length:match.range.location-offset)))+"(.*?)";keys.append(source.substring(with:match.range));offset=NSMaxRange(match.range)}
 pattern+=NSRegularExpression.escapedPattern(for:source.substring(from:offset));if !template.hasSuffix("\n"){pattern+="\\n"};pattern+="\\z"
 guard let regex=try? NSRegularExpression(pattern:pattern,options:[.dotMatchesLineSeparators]),let match=regex.firstMatch(in:body,range:NSRange(location:0,length:(body as NSString).length)) else{return nil}
 var values:[String:String]=[:];let ns=body as NSString
 for(i,key) in keys.enumerated(){let value=ns.substring(with:match.range(at:i+1));if let existing=values[key],existing != value{return nil};values[key]=value}
 return values
}

/// Open an exported session without taking a new screenshot or touching its original assets.
func workingDraft(from session:PreviousSession,topic:Topic,root:URL)throws->Draft{
 _ = try checkedPreviousFile(session.target)
 let assets=URL(fileURLWithPath:session.target.path).deletingLastPathComponent().appendingPathComponent("assets")
 var target=session.target;target.imported=[:];var images:[String]=[];var notes:[String:String]=[:]
 do{
  for image in session.images{
   let name=UUID().uuidString+".png"
   let destination=root.appendingPathComponent(name);try fm.copyItem(at:assets.appendingPathComponent(image),to:destination);images.append(name)
   try copyAnnotationSidecar(from:assets.appendingPathComponent(image),to:destination);target.imported[name]=image;notes[name]=session.imageNotes[image]
  }
 }catch{for name in images{removeAnnotatedImage(root.appendingPathComponent(name))};throw error}
 return Draft(images:images,comment:session.comment,title:session.title,topic:topic,previous:target,imageNotes:notes)
}
