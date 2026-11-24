import AppKit

var previewAppearance:NSAppearance.Name = .aqua
var previewOutput=URL(fileURLWithPath:"/tmp/Screenshot-Note-Design",isDirectory:true)
func exportDesignWindow(_ window:NSWindow,name:String){
 window.appearance=NSAppearance(named:previewAppearance)
 if let editor=window.firstResponder as? NSTextView{editor.setSelectedRange(NSRange(location:0,length:0))};window.makeFirstResponder(nil)
 guard let view=window.contentView else{return}
 view.layoutSubtreeIfNeeded();view.displayIfNeeded()
 guard let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{return}
 view.cacheDisplay(in:view.bounds,to:rep)
 let mode=previewAppearance == .darkAqua ? "dark":"light"
 let language=AppLanguage.current
 if let data=rep.representation(using:.png,properties:[:]){try? data.write(to:previewOutput.appendingPathComponent(name+"-"+language+"-"+mode+".png"));if language=="cs"{try? data.write(to:previewOutput.appendingPathComponent(name+"-"+mode+".png"))}}
}
func previewScreenshot(alternate:Bool=false)->NSImage{
 let image=NSImage(size:NSSize(width:1100,height:680));image.lockFocus()
 NSColor.white.setFill();NSRect(x:0,y:0,width:1100,height:680).fill()
 NSColor(srgbRed:0.96,green:0.96,blue:0.98,alpha:1).setFill();NSRect(x:0,y:620,width:1100,height:60).fill();NSRect(x:0,y:0,width:216,height:620).fill()
 for(i,color) in [NSColor.systemRed,.systemYellow,.systemGreen].enumerated(){color.setFill();NSBezierPath(ovalIn:NSRect(x:24+CGFloat(i)*22,y:643,width:12,height:12)).fill()}
 func write(_ value:String,_ rect:NSRect,_ size:CGFloat=16,_ weight:NSFont.Weight = .regular,_ color:NSColor = .darkGray){(value as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])}
 write(L("Studio / Produkt"),NSRect(x:240,y:639,width:700,height:24),15,.medium)
 write("WORKSPACE",NSRect(x:24,y:565,width:170,height:20),11,.semibold,.gray)
 for(i,text) in [L("Přehled"),L("Projekty"),L("Zpětná vazba"),L("Dokumenty")].enumerated(){let y=CGFloat(515-i*46);if i==2{NSColor(srgbRed:0.9,green:0.88,blue:0.98,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:14,y:y-7,width:187,height:36),xRadius:8,yRadius:8).fill()};write(text,NSRect(x:28,y:y,width:180,height:25),15,i==2 ? .semibold:.regular)}
 write(alternate ? L("Detail požadavku"):L("Zpětná vazba k objednávce"),NSRect(x:264,y:535,width:800,height:48),32,.semibold,.black)
 write(L("Webová aplikace  /  Připomínky"),NSRect(x:264,y:590,width:760,height:20),13,.regular,.gray)
 write(alternate ? L("Zjednodušit poslední krok objednávky."):L("Poznámky z dnešního průchodu produktem."),NSRect(x:264,y:493,width:760,height:28),17)
 for(i,pair) in [(L("Přehlednější potvrzení"),L("Zachovat cenu i způsob doručení na jednom místě.")),(L("Volba platby"),L("Zvýraznit aktuálně zvolenou možnost.")),(L("Dokončení objednávky"),L("Doplnit stručnou informaci o dalším postupu."))].enumerated(){let y=CGFloat(392-i*106);NSColor(white:0.91,alpha:1).setFill();NSRect(x:264,y:y-20,width:770,height:1).fill();write(String(format:"%02d",i+1),NSRect(x:264,y:y+18,width:38,height:22),14,.medium,.gray);write(pair.0,NSRect(x:318,y:y+20,width:670,height:28),19,.semibold,.black);write(pair.1,NSRect(x:318,y:y-7,width:670,height:24),15)}
 NSColor(srgbRed:0.41,green:0.32,blue:0.85,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:820,y:52,width:214,height:46),xRadius:9,yRadius:9).fill();write(L("Uložit změny"),NSRect(x:855,y:61,width:160,height:26),17,.semibold,.white)
 image.unlockFocus();return image
}
func exportDesignPreviews(to directory:URL)throws{
 previewOutput=directory;try fm.createDirectory(at:directory,withIntermediateDirectories:true)
 let root=fm.temporaryDirectory.appendingPathComponent("Screenshot-Note-Design-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 for language in ["cs","en"]{
 AppLanguage.override=language
 for i in 0..<2{let image=previewScreenshot(alternate:i==1);let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!;try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("sample-\(language)-\(i).png"))}
 let demo=Topic(id:"demo",name:L("Produktové poznámky"),detail:L("Připomínky k rozhraní a návrhy úprav"),folder:root.appendingPathComponent("notes").path,combined:false,combinedFile:language=="en" ? "Notes.md":"Poznamky.md")
 let second=Topic(id:"demo2",name:L("Inspirace"),detail:L("Nápady a vizuální reference"),folder:root.appendingPathComponent("inspiration").path,combined:true,combinedFile:"Inspirace.md")
 for appearance in [NSAppearance.Name.aqua,.darkAqua]{
  previewAppearance=appearance;NSApp.appearance=NSAppearance(named:appearance)
  let composer=Composer(draft:Draft(images:["sample-\(language)-0.png","sample-\(language)-1.png"],comment:L("Zvýraznit vybranou platbu a zjednodušit potvrzení objednávky."),title:L("Průchod objednávkou"),topic:demo,imageNotes:["sample-\(language)-0.png":L("Zvýraznit vybranou platbu a zjednodušit potvrzení objednávky.")]),root:root);composer.show();exportDesignWindow(composer.window,name:"capture")
  if let thumbnail=composer.buttons.first as? ScreenshotThumbnailButton{
   thumbnail.setHovered(true)
   exportDesignWindow(composer.window,name:"capture-hover")
   thumbnail.setHovered(false)
  }
  let imageNote=ImageNoteEditor();_ = imageNote.run(L("Zjednodušit poslední krok objednávky."),image:root.appendingPathComponent("sample-\(language)-0.png"))
  let chooser=SessionChoiceDialog();_ = chooser.run(title:L("Vybrat konfiguraci"),choices:[SessionChoice(title:demo.name,detail:demo.detail),SessionChoice(title:second.name,detail:second.detail)])
  let sessions=SessionChoiceDialog();_ = sessions.run(title:L("Vybrat relaci"),choices:[SessionChoice(title:L("Nová relace"),detail:L("Vytvořit novou poznámku z aktuálních snímků.")),SessionChoice(title:L("Průchod objednávkou"),detail:L("Zvýraznit vybranou platbu a zjednodušit potvrzení objednávky."),images:[root.appendingPathComponent("sample-\(language)-0.png"),root.appendingPathComponent("sample-\(language)-1.png")])])
  let cloudVault=CloudMemoryVault(), pairingID=UUID()
  cloudVault.value=CloudConnection(endpoint:"https://screenshotnote.com",token:"sn_device_v1_" + String(repeating:"a",count:43),id:pairingID,
   comparisonCode:"AB12CD34",verificationURI:"https://screenshotnote.com/pair-device/" + pairingID.uuidString.lowercased(),expiresAt:"2099-01-01T00:00:00Z")
  let cloud=CloudSettings(library:CloudLibrary(queue:root.appendingPathComponent("preview-cloud"),vault:cloudVault,endpoint:CloudEndpoint("https://screenshotnote.com")!));cloud.show();exportDesignWindow(cloud.window!,name:"cloud-pairing")
  // Připojený stav: ikona stavu v okraji, text a poznámka na stejné hraně.
  let connectedVault=CloudMemoryVault();var connected=cloudVault.value!;connected.ownerID=UUID();connected.email="ukazka@example.com";connectedVault.value=connected
  let linked=CloudSettings(library:CloudLibrary(queue:root.appendingPathComponent("preview-cloud-connected"),vault:connectedVault,endpoint:CloudEndpoint("https://screenshotnote.com")!));linked.show();exportDesignWindow(linked.window!,name:"cloud-connected")
  let hotkeys=Hotkeys();let settings=SettingsController(hotkeys:hotkeys);settings.show();exportDesignWindow(settings.window,name:"settings")
  var signed=cloudVault.value!;signed.ownerID=UUID()
  var cloudTopic=demo;cloudTopic.cloudFolderID=UUID();cloudTopic.cloudOwnerID=signed.ownerID;cloudTopic.cloudOrigin="https://screenshotnote.com";cloudTopic.id="preview-cloud";cloudTopic.name=L("Výzkum uživatelů");cloudTopic.detail=L("Rozhovory a testování s uživateli");cloudTopic.folder="/Users/example/Pictures/Cloud Notes";cloudTopic.combined=true;cloudTopic.combinedFile=language=="en" ? "Research.md":"Vyzkum.md"
  var cloudSeparate=cloudTopic;cloudSeparate.id="preview-cloud-2";cloudSeparate.cloudFolderID=UUID();cloudSeparate.name=L("Sdílené podklady");cloudSeparate.detail="";cloudSeparate.combined=false;cloudSeparate.folder="/Users/example/Pictures/Shared"
  let topics=TopicSettings(connection:{signed});topics.previewDefaultID=demo.id;topics.list=[demo,second,cloudTopic,cloudSeparate];topics.show();topics.folder.stringValue=language=="en" ? "~/Pictures/Screenshot Note/Product":"~/Pictures/Screenshot Note/Produkt";exportDesignWindow(topics.window,name:"configurations")
  topics.editingID=cloudTopic.id;topics.reloadFolders();exportDesignWindow(topics.window,name:"cloud-folders")
  topics.editingID=second.id;topics.reloadFolders();topics.beginNameEdit();exportDesignWindow(topics.window,name:"folder-rename")
  topics.addTopic();exportDesignWindow(topics.window,name:"folder-new")
  _ = MarkdownEditor().run(title:L("Šablona Markdownu"),tabs:[(L("Šablona relace"),defaultMarkdownTemplate,sessionTemplateHint),(L("Šablona souboru"),defaultCombinedTemplate,fileTemplateHint)],apply:L("Použít šablonu"))
  let fileTab=MarkdownEditor();_ = fileTab.run(title:L("Šablona Markdownu"),tabs:[(L("Šablona relace"),defaultMarkdownTemplate,sessionTemplateHint),(L("Šablona souboru"),defaultCombinedTemplate,fileTemplateHint)],apply:L("Použít šablonu"),present:false)
  presentScreenshotPanel(fileTab.window);fileTab.select(1);exportDesignWindow(fileTab.window,name:"template-file-tab");fileTab.window.orderOut(nil)
  let shortcuts=ShortcutSettings(hotkeys:hotkeys);shortcuts.show()
  AboutController.shared.window=nil;AboutController.shared.show();exportDesignWindow(AboutController.shared.window!,name:"about")
  let markdown=MarkdownEditor();_ = markdown.run(language=="en" ? "# Checkout notes\n\nToday’s review highlighted **two important changes**.\n\n- Highlight the selected payment method\n- Shorten the confirmation step\n\n## What to keep\n\nClear pricing and delivery information.\n\n> Make the last step easier to understand.":"# Poznámky k objednávce\n\nZ dnešního průchodu vyplývají **dvě důležité úpravy**.\n\n- Zvýraznit vybranou platební metodu\n- Zkrátit potvrzovací krok\n\n## Co zachovat\n\nPřehlednou cenu a jasné informace o doručení.\n\n> Cílem je méně rozhodování v posledním kroku.")
  let editor=AnnotationEditor();_ = editor.run(url:root.appendingPathComponent("sample-\(language)-0.png"))
  editor.canvas.marks=[Mark(tool:.text,points:[NSPoint(x:300,y:300)],color:.systemRed,width:4,text:L("Poznámka ke snímku"),bold:true,italic:false,underline:false,fontSize:32)];editor.canvas.tool = .text;editor.canvas.choose(0);editor.canvas.startText(0);editor.sync();exportDesignWindow(editor.window,name:"annotation-text")
  editor.canvas.finishText();editor.canvas.marks[0].rotation = .pi/9;editor.canvas.choose(0);exportDesignWindow(editor.window,name:"annotation-transform")
  // Panel komentářů: přehled se seznamem a úprava komentáře tvaru.
  let commented=AnnotationEditor();_ = commented.run(url:root.appendingPathComponent("sample-\(language)-0.png"),caption:L("Poznámka ke snímku"),note:true)
  var box=Mark(tool:.rectangle,points:[NSPoint(x:120,y:160),NSPoint(x:520,y:360)],color:.systemRed,width:4,text:"",bold:false,italic:false,underline:false,fontSize:28);box.comment=language=="en" ? "Wrong alignment of the button":"Špatné zarovnání tlačítka";box.number=1
  var arrow=Mark(tool:.arrow,points:[NSPoint(x:700,y:200),NSPoint(x:900,y:420)],color:.systemBlue,width:4,text:"",bold:false,italic:false,underline:false,fontSize:28);arrow.comment=language=="en" ? "Click here":"Sem klikni";arrow.number=2
  commented.canvas.marks=[box,arrow];commented.canvas.changed?();commented.canvas.choose(nil);exportDesignWindow(commented.window,name:"annotation-comments")
  commented.canvas.choose(0);commented.canvas.startElementNote(0);exportDesignWindow(commented.window,name:"annotation-comment-edit")
  commented.canvas.dropElementField();commented.window.orderOut(nil)
  _ = AnnotationCloseDialog().run()
  composer.collapseCompact();exportDesignWindow(composer.window,name:"compact")
 }
 }
 AppLanguage.override=nil
 NSApp.appearance=nil
 print("Design previews: "+directory.path)
}
