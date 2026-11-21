import AppKit
import Carbon
import CoreGraphics
@testable import ScreenshotNoteKit

// Testovací host: stejné přepínače jako dřív v appce, binárka se do .app nebalí.
// Výstup do roury po řádcích, aby PASS řádky přežily pád testu.
setvbuf(stdout,nil,_IOLBF,0)
// Testy a náhledy pracují s vlastním dočasným indexem.
if CommandLine.arguments.contains(where:{($0.hasSuffix("-test") && $0 != "--preview-test") || $0=="--design-export"}){
 SessionIndex.shared=SessionIndex(file:fm.temporaryDirectory.appendingPathComponent("sn-index-"+UUID().uuidString+".json"))
 TemplateDefaults.shared=TemplateDefaults(store:UserDefaults(suiteName:"sn-test-"+UUID().uuidString)!,connection:{nil})
}
if CommandLine.arguments.contains("--folder-sync-self-test") {
 _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
 // Výstup do roury se hned propisuje a zaseknutý běh skončí čitelnou chybou dřív než timeout volajícího.
 setvbuf(stdout,nil,_IOLBF,0)
 DispatchQueue.global().asyncAfter(deadline:.now()+75){fputs("Cloud folder sync test timed out after 75 s.\n",stderr);exit(1)}
 Task{@MainActor in do{try await cloudFolderSyncTests();exit(0)}catch{fputs("Cloud folder sync test failed: \(error)\n",stderr);exit(1)}}
 dispatchMain()
}

if CommandLine.arguments.contains("--folder-transfer-self-test") {
 _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
 Task{@MainActor in do{try await folderTransferTests();exit(0)}catch{fputs("Folder transfer test failed: \(error)\n",stderr);exit(1)}}
 dispatchMain()
}

if CommandLine.arguments.contains("--bridge-self-test") {
 _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
 Task{do{try await browserBridgeTests();exit(0)}catch{fputs("Browser bridge test failed: \(error)\n",stderr);exit(1)}}
 dispatchMain()
}

if CommandLine.arguments.contains("--context-self-test") {
 _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
 Task{@MainActor in do{try await captureContextTests();try elementMappingTests();print("Capture context self-test passed");exit(0)}catch{fputs("Capture context test failed: \(error)\n",stderr);exit(1)}}
 dispatchMain()
}

if CommandLine.arguments.contains("--cloud-self-test") {
 _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
 Task { @MainActor in
  do { try await cloudIntegrationTest();exit(0) }
  catch { fputs("Native REST integration failed: \(error)\n",stderr);exit(1) }
 }
 dispatchMain()
}

