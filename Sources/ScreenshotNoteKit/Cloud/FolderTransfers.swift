import AppKit
import UserNotifications
import CryptoKit

private struct FolderTransfer:Codable {
 // local je ID relace v indexu; podle něj se pozná i relace upravená během přesunu.
 struct Entry:Codable{let key:String;let id:UUID;var local:String? = nil}
 let source:Topic;let target:Topic;let owner:UUID;let origin:String
 var entries:[Entry]=[]
}
final class FolderTransfers {
 static let shared=FolderTransfers()
 private let directory:URL
 private(set) var busy=false
 init(directory:URL=draftRoot.deletingLastPathComponent().appendingPathComponent("Folder Transfers")){self.directory=directory}
 private func location(_ source:Topic,_ c:CloudConnection)->URL {
  directory.appendingPathComponent(sessionFingerprint(Data((c.endpoint+(c.ownerID?.uuidString ?? "")+source.id).utf8))+".json")
 }
 private func save(_ plan:FolderTransfer,to file:URL)throws {
  try fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let data=try JSONEncoder().encode(plan);guard data.count<=10000000 else{throw CloudFailure.invalid};try data.write(to:file,options:.atomic)
 }
 private func key(_ session:PreviousSession,source:Topic)throws->String {
  var value=source.id+"\0"+session.target.path+"\0"+String(session.section)+"\0"+session.target.original
  let assets=URL(fileURLWithPath:session.target.path).deletingLastPathComponent().appendingPathComponent("assets")
  for image in session.images {
   let url=assets.appendingPathComponent(image),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
   guard size<=100000000 else{throw CloudFailure.invalid}
   value+="\0"+sessionFingerprint(try Data(contentsOf:url,options:.mappedIfSafe))
  }
  return sessionFingerprint(Data(value.utf8))
 }
 /// Relace k nahrání; u dřívější cloudové složky jen ty, které v cloudu nikdy nebyly.
 private func uploadable(_ source:Topic)throws->[PreviousSession] {
  let sessions=try previousSessions(in:source.destination)
  guard let former=source.formerCloudFolderID?.uuidString.lowercased() else{return sessions}
  let cloud=Set(SessionIndex.shared.all.filter{$0.isCloud && $0.folder==former}.map(\.id))
  return sessions.filter{session in !(session.target.session.map{cloud.contains($0.lowercased())} ?? false)}
 }
 @MainActor @discardableResult func move(_ source:Topic,to target:Topic,library:CloudLibrary = .shared,folders:CloudFolders = .shared)async throws->Bool {
  guard !busy,let c=library.connection,let owner=c.ownerID,source.cloudFolderID==nil,target.cloudOrigin==c.endpoint,folders.topics.contains(where:{$0.cloudFolderID==target.cloudFolderID && $0.cloudOwnerID==target.cloudOwnerID}) else{throw CloudFailure.invalid}
  busy=true;defer{busy=false;NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)}
  let file=location(source,c);var plan:FolderTransfer
  if fm.fileExists(atPath:file.path) {
   let data=try Data(contentsOf:file);guard data.count<=10000000 else{throw CloudFailure.invalid};plan=try JSONDecoder().decode(FolderTransfer.self,from:data)
   guard plan.owner==owner,plan.origin==c.endpoint,plan.source==source,plan.target.cloudFolderID==target.cloudFolderID else{throw CloudFailure(L("Pro tuto složku už je rozpracovaný jiný přesun. Nejprve jej dokonči."))}
  }else{plan=FolderTransfer(source:source,target:target,owner:owner,origin:c.endpoint)}
  let sessions=try uploadable(source)
  var keys:[String]=[]
  func entry(_ session:PreviousSession,_ fingerprint:String)->FolderTransfer.Entry?{plan.entries.first{$0.local != nil && $0.local==session.target.session} ?? plan.entries.first{$0.key==fingerprint}}
  for session in sessions {
   let fingerprint=try key(session,source:source);keys.append(fingerprint)
   if entry(session,fingerprint)==nil{plan.entries.append(.init(key:fingerprint,id:UUID(),local:session.target.session))}
  }
  try save(plan,to:file)
  for (index,session) in sessions.enumerated() {
   guard library.connection?.ownerID==owner,library.connection?.endpoint==c.endpoint else{throw CloudFailure.invalid}
   let entry=entry(session,keys[index])!
   if library.isCommitted(entry.id,folder:target.cloudFolderID){continue}
   let root=fm.temporaryDirectory.appendingPathComponent("sn-folder-transfer-"+UUID().uuidString)
   try fm.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
   defer{try? fm.removeItem(at:root)}
   var draft=try workingDraft(from:session,topic:source,root:root)
   var frozen=plan.target;frozen.markdownTemplate=source.markdownTemplate;frozen.commentTemplate=source.commentTemplate;frozen.imageTemplate=source.imageTemplate;frozen.defaultTitle=frozen.defaultTitle ?? source.defaultTitle;draft.topic=frozen;draft.previous=nil
   try library.enqueue(draft,root:root,sessionID:entry.id,folders:folders.topics)
   await Task.yield()
  }
  await library.sync()
  guard library.connection?.ownerID==owner,library.connection?.endpoint==c.endpoint else{throw CloudFailure.invalid}
  guard plan.entries.allSatisfy({library.isCommitted($0.id,folder:target.cloudFolderID)}) else{return false}
  // Nová relace přidaná během přesunu se musí nejdřív nahrát.
  let current=try uploadable(source)
  let matched=try current.map{session->(PreviousSession,FolderTransfer.Entry,Bool) in
   let fingerprint=try key(session,source:source)
   guard let found=entry(session,fingerprint) else{throw CloudFailure(L("Obsah místní složky se během přesunu změnil. Spusť kontrolu přesunu znovu."))}
   return (session,found,found.key != fingerprint)
  }
  // Nahrané místní soubory se převezmou jako cloudová relace, aby se nestáhly podruhé.
  for (session,found,changed) in matched{folders.adoptUpload(session,id:found.id,source:source,target:target,changed:changed)}
  try folders.finishTransfer(source,to:target)
  return true
 }
 @MainActor func resume(library:CloudLibrary = .shared,folders:CloudFolders = .shared)async {
  guard !busy,let c=library.connection,let owner=c.ownerID else{return}
  let files=(try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []
  for file in files where file.pathExtension=="json" {
   guard let data=try? Data(contentsOf:file),data.count<=10000000,let plan=try? JSONDecoder().decode(FolderTransfer.self,from:data),plan.owner==owner,plan.origin==c.endpoint,
         Topics.local.contains(where:{$0==plan.source}) else{continue}
   do{_ = try await move(plan.source,to:plan.target,library:library,folders:folders)}catch{folders.lastError=error.localizedDescription}
  }
 }
}

