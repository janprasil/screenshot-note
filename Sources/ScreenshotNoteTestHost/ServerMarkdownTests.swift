import Foundation
@testable import ScreenshotNoteKit

/// Data ze serveru nesmí vložit Markdown mimo své místo.
func serverMarkdownTests() throws {
 // Název a popis cloudové složky se escapují, lokální složka zůstává beze změny.
 var cloud=Topic(id:"cloud:x",name:"A ![x](https://evil.test/p.png)",detail:"---",folder:"",combined:true,combinedFile:"Note.md")
 cloud.cloudFolderID=UUID()
 let (name,detail)=combinedFolderText(cloud)
 let header=combinedTemplateParts(defaultCombinedTemplate,folderName:name,folderDescription:detail).0
 assert(header.contains("!\\[x]") && header.contains("\\---") && !header.contains("![x]"),header)
 var local=cloud;local.cloudFolderID=nil
 assert(combinedFolderText(local)==(cloud.name,cloud.detail))
 // Zpětný apostrof ve jménu autora neukončí code span, obrázek zůstane uvnitř.
 let comments=renderCommentList([RemoteNote.Comment(author_name:"Eve` ![p](https://evil.test/p.png) `",body:"Ahoj",created_at:nil)],template:nil)
 let author=comments.components(separatedBy:"\n")[1]
 assert(author.hasPrefix("`Eve' ![p](https://evil.test/p.png) '`"),author)
 print("PASS: cloud folder names and descriptions are escaped and author names cannot leave their code span")
}