if CommandLine.arguments.contains("--self-test") {
 try cloudUnitTests()
 try serverMarkdownTests()
 let interactiveUITests=CommandLine.arguments.contains("--interactive-ui-tests")
 _ = NSApplication.shared;NSApp.setActivationPolicy(interactiveUITests ? .accessory:.prohibited)
 AppLanguage.override="cs"
 let root=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 var draft=Draft(images:[],comment:"Český komentář\nDruhý řádek",title:"Můj nadpis")
 for n in 1...5{let name="\(n).png";try Data([UInt8(n)]).write(to:root.appendingPathComponent(name));draft.images.append(name);try stage(draft,root:root);let loaded=try readDraft(root);assert(loaded.images.count == n && loaded.title == "Můj nadpis")}
 let dest=root.appendingPathComponent("output");try finish(draft,root:root,dest:dest)
 let md=try fm.contentsOfDirectory(at:dest,includingPropertiesForKeys:nil).first{$0.pathExtension == "md"}!
 let content=try String(contentsOf:md,encoding:.utf8);assert(content.contains("# Můj nadpis\n\n# Screenshots\n"));assert(content.contains("# Description\n\nČeský komentář"));assert(content.components(separatedBy:"](<assets/").count == 6 && content.contains("![Screenshot 1](<assets/") && !content.contains("![[assets/"))
 let empty=try readDraft(root);assert(empty.images.isEmpty)
 // Old drafts without a title remain readable.
 try Data("{\"images\":[],\"comment\":\"původní\"}".utf8).write(to:root.appendingPathComponent("draft.json"));let old=try readDraft(root);assert(old.title == nil)
 let image=NSImage(size:NSSize(width:600,height:400));image.lockFocus();NSColor.white.setFill();NSRect(x:0,y:0,width:600,height:400).fill();image.unlockFocus()
 let drawing=DrawingView(image:image,frame:NSRect(x:0,y:0,width:600,height:400))
 for tool in [Tool.arrow,.ellipse,.rectangle,.pen,.text]{drawing.marks.append(Mark(tool:tool,points:[NSPoint(x:20,y:20),NSPoint(x:200,y:180)],color:.red,width:6,text:"Text",bold:true,italic:true,underline:true,fontSize:28))}
 let data=drawing.png()!;let output=NSBitmapImageRep(data:data)!;assert(output.pixelsWide == 600 && output.pixelsHigh == 400)
 let markdown=LiveMarkdownView(frame:NSRect(x:0,y:0,width:600,height:400))
 let raw="# Nadpis\n\n**Tučný** a *kurzíva*\n\n- seznam\n\n```\n# kód\n```"
 markdown.string=raw;markdown.renderMarkdown();assert(markdown.string == raw)
 let headingFont=markdown.textStorage!.attribute(.font,at:2,effectiveRange:nil) as! NSFont;assert(headingFont.pointSize == 30)
 let boldRange=(raw as NSString).range(of:"Tučný");let boldFont=markdown.textStorage!.attribute(.font,at:boldRange.location,effectiveRange:nil) as! NSFont;assert(NSFontManager.shared.traits(of:boldFont).contains(.boldFontMask))
 markdown.setSelectedRange(NSRange(location:2,length:6));markdown.renderMarkdown();assert(markdown.selectedRange() == NSRange(location:2,length:6))
 // Run the actual link/code toolbar actions and force TextKit layout and drawing after each.
 let markdownPanel=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:650,height:300),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);markdownPanel.isReleasedWhenClosed=false
 let formattingView=LiveMarkdownView(frame:NSRect(x:0,y:0,width:650,height:300));formattingView.wantsLayer=true;markdownPanel.contentView!.addSubview(formattingView)
 let formattingEditor=MarkdownEditor();formattingEditor.window=markdownPanel;formattingEditor.text=formattingView
 let samples=["", "Plain text", "Příliš žluťoučký kůň 😀", "# Heading\n\nExisting `code` and [link](https://example.com)"]
 for (tag,prefix,suffix) in [(4,"[","](https://)"),(5,"`","`")]{
  for source in samples{
   let length=(source as NSString).length
   for selection in [NSRange(location:length,length:0),NSRange(location:0,length:length)]{
    formattingView.string=source;formattingView.renderMarkdown();formattingView.setSelectedRange(selection);markdownPanel.makeFirstResponder(formattingView)
    let selected=(source as NSString).substring(with:selection);let inserted=selected.isEmpty ? "text":selected
    let expected=(source as NSString).replacingCharacters(in:selection,with:prefix+inserted+suffix)
    let button=NSButton(title:"",target:formattingEditor,action:#selector(MarkdownEditor.format));button.tag=tag;button.performClick(nil)
    assert(formattingView.string==expected && formattingView.selectedRange()==NSRange(location:selection.location+prefix.utf16.count,length:inserted.utf16.count))
    formattingView.layoutManager!.ensureLayout(for:formattingView.textContainer!);_ = formattingView.layoutManager!.glyphRange(forCharacterRange:NSRange(location:0,length:(expected as NSString).length),actualCharacterRange:nil)
    let rep=formattingView.bitmapImageRepForCachingDisplay(in:formattingView.bounds)!;formattingView.cacheDisplay(in:formattingView.bounds,to:rep)
    let retainedSelection=formattingView.selectedRange();for _ in 0..<3{formattingView.renderMarkdown();assert(formattingView.selectedRange()==retainedSelection && formattingView.string==expected)}
   }
  }
 }
 // Format only the UTF-16 range containing an emoji, preserving surrounding characters.
 formattingView.string="A 😀 B";formattingView.renderMarkdown();formattingView.setSelectedRange((formattingView.string as NSString).range(of:"😀"));formattingView.wrap("`","`");assert(formattingView.string=="A `😀` B" && formattingView.selectedRange().length==2)
 print("PASS: link/code toolbar actions, empty and selected content, Unicode ranges, glyph layout and native drawing")
 installEditingMenu()
 let selectAll=NSApp.mainMenu!.items[1].submenu!.items.last!
 assert(selectAll.keyEquivalent == "a" && selectAll.action == NSSelectorFromString("selectAll:") && selectAll.target == nil)
 markdown.selectAll(nil);assert(markdown.selectedRange().length == (markdown.string as NSString).length)
 let rectangle=Mark(tool:.rectangle,points:[NSPoint(x:50,y:50),NSPoint(x:250,y:200)],color:.blue,width:4,text:"",bold:false,italic:false,underline:false,fontSize:28)
 drawing.marks=[rectangle];assert(drawing.tool == .select);assert(drawing.hit(NSPoint(x:50,y:100)) == 0)
 drawing.choose(0);drawing.color = .green;drawing.thickness=10;drawing.updateSelected();assert(drawing.marks[0].width == 10)
 drawing.delete(nil);assert(drawing.marks.isEmpty);drawing.undoChange();assert(drawing.marks.count == 1)
 drawing.applyCrop(NSRect(x:20,y:20,width:300,height:200));let crop=NSBitmapImageRep(data:drawing.png()!)!;assert(crop.pixelsWide == 300 && crop.pixelsHigh == 200);drawing.undoChange();assert(drawing.viewport.width == 600)
 let document=AnnotationDocument(base:data,marks:drawing.marks,crop:drawing.viewport)
 let decoded=try JSONDecoder().decode(AnnotationDocument.self,from:JSONEncoder().encode(document));assert(decoded.marks.count == 1 && decoded.marks[0].width == 10)
 let a=root.appendingPathComponent("side-a.png"),b=root.appendingPathComponent("side-b.png");try JSONEncoder().encode(document).write(to:annotationSidecar(a));try copyAnnotationSidecar(from:a,to:b);assert(fm.fileExists(atPath:annotationSidecar(b).path));removeAnnotatedImage(b);assert(!fm.fileExists(atPath:annotationSidecar(b).path))
 let portrait=annotationWindowSize(image:NSSize(width:600,height:1200),available:NSSize(width:1440,height:900))
 let landscape=annotationWindowSize(image:NSSize(width:1600,height:600),available:NSSize(width:1440,height:900))
 assert(portrait.width < landscape.width && portrait.height > landscape.height)
 assert(portrait.width >= 620 && landscape.width <= 1380 && portrait.height <= 815)
 // Exercise mouse delivery and the actual formatting actions, not only model setters.
 let canvasPanel=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:620,height:420),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);canvasPanel.isReleasedWhenClosed=false
 let interactive=DrawingView(image:image,frame:NSRect(x:0,y:0,width:600,height:400));canvasPanel.contentView!.addSubview(interactive)
 assert(!interactive.mouseDownCanMoveWindow && canvasPanel.isMovableByWindowBackground)
 func canvasEvent(_ type:NSEvent.EventType,_ point:NSPoint)->NSEvent{NSEvent.mouseEvent(with:type,location:interactive.convert(point,to:nil),modifierFlags:[],timestamp:0,windowNumber:canvasPanel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
 for tool in [Tool.pen,.arrow,.ellipse,.rectangle,.crop]{
  interactive.marks=[];interactive.viewport=NSRect(x:0,y:0,width:600,height:400);interactive.choose(nil);interactive.tool=tool
  assert(interactive.toolCursor === NSCursor.crosshair)
  let frame=canvasPanel.frame
  interactive.mouseDown(with:canvasEvent(.leftMouseDown,NSPoint(x:90,y:100)));interactive.mouseDragged(with:canvasEvent(.leftMouseDragged,NSPoint(x:210,y:180)));interactive.mouseUp(with:canvasEvent(.leftMouseUp,NSPoint(x:210,y:180)))
  assert(canvasPanel.frame==frame && interactive.tool == .select)
  if tool == .crop{assert(interactive.viewport.width==120 && interactive.viewport.height==80)}else{assert(interactive.marks.count==1 && interactive.marks[0].points.first==NSPoint(x:90,y:100) && interactive.marks[0].points.last==NSPoint(x:210,y:180))}
 }
 func redInkBounds(_ view:NSView,_ label:String)->NSRect{
  view.layoutSubtreeIfNeeded();view.displayIfNeeded();let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:rep)
  try? rep.representation(using:.png,properties:[:])!.write(to:fm.temporaryDirectory.appendingPathComponent("annotation-qa-"+label+".png"))
  var minX=rep.pixelsWide,minY=rep.pixelsHigh,maxX=0,maxY=0
  for x in 0..<rep.pixelsWide{for y in 0..<rep.pixelsHigh{let c=rep.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!;if c.redComponent>0.7 && c.greenComponent<0.35 && c.blueComponent<0.35{minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}}}
  assert(maxX>minX && maxY>minY);return NSRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1)
 }
 let transformCanvas=DrawingView(image:image,frame:NSRect(x:0,y:0,width:600,height:400));canvasPanel.contentView!.addSubview(transformCanvas)
 transformCanvas.marks=[rectangle];transformCanvas.choose(0)
 func transformEvent(_ type:NSEvent.EventType,_ p:NSPoint)->NSEvent{NSEvent.mouseEvent(with:type,location:transformCanvas.convert(p,to:nil),modifierFlags:[],timestamp:0,windowNumber:canvasPanel.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!}
 let corner=transformCanvas.selectionCorners(rectangle)[2]
 transformCanvas.mouseDown(with:transformEvent(.leftMouseDown,corner));transformCanvas.mouseDragged(with:transformEvent(.leftMouseDragged,NSPoint(x:corner.x+100,y:corner.y+75)));transformCanvas.mouseUp(with:transformEvent(.leftMouseUp,NSPoint(x:corner.x+100,y:corner.y+75)))
 assert(abs(transformCanvas.marks[0].bounds.width-300)<0.001 && abs(transformCanvas.marks[0].bounds.height-225)<0.001)
 transformCanvas.undoChange();assert(transformCanvas.marks[0].bounds==rectangle.bounds);transformCanvas.choose(0)
 let knob=transformCanvas.rotationHandle(rectangle),center=NSPoint(x:rectangle.bounds.midX,y:rectangle.bounds.midY),rotatedKnob=NSPoint(x:center.x-(knob.y-center.y),y:center.y+(knob.x-center.x))
 transformCanvas.mouseDown(with:transformEvent(.leftMouseDown,knob));transformCanvas.mouseDragged(with:transformEvent(.leftMouseDragged,rotatedKnob));transformCanvas.mouseUp(with:transformEvent(.leftMouseUp,rotatedKnob))
 assert(abs(transformCanvas.marks[0].rotation - .pi/2)<0.001)
 let rotatedEdge=transformCanvas.marks[0].rotatedPoint(NSPoint(x:rectangle.bounds.minX,y:rectangle.bounds.midY));assert(transformCanvas.hit(rotatedEdge)==0)
 let rotatedMark=transformCanvas.marks[0],fixed=rotatedMark.rotatedPoint(rotatedMark.corners[0]),scaled=rotatedMark.resized(by:1.5,fixedCorner:0),scaledFixed=scaled.rotatedPoint(scaled.corners[0])
 assert(hypot(fixed.x-scaledFixed.x,fixed.y-scaledFixed.y)<0.001 && abs(scaled.bounds.width-300)<0.001)
 transformCanvas.undoChange();assert(transformCanvas.marks[0].rotation==0)
 // Legacy sidecars omit rotation; new ones preserve transformations.
 var legacyMark=try JSONSerialization.jsonObject(with:JSONEncoder().encode(rectangle)) as! [String:Any];legacyMark.removeValue(forKey:"rotation")
 let migrated=try JSONDecoder().decode(Mark.self,from:JSONSerialization.data(withJSONObject:legacyMark));assert(migrated.rotation==0)
 let closeEditor=AnnotationEditor();closeEditor.canvas=transformCanvas;closeEditor.recordInitialState();var asked=0
 assert(closeEditor.requestedCloseChoice(confirm:{asked+=1;return .save}) == .discard && asked==0)
 transformCanvas.marks[0].rotation = .pi/2
 assert(closeEditor.hasUnsavedChanges && closeEditor.requestedCloseChoice(confirm:{asked+=1;return .cancel}) == .cancel && asked==1)
 assert(closeEditor.requestedCloseChoice(confirm:{.save}) == .save && closeEditor.requestedCloseChoice(confirm:{.discard}) == .discard)
 let cleanPNG=NSBitmapImageRep(data:image.tiffRepresentation!)!.representation(using:.png,properties:[:])!
 let transformedFile=root.appendingPathComponent("transformed.png");try cleanPNG.write(to:transformedFile);closeEditor.baseData=cleanPNG;closeEditor.workingURL=transformedFile
 // Force sidecar write failure after PNG creation; the original PNG must be restored.
 try fm.createDirectory(at:annotationSidecar(transformedFile),withIntermediateDirectories:true)
 do{try closeEditor.saveWorkingImage();assertionFailure("Sidecar directory should reject file write")}catch{}
 let rolledBack=try Data(contentsOf:transformedFile);assert(rolledBack==cleanPNG && closeEditor.hasUnsavedChanges)
 try fm.removeItem(at:annotationSidecar(transformedFile))
 try closeEditor.saveWorkingImage()
 let transformedDoc=try JSONDecoder().decode(AnnotationDocument.self,from:Data(contentsOf:annotationSidecar(transformedFile)));assert(abs(transformedDoc.marks[0].rotation - .pi/2)<0.001)
 closeEditor.recordInitialState();assert(!closeEditor.hasUnsavedChanges)
 transformCanvas.applyCrop(NSRect(x:20,y:20,width:300,height:200));assert(closeEditor.hasUnsavedChanges);transformCanvas.undoChange();assert(!closeEditor.hasUnsavedChanges)
 transformCanvas.marks=[Mark(tool:.text,points:[NSPoint(x:180,y:170)],color:.red,width:4,text:"Rotate text",bold:false,italic:false,underline:false,fontSize:28,rotation:.pi/6)];transformCanvas.choose(0)
 let rotatedInactive=redInkBounds(transformCanvas,"rotated-inactive");transformCanvas.startText(0);canvasPanel.makeFirstResponder(nil);let rotatedActive=redInkBounds(transformCanvas,"rotated-active")
 print("Rotated text: inactive=\(rotatedInactive) active=\(rotatedActive)");fflush(stdout)
 assert(abs(rotatedInactive.minX-rotatedActive.minX)<=2 && abs(rotatedInactive.minY-rotatedActive.minY)<=2 && abs(rotatedInactive.width-rotatedActive.width)<=2 && abs(rotatedInactive.height-rotatedActive.height)<=2)
 transformCanvas.finishText()
 let textBefore=transformCanvas.marks[0],textCorners=transformCanvas.selectionCorners(textBefore)
 let textCorner=textCorners[1]
 for index in [0,2,3]{assert(transformCanvas.transformHandle(at:textCorners[index],for:textBefore)==nil)}
 let narrowPoint=NSPoint(x:textCorner.x-80*cos(textBefore.rotation),y:textCorner.y-80*sin(textBefore.rotation))
 transformCanvas.mouseDown(with:transformEvent(.leftMouseDown,textCorner))
 transformCanvas.mouseDragged(with:transformEvent(.leftMouseDragged,narrowPoint))
 transformCanvas.mouseUp(with:transformEvent(.leftMouseUp,narrowPoint))
 let narrow=transformCanvas.marks[0]
 assert(narrow.fontSize==textBefore.fontSize && narrow.rotation==textBefore.rotation && narrow.bounds.height>textBefore.bounds.height)
 let anchor=textBefore.rotatedPoint(textBefore.corners[3]),narrowAnchor=narrow.rotatedPoint(narrow.corners[3])
 assert(hypot(anchor.x-narrowAnchor.x,anchor.y-narrowAnchor.y)<0.001)
 let wide=narrow.resizingText(by:NSPoint(x:250-narrow.bounds.width,y:0))
 let decodedText=try JSONDecoder().decode(Mark.self,from:JSONEncoder().encode(wide))
 assert(decodedText.textWidth==250 && decodedText.fontSize==narrow.fontSize && decodedText.bounds.height<narrow.bounds.height)
 transformCanvas.marks[0]=wide
 let bottomRight=transformCanvas.selectionCorners(wide)[1]
 let down=NSPoint(x:bottomRight.x+60*sin(wide.rotation),y:bottomRight.y-60*cos(wide.rotation))
 transformCanvas.mouseDown(with:transformEvent(.leftMouseDown,bottomRight))
 transformCanvas.mouseDragged(with:transformEvent(.leftMouseDragged,down))
 transformCanvas.mouseUp(with:transformEvent(.leftMouseUp,down))
 let tall=transformCanvas.marks[0],tallAnchor=tall.rotatedPoint(tall.corners[3])
 assert(abs(tall.bounds.height-wide.bounds.height-60)<0.001 && abs(tall.bounds.width-wide.bounds.width)<0.001)
 assert(hypot(anchor.x-tallAnchor.x,anchor.y-tallAnchor.y)<0.001 && tall.fontSize==wide.fontSize)
 let decodedTall=try JSONDecoder().decode(Mark.self,from:JSONEncoder().encode(tall))
 assert(decodedTall.bounds==tall.bounds)
 transformCanvas.undoChange()
 transformCanvas.undoChange();assert(transformCanvas.marks[0].textWidth==nil)
 print("PASS: text box wrapping, unchanged font size, rotated corner anchoring, persistence and undo")
 transformCanvas.removeFromSuperview()
 print("PASS: corner resizing, rotation handle, rotated hit testing, undo, saved transforms, legacy migration and dirty-close decisions")
 for factor in [CGFloat(1),0.5]{
  interactive.viewport=NSRect(x:0,y:0,width:600,height:400);interactive.frame.size=NSSize(width:600*factor,height:400*factor)
  interactive.marks=[Mark(tool:.text,points:[NSPoint(x:120,y:140)],color:.red,width:4,text:"Hgj Text",bold:false,italic:false,underline:false,fontSize:28)];interactive.tool = .text;interactive.choose(0)
  assert(interactive.toolCursor === NSCursor.iBeam)
  let inactive=redInkBounds(interactive,"inactive-\(factor)")
  interactive.startText(0);canvasPanel.makeFirstResponder(interactive)
  assert(interactive.inline != nil && !interactive.inline!.drawsBackground && !interactive.inline!.mouseDownCanMoveWindow && interactive.inline!.textContainerInset == .zero)
  let active=redInkBounds(interactive,"active-\(factor)")
  print("Text geometry \(factor): inactive=\(inactive) active=\(active)");fflush(stdout)
  assert(abs(inactive.minX-active.minX)<=2 && abs(inactive.minY-active.minY)<=2 && abs(inactive.width-active.width)<=2 && abs(inactive.height-active.height)<=2)
  let editor=AnnotationEditor();editor.canvas=interactive;editor.width=AnnotationToolButton();editor.size=AnnotationToolButton()
  for index in 0..<3{let button=AnnotationToolButton();button.tag=index;button.setButtonType(.toggle);button.target=editor;button.action=#selector(AnnotationEditor.changeText(_:));editor.styleButtons.append(button)}
  editor.window=canvasPanel;editor.size.frame=NSRect(x:16,y:380,width:36,height:34);editor.width.frame=NSRect(x:60,y:380,width:36,height:34);canvasPanel.contentView!.addSubview(editor.size);canvasPanel.contentView!.addSubview(editor.width)
  // Activate the real value buttons inside nested AppKit modal loops.
  // performClick avoids relying on the physical mouse location for offscreen controls.
  var pickerClicked=false
  editor.onValuePickerPresented={popup,buttons in
   popup.setFrameOrigin(NSPoint(x:-10000,y:-10000))
   let button=buttons[4]
   let click=Timer(timeInterval:0.05,repeats:false){_ in
    button.performClick(nil)
    pickerClicked=true
   };RunLoop.main.add(click,forMode:.modalPanel)
  }
  if interactiveUITests{
  let exercise=Timer(timeInterval:0.05,repeats:false){_ in editor.sizeMenu();NSApp.stopModal()};RunLoop.main.add(exercise,forMode:.modalPanel)
  let timeout=Timer(timeInterval:3,repeats:false){_ in NSApp.abortModal()};RunLoop.main.add(timeout,forMode:.modalPanel)
  canvasPanel.makeFirstResponder(nil);canvasPanel.setFrameOrigin(NSPoint(x:-11000,y:-11000));NSApp.runModal(for:canvasPanel);canvasPanel.orderOut(nil);timeout.invalidate()
  assert(pickerClicked && interactive.marks[0].fontSize==48 && interactive.inline!.font!.pointSize==48)
  }else{interactive.fontSize=48;interactive.updateSelected();editor.sync()}
  editor.styleButtons[0].performClick(nil)
  assert(interactive.marks[0].bold && NSFontManager.shared.traits(of:interactive.inline!.font!).contains(.boldFontMask))
  editor.styleButtons[1].performClick(nil);editor.styleButtons[2].performClick(nil);assert(interactive.marks[0].italic && interactive.marks[0].underline)
  let styledActive=redInkBounds(interactive,"styled-active-\(factor)")
  interactive.finishText();assert(interactive.marks[0].text=="Hgj Text" && interactive.marks[0].fontSize==48 && interactive.tool == .select)
  let styledInactive=redInkBounds(interactive,"styled-inactive-\(factor)")
  assert(abs(styledActive.minX-styledInactive.minX)<=2 && abs(styledActive.minY-styledInactive.minY)<=2 && abs(styledActive.width-styledInactive.width)<=2 && abs(styledActive.height-styledInactive.height)<=2)
  let strokeCanvas=DrawingView(image:image,frame:NSRect(x:0,y:0,width:600,height:400));canvasPanel.contentView!.addSubview(strokeCanvas);strokeCanvas.marks=[rectangle];strokeCanvas.choose(0);editor.canvas=strokeCanvas;editor.sync();pickerClicked=false;canvasPanel.makeFirstResponder(nil)
  if interactiveUITests{
  let widthExercise=Timer(timeInterval:0.05,repeats:false){_ in editor.widthMenu();NSApp.stopModal()};RunLoop.main.add(widthExercise,forMode:.modalPanel)
  let widthTimeout=Timer(timeInterval:3,repeats:false){_ in NSApp.abortModal()};RunLoop.main.add(widthTimeout,forMode:.modalPanel)
  NSApp.runModal(for:canvasPanel);canvasPanel.orderOut(nil);widthTimeout.invalidate()
  assert(pickerClicked && strokeCanvas.marks.first?.width==10 && strokeCanvas.thickness==10)  }else{strokeCanvas.thickness=10;strokeCanvas.updateSelected();assert(strokeCanvas.marks.first?.width==10)}
  strokeCanvas.removeFromSuperview()

 }
 print("PASS: drawing/crop mouse interaction, tool cursors, transparent inline text alignment, formatting actions (modal UI tests run only with --interactive-ui-tests)")
 print("PASS: image-dependent editor dimensions and screen limits")
 print("PASS: object selection, properties, deletion, undo, crop dimensions and editable annotation persistence")
 print("PASS: Select All responder command and editing menu shortcut")
 print("PASS: live Markdown headings, bold text, source and selection preserved")
 assert(filenameFromTitle("Příliš žluťoučký kůň") == "Prilis zlutoucky kun")
 assert(filenameFromTitle("   ") == nil)
 assert(filenameFromTitle("../A/B") == "_A_B")
 let namingRoot=root.appendingPathComponent("naming");try fm.createDirectory(at:namingRoot,withIntermediateDirectories:true)
 let namingDest=namingRoot.appendingPathComponent("output")
 for count in [1,1,2,2] {
  var names:[String]=[]
  for i in 0..<count {let filename="source_\(i).png";try Data([UInt8(count)]).write(to:namingRoot.appendingPathComponent(filename));names.append(filename)}
  try finish(Draft(images:names,comment:"Test",title:"Český nadpis"),root:namingRoot,dest:namingDest)
 }
 let readable=readableSessionName("Český nadpis",created:Date())
 for filename in [readable+".md",readable+" 2.md",readable+" 3.md",readable+" 4.md"] {assert(fm.fileExists(atPath:namingDest.appendingPathComponent(filename).path))}
 let expectedImages=[readable+"-1.png",readable+" 2-1.png",readable+" 3-1.png",readable+" 3-2.png",readable+" 4-1.png",readable+" 4-2.png"]
 for filename in expectedImages {assert(fm.fileExists(atPath:namingDest.appendingPathComponent("assets").appendingPathComponent(filename).path))}
 let collisionMD=try String(contentsOf:namingDest.appendingPathComponent(readable+" 4.md"),encoding:.utf8)
 assert(collisionMD.contains("assets/"+readable+" 4-1.png") && collisionMD.contains("assets/"+readable+" 4-2.png"))
 print("PASS: title filenames, diacritics, unsafe characters, single/multiple images and independent collisions")
 let topicRoot=root.appendingPathComponent("topic-sessions");try fm.createDirectory(at:topicRoot,withIntermediateDirectories:true)
 let topicDest=topicRoot.appendingPathComponent("chosen-folder")
 let topic=Topic(id:"test",name:"Testovací téma",detail:"Popis",folder:topicDest.path,combined:true,combinedFile:"Spolecny.md")
 try fm.createDirectory(at:topicDest,withIntermediateDirectories:true)
 try Data("# Původní obsah\n".utf8).write(to:topicDest.appendingPathComponent("Spolecny.md"))
 for count in [1,2] {
  var names:[String]=[]
  for i in 0..<count{let name="topic-\(i).png";names.append(name);try Data([UInt8(count)]).write(to:topicRoot.appendingPathComponent(name))}
  let session=Draft(images:names,comment:"Relace \(count)",title:"Nadpis",topic:topic)
  try stage(session,root:topicRoot);let reloaded=try readDraft(topicRoot);assert(reloaded.topic == topic)
  try finishSession(reloaded,root:topicRoot)
 }
 let aggregate=try String(contentsOf:topicDest.appendingPathComponent("Spolecny.md"),encoding:.utf8)
 assert(aggregate.hasPrefix("# Původní obsah") && aggregate.contains("Relace 1") && aggregate.contains("Relace 2"))
 let aggregateFiles=try fm.contentsOfDirectory(at:topicDest,includingPropertiesForKeys:nil);assert(aggregateFiles.filter{$0.pathExtension=="md"}.count==1)
 assert(aggregate.components(separatedBy:"](<assets/").count==4)
 var separate=topic;separate.combined=false;separate.folder=topicRoot.appendingPathComponent("separate").path
 for _ in 0..<2{try Data([1]).write(to:topicRoot.appendingPathComponent("one.png"));try finishSession(Draft(images:["one.png"],comment:"",title:"Stejný",topic:separate),root:topicRoot)}
 let separateFiles=try fm.contentsOfDirectory(atPath:separate.folder);let same=readableSessionName("Stejný",created:Date());assert(separateFiles.contains(same+".md") && separateFiles.contains(same+" 2.md"))
 let deleteRoot=topicRoot.appendingPathComponent("deletion");try fm.createDirectory(at:deleteRoot,withIntermediateDirectories:true)
 for name in ["a.png","b.png"]{try Data([1]).write(to:deleteRoot.appendingPathComponent(name));try Data([2]).write(to:annotationSidecar(deleteRoot.appendingPathComponent(name)))}
 let compose=Composer(draft:Draft(images:["a.png","b.png"],comment:"Zachovat",title:"Nadpis",topic:topic),root:deleteRoot)
 let remove=NSButton();remove.tag=0;compose.removeImage(remove)
 assert(compose.draft.images==["b.png"] && compose.draft.topic==topic && compose.draft.comment=="Zachovat")
 assert(!fm.fileExists(atPath:deleteRoot.appendingPathComponent("a.png").path) && !fm.fileExists(atPath:annotationSidecar(deleteRoot.appendingPathComponent("a.png")).path))
 let imageBeforeNote=try Data(contentsOf:deleteRoot.appendingPathComponent("b.png"))
 compose.setImageNote("# Per-image note\n**Detail**",for:"b.png")
 assert(compose.draft.imageNotes?["b.png"]=="# Per-image note\n**Detail**")
 let imageAfterNote=try Data(contentsOf:deleteRoot.appendingPathComponent("b.png"));assert(imageBeforeNote==imageAfterNote)
 let thumbnail=compose.buttons[0] as! ScreenshotThumbnailButton
 let hoverActions=thumbnail.subviews.compactMap{$0 as? ThumbnailActionButton}
 assert(hoverActions.count==2)
 let annotate=hoverActions[0],note=hoverActions[1]
 assert(annotate.isHidden && note.isHidden)
 assert(annotate.frame.minY==note.frame.maxY && annotate.frame.width==note.frame.width && annotate.frame.height==note.frame.height)
 assert(thumbnail.notePreview.stringValue=="# Per-image note **Detail**" && thumbnail.notePreview.lineBreakMode == .byTruncatingTail && thumbnail.notePreview.maximumNumberOfLines==1)
 thumbnail.setHovered(true);assert(!annotate.isHidden)
 assert(annotate.action == #selector(Composer.edit) && note.action == #selector(Composer.editImageNote))
 annotate.setExpanded(true,animated:false)
 assert(annotate.expandedTitle==L("Anotace") && note.expandedTitle==L("Poznámka") && annotate.frame==annotate.collapsedFrame && annotate.overlayOpacity>note.overlayOpacity)
 let notePoint=thumbnail.convert(NSPoint(x:note.frame.midX,y:note.frame.midY),to:thumbnail.superview)
 assert(thumbnail.hitTest(notePoint) === note)
 thumbnail.setHovered(false);assert(annotate.isHidden && note.isHidden && annotate.frame==annotate.collapsedFrame)
 compose.setImageNote("",for:"b.png");assert(compose.draft.imageNotes?["b.png"]==nil)
 print("PASS: thumbnail hover actions and per-image notes independent of PNG editing")

 compose.removeImage(remove);assert(compose.draft.images.isEmpty && !compose.saveButton.isEnabled && compose.addShotButton.isEnabled)
 let shortcut=Shortcut(key:21,modifiers:UInt32(controlKey|optionKey|shiftKey),name:"4")
 func shortcutEvent(_ key:UInt16,_ flags:NSEvent.ModifierFlags)->NSEvent {
  NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"4",charactersIgnoringModifiers:"4",isARepeat:false,keyCode:key)!
 }
 assert(shortcut.matches(shortcutEvent(21,[.control,.option,.shift,.capsLock])))
 assert(!shortcut.matches(shortcutEvent(21,[.control,.option])))
 assert(!shortcut.matches(shortcutEvent(21,[.control,.option,.shift,.command])))
 assert(!shortcut.matches(shortcutEvent(20,[.control,.option,.shift])))
 let hotkeyProbe=Hotkeys();var triggered:[Int]=[];hotkeyProbe.callback={triggered.append($0)}
 assert(hotkeyProbe.trigger(1,at:10));assert(!hotkeyProbe.trigger(1,at:10.05))
 assert(hotkeyProbe.trigger(2,at:10.1));assert(hotkeyProbe.trigger(1,at:10.4));assert(triggered==[1,2,1])
 let captureProbe=Composer(draft:Draft(images:[],comment:"",title:"",topic:topic),root:deleteRoot);captureProbe.show(present:false)
 assert(captureProbe.topicLink.superview != nil && captureProbe.addShotButton.superview != nil)
 assert(captureProbe.sessionLink.superview == nil && captureProbe.laterButton.superview == nil)
 assert(captureProbe.copyLinkButton.superview != nil && captureProbe.copyLinkButton.isHidden && captureProbe.shareableSessionID() == nil)
 // Viditelné tlačítko se nepřekrývá s konfigurací, odkazem relace ani snímáním.
 captureProbe.copyLinkButton.isHidden=false;captureProbe.layoutContextRow()
 assert(!captureProbe.copyLinkButton.frame.intersects(captureProbe.topicLink.frame) && !captureProbe.copyLinkButton.frame.intersects(captureProbe.captureGroup.frame))
 captureProbe.window.contentView!.addSubview(captureProbe.sessionLink);captureProbe.layoutContextRow()
 assert(!captureProbe.copyLinkButton.frame.intersects(captureProbe.sessionLink.frame) && !captureProbe.copyLinkButton.frame.intersects(captureProbe.captureGroup.frame))
 captureProbe.sessionLink.removeFromSuperview()
 assert(captureProbe.addShotButton.isEnabled && !captureProbe.saveButton.isEnabled)
 captureProbe.window.close()
 print("PASS: capture controls without session picker, exact shortcut matching and duplicate hotkey suppression")
 // Zrušit s neuloženou prací se ptá; Odložit uloží koncept, Zahodit zahodí, Pokračovat nechá okno otevřené.
 let cancelRoot=root.appendingPathComponent("cancel");try fm.createDirectory(at:cancelRoot,withIntermediateDirectories:true);try Data([9]).write(to:cancelRoot.appendingPathComponent("c.png"))
 let unsaved=Draft(images:["c.png"],comment:"Text",title:"Neuloženo",topic:topic)
 let cancelProbe=Composer(draft:unsaved,root:cancelRoot);cancelProbe.show(present:false)
 let pristine=draftSignature(Draft(images:[],comment:"",topic:topic),root:cancelRoot)
 cancelProbe.hasUnsavedWork={draftSignature(cancelProbe.draft,root:cancelRoot) != pristine}
 assert(cancelProbe.requestedCancel(confirm:{.keep})==nil && cancelProbe.requestedCancel(confirm:{.later})==1 && cancelProbe.requestedCancel(confirm:{.discard})==0)
 let openedSignature=draftSignature(unsaved,root:cancelRoot);cancelProbe.hasUnsavedWork={draftSignature(cancelProbe.draft,root:cancelRoot) != openedSignature}
 assert(cancelProbe.requestedCancel(confirm:{assertionFailure("Unchanged draft asked");return .keep})==0)
 try Data([10]).write(to:cancelRoot.appendingPathComponent("c.png"));assert(cancelProbe.requestedCancel(confirm:{.keep})==nil)
 cancelProbe.window.close()
 // Záloha po snímku se při dalším spuštění vrátí jako rozpracovaná poznámka.
 let recoveryProbe=AppDelegate(),recovered=root.appendingPathComponent("recovery"),storage=root.appendingPathComponent("storage")
 try recoveryProbe.persist(unsaved,root:cancelRoot,to:recovered)
 let didRestore=try recoveryProbe.restoreRecoveredDraft(from:recovered,to:storage);assert(didRestore && !fm.fileExists(atPath:recovered.path))
 let restoredDraft=try readDraft(storage);assert(restoredDraft.images.count==1 && restoredDraft.title=="Neuloženo" && restoredDraft.comment=="Text")
 let again=try recoveryProbe.restoreRecoveredDraft(from:recovered,to:storage);assert(!again)
 // Novější uložený koncept má přednost před starší zálohou, záloha se zahodí.
 var newer=unsaved;newer.title="Novější";try recoveryProbe.persist(unsaved,root:cancelRoot,to:recovered);try recoveryProbe.persist(newer,root:cancelRoot,to:storage)
 try fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-60)],ofItemAtPath:recovered.appendingPathComponent("draft.json").path)
 let staleBackup=try recoveryProbe.restoreRecoveredDraft(from:recovered,to:storage);assert(!staleBackup && (try! readDraft(storage)).title=="Novější" && !fm.fileExists(atPath:recovered.path))
 try recoveryProbe.persist(unsaved,root:cancelRoot,to:recovered)
 try fm.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-120)],ofItemAtPath:storage.appendingPathComponent("draft.json").path)
 let fresher=try recoveryProbe.restoreRecoveredDraft(from:recovered,to:storage);assert(fresher && (try! readDraft(storage)).title=="Neuloženo")
 print("PASS: cancel/close with unsaved work asks (keep/later/discard), unchanged drafts close directly, autosaved draft is recovered on next launch")
 assert(Shortcut(key:103,modifiers:UInt32(256),name:"\u{F70E}").display == "⌘F11")
 assert(Shortcut.keyName(122,fallback:"?")=="F1" && Shortcut.keyName(111,fallback:"?")=="F12")
 print("PASS: topic persistence/routing, combined append preserving existing content, separate sessions, image removal and F-key labels")
 let panel=ScreenshotPanel(contentRect:NSRect(x:50,y:50,width:740,height:450),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
 prepareScreenshotPanel(panel)
 assert(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
 assert(panel.collectionBehavior.contains(.canJoinAllApplications))
 assert(!panel.collectionBehavior.contains(.moveToActiveSpace) && panel.level == .floating && !panel.hidesOnDeactivate)
 assert(!panel.styleMask.contains(.titled) && panel.frame.size == panel.contentView!.bounds.size && panel.isMovableByWindowBackground)
 // Check the live AppKit field editor as well as the inactive text layout.
 for (height,size) in [(24.0,13.0),(42.0,27.0)] {
  let field=CenteredTextField(frame:NSRect(x:20,y:20,width:300,height:height));field.isBordered=false;field.drawsBackground=false;field.font = .systemFont(ofSize:size);field.stringValue="Test čgj";field.usesSingleLineMode=true
  panel.contentView!.addSubview(field)
  let rect=field.cell!.drawingRect(forBounds:field.bounds);assert(abs(rect.midY-field.bounds.midY)<0.5)
  panel.makeFirstResponder(field);field.selectText(nil)
  assert(field.currentEditor() != nil)
  if let editor=field.currentEditor(){let editorRect=field.convert(editor.bounds,from:editor);assert(abs(editorRect.midY-field.bounds.midY)<2)}
  panel.makeFirstResponder(nil);field.removeFromSuperview()
 }
 print("PASS: centered inactive and editing text fields, frameless movable panels")
 panel.isReleasedWhenClosed=false;compose.window=panel;compose.titleField.stringValue="Rozepsaný nadpis";compose.comment.stringValue="# Markdown\nKomentář"
 let originalContent=panel.contentView;let originalFrame=panel.frame
 compose.collapseCompact();assert(compose.isCompact && panel.frame.width<300 && panel.frame.height<100)
 compose.expandCompact();assert(!compose.isCompact && panel.contentView === originalContent && panel.frame == originalFrame)
 assert(compose.titleField.stringValue=="Rozepsaný nadpis" && compose.comment.stringValue=="# Markdown\nKomentář" && compose.draft.topic==topic)
 for i in 0..<6 {let name="extra-\(i).png";try Data([1]).write(to:deleteRoot.appendingPathComponent(name));let added=compose.appendCapturedImage(name);assert(added)}
 assert(compose.draft.images.count==6 && compose.titleField.stringValue=="Rozepsaný nadpis" && compose.comment.stringValue=="# Markdown\nKomentář")
 assert(!compose.appendCapturedImage("extra-0.png"))
 func backgroundLuminance(_ name:NSAppearance.Name)->CGFloat {
  let view=AdaptiveInputBackground(frame:NSRect(x:0,y:0,width:120,height:34));view.appearance=NSAppearance(named:name)
  let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:rep)
  let color=rep.colorAt(x:60,y:16)!.usingColorSpace(.sRGB)!
  return 0.2126*color.redComponent+0.7152*color.greenComponent+0.0722*color.blueComponent
 }
 let light=backgroundLuminance(.aqua),dark=backgroundLuminance(.darkAqua);assert(light>0.7 && dark<0.4)
 func iconMaximumLuminance(_ name:NSAppearance.Name)->CGFloat {
  let button=AnnotationToolButton(frame:NSRect(x:0,y:0,width:34,height:28));button.appearance=NSAppearance(named:name);button.image=NSImage(systemSymbolName:"plus",accessibilityDescription:nil);button.state = .off
  let rep=button.bitmapImageRepForCachingDisplay(in:button.bounds)!;button.cacheDisplay(in:button.bounds,to:rep)
  var brightest:CGFloat=0
  for x in Int(Double(rep.pixelsWide)*0.3)..<Int(Double(rep.pixelsWide)*0.7){for y in Int(Double(rep.pixelsHigh)*0.3)..<Int(Double(rep.pixelsHigh)*0.7){let c=rep.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!;brightest=max(brightest,0.2126*c.redComponent+0.7152*c.greenComponent+0.0722*c.blueComponent)}}
  return brightest
 }
 assert(iconMaximumLuminance(.darkAqua)>0.6)
 print("PASS: light/dark input rendering, compact/expand state preservation, adding screenshots to open session and unlimited screenshots")
 let savedSessions=try previousSessions(in:topicDest);assert(savedSessions.count==2)
 let prior=savedSessions[0],other=savedSessions[1]
 let editRoot=root.appendingPathComponent("edit-prior");try fm.createDirectory(at:editRoot,withIntermediateDirectories:true)
 var priorTarget=prior.target;var editNames:[String]=[]
 for (i,image) in prior.images.enumerated(){let local="old-\(i).png";try fm.copyItem(at:topicDest.appendingPathComponent("assets").appendingPathComponent(image),to:editRoot.appendingPathComponent(local));editNames.append(local);priorTarget.imported[local]=image}
 try Data([42]).write(to:editRoot.appendingPathComponent("added.png"));editNames.append("added.png")
 try finishSession(Draft(images:editNames,comment:"Rozšířený komentář",title:prior.title,topic:topic,previous:priorTarget),root:editRoot)
 let changed=try String(contentsOf:topicDest.appendingPathComponent("Spolecny.md"),encoding:.utf8)
 assert(changed.contains("Rozšířený komentář") && changed.contains(other.target.original) && changed.hasPrefix("# Původní obsah"))
 let refreshed=try previousSessions(in:topicDest);assert(refreshed.count==2 && refreshed.contains{$0.images.count==3 && $0.comment=="Rozšířený komentář"})
 let assetsAfter=try fm.contentsOfDirectory(atPath:topicDest.appendingPathComponent("assets").path);assert(assetsAfter.count==4)
 // A stale snapshot must never overwrite externally updated content or leave new assets.
 try Data([43]).write(to:editRoot.appendingPathComponent("stale.png"))
 let stale=Draft(images:["stale.png"],comment:"Stará verze",title:"Test",topic:topic,previous:priorTarget)
 do{try finishSession(stale,root:editRoot);assertionFailure("Stale note should be rejected")}catch{}
 let unchanged=try String(contentsOf:topicDest.appendingPathComponent("Spolecny.md"),encoding:.utf8);assert(unchanged==changed)
 let unchangedAssets=try fm.contentsOfDirectory(atPath:topicDest.appendingPathComponent("assets").path);assert(unchangedAssets.count==4)
 let selectionRoot=root.appendingPathComponent("select-prior");try fm.createDirectory(at:selectionRoot,withIntermediateDirectories:true);try Data([44]).write(to:selectionRoot.appendingPathComponent("fresh.png"))
 let selector=Composer(draft:Draft(images:["fresh.png"],comment:"Nový komentář",title:"Nový nadpis",topic:topic),root:selectionRoot)
 selector.window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:740,height:505),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
 selector.titleField.stringValue="Nový nadpis";selector.comment.markdownText="Nový komentář";selector.refreshPreviousSessions();assert(selector.sessionPicker.indexOfSelectedItem==0)
 selector.sessionPicker.selectItem(at:1);selector.changePreviousSession();assert(selector.draft.previous != nil && selector.draft.images.count>1)
 assert(selector.comment.markdownText.contains("Nový komentář") && !selector.comment.stringValue.contains("\n"))
 assert(!selector.topicLink.isEnabled)
 let lockedTopic=selector.draft.topic;selector.chooseConfiguration();assert(selector.draft.topic==lockedTopic)

 selector.sessionPicker.selectItem(at:0);selector.changePreviousSession();assert(selector.draft.previous==nil && selector.draft.images.contains("fresh.png") && selector.comment.markdownText=="Nový komentář")
 assert(selector.topicLink.isEnabled)
 let compactField=SessionCommentField();compactField.markdownText="# Nadpis\nDalší řádek";assert(!compactField.stringValue.contains("\n") && compactField.markdownText=="# Nadpis\nDalší řádek" && !compactField.isEditable)
 var opened=false;compactField.onExpand={opened=true}
 let click=NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:0,clickCount:1,pressure:1)!
 compactField.mouseDown(with:click);assert(opened);compactField.markdownText="Jeden řádek";assert(compactField.isEditable)
 var captureModes:[Bool]=[]
 selector.onCapture={full in assert(selector.isCompact);captureModes.append(full)}
 let expandedSize=selector.window.frame.size
 selector.addScreenshot()
 selector.window.setFrameOrigin(NSPoint(x:1200,y:180))
 let compactAnchor=NSPoint(x:selector.window.frame.maxX,y:selector.window.frame.maxY)
 selector.expandCompact()
 assert(selector.window.frame.size==expandedSize && selector.window.frame.maxX==compactAnchor.x && selector.window.frame.maxY==compactAnchor.y)
 selector.addFullscreenScreenshot();selector.expandCompact()
 assert(captureModes == [false,true] && !selector.isCompact)
 print("PASS: previous-session discovery, precise updates in shared MD, asset reuse, stale-write rejection, session selection, compact-before-capture and multiline-editor routing")
 assert(AppLanguage.resolve(["cs-CZ"])=="cs" && AppLanguage.resolve(["en-GB"])=="en" && AppLanguage.resolve(["de-DE"])=="en" && AppLanguage.resolve(["fr-FR","cs-CZ"])=="cs")
 var languageKeys:Set<String>?
 for language in ["cs","en"] {
  AppLanguage.override=language
  let file=AppLanguage.bundle(language)!.url(forResource:"Localizable",withExtension:"strings")!
  let values=try PropertyListSerialization.propertyList(from:Data(contentsOf:file),options:[],format:nil) as! [String:String]
  let keys=Set(values.keys);if let previous=languageKeys{assert(previous==keys)};languageKeys=keys
  for(key,value) in values{assert(!value.isEmpty && L(key)==value)}
 }
 AppLanguage.override="en";assert(L("Uložit")=="Save" && L("O aplikaci")=="About")
 let translatedRoot=root.appendingPathComponent("translated");try fm.createDirectory(at:translatedRoot,withIntermediateDirectories:true)
 let translatedOutput=translatedRoot.appendingPathComponent("output")
 for language in ["en","cs"] {
  AppLanguage.override=language;try Data([1]).write(to:translatedRoot.appendingPathComponent("capture.png"))
  try finish(Draft(images:["capture.png"],comment:"Uživatelský komentář",title:"Český uživatelský nadpis"),root:translatedRoot,dest:translatedOutput)
 }
 let bilingual=try previousSessions(in:translatedOutput);assert(bilingual.count==2 && bilingual.allSatisfy{$0.title=="Český uživatelský nadpis" && $0.comment=="Uživatelský komentář"})
 AppLanguage.override="en";let exported=try String(contentsOf:translatedOutput.appendingPathComponent(readableSessionName("Český uživatelský nadpis",created:Date())+".md"),encoding:.utf8);assert(exported.contains("# Description") && exported.contains("# Český uživatelský nadpis"))
 AppLanguage.override="cs";assert(L("Uložit")=="Uložit")
 print("PASS: Czech/English system-language resolution, complete translation catalogs, bilingual Markdown discovery and unchanged user content")
 let manyRoot=root.appendingPathComponent("many");try fm.createDirectory(at:manyRoot,withIntermediateDirectories:true)
 let customDestination=manyRoot.appendingPathComponent("output")
 var customTopic=topic;customTopic.folder=customDestination.path;customTopic.combined=true;customTopic.combinedFile="All.md";customTopic.markdownTemplate="{text}\n\n### {title}\n\n{screenshots}\n";customTopic.combinedTemplate="{sessions}"
 var many=Draft(images:[],comment:"Comment with literal {title}",title:"Custom layout",topic:customTopic,imageNotes:[:])
 for i in 0..<12{let name="image-\(i).png";try Data([UInt8(i)]).write(to:manyRoot.appendingPathComponent(name));many.images.append(name);many.imageNotes?[name]="Caption \(i)\n**Detail**"}
 try stage(many,root:manyRoot);let loadedMany=try readDraft(manyRoot);assert(loadedMany.images.count==12 && loadedMany.imageNotes?["image-11.png"]=="Caption 11\n**Detail**")
 let persistedRoot=manyRoot.appendingPathComponent("persisted");try AppDelegate().persist(loadedMany,root:manyRoot,to:persistedRoot)
 let persisted=try readDraft(persistedRoot);assert(persisted.images.count==12 && persisted.imageNotes?[persisted.images[11]]=="Caption 11\n**Detail**")
 try finishSession(persisted,root:persistedRoot)
 let customMD=try String(contentsOf:customDestination.appendingPathComponent("All.md"),encoding:.utf8)
 assert(customMD.contains("Comment with literal {title}\n\n### Custom layout") && customMD.contains(">)\n\nCaption 11\n**Detail**"))
 let customSessions=try previousSessions(in:customDestination);assert(customSessions.count==1 && customSessions[0].images.count==12 && customSessions[0].imageNotes.count==12 && customSessions[0].comment==many.comment)
 // Mix a legacy section and the new arbitrary-template format in the same Markdown file.
 let mixed="# Legacy\n\n## Screenshot\n\n![[assets/"+customSessions[0].images[0]+"]]\n\n## Comment\n\nLegacy comment\n\n---\n\n"+customMD
 try Data(mixed.utf8).write(to:customDestination.appendingPathComponent("All.md"),options:.atomic)
 let mixedSessions=try previousSessions(in:customDestination);assert(mixedSessions.count==2 && mixedSessions.contains{$0.title=="Legacy" && $0.comment=="Legacy comment"} && mixedSessions.contains{$0.title=="Custom layout" && $0.images.count==12})
 let externallyEdited=mixed.replacingOccurrences(of:"Comment with literal {title}",with:"Edited in Obsidian").replacingOccurrences(of:"Caption 11",with:"Updated caption")
 try Data(externallyEdited.utf8).write(to:customDestination.appendingPathComponent("All.md"),options:.atomic)
 let editedSessions=try previousSessions(in:customDestination);assert(editedSessions.count==2 && editedSessions.contains{$0.title=="Custom layout" && $0.comment=="Edited in Obsidian" && $0.imageNotes.values.contains("Updated caption\n**Detail**")})
 let reopenRoot=manyRoot.appendingPathComponent("reopen");try fm.createDirectory(at:reopenRoot,withIntermediateDirectories:true)
 let toReopen=editedSessions.first{$0.title=="Custom layout"}!
 let reopened=try workingDraft(from:toReopen,topic:customTopic,root:reopenRoot)
 assert(reopened.images.count==12 && reopened.title==toReopen.title && reopened.comment=="Edited in Obsidian" && reopened.previous?.id==toReopen.target.id && reopened.imageNotes?.values.contains("Updated caption\n**Detail**")==true)
 assert(reopened.images.allSatisfy{fm.fileExists(atPath:reopenRoot.appendingPathComponent($0).path)} && reopened.previous!.imported.count==12)
 try finishSession(reopened,root:reopenRoot)
 let afterReopening=try previousSessions(in:customDestination);assert(afterReopening.count==2 && afterReopening.contains{$0.title=="Legacy" && $0.comment=="Legacy comment"} && afterReopening.contains{$0.title=="Custom layout" && $0.images.count==12})
 print("PASS: reopening saved sessions without capture, including per-image notes and updates in a shared Markdown file")
 // Šablona společného souboru: hlavička při vytvoření, nové relace před patičkou.
 let fileRoot=root.appendingPathComponent("file-template");try fm.createDirectory(at:fileRoot,withIntermediateDirectories:true)
 var fileTopic=topic;fileTopic.name="Složka";fileTopic.detail="";fileTopic.folder=fileRoot.appendingPathComponent("out").path;fileTopic.combinedFile="Spolu.md";fileTopic.combinedTemplate="# {folderName}\n\n{folderDescription}\n\n{sessions}\n\n_Konec {folderName}_\n"
 for title in ["První","Druhá"]{try Data([7]).write(to:fileRoot.appendingPathComponent("f.png"));try finishSession(Draft(images:["f.png"],comment:title+" komentář",title:title,topic:fileTopic),root:fileRoot)}
 let fileMD=try String(contentsOf:fileRoot.appendingPathComponent("out/Spolu.md"),encoding:.utf8)
 assert(fileMD.hasPrefix("# Složka\n\n# První\n") && !fileMD.contains("<!--") && fileMD.hasSuffix("komentář\n\n\n_Konec Složka_\n") && fileMD.components(separatedBy:"_Konec").count==2)
 assert(fileMD.range(of:"První komentář")!.lowerBound<fileMD.range(of:"Druhá komentář")!.lowerBound)
 let fileSessions=try previousSessions(in:fileRoot.appendingPathComponent("out"));assert(fileSessions.count==2)
 let firstFileSession=fileSessions.first{$0.title=="První"}!
 let fileReopen=root.appendingPathComponent("file-reopen");try fm.createDirectory(at:fileReopen,withIntermediateDirectories:true)
 var extendedFile=try workingDraft(from:firstFileSession,topic:fileTopic,root:fileReopen);try Data([8]).write(to:fileReopen.appendingPathComponent("new.png"));extendedFile.images.append("new.png");extendedFile.comment="Upraveno"
 try finishSession(extendedFile,root:fileReopen)
 let fileAfter=try String(contentsOf:fileRoot.appendingPathComponent("out/Spolu.md"),encoding:.utf8)
 assert(fileAfter.hasSuffix("_Konec Složka_\n") && fileAfter.contains("Upraveno") && (try! previousSessions(in:fileRoot.appendingPathComponent("out"))).contains{$0.title=="První" && $0.images.count==2})
 assert(combinedTemplateParts(defaultCombinedTemplate,folderName:"A",folderDescription:"").0=="# A\n\n" && validCombinedTemplate(defaultCombinedTemplate) && !validCombinedTemplate("{sessions}{sessions}") && !validCombinedTemplate("# x"))
 print("PASS: combined file template header/footer, insertion before footer, precise updates and discovery")
 let removeNote=NSButton();removeNote.tag=0;let noteComposer=Composer(draft:loadedMany,root:manyRoot);noteComposer.removeImage(removeNote);assert(noteComposer.draft.imageNotes?["image-0.png"]==nil && noteComposer.draft.images.count==11)
 print("PASS: 12 screenshots, per-image notes, draft remapping, custom template roundtrip, literal tokens and mixed legacy/new sessions")
 if !interactiveUITests{assert(!NSApp.windows.contains{$0.isVisible});print("PASS: default regression checks opened no visible windows")}
 print("PASS: titles, Markdown headings, multiple images, legacy drafts, annotations PNG dimensions")
 exit(0)
}

fputs("Usage: ScreenshotNote --self-test [--interactive-ui-tests] | --folder-transfer-self-test | --bridge-self-test | --cloud-self-test | --folder-sync-self-test\n",stderr)
exit(2)
