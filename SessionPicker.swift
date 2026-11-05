import AppKit

struct SessionChoice {
 var title:String;var detail:String;var images:[URL] = []
}
final class ChoiceRow:AppButton {
 override var isFlipped:Bool{false}
 override func hitTest(_ point:NSPoint)->NSView?{bounds.contains(convert(point,from:superview)) ? self:nil}
}
final class SessionChoiceDialog:NSObject,NSWindowDelegate {
 var window:NSWindow!;var selected:Int?;var choices:[SessionChoice]=[]
 func run(title:String,choices:[SessionChoice],current:Int=0)->Int?{
  self.choices=choices
  let heights=choices.map{CGFloat($0.images.isEmpty ? 78:154)}
  let contentHeight=min(386,max(156,heights.reduce(0,+)));let panelHeight=contentHeight+174
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:680,height:panelHeight),styleMask:[.nonactivatingPanel],backing:.buffered,defer:false);window.delegate=self
  let view=installDesignRoot(window,headerHeight:88,showClose:false)
  view.addSubview(designLabel(title,NSRect(x:28,y:panelHeight-60,width:624,height:32),size:23,weight:.semibold))
  let scroll=NSScrollView(frame:NSRect(x:20,y:76,width:640,height:contentHeight));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
  let total=max(scroll.contentSize.height,heights.reduce(0,+));let document=NSView(frame:NSRect(x:0,y:0,width:620,height:total));var top=total
  for (i,choice) in choices.enumerated(){
   let height=heights[i];top-=height
   let row=ChoiceRow(title:"",target:self,action:#selector(choose(_:)));row.frame=NSRect(x:4,y:top+4,width:612,height:height-8);row.role = i==current ? .secondary:.quiet;row.tag=i
   row.setAccessibilityLabel(choice.title+". "+choice.detail)
   row.addSubview(designLabel(choice.title,NSRect(x:16,y:row.bounds.height-32,width:570,height:24),size:14,weight:.medium))
   row.addSubview(designLabel(choice.detail.replacingOccurrences(of:"\n",with:" "),NSRect(x:16,y:row.bounds.height-55,width:570,height:20),size:11,color:AppPalette.secondary))
   if !choice.images.isEmpty{
    for(j,url) in choice.images.prefix(6).enumerated(){let image=NSImageView(frame:NSRect(x:16+CGFloat(j)*88,y:20,width:80,height:54));image.image=NSImage(contentsOf:url);image.imageScaling = .scaleProportionallyUpOrDown;row.addSubview(image)}
    if choice.images.count>6{row.addSubview(designLabel("+\(choice.images.count-6)",NSRect(x:552,y:38,width:42,height:20),size:11,color:AppPalette.secondary))}
   }
   document.addSubview(row)
  }
  scroll.documentView=document;document.scroll(NSPoint(x:0,y:max(0,total-scroll.contentSize.height)));view.addSubview(scroll)
  let cancel=styledButton(L("Zrušit"),role:.quiet,frame:NSRect(x:28,y:22,width:100,height:34),target:self,action:#selector(cancel));cancel.keyEquivalent="\u{1b}";view.addSubview(cancel)
  presentScreenshotPanel(window)
  if isExportingDesign{exportDesignWindow(window,name:choices.contains{!$0.images.isEmpty} ? "session-picker":"configuration-picker");return nil}
  NSApp.runModal(for:window);window.orderOut(nil);return selected
 }
 @objc func choose(_ sender:NSButton){selected=sender.tag;NSApp.stopModal()}
 @objc func cancel(){NSApp.stopModal()}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}
