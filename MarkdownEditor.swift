import AppKit

// Attribute-only rendering: the text buffer always remains the original Markdown.
final class LiveMarkdownView:NSTextView,NSTextViewDelegate {
 var styling=false
 var storageOwner:NSTextStorage?
 override init(frame:NSRect,textContainer:NSTextContainer? = nil){let container:NSTextContainer
  if let existing=textContainer {container=existing} else {let storage=NSTextStorage();storageOwner=storage;let layout=NSLayoutManager();container=NSTextContainer(containerSize:NSSize(width:frame.width,height:CGFloat.greatestFiniteMagnitude));storage.addLayoutManager(layout);layout.addTextContainer(container)}
  super.init(frame:frame,textContainer:container);delegate=self;backgroundColor = .textBackgroundColor;textColor = .textColor;insertionPointColor = .textColor;isRichText=false;allowsUndo=true;isAutomaticQuoteSubstitutionEnabled=false;isAutomaticDashSubstitutionEnabled=false;textContainerInset=NSSize(width:22,height:20)}
 required init?(coder:NSCoder){fatalError()}
 override func viewDidChangeEffectiveAppearance(){super.viewDidChangeEffectiveAppearance();renderMarkdown();needsDisplay=true}
 func textDidChange(_ notification:Notification){renderMarkdown()}
 func renderMarkdown(){
  guard !styling,let storage=textStorage else{return};styling=true;defer{styling=false}
  let source=string as NSString;let full=NSRange(location:0,length:source.length)
  let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=5;paragraph.paragraphSpacing=8
  storage.beginEditing();defer{storage.endEditing()}
  storage.setAttributes([.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph],range:full)
  func matches(_ pattern:String,_ body:(NSTextCheckingResult)->Void){guard let regex=try? NSRegularExpression(pattern:pattern,options:[.anchorsMatchLines]) else{return};for match in regex.matches(in:string,range:full){body(match)}}
  func muted(_ range:NSRange){storage.addAttribute(.foregroundColor,value:NSColor.tertiaryLabelColor,range:range)}
  matches("^(#{1,6})[ \\t]+(.+)$"){m in
   let level=m.range(at:1).length;let sizes:[CGFloat]=[30,25,21,19,17,16]
   storage.addAttribute(.font,value:NSFont.systemFont(ofSize:sizes[level-1],weight:.bold),range:m.range);muted(m.range(at:1))
  }
  matches("\\*\\*(.+?)\\*\\*|__(.+?)__"){m in
   let r=m.range(at:m.range(at:1).location != NSNotFound ? 1:2)
   storage.addAttribute(.font,value:NSFont.boldSystemFont(ofSize:16),range:r);muted(NSRange(location:m.range.location,length:2));muted(NSRange(location:NSMaxRange(m.range)-2,length:2))
  }
  matches("(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)|(?<!_)_([^_\\n]+)_(?!_)"){m in
   let r=m.range(at:m.range(at:1).location != NSNotFound ? 1:2)
   let font=NSFontManager.shared.convert(NSFont.systemFont(ofSize:16),toHaveTrait:.italicFontMask)
   storage.addAttribute(.font,value:font,range:r);muted(NSRange(location:m.range.location,length:1));muted(NSRange(location:NSMaxRange(m.range)-1,length:1))
  }
  matches("~~([^\\n]+?)~~"){m in storage.addAttribute(.strikethroughStyle,value:NSUnderlineStyle.single.rawValue,range:m.range(at:1));muted(NSRange(location:m.range.location,length:2));muted(NSRange(location:NSMaxRange(m.range)-2,length:2))}
  matches("`([^`\\n]+)`"){m in storage.addAttributes([.font:NSFont.monospacedSystemFont(ofSize:15,weight:.regular),.backgroundColor:NSColor.quaternaryLabelColor],range:m.range);muted(NSRange(location:m.range.location,length:1));muted(NSRange(location:NSMaxRange(m.range)-1,length:1))}
  matches("^>[ \\t]?.*$"){m in storage.addAttribute(.foregroundColor,value:NSColor.secondaryLabelColor,range:m.range)}
  matches("^[ \\t]*(?:[-+*]|[0-9]+\\.)[ \\t]+"){m in storage.addAttribute(.foregroundColor,value:NSColor.controlAccentColor,range:m.range)}
  matches("\\[([^]\\n]+)\\]\\(([^)\\n]+)\\)"){m in storage.addAttributes([.foregroundColor:NSColor.linkColor,.underlineStyle:NSUnderlineStyle.single.rawValue],range:m.range(at:1));muted(m.range(at:2))}
  // Fenced code blocks override inline formatting, including apparent headings.
  matches("(?s)^```[^\\n]*\\n.*?(?:^```[ \\t]*$|\\z)"){m in storage.addAttributes([.font:NSFont.monospacedSystemFont(ofSize:14,weight:.regular),.foregroundColor:NSColor.labelColor,.backgroundColor:NSColor.quaternaryLabelColor],range:m.range)}
  // Attribute-only edits preserve selection. Never set it while storage is editing:
  // AppKit Writing Tools may synchronously request glyph layout before endEditing().
 }
 func safeSelection(in source:NSString)->NSRange{
  let range=selectedRange();let start=range.location == NSNotFound ? source.length:min(source.length,range.location)
  return NSRange(location:start,length:min(range.length,source.length-start))
 }
 func wrap(_ prefix:String,_ suffix:String){
  let source=string as NSString;let selection=safeSelection(in:source);let current=source.substring(with:selection);let text=current.isEmpty ? "text":current
  insertText(prefix+text+suffix,replacementRange:selection)
  // Any styling transaction triggered by insertText has completed before changing selection.
  setSelectedRange(NSRange(location:selection.location+prefix.utf16.count,length:text.utf16.count));renderMarkdown()
 }
 func prefixLine(_ prefix:String){let ns=string as NSString;let range=ns.paragraphRange(for:safeSelection(in:ns));insertText(prefix+ns.substring(with:range),replacementRange:range);renderMarkdown()}

}
final class MarkdownEditor:NSObject,NSWindowDelegate {
 var window:NSWindow!;var text:LiveMarkdownView!;var accepted=false
 func run(_ initial:String,title:String?=nil,hint:String?=nil)->String? {
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:800,height:640),styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Komentář");window.minSize=NSSize(width:650,height:460);window.delegate=self
  let view=installDesignRoot(window,headerHeight:154,showClose:false)
  let heading=designLabel(title ?? L("Komentář"),NSRect(x:28,y:580,width:744,height:32),size:24,weight:.semibold);heading.autoresizingMask=[.minYMargin];view.addSubview(heading)
  let hint=designLabel(hint ?? L("Markdown se formátuje přímo při psaní."),NSRect(x:28,y:553,width:744,height:22),size:12,color:AppPalette.secondary);hint.autoresizingMask=[.minYMargin];view.addSubview(hint)
  let toolbar=DesignSurface(frame:NSRect(x:28,y:499,width:744,height:42),fill:AppPalette.accent.withAlphaComponent(0.085),radius:9);toolbar.autoresizingMask=[.width,.minYMargin];view.addSubview(toolbar)
  let tools=[("textformat.size",L("Nadpis")),("bold",L("Tučné písmo")),("italic",L("Kurzíva")),("list.bullet",L("Seznam")),("link",L("Odkaz")),("chevron.left.forwardslash.chevron.right",L("Kód"))]
  for(i,tool) in tools.enumerated(){let button=styledButton("",symbol:tool.0,role:.quiet,frame:NSRect(x:5+CGFloat(i)*42,y:5,width:34,height:32),target:self,action:#selector(format));button.tag=i;button.toolTip=tool.1;toolbar.addSubview(button)}
  let scroll=NSScrollView(frame:NSRect(x:28,y:82,width:744,height:387));scroll.hasVerticalScroller=true;scroll.borderType = .noBorder;scroll.backgroundColor=AppPalette.paper;scroll.autoresizingMask=[.width,.height];scroll.wantsLayer=true;scroll.layer?.cornerRadius=10
  text=LiveMarkdownView(frame:NSRect(x:0,y:0,width:scroll.contentSize.width,height:scroll.contentSize.height));text.backgroundColor=AppPalette.paper;text.textContainerInset=NSSize(width:28,height:25);text.isVerticallyResizable=true;text.isHorizontallyResizable=false;text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true;text.textContainer?.containerSize=NSSize(width:scroll.contentSize.width,height:CGFloat.greatestFiniteMagnitude);text.string=initial;scroll.documentView=text;view.addSubview(scroll);text.renderMarkdown()
  view.addSubview(DesignDivider(NSRect(x:28,y:66,width:744,height:1)))
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:28,y:22,width:90,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";view.addSubview(cancel)
  let apply=styledButton(L("Použít komentář"),symbol:"checkmark",role:.primary,frame:NSRect(x:600,y:22,width:172,height:34),target:self,action:#selector(apply));apply.autoresizingMask=[.minXMargin];apply.keyEquivalent="\r";apply.keyEquivalentModifierMask=[.command];view.addSubview(apply)
  presentScreenshotPanel(window);window.makeFirstResponder(text)
  if isExportingDesign{exportDesignWindow(window,name:"comment");return nil}
  NSApp.runModal(for:window);window.orderOut(nil);return accepted ? text.string:nil
 }
 @objc func format(_ button:NSButton){switch button.tag{case 0:text.prefixLine("# ");case 1:text.wrap("**","**");case 2:text.wrap("*","*");case 3:text.prefixLine("- ");case 4:text.wrap("[","](https://)");default:text.wrap("`","`")};window.makeFirstResponder(text)}
 @objc func apply(){accepted=true;NSApp.stopModal()};@objc func cancel(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}
