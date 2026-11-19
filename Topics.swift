import AppKit

struct Topic:Codable,Equatable {
 var id:String;var name:String;var detail:String;var folder:String;var combined:Bool;var combinedFile:String;var markdownTemplate:String? = nil;var uploadToCloud:Bool? = nil;var cloudOnly:Bool? = nil
 var cloudFolderID:UUID? = nil;var cloudOwnerID:UUID? = nil;var cloudOrigin:String? = nil
 // Šablona celého společného souboru; nil znamená výchozí.
 var combinedTemplate:String? = nil
 // Dřívější cloudová složka po odhlášení; slouží k nabídce znovupropojení.
 var formerCloudFolderID:UUID? = nil;var formerCloudOwnerID:UUID? = nil;var formerCloudOrigin:String? = nil
 // Jen pro cloudovou složku na tomto Macu: false = smazání z disku jde do Koše bez dotazu.
 var confirmLocalDeletes:Bool? = nil
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
 static var storedLocal:[Topic]{
  if let data=UserDefaults.standard.data(forKey:"topics"),let list=try? JSONDecoder().decode([Topic].self,from:data),!list.isEmpty{return list.map(localProjection)}
  return [Topic(id:"default",name:L("Výchozí"),detail:L("Běžné screenshoty"),folder:destination.path,combined:false,combinedFile:AppLanguage.current=="cs" ? "Screenshoty.md":"Screenshots.md")]
 }
 static var local:[Topic]{storedLocal.filter{!CloudFolders.shared.migratedLocalIDs.contains($0.id)}}
 static func localProjection(_ saved:Topic)->Topic{var topic=saved;topic.uploadToCloud=nil;topic.cloudOnly=nil;return topic}
 static var all:[Topic]{
  let result=local+CloudFolders.shared.topics;if !result.isEmpty{return result}
  var index=1
  while true {
   let path=destination.appendingPathComponent(index==1 ? "Local Notes":"Local Notes \(index)").path
   let topic=Topic(id:"new-local-default",name:L("Výchozí"),detail:"",folder:path,combined:false,combinedFile:"Notes.md")
   if (try? validateDestinations([topic]+CloudFolders.shared.allTopics)) != nil{return [topic]};index+=1
  }
 }
 // Nová relace začíná ve složce, kam se naposledy ukládalo.
 static var initialTopic:Topic{let list=all;return list.first{$0.id==UserDefaults.standard.string(forKey:"lastTopic")} ?? defaultTopic}
 static func rememberLast(_ topic:Topic?){if let topic,!isExportingDesign{UserDefaults.standard.set(topic.id,forKey:"lastTopic")}}
 static var defaultTopic:Topic{let list=all;return list.first{$0.id==UserDefaults.standard.string(forKey:"defaultTopic")} ?? list[0]}
 /// Uloží lokální složky bez kontroly; volající kontroluje kolize sám.
 static func storeLocal(_ list:[Topic])throws{UserDefaults.standard.set(try JSONEncoder().encode(list.filter{$0.cloudFolderID==nil}),forKey:"topics")}
 static func save(_ list:[Topic],defaultID:String)throws{
  guard CloudFolders.shared.isReadable else{throw CloudFailure.invalid}
  let local=list.filter{$0.cloudFolderID == nil}
  try validateDestinations(local+CloudFolders.shared.allTopics)
  let data=try JSONEncoder().encode(local);UserDefaults.standard.set(data,forKey:"topics");UserDefaults.standard.set(defaultID,forKey:"defaultTopic")
 }
}
final class StarButton:AppButton {
 var isOn=false{didSet{needsDisplay=true}}
 override func draw(_ dirtyRect:NSRect){
  if hovered || isHighlighted{AppPalette.raised.setFill();NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:8,yRadius:8).fill()}
  let symbol=NSImage(systemSymbolName:isOn ? "star.fill":"star",accessibilityDescription:nil)?.withSymbolConfiguration(.init(pointSize:16,weight:.medium))
  drawAdaptiveSymbol(symbol,in:NSRect(x:bounds.midX-9,y:bounds.midY-9,width:18,height:18),color:isOn ? .systemYellow:AppPalette.secondary)
 }
}
final class TopicSettings:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
 var window:NSWindow!;var list=Topics.all;var editingID:String?;let table=NSTableView()
 private let connection:()->CloudConnection?
 var signedIn:Bool{connection()?.ownerID != nil}
 var rows:[Topic]{list}
 // Náhledy designu nemění skutečnou výchozí složku.
 var previewDefaultID:String?
 var defaultID:String{previewDefaultID ?? Topics.defaultTopic.id}
 init(connection:@escaping ()->CloudConnection? = {CloudLibrary.shared.connection}){self.connection=connection}
 private var editingCloud:Bool{list.first{$0.id==editingID}?.cloudFolderID != nil}
 private(set) var deleteButton:AppButton!
 // Viditelné jen u cloudové složky, kde uživatel dotaz před smazáním vypnul.
 let askBeforeDelete=NSButton(checkboxWithTitle:"",target:nil,action:nil)
 private(set) var syncButton:AppButton!;private var saveButton:AppButton!;private var addButton:AppButton!;private var templateButton:AppButton!;private var chooseFolderButton:AppButton!
 private(set) var pencil:AppButton!;let star=StarButton();private let nameShell=AdaptiveInputBackground(frame:.zero);private let nameClick=NSClickGestureRecognizer()
 private var fileLabel:NSTextField!;private(set) var syncCaption:NSTextField!
 let name=CenteredTextField(),detail=CenteredTextField(),folder=CenteredTextField(),file=CenteredTextField()
 var template=defaultMarkdownTemplate;var fileTemplate:String?
 var pendingDefault=false
 // Nová složka dostane kopii výchozích šablon.
 var defaults=TemplateDefaults.shared
 let saveStatus=NSTextField(labelWithString:"")
 let mode=NSPopUpButton()
 func show(present:Bool=true,reload:Bool=true){
  if let w=window{if !isExportingDesign && reload{list=Topics.all};reloadFolders();if present{presentScreenshotPanel(w)};return}
  if !isExportingDesign && reload{list=Topics.all}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:900,height:620),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Konfigurace");window.isReleasedWhenClosed=false
  let view=installDesignRoot(window,headerHeight:108)
  let sidebar=DesignSurface(frame:NSRect(x:0,y:0,width:240,height:620),fill:AppPalette.raised);view.addSubview(sidebar)
  sidebar.addSubview(designLabel(L("Složky"),NSRect(x:20,y:562,width:200,height:30),size:19,weight:.semibold))
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("topic"));column.width=208;table.addTableColumn(column);table.headerView=nil;table.rowHeight=58;table.intercellSpacing=NSSize(width:0,height:3);table.delegate=self;table.dataSource=self;table.style = .plain;table.backgroundColor=AppPalette.raised;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  let scroll=NSScrollView(frame:NSRect(x:12,y:116,width:216,height:430));scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;table.frame=NSRect(x:0,y:0,width:216,height:470);scroll.documentView=table;table.frame.size.width=scroll.contentSize.width;table.autoresizingMask=[.width];sidebar.addSubview(scroll)
  addButton=styledButton(L("Nová složka"),symbol:"plus",frame:NSRect(x:16,y:22,width:208,height:34),target:self,action:#selector(addTopic));sidebar.addSubview(addButton)
  sidebar.addSubview(styledButton(L("Výchozí šablony…"),symbol:"doc.on.doc",role:.quiet,frame:NSRect(x:16,y:64,width:208,height:34),target:self,action:#selector(editDefaults)))
  // Název je nadpis; tužka nebo klik ho přepne do úprav.
  nameShell.isHidden=true;view.addSubview(nameShell)
  name.isBordered=false;name.drawsBackground=false;name.font = .systemFont(ofSize:23,weight:.semibold);name.textColor = .labelColor;name.usesSingleLineMode=true;name.lineBreakMode = .byTruncatingTail;name.isEditable=false;name.isSelectable=false;name.delegate=self
  name.placeholderString=L("Název složky");nameClick.target=self;nameClick.action=#selector(beginNameEdit);name.addGestureRecognizer(nameClick);view.addSubview(name)
  pencil=styledButton("",symbol:"pencil",role:.quiet,frame:.zero,target:self,action:#selector(beginNameEdit));pencil.toolTip=L("Přejmenovat složku");pencil.setAccessibilityLabel(pencil.toolTip);view.addSubview(pencil)
  star.target=self;star.action=#selector(toggleDefault);star.role = .quiet;view.addSubview(star)
  view.addSubview(designLabel(L("Určete, kam a jak se budou relace ukládat."),NSRect(x:272,y:530,width:560,height:22),size:12,color:AppPalette.secondary))
  view.addSubview(sectionLabel(L("Popis"),NSRect(x:272,y:478,width:600,height:18)));inputShell(detail,frame:NSRect(x:272,y:436,width:600,height:36),in:view)
  detail.placeholderString=L("Krátký popis pro snazší výběr")
  view.addSubview(sectionLabel(L("Složka"),NSRect(x:272,y:406,width:600,height:18)))
  inputShell(folder,frame:NSRect(x:272,y:364,width:450,height:36),in:view);folder.placeholderString=L("Vyber místní adresář")
  chooseFolderButton=styledButton(L("Vybrat…"),symbol:"folder",frame:NSRect(x:736,y:365,width:136,height:34),target:self,action:#selector(chooseFolder));view.addSubview(chooseFolderButton)
  syncButton=styledButton(L("Synchronizovat s cloudem"),symbol:"icloud.and.arrow.up",frame:NSRect(x:272,y:314,width:250,height:34),target:self,action:#selector(syncSelected));view.addSubview(syncButton)
  syncCaption=designLabel("",NSRect(x:536,y:320,width:336,height:22),size:11,color:AppPalette.secondary);view.addSubview(syncCaption)
  view.addSubview(DesignDivider(NSRect(x:272,y:296,width:600,height:1)))
  view.addSubview(sectionLabel(L("Ukládání relací"),NSRect(x:272,y:266,width:600,height:18)))
  mode.addItems(withTitles:[L("Samostatný Markdown pro každou relaci"),L("Všechny relace v jednom Markdownu")]);mode.target=self;mode.action=#selector(updateMode);inputShell(mode,frame:NSRect(x:272,y:224,width:376,height:36),in:view)
  templateButton=styledButton(L("Šablona Markdownu…"),symbol:"doc.text",frame:NSRect(x:662,y:225,width:210,height:34),target:self,action:#selector(editTemplate));view.addSubview(templateButton)
  askBeforeDelete.title=L("Ptát se před smazáním v cloudu");askBeforeDelete.frame=NSRect(x:272,y:104,width:600,height:22);askBeforeDelete.target=self;askBeforeDelete.action=#selector(toggleAskBeforeDelete);askBeforeDelete.isHidden=true;view.addSubview(askBeforeDelete)
  fileLabel=sectionLabel(L("Společný soubor"),NSRect(x:272,y:196,width:600,height:18));view.addSubview(fileLabel);inputShell(file,frame:NSRect(x:272,y:154,width:600,height:36),in:view)
  view.addSubview(DesignDivider(NSRect(x:272,y:72,width:600,height:1)))
  deleteButton=styledButton(L("Smazat složku…"),symbol:"trash",role:.quiet,frame:NSRect(x:524,y:22,width:166,height:34),target:self,action:#selector(deleteTopic));view.addSubview(deleteButton)
  saveStatus.frame=NSRect(x:272,y:28,width:244,height:22);saveStatus.font = .systemFont(ofSize:11);saveStatus.textColor=AppPalette.secondary;saveStatus.lineBreakMode = .byTruncatingTail;view.addSubview(saveStatus)
  saveButton=styledButton(L("Uložit složku"),symbol:"checkmark",role:.primary,frame:NSRect(x:700,y:22,width:172,height:34),target:self,action:#selector(saveTopic));view.addSubview(saveButton)
  NotificationCenter.default.addObserver(self,selector:#selector(foldersChanged),name:.cloudFoldersChanged,object:nil)
  reloadFolders();if present{presentScreenshotPanel(window)}
 }
 @objc func foldersChanged(){if !isExportingDesign{list=Topics.all};if window?.isVisible==true{if list.contains(where:{$0.id==editingID}){reloadTable();updateMode()}else{reloadFolders()}}}
 private func reloadTable(){table.reloadData();if let row=rows.firstIndex(where:{$0.id==editingID}){table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}}
 func reloadFolders(){
  table.reloadData();let row=rows.firstIndex{$0.id==editingID} ?? (rows.isEmpty ? nil:0)
  if let row{table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);load(rows[row])}
  else{editingID=nil;name.stringValue="";detail.stringValue="";folder.stringValue="";detail.isEnabled=false;saveButton?.isEnabled=false;folder.isEnabled=false;chooseFolderButton?.isEnabled=false;layoutHeading()}
  updateMode()
 }
 func numberOfRows(in tableView:NSTableView)->Int{rows.count}
 func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat{58}
 func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView?{DesignTopicRow()}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{
  let topic=rows[row];let cell=NSView(frame:NSRect(x:0,y:0,width:208,height:58));let cloud=topic.cloudFolderID != nil
  let icon=NSImageView(frame:NSRect(x:10,y:18,width:24,height:22));icon.image=NSImage(systemSymbolName:cloud ? "icloud":"icloud.slash",accessibilityDescription:cloud ? L("Cloudová složka"):L("Lokální složka"))?.withSymbolConfiguration(.init(pointSize:15,weight:.regular));icon.contentTintColor=cloud ? .systemBlue:.systemRed;cell.addSubview(icon)
  if topic.id==defaultID{let badge=NSImageView(frame:NSRect(x:26,y:11,width:13,height:13));badge.image=NSImage(systemSymbolName:"star.fill",accessibilityDescription:L("Výchozí složka"))?.withSymbolConfiguration(.init(pointSize:9,weight:.bold));badge.contentTintColor = .systemYellow;cell.addSubview(badge)}
  cell.addSubview(designLabel(topic.name,NSRect(x:46,y:28,width:152,height:21),size:13,weight:.medium))
  let secondary=(cloud ? (topic.folder.isEmpty ? L("Bez místního adresáře"):L("Cloud")):L("Jen na tomto Macu"))+" · "+(topic.combined ? L("Společný soubor"):L("Samostatné relace"))
  cell.addSubview(designLabel(secondary,NSRect(x:46,y:9,width:152,height:18),size:10,color:AppPalette.secondary));cell.toolTip=topic.name+(topic.id==defaultID ? "\n"+L("Výchozí složka"):"");return cell
 }
 func tableViewSelectionDidChange(_ notification:Notification){let row=table.selectedRow;if rows.indices.contains(row){load(rows[row])}}
 func load(_ topic:Topic){
  saveStatus.stringValue="";saveStatus.textColor=AppPalette.secondary;editingID=topic.id;pendingDefault=false
  template=topic.markdownTemplate ?? defaultMarkdownTemplate;fileTemplate=topic.combinedTemplate
  endNameEdit();name.stringValue=topic.name;detail.stringValue=topic.detail;folder.stringValue=topic.folder;file.stringValue=topic.combinedFile;mode.selectItem(at:topic.combined ? 1:0)
  detail.isEnabled=true;folder.isEnabled=true;chooseFolderButton?.isEnabled=true;saveButton?.isEnabled=true;layoutHeading();updateMode()
 }
 func layoutHeading(){
  let editing=name.isEditable,text=name.stringValue.isEmpty ? (name.placeholderString ?? ""):name.stringValue
  let width=editing ? 440:min(440,ceil((text as NSString).size(withAttributes:[.font:name.font!]).width)+6)
  name.frame=NSRect(x:editing ? 282:272,y:558,width:width,height:34);nameShell.frame=NSRect(x:272,y:556,width:width+20,height:38);nameShell.isHidden = !editing;nameClick.isEnabled = !editing
  pencil?.frame=NSRect(x:name.frame.maxX+(editing ? 16:6),y:561,width:28,height:28);pencil?.isHidden=editing
  star.frame=NSRect(x:(editing ? nameShell.frame.maxX:pencil.frame.maxX)+4,y:561,width:30,height:28)
  let isDefault=pendingDefault || (editingID != nil && editingID==defaultID);star.isOn=isDefault
  star.toolTip=isDefault ? L("Výchozí složka pro nové relace"):L("Nastavit jako výchozí složku");star.setAccessibilityLabel(star.toolTip)
 }
 @objc func beginNameEdit(){
  guard !name.isEditable else{return}
  name.isEditable=true;name.isSelectable=true;layoutHeading();window.makeFirstResponder(name);name.currentEditor()?.selectAll(nil)
 }
 func endNameEdit(){guard name.isEditable else{return};name.isEditable=false;name.isSelectable=false;if window?.firstResponder===name.currentEditor(){window.makeFirstResponder(nil)};layoutHeading()}
 func controlTextDidEndEditing(_ notification:Notification){if !isExportingDesign,(notification.object as? NSTextField)===name{name.stringValue=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);endNameEdit()}}
 func controlTextDidChange(_ notification:Notification){if (notification.object as? NSTextField)===name{layoutHeading()}}
 @objc func toggleDefault(){
  guard editingID != nil,list.contains(where:{$0.id==editingID}) else{pendingDefault.toggle();layoutHeading();return}
  // Výchozí složka jde jen přepnout na jinou, ne zrušit.
  guard editingID != defaultID else{return}
  if isExportingDesign{previewDefaultID=editingID}else{UserDefaults.standard.set(editingID,forKey:"defaultTopic")}
  reloadTable();layoutHeading()
 }
 @objc func updateMode(){
  let cloud=editingCloud,combined=mode.indexOfSelectedItem==1,saved=list.contains{$0.id==editingID}
  fileLabel?.isHidden = !combined;file.superview?.isHidden = !combined;file.isEnabled=combined
  guard let syncButton else{return}
  if cloud {
   syncButton.title=L("Synchronizováno s cloudem");syncButton.image=NSImage(systemSymbolName:"checkmark",accessibilityDescription:nil);syncButton.role = .success;syncButton.isHidden=false
   syncButton.toolTip=L("Složka se synchronizuje s cloudem. Kliknutím ji synchronizuješ hned.")
   syncCaption.stringValue=L("Relace se nahrávají do cloudu a stahují sem.")
  } else {
   syncButton.title=L("Synchronizovat s cloudem");syncButton.image=NSImage(systemSymbolName:"icloud.and.arrow.up",accessibilityDescription:nil);syncButton.role = .secondary
   syncButton.isHidden = !signedIn || !saved;syncButton.toolTip=L("Nahraje relace do cloudu a změní složku na cloudovou.")
   syncCaption.stringValue=signedIn ? (saved ? L("Relace jsou zatím jen na tomto Macu."):L("Synchronizaci zapneš po uložení složky.")):L("Pro synchronizaci připoj Mac v Cloudové knihovně.")
  }
  deleteButton?.isHidden = !saved
  let current=list.first{$0.id==editingID}
  askBeforeDelete.isHidden = !(cloud && current?.confirmLocalDeletes==false) || combined;askBeforeDelete.state = .off
  syncCaption.frame.origin.x=syncButton.isHidden ? 272:536;syncCaption.frame.size.width=syncButton.isHidden ? 600:336
  syncButton.needsDisplay=true
 }
 @objc func addTopic(){
  saveStatus.stringValue="";editingID=nil;pendingDefault=false;(template,fileTemplate)=defaults.newFolderTemplates;table.deselectAll(nil);detail.isEnabled=true;folder.isEnabled=true;chooseFolderButton.isEnabled=true;saveButton.isEnabled=true
  name.stringValue="";detail.stringValue="";folder.stringValue="";file.stringValue=defaultCombinedFile;mode.selectItem(at:0);updateMode();beginNameEdit()
 }
 @objc func syncSelected(){
  guard let topic=list.first(where:{$0.id==editingID}) else{return}
  if topic.cloudFolderID != nil{Task{@MainActor in await CloudLibrary.shared.sync();await CloudFolders.shared.refresh(CloudLibrary.shared.connection)};return}
  guard signedIn else{return}
  Task{@MainActor in
   await FolderDialogs.move([topic]);self.list=Topics.all
   if let moved=CloudFolders.shared.records.first(where:{$0.migratedLocalIDs?.contains(topic.id)==true}),let target=self.list.first(where:{$0.cloudFolderID==moved.id}){self.editingID=target.id}
   self.reloadFolders()
  }
 }
 /// Smaže složku: cloudovou i na webu (30 dní v Koši), adresář jde do Koše v macOS.
 @objc func deleteTopic(){
  guard let topic=list.first(where:{$0.id==editingID}) else{return}
  let alert=NSAlert();alert.messageText=LF("Smazat složku „%@“?",topic.name)
  alert.informativeText=topic.cloudFolderID != nil ? L("Složka se smaže i v cloudu (bude 30 dní v Koši na webu). Lokální soubory se přesunou do Koše v macOS."):L("Složka zmizí z aplikace a její lokální soubory se přesunou do Koše v macOS.")
  alert.addButton(withTitle:L("Smazat"));alert.addButton(withTitle:L("Zrušit"));alert.buttons[0].hasDestructiveAction=true
  guard alert.runModal() == .alertFirstButtonReturn else{return}
  Task{@MainActor in
   do {
    if topic.cloudFolderID != nil{try await CloudFolders.shared.trashFolder(topic)}else{try CloudFolders.shared.deleteLocalFolder(topic)}
    self.editingID=nil;self.list=Topics.all;self.reloadFolders()
   } catch {showError(error.localizedDescription)}
  }
 }
 /// Výchozí šablony pro nové složky; s účtem se ukládají na server.
 @objc func editDefaults(){
  var values=[defaults.effectiveSession,defaults.effectiveFile];var selected=0
  while let edited=MarkdownEditor().run(title:L("Výchozí šablony"),tabs:[(L("Šablona relace"),values[0],L("Proměnné: {title}, {screenshots}, {text}, {comments}")),(L("Šablona souboru"),values[1],L("Proměnné: {folderName}, {folderDescription}, {sessions}"))],selected:selected,apply:L("Uložit")){
   values=edited
   guard TemplateDefaults.valid(session:values[0],file:values[1]) else{selected=["{title}","{screenshots}","{text}"].allSatisfy{values[0].contains($0)} ? 1:0;showError(L("Šablona relace musí obsahovat {title}, {screenshots} a {text}; šablona souboru {sessions} právě jednou."));continue}
   let chosen=values
   Task{@MainActor in do{try await self.defaults.save(session:chosen[0],file:chosen[1]);self.showStatus(L("Výchozí šablony byly uloženy."))}catch{showError(error.localizedDescription)}}
   break
  }
  window.makeKeyAndOrderFront(nil)
 }
 /// Potvrzení změny šablony u existujících relací složky.
 private func confirmTemplateChange(_ original:Topic,template:String?,file:String?)->Bool {
  guard (original.markdownTemplate ?? defaultMarkdownTemplate) != (template ?? defaultMarkdownTemplate) || (original.combinedTemplate ?? defaultCombinedTemplate) != (file ?? defaultCombinedTemplate) else{return true}
  let count=indexedSessionCount(original);guard count>0,!isExportingDesign else{return true}
  let alert=NSAlert();alert.messageText=LP(count,"Šablona se použije na %ld relaci ve složce %@.","Šablona se použije na všechny %ld relace ve složce %@.","Šablona se použije na všech %ld relací ve složce %@.",count,original.name)
  alert.addButton(withTitle:L("Použít"));alert.addButton(withTitle:L("Zrušit"))
  return alert.runModal() == .alertFirstButtonReturn
 }
 @objc func toggleAskBeforeDelete(){
  guard askBeforeDelete.state == .on,let topic=list.first(where:{$0.id==editingID}) else{return}
  do{try CloudFolders.shared.setConfirmLocalDeletes(topic,true);list=Topics.all;updateMode()}catch{askBeforeDelete.state = .off;showError(error.localizedDescription)}
 }
 @objc func chooseFolder(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;if !folder.stringValue.isEmpty{panel.directoryURL=URL(fileURLWithPath:folder.stringValue)};if panel.runModal() == .OK,let url=panel.url{folder.stringValue=url.path}}
 @objc func editTemplate(){
  let sessionHint=L("Proměnné: {title}, {screenshots}, {text}, {comments}"),sessionError=L("Šablona musí obsahovat {title}, {screenshots} a {text}.")
  func validSession(_ value:String)->Bool{["{title}","{screenshots}","{text}"].allSatisfy{value.contains($0)}}
  if mode.indexOfSelectedItem==0 {
   var value=template
   while let edited=MarkdownEditor().run(value,title:L("Šablona Markdownu"),hint:sessionHint,apply:L("Použít šablonu")){
    value=edited;if validSession(value){template=value;break};showError(sessionError)
   }
  } else {
   var values=[template,fileTemplate ?? defaultCombinedTemplate];var selected=0
   while let edited=MarkdownEditor().run(title:L("Šablona Markdownu"),tabs:[(L("Šablona relace"),values[0],sessionHint),(L("Šablona souboru"),values[1],L("Proměnné: {folderName}, {folderDescription}, {sessions}"))],selected:selected,apply:L("Použít šablonu")){
    values=edited
    if !validSession(values[0]){selected=0;showError(sessionError);continue}
    if !validCombinedTemplate(values[1]){selected=1;showError(L("Šablona souboru musí obsahovat {sessions} právě jednou."));continue}
    template=values[0];fileTemplate=values[1]==defaultCombinedTemplate ? nil:values[1];break
   }
  }
  window.makeKeyAndOrderFront(nil)
 }
 private func showStatus(_ text:String,warning:Bool=false){saveStatus.stringValue=text;saveStatus.textColor=warning ? .systemOrange:AppPalette.secondary;saveStatus.alphaValue=0;animateDesign{saveStatus.animator().alphaValue=1}}
 @objc func saveTopic(){
  window.makeFirstResponder(nil);endNameEdit()
  let title=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),path=folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !title.isEmpty,path.hasPrefix("/") else{showError(L("Vyplň název konfigurace a absolutní cestu ke složce."));return}
  let rawFile=(file.stringValue as NSString).deletingPathExtension
  let filename=(filenameFromTitle(rawFile) ?? filenameFromTitle(title) ?? "Screenshoty")+".md"
  if editingCloud {
   guard let original=list.first(where:{$0.id==editingID}) else{return}
   var changed=original;changed.name=title;changed.detail=detail.stringValue;changed.combined=mode.indexOfSelectedItem==1;changed.combinedFile=filename
   changed.markdownTemplate=original.markdownTemplate==nil && template==defaultMarkdownTemplate ? nil:template;changed.combinedTemplate=fileTemplate
   guard confirmTemplateChange(original,template:changed.markdownTemplate,file:changed.combinedTemplate) else{return}
   do{if original.folder != path{try CloudFolders.shared.setFolder(original,path:path)}}catch{showError(error.localizedDescription);return}
   changed.folder=path
   guard changed != (list.first{$0.id==editingID}.map{var value=$0;value.folder=path;return value}) else{list=Topics.all;reloadTable();showStatus(L("Konfigurace byla uložena."));refreshCloud();return}
   saveButton.isEnabled=false;saveStatus.stringValue=L("Ukládám do cloudu…")
   Task{@MainActor in
    defer{self.saveButton.isEnabled=true}
    do{let saved=try await CloudFolders.shared.update(changed);self.list=Topics.all;self.editingID=saved.id;self.reloadFolders();self.showStatus(L("Konfigurace byla uložena."));self.refreshCloud()}
    catch let failure as CloudFailure where failure.code=="folder_conflict"{self.list=Topics.all;self.reloadFolders();self.showStatus(failure.message,warning:true)}
    catch{self.saveStatus.stringValue="";showError(error.localizedDescription)}
   }
   return
  }
  var topic=Topic(id:editingID ?? UUID().uuidString,name:title,detail:detail.stringValue,folder:path,combined:mode.indexOfSelectedItem==1,combinedFile:filename,markdownTemplate:template,combinedTemplate:fileTemplate)
  let previous=list.first{$0.id==topic.id && $0.cloudFolderID==nil}
  if let previous{topic.formerCloudFolderID=previous.formerCloudFolderID;topic.formerCloudOwnerID=previous.formerCloudOwnerID;topic.formerCloudOrigin=previous.formerCloudOrigin}
  if let previous,!confirmTemplateChange(previous,template:topic.markdownTemplate,file:topic.combinedTemplate){return}
  var updated=list.filter{$0.cloudFolderID==nil}
  if let i=updated.firstIndex(where:{$0.id==topic.id}){updated[i]=topic}else{updated.append(topic)}
  let defaultValue=pendingDefault ? topic.id:(UserDefaults.standard.string(forKey:"defaultTopic") ?? Topics.defaultTopic.id)
  do {
   try Topics.save(updated,defaultID:defaultValue);list=Topics.all;editingID=topic.id;reloadTable();load(topic);showStatus(L("Konfigurace byla uložena."))
   // Změněná šablona se použije na všechny relace složky.
   if let previous,previous.markdownTemplate != topic.markdownTemplate || previous.combinedTemplate != topic.combinedTemplate || (topic.combined && (previous.name != topic.name || previous.detail != topic.detail)) {
    let result=rerenderFolder(topic,previous:previous)
    if result.edited>0{showStatus(LP(result.edited,"%ld relace byla ručně upravena, nová verze je uložená vedle (_template).","%ld relace byly ručně upraveny, nová verze je uložená vedle (_template).","%ld relací bylo ručně upraveno, nová verze je uložená vedle (_template).",result.edited),warning:true)}
   }
  }catch{showError(error.localizedDescription)}
 }
 private func refreshCloud(){Task{@MainActor in await CloudFolders.shared.refresh(CloudLibrary.shared.connection)}}
}
