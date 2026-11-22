import AppKit
import AVFoundation
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Limity videa podle rozhodnutí v issue #32 (web #85 je ověřuje znovu).
enum RecordingLimits {
 static let fps:Int32=10
 static let maxSide=1280
 static let bitrate=1_200_000
 static let maxDuration:TimeInterval=60
 static let maxFrames=12
 static let countdowns=[3,5,10]
}

/// Odpočet před záznamem; výchozí 3 s, jiné hodnoty než 3/5/10 se ignorují.
var recordingCountdown:Int {
 get{let value=UserDefaults.standard.integer(forKey:"recordingCountdown");return RecordingLimits.countdowns.contains(value) ? value:3}
 set{UserDefaults.standard.set(RecordingLimits.countdowns.contains(newValue) ? newValue:3,forKey:"recordingCountdown")}
}

/// Výstupní rozměr v pixelech: delší strana nejvýš 1280, sudé hodnoty pro H.264.
func recordingSize(width:Double,height:Double,maxSide:Int=RecordingLimits.maxSide)->(width:Int,height:Int) {
 let scale=min(1,Double(maxSide)/max(width,height,1))
 func even(_ value:Double)->Int{max(2,Int(value*scale/2)*2)}
 return (even(width),even(height))
}

/// Délka videa v Markdownu: m:ss zaokrouhleno na sekundy (web videoDuration).
func videoDuration(_ ms:Int)->String {
 let seconds=Int((Double(ms)/1000).rounded())
 return "\(seconds/60):"+String(format:"%02d",seconds%60)
}

/// Otisk scény: 32×18 jasů z BGRA bufferu, stačí na detekci změny obrazovky.
func sceneSignature(bgra base:UnsafeRawPointer,width:Int,height:Int,bytesPerRow:Int,columns:Int=32,rows:Int=18)->[UInt8] {
 var values=[UInt8](repeating:0,count:columns*rows)
 guard width>0,height>0 else{return values}
 for row in 0..<rows {
  let y=min(height-1,(row*height+height/2)/rows)
  for column in 0..<columns {
   let x=min(width-1,(column*width+width/2)/columns)
   let pixel=base.advanced(by:y*bytesPerRow+x*4).assumingMemoryBound(to:UInt8.self)
   values[row*columns+column]=UInt8((Int(pixel[2])*77+Int(pixel[1])*150+Int(pixel[0])*29)>>8)
  }
 }
 return values
}
/// Průměrný rozdíl jasu 0…1.
func sceneDifference(_ a:[UInt8],_ b:[UInt8])->Double {
 guard a.count==b.count,!a.isEmpty else{return 1}
 return Double(zip(a,b).reduce(0){$0+abs(Int($1.0)-Int($1.1))})/Double(a.count*255)
}

/// Klíčové snímky podle změny scény: první vždy, další po změně nad prahem a nejdřív po `minGap` ms.
/// Nad limit vypadne snímek s nejmenší změnou (kromě prvního).
struct KeyFrameSelector<Frame> {
 var limit=RecordingLimits.maxFrames,threshold=0.04,minGap=500
 private(set) var frames:[(ms:Int,score:Double,frame:Frame)]=[]
 private var last:[UInt8]?;private var lastMs = -1_000_000
 init(limit:Int=RecordingLimits.maxFrames,threshold:Double=0.04,minGap:Int=500){self.limit=limit;self.threshold=threshold;self.minGap=minGap}
 @discardableResult mutating func offer(ms:Int,signature:[UInt8],make:()->Frame?)->Bool {
  let score=last.map{sceneDifference($0,signature)} ?? .infinity
  guard score.isInfinite || (score>=threshold && ms-lastMs>=minGap),let frame=make() else{return false}
  frames.append((ms,score,frame));last=signature;lastMs=ms
  if frames.count>limit,let weakest=frames.indices.dropFirst().min(by:{frames[$0].score<frames[$1].score}){frames.remove(at:weakest)}
  return true
 }
}

/// Výsledek záznamu v pracovní složce: MP4, poster (první snímek) a klíčové snímky s časem.
struct RecordingResult {var video:URL;var durationMs:Int;var width:Int;var height:Int;var poster:CGImage;var frames:[(ms:Int,image:CGImage)]}

