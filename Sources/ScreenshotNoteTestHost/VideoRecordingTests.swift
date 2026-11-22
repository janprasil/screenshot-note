import AppKit
@testable import ScreenshotNoteKit

// Video ze záznamu obrazovky; parita Markdownu s webem (tests/video.test.mjs, videoParity).
@MainActor func videoRecordingTests() throws {
 // Rozměr: delší strana nejvýš 1280, sudé hodnoty.
 assert(recordingSize(width:2880,height:1800)==(1280,800))
 assert(recordingSize(width:1000,height:501)==(1000,500))
 assert(recordingSize(width:1,height:1)==(2,2))
 assert(recordingSize(width:1800,height:2880)==(800,1280))
 // Délka m:ss jako web videoDuration.
 assert([500,59499,59500,60500,0].map(videoDuration)==["0:01","0:59","1:00","1:01","0:00"])
 assert(RecordingLimits.fps==10 && RecordingLimits.maxSide==1280 && RecordingLimits.bitrate==850_000 && RecordingLimits.maxDuration==60 && RecordingLimits.maxFrames==12)
 // 60 s při cílovém bitrate se s rezervou vejde do 8 MiB limitu cloudu.
 assert(Double(RecordingLimits.bitrate)*RecordingLimits.maxDuration/8<Double(CloudAttachment.videoLimit)*0.8)
 // Odpočet: výchozí 3 s, jen 3/5/10.
 let savedCountdown=UserDefaults.standard.object(forKey:"recordingCountdown")
 UserDefaults.standard.removeObject(forKey:"recordingCountdown");assert(recordingCountdown==3)
 recordingCountdown=10;assert(recordingCountdown==10);recordingCountdown=7;assert(recordingCountdown==3)
 if let savedCountdown{UserDefaults.standard.set(savedCountdown,forKey:"recordingCountdown")}else{UserDefaults.standard.removeObject(forKey:"recordingCountdown")}
 // Oblast v souřadnicích displeje (počátek vlevo nahoře).
 assert(displaySourceRect(CGRect(x:100,y:200,width:300,height:400),screen:CGRect(x:0,y:0,width:1440,height:900))==CGRect(x:100,y:300,width:300,height:400))
 assert(displaySourceRect(CGRect(x:1540,y:100,width:200,height:100),screen:CGRect(x:1440,y:0,width:1920,height:1080))==CGRect(x:100,y:880,width:200,height:100))
 print("PASS: recording size, duration format, limits, countdown setting and region coordinates")

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
 assert(video.filename=="2.mp4" && video.contentType=="video/mp4" && video.sizeLimit==8*1024*1024 && !video.isContext)
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
