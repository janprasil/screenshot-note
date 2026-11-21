import AppKit

/// Výchozí šablony pro nové složky: lokálně bez účtu, s účtem z /api/v1/account/templates.
final class TemplateDefaults {
 static var shared=TemplateDefaults()
 private struct Remote:Codable {
  let session_template:String?;let file_template:String?;let revision:String?
  enum CodingKeys:String,CodingKey{case session_template,file_template,revision}
  // Vestavěná šablona se posílá jako explicitní null.
  func encode(to encoder:Encoder)throws{var c=encoder.container(keyedBy:CodingKeys.self);try c.encode(session_template,forKey:.session_template);try c.encode(file_template,forKey:.file_template);try c.encode(revision,forKey:.revision)}
 }
 private struct Envelope:Decodable{let data:Remote}
 private let store:UserDefaults
 private let connection:()->CloudConnection?
 private let request:(CloudEndpoint,String,String) async throws->Data
 private let send:(CloudEndpoint,String,String,Data) async throws->Data
 init(store:UserDefaults = .standard,connection:@escaping ()->CloudConnection? = {CloudLibrary.shared.connection},request:@escaping (CloudEndpoint,String,String) async throws->Data = {endpoint,path,token in try await CloudTransport.shared.request(endpoint,path,token:token)},send:@escaping (CloudEndpoint,String,String,Data) async throws->Data = {endpoint,path,token,body in try await CloudTransport.shared.request(endpoint,path,method:"PUT",token:token,body:body)}) {
  self.store=store;self.connection=connection;self.request=request;self.send=send
 }
 // nil znamená vestavěnou šablonu.
 var session:String?{store.string(forKey:"defaultSessionTemplate")}
 var file:String?{store.string(forKey:"defaultFileTemplate")}
 var effectiveSession:String{session ?? defaultMarkdownTemplate}
 var effectiveFile:String{file ?? defaultCombinedTemplate}
 /// Kopie výchozích šablon pro novou složku (šablona relace, šablona souboru nebo nil).
 var newFolderTemplates:(String,String?){(effectiveSession,file)}
 private var revision:String?{store.string(forKey:"defaultTemplatesRevision")}
 private func keep(_ session:String?,_ file:String?,revision:String?) {
  for (key,value) in [("defaultSessionTemplate",session),("defaultFileTemplate",file),("defaultTemplatesRevision",revision)]{if let value{store.set(value,forKey:key)}else{store.removeObject(forKey:key)}}
 }
 static func valid(session:String,file:String)->Bool{["{title}","{screenshots}","{text}"].allSatisfy{session.contains($0)} && session.count<=20000 && validCombinedTemplate(file)}
 /// Účet má přednost; starý server bez endpointu nechá lokální hodnoty.
 @MainActor func refresh() async {
  guard let c=connection(),c.ownerID != nil,let endpoint=CloudEndpoint(c.endpoint),
        let data=try? await request(endpoint,"/api/v1/account/templates",c.token),let remote=try? JSONDecoder().decode(Envelope.self,from:data).data else{return}
  // Neplatná šablona ze serveru se nepoužije.
  keep(remote.session_template.flatMap{validSessionTemplate($0) ? $0:nil},remote.file_template.flatMap{validCombinedTemplate($0) ? $0:nil},revision:remote.revision)
 }
 /// Uloží výchozí šablony; vestavěné hodnoty se ukládají jako null.
 @MainActor func save(session:String,file:String) async throws {
  guard Self.valid(session:session,file:file) else{throw CloudFailure(L("Šablona relace musí obsahovat {title}, {screenshots} a {text}; šablona souboru {sessions} právě jednou."))}
  let sessionValue=session==defaultMarkdownTemplate ? nil:session,fileValue=file==defaultCombinedTemplate ? nil:file
  guard let c=connection(),c.ownerID != nil,let endpoint=CloudEndpoint(c.endpoint) else{keep(sessionValue,fileValue,revision:nil);return}
  // První uložení na účet má revizi "0".
  let body=try JSONEncoder().encode(Remote(session_template:sessionValue,file_template:fileValue,revision:revision ?? "0"))
  do {
   let data=try await send(endpoint,"/api/v1/account/templates",c.token,body)
   let remote=try JSONDecoder().decode(Envelope.self,from:data).data
   keep(remote.session_template,remote.file_template,revision:remote.revision)
  }
  catch let failure as CloudFailure where failure.status==409 {await refresh();throw CloudFailure(L("Změněno jinde. Načetl jsem novou verzi."),status:409,code:failure.code)}
  // Server bez výchozích šablon: hodnoty zůstanou aspoň na tomto Macu.
  catch let failure as CloudFailure where failure.status==404 {keep(sessionValue,fileValue,revision:nil)}
 }
 /// Po odhlášení zůstanou poslední hodnoty účtu jako lokální.
 func forgetAccount(){store.removeObject(forKey:"defaultTemplatesRevision")}
}

