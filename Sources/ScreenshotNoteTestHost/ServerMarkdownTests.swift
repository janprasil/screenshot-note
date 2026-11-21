import Foundation
@testable import ScreenshotNoteKit

/// Data ze serveru nesmí rozbít šablonu ani vložit Markdown mimo své místo.
func serverMarkdownTests() throws {
 // Neplatná šablona relace ze serveru se nahradí výchozí.
 let broken=RemoteNote(id:UUID(),title:"T",comment:"X",template:"![x](https://evil.test/p.png) {text}",captions:[""],images:[.init(index:1,path:"/p")])
 let body=cloudSessionBody(broken,images:["a.png"])
 assert(!body.contains("evil.test") && body.contains("# T"),body)
 assert(validSessionTemplate(defaultMarkdownTemplate) && !validSessionTemplate("{title}") && !validSessionTemplate("{title}{screenshots}{text}"+String(repeating:"x",count:20001)))
 // Zpětný apostrof ve jménu autora neukončí code span.
 let comments=renderComments([RemoteNote.Comment(author_name:"Eve` ![p](https://evil.test/p.png) `",body:"Ahoj",created_at:nil)])
 assert(comments.components(separatedBy:"`").count==5,comments)
 print("PASS: server session templates are validated and author names cannot leave their code span")
}