/// Záznam obrazovky, okna nebo oblasti do MP4 (H.264, 10 fps, ~1,2 Mbit/s).
final class ScreenRecorder:NSObject,SCStreamOutput,SCStreamDelegate,@unchecked Sendable {
 private let queue=DispatchQueue(label:"cz.janprasil.screenshotnote.recording")
 private let writer:AVAssetWriter;private let input:AVAssetWriterInput
 private var stream:SCStream?;private var start:CMTime?;private var selector=KeyFrameSelector<CGImage>()
 private var failure:Error?;private var stopped=false
 private static let images=CIContext(options:[.cacheIntermediates:false])
 let output:URL;let width:Int;let height:Int
 /// Volá se na hlavním vlákně při chybě streamu.
 var onFailure:((Error)->Void)?

 init(output:URL,width:Int,height:Int)throws {
  self.output=output;self.width=width;self.height=height
  try? FileManager.default.removeItem(at:output)
  writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
  input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
   AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:RecordingLimits.bitrate,AVVideoExpectedSourceFrameRateKey:RecordingLimits.fps,
    AVVideoMaxKeyFrameIntervalKey:Int(RecordingLimits.fps)*2,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]])
  input.expectsMediaDataInRealTime=true
  writer.shouldOptimizeForNetworkUse=true
  guard writer.canAdd(input) else{throw NSError(domain:"ScreenshotNote",code:40,userInfo:[NSLocalizedDescriptionKey:L("Záznam videa se nepodařilo připravit.")])}
  writer.add(input)
 }

 func begin(filter:SCContentFilter,sourceRect:CGRect?)async throws {
  let configuration=SCStreamConfiguration()
  configuration.width=width;configuration.height=height
  configuration.minimumFrameInterval=CMTime(value:1,timescale:RecordingLimits.fps)
  configuration.pixelFormat=kCVPixelFormatType_32BGRA;configuration.showsCursor=true;configuration.queueDepth=5
  if let sourceRect{configuration.sourceRect=sourceRect}
  let stream=SCStream(filter:filter,configuration:configuration,delegate:self)
  try stream.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
  self.stream=stream
  try await stream.startCapture()
 }

 func stream(_ stream:SCStream,didOutputSampleBuffer buffer:CMSampleBuffer,of type:SCStreamOutputType) {
  guard type == .screen,!stopped,buffer.isValid,let pixels=buffer.imageBuffer,
   let info=(CMSampleBufferGetSampleAttachmentsArray(buffer,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]])?.first,
   let raw=info[.status] as? Int,SCFrameStatus(rawValue:raw) == .complete else{return}
  let time=buffer.presentationTimeStamp
  if start == nil {
   guard writer.startWriting() else{failure=writer.error;return}
   writer.startSession(atSourceTime:time);start=time
  }
  guard let start else{return}
  let ms=Int(((time-start).seconds*1000).rounded())
  guard ms<=Int(RecordingLimits.maxDuration*1000) else{return}
  if input.isReadyForMoreMediaData,!input.append(buffer){failure=writer.error}
  CVPixelBufferLockBaseAddress(pixels,.readOnly);defer{CVPixelBufferUnlockBaseAddress(pixels,.readOnly)}
  guard let base=CVPixelBufferGetBaseAddress(pixels) else{return}
  let signature=sceneSignature(bgra:base,width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),bytesPerRow:CVPixelBufferGetBytesPerRow(pixels))
  selector.offer(ms:ms,signature:signature){
   let image=CIImage(cvPixelBuffer:pixels)
   return Self.images.createCGImage(image,from:image.extent)
  }
 }
 func stream(_ stream:SCStream,didStopWithError error:Error) {
  queue.async{self.failure=error}
  DispatchQueue.main.async{self.onFailure?(error)}
 }

 /// Ukončí záznam; délka je čas od prvního snímku do zastavení (nejvýš 60 s).
 func finish()async throws->RecordingResult {
  try? await stream?.stopCapture()
  let (start,failure,frames)=queue.sync{stopped=true;return (self.start,self.failure,selector.frames)}
  guard let start,let first=frames.first,writer.status == .writing else{
   writer.cancelWriting();try? FileManager.default.removeItem(at:output)
   throw failure ?? NSError(domain:"ScreenshotNote",code:41,userInfo:[NSLocalizedDescriptionKey:L("Záznam neobsahuje žádný snímek.")])
  }
  let now=CMClockGetTime(CMClockGetHostTimeClock())
  let end=CMTimeMinimum(now,start+CMTime(seconds:RecordingLimits.maxDuration,preferredTimescale:600))
  input.markAsFinished();writer.endSession(atSourceTime:CMTimeMaximum(end,start+CMTime(value:1,timescale:RecordingLimits.fps)))
  await writer.finishWriting()
  guard writer.status == .completed else{try? FileManager.default.removeItem(at:output);throw writer.error ?? failure ?? NSError(domain:"ScreenshotNote",code:42)}
  let duration=Int(((CMTimeMaximum(end,start+CMTime(value:1,timescale:RecordingLimits.fps))-start).seconds*1000).rounded())
  return RecordingResult(video:output,durationMs:duration,width:width,height:height,poster:first.frame,frames:frames.map{($0.ms,$0.frame)})
 }
 func cancel() {
  Task{try? await stream?.stopCapture();queue.sync{stopped=true};writer.cancelWriting();try? FileManager.default.removeItem(at:output)}
 }
}

