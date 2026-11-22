import Foundation
@testable import ScreenshotNoteKit

// Stejný vstup a výstup jako web tests/item-templates.test.mjs; změna tady = změna tam.
@MainActor func itemTemplateTests() throws {
 let utc=TimeZone(identifier:"UTC")!
 let at=parseServerDate("2026-11-22T14:05:00Z")!
 assert(formatTemplateDate(at,language:"cs",timeZone:utc)=="22. 11. 2026 14:05")
 assert(formatTemplateDate(at,language:"en",timeZone:utc)=="Nov 22, 2026, 14:05")
 assert(formatTemplateDate(parseServerDate("2026-01-02T03:04:00Z")!,language:"cs",timeZone:TimeZone(identifier:"Europe/Prague")!)=="2. 1. 2026 04:04")
 var note=RemoteNote(id:UUID(),title:"Relace ![x](https://e.test/x.png)\nDruhý",comment:"Text\n---\n![a](b)",template:defaultMarkdownTemplate,
  captions:["Popis 1","Popis 2\n\n- **[1] Element** `#btn`: klik"],images:[.init(index:1,path:"/1"),.init(index:2,path:"/2")])
 note.comments=[RemoteNote.Comment(author_name:"Jan `x`",body:"Celá relace",created_at:"2026-11-22T13:05:00Z"),
  RemoteNote.Comment(author_name:"Eva",body:"K obrázku ![p](q)",created_at:"2026-03-05T08:07:00Z",image_index:2)]
 note.author=CloudAuthor(id:nil,name:"Autor")
 let parityCs="# Relace !\\[x](https://e.test/x.png) Druhý\n\n# Screenshots\n\n![Screenshot 1](<assets/S-1.png>)\n\nPopis 1\n\n![Screenshot 2](<assets/S-2.png>)\n\nPopis 2\n\n- **[1] Element** `#btn`: klik\n\nK obrázku !\\[p](q)\n`Eva` - `5. 3. 2026 08:07`\n\n# Description\n\nText\n\\---\n!\\[a](b)\n\nCelá relace\n`Jan 'x'` - `22. 11. 2026 13:05`\n"
 let body=cloudSessionBody(note,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc)
 assert(body==parityCs,body)
 assert(cloudSessionBody(note,images:["S-1.png","S-2.png"],language:"en",timeZone:utc).contains("`Eva` - `Mar 5, 2026, 08:07`"))
 var custom=RemoteNote(id:note.id,title:note.title,comment:note.comment,template:"# {title}\n\n{issues}\n\n{screenshots}\n",captions:note.captions,images:note.images);custom.comments=note.comments
 custom.image_template="### {number}\n\n{image}\n\n{description}\n\n{elements}\n\n{comments}";custom.comment_template="> {text} ({name}, {date})"
 custom.issues=[.init(url:"https://github.com/o/r/issues/1",label:"o/r#1",title:"Bug ![t](u)"),.init(url:"https://x.test/a",label:"x.test",title:nil)]
 let parityCustom="# Relace !\\[x](https://e.test/x.png) Druhý\n\n- [o/r#1](<https://github.com/o/r/issues/1>) — Bug !\\[t](u)\n- [x.test](<https://x.test/a>)\n\n### 1\n\n![Screenshot 1](<assets/S-1.png>)\n\nPopis 1\n\n### 2\n\n![Screenshot 2](<assets/S-2.png>)\n\nPopis 2\n\n- **[1] Element** `#btn`: klik\n\n> K obrázku !\\[p](q) (Eva, 5. 3. 2026 08:07)\n"
 let customBody=cloudSessionBody(custom,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc)
 assert(customBody==parityCustom,customBody)
 // Bez nových polí (starší server) se nic nekóduje navíc a vykreslí se vestavěné šablony.
 let plain=RemoteNote(id:note.id,title:"T",comment:"",template:defaultMarkdownTemplate,captions:["A",""],images:[.init(index:1,path:"/1"),.init(index:2,path:"/2")])
 let encoded=String(data:try JSONEncoder().encode(plain),encoding:.utf8)!
 assert(!encoded.contains("issues") && !encoded.contains("image_template"),encoded)
 assert(cloudSessionBody(plain,images:["S-1.png","S-2.png"])=="# T\n\n# Screenshots\n\n![Screenshot 1](<assets/S-1.png>)\n\nA\n\n![Screenshot 2](<assets/S-2.png>)\n\n# Description\n")
 print("PASS: comment and image templates match the web export byte for byte ({date} cs/en, image comments, {elements}, {issues}, escaping)")

 assert(renderParagraphs("{a}\n\nX {b}\n\n{b}\n\n{c}",["a":"1","b":"","c":"{a}"])=="1\n\nX \n\n{a}")
 assert(splitElements("A\n\n- **[1] Kresba**: x\n  dál\n- **[2] Element**")==("A","- **[1] Kresba**: x\n  dál\n- **[2] Element**"))
 assert(splitElements("A\n\n- seznam")==("A\n\n- seznam",""))
 assert(checkItemTemplate("image",defaultImageTemplate).valid && !checkItemTemplate("image","{description}").valid)
 assert(checkItemTemplate("comment",defaultCommentTemplate+" {foo}").unknown==["foo"] && !checkItemTemplate("comment","").valid)
 // Lokální export a zpětné čtení popisků s vlastní šablonou obrázku.
 let template="### {number}\n\n{image}\n\n**{description}**\n\n{elements}"
 let screenshots=renderImageBlocks([ImageBlock(name:"a.png",caption:"První\n\n- **[1] Kresba**: x"),ImageBlock(name:"b.png",caption:"Druhý")],template:template)
 assert(screenshots=="### 1\n\n![Screenshot 1](<assets/a.png>)\n\n**První**\n\n- **[1] Kresba**: x\n\n### 2\n\n![Screenshot 2](<assets/b.png>)\n\n**Druhý**",screenshots)
 let session=renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:screenshots,text:"X")
 let parsed=parsedSession(defaultMarkdownTemplate,session,imageTemplate:template)
 assert(parsed?.2==["a.png","b.png"] && parsed?.3["a.png"]=="První\n\n- **[1] Kresba**: x" && parsed?.3["b.png"]=="Druhý",String(describing:parsed))
 // Výchozí šablona čte popisky jako dřív.
 let simple=renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:renderImageBlocks([ImageBlock(name:"a.png",caption:"Popis")],template:nil),text:"X")
 assert(parsedSession(defaultMarkdownTemplate,simple)?.3["a.png"]=="Popis")
 // Popis před obrázkem patří k následujícímu odkazu.
 let before="{description}\n\n{image}"
 let reversed=renderSessionTemplate(defaultMarkdownTemplate,title:"T",screenshots:renderImageBlocks([ImageBlock(name:"a.png",caption:"Jedna"),ImageBlock(name:"b.png",caption:"Dvě")],template:before),text:"X")
 let reread=parsedSession(defaultMarkdownTemplate,reversed,imageTemplate:before)
 assert(reread?.3["a.png"]=="Jedna" && reread?.3["b.png"]=="Dvě",String(describing:reread))
 // Komentáře obrázku cloudové relace nejsou součástí popisku.
 let withImageComment=cloudSessionBody(note,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc)
 let cloudRead=parsedSession(defaultMarkdownTemplate,withImageComment,comments:cloudImageComments(note,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc))
 assert(cloudRead?.3["S-2.png"]=="Popis 2\n\n- **[1] Element** `#btn`: klik" && cloudRead?.3["S-1.png"]=="Popis 1",String(describing:cloudRead))
 let customRead=parsedSession(custom.template,customBody,imageTemplate:custom.image_template,comments:cloudImageComments(custom,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc))
 assert(customRead?.3["S-2.png"]=="Popis 2\n\n- **[1] Element** `#btn`: klik",String(describing:customRead))
 // Šablona komentáře bez literálů popisek nesmaže; pole po obou stranách obrázku i komentáře předchozího obrázku.
 var plainComments=custom;plainComments.comment_template="{text}";plainComments.image_template="{description}\n\n{image}\n\n{elements}\n\n{comments}"
 let both=cloudSessionBody(plainComments,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc)
 let bothRead=parsedSession(plainComments.template,both,imageTemplate:plainComments.image_template,comments:cloudImageComments(plainComments,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc))
 assert(bothRead?.3["S-1.png"]=="Popis 1" && bothRead?.3["S-2.png"]=="Popis 2\n\n- **[1] Element** `#btn`: klik",String(describing:bothRead))
 var shifted=plainComments;shifted.comments=[RemoteNote.Comment(author_name:"Eva",body:"K prvnímu",created_at:"2026-03-05T08:07:00Z",image_index:1)]
 let shiftedRead=parsedSession(shifted.template,cloudSessionBody(shifted,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc),imageTemplate:shifted.image_template,comments:cloudImageComments(shifted,images:["S-1.png","S-2.png"],language:"cs",timeZone:utc))
 assert(shiftedRead?.3["S-2.png"]=="Popis 2\n\n- **[1] Element** `#btn`: klik" && shiftedRead?.3["S-1.png"]=="Popis 1",String(describing:shiftedRead))
 print("PASS: image template paragraphs, {elements} split, template checks and caption parsing with a custom image template")
}
