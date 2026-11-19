import AppKit
import CryptoKit

struct CloudFolderRecord:Codable {
 let id:UUID;var name:String;let owner:UUID;let origin:String
 var folder:String=""
 var topic:Topic{Topic(id:"cloud:"+origin+":"+owner.uuidString+":"+id.uuidString,name:name,detail:L("Cloudová složka"),folder:folder,combined:false,combinedFile:"Note.md",cloudFolderID:id,cloudOwnerID:owner,cloudOrigin:origin)}
}
private struct FolderEnvelope<T:Decodable>:Decodable{let data:T}
private struct RemoteFolder:Decodable{let id:UUID;let name:String;let revision:String}
private struct RemoteNoteList:Decodable {
 struct Note:Decodable{let id:UUID;let deleting:Bool}
 struct Pagination:Decodable{let has_more:Bool}
 let data:[Note];let pagination:Pagination
}
private struct RemoteNote:Codable {
 let id:UUID;let title:String;let comment:String;let template:String;let captions:[String]
 struct Image:Codable{let index:Int;let path:String}
 let images:[Image]
}

final class CloudFolders {
 static let shared=CloudFolders()
 private let file:URL
 private let currentConnection:()->CloudConnection?
 private let localTopics:()->[Topic]
 private let request:(CloudEndpoint,String,String,Int) async throws->Data
 private(set) var records:[CloudFolderRecord]=[]
 private var account:(UUID,String)?
 private var readable=true
 var isReadable:Bool{readable}
 private(set) var syncing=false
 var lastError:String?
 var topics:[Topic]{guard let account else{return []};return records.filter{$0.owner==account.0 && $0.origin==account.1}.map(\.topic)}
 var allTopics:[Topic]{records.map(\.topic)}
 init(file:URL=draftRoot.deletingLastPathComponent().appendingPathComponent("Cloud Folders.json"),connection:@escaping ()->CloudConnection? = {CloudLibrary.shared.connection},localTopics:@escaping ()->[Topic] = {Topics.local},request:@escaping (CloudEndpoint,String,String,Int) async throws->Data = {endpoint,path,token,limit in try await CloudTransport.shared.request(endpoint,path,token:token,limit:limit)}) {
  self.file=file;currentConnection=connection;self.localTopics=localTopics;self.request=request
  if fm.fileExists(atPath:file.path) {
   do {let data=try Data(contentsOf:file);guard data.count<=2000000 else{throw CloudFailure.invalid};records=try JSONDecoder().decode([CloudFolderRecord].self,from:data)}
   catch{readable=false;lastError=L("Uložené cloudové složky nelze načíst. Místní data zůstávají zachovaná.")}
  }
 }
 func activate(_ connection:CloudConnection?){account=connection.flatMap{c in c.ownerID.map{($0,c.endpoint)}}}
 private func persist(_ updated:[CloudFolderRecord])throws {
  guard readable else{throw CloudFailure.invalid}
  try Topics.validateDestinations(localTopics()+updated.map(\.topic))
  let data=try JSONEncoder().encode(updated);guard data.count<=2000000 else{throw CloudFailure.invalid}
  try fm.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
  try data.write(to:file,options:.atomic);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);records=updated
 }
 func setFolder(_ topic:Topic,path:String)throws {
  guard let account,topic.cloudOwnerID==account.0,topic.cloudOrigin==account.1,
        let i=records.firstIndex(where:{$0.id==topic.cloudFolderID && $0.owner==account.0 && $0.origin==account.1}) else{throw CloudFailure.invalid}
  var updated=records;updated[i].folder=path
  try persist(updated)
 }
 func accept(_ folders:[CloudFolderRecord])throws {
  guard let account,folders.count<=200,Set(folders.map(\.id)).count==folders.count,
        folders.allSatisfy({$0.owner==account.0 && $0.origin==account.1 && !$0.name.isEmpty && $0.name.unicodeScalars.count<=100 && !$0.name.contains("\0")}) else{throw CloudFailure.invalid}
  var updated=records.filter{$0.owner != account.0 || $0.origin != account.1}
  for var folder in folders {
   folder.folder=records.first(where:{$0.id==folder.id && $0.owner==folder.owner && $0.origin==folder.origin})?.folder ?? ""
   updated.append(folder)
  }
  try persist(updated)
 }
 @MainActor func refresh(_ connection:CloudConnection?) async {
  activate(connection)
  guard !syncing,readable,let c=connection,let owner=c.ownerID,let endpoint=CloudEndpoint(c.endpoint) else{return}
  syncing=true;defer{syncing=false;NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)}
  do {
   let data=try await request(endpoint,"/api/v1/folders",c.token,524288)
   guard currentConnection()?.token==c.token else{throw CloudFailure.invalid}
   let remote=try JSONDecoder().decode(FolderEnvelope<[RemoteFolder]>.self,from:data).data
   try accept(remote.map{CloudFolderRecord(id:$0.id,name:$0.name,owner:owner,origin:c.endpoint)})
   lastError=nil
   for topic in topics where topic.savesLocally {
    try Topics.validateDestination(topic,folder:topic.destination,among:localTopics()+allTopics)
    var page=1
    while page<=10000 {
     guard currentConnection()?.token==c.token else{throw CloudFailure.invalid}
     let path="/api/v1/sessions?folder_id="+topic.cloudFolderID!.uuidString.lowercased()+"&sort=oldest&page=\(page)"
     let list=try JSONDecoder().decode(RemoteNoteList.self,from:await request(endpoint,path,c.token,524288))
     for note in list.data where !note.deleting {try await download(note.id,topic:topic,endpoint:endpoint,token:c.token)}
     if !list.pagination.has_more{break};page+=1
    }
   }
  } catch {lastError=(error as? CloudFailure)?.message ?? L("Cloudové složky se nepodařilo synchronizovat. Místní data zůstávají zachovaná.")}
 }
 @MainActor private func download(_ id:UUID,topic:Topic,endpoint:CloudEndpoint,token:String) async throws {
  func current()->Bool {
   currentConnection()?.token==token && account?.0==topic.cloudOwnerID && account?.1==topic.cloudOrigin &&
    records.contains(where:{$0.id==topic.cloudFolderID && $0.owner==topic.cloudOwnerID && $0.origin==topic.cloudOrigin && $0.folder==topic.folder})
  }
  guard current() else{throw CloudFailure.invalid}
  let path="/api/v1/sessions/"+id.uuidString.lowercased()
  let note=try JSONDecoder().decode(FolderEnvelope<RemoteNote>.self,from:await request(endpoint,path,token,524288)).data
  guard note.id==id,(1...30).contains(note.images.count),note.captions.count==note.images.count,
        note.images.enumerated().allSatisfy({$0.element.index==$0.offset+1 && $0.element.path==path+"/images/\($0.offset+1)"}) else{throw CloudFailure.invalid}
  let fingerprint=SHA256.hash(data:try JSONEncoder.sorted.encode(note)).map{String(format:"%02x",$0)}.joined()
  let base=try Topics.checkedDestination(topic.folder)
  let receipt=file.deletingLastPathComponent().appendingPathComponent("Cloud Downloads").appendingPathComponent(SHA256.hash(data:Data((endpoint.url.absoluteString+topic.cloudOwnerID!.uuidString+base.path+id.uuidString).utf8)).map{String(format:"%02x",$0)}.joined())
  if let saved=try? String(contentsOf:receipt,encoding:.utf8),saved.hasPrefix(fingerprint+"\n") {
   let name=String(saved.dropFirst(fingerprint.count+1))
   guard name==id.uuidString.lowercased() || name==id.uuidString.lowercased()+"-"+fingerprint.prefix(12) else{throw CloudFailure.invalid}
   let target=base.appendingPathComponent(name)
   if fm.fileExists(atPath:target.appendingPathComponent("Note.md").path),note.images.allSatisfy({fm.fileExists(atPath:target.appendingPathComponent("assets/\($0.index).png").path)}){return}
  }
  try fm.createDirectory(at:base,withIntermediateDirectories:true)
  let staging=base.appendingPathComponent(".screenshot-note-"+UUID().uuidString,isDirectory:true)
  try fm.createDirectory(at:staging.appendingPathComponent("assets"),withIntermediateDirectories:true);defer{try? fm.removeItem(at:staging)}
  var total=0;var files:[String:Data]=[:]
  for image in note.images {
   guard current() else{throw CloudFailure.invalid}
   let data=try await request(endpoint,image.path,token,52428800);total+=data.count
   guard current() else{throw CloudFailure.invalid}
   guard total<=100000000,data.starts(with:[137,80,78,71,13,10,26,10]) else{throw CloudFailure.invalid}
   files["assets/\(image.index).png"]=data
  }
  let screenshots=note.images.map{image in "![[assets/\(image.index).png]]"+(note.captions[image.index-1].isEmpty ? "":"\n\n"+note.captions[image.index-1])}.joined(separator:"\n\n")
  let markdown=renderSessionTemplate(note.template,title:note.title,screenshots:screenshots,text:note.comment)
  files["Note.md"]=Data(markdown.utf8)
  for (name,data) in files{try data.write(to:staging.appendingPathComponent(name),options:.withoutOverwriting)}
  try Topics.validateDestination(topic,folder:base,among:localTopics()+allTopics)
  guard try Topics.checkedDestination(topic.folder)==base,current() else{throw CloudFailure.invalid}
  let primary=base.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
  func matches(_ target:URL)->Bool{files.allSatisfy{(try? Data(contentsOf:target.appendingPathComponent($0.key),options:.mappedIfSafe))==$0.value}}
  let target:URL
  if !fm.fileExists(atPath:primary.path) || matches(primary){target=primary}
  else {target=base.appendingPathComponent(id.uuidString.lowercased()+"-"+fingerprint.prefix(12),isDirectory:true)}
  if fm.fileExists(atPath:target.path){guard matches(target) else{throw CloudFailure(L("Místní soubory byly upraveny. Synchronizace je nepřepíše."))}}
  else{try fm.moveItem(at:staging,to:target)}
  try fm.createDirectory(at:receipt.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try Data((fingerprint+"\n"+target.lastPathComponent).utf8).write(to:receipt,options:.atomic)
 }
}
private extension JSONEncoder{static var sorted:JSONEncoder{let value=JSONEncoder();value.outputFormatting = .sortedKeys;return value}}
extension Notification.Name{static let cloudFoldersChanged=Notification.Name("ScreenshotNoteCloudFoldersChanged")}
