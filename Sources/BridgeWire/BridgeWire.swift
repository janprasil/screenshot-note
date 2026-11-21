import Foundation

// Sdílený framing pro bridge helper i appku: 4 B délka v little endian + JSON.
public enum BridgeFrame:Equatable{case message(Data),tooLarge(Int),end}

public enum BridgeWire {
 public static let protocolVersion=1
 public static let inputLimit=64<<20
 public static let browserOutputLimit=1<<20
 public static var defaultSocketPath:String{
  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Screenshot Note/bridge.sock").path
 }
 public static func frame(_ payload:Data)->Data{
  var length=UInt32(payload.count).littleEndian
  var data=Data(bytes:&length,count:4);data.append(payload);return data
 }
 public static func readExact(_ fd:Int32,_ count:Int)->Data?{
  if count==0{return Data()}
  var data=Data(count:count);var offset=0
  while offset<count{
   let n=data.withUnsafeMutableBytes{read(fd,$0.baseAddress!+offset,count-offset)}
   if n>0{offset+=n}else if n<0 && errno==EINTR{continue}else{return nil}
  }
  return data
 }
 public static func readFrame(_ fd:Int32,limit:Int)->BridgeFrame{
  guard let header=readExact(fd,4) else{return .end}
  let length=Int(header.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self))})
  if length>limit{return .tooLarge(length)}
  guard let payload=readExact(fd,length) else{return .end}
  return .message(payload)
 }
 // Přeskočí tělo nadměrné zprávy, aby proud zůstal čitelný.
 public static func skip(_ fd:Int32,_ count:Int)->Bool{
  var remaining=count;var buffer=[UInt8](repeating:0,count:64<<10)
  while remaining>0{
   let n=buffer.withUnsafeMutableBytes{read(fd,$0.baseAddress!,min(remaining,$0.count))}
   if n>0{remaining-=n}else if n<0 && errno==EINTR{continue}else{return false}
  }
  return true
 }
 public static func writeAll(_ fd:Int32,_ data:Data)->Bool{
  data.withUnsafeBytes{raw in
   var offset=0
   while offset<raw.count{
    let n=write(fd,raw.baseAddress!+offset,raw.count-offset)
    if n>0{offset+=n}else if n<0 && errno==EINTR{continue}else{return false}
   }
   return true
  }
 }
 public static func messageType(_ data:Data)->String?{
  ((try? JSONSerialization.jsonObject(with:data)) as? [String:Any])?["type"] as? String
 }
 public static func withAddress<T>(_ path:String,_ body:(UnsafePointer<sockaddr>,socklen_t)->T)->T?{
  var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
  let bytes=Array(path.utf8)
  guard bytes.count<MemoryLayout.size(ofValue:address.sun_path) else{return nil}
  withUnsafeMutableBytes(of:&address.sun_path){$0.copyBytes(from:bytes)}
  address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
  return withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){body($0,socklen_t(MemoryLayout<sockaddr_un>.size))}}
 }
 public static func noSigPipe(_ fd:Int32){var on:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&on,socklen_t(MemoryLayout<Int32>.size))}
 // Protistrana, která nečte, zápis neblokuje navždy.
 public static func sendTimeout(_ fd:Int32,seconds:Int=2){var limit=timeval(tv_sec:seconds,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&limit,socklen_t(MemoryLayout<timeval>.size))}
 public static func connect(_ path:String)->Int32?{
  let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else{return nil}
  noSigPipe(fd);sendTimeout(fd)
  guard withAddress(path,{Darwin.connect(fd,$0,$1)})==0 else{close(fd);return nil}
  return fd
 }
}
