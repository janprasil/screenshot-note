import AppKit
import Security
import CryptoKit
import ImageIO

/// Library z /me: osobní (id = uživatel) nebo tým; role přihlášeného uživatele.
struct CloudLibraryRef: Codable, Equatable { let id: UUID; let kind: String; let name: String?; let role: String?; var isTeam: Bool { kind == LibraryKind.team.rawValue } }

/// Druh library v API (`kind`, `owner_kind`).
enum LibraryKind: String { case personal, team }

/// Role v library (TEAMS.md); složku spravuje vlastník a správce.
enum LibraryRole: String { case owner, admin, member; static func manages(_ raw: String?) -> Bool { raw.flatMap(Self.init(rawValue:)).map { $0 != .member } ?? false } }

/// Odpověď /me; `libraries` chybí u staršího serveru (jen osobní library).
/// Stav cloudu osobní knihovny z /me; nil = starší server nebo vypnutý billing.
struct CloudAccess: Decodable, Equatable { let state: String; let upload_allowed: Bool }
struct CloudOwner: Decodable { let id: UUID; let email: String?; var libraries: [CloudLibraryRef]? = nil; var cloud: CloudAccess? = nil }

struct CloudManifest: Codable,Equatable {
 struct Image: Codable,Equatable { let index: Int; let bytes: Int; let sha256: String }
 let title: String; let comment: String; let configuration: String; let template: String; let captions: [String]; let images: [Image]
 var folder_id:UUID? = nil
 // Počet obrázků, které už server má; nil znamená novou relaci.
 var base_images:Int? = nil
 // Revize stažené relace; server při jiné revizi vrátí session_changed.
 var revision:String? = nil
 static func validRevision(_ value:String?)->Bool{value?.range(of:"^[1-9][0-9]{0,15}$",options:.regularExpression) != nil}
}

extension CloudManifest {
 var valid: Bool {
  func text(_ s: String, _ points: Int, _ bytes: Int) -> Bool { !s.contains("\0") && s.unicodeScalars.count <= points && s.utf8.count <= bytes }
  return (1...30).contains(images.count) && captions.count == images.count && text(title,500,2000) && text(comment,100000,100000)
   && text(configuration,200,800) && text(template,100000,100000) && captions.allSatisfy { text($0,20000,20000) }
   && captions.reduce(0,{$0 + $1.utf8.count}) <= 300000 && (base_images == nil || (0..<images.count).contains(base_images!)) && (revision == nil || (base_images != nil && Self.validRevision(revision))) && images.enumerated().allSatisfy { index,image in
    image.index == index + 1 && (1...52428800).contains(image.bytes) && image.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
   } && images.reduce(0,{$0 + $1.bytes}) <= 100000000
 }
}

// density=false dává bajty bez pHYs jako starší verze appky; staré cloudové relace se s nimi porovnávají.
func cloudImage(_ file: URL, density: Bool = true) throws -> Data {
 guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
       CGImageSourceGetCount(source) == 1,
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
       width > 0, height > 0 else { throw CloudFailure(L("Snímek nejde načíst jako obrázek. Lokálně zůstává uložený, do cloudu ho nahrát nejde.")) }
 guard width <= 16384, height <= 16384, width * height <= 64000000 else {
  throw CloudFailure(LF("Snímek má %ld × %ld px. Cloud přijme nejvýš 16 384 px na stranu a 64 Mpx. Lokálně zůstává uložený.", width, height))
 }
 guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = CGColorSpace(name: CGColorSpace.sRGB),
       let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CloudFailure.invalid }
 context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
 let output = NSMutableData()
 guard let converted = context.makeImage(), let encoder = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw CloudFailure.invalid }
 // DPI (144 = Retina 2×) nese měřítko snímku, web podle něj zobrazí skutečnou velikost.
 var options: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]]
 if density, let dpi = cloudDensity(props) { options[kCGImagePropertyDPIWidth] = dpi; options[kCGImagePropertyDPIHeight] = dpi }
 CGImageDestinationAddImage(encoder, converted, options as CFDictionary)
 guard CGImageDestinationFinalize(encoder) else { throw CloudFailure.invalid }
 // The server accepts a narrow RGB profile; retain only the encoded critical PNG chunks.
 let data = output as Data; var clean = Data(data.prefix(8)), offset = 8
 while offset + 12 <= data.count {
  let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
  guard length <= data.count - offset - 12 else { throw CloudFailure.invalid }
  let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii)
  if ["IHDR", "IDAT", "IEND"].contains(type) || density && type == "pHYs" { clean.append(data[offset..<offset + length + 12]) }
  else if data[offset + 4] & 32 == 0 { throw CloudFailure.invalid }
  if type == "IHDR" { guard length == 13, data[offset + 16] == 8, [2,6].contains(data[offset + 17]), data[offset + 20] == 0 else { throw CloudFailure.invalid } }
  offset += length + 12
 }
 guard offset == data.count else { throw CloudFailure.invalid }
 guard clean.count <= 52428800 else { throw CloudFailure(L("Snímek je po převodu větší než 50 MB, což je cloudový limit. Lokálně zůstává uložený.")) }; return clean
}

/// Celé měřítko 1×–4× ze shodného DPI v obou osách; jiné hodnoty se do cloudu neposílají.
func cloudDensity(_ props: [CFString: Any]) -> Double? {
 guard let x = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue, let y = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue,
       abs(x - y) < 0.5, (1...4).contains((x / 72).rounded()), abs(x / 72 - (x / 72).rounded()) < 0.05 else { return nil }
 return (x / 72).rounded() * 72
}
