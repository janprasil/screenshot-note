import AppKit
@testable import ScreenshotNoteKit

// Kontext z prohlížeče: cíl okna, rozdělení bundlu, export, kolize, mazání, znovuotevření a starý draft.
@MainActor func captureContextTests()async throws{
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 let root=fm.temporaryDirectory.appendingPathComponent("sn-context-"+UUID().uuidString);defer{try? fm.removeItem(at:root)}
 try fm.createDirectory(at:root,withIntermediateDirectories:true)
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}

 // Cíl: nejvyšší okno vrstvy 0 daného procesu, malá a jiná okna se přeskočí.
 func window(_ pid:Int,_ layer:Int,_ rect:CGRect,_ title:String?=nil)->[String:Any]{
  var item:[String:Any]=[kCGWindowOwnerPID as String:pid,kCGWindowLayer as String:layer,kCGWindowBounds as String:rect.dictionaryRepresentation as NSDictionary]
  if let title{item[kCGWindowName as String]=title};return item
 }
 let windows=[window(7,25,CGRect(x:0,y:0,width:800,height:30)),window(9,0,CGRect(x:5,y:5,width:500,height:500)),window(7,0,CGRect(x:1,y:2,width:40,height:20)),window(7,0,CGRect(x:10,y:20,width:1200,height:800),"Orders – Chrome"),window(7,0,CGRect(x:0,y:0,width:900,height:900))]
 let target=captureTarget(windows:windows,pid:7),bounds=target?["windowBounds"] as? [String:CGFloat]
 try check(bounds==["x":10,"y":20,"width":1200,"height":800] && target?["windowTitle"] as? String=="Orders – Chrome","capture target is not the topmost layer-0 browser window")
 try check(captureTarget(windows:windows,pid:8)==nil,"capture target for an app without windows")
 try check(["com.google.Chrome","com.microsoft.edgemac","company.thebrowser.Browser","org.chromium.Chromium"].allSatisfy(chromiumBundleIDs.contains) && !chromiumBundleIDs.contains("com.apple.Safari"),"Chromium bundle IDs")

 // Bez běžícího bridge se nečeká ani nehledá okno.
 let stopped=BrowserBridge(socketPath:root.appendingPathComponent("none.sock").path)
 let started=Date();try check(PendingCaptureContext.start(bridge:stopped)==nil && Date().timeIntervalSince(started)<0.2,"capture context waits without a bridge")
 let empty=await withCheckedContinuation{(c:CheckedContinuation<Bool,Never>) in PendingCaptureContext(bridge:stopped,target:nil).wait(upTo:1){c.resume(returning:$0==nil)}}
 try check(empty,"failed request must deliver no context")

 // Bundle se rozdělí na kontext bez HAR a HAR; cizí formát se odmítne.
 let bundle:[String:Any]=["format":"screenshot-note-context","version":1,"capturedAt":"2026-11-21T10:00:00Z","extensionVersion":"0.1.0",
  "page":["url":"https://app.example.com/orders?id=1","title":"Orders"],"policy":["includeBodies":false],
  "summary":["consoleErrors":1,"consoleWarnings":0,"uncaughtErrors":1,"failedRequests":[["method":"POST","url":"https://app.example.com/api/orders?token=x","status":500],["method":"GET","url":"https://cdn.example.com/a.js","error":"net::ERR_FAILED"]],"requestCount":4],
  "console":[["kind":"console","level":"log","args":["ok"],"time":1,"url":"u"],["kind":"error","time":2,"message":"TypeError: `x` is\nundefined","unhandledRejection":false,"url":"u"]],
  "har":["log":["version":"1.2","entries":[]]],"elements":[],"trimmed":["bodies":true,"network":2,"console":0,"elements":0]]
 let files=CaptureContextFiles(bundle:try JSONSerialization.data(withJSONObject:bundle))
 let context=files.flatMap{(try? JSONSerialization.jsonObject(with:$0.context)) as? [String:Any]}
 try check(context != nil && context?["har"]==nil && (context?["summary"] as? [String:Any]) != nil && files?.har.flatMap{(try? JSONSerialization.jsonObject(with:$0)) as? [String:Any]}?["log"] != nil,"bundle split into context and HAR")
 try check(CaptureContextFiles(bundle:Data(#"{"format":"other","version":1}"#.utf8))==nil && CaptureContextFiles(bundle:Data("[]".utf8))==nil && CaptureContextFiles(bundle:Data(#"{"format":"screenshot-note-context","version":2}"#.utf8))==nil,"foreign bundle accepted")
 try check(inlineCode("a`b\nc")=="`a'b c`" && inlineCode("")=="`?`" && inlineCode(String(repeating:"x",count:300)).count==203,"inline code sanitizing")

 // Export: assets/<název>.png, .context.json a .har; callout pod popiskem a {context}.
 let capture=root.appendingPathComponent("capture");try fm.createDirectory(at:capture,withIntermediateDirectories:true)
 func shot(_ name:String,_ byte:UInt8,context:Bool)throws{let url=capture.appendingPathComponent(name);try Data([byte]).write(to:url);if context{try files!.write(besides:url)}}
 try shot("a.png",1,context:true);try shot("b.png",2,context:false)
 let sides=contextSidecars(capture.appendingPathComponent("a.png"))
 try check(sides.allSatisfy{fm.fileExists(atPath:$0.path)} && (try fm.attributesOfItem(atPath:sides[0].path)[.posixPermissions] as? Int)==0o600,"draft context sidecars")
 let template="# {title}\n\n{screenshots}\n\n## Kontext\n\n{context}\n\n{text}\n"
 let folder=root.appendingPathComponent("local")
 var topic=Topic(id:"ctx",name:"Ctx",detail:"",folder:folder.path,combined:false,combinedFile:"N.md");topic.markdownTemplate=template
 let draft=Draft(images:["a.png","b.png"],comment:"Popis",title:"Bug",topic:topic,imageNotes:["a.png":"Chyba při uložení"],contexts:["a.png":"a.png.context.json"])
 try finishSession(draft,root:capture)
 let stem=readableSessionName("Bug",created:Date()),assets=folder.appendingPathComponent("assets")
 let markdown=folder.appendingPathComponent(stem+".md"),text=try String(contentsOf:markdown,encoding:.utf8)
 let exported=assetContextFiles(assets,stem+"-1.png")
 try check(exported.allSatisfy{fm.fileExists(atPath:$0.path)} && !assetContextFiles(assets,stem+"-2.png").contains{fm.fileExists(atPath:$0.path)},"context files next to the exported PNG")
 try check(((try? JSONSerialization.jsonObject(with:Data(contentsOf:exported[0]))) as? [String:Any])?["har"]==nil,"exported context.json contains HAR")
 try check(text.contains("Chyba při uložení\n\n> [!bug]- Kontext: `https://app.example.com/orders?id=1` (2 chyby, 2 selhané requesty)\n> - `POST /api/orders` → 500\n> - `GET /a.js` → `net::ERR_FAILED`\n> - `TypeError: 'x' is undefined`\n> - Zmenšeno kvůli velikosti: bez těl, 2 requesty\n> - [HAR](<assets/\(stem)-1.har>) · [konzole](<assets/\(stem)-1.context.json>)\n\n![Screenshot 2]"),"callout under the image note:\n\(text)")
 try check(text.contains("## Kontext\n\n- Screenshot 1: `https://app.example.com/orders?id=1` (2 chyby, 2 selhané requesty) · [HAR](<assets/\(stem)-1.har>)") && !text.contains("Screenshot 2: "),"{context} session summary")
 try check(!draft.images.contains{fm.fileExists(atPath:capture.appendingPathComponent($0).path)} && !sides.contains{fm.fileExists(atPath:$0.path)},"draft files left after export")
 let record=SessionIndex.shared.records(file:markdown).first
 try check(record?.files["assets/\(stem)-1.context.json"]==fileHash(exported[0]) && record?.files["assets/\(stem)-1.har"]==fileHash(exported[1]) && record?.notes[stem+"-1.png"]=="Chyba při uložení","index hashes of context files")

 // Kolize: zbylý soubor kontextu blokuje název stejně jako PNG.
 let other=root.appendingPathComponent("other"),otherAssets=other.appendingPathComponent("assets");try fm.createDirectory(at:otherAssets,withIntermediateDirectories:true)
 try Data("stale".utf8).write(to:otherAssets.appendingPathComponent(stem+"-1.har"))
 var second=topic;second.id="other";second.folder=other.path
 try shot("c.png",3,context:true)
 try finishSession(Draft(images:["c.png"],comment:"",title:"Bug",topic:second,contexts:["c.png":"c.png.context.json"]),root:capture)
 try check(fm.fileExists(atPath:otherAssets.appendingPathComponent(stem+"-1 2.png").path) && assetContextFiles(otherAssets,stem+"-1 2.png").allSatisfy{fm.fileExists(atPath:$0.path)} && !fm.fileExists(atPath:otherAssets.appendingPathComponent(stem+"-1.png").path),"collision with a leftover context file")
 try check(String(data:try Data(contentsOf:otherAssets.appendingPathComponent(stem+"-1.har")),encoding:.utf8)=="stale","leftover file overwritten")

 // Znovuotevření: popisek bez calloutu, kontext zpět v draftu, nový export ho zachová bez kopií.
 var found=try previousSessions(for:topic)
 try check(found.count==1 && found[0].imageNotes[stem+"-1.png"]=="Chyba při uložení","reopened note contains the callout")
 let reopen=root.appendingPathComponent("reopen");try fm.createDirectory(at:reopen,withIntermediateDirectories:true)
 var reopened=try workingDraft(from:found[0],topic:topic,root:reopen)
 let first=reopened.images[0]
 try check(reopened.contexts==[first:first+".context.json"] && contextSidecars(reopen.appendingPathComponent(first)).allSatisfy{fm.fileExists(atPath:$0.path)},"reopened draft lost the context")
 try Data([4]).write(to:reopen.appendingPathComponent("d.png"));reopened.images.append("d.png");reopened.comment="Doplněno"
 let before=try fm.contentsOfDirectory(atPath:assets.path).count
 try finishSession(reopened,root:reopen)
 let updated=try String(contentsOf:markdown,encoding:.utf8)
 try check(updated.contains("> - [HAR](<assets/\(stem)-1.har>)") && updated.components(separatedBy:"[!bug]-").count==2 && updated.contains("Doplněno"),"reopen and save keeps the callout:\n\(updated)")
 try check(try fm.contentsOfDirectory(atPath:assets.path).count==before+1,"reopen duplicated context files")
 found=try previousSessions(for:topic)
 try check(found.count==1 && found[0].images.count==3 && found[0].imageNotes[stem+"-1.png"]=="Chyba při uložení","second reopen")
 // Popisek s vlastním calloutem bez odkazu na kontext zůstane.
 try check(stripContextCallout("Text\n\n> [!bug]- Moje\n> - bod")=="Text\n\n> [!bug]- Moje\n> - bod" && stripContextCallout("> [!bug]- K\n> - [konzole](<assets/x.context.json>)")=="","callout stripping")

 // Přerenderování složky novou šablonou zachová callout i souhrn.
 var retemplated=topic;retemplated.markdownTemplate="# {title}\n\n{context}\n\n{screenshots}\n\n{text}\n"
 _ = rerenderFolder(retemplated,previous:topic)
 let rerendered=try String(contentsOf:markdown,encoding:.utf8)
 try check(rerendered.hasPrefix("# Bug\n\n- Screenshot 1: ") && rerendered.contains("> [!bug]- Kontext: "),"rerender drops context:\n\(rerendered)")

 // Cloudová složka: kontext se zahodí, nic se nenahraje ani neexportuje.
 let cloud=root.appendingPathComponent("cloud");try shot("e.png",5,context:true)
 var cloudTopic=topic;cloudTopic.id="cloud";cloudTopic.folder=cloud.path;cloudTopic.cloudFolderID=UUID()
 try finish(Draft(images:["e.png"],comment:"",title:"Cloud",topic:cloudTopic,contexts:["e.png":"e.png.context.json"]),root:capture,dest:cloud)
 let cloudAssets=try fm.contentsOfDirectory(atPath:cloud.appendingPathComponent("assets").path)
 try check(cloudAssets.count==1 && cloudAssets[0].hasSuffix(".png") && !contextSidecars(capture.appendingPathComponent("e.png")).contains{fm.fileExists(atPath:$0.path)},"cloud folder kept context")

 // Smazání obrázku v komposeru smaže i kontext.
 let work=root.appendingPathComponent("work");try fm.createDirectory(at:work,withIntermediateDirectories:true)
 try Data([6]).write(to:work.appendingPathComponent("f.png"));try files!.write(besides:work.appendingPathComponent("f.png"))
 let composer=Composer(draft:Draft(images:["f.png"],comment:"",contexts:["f.png":"f.png.context.json"]),root:work)
 let button=NSButton();button.tag=0;composer.removeImage(button)
 try check(composer.draft.images.isEmpty && composer.draft.contexts?.isEmpty != false && !contextSidecars(work.appendingPathComponent("f.png")).contains{fm.fileExists(atPath:$0.path)},"removing an image keeps its context")

 // Draft ze starší verze bez pole contexts; neplatné mapování se zahodí.
 let old=root.appendingPathComponent("old");try fm.createDirectory(at:old,withIntermediateDirectories:true)
 try Data([7]).write(to:old.appendingPathComponent("g.png"))
 try Data(#"{"images":["g.png"],"comment":"Starý","imageNotes":{"g.png":"pozn"}}"#.utf8).write(to:old.appendingPathComponent("draft.json"))
 let legacy=try readDraft(old)
 try check(legacy.images==["g.png"] && legacy.contexts==nil && legacy.imageNotes?["g.png"]=="pozn","old draft without contexts")
 try Data(#"{"images":["g.png"],"comment":"","contexts":{"g.png":"g.png.context.json","x.png":"x.png.context.json"}}"#.utf8).write(to:old.appendingPathComponent("draft.json"))
 try check(try readDraft(old).contexts?.isEmpty==true,"draft keeps context mapping without files")
 try files!.write(besides:old.appendingPathComponent("g.png"))
 try check(try readDraft(old).contexts==["g.png":"g.png.context.json"],"draft drops valid context mapping")
}
