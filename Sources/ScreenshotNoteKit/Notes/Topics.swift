import AppKit

struct Topic:Codable,Equatable {
 var id:String;var name:String;var detail:String;var folder:String;var combined:Bool;var combinedFile:String;var markdownTemplate:String? = nil;var uploadToCloud:Bool? = nil;var cloudOnly:Bool? = nil
 var cloudFolderID:UUID? = nil;var cloudOwnerID:UUID? = nil;var cloudOrigin:String? = nil
 // Šablona celého společného souboru; nil znamená výchozí.
 var combinedTemplate:String? = nil
 // Šablony komentáře a obrázku; nil znamená vestavěnou.
 var commentTemplate:String? = nil;var imageTemplate:String? = nil
 // Dřívější cloudová složka po odhlášení; slouží k nabídce znovupropojení.
 var formerCloudFolderID:UUID? = nil;var formerCloudOwnerID:UUID? = nil;var formerCloudOrigin:String? = nil
 // Jen pro cloudovou složku na tomto Macu: false = smazání z disku jde do Koše bez dotazu.
 var confirmLocalDeletes:Bool? = nil
 // Týmová složka: název týmu a role přihlášeného uživatele z katalogu.
 var cloudOwnerName:String? = nil;var cloudTeam:Bool? = nil;var cloudRole:String? = nil
 // Cloudová složka: AI návrh názvu relace (nastavení serveru).
 var aiTitle:Bool? = nil
 // Výchozí název relace bez názvu; nil = globální nastavení.
 var defaultTitle:String? = nil
 // Kontext z prohlížeče u lokální složky; nil znamená výchozí politiku.
 var contextPolicy:ContextPolicy? = nil
 // Cloudová složka: strom podsložek ze serveru.
 var subfolders:[CloudSubfolder]? = nil
 /// Zobrazovaný název; týmová složka má vždy předponu týmu.
 var displayName:String{cloudTeam==true ? LF("%@ · %@",cloudOwnerName ?? L("Tým"),name):name}
 /// Přejmenovat, nastavit a smazat týmovou složku smí jen vlastník nebo správce týmu.
 var canManageCloudFolder:Bool{cloudTeam != true || LibraryRole.manages(cloudRole)}
 var savesLocally:Bool{cloudFolderID == nil ? cloudOnly != true:!folder.isEmpty}
 var savesToCloud:Bool{cloudFolderID != nil || cloudOnly == true || uploadToCloud == true}
 var destination:URL{URL(fileURLWithPath:folder,isDirectory:true)}
 /// Typ úložiště pro výběr složky: tým, osobní cloud, nebo jen na tomto Macu.
 var storageKind:String{cloudTeam==true ? LF("Tým %@",cloudOwnerName ?? L("Tým")):cloudFolderID != nil ? L("Osobní cloud"):L("Jen na tomto Macu")}
 var storageSymbol:String{cloudTeam==true ? "person.2":cloudFolderID != nil ? "icloud":"folder"}
 /// Řádek pod názvem ve výběru: typ, popis a místní adresář bez prázdných částí.
 var choiceDetail:String{[storageKind,detail,folder].filter{!$0.isEmpty}.joined(separator:" · ")}
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
 /// `child` leží uvnitř `parent`; porovnává se po předcích jako `sameDestination`.
 static func inside(_ child:URL,_ parent:URL)->Bool {
  if parent.standardizedFileURL.path=="/"{return child.standardizedFileURL.path != "/"}
  var current=child.standardizedFileURL
  while current.path != "/" {current.deleteLastPathComponent();if current.path != "/",sameDestination(current,parent){return true}}
  return false
 }
 /// Stejný adresář, předek nebo potomek; složky se nesmí překrývat.
 static func overlaps(_ lhs:URL,_ rhs:URL)->Bool{sameDestination(lhs,rhs) || inside(lhs,rhs) || inside(rhs,lhs)}
 static func nestedError(_ other:Topic)->CloudFailure{CloudFailure(LF("Adresář leží uvnitř složky „%@“ (nebo ji obsahuje). Vyber adresář mimo ni.",other.displayName))}
 /// První jiná složka, se kterou se adresář překrývá (i dřív uložené vnoření).
 static func overlapping(_ topic:Topic,among list:[Topic])->Topic? {
  guard topic.savesLocally,let target=try? checkedDestination(topic.folder) else{return nil}
  return list.first{$0.id != topic.id && $0.savesLocally && (try? checkedDestination($0.folder)).map{overlaps(target,$0)}==true}
 }
 /// Nadřazená složka cloudu nesmí být složkou ani ležet uvnitř žádné složky.
 static func validateParent(_ root:URL,among list:[Topic])throws {
  let target=try checkedDestination(root.path)
  for other in list where other.savesLocally {
   let folder=try checkedDestination(other.folder)
   if sameDestination(target,folder) || inside(target,folder){throw nestedError(other)}
  }
 }
 /// Uložený seznam: kolize jen u stejného adresáře, aby starší vnořené složky nezablokovaly ukládání ostatních.
 static func validateDestinations(_ list:[Topic])throws {
  var checked:[(Topic,URL)]=[]
  for topic in list where topic.savesLocally {
   let target=try checkedDestination(topic.folder)
   if let other=checked.first(where:{sameDestination($0.1,target)}) {
    throw CloudFailure(LF("Složku už používá „%@“. Pro „%@“ vyber jinou složku.",other.0.displayName,topic.displayName))
   }
   checked.append((topic,target))
  }
 }
 /// Adresář nastavované složky; `nested` povolí dřív uložené vnoření (synchronizace, ukládání snímku).
 static func validateDestination(_ topic:Topic,folder:URL,among supplied:[Topic]?=nil,nested:Bool=false)throws {
  if supplied==nil && !CloudFolders.shared.isReadable{throw CloudFailure.invalid}
  let list=supplied ?? (Topics.local+CloudFolders.shared.allTopics)
  let target=try checkedDestination(folder.path)
  for other in list where other.id != topic.id && other.savesLocally {
   let existing=try checkedDestination(other.folder)
   if sameDestination(target,existing) {
    throw CloudFailure(LF("Složku už používá „%@“. Pro „%@“ vyber jinou složku.",other.displayName,topic.displayName))
   }
   if !nested,inside(target,existing) || inside(existing,target){throw nestedError(other)}
  }
 }
 /// Adresář leží na disku v /Volumes, který teď není připojený; nesmí vzniknout na systémovém disku.
 static func volumeMissing(_ path:String)->Bool {
  let parts=URL(fileURLWithPath:path).standardizedFileURL.pathComponents
  return parts.count>=3 && parts[1]=="Volumes" && !fm.fileExists(atPath:"/Volumes/"+parts[2])
 }
 static func ensureVolume(_ path:String)throws{if volumeMissing(path){throw CloudFailure(L("Disk se složkou není připojený. Připoj ho, nebo vyber jiný adresář."))}}
 /// Lokální složka, jejíž adresář zmizel, ačkoli do něj aplikace dřív ukládala relace.
 static func missingLocal(_ topic:Topic)->Bool {
  guard topic.cloudFolderID==nil,topic.savesLocally,!topic.folder.isEmpty,!fm.fileExists(atPath:topic.folder) else{return false}
  let key=SessionIndex.key(topic.destination)+"/"
  return SessionIndex.shared.all.contains{!$0.isCloud && $0.file.hasPrefix(key)}
 }
 /// Nový adresář lokální složky po zmizení starého; kontroluje kolize i vnoření.
 static func relocateLocal(_ topic:Topic,to url:URL)throws {
  guard CloudFolders.shared.isReadable else{throw CloudFailure.invalid}
  var list=storedLocal;guard let i=list.firstIndex(where:{$0.id==topic.id}) else{throw CloudFailure.invalid}
  try validateDestination(topic,folder:url,among:local+CloudFolders.shared.allTopics)
  list[i].folder=url.path;try storeLocal(list)
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
final class TopicSettings:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSWindowDelegate {
 /// O kolik je okno vyšší než původních 620 px; horní část formuláře se posouvá o stejnou hodnotu.
 static let lift:CGFloat=32
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
 // Náhled stromu podsložek; spravuje se ve snímání nebo na webu.
 private(set) var subfolderButton:AppButton!
 let name=CenteredTextField(),detail=CenteredTextField(),folder=CenteredTextField(),file=CenteredTextField()
 var template=defaultMarkdownTemplate;var fileTemplate:String?;var commentTemplate:String?;var imageTemplate:String?
 var pendingDefault=false
 // Nová složka dostane kopii výchozích šablon.
 var defaults=TemplateDefaults.shared
 let saveStatus=NSTextField(labelWithString:"")
 // Politika kontextu z prohlížeče; uloží se spolu se složkou.
 var contextPolicy=ContextPolicy()
 let contextToggle=NSButton(checkboxWithTitle:"",target:nil,action:nil)
 private(set) var contextButton:AppButton!;private(set) var contextCaption:NSTextField!
 // AI návrh názvu jen u cloudové složky; mění ho vlastník nebo správce, platí hned na serveru.
 let aiTitleToggle=NSButton(checkboxWithTitle:"",target:nil,action:nil)
 // Výchozí název relace bez názvu; u cloudové složky platí hned na serveru, u místní s uložením.
 private(set) var defaultTitleButton:AppButton!;var defaultTitleValue:String?=nil
 let mode=NSPopUpButton()
 // Stav formuláře po načtení složky; rozdíl znamená neuložené změny.
 private var loadedForm:[String]?
 // Zapínání AI názvu čeká na server; mezitím přepínač drží zvolenou hodnotu.
 private var pendingAITitle:(id:String,value:Bool)?
 // AI nastavení chybějící v katalogu se dotáže jednou za otevření.
 private var aiTitleRequested=Set<String>()
 func show(present:Bool=true,reload:Bool=true){
  if let w=window{if !isExportingDesign && reload{list=Topics.all};reloadFolders();if present{presentScreenshotPanel(w)};return}
  if !isExportingDesign && reload{list=Topics.all}
  window=ScreenshotPanel(contentRect:NSRect(x:0,y:0,width:900,height:620+Self.lift),styleMask:[.titled,.closable,.nonactivatingPanel],backing:.buffered,defer:false);window.title=L("Konfigurace");window.isReleasedWhenClosed=false;window.delegate=self
  let view=installDesignRoot(window,headerHeight:108)
  let sidebar=DesignSurface(frame:NSRect(x:0,y:0,width:240,height:620+Self.lift),fill:AppPalette.raised);view.addSubview(sidebar)
  sidebar.addSubview(designLabel(L("Složky"),NSRect(x:20,y:562,width:200,height:30),size:19,weight:.semibold))
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("topic"));column.width=208;table.addTableColumn(column);table.headerView=nil;table.rowHeight=58;table.intercellSpacing=NSSize(width:0,height:3);table.delegate=self;table.dataSource=self;table.style = .plain;table.backgroundColor=AppPalette.raised;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  let scroll=NSScrollView(frame:NSRect(x:12,y:68,width:216,height:478));scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;table.frame=NSRect(x:0,y:0,width:216,height:470);scroll.documentView=table;table.frame.size.width=scroll.contentSize.width;table.autoresizingMask=[.width];sidebar.addSubview(scroll)
  // Úzký překryvný posuvník; čára odděluje seznam od tlačítek dole.
  scroll.scrollerStyle = .overlay;scroll.verticalScroller?.controlSize = .small
  sidebar.addSubview(DesignDivider(NSRect(x:16,y:64,width:208,height:1)))
  // Dole jen Nová složka; výchozí název a šablony jsou v menu „⋯“.
  addButton=styledButton(L("Nová složka"),symbol:"plus",frame:NSRect(x:16,y:16,width:160,height:34),target:self,action:#selector(addTopic));sidebar.addSubview(addButton)
  let more=styledButton("",symbol:"ellipsis",role:.quiet,frame:NSRect(x:184,y:16,width:40,height:34),target:self,action:#selector(showDefaultsMenu(_:)))
  more.toolTip=L("Výchozí název a šablony");more.setAccessibilityLabel(L("Výchozí název a šablony"));sidebar.addSubview(more)
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
  subfolderButton=styledButton("",symbol:"list.bullet.indent",role:.quiet,frame:NSRect(x:652,y:401,width:220,height:26),target:self,action:#selector(showSubfolders(_:)));subfolderButton.alignment = .right;view.addSubview(subfolderButton)
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
  contextToggle.title=L("Přikládat kontext z prohlížeče");contextToggle.frame=NSRect(x:272,y:120,width:380,height:22);contextToggle.target=self;contextToggle.action=#selector(toggleContext);view.addSubview(contextToggle)
  contextCaption=designLabel("",NSRect(x:292,y:90,width:358,height:28),size:11,color:AppPalette.secondary);view.addSubview(contextCaption)
  // Dlouhý popis se zalomí, aby nezasahoval pod tlačítka vpravo.
  contextCaption.usesSingleLineMode=false;contextCaption.maximumNumberOfLines=2;contextCaption.lineBreakMode = .byWordWrapping;contextCaption.cell?.wraps=true;contextCaption.cell?.truncatesLastVisibleLine=true
  contextButton=styledButton(L("Nastavení kontextu…"),symbol:"slider.horizontal.3",frame:NSRect(x:662,y:114,width:210,height:34),target:self,action:#selector(editContext));view.addSubview(contextButton)
  aiTitleToggle.title=L("Navrhovat názvy relací pomocí AI");aiTitleToggle.frame=NSRect(x:272,y:122,width:380,height:22);aiTitleToggle.target=self;aiTitleToggle.action=#selector(toggleAITitle);aiTitleToggle.isHidden=true;view.addSubview(aiTitleToggle)
  defaultTitleButton=styledButton("",symbol:"textformat",role:.secondary,frame:NSRect(x:662,y:122,width:210,height:34),target:self,action:#selector(editTopicDefaultTitle));view.addSubview(defaultTitleButton)
  // Linka ve stejné výšce jako v postranním panelu, tlačítka s odstupem pod ní.
  view.addSubview(DesignDivider(NSRect(x:272,y:64,width:600,height:1)))
  deleteButton=styledButton(L("Smazat složku…"),symbol:"trash",role:.quiet,frame:NSRect(x:524,y:16,width:166,height:34),target:self,action:#selector(deleteTopic));view.addSubview(deleteButton)
  // Hláška svisle na středu tlačítek.
  saveStatus.frame=NSRect(x:272,y:25,width:244,height:16);saveStatus.font = .systemFont(ofSize:11);saveStatus.textColor=AppPalette.secondary;saveStatus.lineBreakMode = .byTruncatingTail;view.addSubview(saveStatus)
  saveButton=styledButton(L("Uložit složku"),symbol:"checkmark",role:.primary,frame:NSRect(x:700,y:16,width:172,height:34),target:self,action:#selector(saveTopic));view.addSubview(saveButton)
  NotificationCenter.default.addObserver(self,selector:#selector(foldersChanged),name:.cloudFoldersChanged,object:nil)
  // Horní část formuláře jde o lift výš; kontext a výchozí název dole tak mají místo nad linkou.
  for child in view.subviews+sidebar.subviews where child !== sidebar && child.frame.minY>=150 && child.autoresizingMask.isEmpty {child.frame.origin.y+=Self.lift}
  scroll.frame.size.height+=Self.lift
  reloadFolders();if present{presentScreenshotPanel(window)}
 }
 @objc func foldersChanged(){
  if !isExportingDesign{list=Topics.all}
  guard window?.isVisible==true else{return}
  // Rozpracovaná nová složka zůstane otevřená i po změně seznamu.
  if editingID==nil,loadedForm != nil{table.reloadData();return}
  if list.contains(where:{$0.id==editingID}){reloadTable();updateMode()}else{reloadFolders()}
 }
 private func reloadTable(){table.reloadData();if let row=rows.firstIndex(where:{$0.id==editingID}){table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}}
 func reloadFolders(){
  table.reloadData();let row=rows.firstIndex{$0.id==editingID} ?? (rows.isEmpty ? nil:0)
  if let row{table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);load(rows[row])}
  else{editingID=nil;name.stringValue="";detail.stringValue="";folder.stringValue="";detail.isEnabled=false;saveButton?.isEnabled=false;folder.isEnabled=false;chooseFolderButton?.isEnabled=false;layoutHeading();loadedForm=nil;updateSubfolders(nil)}
  updateMode()
 }
 func numberOfRows(in tableView:NSTableView)->Int{rows.count}
 @objc func showDefaultsMenu(_ sender:NSButton){
  let menu=NSMenu();menu.autoenablesItems=false
  for (title,symbol,action) in [(L("Výchozí název…"),"textformat",#selector(editGlobalDefaultTitle)),(L("Výchozí šablony…"),"doc.on.doc",#selector(editDefaults))]{
   let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);menu.addItem(item)
  }
  // Nadřazená složka cloudu: nastavená = nové cloudové složky se mapují samy, jinak se appka ptá.
  menu.addItem(.separator())
  let root=NSMenuItem(title:L("Nadřazená složka cloudu…"),action:#selector(chooseCloudRoot),keyEquivalent:"");root.target=self;root.image=NSImage(systemSymbolName:"externaldrive.badge.icloud",accessibilityDescription:nil)
  root.toolTip=L("Nové cloudové složky dostanou podsložku tady.");menu.addItem(root)
  if let current=FolderDialogs.cloudRoot{
   let path=NSMenuItem(title:(current.path as NSString).abbreviatingWithTildeInPath,action:nil,keyEquivalent:"");path.isEnabled=false;path.indentationLevel=1;menu.addItem(path)
   let reset=NSMenuItem(title:L("Ptát se na složku u nové cloudové složky"),action:#selector(resetCloudRoot),keyEquivalent:"");reset.target=self;reset.indentationLevel=1;menu.addItem(reset)
  }else{
   let none=NSMenuItem(title:L("Nenastaveno, u nové cloudové složky se zeptám."),action:nil,keyEquivalent:"");none.isEnabled=false;none.indentationLevel=1;menu.addItem(none)
  }
  menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height+4),in:sender)
 }
 @objc func chooseCloudRoot(){
  let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L("Vybrat")
  panel.message=L("V této složce se vytvoří podsložky pojmenované podle cloudových složek.");panel.directoryURL=FolderDialogs.cloudRoot
  guard panel.runModal() == .OK,let url=panel.url else{return}
  do{try Topics.validateParent(url,among:Topics.all)}catch{showError(error.localizedDescription);return}
  FolderDialogs.cloudRoot=url;Task{@MainActor in await FolderDialogs.mapUnmapped()}
 }
 @objc func resetCloudRoot(){FolderDialogs.cloudRoot=nil}
 func tableView(_ tableView:NSTableView,heightOfRow row:Int)->CGFloat{58}
 func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView?{DesignTopicRow()}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{
  let topic=rows[row];let cell=NSView(frame:NSRect(x:0,y:0,width:208,height:58));let cloud=topic.cloudFolderID != nil,team=topic.cloudTeam==true
  let icon=NSImageView(frame:NSRect(x:10,y:18,width:24,height:22));icon.image=NSImage(systemSymbolName:team ? "person.2":cloud ? "icloud":"icloud.slash",accessibilityDescription:team ? L("Týmová složka"):cloud ? L("Cloudová složka"):L("Lokální složka"))?.withSymbolConfiguration(.init(pointSize:15,weight:.regular));icon.contentTintColor=cloud ? .systemBlue:.systemRed;cell.addSubview(icon)
  if topic.id==defaultID{let badge=NSImageView(frame:NSRect(x:26,y:11,width:13,height:13));badge.image=NSImage(systemSymbolName:"star.fill",accessibilityDescription:L("Výchozí složka"))?.withSymbolConfiguration(.init(pointSize:9,weight:.bold));badge.contentTintColor = .systemYellow;cell.addSubview(badge)}
  cell.addSubview(designLabel(topic.displayName,NSRect(x:46,y:28,width:152,height:21),size:13,weight:.medium))
  // Starší vnořená složka má místo popisu varování.
  let nested=Topics.overlapping(topic,among:list) != nil
  let secondary=nested ? L("Vnořená složka · změň adresář"):(cloud ? (topic.folder.isEmpty ? L("Bez místního adresáře"):L("Cloud")):L("Jen na tomto Macu"))+" · "+(topic.combined ? L("Společný soubor"):L("Samostatné relace"))
  cell.addSubview(designLabel(secondary,NSRect(x:46,y:9,width:152,height:18),size:10,color:nested ? .systemOrange:AppPalette.secondary));cell.toolTip=topic.displayName+(topic.id==defaultID ? "\n"+L("Výchozí složka"):"");return cell
 }
 // Znovuvybrání stejné složky po překreslení seznamu nesmí přepsat rozpracovaný formulář.
 func tableViewSelectionDidChange(_ notification:Notification){
  let row=table.selectedRow
  if rows.indices.contains(row){if rows[row].id != editingID{load(rows[row])}}
  // Zrušený výběr uložené složky vrátí uložené hodnoty, aby formulář neukazoval zahozené změny.
  else if let saved=list.first(where:{$0.id==editingID}),hasUnsavedChanges{load(saved)}
 }
 func selectionShouldChange(in tableView:NSTableView)->Bool{confirmLeave()}
 func windowShouldClose(_ sender:NSWindow)->Bool{confirmLeave()}
 /// Hodnoty formuláře; u cloudové složky se kontext a výchozí název ukládají hned, proto se nepočítají.
 private func formState()->[String] {
  let cloud=editingCloud,encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
  let policy=cloud ? "":((try? encoder.encode(contextPolicy)).map{String(decoding:$0,as:UTF8.self)} ?? "")
  return [name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),detail.stringValue,folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),String(mode.indexOfSelectedItem),mode.indexOfSelectedItem==1 ? file.stringValue:"",template,fileTemplate ?? "",commentTemplate ?? "",imageTemplate ?? "",policy,cloud ? "":(defaultTitleValue ?? ""),pendingDefault ? "1":""]
 }
 private func markLoaded(){loadedForm=formState()}
 var hasUnsavedChanges:Bool{guard !isExportingDesign,let loadedForm else{return false};return formState() != loadedForm}
 /// Neuložené změny: zůstat, nebo odejít bez uložení.
 func confirmLeave()->Bool {
  guard hasUnsavedChanges else{return true}
  let alert=NSAlert();alert.messageText=editingID==nil ? L("Nová složka ještě není uložená."):L("Složka má neuložené změny.")
  alert.informativeText=L("Když odejdeš, změny se zahodí.")
  alert.addButton(withTitle:L("Zůstat"));alert.addButton(withTitle:L("Odejít bez uložení"))
  // Základ se obnoví až načtením jiné složky; formulář, který zůstal otevřený, se dál hlídá.
  return alert.runModal() == .alertSecondButtonReturn
 }
 func load(_ topic:Topic){
  saveStatus.stringValue="";saveStatus.textColor=AppPalette.secondary;editingID=topic.id;pendingDefault=false
  template=topic.markdownTemplate ?? defaultMarkdownTemplate;fileTemplate=topic.combinedTemplate;commentTemplate=topic.commentTemplate;imageTemplate=topic.imageTemplate;contextPolicy=topic.cloudFolderID.map{CloudContextPolicies.policy($0)} ?? topic.contextPolicy ?? ContextPolicy();defaultTitleValue=topic.defaultTitle
  endNameEdit();name.stringValue=topic.name;detail.stringValue=topic.detail;folder.stringValue=topic.folder;file.stringValue=topic.combinedFile;mode.selectItem(at:topic.combined ? 1:0)
  detail.isEnabled=true;folder.isEnabled=true;chooseFolderButton?.isEnabled=true;saveButton?.isEnabled=true;layoutHeading();updateMode();markLoaded()
  updateSubfolders(topic)
  if let other=Topics.overlapping(topic,among:list){showStatus(Topics.nestedError(other).message,warning:true)}
 }
 /// Týmovou složku smí nastavovat jen vlastník nebo správce; člen mění jen místní adresář.
 private var editingManaged:Bool{list.first{$0.id==editingID}?.canManageCloudFolder ?? true}
 func layoutHeading(){
  let editing=name.isEditable,text=name.stringValue.isEmpty ? (name.placeholderString ?? ""):name.stringValue
  let width=editing ? 440:min(440,ceil((text as NSString).size(withAttributes:[.font:name.font!]).width)+6)
  name.frame=NSRect(x:editing ? 282:272,y:558+Self.lift,width:width,height:34);nameShell.frame=NSRect(x:272,y:556+Self.lift,width:width+20,height:38);nameShell.isHidden = !editing;nameClick.isEnabled = !editing
  pencil?.frame=NSRect(x:name.frame.maxX+(editing ? 16:6),y:561+Self.lift,width:28,height:28);pencil?.isHidden=editing || !editingManaged
  star.frame=NSRect(x:(editing ? nameShell.frame.maxX:pencil.frame.maxX)+4,y:561+Self.lift,width:30,height:28)
  let isDefault=pendingDefault || (editingID != nil && editingID==defaultID);star.isOn=isDefault
  star.toolTip=isDefault ? L("Výchozí složka pro nové relace"):L("Nastavit jako výchozí složku");star.setAccessibilityLabel(star.toolTip)
 }
 @objc func beginNameEdit(){
  guard !name.isEditable,editingManaged else{return}
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
 /// Počet podsložek u nadpisu Složka; bez podpory serveru (nebo bez místního adresáře) skryté.
 func updateSubfolders(_ topic:Topic?) {
  guard let subfolderButton else{return}
  let supported=topic.map{$0.cloudFolderID != nil ? $0.subfolders != nil:!$0.folder.isEmpty} ?? false
  let count=supported ? topic.map(subfolderChoices)?.count ?? 0:0
  subfolderButton.isHidden = !supported
  subfolderButton.title=count==0 ? L("Bez podsložek"):LP(count,"%ld podsložka","%ld podsložky","%ld podsložek",count)
  subfolderButton.toolTip=L("Podsložky vytvoříš ve snímání (Podsložka → Nová podsložka…) nebo na webu.")
  subfolderButton.needsDisplay=true
 }
 @objc func showSubfolders(_ sender:NSButton){
  guard let topic=list.first(where:{$0.id==editingID}) else{return}
  let menu=NSMenu();menu.autoenablesItems=false
  let choices=subfolderChoices(topic)
  for choice in choices{let item=NSMenuItem(title:choice.name,action:nil,keyEquivalent:"");item.isEnabled=false;item.indentationLevel=choice.depth;item.image=NSImage(systemSymbolName:"folder",accessibilityDescription:nil);menu.addItem(item)}
  if !choices.isEmpty{menu.addItem(.separator())}
  let hint=NSMenuItem(title:topic.cloudFolderID != nil ? L("Spravuješ je ve snímání nebo na webu."):L("Vytvoříš je ve snímání; jsou to adresáře ve složce."),action:nil,keyEquivalent:"");hint.isEnabled=false;menu.addItem(hint)
  menu.popUp(positioning:nil,at:NSPoint(x:0,y:sender.isFlipped ? sender.bounds.maxY+4:sender.bounds.minY-4),in:sender)
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
   // Bez tarifu tlačítko vede na tarify místo přesunu.
   if signedIn,saved,!CloudFolders.shared.canMoveToCloud{syncButton.title=L("Aktivovat cloud…");syncButton.image=NSImage(systemSymbolName:"icloud",accessibilityDescription:nil);syncButton.toolTip=L("Cloud vyžaduje aktivní tarif nebo zkušební období.");syncCaption.stringValue=L("Synchronizace potřebuje tarif nebo zkušební období.")}
  }
  deleteButton?.isHidden = !saved || !editingManaged
  let current=list.first{$0.id==editingID}
  // Člen týmu nemění nastavení týmové složky, jen místní adresář.
  let managed=editingManaged;if editingID != nil{detail.isEnabled=managed};mode.isEnabled=managed;file.isEnabled=combined && managed;templateButton?.isEnabled=managed;pencil?.isHidden=name.isEditable || !managed
  if let current,current.cloudTeam==true{syncCaption.stringValue=managed ? LF("Složka týmu %@. Relace se nahrávají do cloudu a stahují sem.",current.cloudOwnerName ?? L("Tým")):L("Týmovou složku nastavuje vlastník nebo správce týmu. Tady vybereš jen místní adresář.")}
  askBeforeDelete.isHidden = !(cloud && current?.confirmLocalDeletes==false) || combined;askBeforeDelete.state = .off
  updateContext()
  syncCaption.frame.origin.x=syncButton.isHidden ? 272:536;syncCaption.frame.size.width=syncButton.isHidden ? 600:336
  syncButton.needsDisplay=true
 }
 @objc func addTopic(){
  guard confirmLeave() else{return}
  saveStatus.stringValue="";editingID=nil;pendingDefault=false;(template,fileTemplate)=defaults.newFolderTemplates;commentTemplate=defaults.comment;imageTemplate=defaults.image;contextPolicy=ContextPolicy();defaultTitleValue=nil;table.deselectAll(nil);detail.isEnabled=true;folder.isEnabled=true;chooseFolderButton.isEnabled=true;saveButton.isEnabled=true
  name.stringValue="";detail.stringValue="";folder.stringValue="";file.stringValue=defaultCombinedFile;mode.selectItem(at:0);updateMode();markLoaded();beginNameEdit()
 }
 @objc func syncSelected(){
  guard let topic=list.first(where:{$0.id==editingID}) else{return}
  if topic.cloudFolderID != nil{Task{@MainActor in await CloudLibrary.shared.sync();await CloudFolders.shared.refresh(CloudLibrary.shared.connection)};return}
  if signedIn,!CloudFolders.shared.canMoveToCloud{Task{@MainActor in if await FolderDialogs.cloudReady(){self.updateMode();self.syncSelected()}else{self.updateMode()}};return}
  guard signedIn else{return}
  // Přesun pracuje s uloženou složkou; neuložené změny by se ztratily.
  if hasUnsavedChanges{showError(L("Nejdřív ulož změny složky, pak ji synchronizuj s cloudem."));return}
  Task{@MainActor in
   await FolderDialogs.move([topic]);self.list=Topics.all
   if let moved=CloudFolders.shared.records.first(where:{$0.migratedLocalIDs?.contains(topic.id)==true}),let target=self.list.first(where:{$0.cloudFolderID==moved.id}){self.editingID=target.id}
   self.reloadFolders()
  }
 }
 /// Smaže složku: cloudovou i na webu (30 dní v Koši), adresář jde do Koše v macOS.
 @objc func deleteTopic(){
  guard let topic=list.first(where:{$0.id==editingID}) else{return}
  let alert=NSAlert();alert.messageText=LF("Smazat složku „%@“?",topic.displayName)
  alert.informativeText=topic.cloudFolderID != nil ? L("Složka se smaže i v cloudu (bude 30 dní v Koši na webu). Lokální soubory se přesunou do Koše v macOS."):L("Složka zmizí z aplikace a její lokální soubory se přesunou do Koše v macOS.")
  // Cizí soubory v adresáři zůstávají; uživatel to ví předem.
  if !topic.folder.isEmpty,CloudFolders.shared.hasUnknownFiles(topic.folder){alert.informativeText+="\n\n"+L("Adresář obsahuje i jiné soubory. Ty zůstanou na místě; do Koše v macOS se přesunou jen poznámky Screenshot Note.")}
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
  var values=[defaults.effectiveSession,defaults.effectiveFile,defaults.comment ?? defaultCommentTemplate,defaults.image ?? defaultImageTemplate];var selected=0
  while let edited=MarkdownEditor().run(title:L("Výchozí šablony"),tabs:[(L("Šablona relace"),values[0],sessionTemplateHint),(L("Šablona souboru"),values[1],fileTemplateHint),(L("Komentář"),values[2],commentTemplateHint),(L("Obrázek"),values[3],imageTemplateHint)],selected:selected,apply:L("Uložit")){
   values=edited
   guard TemplateDefaults.valid(session:values[0],file:values[1]) else{selected=["{title}","{screenshots}","{text}"].allSatisfy{values[0].contains($0)} ? 1:0;showError(L("Šablona relace musí obsahovat {title}, {screenshots} a {text}; šablona souboru {sessions} právě jednou."));continue}
   if let problem=itemTemplateProblem(values[2],values[3]){selected=problem.0;showError(problem.1);continue}
   let chosen=values
   Task{@MainActor in do{try await self.defaults.save(session:chosen[0],file:chosen[1],comment:chosen[2],image:chosen[3]);self.showStatus(L("Výchozí šablony byly uloženy."))}catch{showError(error.localizedDescription)}}
   break
  }
  window.makeKeyAndOrderFront(nil)
 }
 /// Chyba šablon položek pro editor: index záložky (komentář 2, obrázek 3) a text.
 private func itemTemplateProblem(_ comment:String,_ image:String)->(Int,String)? {
  if !checkItemTemplate("comment",comment).valid{return (2,LF("Šablona komentáře musí mít 1–%ld znaků.",itemTemplateMaxLength))}
  if !checkItemTemplate("image",image).valid{return (3,L("Šablona obrázku musí obsahovat {image}."))}
  return nil
 }
 /// Potvrzení změny šablony u existujících relací složky.
 private func confirmTemplateChange(_ original:Topic,template:String?,file:String?,comment:String?=nil,image:String?=nil)->Bool {
  guard (original.markdownTemplate ?? defaultMarkdownTemplate) != (template ?? defaultMarkdownTemplate) || (original.combinedTemplate ?? defaultCombinedTemplate) != (file ?? defaultCombinedTemplate)
   || original.commentTemplate != comment || original.imageTemplate != image else{return true}
  let count=indexedSessionCount(original);guard count>0,!isExportingDesign else{return true}
  let alert=NSAlert();alert.messageText=LP(count,"Šablona se použije na %ld relaci ve složce %@.","Šablona se použije na všechny %ld relace ve složce %@.","Šablona se použije na všech %ld relací ve složce %@.",count,original.name)
  alert.addButton(withTitle:L("Použít"));alert.addButton(withTitle:L("Zrušit"))
  return alert.runModal() == .alertFirstButtonReturn
 }
 /// Cloudové složky mají kontext ve výchozím stavu vypnutý; zapnutí nahrává přílohy do cloudu.
 func updateContext(){
  guard let contextButton else{return}
  let cloud=editingCloud
  // Bez společného souboru je řádek hned pod režimem ukládání.
  let top:CGFloat=mode.indexOfSelectedItem==1 ? 150:178+Self.lift
  contextToggle.frame.origin.y=top;contextCaption.frame.origin.y=top-30;contextButton.frame.origin.y=top-6;askBeforeDelete.frame.origin.y=top-84
  contextToggle.state=contextPolicy.enabled ? .on:.off;contextToggle.isEnabled=editingManaged || cloud
  contextButton.isEnabled=contextPolicy.enabled && (editingManaged || cloud)
  contextCaption.stringValue=contextPolicy.enabled ? (cloud ? LF("Nahrává se do cloudu: %@",contextPolicySummary(contextPolicy)):contextPolicySummary(contextPolicy)):L("Snímky z prohlížeče se uloží bez kontextu.")
  // Starší server nastavení nezná (nil); přepínač se pak nezobrazí.
  let current=list.first{$0.id==editingID}
  aiTitleToggle.isHidden = !cloud || current?.aiTitle==nil;aiTitleToggle.frame.origin.y=top-56
  let pending=pendingAITitle.flatMap{$0.id==editingID ? $0.value:nil}
  // AI názvy osobní složky potřebují tarif; týmovou platí tým.
  let planned=current?.cloudTeam==true || CloudFolders.shared.personalCloudAllowed
  aiTitleToggle.state=(pending ?? (current?.aiTitle==true)) ? .on:.off;aiTitleToggle.isEnabled=editingManaged && pending==nil && (planned || current?.aiTitle==true)
  if cloud,let current,current.aiTitle==nil,!aiTitleRequested.contains(current.id),!isExportingDesign{aiTitleRequested.insert(current.id);Task{@MainActor in _ = try? await CloudFolders.shared.aiTitle(current);self.list=Topics.all;self.updateContext()}}
  if let defaultTitleButton {
   // Pod tlačítkem kontextu s odstupem 8 px, aby nepřerostlo linku nad tlačítky.
   defaultTitleButton.frame.origin.y=top-48;defaultTitleButton.isEnabled = !cloud || editingManaged
   defaultTitleButton.title=LF("Výchozí název: %@",defaultTitleValue ?? DefaultTitle.global ?? builtInSessionTitle)
   defaultTitleButton.toolTip=cloud && !editingManaged ? L("Výchozí název týmové složky mění vlastník nebo správce týmu."):L("Použije se, když relace nemá název. Prázdná hodnota převezme globální výchozí název.")
  }
  aiTitleToggle.toolTip = !planned ? L("AI názvy potřebují aktivní cloudový tarif nebo zkušební období."):editingManaged ? L("U nových relací bez názvu navrhne název AI. Ruční název má vždy přednost. Limit je 1 000 názvů měsíčně na uživatele."):L("AI názvy nastavuje vlastník nebo správce týmu.")
  contextToggle.toolTip=cloud ? L("Konzole, requesty a mapa prvků se nahrají do cloudu jako přílohy snímku. Nastavení platí jen na tomto Macu."):L("Konzole, requesty a mapa prvků ze stránky v Chromu vedle snímku.")
 }
 @objc func toggleContext(){
  if contextToggle.state == .on,editingCloud,!confirmCloudContext(){contextToggle.state = .off;return}
  contextPolicy.enabled=contextToggle.state == .on;applyCloudContext();updateContext()
 }
 /// Kontext cloudové složky je místní nastavení Macu; platí hned jako AI názvy.
 private func applyCloudContext(){if let folder=list.first(where:{$0.id==editingID})?.cloudFolderID{CloudContextPolicies.set(contextPolicy,for:folder)}}
 /// Varování před nahráním kontextu do cloudu; data čte každý člen složky.
 func confirmCloudContext()->Bool {
  let alert=NSAlert();alert.alertStyle = .warning
  alert.messageText=L("Nahrávat kontext z prohlížeče do cloudu?")
  alert.informativeText=L("Ke každému snímku z Chromu se nahraje adresa a titulek stránky, konzole, seznam requestů (HAR) a mapa prvků s texty podle nastavení. Cookies a autorizační hlavičky se skrývají vždy. Přílohy uvidí všichni členové složky na webu a v MCP.")
  alert.addButton(withTitle:L("Zapnout"));alert.addButton(withTitle:L("Zrušit"))
  return alert.runModal() == .alertFirstButtonReturn
 }
 /// Dialog výchozího názvu; nil = zrušeno, .some(nil) = převzít nadřazenou hodnotu.
 func promptDefaultTitle(_ message:String,current:String?,inherited:String)->String?? {
  let alert=NSAlert();alert.messageText=message
  alert.informativeText=LF("Použije se, když relace nemá název. Nech prázdné pro „%@“.",inherited)
  let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:24));field.stringValue=current ?? "";field.placeholderString=inherited;alert.accessoryView=field
  alert.addButton(withTitle:L("Uložit"));alert.addButton(withTitle:L("Zrušit"));alert.window.initialFirstResponder=field
  guard alert.runModal() == .alertFirstButtonReturn else{return nil}
  let value=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
  if value.isEmpty{return .some(nil)}
  guard validDefaultTitle(value) else{showError(L("Výchozí název může mít 1–100 znaků na jednom řádku."));return nil}
  return .some(value)
 }
 @objc func editGlobalDefaultTitle(){
  guard let chosen=promptDefaultTitle(L("Globální výchozí název"),current:DefaultTitle.global,inherited:builtInSessionTitle) else{return}
  DefaultTitle.global=chosen
  // S cloudovým účtem se hodnota pošle na server při další synchronizaci.
  MainActor.assumeIsolated{CloudFolders.shared.markDefaultTitlePending()};refreshCloud();updateContext()
  showStatus(L("Výchozí název byl uložen."))
 }
 @objc func editTopicDefaultTitle(){
  let current=list.first{$0.id==editingID}
  guard let chosen=promptDefaultTitle(L("Výchozí název složky"),current:defaultTitleValue,inherited:DefaultTitle.global ?? builtInSessionTitle) else{return}
  guard let current,current.cloudFolderID != nil else{defaultTitleValue=chosen;updateContext();showStatus(L("Výchozí název se uloží s konfigurací."));return}
  defaultTitleButton.isEnabled=false
  Task{@MainActor in
   // Výsledek patří jen ke složce, která je pořád vybraná.
   do{try await CloudFolders.shared.setDefaultTitle(current,chosen);self.list=Topics.all;if self.editingID==current.id{self.defaultTitleValue=chosen;self.updateContext();self.showStatus(L("Výchozí název byl uložen."))}}
   catch{if self.editingID==current.id{self.updateContext()};showError(error.localizedDescription)}
  }
 }
 @objc func toggleAITitle(){
  guard let topic=list.first(where:{$0.id==editingID}),topic.cloudFolderID != nil else{return}
  let enable=aiTitleToggle.state == .on
  if enable,!confirmAITitle(){aiTitleToggle.state = .off;return}
  pendingAITitle=(topic.id,enable);updateContext()
  Task{@MainActor in
   defer{if pendingAITitle?.id==topic.id{pendingAITitle=nil};updateContext()}
   // Výsledek patří složce, která požadavek spustila; jiná vybraná složka se jen překreslí.
   do {
    let setting=try await CloudFolders.shared.aiTitle(topic,enable:enable)
    list=Topics.all
    guard editingID==topic.id else{updateContext();return}
    showStatus(setting.enabled ? LF("AI názvy jsou zapnuté. Tento měsíc zbývá %ld z %ld.",max(0,setting.limit-setting.used),setting.limit):L("AI názvy jsou vypnuté."))
   } catch {if editingID==topic.id{showError(error.localizedDescription)}}
   updateContext()
  }
 }
 /// Před zapnutím AI názvu: co se posílá, komu, že do USA a že jde vypnout.
 func confirmAITitle()->Bool {
  let alert=NSAlert();alert.alertStyle = .warning
  alert.messageText=L("Navrhovat názvy relací pomocí AI?")
  alert.informativeText=L("U nové relace bez názvu pošleme komentář, popisky snímků, titulky a adresy stránek (bez parametrů, zkrácené asi na 2 000 znaků) a nejvýš 3 zmenšené náhledy společnosti Anthropic, PBC v USA, která navrhne název. Konzole, requesty ani HAR se neposílají. Anthropic data zpracovává jako náš zpracovatel podle standardních smluvních doložek a nepoužívá je k trénování. Platí pro celou složku a jde kdykoli vypnout.")
  alert.addButton(withTitle:L("Zapnout"));alert.addButton(withTitle:L("Zrušit"))
  return alert.runModal() == .alertFirstButtonReturn
 }
 /// Dialog s tím, co se přikládá a co se skrývá; zamčené položky rozšíření skryje vždy.
 @objc func editContext(){
  let policy=contextPolicy,width:CGFloat=420
  let view=NSView(frame:NSRect(x:0,y:0,width:width,height:322))
  func box(_ title:String,_ on:Bool,_ y:CGFloat,indent:CGFloat=0,locked:Bool=false)->NSButton{
   let button=NSButton(checkboxWithTitle:title,target:nil,action:nil);button.state=on ? .on:.off;button.frame=NSRect(x:indent,y:y,width:width-indent-24,height:20);button.isEnabled = !locked;view.addSubview(button)
   if locked{let lock=NSImageView(frame:NSRect(x:width-18,y:y+2,width:16,height:16));lock.image=NSImage(systemSymbolName:"lock.fill",accessibilityDescription:L("Vždy zapnuto"));lock.contentTintColor=AppPalette.secondary;lock.toolTip=L("Rozšíření to skryje vždy.");view.addSubview(lock)}
   return button
  }
  func field(_ title:String,_ values:[String],_ y:CGFloat,placeholder:String)->NSTextField{
   view.addSubview(designLabel(title,NSRect(x:0,y:y+26,width:width,height:18),size:12,weight:.medium))
   let input=NSTextField(string:values.joined(separator:", "));input.placeholderString=placeholder;input.frame=NSRect(x:0,y:y,width:width,height:24);view.addSubview(input);return input
  }
  let console=box(L("Konzole a chyby stránky"),policy.includeConsole,300)
  let network=box(L("Network (requesty a odpovědi)"),policy.includeNetwork,276)
  let bodies=box(L("Těla requestů a odpovědí"),policy.includeBodies,252,indent:20)
  bodies.toolTip=L("Jen když je v rozšíření zapnuté nahrávání těl. Citlivé klíče se skryjí.")
  let elements=box(L("Mapa prvků stránky"),policy.includeElements,228)
  let texts=box(L("Včetně textů prvků"),policy.includeElementText,204,indent:20)
  _ = box(L("Skrýt hodnoty cookies"),true,172,locked:true)
  _ = box(L("Skrýt autorizační hlavičky a tokeny"),true,148,locked:true)
  let headers=field(L("Další hlavičky ke skrytí"),policy.redactHeaders,76,placeholder:"X-Tenant-Id, X-Customer")
  let params=field(L("Další citlivé query parametry"),policy.redactQueryParams,8,placeholder:"email, phone")
  let link=ContextDependency(network:network,bodies:bodies,elements:elements,texts:texts);link.update()
  for button in [network,elements]{button.target=link;button.action=#selector(ContextDependency.update)}
  let alert=NSAlert();alert.messageText=L("Kontext z prohlížeče");alert.informativeText=L("Výchozí citlivé hlavičky a parametry se skryjí vždy. Seznamy oddělte čárkou.");alert.accessoryView=view
  alert.addButton(withTitle:L("Použít"));alert.addButton(withTitle:L("Zrušit"))
  if alert.runModal() == .alertFirstButtonReturn {
   contextPolicy.includeConsole=console.state == .on;contextPolicy.includeNetwork=network.state == .on;contextPolicy.includeBodies=bodies.state == .on
   contextPolicy.includeElements=elements.state == .on;contextPolicy.includeElementText=texts.state == .on
   contextPolicy.redactHeaders=ContextPolicy.names([headers.stringValue]);contextPolicy.redactQueryParams=ContextPolicy.names([params.stringValue])
   applyCloudContext();updateContext()
  }
  withExtendedLifetime(link){};window.makeKeyAndOrderFront(nil)
 }
 @objc func toggleAskBeforeDelete(){
  guard askBeforeDelete.state == .on,let topic=list.first(where:{$0.id==editingID}) else{return}
  do{try CloudFolders.shared.setConfirmLocalDeletes(topic,true);list=Topics.all;updateMode()}catch{askBeforeDelete.state = .off;showError(error.localizedDescription)}
 }
 @objc func chooseFolder(){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;if !folder.stringValue.isEmpty{panel.directoryURL=URL(fileURLWithPath:folder.stringValue)};if panel.runModal() == .OK,let url=panel.url{folder.stringValue=url.path}}
 @objc func editTemplate(){
  let sessionError=L("Šablona musí obsahovat {title}, {screenshots} a {text}.")
  func validSession(_ value:String)->Bool{["{title}","{screenshots}","{text}"].allSatisfy{value.contains($0)}}
  // Záložky: relace, soubor (jen společný soubor), komentář a obrázek.
  let combined=mode.indexOfSelectedItem==1,offset=combined ? 1:0
  var values=[template]+(combined ? [fileTemplate ?? defaultCombinedTemplate]:[])+[commentTemplate ?? defaultCommentTemplate,imageTemplate ?? defaultImageTemplate];var selected=0
  var tabs=[(L("Šablona relace"),values[0],sessionTemplateHint)]
  if combined{tabs.append((L("Šablona souboru"),values[1],fileTemplateHint))}
  tabs+=[(L("Komentář"),values[1+offset],commentTemplateHint),(L("Obrázek"),values[2+offset],imageTemplateHint)]
  while let edited=MarkdownEditor().run(title:L("Šablona Markdownu"),tabs:tabs.enumerated().map{($0.element.0,values[$0.offset],$0.element.2)},selected:selected,apply:L("Použít šablonu")){
   values=edited
   if !validSession(values[0]){selected=0;showError(sessionError);continue}
   if combined,!validCombinedTemplate(values[1]){selected=1;showError(L("Šablona souboru musí obsahovat {sessions} právě jednou."));continue}
   if let problem=itemTemplateProblem(values[1+offset],values[2+offset]){selected=problem.0-1+offset;showError(problem.1);continue}
   template=values[0];if combined{fileTemplate=values[1]==defaultCombinedTemplate ? nil:values[1]}
   commentTemplate=values[1+offset]==defaultCommentTemplate ? nil:values[1+offset];imageTemplate=values[2+offset]==defaultImageTemplate ? nil:values[2+offset];break
  }
  window.makeKeyAndOrderFront(nil)
 }
 private func showStatus(_ text:String,warning:Bool=false){saveStatus.stringValue=text;saveStatus.toolTip=text;saveStatus.textColor=warning ? .systemOrange:AppPalette.secondary;saveStatus.alphaValue=0;animateDesign{saveStatus.animator().alphaValue=1}}
 @objc func saveTopic(){
  window.makeFirstResponder(nil);endNameEdit()
  let title=name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),path=folder.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !title.isEmpty,path.hasPrefix("/") else{showError(L("Vyplň název konfigurace a absolutní cestu ke složce."));return}
  let rawFile=(file.stringValue as NSString).deletingPathExtension
  let filename=(filenameFromTitle(rawFile) ?? filenameFromTitle(title) ?? "Screenshoty")+".md"
  if editingCloud {
   guard let original=list.first(where:{$0.id==editingID}) else{return}
   // Politika kontextu cloudové složky je místní nastavení tohoto Macu.
   if let folder=original.cloudFolderID{CloudContextPolicies.set(contextPolicy,for:folder)}
   // Člen týmu ukládá jen místní adresář; nastavení složky na server neposílá.
   if !original.canManageCloudFolder {
    do{if original.folder != path{try CloudFolders.shared.setFolder(original,path:path)}}catch{showError(error.localizedDescription);return}
    list=Topics.all;reloadTable();markLoaded();showStatus(L("Konfigurace byla uložena."));refreshCloud();return
   }
   var changed=original;changed.name=title;changed.detail=detail.stringValue;changed.combined=mode.indexOfSelectedItem==1;changed.combinedFile=filename
   changed.markdownTemplate=original.markdownTemplate==nil && template==defaultMarkdownTemplate ? nil:template;changed.combinedTemplate=fileTemplate
   changed.commentTemplate=commentTemplate;changed.imageTemplate=imageTemplate
   guard confirmTemplateChange(original,template:changed.markdownTemplate,file:changed.combinedTemplate,comment:changed.commentTemplate,image:changed.imageTemplate) else{return}
   do{if original.folder != path{try CloudFolders.shared.setFolder(original,path:path)}}catch{showError(error.localizedDescription);return}
   changed.folder=path
   guard changed != (list.first{$0.id==editingID}.map{var value=$0;value.folder=path;return value}) else{list=Topics.all;reloadTable();markLoaded();showStatus(L("Konfigurace byla uložena."));refreshCloud();return}
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
  topic.commentTemplate=commentTemplate;topic.imageTemplate=imageTemplate
  topic.contextPolicy=contextPolicy==ContextPolicy() ? nil:contextPolicy;topic.defaultTitle=defaultTitleValue
  let previous=list.first{$0.id==topic.id && $0.cloudFolderID==nil}
  if let previous{topic.formerCloudFolderID=previous.formerCloudFolderID;topic.formerCloudOwnerID=previous.formerCloudOwnerID;topic.formerCloudOrigin=previous.formerCloudOrigin}
  if let previous,!confirmTemplateChange(previous,template:topic.markdownTemplate,file:topic.combinedTemplate,comment:topic.commentTemplate,image:topic.imageTemplate){return}
  var updated=list.filter{$0.cloudFolderID==nil}
  if let i=updated.firstIndex(where:{$0.id==topic.id}){updated[i]=topic}else{updated.append(topic)}
  // Nový nebo změněný adresář nesmí ležet v jiné složce; ostatní složky se ukládají i se starším vnořením.
  if previous?.folder != path{do{try Topics.validateDestination(topic,folder:topic.destination,among:updated+CloudFolders.shared.allTopics)}catch{showError(error.localizedDescription);return}}
  let defaultValue=pendingDefault ? topic.id:(UserDefaults.standard.string(forKey:"defaultTopic") ?? Topics.defaultTopic.id)
  do {
   try Topics.save(updated,defaultID:defaultValue);list=Topics.all;editingID=topic.id;reloadTable();load(topic);showStatus(L("Konfigurace byla uložena."))
   // Změněná šablona se použije na všechny relace složky.
   if let previous,previous.markdownTemplate != topic.markdownTemplate || previous.combinedTemplate != topic.combinedTemplate || previous.imageTemplate != topic.imageTemplate || (topic.combined && (previous.name != topic.name || previous.detail != topic.detail)) {
    let result=rerenderFolder(topic,previous:previous)
    if result.edited>0{showStatus(LP(result.edited,"%ld relace byla ručně upravena, nová verze je uložená vedle (_template).","%ld relace byly ručně upraveny, nová verze je uložená vedle (_template).","%ld relací bylo ručně upraveno, nová verze je uložená vedle (_template).",result.edited),warning:true)}
   }
  }catch{showError(error.localizedDescription)}
 }
 private func refreshCloud(){Task{@MainActor in await CloudFolders.shared.refresh(CloudLibrary.shared.connection)}}
}

/// Těla závisí na networku a texty na mapě prvků.
final class ContextDependency:NSObject {
 let network:NSButton,bodies:NSButton,elements:NSButton,texts:NSButton
 init(network:NSButton,bodies:NSButton,elements:NSButton,texts:NSButton){self.network=network;self.bodies=bodies;self.elements=elements;self.texts=texts}
 @objc func update(){bodies.isEnabled=network.state == .on;texts.isEnabled=elements.state == .on}
}
/// Krátký popis politiky pod přepínačem.
func contextPolicySummary(_ policy:ContextPolicy)->String {
 let parts=[policy.includeConsole ? L("konzole"):nil,policy.includeNetwork ? (policy.includeBodies ? L("network s těly"):L("network")):nil,policy.includeElements ? (policy.includeElementText ? L("prvky s texty"):L("prvky bez textů")):nil].compactMap{$0}
 let what=parts.isEmpty ? L("Jen adresa stránky"):parts.joined(separator:", ").prefix(1).uppercased()+parts.joined(separator:", ").dropFirst()
 return what+" · "+L("cookies a tokeny vždy skryté")
}
