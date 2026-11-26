import AppKit
@testable import ScreenshotNoteKit

/// Smazaný místní adresář cloudové složky nesmí nic poslat do Koše (#75).
@MainActor func missingRootTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-missing-root-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 func flagged(_ f:DeletionFixture)->Int{SessionIndex.shared.all.filter{$0.folder==f.folderID.uuidString.lowercased() && ($0.held==true || $0.askDelete==true || $0.missingSince != nil)}.count}
 // Smazání hned po prvním stažení (kořen ještě neznámý), pak nový snímek adresář vytvoří: dřív 4× held, nic se nestáhlo.
 let a=try DeletionFixture(root.appendingPathComponent("unknown-root"),count:4,combined:false);try await a.start()
 try fm.removeItem(at:a.target)
 await a.scan(after:20)
 assert(a.posts.isEmpty && !fm.fileExists(atPath:a.target.path) && a.store.missingRoots.count==1 && a.store.notices==["Místní adresář složky Mazání chybí."])
 try fm.createDirectory(at:a.target,withIntermediateDirectories:true);try "# Nový\n".write(to:a.target.appendingPathComponent("Nový.md"),atomically:true,encoding:.utf8)
 assert(a.store.missingRoots.isEmpty)
 for _ in 0..<3{await a.scan(after:20)}
 assert(a.posts.isEmpty && flagged(a)==0 && a.store.heldFolders.isEmpty && a.store.deletePrompts.isEmpty && a.markdowns()==5 && !a.store.isMissing(a.store.topics[0]))
 // Známý kořen: smazání se ohlásí, znovu vytvořený adresář se naplní, nic se neposílá.
 let b=try DeletionFixture(root.appendingPathComponent("known-root"),count:3,combined:false);try await b.start();await b.scan(after:20)
 try fm.removeItem(at:b.target);await b.scan(after:20);await b.scan(after:20)
 assert(b.posts.isEmpty && !fm.fileExists(atPath:b.target.path) && b.store.notices.count==1)
 try fm.createDirectory(at:b.target,withIntermediateDirectories:true)
 // Stejná identita jako dřív (znovu použitý inode) po zmizení se nebere jako hromadné smazání.
 SessionIndex.shared.setRoot(try Topics.checkedDestination(b.target.path),itemIdentity(b.target)!)
 for _ in 0..<3{await b.scan(after:20)}
 assert(b.posts.isEmpty && flagged(b)==0 && b.markdowns()==3 && b.store.notices.isEmpty)
 print("PASS: deleted cloud folder directory: notice, no server calls, no held or askDelete; recreated or same-identity root downloads again")
 // Stáhnout znovu: vytvoří adresář a stáhne vše; server se nemění.
 let c=try DeletionFixture(root.appendingPathComponent("redownload"),count:3,combined:false);try await c.start();await c.scan(after:20)
 try fm.removeItem(at:c.target);await c.scan(after:20)
 let missing=c.store.missingRoots[0];try c.store.redownload(missing)
 assert(fm.fileExists(atPath:c.target.path) && c.store.missingRoots.isEmpty && !c.store.isMissing(missing))
 await c.scan(after:20);await c.scan(after:20)
 assert(c.posts.isEmpty && c.markdowns()==3 && flagged(c)==0)
 // Vybrat jiný adresář: stáhne se do nového, starý stav indexu zmizí.
 let d=try DeletionFixture(root.appendingPathComponent("relocate"),count:2,combined:false);try await d.start();await d.scan(after:20)
 let oldBase=try Topics.checkedDestination(d.target.path);try fm.removeItem(at:d.target);await d.scan(after:20)
 let other=d.root.appendingPathComponent("elsewhere");try d.store.relocate(d.store.missingRoots[0],path:other.path)
 await d.scan(after:20);await d.scan(after:20)
 let moved=((try? fm.contentsOfDirectory(atPath:other.path)) ?? []).filter{$0.hasSuffix(".md")}
 assert(d.posts.isEmpty && moved.count==2 && SessionIndex.shared.cloudRecords(base:oldBase,folder:d.folderID).isEmpty && d.store.missingRoots.isEmpty && !fm.fileExists(atPath:d.target.path))
 // Jiný adresář nesmí ležet uvnitř jiné složky.
 let e=try DeletionFixture(root.appendingPathComponent("detach"),count:2,combined:false);try await e.start();await e.scan(after:20)
 try fm.removeItem(at:e.target);await e.scan(after:20)
 let local=Topic(id:"local-near",name:"Lokální",detail:"",folder:e.root.appendingPathComponent("local").path,combined:false,combinedFile:"Notes.md")
 do{try Topics.validateDestination(e.store.missingRoots[0],folder:URL(fileURLWithPath:local.folder+"/inner"),among:[local]+e.store.allTopics);assertionFailure("Nested relocate must fail")}catch{}
 // Odpojit na tomto Macu: bez adresáře, bez stahování, nenabízí se k namapování.
 try e.store.detach(e.store.missingRoots[0])
 assert(e.store.topics[0].folder.isEmpty && e.store.isDetached(e.store.topics[0]) && e.store.notices.isEmpty)
 await e.scan(after:20);await e.scan(after:20)
 assert(e.posts.isEmpty && !fm.fileExists(atPath:e.target.path) && e.store.records[0].detached==true && SessionIndex.shared.all.filter{$0.folder==e.folderID.uuidString.lowercased()}.isEmpty)
 // Nové namapování odpojení zruší.
 try e.store.setFolder(e.store.topics[0],path:e.target.path);assert(!e.store.isDetached(e.store.topics[0]))
 await e.scan(after:20);assert(e.markdowns()==2 && e.posts.isEmpty)
 print("PASS: missing directory actions: download again refills, another directory downloads there and forgets the old index, disconnect on this Mac stops syncing until remapped")
 // Lokální složka: chybí jen ta, do které aplikace dřív ukládala.
 let used=root.appendingPathComponent("local-used"),fresh=root.appendingPathComponent("local-fresh")
 let usedTopic=Topic(id:"used",name:"Použitá",detail:"",folder:used.path,combined:false,combinedFile:"Notes.md"),freshTopic=Topic(id:"fresh",name:"Nová",detail:"",folder:fresh.path,combined:false,combinedFile:"Notes.md")
 try fm.createDirectory(at:used,withIntermediateDirectories:true);let note=used.appendingPathComponent("Relace.md");try "# Relace\n".write(to:note,atomically:true,encoding:.utf8)
 SessionIndex.shared.put(SessionRecord(id:UUID().uuidString,file:SessionIndex.key(note),start:0,length:9,hash:"",heading:"# Relace",title:"Relace",comment:"",template:defaultMarkdownTemplate,images:[],notes:[:],combined:false,footer:"",files:[:],seen:1))
 assert(!Topics.missingLocal(usedTopic) && !Topics.missingLocal(freshTopic))
 try fm.removeItem(at:used)
 assert(Topics.missingLocal(usedTopic) && !Topics.missingLocal(freshTopic) && FolderDialogs.isMissing(usedTopic) && !FolderDialogs.isMissing(freshTopic))
 // Disk v /Volumes, který není připojený, se nevytváří.
 assert(Topics.volumeMissing("/Volumes/SN-nepripojeny-"+UUID().uuidString+"/Složka") && !Topics.volumeMissing(used.path) && !Topics.volumeMissing("/Volumes"))
 do{try Topics.ensureVolume("/Volumes/SN-nepripojeny-"+UUID().uuidString+"/Složka");assertionFailure("Unmounted volume must fail")}catch{}
 print("PASS: local folder counts as missing only when the app saved sessions there before")
}

