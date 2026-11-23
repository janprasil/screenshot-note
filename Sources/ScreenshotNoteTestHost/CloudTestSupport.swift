import AppKit
@testable import ScreenshotNoteKit

func cloudFixtureConnection(owner: UUID? = UUID()) -> CloudConnection {
 let id=UUID()
 return CloudConnection(endpoint:"https://fixture.invalid",token:"sn_device_v1_" + String(repeating:"a",count:43),id:id,
  comparisonCode:"1234ABCD",verificationURI:"https://fixture.invalid/pair-device/" + id.uuidString.lowercased(),expiresAt:"2099-01-01T00:00:00Z",ownerID:owner,email:nil)
}

/// /me pro testovací transport; s `teams` vrací i pole libraries.
func cloudFixtureMe(_ owner:UUID,teams:[[String:Any]]?=nil)throws->Data {
 var me:[String:Any]=["id":owner.uuidString,"email":"fixture@example.test"]
 if let teams{me["libraries"]=[["id":owner.uuidString,"kind":"personal","name":NSNull(),"role":"owner"]]+teams}
 return try JSONSerialization.data(withJSONObject:["data":me])
}

func cloudFixturePNG(_ red:CGFloat=0.2) -> Data {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:8,bitsPerPixel:32)!
 for y in 0...1 { for x in 0...1 { bitmap.setColor(NSColor(calibratedRed:red,green:0.4,blue:0.8,alpha:1),atX:x,y:y) } }
 return bitmap.representation(using:.png,properties:[:])!
}

func legacyMarkdown(_ id:String,_ title:String,_ comment:String,_ images:[String],template:String=defaultMarkdownTemplate)->(String,String) {
 let body=renderSessionTemplate(template,title:title,screenshots:images.map{"![[assets/\($0)]]"}.joined(separator:"\n\n"),text:comment)
 let metadata=SessionMetadata(title:title,comment:comment,images:images,imageNotes:Dictionary(uniqueKeysWithValues:images.map{($0,"")}),bodyLength:(body as NSString).length,bodyHash:sessionFingerprint(Data(body.utf8)),sessionID:id,template:template)
 return ("<!-- screenshot-note:begin "+id+" -->\n"+body+"<!-- screenshot-note:v1 "+(try! JSONEncoder().encode(metadata)).base64EncodedString()+" -->\n",body)
}

/// Testovací server pro místní mazání: stav relací, POST trash/restore a hodiny.
@MainActor final class DeletionFixture {
 let c=cloudFixtureConnection(),folderID=UUID(),root:URL,png=cloudFixturePNG(0.4)
 var ids:[UUID]=[],states:[UUID:String]=[:],posts:[UUID]=[],clock=Date(timeIntervalSince1970:1_800_000_000),busy=Set<UUID>()
 var store:CloudFolders!
 init(_ root:URL,count:Int,combined:Bool)throws {
  self.root=root;ids=(0..<count).map{_ in UUID()};for id in ids{states[id]="active"}
  store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{[unowned self] in self.c},localTopics:{[]},request:{[unowned self] _,path,_,_ in
   if path=="/api/v1/me"{return try cloudFixtureMe(self.c.ownerID!)}
   if path.contains("/images/"){return self.png}
   let data:Any
   if path=="/api/v1/folders"{data=["data":[["id":self.folderID.uuidString,"name":"Mazání","revision":"1","combined":combined,"combined_file":"All.md"]]]}
   else if path.contains("?") {
    let wanted=path.contains("state=trashed") ? "trashed":"active"
    data=["data":self.ids.filter{self.states[$0]==wanted}.map{["id":$0.uuidString,"updated_at":"t1","trashed_at":wanted=="trashed" ? "2026-01-01T00:00:00Z":NSNull()]},"pagination":["has_more":false]]
   } else {
    let id=self.ids.first{path.contains($0.uuidString.lowercased())}!,index=self.ids.firstIndex(of:id)!
    data=["data":["id":id.uuidString,"title":"Relace \(index)","comment":"Text \(index)","template":defaultMarkdownTemplate,"captions":[""],"updated_at":"t1","created_at":"2026-01-0\(index%9+1)T10:00:00Z","images":[["index":1,"path":"/api/v1/sessions/"+id.uuidString.lowercased()+"/images/1"]]]]
   }
   return try JSONSerialization.data(withJSONObject:data)
  },send:{[unowned self] _,path,_,_,_ in
   let id=self.ids.first{path.contains($0.uuidString.lowercased())}!
   if path.hasSuffix("/trash"){self.posts.append(id);self.states[id]="trashed"}else{self.states[id]="active"}
   return try JSONSerialization.data(withJSONObject:["data":["id":id.uuidString]])
  },now:{[unowned self] in self.clock},pending:{[unowned self] in self.busy.contains($0)})
 }
 var target:URL{root.appendingPathComponent("cloud")}
 func start()async throws{await store.refresh(c);try store.setFolder(store.topics[0],path:target.path);await store.refresh(c);assert(store.lastError==nil)}
 func scan(after seconds:Double)async{clock=clock.addingTimeInterval(seconds);await store.refresh(c)}
 func directory(_ i:Int)->URL{URL(fileURLWithPath:SessionIndex.shared.cloud(ids[i],base:try! Topics.checkedDestination(target.path))!.file)}
 func markdowns()->Int{((try? fm.contentsOfDirectory(atPath:target.path)) ?? []).filter{$0.hasSuffix(".md")}.count}
}

