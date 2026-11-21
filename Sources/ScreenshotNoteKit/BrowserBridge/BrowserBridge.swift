import BridgeWire
import Foundation

// Socket server pro screenshot-note-bridge. Každý připojený prohlížeč je jeden klient.
struct BrowserClientInfo {
 let id:Int;let connectedAt:Date
 var extensionVersion:String?;var browser:String?;var protocolVersion:Int?
 var helloAt:Date?;var lastSeen:Date
}

struct BrowserBridgeError:LocalizedError {let message:String;var errorDescription:String?{message}}

final class BrowserBridge:@unchecked Sendable {
 static let shared=BrowserBridge(socketPath:BridgeWire.defaultSocketPath)
 static let maxClients=16
 let socketPath:String
 private let lock=NSLock();private let queue=DispatchQueue(label:"cz.janprasil.screenshotnote.browser-bridge")
 private var listener:DispatchSourceRead?
 private var connections:[Int:Connection]=[:];private var nextID=1
 private var pending:[String:Pending]=[:];private var socketInode:ino_t?
 init(socketPath:String){self.socketPath=socketPath}

 private final class Connection:@unchecked Sendable {
  let fd:Int32;var info:BrowserClientInfo;private let writeLock=NSLock();private var closed=false
  init(fd:Int32,id:Int){self.fd=fd;let now=Date();info=BrowserClientInfo(id:id,connectedAt:now,lastSeen:now)}
  // Po zavření se fd už nepoužije, i kdyby ho systém přidělil novému klientovi.
  func send(_ payload:Data){
   writeLock.lock();defer{writeLock.unlock()}
   if !closed && !BridgeWire.writeAll(fd,BridgeWire.frame(payload)){shutdown(fd,SHUT_RDWR)}
  }
  func disconnect(){writeLock.lock();if !closed{shutdown(fd,SHUT_RDWR)};writeLock.unlock()}
  func close(){writeLock.lock();if !closed{closed=true;Darwin.close(fd)};writeLock.unlock()}
 }
 private final class Pending {var waiting:Set<Int>;let finish:(Data?)->Void;init(_ waiting:Set<Int>,_ finish:@escaping (Data?)->Void){self.waiting=waiting;self.finish=finish}}

 var isRunning:Bool{lock.lock();defer{lock.unlock()};return listener != nil}
 var clients:[BrowserClientInfo]{lock.lock();defer{lock.unlock()};return connections.values.map(\.info).sorted{$0.id<$1.id}}

