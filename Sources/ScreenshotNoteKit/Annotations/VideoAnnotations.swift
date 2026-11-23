import AppKit
import AVFoundation
import AVKit

/// Původní záznam a klíčové snímky bez anotací (`video.mp4`, `N.png`) pro další úpravy.
/// Leží ve složce snímků, takže je kopie a odebrání položky berou s sebou; export do assets/ je vynechá.
func videoOriginals(_ poster:URL)->URL{videoSidecars(poster)[1].appendingPathComponent("original",isDirectory:true)}

/// Připraví video a klíčové snímky s anotacemi do dočasné složky vedle položky; položku nemění.
/// Bez anotací vrátí nil (commit pak vrátí původní záznam). Pomalé, volá se mimo hlavní vlákno.
func prepareVideoAnnotations(poster:URL,overlay:CGImage?)throws->URL? {
 guard let overlay else{return nil}
 let sides=videoSidecars(poster),originals=videoOriginals(poster),clean=fm.fileExists(atPath:originals.path)
 let staging=poster.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).video-annotations",isDirectory:true)
 try fm.createDirectory(at:staging,withIntermediateDirectories:false)
 do {
  let source=clean ? originals.appendingPathComponent("video.mp4"):sides[0],output=staging.appendingPathComponent("video.mp4")
  try burnVideoOverlay(overlay,source:source,to:output)
  // Překreslený obraz může mít víc dat; nad limitem cloudu se kóduje znovu s nižším bitrate.
  if let size=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize,size>CloudAttachment.videoLimit {
   try burnVideoOverlay(overlay,source:source,to:output,bitrate:Int(Double(RecordingLimits.bitrate)*Double(CloudAttachment.videoLimit)*0.85/Double(size)))
  }
  for frame in readVideoInfo(sides[1])?.frames ?? [] {
   let file=(clean ? originals:sides[1]).appendingPathComponent(frame.file)
   guard let data=try? Data(contentsOf:file),let image=NSBitmapImageRep(data:data)?.cgImage,
    let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{continue}
   let rect=CGRect(x:0,y:0,width:image.width,height:image.height);context.draw(image,in:rect);context.draw(overlay,in:rect)
   guard let burned=context.makeImage() else{continue}
   try writePNG(burned,to:staging.appendingPathComponent(frame.file))
  }
 } catch {try? fm.removeItem(at:staging);throw error}
 return staging
}

/// Prohodí připravené soubory s položkou; původní záznam a snímky se nejdřív odloží. nil vrátí původní záznam.
func commitVideoAnnotations(poster:URL,prepared:URL?)throws {
 let sides=videoSidecars(poster),originals=videoOriginals(poster)
 func swap(_ source:URL,_ target:URL)throws{if fm.fileExists(atPath:target.path){_ = try fm.replaceItemAt(target,withItemAt:source)}else{try fm.moveItem(at:source,to:target)}}
 guard let prepared else {
  guard fm.fileExists(atPath:originals.path) else{return}
  for name in try fm.contentsOfDirectory(atPath:originals.path){try swap(originals.appendingPathComponent(name),name == "video.mp4" ? sides[0]:sides[1].appendingPathComponent(name))}
  try fm.removeItem(at:originals);return
 }
 defer{try? fm.removeItem(at:prepared)}
 let files=try fm.contentsOfDirectory(atPath:prepared.path)
 if !fm.fileExists(atPath:originals.path) {
  let staging=sides[1].appendingPathComponent(".original-\(UUID().uuidString)",isDirectory:true)
  do {
   try fm.createDirectory(at:staging,withIntermediateDirectories:false)
   for name in files{let source=name == "video.mp4" ? sides[0]:sides[1].appendingPathComponent(name);if fm.fileExists(atPath:source.path){try fm.copyItem(at:source,to:staging.appendingPathComponent(name))}}
   try fm.moveItem(at:staging,to:originals)
  } catch {try? fm.removeItem(at:staging);throw error}
 }
 for name in files{try swap(prepared.appendingPathComponent(name),name == "video.mp4" ? sides[0]:sides[1].appendingPathComponent(name))}
}

