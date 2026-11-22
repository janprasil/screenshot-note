import AppKit
import CryptoKit

private struct FolderEnvelope<T:Decodable>:Decodable{let data:T}
private struct RemoteFolder:Decodable {
 let id:UUID;let name:String;let revision:String
 let description:String?;let combined:Bool?;let combined_file:String?;let markdown_template:String?;let combined_template:String?
 // Týmy: starší server pole neposílá a složka je osobní.
 var owner_id:UUID? = nil;var owner_kind:String? = nil;var owner_name:String? = nil;var role:String? = nil
 // Šablony položek; items říká, že je server zná (starší server neposílá klíče a cizí odmítne).
 var comment_template:String? = nil;var image_template:String? = nil;var items=false
 enum CodingKeys:String,CodingKey{case id,name,revision,description,combined,combined_file,markdown_template,combined_template,owner_id,owner_kind,owner_name,role,comment_template,image_template}
 init(from decoder:Decoder)throws {
  let c=try decoder.container(keyedBy:CodingKeys.self)
  id=try c.decode(UUID.self,forKey:.id);name=try c.decode(String.self,forKey:.name);revision=try c.decode(String.self,forKey:.revision)
  description=try c.decodeIfPresent(String.self,forKey:.description);combined=try c.decodeIfPresent(Bool.self,forKey:.combined);combined_file=try c.decodeIfPresent(String.self,forKey:.combined_file)
  markdown_template=try c.decodeIfPresent(String.self,forKey:.markdown_template);combined_template=try c.decodeIfPresent(String.self,forKey:.combined_template)
  owner_id=try c.decodeIfPresent(UUID.self,forKey:.owner_id);owner_kind=try c.decodeIfPresent(String.self,forKey:.owner_kind);owner_name=try c.decodeIfPresent(String.self,forKey:.owner_name);role=try c.decodeIfPresent(String.self,forKey:.role)
  comment_template=try c.decodeIfPresent(String.self,forKey:.comment_template);image_template=try c.decodeIfPresent(String.self,forKey:.image_template)
  items=c.contains(.comment_template) && c.contains(.image_template)
 }
 func record(owner account:UUID,origin:String,library:UUID?=nil)->CloudFolderRecord {
  var value=CloudFolderRecord(id:id,name:name,owner:owner_id ?? library ?? account,origin:origin,revision:revision,description:description,combined:combined,combinedFile:combined_file,markdownTemplate:markdown_template,combinedTemplate:combined_template)
  value.accountID=account;value.ownerKind=owner_kind;value.ownerName=owner_name;value.role=role
  if items{value.commentTemplate=comment_template;value.imageTemplate=image_template;value.itemTemplates=true}
  return value
 }
}
private struct FolderSettingsBody:Encodable {
 let name:String;let description:String;let combined:Bool;let combined_file:String;let markdown_template:String?;let combined_template:String?;let revision:String?
 var owner_id:UUID? = nil
 // Jen když server šablony položek zná; nil = beze změny.
 var items:(comment:String?,image:String?)? = nil
 enum CodingKeys:String,CodingKey{case name,description,combined,combined_file,markdown_template,combined_template,revision,owner_id,comment_template,image_template}
 // Prázdné šablony a revize se posílají jako null.
 func encode(to encoder:Encoder)throws {
  var c=encoder.container(keyedBy:CodingKeys.self)
  try c.encode(name,forKey:.name);try c.encode(description,forKey:.description);try c.encode(combined,forKey:.combined);try c.encode(combined_file,forKey:.combined_file)
  try c.encode(markdown_template,forKey:.markdown_template);try c.encode(combined_template,forKey:.combined_template);try c.encode(revision,forKey:.revision)
  if let owner_id{try c.encode(owner_id.uuidString.lowercased(),forKey:.owner_id)}
  if let items{try c.encode(items.comment,forKey:.comment_template);try c.encode(items.image,forKey:.image_template)}
 }
}
private struct RemoteNoteList:Decodable {
 struct Note:Decodable{let id:UUID;let deleting:Bool?;let updated_at:String?;let created_at:String?;let trashed_at:String?;var revision:FlexibleString? = nil;var author:CloudAuthor? = nil}
 struct Pagination:Decodable{let has_more:Bool}
 let data:[Note];let pagination:Pagination
}
private struct RemoteNoteStamp:Decodable{let updated_at:String?;let created_at:String?;let trashed_at:String?;let revision:FlexibleString?}
// Účtenka stažení; starší verze byla jen text „otisk\nadresář“.
private struct DownloadReceipt:Codable {
 var fingerprint:String;var name:String
 var updated:String? = nil;var shas:[String]? = nil;var files:[String:String]? = nil;var note:RemoteNote? = nil
}

