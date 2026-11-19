import AppKit

struct Topic:Codable,Equatable {
 var id:String;var name:String;var detail:String;var folder:String;var combined:Bool;var combinedFile:String;var markdownTemplate:String? = nil;var uploadToCloud:Bool? = nil;var cloudOnly:Bool? = nil
 var cloudFolderID:UUID? = nil;var cloudOwnerID:UUID? = nil;var cloudOrigin:String? = nil
 var savesLocally:Bool{cloudFolderID == nil ? cloudOnly != true:!folder.isEmpty}
 var savesToCloud:Bool{cloudFolderID != nil || cloudOnly == true || uploadToCloud == true}
 var destination:URL{URL(fileURLWithPath:folder,isDirectory:true)}
}
enum Topics {
 static func checkedDestination(_ path:String)throws->URL {
  guard path.hasPrefix("/"),!path.contains("\0") else {throw CloudFailure(L("Vyber absolutní cestu k místní složce."))}
  var current=URL(fileURLWithPath:"/",isDirectory:true)
  for component in path.split(separator:"/") {
   if component=="."{continue}
   if component==".."{current.deleteLastPathComponent();continue}
   let candidate=current.appendingPathComponent(String(component),isDirectory:true)
   var directory:ObjCBool=false
   if fm.fileExists(atPath:candidate.path,isDirectory:&directory) {
    guard directory.boolValue else{throw CloudFailure(L("Vyber absolutní cestu k místní složce."))}
    current=candidate.resolvingSymlinksInPath()
   }else{
    if (try? fm.attributesOfItem(atPath:candidate.path)[.type]) as? FileAttributeType == .typeSymbolicLink{throw CloudFailure(L("Vyber absolutní cestu k místní složce."))}
    current=candidate
   }
  }
  return current
 }
 static func sameDestination(_ lhs:URL,_ rhs:URL)->Bool {
  if let a=try? fm.attributesOfItem(atPath:lhs.path),let b=try? fm.attributesOfItem(atPath:rhs.path),
     let deviceA=a[.systemNumber] as? NSNumber,let deviceB=b[.systemNumber] as? NSNumber,
     let inodeA=a[.systemFileNumber] as? NSNumber,let inodeB=b[.systemFileNumber] as? NSNumber,
     deviceA==deviceB,inodeA==inodeB{return true}
  func key(_ url:URL)->String {
   var parent=url
   while !fm.fileExists(atPath:parent.path),parent.path != "/"{parent.deleteLastPathComponent()}
   let sensitive=(try? parent.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
   let value=url.path.precomposedStringWithCanonicalMapping
   return sensitive ? value:value.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX"))
  }
  return key(lhs)==key(rhs)
 }
 static func validateDestinations(_ list:[Topic])throws {
  var checked:[(Topic,URL)]=[]
  for topic in list where topic.savesLocally {
   let target=try checkedDestination(topic.folder)
   if let other=checked.first(where:{sameDestination($0.1,target)}) {
    throw CloudFailure(LF("Složku už používá „%@“. Pro „%@“ vyber jinou složku.",other.0.name,topic.name))
   }
   checked.append((topic,target))
  }
 }
 static func validateDestination(_ topic:Topic,folder:URL,among supplied:[Topic]?=nil)throws {
  if supplied==nil && !CloudFolders.shared.isReadable{throw CloudFailure.invalid}
  let list=supplied ?? (Topics.local+CloudFolders.shared.allTopics)
  let target=try checkedDestination(folder.path)
  for other in list where other.id != topic.id && other.savesLocally {
   if sameDestination(target,try checkedDestination(other.folder)) {
    throw CloudFailure(LF("Složku už používá „%@“. Pro „%@“ vyber jinou složku.",other.name,topic.name))
   }
  }
 }
 static var local:[Topic]{
  if let data=UserDefaults.standard.data(forKey:"topics"),let list=try? JSONDecoder().decode([Topic].self,from:data),!list.isEmpty{return list.map(localProjection)}
  return [Topic(id:"default",name:L("Výchozí"),detail:L("Běžné screenshoty"),folder:destination.path,combined:false,combinedFile:AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md")]
 }
 static func localProjection(_ saved:Topic)->Topic{var topic=saved;topic.uploadToCloud=nil;topic.cloudOnly=nil;return topic}
 static var all:[Topic]{local+CloudFolders.shared.topics}
 static var defaultTopic:Topic{let list=all;return list.first{$0.id==UserDefaults.standard.string(forKey:"defaultTopic")} ?? list[0]}
 static func save(_ list:[Topic],defaultID:String)throws{
  guard CloudFolders.shared.isReadable else{throw CloudFailure.invalid}
  let local=list.filter{$0.cloudFolderID == nil}
  try validateDestinations(local+CloudFolders.shared.allTopics)
  let data=try JSONEncoder().encode(local);UserDefaults.standard.set(data,forKey:"topics");UserDefaults.standard.set(defaultID,forKey:"defaultTopic")
 }
}
final class TopicSettings:NSObject,NSTableViewDataSource,NSTableViewDelegate {
 var window:NSWindow!;var list=Topics.all;var editingID:String?;let table=NSTableView()
 let scope=NSPopUpButton();var visible:[Topic]{list.filter{($0.cloudFolderID != nil)==(scope.indexOfSelectedItem==1)}}
 private var saveButton:AppButton!;private var addButton:AppButton!;private var templateButton:AppButton!
 let name=CenteredTextField(),detail=CenteredTextField(),folder=CenteredTextField(),file=CenteredTextField()
 var template=defaultMarkdownTemplate
 let saveStatus=NSTextField(labelWithString:"")
 let storage=NSPopUpButton();private var chooseFolderButton:AppButton!
 let mode=NSPopUpButton();let isDefault=NSButton(checkboxWithTitle:L("Výchozí složka pro nové relace"),target:nil,action:nil)
 func show(){
  if let w=window{if !isExportingDesign{list=Topics.all};reloadScope();presentScreenshotPanel(w);return}
  if !isExportingDesign{list=Topics.all}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Konfigurace");window.isReleasedWhenClosed=false
  let view=installDesignRoot(window,headerHeight:88)
  let sidebar=DesignSurface(frame:NSRect(x:0,y:0,width:240,height:620),fill:AppPalette.raised);view.addSubview(sidebar)
  sidebar.addSubview(designLabel(L("Složky"),NSRect(x:20,y:562,width:200,height:30),size:19,weight:.semibold))
  scope.addItems(withTitles:[L("Lokální složky"),L("Cloudové složky")]);scope.target=self;scope.action=#selector(changeScope);scope.frame=NSRect(x:16,y:522,width:208,height:32);sidebar.addSubview(scope)
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("topic"));column.width=208;table.addTableColumn(column);table.headerView=nil;table.rowHeight=58;table.intercellSpacing=NSSize(width:0,height:3);table.delegate=self;table.dataSource=self;table.style = .plain;table.backgroundColor=AppPalette.raised;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  let scroll=NSScrollView(frame:NSRect(x:12,y:76,width:216,height:438));scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;table.frame=NSRect(x:0,y:0,width:216,height:438);scroll.documentView=table;table.frame.size.width=scroll.contentSize.width;table.autoresizingMask=[.width];sidebar.addSubview(scroll)
  addButton=styledButton(L("Nová lokální složka"),symbol:"plus",frame:NSRect(x:16,y:22,width:208,height:34),target:self,action:#selector(addTopic));sidebar.addSubview(addButton)
  view.addSubview(designLabel(L("Nastavení složky"),NSRect(x:272,y:558,width:600,height:32),size:23,weight:.semibold))
  view.addSubview(designLabel(L("Určete, kam a jak se budou relace ukládat."),NSRect(x:272,y:532,width:600,height:23),size:12,color:AppPalette.secondary))
  for (text,field,y) in [(L("Název"),name,CGFloat(458)),(L("Popis"),detail,CGFloat(386))]{view.addSubview(sectionLabel(text,NSRect(x:272,y:y+42,width:600,height:18)));inputShell(field,frame:NSRect(x:272,y:y,width:600,height:36),in:view)}
  name.placeholderString=L("Například Produktové poznámky");detail.placeholderString=L("Krátký popis pro snazší výběr")
  view.addSubview(sectionLabel(L("Složka"),NSRect(x:272,y:356,width:600,height:18)))
  inputShell(folder,frame:NSRect(x:272,y:314,width:450,height:36),in:view)
  chooseFolderButton=styledButton(L("Vybrat…"),symbol:"folder",frame:NSRect(x:736,y:315,width:136,height:34),target:self,action:#selector(chooseFolder));view.addSubview(chooseFolderButton)
  view.addSubview(DesignDivider(NSRect(x:272,y:294,width:600,height:1)))
  view.addSubview(sectionLabel(L("Ukládání relací"),NSRect(x:272,y:264,width:600,height:18)))
  mode.addItems(withTitles:[L("Samostatný Markdown pro každou relaci"),L("Všechny relace v jednom Markdownu")]);mode.target=self;mode.action=#selector(updateMode);inputShell(mode,frame:NSRect(x:272,y:222,width:600,height:36),in:view)
  view.addSubview(sectionLabel(L("Společný soubor"),NSRect(x:272,y:194,width:600,height:18)));inputShell(file,frame:NSRect(x:272,y:152,width:600,height:36),in:view)
  isDefault.frame=NSRect(x:272,y:114,width:330,height:24);isDefault.font = .systemFont(ofSize:13);view.addSubview(isDefault)
  storage.addItems(withTitles:[L("Pouze v cloudu"),L("Stahovat také do místní složky")])
  storage.target=self;storage.action=#selector(updateMode)
  inputShell(storage,frame:NSRect(x:272,y:79,width:320,height:32),in:view)
  templateButton=styledButton(L("Šablona Markdownu…"),symbol:"doc.text",frame:NSRect(x:620,y:100,width:252,height:32),target:self,action:#selector(editTemplate));view.addSubview(templateButton)
  view.addSubview(DesignDivider(NSRect(x:272,y:72,width:600,height:1)))
  saveStatus.frame=NSRect(x:272,y:28,width:410,height:22);saveStatus.font = .systemFont(ofSize:11);saveStatus.textColor=AppPalette.secondary;view.addSubview(saveStatus)
  saveButton=styledButton(L("Uložit složku"),symbol:"checkmark",role:.primary,frame:NSRect(x:700,y:22,width:172,height:34),target:self,action:#selector(saveTopic));view.addSubview(saveButton)
  NotificationCenter.default.addObserver(self,selector:#selector(foldersChanged),name:.cloudFoldersChanged,object:nil)
  reloadScope();presentScreenshotPanel(window)
 }
 @objc func foldersChanged(){if !isExportingDesign{list=Topics.all};if window?.isVisible==true{table.reloadData()}}
 @objc func changeScope(){reloadScope()}
 func reloadScope(){
  table.reloadData();let row=visible.firstIndex{$0.id==editingID} ?? 0
  if visible.indices.contains(row){table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);load(visible[row])}
  else{editingID=nil;name.stringValue="";detail.stringValue="";folder.stringValue="";name.isEnabled=false;detail.isEnabled=false;saveButton?.isEnabled=false;folder.isEnabled=false;chooseFolderButton?.isEnabled=false;saveStatus.stringValue=L("Cloudové složky vytvoř na webu. Po připojení se načtou automaticky.")}
  addButton?.title=scope.indexOfSelectedItem==1 ? L("Spravovat na webu"):L("Nová lokální složka")
 }
 func numberOfRows(in tableView:NSTableView)->Int{visible.count}
 func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView?{DesignTopicRow()}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{
  let topic=visible[row];let cell=NSView(frame:NSRect(x:0,y:0,width:208,height:58))
  let icon=NSImageView(frame:NSRect(x:12,y:17,width:20,height:22));icon.image=NSImage(systemSymbolName:"folder",accessibilityDescription:nil);icon.contentTintColor=AppPalette.accent;cell.addSubview(icon)
  cell.addSubview(designLabel(topic.name,NSRect(x:43,y:28,width:152,height:21),size:13,weight:.medium))
  let secondary=(topic.id==Topics.defaultTopic.id ? L("Výchozí · "):"")+(topic.combined ? L("Společný soubor"):L("Samostatné relace"))
  cell.addSubview(designLabel(secondary,NSRect(x:43,y:9,width:152,height:18),size:10,color:AppPalette.secondary));return cell
 }
 func tableViewSelectionDidChange(_ notification:Notification){let row=table.selectedRow;if visible.indices.contains(row){load(visible[row])}}
 func load(_ topic:Topic){saveStatus.stringValue="";editingID=topic.id;template=topic.markdownTemplate ?? defaultMarkdownTemplate;name.stringValue=topic.name;detail.stringValue=topic.detail;folder.stringValue=topic.folder;file.stringValue=topic.combinedFile;mode.selectItem(at:topic.combined ? 1:0);storage.selectItem(at:topic.savesLocally ? 1:0);isDefault.state=topic.id==Topics.defaultTopic.id ? .on:.off;name.isEnabled=topic.cloudFolderID==nil;detail.isEnabled=name.isEnabled;storage.superview?.isHidden=topic.cloudFolderID==nil;saveButton?.isEnabled=true;updateMode()}
 @objc func updateMode(){
  let cloud=scope.indexOfSelectedItem==1,local = !cloud || storage.indexOfSelectedItem==1
  folder.isEnabled=local;folder.superview?.alphaValue=local ? 1:0.45
  chooseFolderButton?.isEnabled=local;mode.isEnabled=local && !cloud
  templateButton?.isEnabled = !cloud
  file.isEnabled=local && mode.indexOfSelectedItem==1
  file.superview?.alphaValue=file.isEnabled ? 1:0.45
 }
 @objc func addTopic(){if scope.indexOfSelectedItem==1{NSWorkspace.shared.open(CloudBuild.endpoint.path("/settings/folders"));return};saveStatus.stringValue="";editingID=nil;template=defaultMarkdownTemplate;table.deselectAll(nil);name.isEnabled=true;detail.isEnabled=true;saveButton.isEnabled=true;name.stringValue="";detail.stringValue="";folder.stringValue="";file.stringValue=AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md";mode.selectItem(at:0);isDefault.state = .off;storage.selectItem(at:0);storage.superview?.isHidden=true;updateMode();window.makeFirstResponder(name)}
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
  let cloud=scope.indexOfSelectedItem==1,local = !cloud || storage.indexOfSelectedItem==1
  guard !title.isEmpty,!local || path.hasPrefix("/") else{showError(L("Vyplň název konfigurace a absolutní cestu ke složce."));return}
  let rawFile=(file.stringValue as NSString).deletingPathExtension
  let filename=(filenameFromTitle(rawFile) ?? filenameFromTitle(title) ?? "Screenshoty")+".md"
  if cloud {
   guard var topic=list.first(where:{$0.id==editingID}),topic.cloudFolderID != nil else{return}
   topic.folder=local ? path:""
   do{try CloudFolders.shared.setFolder(topic,path:topic.folder);if isDefault.state == .on{UserDefaults.standard.set(topic.id,forKey:"defaultTopic")};list=Topics.all;load(topic);saveStatus.stringValue=L("Konfigurace byla uložena.");Task{@MainActor in await CloudFolders.shared.refresh(CloudLibrary.shared.connection)}}catch{showError(error.localizedDescription)}
   return
  }
  let topic=Topic(id:editingID ?? UUID().uuidString,name:title,detail:detail.stringValue,folder:path,combined:mode.indexOfSelectedItem==1,combinedFile:filename,markdownTemplate:template)
  var updated=list
  if let i=updated.firstIndex(where:{$0.id==topic.id}){updated[i]=topic}else{updated.append(topic)}
  let defaultID=isDefault.state == .on ? topic.id:Topics.defaultTopic.id
  do{try Topics.save(updated,defaultID:defaultID);list=updated;editingID=topic.id;table.reloadData();let i=visible.firstIndex{$0.id==topic.id}!;table.selectRowIndexes(IndexSet(integer:i),byExtendingSelection:false);load(topic);saveStatus.stringValue=L("Konfigurace byla uložena.");saveStatus.alphaValue=0;animateDesign{saveStatus.animator().alphaValue=1}}catch{showError(error.localizedDescription)}
 }
}