/// Překreslí každý snímek s průhledným obrázkem anotací přes celý obraz; kódování stejné jako při záznamu.
func burnVideoOverlay(_ overlay:CGImage,source:URL,to output:URL,bitrate:Int=RecordingLimits.bitrate)throws {
 func failure(_ error:Error?=nil)->Error{error ?? NSError(domain:"ScreenshotNote",code:46,userInfo:[NSLocalizedDescriptionKey:L("Anotace se do videa nepodařilo vložit.")])}
 let asset=AVURLAsset(url:source)
 guard let track=asset.tracks(withMediaType:.video).first else{throw failure()}
 let reader=try AVAssetReader(asset:asset)
 let frames=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
 // Do dekódovaného snímku se kreslí; vlastní kopie nesahá na sdílené buffery.
 frames.alwaysCopiesSampleData=true
 guard reader.canAdd(frames) else{throw failure()};reader.add(frames)
 let width=Int(track.naturalSize.width),height=Int(track.naturalSize.height)
 try? fm.removeItem(at:output)
 let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
 let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height,
  AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoExpectedSourceFrameRateKey:RecordingLimits.fps,
   AVVideoMaxKeyFrameIntervalKey:Int(RecordingLimits.fps)*2,AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel]])
 input.expectsMediaDataInRealTime=false;input.transform=track.preferredTransform
 let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:nil)
 guard writer.canAdd(input) else{throw failure()};writer.add(input);writer.shouldOptimizeForNetworkUse=true
 guard reader.startReading() else{throw failure(reader.error)}
 guard writer.startWriting() else{reader.cancelReading();throw failure(writer.error)}
 var started=false
 do {
  while let sample=frames.copyNextSampleBuffer() {try autoreleasepool {
   guard let pixels=CMSampleBufferGetImageBuffer(sample) else{return}
   let time=sample.presentationTimeStamp
   if !started{writer.startSession(atSourceTime:time);started=true}
   CVPixelBufferLockBaseAddress(pixels,[])
   let context=CGContext(data:CVPixelBufferGetBaseAddress(pixels),width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels),bitsPerComponent:8,
    bytesPerRow:CVPixelBufferGetBytesPerRow(pixels),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)
   context?.draw(overlay,in:CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels)))
   CVPixelBufferUnlockBaseAddress(pixels,[])
   guard context != nil else{throw failure()}
   // Zápis mimo reálný čas: čeká se, až kodér převezme další snímek.
   while !input.isReadyForMoreMediaData{guard writer.status == .writing else{throw failure(writer.error)};usleep(2000)}
   guard adaptor.append(pixels,withPresentationTime:time) else{throw failure(writer.error)}
  }}
  guard reader.status == .completed,started else{throw failure(reader.error)}
 } catch {reader.cancelReading();writer.cancelWriting();try? fm.removeItem(at:output);throw error}
 input.markAsFinished();writer.endSession(atSourceTime:CMTimeRangeGetEnd(track.timeRange))
 let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()};done.wait()
 guard writer.status == .completed else{try? fm.removeItem(at:output);throw failure(writer.error)}
}

/// Přehrávač pod plátnem anotací: obraz videa, tlačítko přehrát/pozastavit a časová osa.
final class VideoAnnotationPlayer:NSObject {
 let player:AVPlayer;let view=AVPlayerView();let playButton=AppButton();let timeline=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil)
 private let durationMs:Int;private var timeObserver:Any?;private var endObserver:NSObjectProtocol?
 init(source:URL,durationMs:Int) {
  player=AVPlayer(url:source);self.durationMs=max(1,durationMs);player.actionAtItemEnd = .pause
  super.init()
  view.controlsStyle = .none;view.videoGravity = .resizeAspect;view.player=player;view.setAccessibilityLabel(L("Video"))
  playButton.role = .quiet;playButton.imagePosition = .imageOnly;updateButton();playButton.target=self;playButton.action=#selector(toggle);playButton.toolTip=L("Přehrát nebo pozastavit video");playButton.setAccessibilityLabel(playButton.toolTip)
  timeline.target=self;timeline.action=#selector(seek(_:));timeline.isContinuous=true;timeline.toolTip=L("Posun ve videu");timeline.setAccessibilityLabel(timeline.toolTip)
  timeObserver=player.addPeriodicTimeObserver(forInterval:CMTime(value:1,timescale:10),queue:.main){[weak self] time in self?.update(time)}
  endObserver=NotificationCenter.default.addObserver(forName:.AVPlayerItemDidPlayToEndTime,object:player.currentItem,queue:.main){[weak self] _ in self?.player.seek(to:.zero);self?.updateButton()}
 }
 var playing:Bool{player.rate != 0}
 @objc func toggle(){if playing{player.pause()}else{player.play()};updateButton()}
 @objc func seek(_ sender:NSSlider){player.pause();updateButton();player.seek(to:CMTime(value:CMTimeValue(sender.doubleValue*Double(durationMs)),timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)}
 private func update(_ time:CMTime){guard time.isNumeric else{return};timeline.doubleValue=min(1,max(0,time.seconds*1000/Double(durationMs)))}
 private func updateButton(){playButton.image=NSImage(systemSymbolName:playing ? "pause.fill":"play.fill",accessibilityDescription:nil)}
 /// Zastaví přehrávání a uvolní pozorovatele; volá se při zavření editoru.
 func stop() {
  player.pause()
  if let timeObserver{player.removeTimeObserver(timeObserver)};timeObserver=nil
  if let endObserver{NotificationCenter.default.removeObserver(endObserver)};endObserver=nil
 }
}
