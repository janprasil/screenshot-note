import AppKit

/// A per-image note is saved separately from bitmap annotations.
final class ImageNoteEditor:NSObject,NSWindowDelegate {
 var window:NSWindow!;let field=SessionCommentField();var accepted=false
 func run(_ initial:String,image:URL?=nil)->String?{
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:560,height:216),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);window.delegate=self
  let root=installDesignRoot(window,headerHeight:72,showClose:false)
  var headingX:CGFloat=28
  if let image=image{let preview=NSImageView(frame:NSRect(x:28,y:146,width:44,height:44));preview.image=NSImage(contentsOf:image);preview.imageScaling = .scaleProportionallyUpOrDown;root.addSubview(preview);headingX=86}
  root.addSubview(designLabel(L("Poznámka ke snímku"),NSRect(x:headingX,y:152,width:532-headingX,height:30),size:20,weight:.semibold))
  let input=AdaptiveInputBackground(frame:NSRect(x:28,y:88,width:504,height:40));root.addSubview(input)
  field.frame=NSRect(x:12,y:8,width:442,height:24);field.font = .systemFont(ofSize:14);field.isBordered=false;field.drawsBackground=false;field.textColor = .textColor;field.usesSingleLineMode=true;field.lineBreakMode = .byTruncatingTail;field.placeholderString=L("Poznámka ke snímku…");field.markdownText=initial;field.onExpand={[weak self] in self?.expand()};input.addSubview(field)
  let expand=styledButton("",symbol:"line.3.horizontal",role:.quiet,frame:NSRect(x:462,y:4,width:34,height:32),target:self,action:#selector(expand));expand.toolTip=L("Otevřít Markdown editor");expand.setAccessibilityLabel(L("Otevřít Markdown editor"));input.addSubview(expand)
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:28,y:22,width:100,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";root.addSubview(cancel)
  let save=styledButton(L("Uložit"),symbol:"checkmark",role:.primary,frame:NSRect(x:408,y:22,width:124,height:34),target:self,action:#selector(save));save.keyEquivalent="\r";root.addSubview(save)
  presentScreenshotPanel(window);window.makeFirstResponder(field)
  if isExportingDesign{exportDesignWindow(window,name:"image-note");return nil}
  NSApp.runModal(for:window);window.orderOut(nil);return accepted ? field.markdownText:nil
 }
 @objc func expand(){window.makeFirstResponder(nil);let editor=MarkdownEditor();if let value=editor.run(field.markdownText,title:L("Poznámka ke snímku")){field.markdownText=value};window.makeKeyAndOrderFront(nil)}
 @objc func save(){window.makeFirstResponder(nil);accepted=true;NSApp.stopModal()}
 @objc func cancel(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}