 func start()throws{
  lock.lock();defer{lock.unlock()}
  guard listener==nil else{return}
  let directory=(socketPath as NSString).deletingLastPathComponent
  try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  chmod(directory,0o700)
  // Starý socket po pádu smažeme, jiný typ souboru necháme být.
  var existing=stat()
  if lstat(socketPath,&existing)==0{
   guard existing.st_mode & S_IFMT==S_IFSOCK else{throw BrowserBridgeError(message:"\(socketPath) exists and is not a socket")}
   if let live=BridgeWire.connect(socketPath){close(live);throw BrowserBridgeError(message:"\(socketPath) is used by another running instance")}
   unlink(socketPath)
  }
  let fd=socket(AF_UNIX,SOCK_STREAM,0)
  guard fd>=0 else{throw BrowserBridgeError(message:"socket: \(String(cString:strerror(errno)))")}
  guard BridgeWire.withAddress(socketPath,{bind(fd,$0,$1)})==0 else{let reason=String(cString:strerror(errno));close(fd);throw BrowserBridgeError(message:"bind \(socketPath): \(reason)")}
  chmod(socketPath,0o600)
  guard listen(fd,8)==0 else{close(fd);unlink(socketPath);throw BrowserBridgeError(message:"listen: \(String(cString:strerror(errno)))")}
  _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)
  let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:queue)
  source.setEventHandler{[weak self] in self?.acceptClients(fd)}
  source.setCancelHandler{close(fd)}
  source.resume();listener=source
  var created=stat();if lstat(socketPath,&created)==0{socketInode=created.st_ino}
  NSLog("Browser bridge listening on %@",socketPath)
 }

 func stop(){
  lock.lock()
  guard let source=listener else{lock.unlock();return}
  source.cancel();listener=nil
  let all=Array(connections.values);connections=[:]
  let waiting=Array(pending.values);pending=[:]
  lock.unlock()
  for connection in all{connection.disconnect()}
  for item in waiting{item.finish(nil)}
  // Cizí socket (jiná instance) nemažeme.
  var current=stat()
  if let inode=socketInode,lstat(socketPath,&current)==0,current.st_ino==inode{unlink(socketPath)}
  socketInode=nil
 }

 private func acceptClients(_ listenFD:Int32){
  while true{
   let fd=accept(listenFD,nil,nil)
   if fd<0{
    if errno==EINTR{continue}
    // Při vyčerpání fd zůstane spojení ve frontě, zdroj na chvíli uspíme.
    if errno != EAGAIN && errno != EWOULDBLOCK,let source=listener{NSLog("Browser bridge accept: %s",strerror(errno));source.suspend();queue.asyncAfter(deadline:.now()+1){source.resume()}}
    return
   }
   _=fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) & ~O_NONBLOCK)
   BridgeWire.noSigPipe(fd);BridgeWire.sendTimeout(fd)
   // Jen procesy stejného uživatele.
   var uid=uid_t(0),gid=gid_t(0)
   guard getpeereid(fd,&uid,&gid)==0,uid==getuid() else{close(fd);continue}
   lock.lock()
   guard connections.count<Self.maxClients else{lock.unlock();close(fd);NSLog("Browser bridge: too many clients");continue}
   let connection=Connection(fd:fd,id:nextID);nextID+=1;connections[connection.info.id]=connection
   lock.unlock()
   Thread.detachNewThread{[weak self] in self?.read(connection)}
  }
 }

 private func read(_ connection:Connection){
  loop:while true{
   switch BridgeWire.readFrame(connection.fd,limit:BridgeWire.inputLimit){
   case .message(let data):handle(data,from:connection)
   case .tooLarge(let length):
    NSLog("Browser bridge: message too large (%ld B), dropped",length)
    if !BridgeWire.skip(connection.fd,length){break loop}
   case .end:break loop
   }
  }
  lock.lock();connections[connection.info.id]=nil;lock.unlock()
  connection.close()
 }

 private func handle(_ data:Data,from connection:Connection){
  guard let message=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let type=message["type"] as? String else{NSLog("Browser bridge: invalid message dropped");return}
  lock.lock();connection.info.lastSeen=Date();lock.unlock()
  let id=message["id"] as? String
  switch type{
  case "hello":
   lock.lock()
   connection.info.extensionVersion=message["extensionVersion"] as? String
   connection.info.browser=message["browser"] as? String
   connection.info.protocolVersion=message["protocol"] as? Int
   connection.info.helloAt=Date()
   let info=connection.info
   lock.unlock()
   NSLog("Browser bridge hello: extension %@, protocol %ld, %@",info.extensionVersion ?? "?",info.protocolVersion ?? 0,info.browser ?? "?")
   let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "dev"
   if let reply=try? JSONSerialization.data(withJSONObject:["type":"hello","protocol":BridgeWire.protocolVersion,"app":["version":version,"running":true]] as [String:Any]){connection.send(reply)}
  case "pong":if let id{resolve(id,Data())}
  case "capture.result":
   guard let id else{return}
   if let bundle=message["bundle"] as? [String:Any],let data=try? JSONSerialization.data(withJSONObject:bundle){resolve(id,data)}else{fail(id,client:connection.info.id)}
  case "capture.error":
   NSLog("Browser bridge: capture error %@",message["code"] as? String ?? "?")
   if let id{fail(id,client:connection.info.id)}
  default:NSLog("Browser bridge: unknown message %@",type)
  }
 }

 private func resolve(_ id:String,_ data:Data?){
  lock.lock();let item=pending.removeValue(forKey:id);lock.unlock()
  item?.finish(data)
 }
 // Request končí bez výsledku, až odmítnou všichni oslovení klienti.
 private func fail(_ id:String,client:Int){
  lock.lock()
  guard let item=pending[id] else{lock.unlock();return}
  item.waiting.remove(client)
  if !item.waiting.isEmpty{lock.unlock();return}
  pending[id]=nil;lock.unlock()
  item.finish(nil)
 }

 private func ask(_ message:[String:Any],timeout:TimeInterval)async->Data?{
  let id=UUID().uuidString;var message=message;message["id"]=id
  guard let payload=try? JSONSerialization.data(withJSONObject:message) else{return nil}
  return await withCheckedContinuation{(continuation:CheckedContinuation<Data?,Never>) in
   lock.lock()
   let targets=connections.values.filter{$0.info.helloAt != nil}
   guard !targets.isEmpty else{lock.unlock();continuation.resume(returning:nil);return}
   pending[id]=Pending(Set(targets.map(\.info.id))){continuation.resume(returning:$0)}
   lock.unlock()
   // Deadline běží od začátku a zápisy jdou mimo volající vlákno.
   queue.asyncAfter(deadline:.now()+timeout){[weak self] in self?.resolve(id,nil)}
   for target in targets{DispatchQueue.global(qos:.userInitiated).async{target.send(payload)}}
  }
 }

 /// True, když aspoň jeden prohlížeč odpoví na ping.
 func ping(timeout:TimeInterval=1)async->Bool{await ask(["type":"ping"],timeout:timeout) != nil}

 /// Vyžádá kontext od připojených prohlížečů. Vrací JSON bundlu z první odpovědi, nebo nil.
 func request(policy:[String:Any]?=nil,target:[String:Any]?=nil,timeout:TimeInterval=1)async->Data?{
  var message:[String:Any]=["type":"capture.request"]
  if let policy{message["policy"]=policy}
  if let target{message["target"]=target}
  return await ask(message,timeout:timeout)
 }

 // Jen pro self-test.
 func broadcast(_ payload:Data){
  lock.lock();let all=Array(connections.values);lock.unlock()
  for connection in all{connection.send(payload)}
 }
}