final class CloudFolders {
 static let shared=CloudFolders()
 private let file:URL
 private let currentConnection:()->CloudConnection?
 private let localTopics:()->[Topic]
 private let request:(CloudEndpoint,String,String,Int) async throws->Data
 private let send:(CloudEndpoint,String,String,String,Data) async throws->Data
 private let now:()->Date
 private let storedLocal:()->[Topic]
 private let saveLocal:([Topic])throws->Void
 private let recycle:(URL)throws->Void
 private let pending:(UUID)->Bool
 private(set) var records:[CloudFolderRecord]=[]
 private var account:(UUID,String)?
 private var readable=true
 var isReadable:Bool{readable}
 private(set) var syncing=false
 var lastError:String?
 // Upozornění ze synchronizace koše, každé jen jednou za relaci.
 private var messages:[String]=[]
 /// Upozornění: jednorázové zprávy a živý stav zadržených mazání (zmizí po vyřešení).
 var notices:[String]{messages+heldFolders.map{LP($0.1,"Ve složce %@ zmizela %ld relace. Čeká na potvrzení přesunu do Koše (Zmizelé relace…).","Ve složce %@ zmizely %ld relace. Čeká na potvrzení přesunu do Koše (Zmizelé relace…).","Ve složce %@ zmizelo %ld relací. Čeká na potvrzení přesunu do Koše (Zmizelé relace…).",$0.0.displayName,$0.1)}}
 /// Totožnost zadržené dávky; nová dávka se ptá znovu.
 func heldBatch(_ topic:Topic)->String{SessionIndex.shared.all.filter{$0.held==true && Self.inFolder($0,topic)}.map(\.id).sorted().joined(separator:",")}
 /// Záznam indexu patří do složky (a do jejího adresáře; stejnou týmovou složku můžou mít dva účty).
 static func inFolder(_ record:SessionRecord,_ topic:Topic)->Bool{record.folder==topic.cloudFolderID?.uuidString.lowercased() && (topic.folder.isEmpty || record.base==nil || record.base==SessionIndex.key(topic.destination))}
 /// Záznam patří aktivnímu účtu.
 private func mine(_ record:CloudFolderRecord)->Bool{account.map{record.account==$0.0 && record.origin==$0.1} ?? false}
 private func matches(_ record:CloudFolderRecord,_ topic:Topic)->Bool{mine(record) && record.id==topic.cloudFolderID && record.owner==topic.cloudOwnerID && record.origin==topic.cloudOrigin}
 /// Osobní a týmové složky aktivního účtu; osobní první, jinak pořadí katalogu.
 var topics:[Topic]{let list=records.filter{mine($0) && $0.remoteDeleted != true && $0.unavailable != true};return (list.filter{!$0.isTeam}+list.filter(\.isTeam)).map(\.topic)}
 /// Složky smazané na webu, které mají místní adresář.
 var deletedRemotely:[CloudFolderRecord]{records.filter{mine($0) && $0.remoteDeleted==true && $0.unavailable != true}}
 /// Složka aktivního účtu skrytá po ztrátě přístupu k týmu.
 func isUnavailable(_ topic:Topic)->Bool{records.contains{matches($0,topic) && $0.unavailable==true}}
 /// Název a typ složky podle ID pro hlášky fronty.
 func folderInfo(_ id:UUID)->(name:String,team:Bool)?{records.first{mine($0) && $0.id==id}.map{($0.topic.displayName,$0.isTeam)}}
 var allTopics:[Topic]{records.map(\.topic)}
 var migratedLocalIDs:Set<String>{Set(records.flatMap{$0.migratedLocalIDs ?? []})}
 init(file:URL=draftRoot.deletingLastPathComponent().appendingPathComponent("Cloud Folders.json"),connection:@escaping ()->CloudConnection? = {CloudLibrary.shared.connection},localTopics:@escaping ()->[Topic] = {Topics.local},request:@escaping (CloudEndpoint,String,String,Int) async throws->Data = {endpoint,path,token,limit in try await CloudTransport.shared.request(endpoint,path,token:token,limit:limit)},send:@escaping (CloudEndpoint,String,String,String,Data) async throws->Data = {endpoint,path,method,token,body in try await CloudTransport.shared.request(endpoint,path,method:method,token:token,body:body)},now:@escaping ()->Date = Date.init,pending:@escaping (UUID)->Bool = {CloudLibrary.shared.hasPending($0)},storedLocal:@escaping ()->[Topic] = {Topics.storedLocal},saveLocal:@escaping ([Topic])throws->Void = {try Topics.storeLocal($0)},recycle:@escaping (URL)throws->Void = {try fm.trashItem(at:$0,resultingItemURL:nil)}) {
  self.file=file;currentConnection=connection;self.localTopics=localTopics;self.request=request;self.send=send;self.now=now;self.pending=pending;self.storedLocal=storedLocal;self.saveLocal=saveLocal;self.recycle=recycle
  if fm.fileExists(atPath:file.path) {
   do {let data=try Data(contentsOf:file);guard data.count<=2000000 else{throw CloudFailure.invalid};records=try JSONDecoder().decode([CloudFolderRecord].self,from:data)}
   catch{readable=false;lastError=L("Uložené cloudové složky nelze načíst. Místní data zůstávají zachovaná.")}
  }
 }
 func activate(_ connection:CloudConnection?){account=connection.flatMap{c in c.ownerID.map{($0,c.endpoint)}}}
 private func persist(_ updated:[CloudFolderRecord])throws {
  guard readable else{throw CloudFailure.invalid}
  let hidden=Set(updated.flatMap{$0.migratedLocalIDs ?? []})
  try Topics.validateDestinations(localTopics().filter{!hidden.contains($0.id)}+updated.map(\.topic))
  let data=try JSONEncoder().encode(updated);guard data.count<=2000000 else{throw CloudFailure.invalid}
  try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  try data.write(to:file,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);records=updated
 }
 func setFolder(_ topic:Topic,path:String)throws {
  guard let i=records.firstIndex(where:{matches($0,topic) && $0.unavailable != true}) else{throw CloudFailure.invalid}
  var updated=records;updated[i].folder=path
  try persist(updated)
 }
 /// Katalog aktivního účtu. `libraries` z /me; nil (starší server) znamená jen osobní library.
 func accept(_ folders:[CloudFolderRecord],libraries:[CloudLibraryRef]?=nil)throws {
  guard let account else{throw CloudFailure.invalid}
  let teams=Dictionary((libraries ?? []).filter{$0.isTeam && $0.id != account.0}.map{($0.id,$0)},uniquingKeysWith:{a,_ in a})
  guard folders.count<=400,Set(folders.map{[$0.owner,$0.id]}).count==folders.count,
        folders.allSatisfy({$0.account==account.0 && $0.origin==account.1 && ($0.owner==account.0 || teams[$0.owner] != nil) && !$0.name.isEmpty && $0.name.unicodeScalars.count<=100 && !$0.name.contains("\0") && ($0.ownerName?.unicodeScalars.count ?? 0)<=100 && ($0.markdownTemplate?.utf8.count ?? 0)<=100000 && ($0.combinedTemplate?.utf8.count ?? 0)<=100000 && ($0.description?.utf8.count ?? 0)<=10000}) else{throw CloudFailure.invalid}
  var updated=records.filter{!mine($0)},lost:[CloudFolderRecord]=[]
  for var folder in folders {
   let previous=records.first(where:{mine($0) && $0.id==folder.id && $0.owner==folder.owner})
   folder.folder=previous?.folder ?? "";folder.migratedLocalIDs=previous?.migratedLocalIDs;folder.confirmLocalDeletes=previous?.confirmLocalDeletes
   folder.accountID=account.0;folder.unavailable=nil
   // Týmová složka: chybějící název a role se doplní z /me.
   if let team=teams[folder.owner]{folder.ownerKind=LibraryKind.team.rawValue;folder.ownerName=folder.ownerName ?? team.name;folder.role=folder.role ?? team.role}
   else{folder.ownerKind=LibraryKind.personal.rawValue;folder.ownerName=nil;folder.role=nil}
   if let name=folder.combinedFile,!validCombinedFile(name){folder.combinedFile=nil}
   updated.append(folder)
  }
  for var previous in records where mine(previous) && !folders.contains(where:{$0.id==previous.id && $0.owner==previous.owner}) {
   // Tým zmizel z /me: záznam zůstává skrytý i s mapováním, nic se nemaže ani nepřesouvá.
   if previous.owner != account.0 && teams[previous.owner]==nil{if previous.unavailable != true{lost.append(previous)};previous.accountID=account.0;previous.unavailable=true;updated.append(previous);continue}
   // Na webu smazaná složka s místním adresářem čeká na rozhodnutí, nic se nemaže.
   if !previous.folder.isEmpty{previous.remoteDeleted=true;previous.unavailable=nil;updated.append(previous)}
  }
  try persist(updated)
  // Rozpracované detekce mazání se zahodí, aby se po návratu do týmu nic neodvodilo ze staré doby.
  if !lost.isEmpty {
   let index=SessionIndex.shared
   index.batch{for var record in index.all where lost.contains(where:{Self.inFolder(record,$0.topic)}) && (record.missingSince != nil || record.held != nil || record.askDelete != nil) && record.keptLocal != true{record.missingSince=nil;record.held=nil;record.askDelete=nil;record.confirmed=nil;index.put(record)}}
  }
 }
 private func localCopy(_ record:CloudFolderRecord)->Topic {
  // Týmovou složku mohou mít dva účty; její lokální kopie má v ID i účet.
  var topic=Topic(id:"former-cloud:"+(record.isTeam ? record.account.uuidString.lowercased()+":":"")+record.id.uuidString.lowercased(),name:record.name,detail:record.description ?? "",folder:record.folder,combined:record.combined ?? false,combinedFile:record.combinedFile.flatMap{$0.isEmpty ? nil:$0} ?? defaultCombinedFile,markdownTemplate:record.markdownTemplate,combinedTemplate:record.combinedTemplate)
  topic.formerCloudFolderID=record.id;topic.formerCloudOwnerID=record.owner;topic.formerCloudOrigin=record.origin
  topic.commentTemplate=record.commentTemplate;topic.imageTemplate=record.imageTemplate
  return topic
 }
 // Lokální složky dříve přesunuté do cloudu se stejným adresářem nahradí nová lokální kopie.
 private func superseded(_ record:CloudFolderRecord,_ list:[Topic])->Set<String> {
  let ids=Set(record.migratedLocalIDs ?? []),target=try? Topics.checkedDestination(record.folder)
  return Set(list.filter{topic in ids.contains(topic.id) && (target.map{t in (try? Topics.checkedDestination(topic.folder)).map{Topics.sameDestination($0,t)} ?? false} ?? false)}.map(\.id))
 }
 private func without(_ chosen:[CloudFolderRecord])->[CloudFolderRecord]{records.filter{record in !chosen.contains{$0.id==record.id && $0.owner==record.owner && $0.origin==record.origin && $0.account==record.account}}}
 /// Po odhlášení se cloudové složky účtu stanou lokálními; adresáře, soubory i index zůstávají.
 /// Skryté týmové složky zůstávají záznamem, aby po návratu do týmu navázaly.
 @discardableResult func convertToLocal(owner:UUID,origin:String,only:Set<UUID>?=nil)throws->[String:String] {
  guard readable else{throw CloudFailure.invalid}
  // Při odhlášení zůstávají týmové složky skrytým záznamem s mapováním; po přihlášení navážou bez reconnectu.
  let chosen=records.filter{record in record.account==owner && record.origin==origin && record.unavailable != true && (only.map{$0.contains(record.id)} ?? !record.isTeam)}
  guard !chosen.isEmpty else{return [:]}
  var local=storedLocal(),mapping:[String:String]=[:]
  for record in chosen where !record.folder.isEmpty {
   let topic=localCopy(record),old=superseded(record,local)
   local.removeAll{old.contains($0.id) || $0.id==topic.id};local.append(topic)
   mapping[record.topic.id]=topic.id;for id in old{mapping[id]=topic.id}
  }
  let remaining=without(chosen)
  try Topics.validateDestinations(local+remaining.map(\.topic))
  try saveLocal(local);try persist(remaining)
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
  return mapping
 }
 /// Na webu smazaná složka zůstane jako lokální.
 @discardableResult func keepDeleted(_ id:UUID)throws->[String:String] {
  guard let record=deletedRemotely.first(where:{$0.id==id}) else{return [:]}
  return try convertToLocal(owner:record.account,origin:record.origin,only:[id])
 }
 /// Na webu smazaná složka se přesune do Koše v macOS.
 func discardDeleted(_ id:UUID)throws {
  guard let record=deletedRemotely.first(where:{$0.id==id}) else{return}
  try recycleFolder(record.folder)
  let old=superseded(record,storedLocal());if !old.isEmpty{try saveLocal(storedLocal().filter{!old.contains($0.id)})}
  try persist(without([record]));NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
 }
 /// Soubory, které zapsala aplikace: Markdown relací, jejich obrázky (v kořeni i v podsložkách) a vygenerované kopie.
 func knownFiles(_ directory:URL)->Set<String> {
  let key=SessionIndex.key(directory),assets=directory.appendingPathComponent("assets")
  var known=Set<String>()
  func add(_ url:URL){if fm.fileExists(atPath:url.path){known.insert(SessionIndex.key(url))}}
  for record in SessionIndex.shared.all where record.file.hasPrefix(key+"/") && !record.file.hasPrefix(key+"/.trash/") {
   let markdown=URL(fileURLWithPath:record.file),parent=markdown.deletingLastPathComponent()
   add(markdown)
   // Plochá relace má obrázky ve společném assets/, starší podsložka ve vlastním.
   let flat=record.flat==true || SessionIndex.key(parent)==key
   for image in record.images{let directory=flat ? assets:parent.appendingPathComponent("assets");add(directory.appendingPathComponent(image));for file in assetContextFiles(directory,image){add(file)}
    // Video: MP4 a soubory ve složce snímků patří relaci.
    let video=assetVideoFiles(directory,image);add(video[0]);for file in regularFiles(video[1]){add(file)}}
   if !flat{for name in record.files.keys{add(parent.appendingPathComponent(name))}}
  }
  for path in SessionIndex.shared.generatedFiles where path.hasPrefix(key+"/") && !path.hasPrefix(key+"/.trash/"){add(URL(fileURLWithPath:path))}
  return known
 }
 /// Běžné soubory stromu bez skrytých položek (včetně .trash).
 private func regularFiles(_ url:URL)->[URL] {
  guard let walker=fm.enumerator(at:url,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else{return []}
  return walker.compactMap{$0 as? URL}.filter{(try? $0.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile==true}
 }
 /// Co jde do Koše: podsložka jen se soubory aplikace celá, jinak jednotlivé známé soubory.
 func knownItems(_ directory:URL)->[URL] {
  let known=knownFiles(directory);var items:[URL]=[]
  for child in ((try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])) ?? []).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
   guard (try? child.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory==true else{if known.contains(SessionIndex.key(child)){items.append(child)};continue}
   let inside=regularFiles(child)
   if child.lastPathComponent != "assets",!inside.isEmpty,inside.allSatisfy({known.contains(SessionIndex.key($0))}){items.append(child)}
   else{items+=inside.filter{known.contains(SessionIndex.key($0))}}
  }
  return items
 }
 /// Adresář (rekurzivně, i assets/ a podsložky) obsahuje soubory, které aplikace nezná.
 func hasUnknownFiles(_ path:String)->Bool {
  let directory=URL(fileURLWithPath:path,isDirectory:true),known=knownFiles(directory)
  return regularFiles(directory).contains{!known.contains(SessionIndex.key($0))}
 }
 /// Celý adresář jde do Koše jen bez cizích souborů; jinak se přesunou jen soubory aplikace.
 private func recycleFolder(_ path:String)throws {
  guard !path.isEmpty,fm.fileExists(atPath:path) else{return}
  let directory=URL(fileURLWithPath:path,isDirectory:true)
  if !hasUnknownFiles(path){try recycle(directory);return}
  for item in knownItems(directory){try recycle(item)}
  let assets=directory.appendingPathComponent("assets")
  if let left=try? fm.contentsOfDirectory(atPath:assets.path),left.allSatisfy({$0.hasPrefix(".")}){try recycle(assets)}
 }
 /// Lokální složky, které dřív patřily do cloudu tohoto účtu a ta složka na webu pořád je.
 var repairCandidates:[Topic] {
  guard let account else{return []}
  let hidden=migratedLocalIDs,active=topics
  return storedLocal().filter{local in local.formerCloudOrigin==account.1 && local.formerCloudOwnerID==account.0 && !hidden.contains(local.id) && active.contains{$0.cloudFolderID != nil && $0.cloudFolderID==local.formerCloudFolderID && $0.cloudOwnerID==local.formerCloudOwnerID}}
 }
 /// Znovupropojení: místní relace se nahrají existující cestou přesunu, cloudové se stáhnou.
 @MainActor func repair(_ source:Topic,library:CloudLibrary = .shared,transfers:FolderTransfers = .shared)async throws->Bool {
  guard let target=topics.first(where:{$0.cloudFolderID != nil && $0.cloudFolderID==source.formerCloudFolderID}) else{throw CloudFailure.invalid}
  // Po propojení se každá relace porovná s cloudem znovu, aby rozdílné verze dostaly _cloud.md.
  let former=source.formerCloudFolderID!.uuidString.lowercased(),index=SessionIndex.shared
  index.batch{for var record in index.all where record.isCloud && record.folder==former && record.digest != nil{record.digest=nil;record.updated=nil;index.put(record)}}
  return try await transfers.move(source,to:target,library:library,folders:self)
 }
 /// Smaže cloudovou složku (30 dní v Koši na webu) a místní adresář přesune do Koše v macOS.
 @MainActor func trashFolder(_ topic:Topic)async throws {
  guard let c=currentConnection(),let endpoint=CloudEndpoint(c.endpoint),let id=topic.cloudFolderID,topic.cloudOrigin==c.endpoint,account?.0==c.ownerID,
        let record=records.first(where:{matches($0,topic) && $0.unavailable != true}) else{throw CloudFailure.invalid}
  guard record.topic.canManageCloudFolder else{throw Self.forbidden}
  do{_ = try await send(endpoint,"/api/v1/folders/"+id.uuidString.lowercased()+"/trash","POST",c.token,Data("{}".utf8))}
  catch let failure as CloudFailure where failure.status==404 && failure.code != "not_found"{throw CloudFailure(L("Server zatím mazání cloudových složek nepodporuje. Nic se nesmazalo."),status:404)}
  catch let failure as CloudFailure where failure.status==404{}
  catch let failure as CloudFailure{throw Self.friendly(failure)}
  guard currentConnection()?.token==c.token else{throw CloudFailure.invalid}
  let old=superseded(record,storedLocal());if !old.isEmpty{try saveLocal(storedLocal().filter{!old.contains($0.id)})}
  try persist(without([record]))
  try recycleFolder(record.folder)
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
 }
 /// Lokální složka zmizí z aplikace a její adresář jde do Koše v macOS.
 func deleteLocalFolder(_ topic:Topic)throws {
  guard topic.cloudFolderID==nil else{throw CloudFailure.invalid}
  try recycleFolder(topic.folder)
  try saveLocal(storedLocal().filter{$0.id != topic.id})
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
 }
 /// Potvrzeně nahraná místní relace se zapíše jako materializace cloudové relace na svém místě.
 func adoptUpload(_ session:PreviousSession,id:UUID,source:Topic,target:Topic,changed:Bool) {
  guard let base=try? Topics.checkedDestination(source.folder) else{return}
  let file=URL(fileURLWithPath:session.target.path),directory=file.deletingLastPathComponent(),lower=id.uuidString.lowercased(),index=SessionIndex.shared
  let title=session.title.trimmingCharacters(in:.whitespacesAndNewlines),heading=title.isEmpty ? "Screenshot":title,template=source.markdownTemplate ?? defaultMarkdownTemplate
  let path="/api/v1/sessions/"+lower,assets=directory.appendingPathComponent("assets")
  var note=RemoteNote(id:id,title:heading,comment:session.comment,template:template,captions:session.images.map{session.imageNotes[$0] ?? ""},images:session.images.indices.map{.init(index:$0+1,path:path+"/images/\($0+1)")})
  // Otisk odpovídá souboru vykreslenému šablonami zdrojové složky.
  note.comment_template=source.commentTemplate;note.image_template=source.imageTemplate
  let local=index.records(file:file).first{$0.id==session.target.session && !$0.isCloud}
  var record=SessionRecord(id:lower,file:SessionIndex.key(file),start:session.target.start,length:session.target.length,hash:sessionFingerprint(Data(session.target.original.utf8)),heading:firstLine(session.target.original),title:heading,comment:session.comment,template:template,images:session.images,notes:session.imageNotes,combined:source.combined,footer:local?.footer ?? "",files:[:],seen:0,base:SessionIndex.key(base),folder:target.cloudFolderID?.uuidString.lowercased(),owner:target.cloudOwnerID?.uuidString.lowercased(),origin:target.cloudOrigin)
  // Změna během přesunu: bez otisku serveru se cloudová verze zapíše vedle jako _cloud.
  record.digest=changed ? nil:sessionFingerprint((try? JSONEncoder.sorted.encode(note)) ?? Data())
  record.shas=session.images.map{(try? cloudImage(assets.appendingPathComponent($0))).map(sessionFingerprint) ?? ""}
  record.render=cloudRenderVersion;record.imageTemplate=source.imageTemplate
  var hashes:[String:String]=[:];for image in session.images{hashes["assets/"+image]=fileHash(assets.appendingPathComponent(image))}
  if source.combined{record.note=note;record.stem=uniqueStem(readableSessionName(heading,created:Date()),base:base);record.files=hashes}
  else{hashes[file.lastPathComponent]=fileHash(file);record.files=hashes}
  index.batch{if let local{index.remove(local)};index.put(record)}
  if source.combined{tagCombinedFile(file)}else if SessionIndex.key(directory)==SessionIndex.key(base){writeSessionTag(file,lower)}else{writeSessionTag(directory,lower);writeSessionTag(file,lower)}
 }
 /// Upravit nebo doplnit relaci týmové složky smí autor nebo vlastník/správce; neznámý autor = cizí.
 func mayChange(_ id:UUID,topic:Topic)->Bool {
  guard !topic.canManageCloudFolder else{return true}
  guard let account,!topic.folder.isEmpty,let base=try? Topics.checkedDestination(topic.folder),let record=SessionIndex.shared.cloud(id,base:base) else{return false}
  return record.authorID==account.0.uuidString.lowercased()
 }
 /// Původní texty a revize stažené cloudové relace pro úpravu PATCHem.
 func editBase(_ id:UUID,topic:Topic)->(CloudLibrary.CloudEdit.Fields,String?)? {
  guard !topic.folder.isEmpty,let base=try? Topics.checkedDestination(topic.folder),let r=SessionIndex.shared.cloud(id,base:base),r.trashed != true,r.askDelete != true else{return nil}
  return (.init(title:r.title,comment:r.comment,captions:r.images.map{r.notes[$0] ?? ""}),r.revision)
 }
 /// Při konfliktu úprav zůstane místní text v souboru relace; stahování pak zapíše cloudovou verzi jako _cloud.md.
 func keepLocalEdit(_ id:UUID,_ fields:CloudLibrary.CloudEdit.Fields) {
  for r in SessionIndex.shared.all where r.isCloud && r.id==id.uuidString.lowercased() && r.stem==nil && r.trashed != true {
   let file=URL(fileURLWithPath:r.file)
   guard fileHash(file)==r.files[file.lastPathComponent],r.images.count==fields.captions.count else{continue}
   let screenshots=renderImageBlocks(zip(r.images,fields.captions.map(escapeServerMarkdown)).map{ImageBlock(name:$0.0,caption:$0.1)},template:r.imageTemplate)
   try? Data(renderSessionTemplate(r.template,title:serverTitle(fields.title),screenshots:screenshots,text:escapeServerMarkdown(fields.comment),author:serverTitle(r.author ?? "")).utf8).write(to:file,options:.atomic);writeSessionTag(file,r.id)
  }
 }
 func finishTransfer(_ source:Topic,to target:Topic)throws {
  // Cíl je osobní nebo dostupná týmová složka aktivního účtu.
  guard let account,source.cloudFolderID==nil,target.cloudOrigin==account.1,
        let index=records.firstIndex(where:{matches($0,target) && $0.unavailable != true}) else{throw CloudFailure.invalid}
  var updated=records
  if updated[index].folder.isEmpty{updated[index].folder=source.folder}
  updated[index].migratedLocalIDs=Array(Set((updated[index].migratedLocalIDs ?? [])+[source.id])).sorted()
  try persist(updated)
  if UserDefaults.standard.string(forKey:"defaultTopic")==source.id{UserDefaults.standard.set(updated[index].topic.id,forKey:"defaultTopic")}
 }
 @MainActor func create(_ name:String,team:CloudLibraryRef?=nil)async throws->Topic {
  guard let c=currentConnection(),let account=c.ownerID,team.map({$0.isTeam && LibraryRole.manages($0.role)}) != false,let endpoint=CloudEndpoint(c.endpoint),!name.isEmpty,name.unicodeScalars.count<=100,!name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{throw CloudFailure.invalid}
  activate(c)
  let owner=team?.id ?? account
  let directory=file.deletingLastPathComponent().appendingPathComponent("Cloud Folder Operations")
  try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let key=SHA256.hash(data:Data((c.endpoint+(team == nil ? "":account.uuidString+":")+owner.uuidString+"\0"+name).utf8)).map{String(format:"%02x",$0)}.joined()
  let intent=directory.appendingPathComponent(key)
  let id:UUID
  if fm.fileExists(atPath:intent.path){guard let saved=UUID(uuidString:try String(contentsOf:intent,encoding:.utf8)) else{throw CloudFailure.invalid};id=saved}
  else{id=UUID();try Data(id.uuidString.utf8).write(to:intent,options:.atomic)}
  // Vytvoření je PUT s revizí null.
  let body=try JSONEncoder().encode(FolderSettingsBody(name:name,description:"",combined:false,combined_file:defaultCombinedFile,markdown_template:TemplateDefaults.shared.session,combined_template:TemplateDefaults.shared.file,revision:nil,owner_id:team?.id))
  let data:Data
  do{data=try await send(endpoint,"/api/v1/folders/"+id.uuidString.lowercased(),"PUT",c.token,body)}catch let failure as CloudFailure{throw Self.friendly(failure)}
  let result=try JSONDecoder().decode(FolderEnvelope<RemoteFolder>.self,from:data).data
  guard currentConnection()?.token==c.token,result.id==id,result.name==name else{throw CloudFailure.invalid}
  var updated=records
  if !updated.contains(where:{$0.id==id && $0.owner==owner && $0.account==account && $0.origin==c.endpoint}){
   var created=result.record(owner:account,origin:c.endpoint,library:team?.id);guard created.owner==owner else{throw CloudFailure.invalid}
   created.ownerKind=(team == nil ? LibraryKind.personal:LibraryKind.team).rawValue;created.ownerName=team?.name;created.role=team?.role;updated.append(created)
  }
  try persist(updated);NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
  return updated.first{$0.id==id && $0.owner==owner && $0.account==account && $0.origin==c.endpoint}!.topic
 }
 /// Uloží nastavení cloudové složky na server; při konfliktu načte novou verzi.
 @MainActor func update(_ topic:Topic)async throws->Topic {
  guard let c=currentConnection(),let owner=c.ownerID,let endpoint=CloudEndpoint(c.endpoint),let id=topic.cloudFolderID,topic.cloudOrigin==c.endpoint else{throw CloudFailure.invalid}
  activate(c)
  guard let record=records.first(where:{matches($0,topic) && $0.unavailable != true}) else{throw CloudFailure.invalid}
  guard record.topic.canManageCloudFolder else{throw Self.forbidden}
  var settings=FolderSettingsBody(name:topic.name,description:topic.detail,combined:topic.combined,combined_file:topic.combinedFile,markdown_template:topic.markdownTemplate,combined_template:topic.combinedTemplate,revision:record.revision)
  if record.itemTemplates==true{settings.items=(topic.commentTemplate,topic.imageTemplate)}
  let body=try JSONEncoder().encode(settings)
  let data:Data
  do{data=try await send(endpoint,"/api/v1/folders/"+id.uuidString.lowercased(),"PUT",c.token,body)}
  catch let failure as CloudFailure where failure.status==409 && (failure.code=="folder_conflict" || failure.code==nil) {
   await refresh(c)
   throw CloudFailure(L("Změněno na jiném Macu. Načetl jsem novou verzi."),status:409,code:"folder_conflict")
  }
  catch let failure as CloudFailure{throw Self.friendly(failure)}
  let result=try JSONDecoder().decode(FolderEnvelope<RemoteFolder>.self,from:data).data
  guard currentConnection()?.token==c.token,result.id==id,let index=records.firstIndex(where:{matches($0,topic)}) else{throw CloudFailure.invalid}
  var updated=records,next=result.record(owner:owner,origin:c.endpoint,library:record.owner)
  // Vlastník složky se úpravou nemění.
  guard next.owner==record.owner else{throw CloudFailure.invalid}
  next.folder=updated[index].folder;next.migratedLocalIDs=updated[index].migratedLocalIDs;next.confirmLocalDeletes=updated[index].confirmLocalDeletes
  next.ownerKind=record.ownerKind;next.ownerName=next.ownerName ?? record.ownerName;next.role=next.role ?? record.role
  if let name=next.combinedFile,!validCombinedFile(name){next.combinedFile=nil}
  updated[index]=next;try persist(updated);NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
  return next.topic
 }
 static func friendly(_ failure:CloudFailure)->CloudFailure {
  switch failure.code {
  case "folder_name_taken":return CloudFailure(L("Cloudová složka s tímto názvem už existuje. Zvol jiný název."),status:failure.status,code:failure.code)
  case "folder_limit":return CloudFailure(L("Byl dosažen limit počtu cloudových složek."),status:failure.status,code:failure.code)
  case "not_found":return CloudFailure(L("Cloudová složka už na serveru neexistuje."),status:failure.status,code:failure.code)
  case "folder_trashed":return CloudFailure(L("Cloudová složka je v Koši na webu. Obnov ji na webu, pak ji půjde upravit."),status:failure.status,code:failure.code)
  case "role_forbidden":return forbidden
  default:return failure
  }
 }
 static var forbidden:CloudFailure{CloudFailure(L("Týmovou složku může přejmenovat, nastavit nebo smazat jen vlastník nebo správce týmu."),status:403,code:"role_forbidden")}
 @MainActor func refresh(_ connection:CloudConnection?) async {
  activate(connection)
  guard !syncing,readable,let c=connection,let owner=c.ownerID,let endpoint=CloudEndpoint(c.endpoint) else{return}
  syncing=true;defer{syncing=false;NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)}
  do {
   // Týmy z /me; tým, který zmizel, skryje své složky dřív, než se cokoli stáhne.
   var libraries=try await self.libraries(endpoint:endpoint,token:c.token,owner:owner)
   // Až 200 složek se šablonami a popisy; limit s rezervou.
   let data=try await request(endpoint,"/api/v1/folders",c.token,33554432)
   guard currentConnection()?.token==c.token else{throw CloudFailure.invalid}
   let remote=try JSONDecoder().decode(FolderEnvelope<[RemoteFolder]>.self,from:data).data
   // Zmizelá týmová složka může znamenat odchod z týmu těsně po /me; /me se ověří znovu.
   let teamIDs:Set<UUID>=Set((libraries ?? []).filter(\.isTeam).map(\.id))
   let listed:Set<[UUID]>=Set(remote.map{[$0.id,$0.owner_id ?? owner]})
   if records.contains(where:{record in mine(record) && record.isTeam && record.unavailable != true && record.remoteDeleted != true && teamIDs.contains(record.owner) && !listed.contains([record.id,record.owner])}) {
    libraries=try await self.libraries(endpoint:endpoint,token:c.token,owner:owner)
   }
   let allowed=Set([owner]+(libraries ?? []).filter(\.isTeam).map(\.id))
   // Složka týmu, ke kterému už přístup není (souběh s /me), se v tomto průchodu vynechá.
   try accept(remote.map{$0.record(owner:owner,origin:c.endpoint)}.filter{allowed.contains($0.owner)},libraries:libraries)
   lastError=nil
   // Chyba jedné složky nezastaví ostatní; ohlásí se první z nich.
   var failure:Error?
   for topic in topics where topic.savesLocally {
    do {
     try Topics.validateDestination(topic,folder:topic.destination,among:localTopics().filter{!self.migratedLocalIDs.contains($0.id)}+allTopics)
     let active=try await notes(topic,state:nil,endpoint:endpoint,token:c.token).filter{$0.trashed_at==nil}
     // Starší server koš nezná; bez seznamu koše se koš nesynchronizuje.
     let trashed=try? await notes(topic,state:"trashed",endpoint:endpoint,token:c.token).filter{$0.trashed_at != nil}
     try await reconcile(topic,active:active,trashed:trashed,endpoint:endpoint,token:c.token)
    } catch {
     failure=failure ?? error
     if let cloud=error as? CloudFailure,[401,429].contains(cloud.status){break}
    }
   }
   if let failure{throw failure}
   failures=0;retryAt = .distantPast
  } catch {
   lastError=(error as? CloudFailure)?.message ?? L("Cloudové složky se nepodařilo synchronizovat. Místní data zůstávají zachovaná.")
   // Potíže serveru nebo sítě prodlužují odstup (Retry-After má přednost); vadná jedna relace ne.
   let cloud=error as? CloudFailure
   if error is URLError || (cloud.map{$0.status==401 || $0.status==429 || $0.status>=500 || $0.retryAfter>0} ?? false) {
    failures+=1
    retryAt=now().addingTimeInterval(max(cloud?.retryAfter ?? 0,min(3600,60*pow(2,Double(min(failures,7)-1)))))
   } else{failures=0;retryAt = .distantPast}
   if cloud?.status==401{onUnauthorized?(c.token)}
  }
 }
 /// Týmy z /me, ve kterých smí uživatel zakládat složky (owner/admin).
 @MainActor func manageableTeams()async throws->[CloudLibraryRef] {
  guard let c=currentConnection(),let account=c.ownerID,let endpoint=CloudEndpoint(c.endpoint) else{return []}
  return (try await libraries(endpoint:endpoint,token:c.token,owner:account) ?? []).filter{$0.isTeam && LibraryRole.manages($0.role)}
 }
 /// Library z /me; chybějící pole (starší server) je nil = jen osobní.
 @MainActor private func libraries(endpoint:CloudEndpoint,token:String,owner:UUID)async throws->[CloudLibraryRef]? {
  let me=try JSONDecoder().decode(FolderEnvelope<CloudOwner>.self,from:await request(endpoint,"/api/v1/me",token,524288)).data
  guard currentConnection()?.token==token,me.id==owner else{throw CloudFailure.invalid}
  guard let list=me.libraries else{return nil}
  guard list.count<=100,Set(list.map(\.id)).count==list.count,list.allSatisfy({LibraryKind(rawValue:$0.kind) != nil && ($0.isTeam || $0.id==owner) && ($0.name?.unicodeScalars.count ?? 0)<=100}) else{throw CloudFailure.invalid}
  return list
 }
 /// Před mazáním podle 404 v týmové složce se ověří, že tým v /me pořád je; jinak se složka skryje.
 @MainActor private func stillMember(_ topic:Topic,endpoint:CloudEndpoint,token:String)async throws->Bool {
  guard topic.cloudTeam==true,let account,let team=topic.cloudOwnerID else{return true}
  let list=try await libraries(endpoint:endpoint,token:token,owner:account.0)
  if list?.contains(where:{$0.id==team && $0.isTeam})==true{return true}
  var updated=records,lost:[CloudFolderRecord]=[]
  for i in updated.indices where mine(updated[i]) && updated[i].owner==team{updated[i].unavailable=true;lost.append(updated[i])}
  try persist(updated)
  let index=SessionIndex.shared
  index.batch{for var record in index.all where lost.contains(where:{Self.inFolder(record,$0.topic)}) && record.keptLocal != true && (record.missingSince != nil || record.held != nil || record.askDelete != nil){record.missingSince=nil;record.held=nil;record.askDelete=nil;record.confirmed=nil;index.put(record)}}
  return false
 }
 /// Periodická synchronizace počká do tohoto času (Retry-After a backoff).
 private(set) var retryAt=Date.distantPast
 private var failures=0
 var onUnauthorized:((String)->Void)?
 @MainActor private func notes(_ topic:Topic,state:String?,endpoint:CloudEndpoint,token:String)async throws->[RemoteNoteList.Note] {
  var page=1;var notes:[RemoteNoteList.Note]=[]
  while page<=10000 {
   guard currentConnection()?.token==token else{throw CloudFailure.invalid}
   // Týmová složka se zúží i na library týmu.
   let library=topic.cloudTeam==true ? topic.cloudOwnerID.map{"&library_id="+$0.uuidString.lowercased()} ?? "":""
   let path="/api/v1/sessions?folder_id="+topic.cloudFolderID!.uuidString.lowercased()+library+(state.map{"&state="+$0} ?? "")+"&sort=oldest&page=\(page)"
   let list=try JSONDecoder().decode(RemoteNoteList.self,from:await request(endpoint,path,token,CloudTransport.jsonLimit))
   notes+=list.data.filter{$0.deleting != true}
   if !list.pagination.has_more{break};page+=1
  }
  return notes
 }
 private func notice(_ record:SessionRecord) {
  guard record.noticed != true else{return}
  var next=record;next.noticed=true;SessionIndex.shared.put(next)
  say(LF("Relace „%@“ je na webu v koši, ale místní kopie je upravená, proto zůstává na místě.",record.title))
 }
 @MainActor private func reconcile(_ topic:Topic,active input:[RemoteNoteList.Note],trashed listed:[RemoteNoteList.Note]?,endpoint:CloudEndpoint,token:String)async throws {
  guard isCurrent(topic,token:token),let folderID=topic.cloudFolderID else{throw CloudFailure.invalid}
  let base=try Topics.checkedDestination(topic.folder),index=SessionIndex.shared
  var active=input,trashed=listed
  // Nedostupný kořen (odpojený disk, práva) se nesynchronizuje, aby nevznikl prázdný adresář.
  let identity=itemIdentity(base),readableRoot=identity != nil && (try? fm.contentsOfDirectory(atPath:base.path)) != nil
  if !readableRoot && !index.cloudRecords(base:base,folder:folderID).isEmpty{return}
  if trashed != nil {
   // Relace vrácená uživatelem z .trash se obnoví i na serveru.
   for record in index.cloudRecords(base:base,folder:folderID) where record.trashed==true {
    guard let id=UUID(uuidString:record.id),let found=userRestored(record,base:base) else{continue}
    do{_ = try await send(endpoint,"/api/v1/sessions/"+record.id+"/restore","POST",token,Data("{}".utf8))}
    catch let failure as CloudFailure where failure.status==404{index.remove(record);continue}
    // Cizí relaci v týmu obnovit nelze; soubory zůstanou a znovu se to nezkouší.
    catch let failure as CloudFailure where failure.isRoleForbidden{index.remove(record);say(LF("Relaci „%@“ nelze obnovit v cloudu: v týmové složce ji smí obnovit jen autor nebo správce. Místní soubory zůstávají.",record.title));continue}
    catch{continue}
    guard isCurrent(topic,token:token) else{throw CloudFailure.invalid}
    adoptUserRestore(record,found:found,base:base)
    if let item=trashed?.first(where:{$0.id==id}){trashed=trashed?.filter{$0.id != id};if !active.contains(where:{$0.id==id}){active.append(item)}}
   }
   // Relace, která není v žádném seznamu a detail vrací 404, byla smazána natrvalo.
   let known=Set((active+(trashed ?? [])).map{$0.id.uuidString.lowercased()})
   var checks=0,member:Bool?
   for record in index.cloudRecords(base:base,folder:folderID) where !known.contains(record.id) {
    guard checks<20 else{break};checks+=1
    do{_ = try await request(endpoint,"/api/v1/sessions/"+record.id,token,CloudTransport.jsonLimit);continue}
    catch let failure as CloudFailure where failure.status==404 {
     if member==nil{member=try await stillMember(topic,endpoint:endpoint,token:token)}
     // Ztráta týmu není smazání: nic se nemaže ani nepřesouvá.
     guard member==true else{return}
     guard isCurrent(topic,token:token) else{throw CloudFailure.invalid};purge(record,base:base)
    }
    catch{continue}
   }
  }
  if readableRoot{flatten(topic,base:base);migrateImageLinks(in:base);migrateImageLinks(in:trashURL(base))}
  if trashed != nil,readableRoot,let identity {
   if let saved=index.root(base),saved != identity {
    // Vyměněný kořen: tento průchod nic nemaže a začíná znovu.
    index.batch{for var record in index.cloudRecords(base:base,folder:folderID) where record.missingSince != nil{record.missingSince=nil;index.put(record)};index.setRoot(base,identity)}
   } else {
    index.setRoot(base,identity)
    active=try await propagateLocalDeletions(topic,active:active,base:base,endpoint:endpoint,token:token)
   }
  }
  var failure:Error?
  if topic.combined{try await materializeCombined(active,trashed:trashed ?? [],topic:topic,base:base,endpoint:endpoint,token:token)}
  else {
   // Chyba jedné relace nezastaví stažení ostatních.
   for item in active {
    do{try await download(item,topic:topic,base:base,endpoint:endpoint,token:token)}
    catch{failure=failure ?? error;guard isCurrent(topic,token:token) else{throw error}}
   }
   flatten(topic,base:base)
   for item in trashed ?? []{trashSeparate(item.id,base:base)}
  }
  // Místní poznámky v cloudovém adresáři přijdou o staré značky až po přepsání cloudových souborů.
  migrateLegacyMarkers(in:base,skip:[topic.combinedFile,(topic.combinedFile as NSString).deletingPathExtension+"_cloud.md"])
  if let failure{throw failure}
 }
 private func say(_ message:String){messages.append(message);if messages.count>5{messages.removeFirst()}}
 /// Adresáře zmapovaného stromu včetně .trash; obrázky a skryté položky se přeskakují.
 private func treeDirectories(_ base:URL)->[URL] {
  guard let walker=fm.enumerator(at:base,includingPropertiesForKeys:[.isDirectoryKey],options:[]) else{return []}
  var result:[URL]=[]
  for case let url as URL in walker {
   let name=url.lastPathComponent
   if name.hasPrefix("."),!(walker.level==1 && name==".trash"){walker.skipDescendants();continue}
   guard (try? url.resourceValues(forKeys:[.isDirectoryKey]))?.isDirectory==true else{continue}
   if name=="assets" || walker.level>=5{walker.skipDescendants()}
   if name != "assets" && name != ".trash"{result.append(url)}
   if result.count>20000{break}
  }
  return result
 }
 private func sessionMarkdown(in directory:URL,_ record:SessionRecord)->URL? {
  let expected=URL(fileURLWithPath:record.file).lastPathComponent,hash=record.files[expected],direct=directory.appendingPathComponent(expected)
  if fm.fileExists(atPath:direct.path){return direct}
  let files=((try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md"}
  return files.first{readSessionTag($0)==record.id} ?? files.first{hash != nil && fileHash($0)==hash} ?? (files.count==1 ? files[0]:nil)
 }
 /// Přesunutý či přejmenovaný adresář relace podle xattr, identity souboru nebo otisku.
 private func findSession(_ record:SessionRecord,among directories:[URL])->URL? {
  let expected=URL(fileURLWithPath:record.file).lastPathComponent,hash=record.files[expected]
  return directories.first{readSessionTag($0)==record.id}
   ?? directories.first{record.inode != nil && itemIdentity($0)==record.inode}
   ?? directories.first{hash != nil && fm.fileExists(atPath:$0.appendingPathComponent(expected).path) && fileHash($0.appendingPathComponent(expected))==hash}
 }
 /// Místně smazané relace jdou do Koše na webu; přejmenování jen aktualizuje index.
 @MainActor private func propagateLocalDeletions(_ topic:Topic,active:[RemoteNoteList.Note],base:URL,endpoint:CloudEndpoint,token:String)async throws->[RemoteNoteList.Note] {
  let index=SessionIndex.shared,folderID=topic.cloudFolderID!,stamp=now().timeIntervalSince1970,trash=SessionIndex.key(trashURL(base))+"/"
  let activeIDs=Set(active.map{$0.id.uuidString.lowercased()})
  // Člen týmu posílá do Koše jen vlastní relace; cizí smazání zůstane jen na tomto Macu.
  let authors=Dictionary(active.map{($0.id.uuidString.lowercased(),$0.author?.id)},uniquingKeysWith:{a,_ in a})
  func mayTrash(_ record:SessionRecord)->Bool{topic.canManageCloudFolder || (account != nil && authors[record.id].flatMap{$0}==account?.0)}
  var kept=0
  func keepLocal(_ record:SessionRecord){var next=record;next.keptLocal=true;next.missingSince=next.missingSince ?? stamp;next.held=nil;next.askDelete=nil;next.confirmed=nil;index.put(next);kept+=1}
  defer{if kept>0{say(LF("Smazání ve složce %@ zůstává jen na tomto Macu: cizí relace v týmové složce smí do Koše přesunout jen autor nebo správce.",topic.displayName))}}
  let records=index.cloudRecords(base:base,folder:folderID).filter{$0.trashed != true && activeIDs.contains($0.id) && ($0.stem != nil)==topic.combined}
  guard !records.isEmpty else{return active}
  var text:NSString?,mainKey=""
  if topic.combined {
   let main=base.appendingPathComponent(validCombinedFile(topic.combinedFile) ? topic.combinedFile:defaultCombinedFile);mainKey=SessionIndex.key(main)
   // Smazaný celý společný soubor se jen znovu vygeneruje.
   guard let data=try? boundedData(main,max:20000000),let value=String(data:data,encoding:.utf8) else{return active}
   text=value as NSString
  }
  var cached:[URL]?
  func tree()->[URL]{if let cached{return cached};let value=treeDirectories(base);cached=value;return value}
  var gone:[(SessionRecord,URL?)]=[]
  for var record in records {
   var present=false,inTrash:URL?
   if let text {
    guard record.file==mainKey else{continue}
    let lines=Set((text as String).components(separatedBy:"\n"))
    present=locateSession(record,in:text,avoid:[]) != nil || record.images.contains{containsImageLink(text as String,$0)} || (!record.heading.isEmpty && lines.contains(record.heading))
   } else if isRoot(record,base) {
    // Plochá relace: hledá se jen její Markdown v celém stromu, nikdy celý adresář.
    let expected=URL(fileURLWithPath:record.file).lastPathComponent,hash=record.files[expected]
    let candidates=([base]+tree()).flatMap{((try? fm.contentsOfDirectory(at:$0,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md"}}
    let trashed=((try? fm.contentsOfDirectory(at:trashURL(base),includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md"}
    if fm.fileExists(atPath:record.file){present=true}
    else if let moved=candidates.first(where:{readSessionTag($0)==record.id}) ?? candidates.first(where:{hash != nil && fileHash($0)==hash}) {
     present=true;if let hash=record.files.removeValue(forKey:expected){record.files[moved.lastPathComponent]=hash};record.file=SessionIndex.key(moved);record.flat=true;writeSessionTag(moved,record.id)
    }
    // Markdown přesunutý uživatelem do .trash.
    else if let moved=trashed.first(where:{readSessionTag($0)==record.id}) ?? trashed.first(where:{hash != nil && fileHash($0)==hash}){inTrash=moved}
   } else if let directory=fm.fileExists(atPath:record.directory.path) ? record.directory:findSession(record,among:tree()) {
    if SessionIndex.key(directory).hasPrefix(trash){inTrash=directory}
    else {
     present=true
     // Přejmenování nebo přesun uvnitř složky jen přepíše cestu v indexu.
     if let markdown=sessionMarkdown(in:directory,record),SessionIndex.key(markdown) != record.file {
      let old=URL(fileURLWithPath:record.file).lastPathComponent
      if let hash=record.files.removeValue(forKey:old){record.files[markdown.lastPathComponent]=hash}
      record.file=SessionIndex.key(markdown);record.inode=itemIdentity(directory);writeSessionTag(directory,record.id)
     }
    }
   }
   if present{record.missingSince=nil;record.held=nil;record.confirmed=nil;record.askDelete=nil;record.keptLocal=nil;index.put(record);continue}
   // Smazání, které zůstalo jen místní, se znovu neposílá.
   if record.keptLocal==true{continue}
   // Neodeslané změny relace mají přednost; smazání počká, ale relace se znovu nestáhne.
   let busy=UUID(uuidString:record.id).map(pending) ?? true
   if let inTrash{if !busy{if mayTrash(record){gone.append((record,inTrash))}else{keepLocal(record)}};continue}
   guard let since=record.missingSince else{record.missingSince=stamp;index.put(record);continue}
   if stamp-since>=10 && !busy{if mayTrash(record){gone.append((record,nil))}else{keepLocal(record)}}
  }
  // Hromadné zmizení se posílá až po potvrzení.
  let deleted=gone.filter{$0.1==nil && $0.0.confirmed != true}
  if deleted.count>5 || (deleted.count>1 && deleted.count*2>records.count) {
   for (record,_) in deleted where record.held != true{var next=record;next.held=true;index.put(next)}
   let held=Set(deleted.map(\.0.id));gone.removeAll{held.contains($0.0.id)}
  }
  // Smazání z disku (ne přesun do .trash) se nejdřív potvrdí, pokud to složka nemá vypnuté.
  let ask=topic.confirmLocalDeletes != false
  if ask {
   for (record,location) in gone where location==nil && record.confirmed != true && record.askDelete != true{var next=record;next.askDelete=true;index.put(next)}
   gone.removeAll{$0.1==nil && $0.0.confirmed != true}
  }
  var removed=Set<String>()
  for (record,location) in gone {
   do{_ = try await send(endpoint,"/api/v1/sessions/"+record.id+"/trash","POST",token,Data("{}".utf8))}
   catch let failure as CloudFailure where failure.status==404{index.remove(record);removed.insert(record.id);continue}
   catch let failure as CloudFailure where failure.isRoleForbidden{keepLocal(record);continue}
   catch{continue}
   guard isCurrent(topic,token:token) else{throw CloudFailure.invalid}
   var next=record;next.missingSince=nil;next.held=nil;next.confirmed=nil
   if !topic.combined,isRoot(record,base),let location {
    // Relace z kořene: s Markdownem do .trash putují i její obrázky.
    let images=trashImages(record,base:base),name=URL(fileURLWithPath:record.file).lastPathComponent
    if let hash=next.files.removeValue(forKey:name){next.files[location.lastPathComponent]=hash}
    next.trashed=true;next.away=record.file;next.file=SessionIndex.key(location);next.rootMoved=images.moved;next.trashCopies=images.copied
   } else if !topic.combined {
    next.trashed=true;next.away=SessionIndex.key(record.directory)
    if let location{next.file=SessionIndex.key(sessionMarkdown(in:location,record) ?? location.appendingPathComponent(URL(fileURLWithPath:record.file).lastPathComponent));next.inode=itemIdentity(location)}
   }
   next.askDelete=nil;index.put(next);removed.insert(record.id)
   // Bez dotazu jde zpráva do systémové notifikace s akcí Obnovit; jinak do stavu v okně Cloudu.
   if !ask && location==nil && record.confirmed != true,let post=onTrashedQuietly{post(next,topic)}
   else{say(LF("Relace „%@“ přesunuta do Koše na webu (lze obnovit 30 dní).",record.title))}
  }
  return active.filter{!removed.contains($0.id.uuidString.lowercased())}
 }
 var onTrashedQuietly:((SessionRecord,Topic)->Void)?
 func notify(_ message:String){say(message)}
 /// Relace smazané z disku, které čekají na potvrzení, po složkách.
 var deletePrompts:[(Topic,[SessionRecord])] {
  let asking=SessionIndex.shared.all.filter{$0.askDelete==true && $0.held != true}
  return topics.compactMap{topic in let list=asking.filter{Self.inFolder($0,topic)};return list.isEmpty ? nil:(topic,list)}
 }
 /// Odpověď na dotaz: do Koše na webu, nebo znovu stáhnout; volitelně se příště neptat.
 func resolveDeletePrompt(_ topic:Topic,trash:Bool,suppress:Bool) {
  let index=SessionIndex.shared
  index.batch{for var record in index.all where Self.inFolder(record,topic) && record.askDelete==true{if trash{record.askDelete=nil;record.confirmed=true;index.put(record)}else{index.remove(record)}}}
  if suppress{try? setConfirmLocalDeletes(topic,false)}
 }
 func setConfirmLocalDeletes(_ topic:Topic,_ value:Bool)throws {
  guard let i=records.firstIndex(where:{matches($0,topic)}) else{throw CloudFailure.invalid}
  var updated=records;updated[i].confirmLocalDeletes=value ? nil:false;try persist(updated)
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
 }
 /// Obnovení z notifikace: POST /restore a nové stažení.
 @MainActor func restoreFromNotification(_ id:UUID) async {
  guard let c=currentConnection(),let endpoint=CloudEndpoint(c.endpoint) else{return}
  do{_ = try await send(endpoint,"/api/v1/sessions/"+id.uuidString.lowercased()+"/restore","POST",c.token,Data("{}".utf8))}catch{say((error as? CloudFailure)?.message ?? error.localizedDescription);return}
  await refresh(c)
 }
 /// Složky se zadrženým hromadným smazáním.
 var heldFolders:[(Topic,Int)] {
  let held=SessionIndex.shared.all.filter{$0.held==true}
  return topics.compactMap{topic in let count=held.filter{Self.inFolder($0,topic)}.count;return count>0 ? (topic,count):nil}
 }
 /// Potvrdí přesun do Koše, nebo relace znovu stáhne.
 func resolveHeld(_ topic:Topic,trash:Bool) {
  let index=SessionIndex.shared
  index.batch{for var record in index.all where Self.inFolder(record,topic) && record.held==true{if trash{record.held=nil;record.confirmed=true;index.put(record)}else{index.remove(record)}}}
 }
 private func trashURL(_ base:URL)->URL{base.appendingPathComponent(".trash",isDirectory:true)}
 /// Najde relaci, kterou uživatel vrátil z .trash zpět do složky.
 private func isRoot(_ record:SessionRecord,_ base:URL)->Bool{record.stem==nil && (record.flat==true || SessionIndex.key(record.directory)==SessionIndex.key(base))}
 /// Soubor záznamu: u ploché relace Markdown podle cesty, obrázky ze společného assets/.
 private func fileURL(_ record:SessionRecord,_ key:String,base:URL)->URL{isRoot(record,base) ? (key==URL(fileURLWithPath:record.file).lastPathComponent ? URL(fileURLWithPath:record.file):base.appendingPathComponent(key)):record.directory.appendingPathComponent(key)}
 private func flatStem(_ name:String,base:URL)->String{uniqueName(name){fm.fileExists(atPath:base.appendingPathComponent($0+".md").path) || fm.fileExists(atPath:base.appendingPathComponent("assets/"+$0+"-1.png").path) || fm.fileExists(atPath:self.trashURL(base).appendingPathComponent($0+".md").path)}}
 /// Starší podsložky relací se zploští do kořene, pokud je nikdo neupravil; upravené zůstávají.
 private func flatten(_ topic:Topic,base:URL) {
  guard !topic.combined,let folder=topic.cloudFolderID else{return}
  let index=SessionIndex.shared,assets=base.appendingPathComponent("assets")
  for var record in index.cloudRecords(base:base,folder:folder) where record.trashed != true && !isRoot(record,base) && SessionIndex.key(record.directory.deletingLastPathComponent())==SessionIndex.key(base) {
   let directory=record.directory,source=URL(fileURLWithPath:record.file)
   guard fm.fileExists(atPath:directory.path),directoryUnmodified(directory,record.files),let text=(try? boundedData(source,max:20000000)).flatMap({String(data:$0,encoding:.utf8)}) else{continue}
   let guid=directory.lastPathComponent.range(of:"^[0-9a-f]{8}-[0-9a-f]{4}-",options:.regularExpression) != nil
   let stem=flatStem(guid ? readableSessionName(record.title,created:parseServerDate(record.created) ?? Date()):directory.lastPathComponent,base:base)
   var output=text,names:[String:String]=[:]
   for (i,image) in record.images.enumerated() {
    let name=uniqueName(stem+"-\(i+1)"){assetStemTaken(assets,$0) || names.values.contains($0+".png")}+".png"
    names[image]=name
   }
   output=rewriteImageLinks(output,order:record.images,rename:names)
   let target=base.appendingPathComponent(stem+".md")
   try? fm.createDirectory(at:assets,withIntermediateDirectories:true)
   guard (try? Data(output.utf8).write(to:target,options:.withoutOverwriting)) != nil else{continue}
   for (old,name) in names{try? fm.moveItem(at:directory.appendingPathComponent("assets/"+old),to:assets.appendingPathComponent(name))}
   try? fm.removeItem(at:source)
   // Prázdná podsložka (jen skryté soubory) se odstraní.
   if ((fm.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles])?.allObjects as? [URL]) ?? []).allSatisfy({(try? $0.resourceValues(forKeys:[.isRegularFileKey]))?.isRegularFile != true}){try? fm.removeItem(at:directory)}
   var files=[target.lastPathComponent:sessionFingerprint(Data(output.utf8))];for name in names.values{files["assets/"+name]=fileHash(assets.appendingPathComponent(name))}
   var notes:[String:String]=[:];for (old,name) in names{notes[name]=record.notes[old]}
   record.file=SessionIndex.key(target);record.images=record.images.map{names[$0] ?? $0};record.notes=notes;record.imageComments=record.imageComments.map{Dictionary($0.map{(names[$0.key] ?? $0.key,$0.value)},uniquingKeysWith:{a,_ in a})};record.files=files;record.flat=true;record.inode=nil
   record.length=(output as NSString).length;record.hash=sessionFingerprint(Data(output.utf8));record.heading=firstLine(output)
   index.put(record);writeSessionTag(target,record.id)
  }
 }
 /// Obrázky relace z kořene, které nepoužívá žádná jiná poznámka ve složce.
 private func ownImages(_ record:SessionRecord,base:URL)->[String] {
  let others=SessionIndex.shared.all.filter{$0.id != record.id && $0.trashed != true && (SessionIndex.key($0.directory)==SessionIndex.key(base) || ($0.base != nil && $0.base==SessionIndex.key(base)))}.flatMap(\.images)
  let texts=((try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md" && SessionIndex.key($0) != record.file}.compactMap{(try? boundedData($0,max:20000000)).flatMap{String(data:$0,encoding:.utf8)}}
  return record.images.filter{name in !others.contains(name) && !texts.contains{containsImageLink($0,name)}}
 }
 /// Obrázky relace jdou do .trash/assets: vlastní se přesunou, sdílené s živou relací zkopírují.
 private func trashImages(_ record:SessionRecord,base:URL)->(moved:[String],copied:[String]) {
  let assets=base.appendingPathComponent("assets"),trash=trashURL(base).appendingPathComponent("assets"),own=Set(ownImages(record,base:base))
  var moved:[String]=[],copied:[String]=[]
  for image in record.images where fm.fileExists(atPath:assets.appendingPathComponent(image).path) && !fm.fileExists(atPath:trash.appendingPathComponent(image).path) {
   let target=trash.appendingPathComponent(image);try? fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
   if own.contains(image){if (try? fm.moveItem(at:assets.appendingPathComponent(image),to:target)) != nil{moved.append(image)
    // Video jde s posterem, aby se po obnovení dalo přejmenovat spolu s ním.
    for (source,side) in zip(assetVideoFiles(assets,image),assetVideoFiles(trash,image)) where fm.fileExists(atPath:source.path) && !fm.fileExists(atPath:side.path){try? fm.moveItem(at:source,to:side)}}}
   else if (try? fm.copyItem(at:assets.appendingPathComponent(image),to:target)) != nil{copied.append(image)}
  }
  return (moved,copied)
 }
 /// Kopie sdílených obrázků z .trash zmizí, jen pokud jsou netknuté.
 private func removeTrashCopies(_ record:SessionRecord,base:URL) {
  for image in record.trashCopies ?? []{let url=trashURL(base).appendingPathComponent("assets/"+image);if fileHash(url)==record.files["assets/"+image]{try? fm.removeItem(at:url)}}
 }
 /// Web přesunul do koše relaci z kořene: do .trash jde jen její Markdown a vlastní obrázky.
 private func trashRoot(_ record:SessionRecord,base:URL) {
  var next=record;let markdown=URL(fileURLWithPath:record.file),name=markdown.lastPathComponent,assets=base.appendingPathComponent("assets")
  guard fm.fileExists(atPath:markdown.path) else{next.trashed=true;next.away=record.file;next.rootMoved=[];SessionIndex.shared.put(next);return}
  guard fileHash(markdown)==record.files[name],record.images.allSatisfy({fileHash(assets.appendingPathComponent($0))==record.files["assets/"+$0]}) else{notice(record);return}
  let trash=trashURL(base),target=trash.appendingPathComponent(uniqueName((name as NSString).deletingPathExtension){fm.fileExists(atPath:trash.appendingPathComponent($0+".md").path)}+".md")
  try? fm.createDirectory(at:trash.appendingPathComponent("assets"),withIntermediateDirectories:true)
  guard (try? fm.moveItem(at:markdown,to:target)) != nil else{return}
  let images=trashImages(record,base:base)
  if let hash=next.files.removeValue(forKey:name){next.files[target.lastPathComponent]=hash}
  next.trashed=true;next.away=record.file;next.file=SessionIndex.key(target);next.rootMoved=images.moved;next.trashCopies=images.copied;SessionIndex.shared.put(next)
 }
 /// Vrátí Markdown a přesunuté obrázky na původní místa; obsazené názvy dostanou příponu.
 private func restoreRoot(_ record:SessionRecord,base:URL,markdown found:URL?=nil)->SessionRecord {
  var next=record;let assets=base.appendingPathComponent("assets"),trash=trashURL(base)
  next.trashed=false;next.noticed=nil
  let original=URL(fileURLWithPath:record.away ?? record.file),current=found ?? URL(fileURLWithPath:record.file)
  if found != nil{next.file=SessionIndex.key(current)}
  else if fm.fileExists(atPath:current.path) {
   let stem=(original.lastPathComponent as NSString).deletingPathExtension
   let parent=fm.fileExists(atPath:original.deletingLastPathComponent().path) ? original.deletingLastPathComponent():base
   let target=parent.appendingPathComponent(uniqueName(stem){fm.fileExists(atPath:parent.appendingPathComponent($0+".md").path)}+".md")
   if (try? fm.moveItem(at:current,to:target)) != nil{next.file=SessionIndex.key(target)}
  }
  if let hash=next.files.removeValue(forKey:current.lastPathComponent){next.files[URL(fileURLWithPath:next.file).lastPathComponent]=hash}
  var renamed:[String:String]=[:]
  for image in record.rootMoved ?? [] where fm.fileExists(atPath:trash.appendingPathComponent("assets/"+image).path) {
   let stem=(image as NSString).deletingPathExtension,ext=(image as NSString).pathExtension
   let name=uniqueName(stem){candidate in [ext,"mp4","frames"].contains{fm.fileExists(atPath:assets.appendingPathComponent(candidate+"."+$0).path)}}+"."+ext
   try? fm.createDirectory(at:assets,withIntermediateDirectories:true)
   if (try? fm.moveItem(at:trash.appendingPathComponent("assets/"+image),to:assets.appendingPathComponent(name))) != nil {
    for (source,side) in zip(assetVideoFiles(trash.appendingPathComponent("assets"),image),assetVideoFiles(assets,name)) where fm.fileExists(atPath:source.path) && !fm.fileExists(atPath:side.path){try? fm.moveItem(at:source,to:side)}
    if name != image{renamed[image]=name}
   }
  }
  if !renamed.isEmpty {
   // Obsazený název: záznam i odkazy v Markdownu ukazují na přejmenovaný obrázek.
   next.images=next.images.map{renamed[$0] ?? $0}
   next.notes=Dictionary(next.notes.map{(renamed[$0.key] ?? $0.key,$0.value)},uniquingKeysWith:{a,_ in a})
   next.imageComments=next.imageComments.map{Dictionary($0.map{(renamed[$0.key] ?? $0.key,$0.value)},uniquingKeysWith:{a,_ in a})}
   for (old,new) in renamed{
    if let hash=next.files.removeValue(forKey:"assets/"+old){next.files["assets/"+new]=hash}
    let video={(name:String)->String in "assets/"+(name as NSString).deletingPathExtension+".mp4"}
    if let hash=next.files.removeValue(forKey:video(old)){next.files[video(new)]=hash}
   }
   let markdown=URL(fileURLWithPath:next.file),key=markdown.lastPathComponent
   if let text=(try? boundedData(markdown,max:20000000)).flatMap({String(data:$0,encoding:.utf8)}) {
    let pristine=fileHash(markdown)==next.files[key],output=rewriteImageLinks(text,order:record.images,rename:renamed)
    if output != text,(try? Data(output.utf8).write(to:markdown,options:.atomic)) != nil {
     writeSessionTag(markdown,record.id)
     if pristine{next.files[key]=sessionFingerprint(Data(output.utf8));next.length=(output as NSString).length;next.hash=sessionFingerprint(Data(output.utf8));next.heading=firstLine(output)}
    }
   }
  }
  removeTrashCopies(record,base:base)
  next.away=nil;next.rootMoved=nil;next.trashCopies=nil;SessionIndex.shared.put(next);return next
 }
 private func userRestored(_ record:SessionRecord,base:URL)->URL? {
  if record.rootMoved != nil {
   // Markdown vrácený uživatelem z .trash do kořene.
   guard !fm.fileExists(atPath:record.file) else{return nil}
   let name=URL(fileURLWithPath:record.file).lastPathComponent,hash=record.files[name]
   let files=((try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).filter{$0.pathExtension.lowercased()=="md"}
   return files.first{readSessionTag($0)==record.id} ?? files.first{hash != nil && fileHash($0)==hash}
  }
  if record.stem != nil {
   guard let note=record.trashNote,!fm.fileExists(atPath:note) else{return nil}
   let direct=base.appendingPathComponent(URL(fileURLWithPath:note).lastPathComponent)
   if fm.fileExists(atPath:direct.path),sessionTagIDs(direct)==[record.id] || fileHash(direct)==record.trashHash{return direct}
   let files=(try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []
   return files.first{$0.pathExtension.lowercased()=="md" && sessionTagIDs($0)==[record.id]}
  }
  let directory=record.directory,markdown=URL(fileURLWithPath:record.file).lastPathComponent
  guard !fm.fileExists(atPath:directory.path) else{return nil}
  let children=(try? fm.contentsOfDirectory(at:base,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []
  let candidates=[base.appendingPathComponent(directory.lastPathComponent,isDirectory:true)]+children.filter{readSessionTag($0)==record.id}
  return candidates.first{fm.fileExists(atPath:$0.appendingPathComponent(markdown).path) && (readSessionTag($0)==record.id || fileHash($0.appendingPathComponent(markdown))==record.files[markdown])}
 }
 private func adoptUserRestore(_ record:SessionRecord,found:URL,base:URL) {
  if record.rootMoved != nil{_ = restoreRoot(record,base:base,markdown:found);return}
  var next=record;next.trashed=false;next.noticed=nil;next.away=nil
  if record.stem != nil {
   removeTrashCopies(record,base:base);moveImagesBack(record,base:base)
   if fileHash(found)==record.trashHash{try? fm.removeItem(at:found)}
   next.trashNote=nil;next.trashHash=nil;next.trashCopies=nil
  } else {next.file=SessionIndex.key(found.appendingPathComponent(URL(fileURLWithPath:record.file).lastPathComponent))}
  SessionIndex.shared.put(next)
 }
 private func moveImagesBack(_ record:SessionRecord,base:URL) {
  for name in record.images {
   let from=trashURL(base).appendingPathComponent("assets/"+name),to=base.appendingPathComponent("assets/"+name)
   guard fm.fileExists(atPath:from.path),!fm.fileExists(atPath:to.path) else{continue}
   try? fm.createDirectory(at:to.deletingLastPathComponent(),withIntermediateDirectories:true);try? fm.moveItem(at:from,to:to)
   for (source,side) in zip(assetVideoFiles(trashURL(base).appendingPathComponent("assets"),name),assetVideoFiles(base.appendingPathComponent("assets"),name)) where fm.fileExists(atPath:source.path) && !fm.fileExists(atPath:side.path){try? fm.moveItem(at:source,to:side)}
  }
 }
 /// Video posteru v .trash: MP4 jen netknuté (hash z indexu), složka snímků s ním.
 private func removeTrashedVideo(_ record:SessionRecord,image:String,base:URL) {
  let files=assetVideoFiles(trashURL(base).appendingPathComponent("assets"),image)
  guard let hash=record.files["assets/"+(image as NSString).deletingPathExtension+".mp4"],fileHash(files[0])==hash else{return}
  for url in files{try? fm.removeItem(at:url)}
 }
 /// Natrvalo smazaná relace zmizí z .trash, jen pokud ji nikdo neupravil.
 private func purge(_ record:SessionRecord,base:URL) {
  let index=SessionIndex.shared
  if let moved=record.rootMoved {
   // Smaže se jen to, co se do .trash přesunulo s relací, a jen netknuté.
   let markdown=URL(fileURLWithPath:record.file)
   if SessionIndex.key(markdown).hasPrefix(SessionIndex.key(trashURL(base))+"/"),fileHash(markdown)==record.files[markdown.lastPathComponent]{try? fm.removeItem(at:markdown)}
   for image in moved{let url=trashURL(base).appendingPathComponent("assets/"+image);if fileHash(url)==record.files["assets/"+image]{try? fm.removeItem(at:url)};removeTrashedVideo(record,image:image,base:base)}
   removeTrashCopies(record,base:base);index.remove(record);return
  }
  if record.stem != nil {
   if record.trashed==true {
    if let note=record.trashNote,fileHash(URL(fileURLWithPath:note))==record.trashHash{try? fm.removeItem(atPath:note)}
    for name in record.images{let url=trashURL(base).appendingPathComponent("assets/"+name);if fileHash(url)==record.files["assets/"+name]{try? fm.removeItem(at:url)};removeTrashedVideo(record,image:name,base:base)}
   } else {var copy=record;_ = trashCombined(&copy,base:base)}
  } else {
   let directory=record.directory
   // Mazat se smí jen adresář uvnitř .trash, nikdy kořen složky.
   if record.trashed==true{if SessionIndex.key(directory).hasPrefix(SessionIndex.key(trashURL(base))+"/"),directoryUnmodified(directory,record.files){try? fm.removeItem(at:directory)}}
   else if isRoot(record,base){trashRoot(record,base:base)}
   else if SessionIndex.key(directory.deletingLastPathComponent())==SessionIndex.key(base),directoryUnmodified(directory,record.files) {
    let trash=trashURL(base);try? fm.createDirectory(at:trash,withIntermediateDirectories:true)
    try? fm.moveItem(at:directory,to:trash.appendingPathComponent(uniqueName(directory.lastPathComponent){fm.fileExists(atPath:trash.appendingPathComponent($0).path)}))
   }
  }
  index.remove(record)
 }
 private func restoreSeparate(_ record:SessionRecord,base:URL)->SessionRecord {
  if record.rootMoved != nil{return restoreRoot(record,base:base)}
  var next=record;next.trashed=false;next.noticed=nil
  let directory=record.directory,markdown=URL(fileURLWithPath:record.file).lastPathComponent
  if fm.fileExists(atPath:directory.path),SessionIndex.key(directory).hasPrefix(SessionIndex.key(trashURL(base))+"/") {
   let original=record.away.map{URL(fileURLWithPath:$0).lastPathComponent} ?? directory.lastPathComponent
   let target=base.appendingPathComponent(uniqueName(original){fm.fileExists(atPath:base.appendingPathComponent($0).path)},isDirectory:true)
   if (try? fm.moveItem(at:directory,to:target)) != nil{next.file=SessionIndex.key(target.appendingPathComponent(markdown))}
  }
  next.away=nil;SessionIndex.shared.put(next);return next
 }
 private func trashSeparate(_ id:UUID,base:URL) {
  let index=SessionIndex.shared
  guard var record=index.cloud(id,base:base),record.trashed != true,record.stem==nil else{return}
  if isRoot(record,base){trashRoot(record,base:base);return}
  let directory=record.directory,markdown=URL(fileURLWithPath:record.file).lastPathComponent
  guard SessionIndex.key(directory.deletingLastPathComponent())==SessionIndex.key(base) else{return}
  if !fm.fileExists(atPath:directory.path){record.trashed=true;record.away=SessionIndex.key(directory);index.put(record);return}
  guard directoryUnmodified(directory,record.files) else{notice(record);return}
  let trash=trashURL(base);try? fm.createDirectory(at:trash,withIntermediateDirectories:true)
  let target=trash.appendingPathComponent(uniqueName(directory.lastPathComponent){fm.fileExists(atPath:trash.appendingPathComponent($0).path)},isDirectory:true)
  guard (try? fm.moveItem(at:directory,to:target)) != nil else{return}
  record.away=SessionIndex.key(directory);record.trashed=true;record.file=SessionIndex.key(target.appendingPathComponent(markdown));index.put(record)
 }
 /// Blok společného souboru se v koši uloží jako samostatná poznámka s obrázky.
 private func trashCombined(_ record:inout SessionRecord,base:URL)->Bool {
  guard let note=record.note,let stem=record.stem else{return false}
  let assets=base.appendingPathComponent("assets"),trash=trashURL(base)
  for name in record.images {
   let url=assets.appendingPathComponent(name)
   if fm.fileExists(atPath:url.path),fileHash(url) != record.files["assets/"+name] || fm.fileExists(atPath:trash.appendingPathComponent("assets/"+name).path){return false}
  }
  record.trashCopies=trashImages(record,base:base).copied
  let body=cloudSessionBody(note,images:record.images)
  let file=trash.appendingPathComponent(uniqueName(stem){fm.fileExists(atPath:trash.appendingPathComponent($0+".md").path)}+".md")
  guard (try? Data(body.utf8).write(to:file,options:.withoutOverwriting)) != nil else{return false}
  writeSessionTag(file,record.id)
  record.trashNote=SessionIndex.key(file);record.trashHash=sessionFingerprint(Data(body.utf8));record.trashed=true;SessionIndex.shared.put(record)
  return true
 }
 private func restoreCombined(_ record:SessionRecord,base:URL)->SessionRecord {
  removeTrashCopies(record,base:base);moveImagesBack(record,base:base)
  if let note=record.trashNote,fileHash(URL(fileURLWithPath:note))==record.trashHash{try? fm.removeItem(atPath:note)}
  var next=record;next.trashed=false;next.trashNote=nil;next.trashHash=nil;next.noticed=nil;next.trashCopies=nil;SessionIndex.shared.put(next);return next
 }
 private func cloudRecord(_ id:UUID,topic:Topic,base:URL,body:String,images names:[String],note:RemoteNote)->SessionRecord {
  SessionRecord(id:id.uuidString.lowercased(),file:"",start:0,length:(body as NSString).length,hash:sessionFingerprint(Data(body.utf8)),heading:firstLine(body),title:note.title,comment:note.comment,template:note.template,images:names,notes:Dictionary(zip(names,note.captions),uniquingKeysWith:{a,_ in a}),combined:false,footer:"",files:[:],seen:0,base:SessionIndex.key(base),folder:topic.cloudFolderID?.uuidString.lowercased(),owner:topic.cloudOwnerID?.uuidString.lowercased(),origin:topic.cloudOrigin,author:note.author?.name,authorID:note.author?.id?.uuidString.lowercased())
 }
 /// Starší stažení `<uuid>/Note.md` se přejmenuje, pokud ho nikdo neupravil; upravené zůstává na místě.
 private func migrateSeparate(_ id:UUID,note:RemoteNote,created:String?,topic:Topic,base:URL,endpoint:CloudEndpoint,owner:UUID)->SessionRecord? {
  let lower=id.uuidString.lowercased(),receipt=readReceipt(receiptFile(endpoint,owner:owner,base:base,id:id))
  let name=receipt?.name ?? lower
  guard name==lower || (name.hasPrefix(lower+"-") && name.count==lower.count+13) else{return nil}
  let directory=base.appendingPathComponent(name,isDirectory:true),markdown=directory.appendingPathComponent("Note.md")
  guard let data=try? boundedData(markdown,max:20000000),let text=String(data:data,encoding:.utf8),let (body,metadata)=legacyCloudBody(text) else{return nil}
  var record=cloudRecord(id,topic:topic,base:base,body:body,images:metadata.images,note:note)
  record.title=metadata.title;record.comment=metadata.comment;record.template=metadata.template;record.notes=metadata.imageNotes
  record.file=SessionIndex.key(markdown);record.files=receipt?.files ?? [:];record.updated=receipt?.updated;record.created=created;record.digest=receipt?.fingerprint;record.shas=receipt?.shas
  if let files=receipt?.files,sessionFingerprint(Data(body.utf8))==metadata.bodyHash,directoryUnmodified(directory,files) {
   let readable=uniqueName(readableSessionName(note.title,created:parseServerDate(created) ?? Date())){fm.fileExists(atPath:base.appendingPathComponent($0).path)}
   let target=base.appendingPathComponent(readable,isDirectory:true),renamed=target.appendingPathComponent(readable+".md")
   if (try? fm.moveItem(at:directory,to:target)) != nil {
    if (try? Data(body.utf8).write(to:renamed,options:.withoutOverwriting)) != nil {
     try? fm.removeItem(at:target.appendingPathComponent("Note.md"))
     var updated=files;updated.removeValue(forKey:"Note.md");updated[readable+".md"]=sessionFingerprint(Data(body.utf8))
     record.file=SessionIndex.key(renamed);record.files=updated;record.inode=itemIdentity(target)
     writeSessionTag(target,lower);writeSessionTag(renamed,lower)
    } else {record.file=SessionIndex.key(target.appendingPathComponent("Note.md"));record.files=[:]}
   }
  }
  SessionIndex.shared.put(record);return record
 }
 @MainActor private func download(_ item:RemoteNoteList.Note,topic:Topic,base:URL,endpoint:CloudEndpoint,token:String) async throws {
  let id=item.id,lower=id.uuidString.lowercased(),index=SessionIndex.shared
  guard isCurrent(topic,token:token),let owner=topic.cloudOwnerID else{throw CloudFailure.invalid}
  var record=index.cloud(id,base:base)
  if let saved=record,saved.stem != nil{record=nil}
  // Místně smazaná relace čeká na potvrzení a znovu se nestahuje.
  if let saved=record,saved.missingSince != nil || saved.held==true{return}
  // Na webu obnovená relace se vrací z koše.
  if let saved=record,saved.trashed==true{record=restoreSeparate(saved,base:base)}
  func present(_ r:SessionRecord)->Bool{!r.files.isEmpty && r.files.keys.allSatisfy{fm.fileExists(atPath:self.fileURL(r,$0,base:base).path)}}
  // Beze změny na serveru se nic nestahuje.
  // Změněná revize (úprava, komentář, šablona) znamená nové vykreslení i beze změny updated_at.
  if let saved=record,let updated=item.updated_at,saved.updated==updated,item.revision==nil || item.revision?.value==saved.revision,saved.render==cloudRenderVersion,present(saved){return}
  let (note,stamp,digest)=try await fetchNote(id,endpoint:endpoint,token:token)
  let created=stamp?.created_at ?? item.created_at
  if record==nil{record=migrateSeparate(id,note:note,created:created,topic:topic,base:base,endpoint:endpoint,owner:owner)}
  if var saved=record,saved.digest==digest,saved.render==cloudRenderVersion,present(saved) {
   saved.updated=stamp?.updated_at ?? item.updated_at;saved.created=saved.created ?? created;saved.revision=stamp?.revision?.value ?? saved.revision
   if saved != record{index.put(saved)};return
  }
  let data=try await images(note,topic:topic,endpoint:endpoint,token:token),shas=data.map(sessionFingerprint)
  let contexts=try await contextAttachments(note,topic:topic,endpoint:endpoint,token:token)
  func sidecar(_ key:String)->Bool{key.hasSuffix(".context.json") || key.hasSuffix(".har") || key.hasSuffix(".mp4")}
  guard try Topics.checkedDestination(topic.folder)==base,isCurrent(topic,token:token) else{throw CloudFailure.invalid}
  try Topics.validateDestination(topic,folder:base,among:localTopics().filter{!self.migratedLocalIDs.contains($0.id)}+allTopics)
  let assets=base.appendingPathComponent("assets");try fm.createDirectory(at:assets,withIntermediateDirectories:true)
  func finished(_ file:URL,_ body:String,_ names:[String],_ files:[String:String])->SessionRecord {
   var next=cloudRecord(id,topic:topic,base:base,body:body,images:names,note:note)
   next.updated=stamp?.updated_at ?? item.updated_at;next.created=record?.created ?? created;next.digest=digest;next.shas=shas;next.revision=stamp?.revision?.value
   next.file=SessionIndex.key(file);next.files=files;next.flat=true;next.render=cloudRenderVersion;next.imageTemplate=note.image_template;next.imageComments=cloudImageComments(note,images:names);return next
  }
  func exists(_ r:SessionRecord)->Bool{isRoot(r,base) ? fm.fileExists(atPath:r.file):fm.fileExists(atPath:r.directory.path)}
  if let saved=record,!isRoot(saved,base),fm.fileExists(atPath:saved.directory.path),directoryUnmodified(saved.directory,saved.files) {
   // Starší netknutá podsložka se aktualizuje na místě; při další synchronizaci se zploští.
   let directory=saved.directory,markdown=URL(fileURLWithPath:saved.file).lastPathComponent,names=note.images.map{"\($0.index).png"},body=cloudSessionBody(note,images:names,contexts:contexts)
   var files:[String:Data]=[markdown:Data(body.utf8)];for (name,bytes) in zip(names,data){files["assets/"+name]=bytes}
   try fm.createDirectory(at:directory.appendingPathComponent("assets"),withIntermediateDirectories:true)
   for (name,bytes) in files{try bytes.write(to:directory.appendingPathComponent(name),options:.atomic)}
   let sides=try writeContextAttachments(contexts,names:names,assets:directory.appendingPathComponent("assets"),previous:saved.files)
   for name in saved.files.keys where files[name]==nil && sides[name]==nil{try? fm.removeItem(at:directory.appendingPathComponent(name))}
   var next=finished(URL(fileURLWithPath:saved.file),body,names,files.mapValues(sessionFingerprint).merging(sides){a,_ in a});next.flat=nil;next.inode=itemIdentity(directory)
   index.put(next);writeSessionTag(directory,lower);writeSessionTag(directory.appendingPathComponent(markdown),lower);return
  }
  if let saved=record,exists(saved) {
   let flat=isRoot(saved,base),markdown=URL(fileURLWithPath:saved.file),stem=markdown.deletingPathExtension().lastPathComponent
   let folderAssets=flat ? assets:saved.directory.appendingPathComponent("assets")
   var names:[String]=[]
   for i in data.indices{names.append(i<saved.images.count ? saved.images[i]:(flat ? uniqueName(stem+"-\(i+1)"){assetStemTaken(folderAssets,$0) || names.contains($0+".png")}+".png":"\(i+1).png"))}
   let unmodified = !saved.files.isEmpty && saved.files.allSatisfy{fileHash(fileURL(saved,$0.key,base:base))==$0.value}
   if unmodified,saved.shas==shas,!flat || fileHash(markdown)==sessionFingerprint(Data(cloudSessionBody(note,images:names,contexts:contexts).utf8)),saved.title==note.title,saved.comment==note.comment,saved.template==note.template,saved.images.map({saved.notes[$0] ?? ""})==note.captions,!note.template.contains("{author}") || saved.author==note.author?.name {
    // Netknutá kopie se shoduje s cloudem; jen se zapíše otisk serveru.
    var same=saved;same.files=saved.files.filter{!sidecar($0.key)}.merging(try writeContextAttachments(contexts,names:names,assets:folderAssets,previous:saved.files)){a,_ in a};same.digest=digest;same.author=note.author?.name;same.authorID=note.author?.id?.uuidString.lowercased();same.revision=stamp?.revision?.value;same.updated=stamp?.updated_at ?? item.updated_at;same.created=saved.created ?? created;same.render=cloudRenderVersion;same.imageTemplate=note.image_template;same.imageComments=cloudImageComments(note,images:names);index.put(same);return
   }
   if flat && unmodified {
    // Netknutá plochá relace se aktualizuje na místě; nové snímky dostanou další -N ve společném assets/.
    let body=cloudSessionBody(note,images:names,contexts:contexts);var files=[markdown.lastPathComponent:sessionFingerprint(Data(body.utf8))]
    for (name,bytes) in zip(names,data){let url=assets.appendingPathComponent(name);if fileHash(url) != sessionFingerprint(bytes){try bytes.write(to:url,options:.atomic)};files["assets/"+name]=sessionFingerprint(bytes)}
    try Data(body.utf8).write(to:markdown,options:.atomic)
    files.merge(try writeContextAttachments(contexts,names:names,assets:assets,previous:saved.files)){a,_ in a}
    index.put(finished(markdown,body,names,files));writeSessionTag(markdown,lower);return
   }
   // Upravená místní kopie zůstává; cloudová verze jde vedle jako <název>_cloud.md.
   var links:[String]=[],fresh:[Int:[String:Data]]=[:]
   for (position,(name,bytes)) in zip(names,data).enumerated() {
    let url=folderAssets.appendingPathComponent(name),hash=fileHash(url)
    if hash==nil{try fm.createDirectory(at:folderAssets,withIntermediateDirectories:true);try bytes.write(to:url,options:.withoutOverwriting);links.append(name);fresh[position+1]=contexts[position+1]}
    else if hash==sessionFingerprint(bytes){links.append(name)}
    else{links.append(try writeGeneratedCopy(bytes,to:folderAssets.appendingPathComponent((name as NSString).deletingPathExtension+"_cloud.png")).lastPathComponent);fresh[position+1]=contexts[position+1]}
   }
   // Video a kontext jen k nově zapsaným obrázkům; místní soubory upravené relace se nemění ani nemažou.
   let videoFree={(position:Int)->Bool in !assetVideoFiles(folderAssets,links[position-1]).contains{fm.fileExists(atPath:$0.path)} && !assetContextFiles(folderAssets,links[position-1]).contains{fm.fileExists(atPath:$0.path)}}
   fresh=fresh.filter{videoFree($0.key)}
   let sides=try writeContextAttachments(fresh,names:links,assets:folderAssets)
   let copy=markdown.deletingLastPathComponent().appendingPathComponent(stem+"_cloud.md"),text=Data(cloudSessionBody(note,images:links,contexts:fresh).utf8)
   if !fm.fileExists(atPath:copy.path) || fileHash(copy)==saved.cloudCopy{try text.write(to:copy,options:.atomic)}
   var kept=saved;kept.digest=digest;kept.revision=stamp?.revision?.value;kept.updated=stamp?.updated_at ?? item.updated_at;kept.shas=shas;kept.cloudCopy=sessionFingerprint(text);kept.render=cloudRenderVersion;kept.files.merge(sides){_,b in b};index.put(kept);return
  }
  // Nová relace: „YYYY-MM-DD Název.md“ v kořeni, obrázky „YYYY-MM-DD Název-N.png“ ve společném assets/.
  let stem=flatStem(readableSessionName(note.title,created:parseServerDate(record?.created ?? created) ?? Date()),base:base)
  var names:[String]=[];for i in data.indices{names.append(uniqueName(stem+"-\(i+1)"){assetStemTaken(assets,$0) || names.contains($0+".png")}+".png")}
  let body=cloudSessionBody(note,images:names,contexts:contexts),markdown=base.appendingPathComponent(stem+".md")
  var files=[markdown.lastPathComponent:sessionFingerprint(Data(body.utf8))]
  for (name,bytes) in zip(names,data){try bytes.write(to:assets.appendingPathComponent(name),options:.withoutOverwriting);files["assets/"+name]=sessionFingerprint(bytes)}
  try Data(body.utf8).write(to:markdown,options:.withoutOverwriting)
  files.merge(try writeContextAttachments(contexts,names:names,assets:assets)){a,_ in a}
  index.put(finished(markdown,body,names,files));writeSessionTag(markdown,lower)
 }
 private func uniqueStem(_ name:String,base:URL)->String {
  let used=Set(SessionIndex.shared.all.filter{$0.base==SessionIndex.key(base)}.compactMap(\.stem))
  return uniqueName(name){used.contains($0) || fm.fileExists(atPath:base.appendingPathComponent("assets/"+$0+"-1.png").path) || fm.fileExists(atPath:self.trashURL(base).appendingPathComponent($0+".md").path)}
 }
 /// Starší obrázky `assets/<uuid>/N.png` se přejmenují, pokud je nikdo neupravil.
 private func migrateCombined(_ id:UUID,created:String?,topic:Topic,base:URL,endpoint:CloudEndpoint,owner:UUID)->SessionRecord? {
  let lower=id.uuidString.lowercased()
  guard let receipt=readReceipt(receiptFile(endpoint,owner:owner,base:base,id:id,kind:"combined")),let note=receipt.note else{return nil}
  let assets=base.appendingPathComponent("assets"),legacy=assets.appendingPathComponent(lower)
  let stem=uniqueStem(readableSessionName(note.title,created:parseServerDate(created) ?? Date()),base:base)
  var names:[String]=[],files:[String:String]=[:]
  for image in note.images {
   let old=legacy.appendingPathComponent("\(image.index).png"),hash=fileHash(old),recorded=receipt.files?["\(image.index).png"]
   let renamed=stem+"-\(image.index).png",target=assets.appendingPathComponent(renamed)
   if hash==nil || (hash==recorded && !fm.fileExists(atPath:target.path) && (try? fm.moveItem(at:old,to:target)) != nil){names.append(renamed);files["assets/"+renamed]=recorded ?? ""}
   else{names.append(lower+"/\(image.index).png");files["assets/"+lower+"/\(image.index).png"]=recorded ?? hash}
  }
  if (try? fm.contentsOfDirectory(atPath:legacy.path))?.filter({!$0.hasPrefix(".")}).isEmpty==true{try? fm.removeItem(at:legacy)}
  var record=cloudRecord(id,topic:topic,base:base,body:"",images:names,note:note)
  record.combined=true;record.files=files;record.updated=receipt.updated;record.created=created;record.digest=receipt.fingerprint;record.shas=receipt.shas;record.note=note;record.stem=stem
  SessionIndex.shared.put(record);return record
 }
 /// Společný soubor se skládá ze všech aktivních relací; ručně upravený soubor se nepřepíše.
 @MainActor private func materializeCombined(_ items:[RemoteNoteList.Note],trashed:[RemoteNoteList.Note],topic:Topic,base:URL,endpoint:CloudEndpoint,token:String)async throws {
  guard isCurrent(topic,token:token),let owner=topic.cloudOwnerID,let folderID=topic.cloudFolderID else{throw CloudFailure.invalid}
  let index=SessionIndex.shared,assets=base.appendingPathComponent("assets",isDirectory:true)
  var sections:[(SessionRecord,Int)]=[],refreshed=Set<String>(),failure:Error?
  func present(_ r:SessionRecord)->Bool{r.note != nil && !r.images.isEmpty && r.images.allSatisfy{fm.fileExists(atPath:assets.appendingPathComponent($0).path)}}
  for (order,item) in items.enumerated() {
   var record=index.cloud(item.id,base:base)
   if let saved=record,saved.stem==nil{record=nil}
   if let saved=record,saved.trashed==true{record=restoreCombined(saved,base:base)}
   if let saved=record,let updated=item.updated_at,saved.updated==updated,item.revision==nil || item.revision?.value==saved.revision,saved.render==cloudRenderVersion,present(saved){sections.append((saved,order));continue}
   let fetched:(RemoteNote,RemoteNoteStamp?,String)
   do{fetched=try await fetchNote(item.id,endpoint:endpoint,token:token)}
   catch {
    // Nedostupná relace: známý blok zůstává beze změny, nová se přidá při dalším průchodu.
    guard isCurrent(topic,token:token),record?.note != nil || record==nil else{throw error}
    failure=failure ?? error;if let saved=record{sections.append((saved,order))};continue
   }
   let (note,stamp,digest)=fetched
   let created=stamp?.created_at ?? item.created_at
   if record==nil{record=migrateCombined(item.id,created:created,topic:topic,base:base,endpoint:endpoint,owner:owner)}
   if var saved=record,saved.digest==digest,saved.render==cloudRenderVersion,present(saved) {
    saved.updated=stamp?.updated_at ?? item.updated_at;saved.created=saved.created ?? created;saved.revision=stamp?.revision?.value ?? saved.revision;index.put(saved);sections.append((saved,order));continue
   }
   let data:[Data]
   let contexts:[Int:[String:Data]]
   do{data=try await images(note,topic:topic,endpoint:endpoint,token:token);contexts=try await contextAttachments(note,topic:topic,endpoint:endpoint,token:token)}
   catch {
    guard isCurrent(topic,token:token),record?.note != nil || record==nil else{throw error}
    failure=failure ?? error;if let saved=record{sections.append((saved,order))};continue
   }
   guard try Topics.checkedDestination(topic.folder)==base,isCurrent(topic,token:token) else{throw CloudFailure.invalid}
   try fm.createDirectory(at:assets,withIntermediateDirectories:true)
   let stem=record?.stem ?? uniqueStem(readableSessionName(note.title,created:parseServerDate(created) ?? Date()),base:base)
   var names=Array((record?.images ?? []).prefix(data.count)),files=record?.files ?? [:]
   for (i,bytes) in data.enumerated() {
    if i>=names.count{names.append(uniqueName(stem+"-\(i+1)"){assetStemTaken(assets,$0) || names.contains($0+".png")}+".png")}
    let url=assets.appendingPathComponent(names[i]),existing=try? boundedData(url,max:52428800)
    // Místně upravený obrázek zůstává; převzatý originál, ze kterého server vznikl, se nepřepisuje.
    let source=existing != nil && record?.shas?.indices.contains(i)==true && record?.shas?[i]==sessionFingerprint(bytes) && existing.map(sessionFingerprint)==files["assets/"+names[i]]
    if source{continue}
    if existing==nil || (existing != bytes && existing.map(sessionFingerprint)==files["assets/"+names[i]]) {
     try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:url,options:.atomic)
    }
    files["assets/"+names[i]]=sessionFingerprint(bytes)
   }
   // Přílohy kontextu i ve společném souboru; index relace nese jejich hashe.
   let sides=try writeContextAttachments(contexts,names:names,assets:assets,previous:record?.files ?? [:])
   files=files.filter{!$0.key.hasSuffix(".context.json") && !$0.key.hasSuffix(".har") && !$0.key.hasSuffix(".mp4")}.merging(sides){a,_ in a}
   var next=cloudRecord(item.id,topic:topic,base:base,body:"",images:names,note:note)
   next.combined=true;next.files=files.filter{names.contains(String($0.key.dropFirst(7))) || sides[$0.key] != nil};next.updated=stamp?.updated_at ?? item.updated_at;next.created=record?.created ?? created
   next.digest=digest;next.shas=data.map(sessionFingerprint);next.note=note;next.stem=stem;next.file=record?.file ?? "";next.revision=stamp?.revision?.value
   // Metadata čtení patří bloku v souboru; nová se zapíšou až s novým blokem.
   next.render=cloudRenderVersion;next.imageTemplate=record?.imageTemplate ?? note.image_template;next.imageComments=record.map{$0.imageComments} ?? cloudImageComments(note,images:names)
   if let saved=record{next.start=saved.start;next.length=saved.length;next.hash=saved.hash;next.heading=saved.heading;next.footer=saved.footer}
   // Obsahově shodná relace (jen nové porovnání) se nebere jako změna.
   let same=record.map{$0.note.map{old in old.title==note.title && old.comment==note.comment && old.captions==note.captions && old.template==note.template && (!note.template.contains("{author}") || old.author==note.author)
    && old.comments==note.comments && old.comment_template==note.comment_template && old.image_template==note.image_template && old.issues==note.issues} ?? false && $0.render==cloudRenderVersion && $0.shas==next.shas} ?? false
   index.put(next);sections.append((next,order));if !same{refreshed.insert(next.id)}
  }
  for item in trashed {
   guard var record=index.cloud(item.id,base:base),record.stem != nil,record.trashed != true else{continue}
   // Upravené obrázky zůstávají a blok také.
   if !trashCombined(&record,base:base){notice(record);if present(record){sections.append((record,items.count+sections.count))}}
  }
  let dated=sections.map{parseServerDate($0.0.created)}
  let ordered=dated.allSatisfy({$0 != nil}) ? zip(sections,dated).sorted{($0.1!,$0.0.1)<($1.1!,$1.0.1)}.map(\.0):sections.sorted{$0.1<$1.1}
  let marker="\u{0}sessions\u{0}"
  // Název a popis složky jsou data ze serveru.
  let folderText=combinedFolderText(topic)
  var skeleton=renderCombinedTemplate(topic.combinedTemplate ?? defaultCombinedTemplate,folderName:folderText.0,folderDescription:folderText.1,sessions:marker)
  if !skeleton.contains(marker){skeleton+=marker}
  let split=(skeleton as NSString).range(of:marker),header=(skeleton as NSString).substring(to:split.location),footer=(skeleton as NSString).substring(from:NSMaxRange(split))
  var text=header;var placed:[(SessionRecord,Int,String)]=[]
  for (i,(record,_)) in ordered.enumerated() {
   if i>0{text+="\n\n---\n\n"}
   let body=cloudSessionBody(record.note!,images:record.images,contexts:diskContexts(record.images,assets:assets));placed.append((record,(text as NSString).length,body));text+=body
  }
  text+=footer
  let name=validCombinedFile(topic.combinedFile) ? topic.combinedFile:defaultCombinedFile
  var target=base.appendingPathComponent(name)
  let generated=Data(text.utf8),existing=try? boundedData(target,max:20000000)
  let baseline=index.generated(target) ?? readReceipt(receiptFile(endpoint,owner:owner,base:base,id:folderID,kind:"combined-file:"+name))?.fingerprint
  guard try Topics.checkedDestination(topic.folder)==base,isCurrent(topic,token:token) else{throw CloudFailure.invalid}
  try fm.createDirectory(at:base,withIntermediateDirectories:true)
  let mainKey=SessionIndex.key(target),current=existing.flatMap{String(data:$0,encoding:.utf8)}.map{$0 as NSString}
  // Ručně vedený soubor, který už obsahuje všechny relace beze změny, nepotřebuje kopii _cloud.
  let covered=existing != generated && existing.map(sessionFingerprint) != baseline && current != nil && !placed.isEmpty && placed.allSatisfy{entry in entry.0.file==mainKey && !refreshed.contains(entry.0.id) && locateSession(entry.0,in:current!,avoid:[]).map{sessionFingerprint(Data(current!.substring(with:$0.0).utf8))==entry.0.hash}==true}
  if existing==generated || covered{}
  else if existing==nil || existing.map(sessionFingerprint)==baseline{try generated.write(to:target,options:.atomic)}
  else {
   target=try writeGeneratedCopy(generated,to:base.appendingPathComponent((name as NSString).deletingPathExtension+"_cloud.md"))
  }
  index.batch {
   if !covered{index.setGenerated(target,sessionFingerprint(generated))}
   for (record,start,body) in placed {
    // Bloky z ručně upraveného hlavního souboru se dál hlídají v něm a drží svou pozici.
    var next=record;next.combined=true
    if record.file==mainKey && (covered || SessionIndex.key(target) != mainKey){index.put(next);continue}
    if let note=next.note{next.imageTemplate=note.image_template;next.imageComments=cloudImageComments(note,images:next.images)}
    next.file=SessionIndex.key(target);next.start=start;next.length=(body as NSString).length;next.hash=sessionFingerprint(Data(body.utf8))
    next.heading=firstLine(body);next.footer=footer;index.put(next)
   }
  }
  tagCombinedFile(target)
  if let failure{throw failure}
 }
 /// Otisky obrázků, které server u stažené relace má.
 func serverImages(for target:PreviousSessionTarget,topic:Topic)->(UUID,[String])? {
  guard let id=target.session.flatMap({UUID(uuidString:$0)}) ?? cloudSessionID(target.original),let owner=topic.cloudOwnerID,let origin=topic.cloudOrigin,let endpoint=CloudEndpoint(origin),
        !topic.folder.isEmpty,let base=try? Topics.checkedDestination(topic.folder) else{return nil}
  // Relace známá indexu se nikdy nedoplňuje, pokud je v koši nebo smazaná z disku; stará účtenka to nepřebije.
  if let record=SessionIndex.shared.cloud(id,base:base){return record.trashed != true && record.askDelete != true && record.missingSince==nil ? record.shas.map{(id,$0)}:nil}
  let parent=URL(fileURLWithPath:target.path).deletingLastPathComponent()
  if let separate=readReceipt(receiptFile(endpoint,owner:owner,base:base,id:id)),separate.name==parent.lastPathComponent,let shas=separate.shas{return (id,shas)}
  if let combined=readReceipt(receiptFile(endpoint,owner:owner,base:base,id:id,kind:"combined")),let shas=combined.shas{return (id,shas)}
  return nil
 }
 private func receiptFile(_ endpoint:CloudEndpoint,owner:UUID,base:URL,id:UUID,kind:String="")->URL {
  file.deletingLastPathComponent().appendingPathComponent("Cloud Downloads").appendingPathComponent(sessionFingerprint(Data((endpoint.url.absoluteString+owner.uuidString+base.path+id.uuidString+kind).utf8)))
 }
 private func readReceipt(_ url:URL)->DownloadReceipt? {
  guard let data=try? Data(contentsOf:url),data.count<=5000000 else{return nil}
  if let receipt=try? JSONDecoder().decode(DownloadReceipt.self,from:data){return receipt}
  guard let text=String(data:data,encoding:.utf8),let split=text.firstIndex(of:"\n") else{return nil}
  return DownloadReceipt(fingerprint:String(text[..<split]),name:String(text[text.index(after:split)...]))
 }
 private func fetchNote(_ id:UUID,endpoint:CloudEndpoint,token:String)async throws->(RemoteNote,RemoteNoteStamp?,String) {
  let path="/api/v1/sessions/"+id.uuidString.lowercased()
  let data=try await request(endpoint,path,token,CloudTransport.jsonLimit)
  var note=try JSONDecoder().decode(FolderEnvelope<RemoteNote>.self,from:data).data
  if note.comments?.isEmpty==true{note.comments=nil}
  if note.issues?.isEmpty==true{note.issues=nil}
  note=Self.normalizedAttachments(note,path:path)
  let stamp=(try? JSONDecoder().decode(FolderEnvelope<RemoteNoteStamp>.self,from:data))?.data
  guard note.id==id,(1...30).contains(note.images.count),note.captions.count==note.images.count,
        note.images.enumerated().allSatisfy({$0.element.index==$0.offset+1 && $0.element.path==path+"/images/\($0.offset+1)"}) else{throw CloudFailure.invalid}
  return (note,stamp,SHA256.hash(data:try JSONEncoder.sorted.encode(note)).map{String(format:"%02x",$0)}.joined())
 }
 private func isCurrent(_ topic:Topic,token:String)->Bool {
  currentConnection()?.token==token && account?.0==currentConnection()?.ownerID && account?.1==topic.cloudOrigin &&
   records.contains(where:{matches($0,topic) && $0.folder==topic.folder && $0.unavailable != true && $0.remoteDeleted != true})
 }
 /// Platné přílohy kontextu a videa; neznámé nebo nesedící záznamy se zahodí, prázdný seznam je nil.
 static func normalizedAttachments(_ source:RemoteNote,path:String)->RemoteNote {
  var note=source
  note.images=note.images.map{image in
   var copy=image
   let valid=(image.attachments ?? []).filter{CloudAttachment.validKind($0.kind) && (1...CloudAttachment(index:1,kind:$0.kind,bytes:0,sha256:"").sizeLimit).contains($0.bytes) && $0.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
    && $0.path==path+"/attachments/\(image.index)/\($0.kind)"}
   copy.attachments=valid.isEmpty ? nil:Array(Dictionary(valid.map{($0.kind,$0)},uniquingKeysWith:{a,_ in a}).values).sorted{$0.kind<$1.kind}
   return copy
  }
  return note
 }
 /// Stáhne přílohy kontextu a ověří velikost a hash; výsledek je index snímku → druh → data.
 @MainActor private func contextAttachments(_ note:RemoteNote,topic:Topic,endpoint:CloudEndpoint,token:String)async throws->[Int:[String:Data]] {
  var result:[Int:[String:Data]]=[:]
  for image in note.images {
   for item in image.attachments ?? [] {
    guard isCurrent(topic,token:token) else{throw CloudFailure.invalid}
    // Chybějící nebo poškozená příloha neblokuje stažení relace; dočasná chyba ho zopakuje později.
    let data:Data
    do{data=try await request(endpoint,item.path,token,CloudAttachment(index:1,kind:item.kind,bytes:0,sha256:"").sizeLimit+1)}
    catch let failure as CloudFailure where failure.status==404{continue}
    guard data.count==item.bytes,sessionFingerprint(data)==item.sha256 else{continue}
    result[image.index,default:[:]][item.kind]=data
   }
   // Metadata videa jako video.json do složky snímků (časy z media).
   if result[image.index]?["video"] != nil,let json=remoteVideoInfo(image.attachments ?? [],downloaded:Set(result[image.index]?.keys.map{$0} ?? [])).flatMap({try? JSONEncoder().encode($0)}){result[image.index]?["video.json"]=json}
   else{result[image.index]?["video"]=nil}
  }
  return result
 }
 /// Zapíše přílohy vedle obrázků v assets/ (`<název>.context.json`, `<název>.har`) a vrátí jejich hashe pro index relace.
 func writeContextAttachments(_ contexts:[Int:[String:Data]],names:[String],assets:URL,prefix:String="assets/",previous:[String:String]=[:])throws->[String:String] {
  var files:[String:String]=[:]
  for (position,name) in names.enumerated() {
   for (kind,target) in zip(["context","har"],assetContextFiles(assets,name)) {
    let key=prefix+target.lastPathComponent
    if let data=contexts[position+1]?[kind] {
     if fileHash(target) != sessionFingerprint(data) {
      // Soubor vzniká rovnou jako 0600 a přejmenuje se na místo.
      let temporary=assets.appendingPathComponent(".\(UUID().uuidString).tmp")
      guard fm.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw CloudFailure.invalid}
      guard rename(temporary.path,target.path)==0 else{try? fm.removeItem(at:temporary);throw CloudFailure.invalid}
     } else{try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)}
     files[key]=sessionFingerprint(data)
    // Smazat jen přílohu staženou dřív z cloudu; místní soubor zůstává.
    } else if previous[key] != nil,fm.fileExists(atPath:target.path){try fm.removeItem(at:target)}
   }
   // Video: `<název>.mp4` a `<název>.frames/` (N.png + video.json) vedle posteru.
   let video=assetVideoFiles(assets,name),key=prefix+video[0].lastPathComponent
   // Místně změněné MP4 (jiný hash než při posledním stažení) se nepřepíše ani nesmaže.
   let edited=fm.fileExists(atPath:video[0].path) && fileHash(video[0]) != previous[key]
   // Cizí MP4 bez záznamu v indexu se nepřebírá (sync ho nikdy nepřepíše ani nesmaže).
   if edited{if let hash=previous[key]{files[key]=hash}}
   else if let mp4=contexts[position+1]?["video"],let json=contexts[position+1]?["video.json"],let info=try? JSONDecoder().decode(VideoInfo.self,from:json) {
    if fileHash(video[0]) != sessionFingerprint(mp4){try replaceFile(video[0],with:mp4,in:assets)}
    // Snímky se porovnají i obsahem; stejný čas a název neznamená stejný obrázek.
    let current=info.frames.allSatisfy{frame in (try? Data(contentsOf:video[1].appendingPathComponent(frame.file))) == contexts[position+1]?["frame-"+frame.file.replacingOccurrences(of:".png",with:"")]}
    if (try? Data(contentsOf:video[1].appendingPathComponent("video.json"))) != json || !current {
     let staging=assets.appendingPathComponent(".\(UUID().uuidString).frames",isDirectory:true)
     try fm.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
     do {
      for frame in info.frames{guard let data=contexts[position+1]?["frame-"+frame.file.replacingOccurrences(of:".png",with:"")] else{continue};guard fm.createFile(atPath:staging.appendingPathComponent(frame.file).path,contents:data,attributes:[.posixPermissions:0o600]) else{throw CloudFailure.invalid}}
      guard fm.createFile(atPath:staging.appendingPathComponent("video.json").path,contents:json,attributes:[.posixPermissions:0o600]) else{throw CloudFailure.invalid}
      try? fm.removeItem(at:video[1]);try fm.moveItem(at:staging,to:video[1])
     }catch{try? fm.removeItem(at:staging);throw error}
    }
    files[key]=sessionFingerprint(mp4)
   } else if previous[key] != nil {for url in video{try? fm.removeItem(at:url)}}
  }
  return files
 }
 /// Soubor vzniká rovnou jako 0600 a přejmenuje se na místo.
 private func replaceFile(_ target:URL,with data:Data,in assets:URL)throws {
  let temporary=assets.appendingPathComponent(".\(UUID().uuidString).tmp")
  guard fm.createFile(atPath:temporary.path,contents:data,attributes:[.posixPermissions:0o600]) else{throw CloudFailure.invalid}
  guard rename(temporary.path,target.path)==0 else{try? fm.removeItem(at:temporary);throw CloudFailure.invalid}
 }
 @MainActor private func images(_ note:RemoteNote,topic:Topic,endpoint:CloudEndpoint,token:String)async throws->[Data] {
  var total=0;var result:[Data]=[]
  for image in note.images {
   guard isCurrent(topic,token:token) else{throw CloudFailure.invalid}
   let data=try await request(endpoint,image.path,token,CloudTransport.imageLimit);total+=data.count
   guard isCurrent(topic,token:token) else{throw CloudFailure.invalid}
   guard total<=100000000,data.starts(with:[137,80,78,71,13,10,26,10]) else{throw CloudFailure.invalid}
   result.append(data)
  }
  return result
 }
}