/// Metadata videa v pracovní složce i v assets/ (`<obrázek>.frames/video.json`).
struct VideoInfo:Codable,Equatable {
 struct Frame:Codable,Equatable{var file:String;var ms:Int}
 var durationMs:Int;var width:Int;var height:Int;var frames:[Frame]
}
/// Video položky leží vedle posteru: `<poster>.mp4` a složka `<poster>.frames/` s PNG snímky a video.json.
func videoSidecars(_ image:URL)->[URL]{[image.appendingPathExtension("mp4"),image.appendingPathExtension("frames")]}
/// Stejné soubory v assets/: `<název>.mp4` a `<název>.frames/` vedle `<název>.png`.
func assetVideoFiles(_ assets:URL,_ image:String)->[URL]{let base=(image as NSString).deletingPathExtension;return [assets.appendingPathComponent(base+".mp4"),assets.appendingPathComponent(base+".frames",isDirectory:true)]}
/// Metadata videa z adresáře snímků; neplatná data = nil (položka pak zůstane obrázkem).
func readVideoInfo(_ frames:URL)->VideoInfo? {
 guard let data=try? boundedData(frames.appendingPathComponent("video.json"),max:64*1024),let info=try? JSONDecoder().decode(VideoInfo.self,from:data),
  (1...Int(RecordingLimits.maxDuration*1000+500)).contains(info.durationMs),info.frames.count<=RecordingLimits.maxFrames,
  info.frames.allSatisfy({$0.file.range(of:"^([1-9]|1[0-2])\\.png$",options:.regularExpression) != nil && (0...60500).contains($0.ms)}) else{return nil}
 return info
}
/// Uloží výsledek záznamu vedle posteru v pracovní složce.
func storeRecording(_ result:RecordingResult,poster:URL)throws {
 try writePNG(result.poster,to:poster)
 let sides=videoSidecars(poster)
 try? fm.removeItem(at:sides[0]);try fm.moveItem(at:result.video,to:sides[0])
 try? fm.removeItem(at:sides[1]);try fm.createDirectory(at:sides[1],withIntermediateDirectories:true)
 var frames:[VideoInfo.Frame]=[]
 for (offset,frame) in result.frames.enumerated(){let name="\(offset+1).png";try writePNG(frame.image,to:sides[1].appendingPathComponent(name));frames.append(.init(file:name,ms:frame.ms))}
 try JSONEncoder().encode(VideoInfo(durationMs:result.durationMs,width:result.width,height:result.height,frames:frames)).write(to:sides[1].appendingPathComponent("video.json"),options:.atomic)
}
func writePNG(_ image:CGImage,to url:URL)throws {
 guard let target=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else{throw NSError(domain:"ScreenshotNote",code:43)}
 CGImageDestinationAddImage(target,image,nil)
 guard CGImageDestinationFinalize(target) else{throw NSError(domain:"ScreenshotNote",code:43)}
}

/// Metadata videa ze serveru: délka a rozměry videa, snímky stažené a seřazené podle času (soubor `N.png` podle frame-N).
func remoteVideoInfo(_ attachments:[RemoteNote.Image.Attachment],downloaded:Set<String>)->VideoInfo? {
 guard let video=attachments.first(where:{$0.kind=="video"})?.media,let duration=video.duration_ms,let width=video.width,let height=video.height,
  (1...Int(RecordingLimits.maxDuration*1000+500)).contains(duration) else{return nil}
 let frames=attachments.compactMap{item->VideoInfo.Frame? in
  guard downloaded.contains(item.kind),let number=item.kind.range(of:"^frame-([1-9]|1[0-2])$",options:.regularExpression).map({_ in item.kind.dropFirst(6)}),
   let ms=item.media?.timestamp_ms,(0...60500).contains(ms) else{return nil}
  return .init(file:"\(number).png",ms:ms)
 }.sorted{$0.ms<$1.ms}
 return VideoInfo(durationMs:duration,width:width,height:height,frames:frames)
}