enum FolderDialogs {
 @MainActor static func name(_ initial:String)->String? {
  let alert=NSAlert();alert.messageText=L("Název cloudové složky");alert.addButton(withTitle:L("Pokračovat"));alert.addButton(withTitle:L("Zrušit"))
  let field=NSTextField(frame:NSRect(x:0,y:0,width:330,height:28));field.stringValue=initial;alert.accessoryView=field
  guard alert.runModal() == .alertFirstButtonReturn else{return nil}
  return field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
 }
 /// Kam přesunout: osobní cloud, nebo tým, kde je uživatel owner/admin; nil = zrušeno.
 @MainActor static func library(for name:String,teams:[CloudLibraryRef])->CloudLibraryRef?? {
  guard !teams.isEmpty else{return .some(nil)}
  let alert=NSAlert();alert.messageText=LF("Kam přesunout složku „%@“?",name)
  alert.informativeText=L("Týmovou složku uvidí a doplňují všichni členové týmu.")
  let popup=NSPopUpButton(frame:NSRect(x:0,y:0,width:330,height:28),pullsDown:false)
  popup.addItem(withTitle:L("Osobní cloud"));for team in teams{popup.addItem(withTitle:LF("Tým %@",team.name ?? L("Tým")))}
  alert.accessoryView=popup;alert.addButton(withTitle:L("Pokračovat"));alert.addButton(withTitle:L("Zrušit"))
  guard alert.runModal() == .alertFirstButtonReturn else{return nil}
  return .some(popup.indexOfSelectedItem==0 ? nil:teams[popup.indexOfSelectedItem-1])
 }
 @MainActor static func destination(_ initial:String)async throws->Topic? {
  await CloudFolders.shared.refresh(CloudLibrary.shared.connection)
  if let error=CloudFolders.shared.lastError{throw CloudFailure(error)}
  guard let choice=library(for:initial,teams:try await CloudFolders.shared.manageableTeams()) else{return nil}
  let owner=choice?.id ?? CloudLibrary.shared.connection?.ownerID
  var title=initial
  for _ in 0..<20 {
   if let existing=CloudFolders.shared.topics.first(where:{$0.cloudOwnerID==owner && $0.name.lowercased()==title.lowercased()}) {
    let alert=NSAlert();alert.messageText=LF("Cloudová složka „%@“ už existuje.",existing.name)
    alert.informativeText=L("Sloučení přidá poznámky do této složky. Existující poznámky ani místní soubory nepřepíše.")
    alert.addButton(withTitle:L("Sloučit"));alert.addButton(withTitle:L("Přejmenovat"));alert.addButton(withTitle:L("Přeskočit"))
    let response=alert.runModal();if response == .alertFirstButtonReturn{return existing}
    guard response == .alertSecondButtonReturn,let renamed=name(title) else{return nil};title=renamed;continue
   }
   do{return try await CloudFolders.shared.create(title,team:choice)}
   catch let error as CloudFailure where error.code=="folder_name_taken" {await CloudFolders.shared.refresh(CloudLibrary.shared.connection)}
  }
  throw CloudFailure.invalid
 }
 @MainActor static func move(_ sources:[Topic])async {
  let preview=NSAlert();preview.messageText=L("Přesun lokálních složek do cloudu")
  preview.informativeText=L("Nahrají se rozpoznané poznámky Screenshot Note. Ostatní soubory a původní místní poznámky zůstanou zachované. Místní složka se změní na cloudovou až po potvrzení všech přenosů.")
  preview.addButton(withTitle:L("Pokračovat"));preview.addButton(withTitle:L("Zrušit"));guard preview.runModal() == .alertFirstButtonReturn else{return}
  for source in sources {
   do {
    guard let target=try await destination(source.name) else{continue}
    let different = try !target.folder.isEmpty && !Topics.sameDestination(Topics.checkedDestination(target.folder),Topics.checkedDestination(source.folder))
    if different {
     let alert=NSAlert();alert.messageText=L("Cloudová složka už má místní adresář.");alert.informativeText=L("Stávající cloudový adresář zůstane zachovaný. Původní místní soubory se nesmažou.");alert.addButton(withTitle:L("Pokračovat"));alert.addButton(withTitle:L("Přeskočit"))
     if alert.runModal() != .alertFirstButtonReturn{continue}
    }
    if !(try await FolderTransfers.shared.move(source,to:target)){showError(L("Přesun čeká na potvrzené nahrání všech poznámek. Místní složka zůstává dostupná a přesun se zkusí znovu."));continue}
    // Nová cloudová složka převezme nastavení lokální složky.
    if let moved=CloudFolders.shared.topics.first(where:{$0.cloudFolderID==target.cloudFolderID}),moved.detail.isEmpty,!moved.combined,moved.markdownTemplate==nil,moved.combinedTemplate==nil {
     var settings=moved;settings.detail=source.detail;settings.combined=source.combined;settings.combinedFile=source.combinedFile;settings.markdownTemplate=source.markdownTemplate;settings.combinedTemplate=source.combinedTemplate
     // Šablony položek jen místo zděděných výchozích; vlastní šablony cílové složky zůstanou.
     if moved.commentTemplate==nil || moved.commentTemplate==TemplateDefaults.shared.comment{settings.commentTemplate=source.commentTemplate}
     if moved.imageTemplate==nil || moved.imageTemplate==TemplateDefaults.shared.image{settings.imageTemplate=source.imageTemplate}
     if settings != moved{_ = try? await CloudFolders.shared.update(settings)}
    }
    // Výchozí název místní složky přejde na cloudovou, pokud ta vlastní nemá.
    if let title=source.defaultTitle,let moved=CloudFolders.shared.topics.first(where:{$0.cloudFolderID==target.cloudFolderID}),moved.defaultTitle==nil,moved.canManageCloudFolder {
     _ = try? await CloudFolders.shared.setDefaultTitle(moved,title)
    }
   }catch{showError(error.localizedDescription)}
  }
 }
 @MainActor private static var dismissed=Set<UUID>()
 /// Výchozí nadřazená složka cloudu; nastavená = nové složky dostanou podsložku bez dotazu.
 static var cloudRoot:URL?{
  get{UserDefaults.standard.string(forKey:"cloudFolderRoot").map{URL(fileURLWithPath:$0,isDirectory:true)}}
  set{if let newValue{UserDefaults.standard.set(newValue.path,forKey:"cloudFolderRoot")}else{UserDefaults.standard.removeObject(forKey:"cloudFolderRoot")}}
 }
 @MainActor private static var deferredHeld=Set<String>()
 @MainActor private static var deferredDeletes=Set<String>()
 /// Relace smazané z disku: jeden dotaz na složku a dávku; Esc/Později se zeptá až při dalším spuštění.
 @MainActor static func confirmDeletes(folders:CloudFolders = .shared)async {
  var changed=false
  for (topic,records) in folders.deletePrompts {
   let batch=records.map(\.id).sorted().joined(separator:",")
   guard !deferredDeletes.contains(batch) else{continue}
   NSApp.activate(ignoringOtherApps:true)
   let alert=NSAlert()
   if records.count==1{alert.messageText=LF("Relace „%@“ byla smazána z disku. Přesunout ji do Koše na webu? Lze ji obnovit 30 dní.",records[0].title)}
   else {
    alert.messageText=LP(records.count,"Ve složce %@ byly z disku smazány %ld relace:","Ve složce %@ byly z disku smazány %ld relace:","Ve složce %@ bylo z disku smazáno %ld relací:",topic.displayName,records.count)
    alert.informativeText=records.prefix(5).map{"• "+$0.title}.joined(separator:"\n")+(records.count>5 ? "\n…":"")+"\n\n"+L("Přesunout je do Koše na webu? Lze je obnovit 30 dní.")
   }
   alert.addButton(withTitle:L("Přesunout do Koše"));alert.addButton(withTitle:L("Obnovit na disku"))
   let later=alert.addButton(withTitle:L("Později"));later.keyEquivalent="\u{1b}"
   alert.showsSuppressionButton=true;alert.suppressionButton?.title=L("Příště se neptat")
   alert.window.level = .modalPanel
   let response=alert.runModal(),suppress=alert.suppressionButton?.state == .on
   switch response {
   case .alertFirstButtonReturn:folders.resolveDeletePrompt(topic,trash:true,suppress:suppress);changed=true
   case .alertSecondButtonReturn:folders.resolveDeletePrompt(topic,trash:false,suppress:suppress);changed=true
   default:deferredDeletes.insert(batch);if suppress{try? folders.setConfirmLocalDeletes(topic,false)}
   }
  }
  if changed{await folders.refresh(CloudLibrary.shared.connection)}
 }
 /// Zadržené hromadné mazání se hned zeptá; „Později“ platí pro tuto dávku do konce běhu aplikace.
 @MainActor static func resolveHeld(folders:CloudFolders = .shared,manual:Bool=false)async {
  var changed=false
  for (topic,count) in folders.heldFolders {
   let batch=folders.heldBatch(topic)
   if !manual && deferredHeld.contains(batch){continue}
   NSApp.activate(ignoringOtherApps:true)
   let alert=NSAlert();alert.messageText=LP(count,"Ve složce %@ zmizela %ld relace. Přesunout ji do Koše na webu? Lze ji obnovit 30 dní.","Ve složce %@ zmizely %ld relace. Přesunout je do Koše na webu? Lze je obnovit 30 dní.","Ve složce %@ zmizelo %ld relací. Přesunout je do Koše na webu? Lze je obnovit 30 dní.",topic.displayName,count)
   alert.addButton(withTitle:L("Přesunout do Koše"));alert.addButton(withTitle:L("Znovu stáhnout"));alert.addButton(withTitle:L("Později"))
   alert.window.level = .modalPanel
   switch alert.runModal() {
   case .alertFirstButtonReturn:folders.resolveHeld(topic,trash:true);changed=true
   case .alertSecondButtonReturn:folders.resolveHeld(topic,trash:false);changed=true
   default:deferredHeld.insert(batch)
   }
  }
  if changed{await folders.refresh(CloudLibrary.shared.connection)}
 }
 /// Po přihlášení nabídne znovupropojení dřívějších cloudových složek tohoto účtu.
 @MainActor static func offerRepair(folders:CloudFolders = .shared)async {
  guard let c=CloudLibrary.shared.connection,let owner=c.ownerID else{return}
  let key="repair-declined:"+sessionFingerprint(Data((c.endpoint+owner.uuidString).utf8))
  let declined=Set(UserDefaults.standard.stringArray(forKey:key) ?? [])
  let candidates=folders.repairCandidates.filter{!declined.contains($0.id)}
  guard !candidates.isEmpty else{return}
  NSApp.activate(ignoringOtherApps:true)
  let alert=NSAlert();alert.messageText=L("Znovu propojit složky s cloudem?")
  alert.informativeText=L("Tyto lokální složky dřív patřily do cloudu tohoto účtu. Místní relace se nahrají, cloudové se stáhnou a rozdílné verze se uloží vedle jako _cloud.md.")
  let boxes=candidates.map{topic->NSButton in let box=NSButton(checkboxWithTitle:topic.displayName,target:nil,action:nil);box.state = .on;return box}
  let stack=NSStackView(views:boxes);stack.orientation = .vertical;stack.alignment = .leading;stack.frame=NSRect(x:0,y:0,width:330,height:CGFloat(boxes.count)*24);alert.accessoryView=stack
  alert.addButton(withTitle:L("Propojit"));alert.addButton(withTitle:L("Teď ne"))
  let accepted=alert.runModal() == .alertFirstButtonReturn
  var rejected=declined
  for (topic,box) in zip(candidates,boxes) {
   guard accepted,box.state == .on else{rejected.insert(topic.id);continue}
   do{if !(try await folders.repair(topic)){showError(L("Přesun čeká na potvrzené nahrání všech poznámek. Místní složka zůstává dostupná a přesun se zkusí znovu."))}}catch{showError(error.localizedDescription)}
  }
  UserDefaults.standard.set(Array(rejected),forKey:key)
 }
 /// Na webu smazaná složka: zachovat jako lokální, nebo přesunout do Koše v macOS.
 @MainActor static func resolveDeleted(folders:CloudFolders = .shared) {
  for record in folders.deletedRemotely {
   NSApp.activate(ignoringOtherApps:true)
   let alert=NSAlert();alert.messageText=LF("Složka %@ byla smazána v cloudu. Zachovat ji jako lokální, nebo smazat?",record.topic.displayName)
   alert.informativeText=record.folder+(folders.hasUnknownFiles(record.folder) ? "\n\n"+L("Adresář obsahuje i jiné soubory. Ty zůstanou na místě; do Koše v macOS se přesunou jen poznámky Screenshot Note."):"")
   alert.addButton(withTitle:L("Zachovat jako lokální"));alert.addButton(withTitle:L("Smazat"));alert.addButton(withTitle:L("Později"))
   // Obnovení na webu během dotazu dialog zavře.
   let observer=NotificationCenter.default.addObserver(forName:.cloudFoldersChanged,object:nil,queue:.main){_ in
    MainActor.assumeIsolated{if !folders.deletedRemotely.contains(where:{$0.id==record.id}),NSApp.modalWindow===alert.window{NSApp.abortModal()}}
   }
   let response=alert.runModal();NotificationCenter.default.removeObserver(observer)
   guard folders.deletedRemotely.contains(where:{$0.id==record.id}) else{continue}
   do {
    switch response {
    case .alertFirstButtonReturn:rememberMoved(try folders.keepDeleted(record.id))
    case .alertSecondButtonReturn:try folders.discardDeleted(record.id)
    default:break
    }
   } catch {showError(error.localizedDescription)}
  }
 }
 /// Cloudové složky bez místního adresáře dostanou adresář hned po připojení.
 @MainActor static func mapUnmapped(folders:CloudFolders = .shared)async {
  // Složky čekající na znovupropojení se neptají na nový adresář.
  let repairing=Set(folders.repairCandidates.compactMap(\.formerCloudFolderID))
  let unmapped=folders.topics.filter{$0.folder.isEmpty && $0.cloudFolderID != nil && !repairing.contains($0.cloudFolderID!)}
  guard !unmapped.isEmpty else{return}
  // Nastavená nadřazená složka: podsložky bez dotazu; chybí-li adresář, zeptá se jako dřív.
  if let root=cloudRoot,fm.fileExists(atPath:root.path){
   do{try assign(unmapped,root:root,folders:folders);NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil);await folders.refresh(CloudLibrary.shared.connection);return}
   catch{showError(error.localizedDescription)}
  }
  guard unmapped.contains(where:{!dismissed.contains($0.cloudFolderID!)}) else{return}
  NSApp.activate(ignoringOtherApps:true)
  let alert=NSAlert();alert.messageText=L("Cloudové složky potřebují místní adresář")
  alert.informativeText=L("Každá cloudová složka se na tomto Macu ukládá do vlastního adresáře. Chybí u těchto složek:")+"\n\n"+unmapped.prefix(12).map{"• "+$0.displayName}.joined(separator:"\n")+(unmapped.count>12 ? "\n…":"")
  alert.addButton(withTitle:L("Jedna nadřazená složka…"));alert.addButton(withTitle:L("Vybrat pro každou zvlášť…"));alert.addButton(withTitle:L("Později"))
  var mapped=false
  switch alert.runModal() {
  case .alertFirstButtonReturn:
   let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L("Vybrat")
   panel.message=L("V této složce se vytvoří podsložky pojmenované podle cloudových složek. Nové cloudové složky se sem uloží samy; změníš to v Nastavení.")
   guard panel.runModal() == .OK,let root=panel.url else{break}
   do{try assign(unmapped,root:root,folders:folders);mapped=true;cloudRoot=root}catch{showError(error.localizedDescription)}
  case .alertSecondButtonReturn:
   for topic in unmapped {
    let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L("Vybrat")
    panel.message=LF("Vyber místní adresář pro cloudovou složku „%@“.",topic.displayName)
    guard panel.runModal() == .OK,let url=panel.url else{continue}
    do{try folders.setFolder(topic,path:url.path);mapped=true}catch{showError(error.localizedDescription)}
   }
  default:break
  }
  // Zrušený výběr se v tomto běhu aplikace znovu nenabízí.
  dismissed.formUnion(folders.topics.filter{$0.folder.isEmpty}.compactMap(\.cloudFolderID))
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
  if mapped{await folders.refresh(CloudLibrary.shared.connection)}
 }
 /// Podsložky podle názvů; kolize dostanou číselnou příponu.
 static func assign(_ topics:[Topic],root:URL,folders:CloudFolders)throws {
  for topic in topics {
   let base=folderName(topic.name)
   var index=1
   while true {
    let candidate=root.appendingPathComponent(index==1 ? base:base+" \(index)",isDirectory:true)
    var directory:ObjCBool=false
    // Existující neprázdný adresář se nepřebírá, aby do něj stahování nepřimíchalo cizí soubory.
    let exists=fm.fileExists(atPath:candidate.path,isDirectory:&directory)
    let blocked=exists && (!directory.boolValue || ((try? fm.contentsOfDirectory(atPath:candidate.path)) ?? []).contains{!$0.hasPrefix(".")})
    if !blocked,(try? folders.setFolder(topic,path:candidate.path)) != nil{break}
    index+=1;guard index<=100 else{throw CloudFailure(LF("Pro „%@“ se nepodařilo najít volný adresář.",topic.displayName))}
   }
  }
 }
 /// Odložené a osiřelé položky cloudové fronty: Zkusit znovu, Uložit lokálně, Zahodit.
 @MainActor static func resolveParked(library:CloudLibrary = .shared) {
  for item in library.parkedItems {
   NSApp.activate(ignoringOtherApps:true)
   let alert=NSAlert()
   alert.messageText=item.stranded ? LF("Relace „%@“ čeká ve frontě jiného účtu nebo odpojeného Macu.",item.title):LF("Relace „%@“ se nenahrála do cloudu.",item.title)
   var info:[String]=[]
   switch item.kind{case .upload:info.append(L("Nová relace se snímky."));case .addition:info.append(L("Doplnění relace o nové snímky."));case .edit:info.append(L("Úprava textu relace."))}
   if let reason=item.reason{info.append(reason)}
   if item.stranded{info.append(L("Nahraje se po připojení stejného účtu. Mezitím ji můžeš uložit lokálně."))}
   alert.informativeText=info.joined(separator:"\n\n")
   var actions:[String]=[]
   if item.retryable{alert.addButton(withTitle:L("Zkusit znovu"));actions.append("retry")}
   alert.addButton(withTitle:L("Uložit lokálně…"));actions.append("save")
   alert.addButton(withTitle:L("Zahodit…"));actions.append("discard")
   let later=alert.addButton(withTitle:L("Později"));later.keyEquivalent="\u{1b}";actions.append("later")
   alert.window.level = .modalPanel
   let choice=alert.runModal().rawValue-NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
   guard actions.indices.contains(choice),actions[choice] != "later" else{break}
   do {
    switch actions[choice] {
    case "retry":try library.retryParked(item);Task{@MainActor in await library.sync()}
    case "save":
     let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;panel.prompt=L("Uložit sem")
     panel.message=L("Vyber místní adresář; relace se do něj uloží jako Markdown se snímky.")
     if let local=Topics.local.first(where:\.savesLocally){panel.directoryURL=local.destination}
     guard panel.runModal() == .OK,let url=panel.url else{continue}
     NSWorkspace.shared.activateFileViewerSelecting([try library.saveParkedLocally(item,to:url)])
    default:
     let confirm=NSAlert();confirm.messageText=LF("Zahodit relaci „%@“?",item.title);confirm.informativeText=L("Položka se přesune do Koše v macOS a do cloudu se nenahraje.")
     confirm.addButton(withTitle:L("Zahodit")).hasDestructiveAction=true;confirm.addButton(withTitle:L("Zrušit"))
     if confirm.runModal() == .alertFirstButtonReturn{try library.discardParked(item)}
    }
   } catch {showError(error.localizedDescription)}
  }
  NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)
 }
 static func folderName(_ name:String)->String {
  let forbidden=CharacterSet(charactersIn:"/:\\").union(.controlCharacters)
  let clean=String(String.UnicodeScalarView(name.unicodeScalars.map{forbidden.contains($0) ? "_":$0})).trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:".")))
  return clean.isEmpty ? "Cloud":String(clean.prefix(100))
 }
}
/// Výchozí a poslední složka následují složku po změně cloud ↔ lokální.
func rememberMoved(_ mapping:[String:String]) {
 for key in ["defaultTopic","lastTopic"]{if let id=UserDefaults.standard.string(forKey:key),let next=mapping[id]{UserDefaults.standard.set(next,forKey:key)}}
}
/// Systémová notifikace o přesunu do Koše s akcí Obnovit; bez povolení zůstane zpráva v okně Cloudu.
final class TrashNotifier:NSObject,UNUserNotificationCenterDelegate {
 static let shared=TrashNotifier()
 func install() {
  let center=UNUserNotificationCenter.current();center.delegate=self
  center.setNotificationCategories([UNNotificationCategory(identifier:"session-trashed",actions:[UNNotificationAction(identifier:"restore",title:L("Obnovit"),options:[])],intentIdentifiers:[],options:[])])
  CloudFolders.shared.onTrashedQuietly={record,_ in TrashNotifier.shared.post(record)}
  CloudFolders.shared.onRetained={topic in TrashNotifier.shared.postRetained(topic)}
 }
 /// Bez povolení stačí zpráva v okně Cloudu, kterou synchronizace přidala vždy.
 func postRetained(_ topic:Topic) {
  let text=LF("Cloudová kopie byla smazána po konci předplatného, místní soubory jsou v koši složky %@ (.trash).",topic.displayName)
  UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]){granted,_ in
   guard granted else{return}
   let content=UNMutableNotificationContent();content.title="Screenshot Note";content.body=text
   UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"retention-"+(topic.cloudFolderID?.uuidString ?? topic.id),content:content,trigger:nil))
  }
 }
 func post(_ record:SessionRecord) {
  let text=LF("Relace %@ přesunuta do Koše na webu",record.title),fallback=LF("Relace „%@“ přesunuta do Koše na webu (lze obnovit 30 dní).",record.title)
  UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]){granted,_ in
   guard granted else{DispatchQueue.main.async{CloudFolders.shared.notify(fallback);NotificationCenter.default.post(name:.cloudFoldersChanged,object:nil)};return}
   let content=UNMutableNotificationContent();content.title="Screenshot Note";content.body=text;content.categoryIdentifier="session-trashed";content.userInfo=["session":record.id]
   UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:"trash-"+record.id,content:content,trigger:nil))
  }
 }
 func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler done:@escaping ()->Void) {
  if response.actionIdentifier=="restore",let id=(response.notification.request.content.userInfo["session"] as? String).flatMap(UUID.init(uuidString:)){Task{@MainActor in await CloudFolders.shared.restoreFromNotification(id)}}
  done()
 }
 func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler done:@escaping (UNNotificationPresentationOptions)->Void){done([.banner,.list])}
}
