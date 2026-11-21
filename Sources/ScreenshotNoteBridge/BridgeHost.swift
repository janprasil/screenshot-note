import Foundation

// Native Messaging host: Chrome (stdio) ↔ appka (Unix socket). Běží i bez appky.
@main enum BridgeHost {
 static func main(){
  signal(SIGPIPE,SIG_IGN)
  let path=ProcessInfo.processInfo.environment["SCREENSHOT_NOTE_BRIDGE_SOCKET"] ?? BridgeWire.defaultSocketPath
  exit(BridgeRelay(socketPath:path).run())
 }
}

final class BridgeRelay:@unchecked Sendable {
 let socketPath:String
 private let lock=NSLock();private let outputLock=NSLock()
 private var socket:Int32 = -1;private var hello:Data?
 private let offline=try! JSONSerialization.data(withJSONObject:["type":"hello","protocol":BridgeWire.protocolVersion,"app":["running":false]] as [String:Any])
 init(socketPath:String){self.socketPath=socketPath}

 func run()->Int32{
  Thread.detachNewThread{[self] in while true{connectIfNeeded();Thread.sleep(forTimeInterval:2)}}
  while true{
   switch BridgeWire.readFrame(STDIN_FILENO,limit:BridgeWire.inputLimit){
   case .end:return 0
   case .tooLarge(let length):log("message from browser too large (\(length) B)");return 1
   case .message(let data):forward(data)
   }
  }
 }

 private func log(_ text:String){FileHandle.standardError.write(Data(("screenshot-note-bridge: "+text+"\n").utf8))}

 private func toBrowser(_ data:Data){
  guard data.count<=BridgeWire.browserOutputLimit else{log("message for browser too large (\(data.count) B), dropped");return}
  outputLock.lock();defer{outputLock.unlock()}
  if !BridgeWire.writeAll(STDOUT_FILENO,BridgeWire.frame(data)){exit(0)}
 }

 private func forward(_ data:Data){
  guard let type=BridgeWire.messageType(data) else{log("invalid message from browser, dropped");return}
  lock.lock();defer{lock.unlock()}
  if type=="hello"{hello=data}
  // Zavření a hlášení offline nechá na čtecím vlákně, aby se číslo fd nerecyklovalo pod rukama.
  if socket>=0{if !BridgeWire.writeAll(socket,BridgeWire.frame(data)){shutdown(socket,SHUT_RDWR)};return}
  // Offline odpověď pod zámkem, aby nepředběhla online hello z nového spojení.
  if type=="hello"{toBrowser(offline)}
 }

 private func connectIfNeeded(){
  lock.lock();defer{lock.unlock()}
  guard socket<0,let fd=BridgeWire.connect(socketPath) else{return}
  if let hello,!BridgeWire.writeAll(fd,BridgeWire.frame(hello)){close(fd);return}
  socket=fd
  Thread.detachNewThread{[self] in readApp(fd)}
 }

 private func readApp(_ fd:Int32){
  loop:while true{
   switch BridgeWire.readFrame(fd,limit:BridgeWire.inputLimit){
   case .message(let data):
    if BridgeWire.messageType(data)==nil{log("invalid message from app, dropped")}else{toBrowser(data)}
   case .tooLarge(let length):
    log("message from app too large (\(length) B), dropped")
    if !BridgeWire.skip(fd,length){break loop}
   case .end:break loop
   }
  }
  lock.lock();defer{lock.unlock()}
  if socket==fd{socket = -1}
  close(fd)
  if hello != nil{toBrowser(offline)}
 }
}
