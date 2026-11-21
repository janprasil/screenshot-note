import AppKit
@testable import ScreenshotNoteKit

// Anotace Element: hit-test, rodič, ořez, zpětná kompatibilita dokumentu a export řádků.
@MainActor func elementAnnotationTests()throws{
 func check(_ condition:Bool,_ message:String)throws{if !condition{throw BrowserBridgeError(message:message)}}
 func near(_ a:CGRect?,_ b:CGRect)->Bool{guard let a else{return false};return abs(a.minX-b.minX)<0.01 && abs(a.minY-b.minY)<0.01 && abs(a.width-b.width)<0.01 && abs(a.height-b.height)<0.01}
 func target(_ index:Int,_ rect:NSRect,depth:Int,selector:String="",name:String="")->ElementTarget{ElementTarget(index:index,selector:selector.isEmpty ? "#e\(index)":selector,tag:"div",name:name,text:"",depth:depth,rect:rect)}

 // Hit-test: nejmenší prvek, při shodném obdélníku hlubší; rodič podle obsahování a hloubky.
 let body=target(0,NSRect(x:0,y:0,width:1000,height:800),depth:0),panel=target(1,NSRect(x:100,y:100,width:400,height:300),depth:1)
 let button=target(2,NSRect(x:150,y:150,width:100,height:40),depth:2,selector:"button[data-testid=\"save\"]",name:"Uložit"),label=target(3,NSRect(x:150,y:150,width:100,height:40),depth:3)
 let corner=target(4,NSRect(x:0,y:0,width:50,height:50),depth:1),targets=[body,panel,button,label,corner]
 try check(smallestElement(at:NSPoint(x:160,y:160),in:targets)?.index==3,"smallest with equal rect prefers deeper")
 try check(smallestElement(at:NSPoint(x:300,y:300),in:targets)?.index==1,"smallest panel")
 try check(smallestElement(at:NSPoint(x:1200,y:10),in:targets)==nil,"outside of every element")
 try check(parentElement(of:label,in:targets)?.index==2,"parent with identical rect")
 try check(parentElement(of:button,in:targets)?.index==1 && parentElement(of:panel,in:targets)?.index==0 && parentElement(of:body,in:targets)==nil,"parent chain")
 let flipped=elementTargets([MappedElement(index:7,selector:"#a",depth:1,rect:CGRect(x:10,y:20,width:100,height:30),tag:"a",name:"Odkaz")],imageHeight:600)
 try check(flipped.count==1 && near(flipped[0].rect,CGRect(x:10,y:550,width:100,height:30)) && flipped[0].name=="Odkaz","image rect is flipped to editor coordinates")

 // Editor: klik vybere nejmenší, opakovaný klik rodiče, ⌥ rovnou rodiče, Esc zruší rozpracovaný výběr.
 let canvas=DrawingView(image:NSImage(size:NSSize(width:1000,height:800)),frame:NSRect(x:0,y:0,width:500,height:400))
 canvas.elementMap=targets;canvas.tool = .element
 canvas.elementClick(NSPoint(x:160,y:160),parent:false)
 try check(canvas.marks.count==1 && canvas.marks[0].element?.selector=="#e3" && canvas.marks[0].element?.number==1 && canvas.elementField != nil,"click selects smallest and opens note")
 canvas.elementField?.stringValue="Popis";canvas.commitElementNote()
 canvas.elementClick(NSPoint(x:160,y:160),parent:false)
 try check(canvas.marks.count==1 && canvas.marks[0].element?.selector==button.selector && canvas.marks[0].text=="Popis" && canvas.marks[0].element?.number==1,"repeated click climbs to parent and keeps note")
 canvas.commitElementNote();canvas.activeElement=nil
 canvas.elementClick(NSPoint(x:20,y:20),parent:true)
 try check(canvas.marks.count==2 && canvas.marks[1].element?.selector=="#e0" && canvas.marks[1].element?.number==2,"option click selects parent")
 canvas.cancelActiveElement()
 try check(canvas.marks.count==1 && canvas.activeElement==nil && canvas.elementField==nil,"escape cancels pending element")
 canvas.cancelActiveElement()
 try check(canvas.tool == .select,"escape without selection leaves the tool")
 // Po Enteru zůstane výběr pro rodiče, Esc už potvrzenou anotaci nesmaže; klik na jiné dítě vybere nový prvek.
 canvas.tool = .element;canvas.marks=[];canvas.elementClick(NSPoint(x:300,y:300),parent:false);canvas.confirmElementNote()
 canvas.elementClick(NSPoint(x:300,y:300),parent:false)
 try check(canvas.marks.count==1 && canvas.marks[0].element?.selector=="#e0","click after Enter climbs to the parent")
 canvas.confirmElementNote();canvas.elementClick(NSPoint(x:160,y:160),parent:false)
 try check(canvas.marks.count==2 && canvas.marks[1].element?.selector=="#e3","click on another child inside the active parent selects it")
 canvas.confirmElementNote();canvas.cancelActiveElement()
 try check(canvas.marks.count==2,"escape keeps a confirmed element")
 try check(canvas.hit(NSPoint(x:500,y:400))==nil && canvas.hit(NSPoint(x:999,y:400)).map{canvas.marks[$0].tool == .element}==true,"element hit only on the border")
 // Znovu otevřená relace: čísla navážou na řádky v popisku.
 try check(highestElementNumber(in:"Popis\n\n- **[1] Element** `a`\n- **[12] Element**: x\n text - **[99] Element**")==12,"highest element number in caption")
 canvas.marks=[];canvas.firstElementNumber=13;canvas.elementClick(NSPoint(x:160,y:160),parent:false)
 try check(canvas.marks.first?.element?.number==13,"numbering continues after reopened caption");canvas.firstElementNumber=1;canvas.marks=[];canvas.activeElement=nil;canvas.commitElementNote()

 // Ořez: prvky se oříznou nebo vynechají a výřez snímku se posune.
 let clipped=clippedTargets(targets,to:NSRect(x:120,y:0,width:880,height:800))
 try check(!clipped.contains{$0.index==4} && near(clipped.first{$0.index==1}?.rect,CGRect(x:120,y:100,width:380,height:300)) && near(clipped.first{$0.index==2}?.rect,button.rect),"crop clips the element map")
 canvas.viewport=NSRect(x:120,y:0,width:880,height:800)
 try check(smallestElement(at:NSPoint(x:20,y:20),in:canvas.visibleElements)==nil,"hit-test ignores cropped elements")
 let capture=CaptureGeometry(rect:CGRect(x:0,y:0,width:1440,height:900),backingScale:2,imageScale:2,window:CGRect(x:100,y:50,width:1000,height:800))
 let crop=NSRect(x:200,y:900,width:1000,height:600),moved=croppedCapture(capture,crop:crop)
 try check(near(moved.rect,CGRect(x:100,y:150,width:500,height:300)) && moved.window==capture.window && moved.imageScale==2,"cropped capture rect: \(moved.rect)")
 let page:[String:Any]=["page":["geometry":["devicePixelRatio":2,"innerWidth":1000,"innerHeight":700,"screenX":0,"screenY":0,"outerHeight":0,"outerWidth":1000]],"elements":[["selector":"#a","tag":"a","rect":["x":10,"y":20,"width":100,"height":30],"depth":1]]]
 try check(near(mapElements(page,capture:moved).first?.rect,CGRect(x:20,y:40,width:200,height:60)),"element map follows the crop")
 let folder=fm.temporaryDirectory.appendingPathComponent("element-annotations-\(UUID().uuidString)",isDirectory:true);try fm.createDirectory(at:folder,withIntermediateDirectories:true);defer{try? fm.removeItem(at:folder)}
 let image=folder.appendingPathComponent("shot.png"),contextFile=contextSidecars(image)[0]
 var stored=page;stored["capture"]=capture.json;try JSONSerialization.data(withJSONObject:stored).write(to:contextFile)
 try JSONEncoder().encode(AnnotationDocument(base:Data(),marks:[],crop:crop)).write(to:annotationSidecar(image))
 try check(mapElements(contextFile:contextFile,imageSize:CGSize(width:1000,height:600)).isEmpty,"map is rejected for an image of another size")
 adjustContextCapture(contextFile,annotations:annotationSidecar(image))
 try check(near(mapElements(contextFile:contextFile,imageSize:CGSize(width:1000,height:600)).first?.rect,CGRect(x:20,y:40,width:200,height:60)),"exported context follows the crop")
 try check(mapElements(contextFile:contextFile,imageSize:CGSize(width:2880,height:1800)).isEmpty,"full image no longer matches the cropped context")
 try check(((try fm.attributesOfItem(atPath:contextFile.path))[.posixPermissions] as? NSNumber)?.intValue==0o600,"rewritten context stays private")

 // Codable: dokument ze starší verze bez pole element se načte, nový se vrátí beze ztráty.
 let old=#"{"base":"","crop":[[0,0],[10,10]],"marks":[{"tool":4,"points":[[1,2]],"rgba":[1,0,0,1],"width":4,"text":"Ahoj","bold":false,"italic":false,"underline":false,"fontSize":28}]}"#
 let decoded=try JSONDecoder().decode(AnnotationDocument.self,from:Data(old.utf8))
 try check(decoded.marks.count==1 && decoded.marks[0].tool == .text && decoded.marks[0].element==nil && decoded.marks[0].rotation==0,"old annotation document decodes")
 var mark=canvas.elementMark(button,number:3);mark.text="Nic"
 let again=try JSONDecoder().decode(Mark.self,from:JSONEncoder().encode(mark))
 try check(again.tool == .element && again.element==mark.element && again.text=="Nic" && near(again.bounds,button.rect),"element mark round trip")

 // Export: pořadí podle čísla, ořez, escapování textu stránky a selektor podobný odkazu na obrázek.
 func exported(_ number:Int,_ rect:NSRect,selector:String,tag:String="div",name:String="",text:String="",note:String="")->Mark{
  var mark=Mark(tool:.element,points:[rect.origin,NSPoint(x:rect.maxX,y:rect.maxY)],color:.red,width:2,text:note,bold:false,italic:false,underline:false,fontSize:14)
  mark.element=ElementInfo(number:number,selector:selector,tag:tag,name:name,text:text);return mark
 }
 let marks=[exported(2,button.rect,selector:"a`b",text:"Hello\n  world"),exported(1,button.rect,selector:"button[data-testid=\"save\"]",name:"Uložit",note:"Klik nic\nneudělá"),
  exported(3,NSRect(x:900,y:700,width:50,height:50),selector:"#out"),exported(5,button.rect,selector:"![[assets/a.png]]",tag:"![[assets/b.png]]"),exported(4,button.rect,selector:"img[alt=\"![x](assets/evil.png)\"]",tag:"img",name:"![y](assets/z.png)"),
  Mark(tool:.rectangle,points:[.zero,NSPoint(x:5,y:5)],color:.red,width:2,text:"",bold:false,italic:false,underline:false,fontSize:14)]
 let lines=elementMarkdownLines(marks,crop:NSRect(x:0,y:0,width:500,height:500))
 let expected="- **[1] Element** `button[data-testid=\"save\"]` „Uložit“: Klik nic neudělá\n- **[2] Element** ``a`b`` „Hello world“\n- **[4] Element** `img` „\\!\\[y\\]\\(assets/z.png\\)“\n- **[5] Element**"
 try check(lines==expected,"element lines:\n\(lines)")
 try check(imageLinks(lines).isEmpty,"page text cannot create image links")
 try JSONEncoder().encode(AnnotationDocument(base:Data(),marks:marks,crop:NSRect(x:0,y:0,width:500,height:500))).write(to:annotationSidecar(image))
 try check(captionWithElements("Popisek",image:image)=="Popisek\n\n"+expected && captionWithElements("",image:image)==expected,"caption with elements")
 try check(captionWithElements("Jen text",image:folder.appendingPathComponent("missing.png"))=="Jen text","caption without annotations")
 try check(captionWithElements("",image:image,pageData:false)=="- **[1] Element**: Klik nic neudělá\n- **[2] Element**\n- **[4] Element**\n- **[5] Element**","cloud caption without page data")
 // Komentáře tvarů: společná řada čísel s elementy, prázdný komentář číslo odebere, ostatní se přečíslují.
 let notes=DrawingView(image:NSImage(size:NSSize(width:1000,height:800)),frame:NSRect(x:0,y:0,width:500,height:400))
 func shape(_ tool:Tool,_ rect:NSRect)->Mark{Mark(tool:tool,points:[rect.origin,NSPoint(x:rect.maxX,y:rect.maxY)],color:.red,width:3,text:"",bold:false,italic:false,underline:false,fontSize:14)}
 notes.marks=[shape(.rectangle,NSRect(x:10,y:10,width:100,height:100)),exported(1,NSRect(x:200,y:200,width:50,height:50),selector:"#a"),shape(.arrow,NSRect(x:300,y:300,width:80,height:20))]
 func comment(_ index:Int,_ text:String){notes.startElementNote(index);notes.elementField?.stringValue=text;notes.commitElementNote()}
 comment(0,"Špatné zarovnání");comment(2,"Sem klikni")
 try check(notes.marks[0].number==2 && notes.marks[2].number==3 && notes.marks[1].element?.number==1,"shape comments continue the element numbering")
 let shapeLines=elementMarkdownLines(notes.marks,crop:nil,pageData:false)
 try check(shapeLines=="- **[1] Element**\n- **[2] Rámeček**: Špatné zarovnání\n- **[3] Šipka**: Sem klikni","shape comment lines:\n\(shapeLines)")
 comment(0,"");try check(notes.marks[0].number==nil && notes.marks[0].comment==nil && notes.marks[2].number==2,"empty comment removes the number and renumbers")
 notes.undoChange();try check(notes.marks[0].number==2 && notes.marks[0].comment=="Špatné zarovnání","comment removal can be undone")
 let commented=try JSONDecoder().decode(Mark.self,from:JSONEncoder().encode(notes.marks[0]))
 try check(commented.comment=="Špatné zarovnání" && commented.number==2,"shape comment round trip")
 try check(highestElementNumber(in:"- **[1] Element**\n- **[7] Rámeček**: x")==7,"highest number includes shape comments")
 try check(highestElementNumber(in:"- **[9] Krok**\n- **[2] Šipka**: y")==2,"user list items do not shift numbering")
 notes.marks[0].comment="viz ![x](assets/a.png)";try check(imageLinks(elementMarkdownLines(notes.marks,crop:nil)).isEmpty,"comment cannot create an image link")
 let rendered=notes.png();try check(rendered != nil,"export with comment badges renders")
 // Úprava popisu existujícího elementu jde vrátit.
 let undoCanvas=DrawingView(image:NSImage(size:NSSize(width:1000,height:800)),frame:NSRect(x:0,y:0,width:500,height:400))
 undoCanvas.marks=[exported(1,button.rect,selector:"#b",note:"Původní")];undoCanvas.startElementNote(0);undoCanvas.elementField?.stringValue="Nový";undoCanvas.commitElementNote()
 try check(undoCanvas.marks[0].text=="Nový","note edited");undoCanvas.undoChange()
 try check(undoCanvas.marks[0].text=="Původní","undo restores the element note")
}
