import AppKit
import AVFoundation
@testable import ScreenshotNoteKit

// Video ze záznamu obrazovky; parita Markdownu s webem (tests/video.test.mjs, videoParity).
@MainActor func videoRecordingTests() throws {
 // Rozměr: delší strana nejvýš 1920, sudé hodnoty.
 assert(recordingSize(width:2880,height:1800)==(1920,1200))
 assert(recordingSize(width:1000,height:501)==(1000,500))
 assert(recordingSize(width:1,height:1)==(2,2))
 assert(recordingSize(width:1800,height:2880)==(1200,1920))
 // Délka m:ss jako web videoDuration.
 assert([500,59499,59500,60500,0].map(videoDuration)==["0:01","0:59","1:00","1:01","0:00"])
 assert(RecordingLimits.fps==20 && RecordingLimits.maxSide==1920 && RecordingLimits.bitrate==1_750_000 && RecordingLimits.maxDuration==60 && RecordingLimits.maxFrames==12)
 // 60 s při cílovém bitrate i stropu se vejde do 16 MiB limitu cloudu.
 assert(Double(RecordingLimits.bitrate)*RecordingLimits.maxDuration/8<Double(CloudAttachment.videoLimit)*0.8)
 assert(Double(RecordingLimits.peakBytesPerSecond)*RecordingLimits.maxDuration<Double(CloudAttachment.videoLimit)*0.9)
 // Odpočet: výchozí 3 s, jen 3/5/10.
 let savedCountdown=UserDefaults.standard.object(forKey:"recordingCountdown")
 UserDefaults.standard.removeObject(forKey:"recordingCountdown");assert(recordingCountdown==3)
 recordingCountdown=10;assert(recordingCountdown==10);recordingCountdown=7;assert(recordingCountdown==3)
 if let savedCountdown{UserDefaults.standard.set(savedCountdown,forKey:"recordingCountdown")}else{UserDefaults.standard.removeObject(forKey:"recordingCountdown")}
 // Oblast v souřadnicích displeje (počátek vlevo nahoře).
 assert(displaySourceRect(CGRect(x:100,y:200,width:300,height:400),screen:CGRect(x:0,y:0,width:1440,height:900))==CGRect(x:100,y:300,width:300,height:400))
 assert(displaySourceRect(CGRect(x:1540,y:100,width:200,height:100),screen:CGRect(x:1440,y:0,width:1920,height:1080))==CGRect(x:100,y:880,width:200,height:100))
 // Nastavení enkodéru (strop datového toku) AVAssetWriter přijme.
 let probe=fm.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString).mp4");defer{try? fm.removeItem(at:probe)}
 _ = try ScreenRecorder(output:probe,width:1920,height:1200)
 print("PASS: recording size, duration format, limits, countdown setting and region coordinates")
 
 // Esc: jen během výběru, odpočtu a záznamu; zapnutí je idempotentní a vypnutí uvolní zkratku.
 assert([RecordingController.State.idle,.preparing,.counting,.recording,.finishing].map(\.stopsOnEscape)==[false,true,true,true,false])
 let escape=Hotkeys();var escaped:[Int]=[];escape.callback={escaped.append($0)}
 assert(!escape.escapeActive)
 assert(escape.setEscape(true) && escape.escapeActive && escape.setEscape(true) && escape.escapeActive)
 assert(escape.setEscape(false) && !escape.escapeActive && escape.setEscape(false))
 // Po uvolnění jde Esc zaregistrovat znovu.
 let other=Hotkeys();assert(other.setEscape(true));other.setEscape(false)
 assert(escape.trigger(Hotkeys.escapeID,at:20) && escaped==[Hotkeys.escapeID])
 print("PASS: temporary Esc hotkey follows the recording state and is released on stop")

 // Otisk scény a rozdíl.
 var pixels=[UInt8](repeating:0,count:64*36*4)
 let dark=pixels.withUnsafeBytes{sceneSignature(bgra:$0.baseAddress!,width:64,height:36,bytesPerRow:256)}
 for i in stride(from:0,to:pixels.count,by:4){pixels[i]=255;pixels[i+1]=255;pixels[i+2]=255}
 let light=pixels.withUnsafeBytes{sceneSignature(bgra:$0.baseAddress!,width:64,height:36,bytesPerRow:256)}
 assert(dark.count==32*18 && sceneDifference(dark,dark)==0 && sceneDifference(dark,light)>0.99)
 // Klíčové snímky: první vždy, malá změna ne, rozestup aspoň 500 ms, nad limit vypadne nejmenší změna.
 func signature(_ value:UInt8)->[UInt8]{[UInt8](repeating:value,count:32*18)}
 var selector=KeyFrameSelector<Int>(limit:3,threshold:0.04,minGap:500)
 assert(selector.offer(ms:0,signature:signature(0)){0})
 assert(!selector.offer(ms:600,signature:signature(5)){1})
 assert(!selector.offer(ms:200,signature:signature(200)){2})
 assert(selector.offer(ms:700,signature:signature(200)){3})
 assert(selector.offer(ms:1300,signature:signature(150)){4})
 assert(selector.offer(ms:2000,signature:signature(0)){5})
 assert(selector.frames.map(\.frame)==[0,3,5],"\(selector.frames.map(\.frame))")
 assert(selector.frames.first?.ms==0)
 print("PASS: scene signature, key frame threshold, spacing and 12-frame budget keeping the first frame")

 // Markdown: stejný řetězec jako web (videoParity).
 let videoParity="[![Video 0:30](<assets/S-1.png>)](<assets/S-1.mp4>)\n\nPopis 1\n\n![Screenshot 2](<assets/S-2.png>)\n\nPopis 2"
 let blocks=[ImageBlock(name:"S-1.png",caption:"Popis 1",videoMs:30400),ImageBlock(name:"S-2.png",caption:"Popis 2")]
 assert(renderImageBlocks(blocks,template:nil)==videoParity,renderImageBlocks(blocks,template:nil))
 assert(renderImageBlocks(blocks,template:"{number}: {image}")=="1: [![Video 0:30](<assets/S-1.png>)](<assets/S-1.mp4>)\n\n2: ![Screenshot 2](<assets/S-2.png>)")
 // Odkaz na video je jedna položka s názvem posteru; přejmenování video zachová.
 let text="# T\n\n"+videoParity
 assert(imageLinkNames(text)==["S-1.png","S-2.png"])
 assert(rewriteImageLinks(text,order:["S-1.png","S-2.png"],rename:["S-1.png":"X 1.png"]).contains("[![Video 0:30](<assets/X 1.png>)](<assets/X 1.mp4>)"))
 // Cloudová relace se staženým videem se vykreslí stejně jako webový export.
 let info=VideoInfo(durationMs:30400,width:1280,height:720,frames:[.init(file:"1.png",ms:0)])
 let note=RemoteNote(id:UUID(),title:"Rec",comment:"",template:"{screenshots}",captions:["Popis 1","Popis 2"],images:[.init(index:1,path:"/1"),.init(index:2,path:"/2")])
 let infoJSON=try JSONEncoder().encode(info)
 assert(cloudSessionBody(note,images:["S-1.png","S-2.png"],contexts:[1:["video":Data([1]),"video.json":infoJSON]])==videoParity+"\n")
 print("PASS: video Markdown links the poster to the MP4 like the web export; link parsing and renaming keep the video")

 // Soubory: záznam vedle posteru, čtení metadat, assets a stažení z cloudu.
 let root=fm.temporaryDirectory.appendingPathComponent("video-tests-\(UUID().uuidString)",isDirectory:true)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let image=CGContext(data:nil,width:8,height:6,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
 let movie=root.appendingPathComponent("raw.mp4");try Data([0,0,0,8]).write(to:movie)
 let poster=root.appendingPathComponent("A.png")
 try storeRecording(RecordingResult(video:movie,durationMs:4200,width:8,height:6,poster:image,frames:[(0,image),(2100,image)],startedAt:Date(timeIntervalSince1970:1_800_000_000.25)),poster:poster)
 let sides=videoSidecars(poster)
 assert(fm.fileExists(atPath:poster.path) && fm.fileExists(atPath:sides[0].path) && !fm.fileExists(atPath:movie.path))
 assert(readVideoInfo(sides[1])==VideoInfo(durationMs:4200,width:8,height:6,frames:[.init(file:"1.png",ms:0),.init(file:"2.png",ms:2100)],startedAtMs:1_800_000_000_250))
 // Starší video.json bez začátku záznamu se načte.
 let legacyInfo=try JSONDecoder().decode(VideoInfo.self,from:Data("{\"durationMs\":1,\"width\":1,\"height\":1,\"frames\":[]}".utf8))
 assert(legacyInfo.startedAtMs==nil)
 assert(fm.fileExists(atPath:sides[1].appendingPathComponent("2.png").path))
 // Kopie a odebrání položky berou video s sebou.
 let copy=root.appendingPathComponent("B.png");try fm.copyItem(at:poster,to:copy);try copyAnnotationSidecar(from:poster,to:copy)
 assert(videoSidecars(copy).allSatisfy{fm.fileExists(atPath:$0.path)})
 removeAnnotatedImage(copy);assert(!videoSidecars(copy).contains{fm.fileExists(atPath:$0.path)})
 // Neplatná metadata: položka zůstane obrázkem.
 try Data("{\"durationMs\":99999,\"width\":1,\"height\":1,\"frames\":[]}".utf8).write(to:sides[1].appendingPathComponent("video.json"))
 assert(readVideoInfo(sides[1])==nil)
 // Assets/: render podle souborů vedle posteru.
 let assets=root.appendingPathComponent("assets",isDirectory:true);try fm.createDirectory(at:assets,withIntermediateDirectories:true)
 let files=assetVideoFiles(assets,"S-1.png");assert(files.map(\.lastPathComponent)==["S-1.mp4","S-1.frames"])
 try Data([1]).write(to:files[0]);try fm.createDirectory(at:files[1],withIntermediateDirectories:true);try infoJSON.write(to:files[1].appendingPathComponent("video.json"))
 assert(screenshotsWithContext(["S-1.png","S-2.png"],["Popis 1","Popis 2"],assets:assets).screenshots==videoParity)
 // Stažení z cloudu: MP4, snímky podle času, video.json a hash pro index; bez videa se smaže.
 let mp4=Data([0,0,0,24]),frame=Data([137,80,78,71])
 let attachments:[RemoteNote.Image.Attachment]=[.init(kind:"frame-2",bytes:4,sha256:"",path:"",media:.init(timestamp_ms:900)),.init(kind:"video",bytes:4,sha256:"",path:"",media:.init(duration_ms:5000,width:640,height:360,started_at_ms:1_800_000_000_000)),
  .init(kind:"frame-1",bytes:4,sha256:"",path:"",media:.init(timestamp_ms:0)),.init(kind:"frame-3",bytes:4,sha256:"",path:"",media:.init(timestamp_ms:50))]
 let remote=remoteVideoInfo(attachments,downloaded:["video","frame-1","frame-2"])!
 assert(remote==VideoInfo(durationMs:5000,width:640,height:360,frames:[.init(file:"1.png",ms:0),.init(file:"2.png",ms:900)],startedAtMs:1_800_000_000_000))
 assert(remoteVideoInfo(attachments.filter{$0.kind != "video"},downloaded:["frame-1"])==nil)
 let synced=root.appendingPathComponent("synced",isDirectory:true);try fm.createDirectory(at:synced,withIntermediateDirectories:true)
 let remoteJSON=try JSONEncoder().encode(remote)
 let written=try CloudFolders.shared.writeContextAttachments([1:["video":mp4,"video.json":remoteJSON,"frame-1":frame,"frame-2":frame]],names:["1.png"],assets:synced)
 assert(written==["assets/1.mp4":sessionFingerprint(mp4)])
 assert(readVideoInfo(synced.appendingPathComponent("1.frames"))==remote && fm.fileExists(atPath:synced.appendingPathComponent("1.frames/2.png").path))
 // Místně změněné MP4 se při dalším syncu nepřepíše ani nesmaže.
 try Data([9,9]).write(to:synced.appendingPathComponent("1.mp4"))
 let kept=try CloudFolders.shared.writeContextAttachments([:],names:["1.png"],assets:synced,previous:written)
 let local=try Data(contentsOf:synced.appendingPathComponent("1.mp4"))
 assert(kept==written && local==Data([9,9]))
 try mp4.write(to:synced.appendingPathComponent("1.mp4"))
 // Video na serveru je, jen se nestáhlo: místní kopie zůstane.
 let retained=try CloudFolders.shared.writeContextAttachments([1:["video.keep":Data()]],names:["1.png"],assets:synced,previous:written)
 assert(retained==written)
 assert(fm.fileExists(atPath:synced.appendingPathComponent("1.mp4").path))
 _ = try CloudFolders.shared.writeContextAttachments([:],names:["1.png"],assets:synced,previous:written)
 assert(!fm.fileExists(atPath:synced.appendingPathComponent("1.mp4").path) && !fm.fileExists(atPath:synced.appendingPathComponent("1.frames").path))
 print("PASS: recording files beside the poster, copy/remove with the item, assets rendering and cloud download of MP4 and frames")

 // Cloudové přílohy: typ, limit, název souboru ve frontě a hlavičky snímku.
 let video=CloudAttachment(index:2,kind:"video",bytes:10,sha256:"a")
 assert(video.filename=="2.mp4" && video.contentType=="video/mp4" && video.sizeLimit==16*1024*1024 && !video.isContext)
 let shot=CloudAttachment(index:2,kind:"frame-12",bytes:10,sha256:"b",timestampMs:900,video:"a")
 assert(shot.filename=="2.frame-12.png" && shot.contentType=="image/png" && shot.sizeLimit==4*1024*1024)
 assert(CloudAttachment(index:1,kind:"har",bytes:1,sha256:"").filename=="1.har" && CloudAttachment(index:1,kind:"context",bytes:1,sha256:"").contentType=="application/json")
 assert(["context","har","video","frame-1","frame-12"].allSatisfy(CloudAttachment.validKind) && !["frame-13","frame-0","poster","mp4"].contains(where:CloudAttachment.validKind))
 // Starší job bez nových polí se načte beze změny.
 let sized=CloudAttachment(index:1,kind:"video",bytes:1,sha256:"a",durationMs:4200,width:640,height:360,startedAtMs:1_800_000_000_000)
 let roundTrip=try JSONDecoder().decode(CloudAttachment.self,from:JSONEncoder().encode(sized))
 assert(roundTrip==sized)
 let legacy=try JSONDecoder().decode(CloudAttachment.self,from:Data("{\"index\":1,\"kind\":\"har\",\"bytes\":1,\"sha256\":\"x\"}".utf8))
 assert(legacy.timestampMs==nil && legacy.video==nil)
 print("PASS: video and key frame cloud attachments: kinds, MIME types, size limits, queue file names and legacy jobs")
}

