import AppKit
@testable import ScreenshotNoteKit

// Přepočet mapy elementů na pixely obrázku s pevnými čísly, geometrie výřezu v kontextu a ladicí vykreslení.
@MainActor func elementMappingTests()throws{
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 func near(_ a:CGRect?,_ b:CGRect)->Bool{guard let a else{return false};return abs(a.minX-b.minX)<0.01 && abs(a.minY-b.minY)<0.01 && abs(a.width-b.width)<0.01 && abs(a.height-b.height)<0.01}
 func rect(_ x:Double,_ y:Double,_ width:Double,_ height:Double)->[String:Any]{["x":x,"y":y,"width":width,"height":height]}
 func context(ratio:Double,inner:(Double,Double),screen:(Double,Double,Double)=(0,0,0),viewport:[String:Any]?=nil,elements:[[String:Any]])->[String:Any]{
  var geometry:[String:Any]=["devicePixelRatio":ratio,"innerWidth":inner.0,"innerHeight":inner.1,"screenX":screen.0,"screenY":screen.1,"outerHeight":screen.2,"outerWidth":inner.0]
  if let viewport{geometry["visualViewport"]=viewport}
  return ["format":"screenshot-note-context","version":1,"page":["url":"https://example.test/","geometry":geometry],"elements":elements]
 }
 func element(_ x:Double,_ y:Double,_ width:Double,_ height:Double,depth:Int=1)->[String:Any]{["selector":"#e\(Int(x))","tag":"div","rect":rect(x,y,width,height),"depth":depth]}

 // Ne-Retina, zoom 1: obsah 700 bodů u spodního okraje okna 800 bodů.
 let plain=CaptureGeometry(rect:CGRect(x:0,y:0,width:1440,height:900),backingScale:1,imageScale:1,window:CGRect(x:100,y:50,width:1000,height:800))
 var mapped=mapElements(context(ratio:1,inner:(1000,700),elements:[element(10,20,100,30)]),capture:plain)
 try check(mapped.count==1 && near(mapped.first?.rect,CGRect(x:110,y:170,width:100,height:30)),"zoom 1 non-Retina: \(mapped)")

 // Retina, zoom 1,25: devicePixelRatio 2,5 / backingScale 2.
 let retina=CaptureGeometry(rect:CGRect(x:0,y:0,width:1440,height:900),backingScale:2,imageScale:2,window:CGRect(x:100,y:50,width:1000,height:800))
 mapped=mapElements(context(ratio:2.5,inner:(800,560),elements:[element(10,20,100,30)]),capture:retina)
 try check(mapped.count==1 && near(mapped.first?.rect,CGRect(x:225,y:350,width:250,height:75)),"zoom 1.25 Retina: \(mapped)")

 // Retina, zoom 1 a ne-Retina, zoom 1,25.
 mapped=mapElements(context(ratio:2,inner:(1000,700),elements:[element(10,20,100,30)]),capture:retina)
 try check(near(mapped.first?.rect,CGRect(x:220,y:340,width:200,height:60)),"zoom 1 Retina: \(mapped)")
 mapped=mapElements(context(ratio:1.25,inner:(800,560),elements:[element(10,20,100,30)]),capture:plain)
 try check(near(mapped.first?.rect,CGRect(x:112.5,y:175,width:125,height:37.5)),"zoom 1.25 non-Retina: \(mapped)")

 // Posunutý výřez (druhý displej): mimo výřez a viewport se vynechá, přesah se ořízne.
 let shifted=CaptureGeometry(rect:CGRect(x:1440,y:-200,width:1920,height:1080),backingScale:1,imageScale:1,window:CGRect(x:1500,y:0,width:800,height:600))
 mapped=mapElements(context(ratio:1,inner:(800,500),elements:[element(0,0,50,50),element(-1000,0,50,50),element(0,-100,50,50),element(780,0,100,10),element(0,600,10,10),element(5,5,0,10)]),capture:shifted)
 try check(mapped.map(\.index)==[0,3],"shifted indexes: \(mapped)")
 try check(near(mapped.first?.rect,CGRect(x:60,y:300,width:50,height:50)) && near(mapped.last?.rect,CGRect(x:840,y:300,width:20,height:10)),"shifted rects: \(mapped)")
 // Okno přesahuje levý okraj displeje: část mimo výřez se ořízne.
 let partial=CaptureGeometry(rect:CGRect(x:0,y:0,width:1440,height:900),backingScale:2,imageScale:2,window:CGRect(x:-100,y:-100,width:800,height:600))
 mapped=mapElements(context(ratio:2,inner:(800,500),elements:[element(50,0,100,100)]),capture:partial)
 try check(near(mapped.first?.rect,CGRect(x:0,y:0,width:100,height:200)),"partial window: \(mapped)")

 // Přesná pozice z Accessibility má přednost před výpočtem z okna.
 var accessible=retina;accessible.webArea=CGRect(x:200,y:300,width:1000,height:700)
 mapped=mapElements(context(ratio:2,inner:(1000,700),elements:[element(0,0,10,10)]),capture:accessible)
 try check(near(mapped.first?.rect,CGRect(x:400,y:600,width:20,height:20)),"web area: \(mapped)")
 // Bez okna se použije výpočet z geometrie stránky podle PROTOCOL.md.
 var bare=plain;bare.window=nil
 mapped=mapElements(context(ratio:1,inner:(1000,700),screen:(100,50,800),elements:[element(10,20,100,30)]),capture:bare)
 try check(near(mapped.first?.rect,CGRect(x:110,y:170,width:100,height:30)),"protocol fallback: \(mapped)")
 // Pinch zoom posune a zvětší prvky podle visualViewport.
 mapped=mapElements(context(ratio:1,inner:(1000,700),viewport:["scale":2,"offsetLeft":10,"offsetTop":20],elements:[element(10,20,100,30)]),capture:plain)
 try check(near(mapped.first?.rect,CGRect(x:100,y:150,width:200,height:60)),"pinch zoom: \(mapped)")
 // Záložní geometrie bez content scriptu (devicePixelRatio 0) mapu nemá.
 try check(mapElements(context(ratio:0,inner:(1000,700),elements:[element(10,20,100,30)]),capture:plain).isEmpty,"zero ratio maps elements")

 // Geometrie displeje: obrázek jiné velikosti než displej se odmítne.
 try check(CaptureGeometry.display(bounds:CGRect(x:0,y:0,width:1440,height:900),backingScale:2,pixelSize:CGSize(width:2880,height:1800),window:nil,webArea:nil)?.imageScale==2,"display geometry")
 try check(CaptureGeometry.display(bounds:CGRect(x:0,y:0,width:1440,height:900),backingScale:2,pixelSize:CGSize(width:3840,height:2160),window:nil,webArea:nil)==nil,"mismatched display accepted")

 // Geometrie se uloží do kontextu; podvržený klíč capture z rozšíření se zahodí.
 var bundle=context(ratio:2,inner:(1000,700),elements:[element(10,20,100,30)]);bundle["capture"]=["rect":rect(0,0,1,1),"backingScale":1,"imageScale":1];bundle["har"]=["log":[:]]
 let raw=try JSONSerialization.data(withJSONObject:bundle)
 guard let files=CaptureContextFiles(bundle:raw) else{throw BrowserBridgeError(message:"bundle rejected")}
 try check(((try JSONSerialization.jsonObject(with:files.context)) as? [String:Any])?["capture"]==nil,"extension capture kept")
 let root=fm.temporaryDirectory.appendingPathComponent("sn-elements-"+UUID().uuidString);defer{try? fm.removeItem(at:root)}
 try fm.createDirectory(at:root,withIntermediateDirectories:true)
 let image=root.appendingPathComponent("shot.png")
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2880,pixelsHigh:1800,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 try bitmap.representation(using:.png,properties:[:])!.write(to:image)
 try files.attaching(retina).write(besides:image)
 let stored=(try JSONSerialization.jsonObject(with:Data(contentsOf:contextSidecars(image)[0]))) as? [String:Any]
 try check(CaptureGeometry(json:stored?["capture"])==retina && stored?["format"] as? String=="screenshot-note-context","stored capture geometry")
 try check(ContextSummary(try Data(contentsOf:contextSidecars(image)[0])) != nil,"summary of context with capture")
 mapped=mapElements(contextFile:contextSidecars(image)[0])
 try check(near(mapped.first?.rect,CGRect(x:220,y:340,width:200,height:60)),"mapping from file: \(mapped)")
 try check(files.attaching(nil).context==files.context,"nil geometry changes context")

 // Ladicí vykreslení vytvoří kopii stejné velikosti a originál nemění.
 let before=try Data(contentsOf:image)
 guard let debug=ElementDebug.render(image:image,elements:mapped,to:root.appendingPathComponent("debug")),let copy=NSImageRep(contentsOf:debug) else{throw BrowserBridgeError(message:"debug render failed")}
 try check(copy.pixelsWide==2880 && copy.pixelsHigh==1800 && (try Data(contentsOf:image))==before,"debug render size or original changed")
 print("PASS element mapping")
}
