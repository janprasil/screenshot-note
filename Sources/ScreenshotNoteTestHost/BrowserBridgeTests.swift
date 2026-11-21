import BridgeWire
import Foundation
@testable import ScreenshotNoteKit


private final class FrameStream:@unchecked Sendable {
 private let lock=NSLock();private let signal=DispatchSemaphore(value:0);private var frames:[Data]=[]
 init(fd:Int32){
  Thread.detachNewThread{[self] in
   while case .message(let data)=BridgeWire.readFrame(fd,limit:BridgeWire.inputLimit){lock.lock();frames.append(data);lock.unlock();signal.signal()}
  }
 }
 func next(_ timeout:TimeInterval=4)->[String:Any]?{
  guard signal.wait(timeout:.now()+timeout) == .success else{return nil}
  lock.lock();let data=frames.removeFirst();lock.unlock()
  return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
 }
}

func browserBridgeTests()async throws{
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 func json(_ object:[String:Any])->Data{try! JSONSerialization.data(withJSONObject:object)}
 func blocking<T>(_ work:@escaping @Sendable ()->T)async->T{await withCheckedContinuation{c in Thread.detachNewThread{c.resume(returning:work())}}}

 // Framing roundtrip a odmítnutí nadměrné hlavičky.
 let pipe=Pipe();let readFD=pipe.fileHandleForReading.fileDescriptor,writeFD=pipe.fileHandleForWriting.fileDescriptor
 let payload=Data(#"{"type":"hello","text":"Příliš žluťoučký"}"#.utf8)
 let framed=BridgeWire.frame(payload)
 try check(framed.prefix(4)==Data([UInt8(payload.count),0,0,0]),"frame header is not little endian")
 try check(BridgeWire.writeAll(writeFD,framed),"pipe write failed")
 try check(BridgeWire.readFrame(readFD,limit:BridgeWire.inputLimit) == .message(payload),"framing roundtrip failed")
 try check(BridgeWire.writeAll(writeFD,Data([1,0,0,4])),"pipe write failed")
 try check(BridgeWire.readFrame(readFD,limit:BridgeWire.inputLimit) == .tooLarge(0x0400_0001),"oversized frame was not rejected")

 let directory=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("snb-\(UUID().uuidString.prefix(8))")
 defer{try? FileManager.default.removeItem(at:directory)}
 let socketPath=directory.appendingPathComponent("bridge.sock").path

 // Bridge bez appky odpoví na hello sám.
 let helper=Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(NativeHostRegistration.helperName)
 try check(FileManager.default.isExecutableFile(atPath:helper.path),"bridge helper missing at \(helper.path)")
 let process=Process();process.executableURL=helper
 process.environment=ProcessInfo.processInfo.environment.merging(["SCREENSHOT_NOTE_BRIDGE_SOCKET":socketPath]){$1}
 let stdin=Pipe(),stdout=Pipe();process.standardInput=stdin;process.standardOutput=stdout
 try process.run()
 defer{if process.isRunning{process.terminate()}}
 let input=stdin.fileHandleForWriting.fileDescriptor
 let output=FrameStream(fd:stdout.fileHandleForReading.fileDescriptor)
 _=BridgeWire.writeAll(input,BridgeWire.frame(json(["type":"hello","protocol":1,"extensionVersion":"9.9.9","browser":"SelfTest/1.0"])))
 var reply=output.next()
 try check(reply?["type"] as? String=="hello" && (reply?["app"] as? [String:Any])?["running"] as? Bool==false,"offline hello missing: \(String(describing:reply))")

 // Appka naběhne, bridge se do 2 s připojí a přepošle hello.
 let server=BrowserBridge(socketPath:socketPath)
 try server.start();defer{server.stop()}
 var info=stat()
 try check(stat(directory.path,&info)==0 && info.st_mode & 0o777==0o700,"socket directory is not 0700")
 try check(stat(socketPath,&info)==0 && info.st_mode & 0o777==0o600,"socket is not 0600")
 reply=output.next(5)
 try check(reply?["type"] as? String=="hello" && (reply?["app"] as? [String:Any])?["running"] as? Bool==true,"online hello missing: \(String(describing:reply))")
 try check(server.clients.first?.extensionVersion=="9.9.9" && server.clients.first?.browser=="SelfTest/1.0","hello was not recorded")

 // Ping a capture.request oběma směry.
 let ping=Task{await server.ping(timeout:4)}
 reply=await blocking{output.next()}
 try check(reply?["type"] as? String=="ping","ping not relayed")
 _=BridgeWire.writeAll(input,BridgeWire.frame(json(["type":"pong","id":reply?["id"] as? String ?? "","protocol":1,"enabled":true])))
 try check(await ping.value,"pong not relayed")
 let request=Task{await server.request(policy:["includeBodies":false],target:["windowTitle":"Test"],timeout:4)}
 reply=await blocking{output.next()}
 try check(reply?["type"] as? String=="capture.request" && (reply?["target"] as? [String:Any])?["windowTitle"] as? String=="Test","capture.request not relayed")
 _=BridgeWire.writeAll(input,BridgeWire.frame(json(["type":"capture.result","id":reply?["id"] as? String ?? "","bundle":["format":"screenshot-note-context","version":1]])))
 let bundle=await request.value.flatMap{(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}
 try check(bundle?["format"] as? String=="screenshot-note-context","bundle not returned")
 let refused=Task{await server.request(timeout:4)}
 reply=await blocking{output.next()}
 _=BridgeWire.writeAll(input,BridgeWire.frame(json(["type":"capture.error","id":reply?["id"] as? String ?? "","code":"disabled","message":"off"])))
 try check(await refused.value==nil,"capture.error did not end the request")

 // Zpráva nad 1 MiB do Chrome se zahodí, další projde.
 server.broadcast(json(["type":"noise","pad":String(repeating:"x",count:2<<20)]))
 let second=Task{await server.ping(timeout:4)}
 reply=await blocking{output.next()}
 try check(reply?["type"] as? String=="ping","oversized message for browser was not dropped")
 _=BridgeWire.writeAll(input,BridgeWire.frame(json(["type":"pong","id":reply?["id"] as? String ?? ""])))
 try check(await second.value,"second pong not relayed")

 // Falešný klient: neplatná a nadměrná zpráva server neshodí.
 guard let fake=BridgeWire.connect(socketPath) else{throw BrowserBridgeError(message:"fake client cannot connect")}
 defer{close(fake)}
 let fakeOutput=FrameStream(fd:fake)
 _=BridgeWire.writeAll(fake,BridgeWire.frame(Data("not json".utf8)))
 let oversized=BridgeWire.inputLimit+1
 _=await blocking{BridgeWire.writeAll(fake,BridgeWire.frame(Data(count:oversized)))}
 _=BridgeWire.writeAll(fake,BridgeWire.frame(json(["type":"hello","protocol":1,"extensionVersion":"1.0.0"])))
 reply=await blocking{fakeOutput.next()}
 try check(reply?["type"] as? String=="hello" && server.clients.count==2,"server did not survive invalid and oversized messages")

 // Chrome zavře stdin, bridge skončí.
 try stdin.fileHandleForWriting.close()
 let exited=await blocking{for _ in 0..<40{if !process.isRunning{return true};Thread.sleep(forTimeInterval:0.05)};return false}
 try check(exited && process.terminationStatus==0,"bridge did not exit after stdin closed")
 server.stop()
 try check(!FileManager.default.fileExists(atPath:socketPath),"socket not removed on stop")

 // Registrace hostu jen do existujících prohlížečů.
 let home=directory.appendingPathComponent("home")
 for browser in ["Google/Chrome","Arc/User Data"]{try FileManager.default.createDirectory(at:home.appendingPathComponent("Library/Application Support/"+browser),withIntermediateDirectories:true)}
 let installed=try NativeHostRegistration.install(home:home,helper:URL(fileURLWithPath:"/Applications/Old.app/Contents/MacOS/screenshot-note-bridge"))
 try check(installed.count==2,"manifest written to \(installed.count) browsers")
 let moved=URL(fileURLWithPath:"/Applications/Screenshot Note.app/Contents/MacOS/screenshot-note-bridge")
 try NativeHostRegistration.install(home:home,helper:moved)
 let written=(try JSONSerialization.jsonObject(with:Data(contentsOf:installed[0]))) as? [String:Any]
 try check(written?["path"] as? String==moved.path && written?["type"] as? String=="stdio","manifest path not refreshed")
 try check(written?["allowed_origins"] as? [String]==NativeHostRegistration.allowedOrigins,"allowed_origins mismatch")
 let foreign=installed[1];let devHost=Data(#"{"path":"/dev/run-host.sh"}"#.utf8);try devHost.write(to:foreign)
 try NativeHostRegistration.install(home:home,helper:moved,replaceForeign:false)
 try check((try? Data(contentsOf:foreign))==devHost,"startup refresh replaced the development host")
 try check(NativeHostRegistration.uninstall(home:home).count==1,"uninstall removed wrong files")
 try check(!FileManager.default.fileExists(atPath:installed[0].path) && FileManager.default.fileExists(atPath:foreign.path),"uninstall touched the development host")
 print("Browser bridge self-test passed")
}