/// Adresáře složek se nesmí překrývat (#74).
@MainActor func nestedFolderTests() async throws {
 let root=fm.temporaryDirectory.appendingPathComponent("sn-nested-"+UUID().uuidString)
 try fm.createDirectory(at:root,withIntermediateDirectories:true);defer{try? fm.removeItem(at:root)}
 let previousIndex=SessionIndex.shared;SessionIndex.shared=SessionIndex(file:root.appendingPathComponent("index.json"));defer{SessionIndex.shared=previousIndex}
 let language=AppLanguage.override;AppLanguage.override="cs";defer{AppLanguage.override=language}
 let parent=root.appendingPathComponent("Rodič"),child=parent.appendingPathComponent("Dítě"),sibling=root.appendingPathComponent("Rodič 2")
 try fm.createDirectory(at:child,withIntermediateDirectories:true);try fm.createDirectory(at:sibling,withIntermediateDirectories:true)
 let link=root.appendingPathComponent("odkaz");try fm.createSymbolicLink(at:link,withDestinationURL:parent)
 func checked(_ url:URL)->URL{try! Topics.checkedDestination(url.path)}
 assert(Topics.overlaps(checked(parent),checked(parent)) && Topics.overlaps(checked(parent),checked(child)) && Topics.overlaps(checked(child),checked(parent)))
 assert(!Topics.overlaps(checked(parent),checked(sibling)) && !Topics.overlaps(checked(sibling),checked(child)))
 // Symlink na rodiče a jiná velikost písmen (výchozí svazek nerozlišuje) jsou stejný strom.
 assert(Topics.overlaps(checked(link.appendingPathComponent("Dítě")),checked(parent)) && Topics.overlaps(checked(link),checked(child)))
 let sensitive=(try? root.resourceValues(forKeys:[.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == true
 if !sensitive{assert(Topics.overlaps(checked(root.appendingPathComponent("RODIČ/nové")),checked(parent)))}
 // Unicode: rozložené „č“ je stejný název.
 assert(Topics.overlaps(checked(root.appendingPathComponent("Rodic\u{30C}/jiné")),checked(parent)))
 assert(Topics.inside(checked(child),URL(fileURLWithPath:"/")) && !Topics.inside(URL(fileURLWithPath:"/"),checked(child)))
 // Nastavovaná složka: stejný adresář, uvnitř i nad jinou složkou se odmítá s jasnou hláškou; vedle ne.
 let a=Topic(id:"a",name:"Projekt",detail:"",folder:parent.path,combined:false,combinedFile:"Notes.md")
 var b=Topic(id:"b",name:"Druhá",detail:"",folder:child.path,combined:false,combinedFile:"Notes.md")
 for target in [child,child.appendingPathComponent("hluboko"),root,parent.appendingPathComponent(".trash"),parent.appendingPathComponent("assets")] {
  do{try Topics.validateDestination(b,folder:target,among:[a]);assertionFailure("Nested folder must fail: \(target.path)")}
  catch{assert(error.localizedDescription=="Adresář leží uvnitř složky „Projekt“ (nebo ji obsahuje). Vyber adresář mimo ni.")}
 }
 do{try Topics.validateDestination(b,folder:parent,among:[a]);assertionFailure("Same folder must fail")}catch{assert(error.localizedDescription.contains("Složku už používá"))}
 try Topics.validateDestination(b,folder:sibling,among:[a])
 // Starší vnořená konfigurace: ukládání ostatních složek, synchronizace i snímek fungují, složka nese varování.
 try Topics.validateDestinations([a,b]);try Topics.validateDestination(b,folder:child,among:[a],nested:true)
 assert(Topics.overlapping(b,among:[a,b])?.id=="a" && Topics.overlapping(a,among:[a,b])?.id=="b")
 b.folder=sibling.path;assert(Topics.overlapping(b,among:[a,b])==nil)
 // Nadřazená složka cloudu nesmí být složkou ani ležet uvnitř ní; obsahovat složky smí.
 do{try Topics.validateParent(child,among:[a]);assertionFailure("Cloud root inside folder must fail")}catch{}
 do{try Topics.validateParent(parent,among:[a]);assertionFailure("Cloud root equal to folder must fail")}catch{}
 try Topics.validateParent(root,among:[a])
 print("PASS: folder directories may not overlap: same, ancestor, descendant, symlink, case and Unicode folding, .trash/assets, cloud parent root")
 // Cloudové mapování: setFolder a nadřazená složka odmítají vnoření; stávající vnoření nezablokuje katalog.
 let c=cloudFixtureConnection(),owner=c.ownerID!
 let local=Topic(id:"local",name:"Lokální",detail:"",folder:parent.path,combined:false,combinedFile:"Notes.md")
 let store=CloudFolders(file:root.appendingPathComponent("folders.json"),connection:{c},localTopics:{[local]});store.activate(c)
 let first=UUID(),second=UUID()
 try store.accept([CloudFolderRecord(id:first,name:"Cloud",owner:owner,origin:c.endpoint),CloudFolderRecord(id:second,name:"Druhý",owner:owner,origin:c.endpoint)])
 let cloud=store.topics.first{$0.cloudFolderID==first}!
 do{try store.setFolder(cloud,path:child.path);assertionFailure("Cloud folder inside local folder must fail")}catch{assert(error.localizedDescription.contains("Lokální"))}
 do{try FolderDialogs.assign([cloud],root:parent,folders:store);assertionFailure("Cloud parent inside local folder must fail")}catch{}
 assert(store.topics.allSatisfy{$0.folder.isEmpty})
 try FolderDialogs.assign(store.topics,root:sibling,folders:store)
 assert(store.topics.allSatisfy{URL(fileURLWithPath:$0.folder).deletingLastPathComponent().lastPathComponent=="Rodič 2"})
 // Starší vnořené mapování uložené dřív: katalog i jiná složka se dál ukládají.
 let legacy=root.appendingPathComponent("legacy.json")
 var nestedRecord=CloudFolderRecord(id:first,name:"Cloud",owner:owner,origin:c.endpoint);nestedRecord.folder=child.path;nestedRecord.accountID=owner
 try JSONEncoder().encode([nestedRecord,CloudFolderRecord(id:second,name:"Druhý",owner:owner,origin:c.endpoint)]).write(to:legacy)
 let old=CloudFolders(file:legacy,connection:{c},localTopics:{[local]});old.activate(c)
 try old.accept([CloudFolderRecord(id:first,name:"Cloud",owner:owner,origin:c.endpoint),CloudFolderRecord(id:second,name:"Druhý",owner:owner,origin:c.endpoint)])
 try old.setFolder(old.topics.first{$0.cloudFolderID==second}!,path:root.appendingPathComponent("Jinde").path)
 assert(old.topics.first{$0.cloudFolderID==first}?.folder==child.path && Topics.overlapping(old.topics.first{$0.cloudFolderID==first}!,among:[local]+old.allTopics)?.id=="local")
 print("PASS: cloud mapping rejects nesting in setFolder and parent assignment; legacy nested mapping keeps the catalog and other folders saving")
 // Cloudová složka obsahující lokální složku: soubory vnořené složky nejsou její a smazání do nich nesáhne.
 let host=root.appendingPathComponent("Host"),inner=host.appendingPathComponent("Vnitřní")
 try fm.createDirectory(at:inner,withIntermediateDirectories:true)
 let innerNote=inner.appendingPathComponent("Moje.md");try "# Moje\n".write(to:innerNote,atomically:true,encoding:.utf8)
 let hostNote=host.appendingPathComponent("Cloud.md");try "# Cloud\n".write(to:hostNote,atomically:true,encoding:.utf8)
 let innerTopic=Topic(id:"inner",name:"Vnitřní",detail:"",folder:inner.path,combined:false,combinedFile:"Notes.md")
 var hostRecord=CloudFolderRecord(id:UUID(),name:"Host",owner:owner,origin:c.endpoint);hostRecord.folder=host.path;hostRecord.accountID=owner
 try JSONEncoder().encode([hostRecord]).write(to:root.appendingPathComponent("hosting.json"))
 let hosting=CloudFolders(file:root.appendingPathComponent("hosting.json"),connection:{c},localTopics:{[innerTopic]});hosting.activate(c)
 func record(_ file:URL,cloud:Bool)->SessionRecord{var r=SessionRecord(id:UUID().uuidString,file:SessionIndex.key(file),start:0,length:8,hash:"",heading:"",title:"",comment:"",template:defaultMarkdownTemplate,images:[],notes:[:],combined:false,footer:"",files:[:],seen:1);if cloud{r.base=SessionIndex.key(checked(host));r.folder=hostRecord.id.uuidString.lowercased();r.flat=true};return r}
 SessionIndex.shared.put(record(hostNote,cloud:true));SessionIndex.shared.put(record(innerNote,cloud:false))
 assert(hosting.nestedRoots(checked(host))==[SessionIndex.key(checked(inner))])
 let known=hosting.knownFiles(checked(host))
 assert(known.contains(SessionIndex.key(hostNote)) && !known.contains(SessionIndex.key(innerNote)) && hosting.hasUnknownFiles(host.path))
 assert(!hosting.knownItems(checked(host)).contains{SessionIndex.key($0).hasPrefix(SessionIndex.key(inner))})
 print("PASS: cloud folder containing an older nested folder never claims or deletes the nested folder's files")
}