/// Odpovědi pro CloudTransport bez sítě: /me a nahrávání do složky v Koši.
final class TrashedFolderStub: URLProtocol {
 static var owner=UUID()
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "",me=path=="/api/v1/me"
  let body=me ? ["data":["id":Self.owner.uuidString]]:["error":["code":"folder_trashed"]]
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:me ? 200:409,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}

/// Server bez sítě, který nahrání hned potvrdí a zapamatuje si manifest.
final class AcceptingUploadStub: URLProtocol {
 static var owner=UUID()
 static var manifests:[(UUID,[String:Any])]=[]
 static var aiTitleCalls:[UUID]=[]
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "";var body:[String:Any]
  if path=="/api/v1/me"{body=["data":["id":Self.owner.uuidString]]}
  else if path.hasSuffix("/ai-title"),let id=UUID(uuidString:String(path.split(separator:"/").dropLast().last ?? "")){Self.aiTitleCalls.append(id);body=["data":["state":"done","title":"AI"]]}
  else {
   var data=request.httpBody ?? Data()
   if data.isEmpty,let stream=request.httpBodyStream{stream.open();var buffer=[UInt8](repeating:0,count:65536);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};stream.close()}
   let id=UUID(uuidString:String(path.split(separator:"/").last!))!,manifest=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
   if !Self.manifests.contains(where:{$0.0==id}){Self.manifests.append((id,manifest))}
   let count=(manifest["images"] as? [Any])?.count ?? 1
   body=["data":["session_id":id.uuidString,"manifest_digest":String(repeating:"b",count:64),"confirmed_indices":Array(1...count),"state":"committed"]]
  }
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}

/// Server pro PATCH úprav: drží jednu relaci s revizí, při nesouhlasu revize vrací 409.
final class EditStub: URLProtocol {
 static var owner=UUID(),remote:[String:Any]=[:],patches:[[String:Any]]=[],forbidden=false
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  let path=request.url?.path ?? "";var status=200,body:[String:Any]
  if path=="/api/v1/me"{body=["data":["id":Self.owner.uuidString]]}
  else if request.httpMethod=="PATCH" && Self.forbidden{Self.patches.append([:]);status=403;body=["error":["code":"role_forbidden"]]}
  else if request.httpMethod=="PATCH" {
   var data=request.httpBody ?? Data()
   if data.isEmpty,let stream=request.httpBodyStream{stream.open();var buffer=[UInt8](repeating:0,count:65536);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};stream.close()}
   let sent=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:];Self.patches.append(sent)
   if sent["revision"] as? String != Self.remote["revision"] as? String{status=409;body=["error":["code":"session_changed"]]}
   else{for key in ["title","comment","captions"]{Self.remote[key]=sent[key]};Self.remote["revision"]=String(Int(Self.remote["revision"] as! String)!+1);body=["data":Self.remote]}
  } else {body=["data":Self.remote]}
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body));client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
}

/// Server pro regresní testy fronty: odpověď určuje handler podle metody, cesty a těla.
final class ReviewStub: URLProtocol {
 static var handler:((String,String,Data)->(Int,Any))={_,_,_ in (404,["error":["code":"not_found"]])}
 static var log:[(String,String,Data)]=[]
 override class func canInit(with request:URLRequest)->Bool{true}
 override class func canonicalRequest(for request:URLRequest)->URLRequest{request}
 override func startLoading() {
  var data=request.httpBody ?? Data()
  if data.isEmpty,let stream=request.httpBodyStream{stream.open();var buffer=[UInt8](repeating:0,count:65536);while stream.hasBytesAvailable{let n=stream.read(&buffer,maxLength:buffer.count);if n<=0{break};data.append(buffer,count:n)};stream.close()}
  let method=request.httpMethod ?? "GET",path=request.url?.path ?? ""
  Self.log.append((method,path,data))
  let (status,body)=Self.handler(method,path,data)
  let payload=(body as? Data) ?? (try! JSONSerialization.data(withJSONObject:body))
  client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:payload);client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading(){}
 /// Obě session transportu míří na stub; vrací obnovení původních.
 static func install()->()->Void {
  let t=CloudTransport.shared,saved=(t.session,t.transferSession),config=URLSessionConfiguration.ephemeral;config.protocolClasses=[ReviewStub.self]
  t.session=URLSession(configuration:config);t.transferSession=URLSession(configuration:config)
  return {t.session=saved.0;t.transferSession=saved.1}
 }
}

func json(_ data:Data)->[String:Any]{(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]}