// Anotace přes video: plátno bez obrazu, vrstva anotací a vypálení do MP4 s původním záznamem stranou.
@MainActor func videoAnnotationTests() throws {
 let root=fm.temporaryDirectory.appendingPathComponent("video-annotations-\(UUID().uuidString)",isDirectory:true)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let (width,height)=(64,48)
 // Krátké černé video 64×48, 5 snímků po 100 ms.
 func blackVideo(_ url:URL)throws {
  let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
  let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
  let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height])
  writer.add(input);assert(writer.startWriting());writer.startSession(atSourceTime:.zero)
  for frame in 0..<5 {
   var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)
   CVPixelBufferLockBaseAddress(buffer!,[]);memset(CVPixelBufferGetBaseAddress(buffer!),0,CVPixelBufferGetDataSize(buffer!));CVPixelBufferUnlockBaseAddress(buffer!,[])
   while !input.isReadyForMoreMediaData{usleep(1000)}
   assert(adaptor.append(buffer!,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:10)))
  }
  input.markAsFinished();writer.endSession(atSourceTime:CMTime(value:5,timescale:10))
  let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()};done.wait()
  assert(writer.status == .completed,"\(String(describing:writer.error))")
 }
 // Barva pixelu prvního snímku (x zleva, y shora).
 func pixel(_ url:URL,x:Int,y:Int)->(r:Int,g:Int,b:Int) {
  let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
  let image=try! generator.copyCGImage(at:.zero,actualTime:nil)
  var data=[UInt8](repeating:0,count:width*height*4)
  let context=CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
  let i=(y*width+x)*4;return (Int(data[i]),Int(data[i+1]),Int(data[i+2]))
 }
 // Plátno: bez anotací žádná vrstva; s anotací průhledná mimo tvar a v rozměru obrazu.
 let poster=NSImage(size:NSSize(width:width,height:height));poster.lockFocus();NSColor.black.setFill();NSRect(x:0,y:0,width:width,height:height).fill();poster.unlockFocus()
 let canvas=DrawingView(image:poster,frame:NSRect(x:0,y:0,width:320,height:240))
 assert(canvas.overlay()==nil)
 // Vyplněný levý horní roh: tlustý rámeček přes celou levou polovinu horní poloviny.
 canvas.marks=[Mark(tool:.rectangle,points:[NSPoint(x:8,y:30),NSPoint(x:24,y:42)],color:.red,width:12,text:"",bold:false,italic:false,underline:false,fontSize:28)]
 let overlay=canvas.overlay()!
 assert(overlay.width==width && overlay.height==height)
 var alpha=[UInt8](repeating:0,count:width*height*4)
 CGContext(data:&alpha,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(overlay,in:CGRect(x:0,y:0,width:width,height:height))
 // Řádky bitmapy jdou shora: bod (16,36) v souřadnicích obrazu je řádek 11.
 assert(alpha[(11*width+16)*4+3]>200 && alpha[(40*width+56)*4+3]==0)
 print("PASS: video annotation canvas renders marks only on a transparent overlay at the poster size")

 // Vypálení: anotace ve videu na správném místě, zbytek obrazu beze změny, délka zachovaná.
 let source=root.appendingPathComponent("source.mp4");try blackVideo(source)
 let burned=root.appendingPathComponent("burned.mp4");try burnVideoOverlay(overlay,source:source,to:burned)
 let mark=pixel(burned,x:16,y:11),empty=pixel(burned,x:56,y:40)
 assert(mark.r>150 && mark.g<90 && empty.r<50 && empty.g<50,"\(mark) \(empty)")
 let sourceDuration=AVURLAsset(url:source).duration.seconds,burnedDuration=AVURLAsset(url:burned).duration.seconds
 assert(abs(sourceDuration-burnedDuration)<0.15,"\(sourceDuration) \(burnedDuration)")
 // Položka: původní záznam a snímky odložené ve složce snímků, MP4 i klíčový snímek s anotacemi; bez anotací se původní vrátí.
 func apply(_ poster:URL,_ overlay:CGImage?)throws{try commitVideoAnnotations(poster:poster,prepared:prepareVideoAnnotations(poster:poster,overlay:overlay))}
 let item=root.appendingPathComponent("item.png"),sides=videoSidecars(item),originals=videoOriginals(item)
 try fm.createDirectory(at:sides[1],withIntermediateDirectories:true);try fm.copyItem(at:source,to:sides[0])
 let black=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 black.setFillColor(CGColor(red:0,green:0,blue:0,alpha:1));black.fill(CGRect(x:0,y:0,width:width,height:height))
 try writePNG(black.makeImage()!,to:sides[1].appendingPathComponent("1.png"))
 try JSONEncoder().encode(VideoInfo(durationMs:500,width:width,height:height,frames:[.init(file:"1.png",ms:0)])).write(to:sides[1].appendingPathComponent("video.json"))
 let raw=try Data(contentsOf:source),rawFrame=try Data(contentsOf:sides[1].appendingPathComponent("1.png"))
 let data:(URL)->Data={(try? Data(contentsOf:$0)) ?? Data()}
 func framePixel(_ url:URL)->UInt8{
  let image=NSBitmapImageRep(data:data(url))!.cgImage!;var bytes=[UInt8](repeating:0,count:width*height*4)
  CGContext(data:&bytes,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
  return bytes[(11*width+16)*4]
 }
 // Příprava položku nemění.
 let prepared=try prepareVideoAnnotations(poster:item,overlay:overlay)!
 assert(data(sides[0])==raw && !fm.fileExists(atPath:originals.path))
 try commitVideoAnnotations(poster:item,prepared:prepared);assert(!fm.fileExists(atPath:prepared.path))
 assert(data(originals.appendingPathComponent("video.mp4"))==raw && data(originals.appendingPathComponent("1.png"))==rawFrame && data(sides[0]) != raw)
 assert(pixel(sides[0],x:16,y:11).r>150 && framePixel(sides[1].appendingPathComponent("1.png"))>150 && readVideoInfo(sides[1]) != nil)
 // Další úprava vychází z původního záznamu, ne z už vypáleného.
 try apply(item,overlay);assert(data(originals.appendingPathComponent("video.mp4"))==raw && data(originals.appendingPathComponent("1.png"))==rawFrame)
 try apply(item,nil)
 assert(data(sides[0])==raw && data(sides[1].appendingPathComponent("1.png"))==rawFrame && !fm.fileExists(atPath:originals.path))
 // Bez původního záznamu a bez anotací se nic nemění.
 try apply(item,nil);assert(data(sides[0])==raw)
 // Nečitelné video: chyba, položka zůstane beze změny a dočasná složka nezůstane.
 let broken=root.appendingPathComponent("broken.png"),brokenSides=videoSidecars(broken)
 try fm.createDirectory(at:brokenSides[1],withIntermediateDirectories:true);try Data([0,1,2,3]).write(to:brokenSides[0])
 var failed=false;do{try apply(broken,overlay)}catch{failed=true}
 assert(failed && data(brokenSides[0])==Data([0,1,2,3]) && !fm.fileExists(atPath:videoOriginals(broken).path))
 assert(((try? fm.contentsOfDirectory(atPath:root.path)) ?? []).allSatisfy{!$0.hasPrefix(".")})
 // Kopie a odebrání položky berou původní záznam s sebou (je ve složce snímků).
 try apply(item,overlay)
 let copy=root.appendingPathComponent("copy.png");try Data().write(to:copy);try copyAnnotationSidecar(from:item,to:copy)
 assert(fm.fileExists(atPath:videoOriginals(copy).path))
 removeAnnotatedImage(copy);assert(!fm.fileExists(atPath:videoOriginals(copy).path))
 print("PASS: annotations burn into the MP4 and key frames at the right place; the original recording is kept for re-editing and restored without marks")
}