/// Nápověda proměnných šablon pro editor; jediné místo textu.
var sessionTemplateHint:String{L("Proměnné: {title}, {screenshots}, {text}, {comments}, {author}")}
var fileTemplateHint:String{L("Proměnné: {folderName}, {folderDescription}, {sessions}")}
/// Počet relací ve složce, kterých se změna šablony týká.
func indexedSessionCount(_ topic:Topic)->Int {
 let folder=SessionIndex.key(topic.destination)
 if let id=topic.cloudFolderID?.uuidString.lowercased(){return SessionIndex.shared.all.filter{$0.isCloud && $0.folder==id && $0.trashed != true}.count}
 return SessionIndex.shared.all.filter{!$0.isCloud && SessionIndex.key($0.directory)==folder}.count
}
/// Přerenderuje relace lokální složky novou šablonou; upravené dostanou vedle soubor _template.md.
@discardableResult func rerenderFolder(_ topic:Topic,previous:Topic)->(updated:Int,edited:Int) {
 guard topic.cloudFolderID==nil else{return (0,0)}
 migrateLegacyMarkers(in:topic.destination)
 let index=SessionIndex.shared,folder=SessionIndex.key(topic.destination),template=topic.markdownTemplate ?? defaultMarkdownTemplate
 let records=index.all.filter{!$0.isCloud && SessionIndex.key($0.directory)==folder}
 func body(_ r:SessionRecord)->String{renderSessionTemplate(template,title:r.title,screenshots:screenshotsMarkdown(r.images,r.images.map{r.notes[$0] ?? ""}),text:r.comment)}
 func exact(_ r:SessionRecord,_ ns:NSString)->Bool{r.start>=0 && r.start+r.length<=ns.length && sessionFingerprint(Data(ns.substring(with:NSRange(location:r.start,length:r.length)).utf8))==r.hash}
 var updated=0,edited=0
 index.batch {
  for (path,group) in Dictionary(grouping:records,by:\.file) {
   let file=URL(fileURLWithPath:path)
   guard let text=(try? boundedData(file,max:20000000)).flatMap({String(data:$0,encoding:.utf8)}) else{continue}
   let ns=text as NSString,blocks=group.sorted{$0.start<$1.start},stem=(file.lastPathComponent as NSString).deletingPathExtension
   let sidecar=file.deletingLastPathComponent().appendingPathComponent(stem+"_template.md")
   if blocks.count==1 && !blocks[0].combined {
    var r=blocks[0];let next=body(r)
    guard exact(r,ns),r.start==0,r.length==ns.length else{_ = try? writeGeneratedCopy(Data(next.utf8),to:sidecar);edited+=1;continue}
    guard (try? Data(next.utf8).write(to:file,options:.atomic)) != nil else{continue}
    r.length=(next as NSString).length;r.hash=sessionFingerprint(Data(next.utf8));r.heading=firstLine(next);r.template=template;index.put(r);writeSessionTag(file,r.id);updated+=1
    continue
   }
   // Společný soubor se přepíše jen tehdy, když odpovídá přesně tomu, co aplikace zapsala.
   let (oldHeader,oldFooter)=combinedTemplateParts(previous.combinedTemplate ?? defaultCombinedTemplate,folderName:previous.name,folderDescription:previous.detail)
   let (header,footer)=combinedTemplateParts(topic.combinedTemplate ?? defaultCombinedTemplate,folderName:topic.name,folderDescription:topic.detail)
   let old=blocks.map{ns.substring(with:NSRange(location:min($0.start,ns.length),length:max(0,min($0.length,ns.length-$0.start))))}
   let pristine=blocks.allSatisfy{exact($0,ns)} && oldHeader+old.joined(separator:"\n\n---\n\n")+oldFooter==text
   var output=header,placed:[(SessionRecord,Int,String)]=[]
   for (i,r) in blocks.enumerated(){if i>0{output+="\n\n---\n\n"};let value=body(r);placed.append((r,(output as NSString).length,value));output+=value}
   output+=footer
   if !pristine{_ = try? writeGeneratedCopy(Data(output.utf8),to:sidecar);edited+=max(1,blocks.filter{!exact($0,ns)}.count);continue}
   guard (try? Data(output.utf8).write(to:file,options:.atomic)) != nil else{continue}
   for (r,start,value) in placed{var next=r;next.start=start;next.length=(value as NSString).length;next.hash=sessionFingerprint(Data(value.utf8));next.heading=firstLine(value);next.template=template;next.footer=footer;index.put(next);updated+=1}
   tagCombinedFile(file)
  }
 }
 return (updated,edited)
}
