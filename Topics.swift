import AppKit

struct Topic:Codable,Equatable {
 var id:String;var name:String;var detail:String;var folder:String;var combined:Bool;var combinedFile:String;var markdownTemplate:String? = nil
 var destination:URL{URL(fileURLWithPath:folder,isDirectory:true)}
}
enum Topics {
 static var all:[Topic]{
  if let data=UserDefaults.standard.data(forKey:"topics"),let list=try? JSONDecoder().decode([Topic].self,from:data),!list.isEmpty{return list}
  return [Topic(id:"default",name:L("Výchozí"),detail:L("Běžné screenshoty"),folder:destination.path,combined:false,combinedFile:AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md")]
 }
 static var defaultTopic:Topic{let list=all;return list.first{$0.id==UserDefaults.standard.string(forKey:"defaultTopic")} ?? list[0]}
 static func save(_ list:[Topic],defaultID:String)throws{let data=try JSONEncoder().encode(list);UserDefaults.standard.set(data,forKey:"topics");UserDefaults.standard.set(defaultID,forKey:"defaultTopic")}
}
final class TopicSettings:NSObject,NSTableViewDataSource,NSTableViewDelegate {
 var window:NSWindow!;var list=Topics.all;var editingID:String?;let table=NSTableView()
 let name=CenteredTextField(),detail=CenteredTextField(),folder=CenteredTextField(),file=CenteredTextField()
 var template=defaultMarkdownTemplate
 let saveStatus=NSTextField(labelWithString:"")
 let mode=NSPopUpButton();let isDefault=NSButton(checkboxWithTitle:L("Výchozí konfigurace pro nové relace"),target:nil,action:nil)
 func show(){
  if let w=window{if !isExportingDesign{list=Topics.all};table.reloadData();if let topic=list.first(where:{$0.id==editingID}){load(topic)};presentScreenshotPanel(w);return}
  if !isExportingDesign{list=Topics.all}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Konfigurace");window.isReleasedWhenClosed=false
  let view=installDesignRoot(window,headerHeight:88)
  let sidebar=DesignSurface(frame:NSRect(x:0,y:0,width:240,height:620),fill:AppPalette.raised);view.addSubview(sidebar)
  sidebar.addSubview(designLabel(L("Konfigurace"),NSRect(x:20,y:562,width:200,height:30),size:19,weight:.semibold))
  sidebar.addSubview(sectionLabel(L("Cíle ukládání"),NSRect(x:20,y:536,width:200,height:18)))
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("topic"));column.width=208;table.addTableColumn(column);table.headerView=nil;table.rowHeight=58;table.intercellSpacing=NSSize(width:0,height:3);table.delegate=self;table.dataSource=self;table.style = .plain;table.backgroundColor=AppPalette.raised;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  let scroll=NSScrollView(frame:NSRect(x:12,y:76,width:216,height:438));scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;table.frame=NSRect(x:0,y:0,width:216,height:438);scroll.documentView=table;table.frame.size.width=scroll.contentSize.width;table.autoresizingMask=[.width];sidebar.addSubview(scroll)
  let add=styledButton(L("Nová konfigurace"),symbol:"plus",frame:NSRect(x:16,y:22,width:208,height:34),target:self,action:#selector(addTopic));sidebar.addSubview(add)
  view.addSubview(designLabel(L("Nastavení konfigurace"),NSRect(x:272,y:558,width:600,height:32),size:23,weight:.semibold))
  view.addSubview(designLabel(L("Určete, kam a jak se budou relace ukládat."),NSRect(x:272,y:532,width:600,height:23),size:12,color:AppPalette.secondary))
  for (text,field,y) in [(L("Název"),name,CGFloat(458)),(L("Popis"),detail,CGFloat(386))]{view.addSubview(sectionLabel(text,NSRect(x:272,y:y+42,width:600,height:18)));inputShell(field,frame:NSRect(x:272,y:y,width:600,height:36),in:view)}
  name.placeholderString=L("Například Produktové poznámky");detail.placeholderString=L("Krátký popis pro snazší výběr")
  view.addSubview(sectionLabel(L("Složka"),NSRect(x:272,y:356,width:600,height:18)))
  inputShell(folder,frame:NSRect(x:272,y:314,width:450,height:36),in:view)
  let choose=styledButton(L("Vybrat…"),symbol:"folder",frame:NSRect(x:736,y:315,width:136,height:34),target:self,action:#selector(chooseFolder));view.addSubview(choose)
  view.addSubview(DesignDivider(NSRect(x:272,y:294,width:600,height:1)))
  view.addSubview(sectionLabel(L("Ukládání relací"),NSRect(x:272,y:264,width:600,height:18)))
  mode.addItems(withTitles:[L("Samostatný Markdown pro každou relaci"),L("Všechny relace v jednom Markdownu")]);mode.target=self;mode.action=#selector(updateMode);inputShell(mode,frame:NSRect(x:272,y:222,width:600,height:36),in:view)
  view.addSubview(sectionLabel(L("Společný soubor"),NSRect(x:272,y:194,width:600,height:18)));inputShell(file,frame:NSRect(x:272,y:152,width:600,height:36),in:view)
  isDefault.frame=NSRect(x:272,y:102,width:330,height:28);isDefault.font = .systemFont(ofSize:13);view.addSubview(isDefault)
  view.addSubview(styledButton(L("Šablona Markdownu…"),symbol:"doc.text",frame:NSRect(x:620,y:100,width:252,height:32),target:self,action:#selector(editTemplate)))
  view.addSubview(DesignDivider(NSRect(x:272,y:72,width:600,height:1)))
  saveStatus.frame=NSRect(x:272,y:28,width:410,height:22);saveStatus.font = .systemFont(ofSize:11);saveStatus.textColor=AppPalette.secondary;view.addSubview(saveStatus)
  let save=styledButton(L("Uložit konfiguraci"),symbol:"checkmark",role:.primary,frame:NSRect(x:700,y:22,width:172,height:34),target:self,action:#selector(saveTopic));view.addSubview(save)
  table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);load(list[0]);presentScreenshotPanel(window)
 }
 func numberOfRows(in tableView:NSTableView)->Int{list.count}
 func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView?{DesignTopicRow()}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{
  let topic=list[row];let cell=NSView(frame:NSRect(x:0,y:0,width:208,height:58))
  let icon=NSImageView(frame:NSRect(x:12,y:17,width:20,height:22));icon.image=NSImage(systemSymbolName:"folder",accessibilityDescription:nil);icon.contentTintColor=AppPalette.accent;cell.addSubview(icon)
  cell.addSubview(designLabel(topic.name,NSRect(x:43,y:28,width:152,height:21),size:13,weight:.medium))
  let secondary=(topic.id==Topics.defaultTopic.id ? L("Výchozí · "):"")+(topic.combined ? L("Společný soubor"):L("Samostatné relace"))
  cell.addSubview(designLabel(secondary,NSRect(x:43,y:9,width:152,height:18),size:10,color:AppPalette.secondary));return cell
 }
 func tableViewSelectionDidChange(_ notification:Notification){let row=table.selectedRow;if list.indices.contains(row){load(list[row])}}
 func load(_ topic:Topic){saveStatus.stringValue="";editingID=topic.id;template=topic.markdownTemplate ?? defaultMarkdownTemplate;name.stringValue=topic.name;detail.stringValue=topic.detail;folder.stringValue=topic.folder;file.stringValue=topic.combinedFile;mode.selectItem(at:topic.combined ? 1:0);isDefault.state=topic.id==Topics.defaultTopic.id ? .on:.off;updateMode()}
 @objc func updateMode(){file.isEnabled=mode.indexOfSelectedItem==1;file.superview?.alphaValue=file.isEnabled ? 1:0.45}
 @objc func addTopic(){saveStatus.stringValue="";editingID=nil;template=defaultMarkdownTemplate;table.deselectAll(nil);name.stringValue="";detail.stringValue="";folder.stringValue=destination.path;file.stringValue=AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md";mode.selectItem(at:0);isDefault.state = .off;updateMode();window.makeFirstResponder(name)}
 @objc func chooseFolder(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.directoryURL=URL(fileURLWithPath:folder.stringValue);if panel.runModal() == .OK,let url=panel.url{folder.stringValue=url.path}}
 @objc func editTemplate(){
  let editor=MarkdownEditor()
  if let value=editor.run(template,title:L("Šablona Markdownu"),hint:L("Proměnné: {title}, {screenshots}, {text}")){
   guard ["{title}","{screenshots}","{text}"].allSatisfy({value.contains($0)}) else{showError(L("Šablona musí obsahovat {title}, {screenshots} a {text}."));return};template=value
  };window.makeKeyAndOrderFront(nil)
 }
 @objc func saveTopic(){
  window.makeFirstResponder(nil)
  let title=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),path=folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !title.isEmpty,path.hasPrefix("/") else{showError(L("Vyplň název konfigurace a absolutní cestu ke složce."));return}
  let rawFile=(file.stringValue as NSString).deletingPathExtension
  let filename=(filenameFromTitle(rawFile) ?? filenameFromTitle(title) ?? "Screenshoty")+".md"
  let topic=Topic(id:editingID ?? UUID().uuidString,name:title,detail:detail.stringValue,folder:path,combined:mode.indexOfSelectedItem==1,combinedFile:filename,markdownTemplate:template)
  if let i=list.firstIndex(where:{$0.id==topic.id}){list[i]=topic}else{list.append(topic)}
  let defaultID=isDefault.state == .on ? topic.id:Topics.defaultTopic.id
  do{try Topics.save(list,defaultID:defaultID);editingID=topic.id;table.reloadData();let i=list.firstIndex{$0.id==topic.id}!;table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false);load(topic);saveStatus.stringValue=L("Konfigurace byla uložena.");saveStatus.alphaValue=0;animateDesign{saveStatus.animator().alphaValue=1}}catch{showError(error.localizedDescription)}
 }
}