// Registrace Native Messaging hostu v prohlížečích založených na Chromiu.
enum NativeHostRegistration {
 static let name="cz.janprasil.screenshotnote.bridge"
 static let enabledKey="browserBridgeEnabled"
 static let allowedOrigins=["chrome-extension://hffkngdjiopodemokmgiedickoiehidb/"]
 static let browserDirectories=["Google/Chrome","Google/Chrome Beta","Google/Chrome Canary","Microsoft Edge","BraveSoftware/Brave-Browser","Arc/User Data","Chromium"]
 static let helperName="screenshot-note-bridge"
 static var bundledHelper:URL{Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/"+helperName)}
 static var isEnabled:Bool{UserDefaults.standard.bool(forKey:enabledKey)}

 static func manifest(helper:URL)->Data{
  let object:[String:Any]=["name":name,"description":"Screenshot Note browser bridge","path":helper.path,"type":"stdio","allowed_origins":allowedOrigins]
  return (try? JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])) ?? Data()
 }
 static func manifestFiles(home:URL)->[URL]{
  let support=home.appendingPathComponent("Library/Application Support")
  return browserDirectories.compactMap{directory in
   var isDirectory:ObjCBool=false
   let base=support.appendingPathComponent(directory)
   guard FileManager.default.fileExists(atPath:base.path,isDirectory:&isDirectory),isDirectory.boolValue else{return nil}
   return base.appendingPathComponent("NativeMessagingHosts/\(name).json")
  }
 }
 /// Zapíše manifest jen tam, kde se liší. Tím se po přesunutí appky opraví `path`.
 /// Bez `replaceForeign` nechá cizí manifest (vývojový host) být.
 @discardableResult static func install(home:URL=FileManager.default.homeDirectoryForCurrentUser,helper:URL=bundledHelper,replaceForeign:Bool=true)throws->[URL]{
  let data=manifest(helper:helper)
  let files=manifestFiles(home:home).filter{replaceForeign || isOurs($0) || !FileManager.default.fileExists(atPath:$0.path)}
  for file in files where (try? Data(contentsOf:file)) != data{
   try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
   try data.write(to:file,options:.atomic)
  }
  return files
 }
 /// Smaže jen naše manifesty. Vývojový host z repa rozšíření nechá být.
 @discardableResult static func uninstall(home:URL=FileManager.default.homeDirectoryForCurrentUser)->[URL]{
  manifestFiles(home:home).filter{isOurs($0) && (try? FileManager.default.removeItem(at:$0)) != nil}
 }
 static func isOurs(_ file:URL)->Bool{
  guard let data=try? Data(contentsOf:file),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
        let path=object["path"] as? String else{return false}
  return (path as NSString).lastPathComponent==helperName
 }

 /// Při startu appky: přepíše manifesty a spustí server, pokud je funkce zapnutá.
 static func applyStoredSetting(){
  guard isEnabled else{return}
  do{try install(replaceForeign:false);try BrowserBridge.shared.start()}catch{NSLog("Browser bridge start failed: %@",error.localizedDescription)}
 }
 /// Vrací počet prohlížečů, do kterých se manifest zapsal.
 static func setEnabled(_ enabled:Bool)throws->Int{
  if !enabled{UserDefaults.standard.set(false,forKey:enabledKey);uninstall();BrowserBridge.shared.stop();return 0}
  // Zapnuto se uloží, až když manifesty i server opravdu běží.
  do{let files=try install();try BrowserBridge.shared.start();UserDefaults.standard.set(true,forKey:enabledKey);return files.count}
  catch{uninstall();throw error}
 }
}
