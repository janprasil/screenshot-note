import AppKit
import Security
import CryptoKit
import ImageIO

struct CloudEndpoint: Equatable {
 let url: URL
 init?(_ raw: String) {
  guard var p = URLComponents(string: raw), let host = p.host, p.user == nil, p.password == nil,
        p.query == nil, p.fragment == nil, p.path.isEmpty || p.path == "/",
        p.scheme == "https" || (p.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else { return nil }
  p.path = ""; guard let url = p.url else { return nil }; self.url = url
 }
 func path(_ path: String) -> URL { URL(string: url.absoluteString + path)! }
}

enum CloudBuild {
 static let endpoint: CloudEndpoint = {
  guard let raw = Bundle.main.object(forInfoDictionaryKey: "ScreenshotNoteWebOrigin") as? String,
        let endpoint = CloudEndpoint(raw) else { preconditionFailure("Missing build web origin") }
  return endpoint
 }()
}

struct CloudConnection: Codable {
 let endpoint: String
 let token: String
 let id: UUID
 let comparisonCode: String
 let verificationURI: String
 var expiresAt: String
 var ownerID: UUID?
 var email: String?
 static func validToken(_ token: String) -> Bool {
  token.range(of: "^sn_device_v1_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil
 }
}

protocol CloudCredentialStore {
 func load() throws -> CloudConnection?
 func save(_ value: CloudConnection?) throws
}
struct CloudKeychain: CloudCredentialStore {
 let endpoint: CloudEndpoint
 init(endpoint: CloudEndpoint = CloudBuild.endpoint) { self.endpoint = endpoint }
 var service: String {
  let base = "cz.janprasil.screenshotnote.device.v1"
  if endpoint == CloudEndpoint("https://screenshotnote.com") { return base }
  return base + "." + SHA256.hash(data: Data(endpoint.url.absoluteString.utf8)).map { String(format:"%02x",$0) }.joined()
 }
 private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
  kSecAttrService as String: service, kSecAttrAccount as String: "current",
  kSecAttrSynchronizable as String: false] }
 func load() throws -> CloudConnection? {
  var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
  var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
  if status == errSecItemNotFound { return nil }
  guard status == errSecSuccess, let data = value as? Data else { throw CloudFailure.keychain }
  return try JSONDecoder().decode(CloudConnection.self, from: data)
 }
 func save(_ value: CloudConnection?) throws {
  guard let value else { let s = SecItemDelete(query as CFDictionary); guard s == errSecSuccess || s == errSecItemNotFound else { throw CloudFailure.keychain }; return }
  let data = try JSONEncoder().encode(value)
  let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
  if updated == errSecItemNotFound {
   var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
   guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CloudFailure.keychain }
  } else if updated != errSecSuccess { throw CloudFailure.keychain }
 }
}

struct CloudFailure: LocalizedError {
 let message: String
 let status: Int
 let retryAfter: TimeInterval
 var code: String? = nil
 init(_ message: String, status: Int = 0, retryAfter: TimeInterval = 0, code: String? = nil) { self.message = message; self.status = status; self.retryAfter = retryAfter; self.code = code }
 var errorDescription: String? { message }
 static var keychain: Self { Self(L("Přístup do Keychain se nezdařil. Připojení nebylo změněno.")) }
 static var invalid: Self { Self(L("Server vrátil neplatnou odpověď. Lokální data zůstávají zachovaná.")) }
}

final class CloudTransport: NSObject, URLSessionTaskDelegate {
 static let shared = CloudTransport()
 lazy var session: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
  config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.timeoutIntervalForResource = 75
  return URLSession(configuration: config, delegate: self, delegateQueue: nil)
 }()
 func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                 newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
 func request(_ endpoint: CloudEndpoint, _ path: String, method: String = "GET", token: String? = nil,
              body: Data? = nil, file: URL? = nil, limit:Int=524288) async throws -> Data {
  guard path.hasPrefix("/api/v1/"), !path.contains("#"), !path.contains(".."), (1...52428800).contains(limit) else { throw CloudFailure.invalid }
  var req = URLRequest(url: endpoint.path(path)); req.httpMethod = method; req.timeoutInterval = file == nil ? 15 : 70
  if let token { guard CloudConnection.validToken(token) else { throw CloudFailure.invalid }; req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
  if let file {
   req.httpBodyStream = InputStream(url: file)
   let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
   req.setValue(String(bytes), forHTTPHeaderField: "Content-Length"); req.setValue("image/png", forHTTPHeaderField: "Content-Type")
  } else if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
  let (stream, response) = try await session.bytes(for: req)
  guard let http = response as? HTTPURLResponse else { throw CloudFailure.invalid }
  var data = Data()
  for try await byte in stream { if data.count >= limit { throw CloudFailure.invalid }; data.append(byte) }
  guard (200..<300).contains(http.statusCode) else {
   let retry = min(3600, max(0, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0))
   let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { $0["error"] as? [String: Any] }?["code"] as? String
   let message: String
   switch http.statusCode {
    case 401, 403: message = L("Zařízení nemá přístup. Zkontroluj připojení na webu nebo jej spáruj znovu.")
    case 402: message = L("Nahrávání do cloudu vyžaduje aktivní tarif nebo trial. Poznámka zůstává uložená lokálně.")
    case 413: message = L("V cloudu už pro tuto relaci nezbývá místo. Poznámka zůstává uložená lokálně; uvolni místo nebo zvyš tarif na webu.")
    case 415: message = L("Server nepřijal obrázek. Lokální relace zůstává ve frontě.")
    case 429: message = L("Příliš mnoho požadavků. Další pokus počká na povolený interval.")
    case 503: message = L("Cloud je teď nedostupný. Poznámky počkají na Macu a nahrají se později.")
    case 409, 410: message = L("Přenos zatím nelze dokončit. Zkus jej později znovu; lokální data zůstávají zachovaná.")
    default: message = LF("Cloud vrátil chybu HTTP %ld.", http.statusCode)
   }
   throw CloudFailure(message, status: http.statusCode, retryAfter: max(retry, code == "upload_incomplete" ? 90 : 0), code: code)
  }
  return data
 }
}

private struct Envelope<T: Decodable>: Decodable { let data: T }
private struct Pairing: Decodable {
 let id: UUID; let expires_at: String; let device_token: String; let comparison_code: String; let verification_uri: String; let interval: Int
}
private struct PairingStatus: Decodable { let state: String; let expires_at: String; let interval: Int }
private struct CloudOwner: Decodable { let id: UUID; let email: String? }
struct CloudManifest: Codable,Equatable {
 struct Image: Codable,Equatable { let index: Int; let bytes: Int; let sha256: String }
 let title: String; let comment: String; let configuration: String; let template: String; let captions: [String]; let images: [Image]
 var folder_id:UUID? = nil
 // Počet obrázků, které už server má; nil znamená novou relaci.
 var base_images:Int? = nil
}
extension CloudManifest {
 var valid: Bool {
  func text(_ s: String, _ points: Int, _ bytes: Int) -> Bool { !s.contains("\0") && s.unicodeScalars.count <= points && s.utf8.count <= bytes }
  return (1...30).contains(images.count) && captions.count == images.count && text(title,500,2000) && text(comment,100000,100000)
   && text(configuration,200,800) && text(template,100000,100000) && captions.allSatisfy { text($0,20000,20000) }
   && captions.reduce(0,{$0 + $1.utf8.count}) <= 300000 && (base_images == nil || (0..<images.count).contains(base_images!)) && images.enumerated().allSatisfy { index,image in
    image.index == index + 1 && (1...52428800).contains(image.bytes) && image.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
   } && images.reduce(0,{$0 + $1.bytes}) <= 100000000
 }
}
private struct CloudJob: Codable {
 let schemaVersion: Int
 let endpoint: String
 let ownerID: UUID
 let sessionID: UUID
 let manifest: CloudManifest
 var manifestDigest: String?
}
private struct UploadStatus: Decodable {
 let session_id: UUID; let state: String; let manifest_digest: String; let confirmed_indices: [Int]
}
private struct EditedSession: Decodable { let title: String; let comment: String; let captions: [String]; let revision: FlexibleString? }
private struct RemoteSession: Decodable {
 struct Image: Decodable { let index: Int; let path: String }
 let id: UUID; let captions: [String]; let images: [Image]
}
private struct CommittedUpload:Codable{let owner:UUID;let origin:String;let id:UUID;let folder:UUID?;let digest:String}

func cloudImage(_ file: URL) throws -> Data {
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
 CGImageDestinationAddImage(encoder, converted, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGInterlaceType: 0]] as CFDictionary)
 guard CGImageDestinationFinalize(encoder) else { throw CloudFailure.invalid }
 // The server accepts a narrow RGB profile; retain only the encoded critical PNG chunks.
 let data = output as Data; var clean = Data(data.prefix(8)), offset = 8
 while offset + 12 <= data.count {
  let length = data[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
  guard length <= data.count - offset - 12 else { throw CloudFailure.invalid }
  let type = String(bytes: data[offset + 4..<offset + 8], encoding: .ascii)
  if ["IHDR", "IDAT", "IEND"].contains(type) { clean.append(data[offset..<offset + length + 12]) }
  else if data[offset + 4] & 32 == 0 { throw CloudFailure.invalid }
  if type == "IHDR" { guard length == 13, data[offset + 16] == 8, [2,6].contains(data[offset + 17]), data[offset + 20] == 0 else { throw CloudFailure.invalid } }
  offset += length + 12
 }
 guard offset == data.count else { throw CloudFailure.invalid }
 guard clean.count <= 52428800 else { throw CloudFailure(L("Snímek je po převodu větší než 50 MB, což je cloudový limit. Lokálně zůstává uložený.")) }; return clean
}

final class CloudLibrary {
 static let shared = CloudLibrary()
 let endpoint: CloudEndpoint
 private let queue: URL
 private let vault: CloudCredentialStore
 private let now: () -> Date
 private(set) var connection: CloudConnection?
 private(set) var syncing = false
 private(set) var connecting = false
 private(set) var retryAt = Date.distantPast
 // Retry-After sdílení platí jen pro účet a origin, pro který přišel.
 private var shareRetry:(account:String,until:Date)?
 private var nextPoll = Date.distantPast
 var lastError: String?
 // Chyby tarifu (402/413) hlásíme hned po uložení, ne jen v okně cloudu.
 var onQuotaFailure: ((String) -> Void)?
 var didChange: (() -> Void)?

 init(queue: URL = draftRoot.deletingLastPathComponent().appendingPathComponent("Cloud Outbox", isDirectory: true), vault: CloudCredentialStore? = nil, endpoint: CloudEndpoint = CloudBuild.endpoint, now: @escaping () -> Date = Date.init) {
  self.queue = queue; self.endpoint = endpoint; self.vault = vault ?? CloudKeychain(endpoint:endpoint); self.now = now
  do {
   if let saved = try self.vault.load() {
    guard CloudEndpoint(saved.endpoint) == endpoint, CloudConnection.validToken(saved.token), Self.browserURL(saved) != nil else { throw CloudFailure.invalid }
    connection = saved
   }
  } catch { lastError = L("Uložené připojení nelze načíst. Zkontroluj Keychain; lokální data se nemění.") }
 }
 var signedInEmail: String? { connection.flatMap { c in c.ownerID.map { c.email ?? $0.uuidString } } }
 var pendingCount: Int { jobs().count + edits().count }
 var legacyPendingCount: Int { entries().filter { readJob($0) == nil }.count }
 private func readJob(_ directory: URL) -> CloudJob? {
  guard let handle = try? FileHandle(forReadingFrom:directory.appendingPathComponent("job.json")) else { return nil }
  defer { try? handle.close() }
  guard let data = try? handle.read(upToCount:1000001), data.count <= 1000000,
        let job = try? JSONDecoder().decode(CloudJob.self,from:data),job.schemaVersion == 1,job.manifest.valid,
        job.manifestDigest == nil || job.manifestDigest!.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
        directory.lastPathComponent == job.sessionID.uuidString.lowercased() else { return nil };return job
 }
 static func browserURL(_ c: CloudConnection) -> URL? {
  guard let endpoint = CloudEndpoint(c.endpoint), let url = URL(string: c.verificationURI),
        url == endpoint.path("/pair-device/" + c.id.uuidString.lowercased()) else { return nil }; return url
 }
 private static func date(_ raw: String) -> Date? {
  let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
 }
 @MainActor func startPairing(endpoint: CloudEndpoint, name: String) async throws {
  guard endpoint == self.endpoint, !syncing, !connecting, now() >= retryAt, connection == nil else { throw CloudFailure.invalid }
  connecting = true; defer { connecting = false; didChange?() }
  let clean = String(String.UnicodeScalarView(name.unicodeScalars.filter { !CharacterSet.controlCharacters.union(.illegalCharacters).contains($0) }.prefix(100)))
  let body = try JSONEncoder().encode(["device_name": clean.isEmpty ? "Mac" : clean])
  let data: Data
  do { data = try await CloudTransport.shared.request(endpoint, "/api/v1/device-pairings", method: "POST", body: body) }
  catch { retryAt = now().addingTimeInterval(max(5,(error as? CloudFailure)?.retryAfter ?? 15));throw error }
  let result = try JSONDecoder().decode(Envelope<Pairing>.self, from: data).data
  let saved = CloudConnection(endpoint: endpoint.url.absoluteString, token: result.device_token, id: result.id,
    comparisonCode: result.comparison_code, verificationURI: result.verification_uri, expiresAt: result.expires_at)
  guard CloudConnection.validToken(saved.token), saved.comparisonCode.range(of: "^[A-F0-9]{8}$", options: .regularExpression) != nil,
        Self.browserURL(saved) != nil, let expires = Self.date(saved.expiresAt), expires > now(), expires < now().addingTimeInterval(660), result.interval >= 5 else { throw CloudFailure.invalid }
  try vault.save(saved); connection = saved; nextPoll = now().addingTimeInterval(TimeInterval(result.interval)); lastError = nil
  didChange?()
 }
 @MainActor func refreshConnection() async throws {
  guard !connecting, !syncing, let current = connection, let endpoint = CloudEndpoint(current.endpoint) else { return }
  guard now() >= nextPoll else { return }
  connecting = true; defer { connecting = false; didChange?() }
  nextPoll = now().addingTimeInterval(5)
  let data: Data
  do { data = try await CloudTransport.shared.request(endpoint, "/api/v1/device-pairing", token: current.token) }
  catch { nextPoll = now().addingTimeInterval(max(30,(error as? CloudFailure)?.retryAfter ?? 30));throw error }
  let status = try JSONDecoder().decode(Envelope<PairingStatus>.self, from: data).data
  nextPoll = now().addingTimeInterval(TimeInterval(max(5, min(3600, status.interval))))
  guard status.state == "active" else {
   if status.state == "pending", current.ownerID == nil, let expiry = Self.date(status.expires_at), expiry > now() { return }
   nextPoll = .distantFuture
   throw CloudFailure(L("Párování bylo odmítnuto, odvoláno nebo vypršelo. Připoj zařízení znovu."), status: 403)
  }
  let ownerData = try await CloudTransport.shared.request(endpoint, "/api/v1/me", token: current.token)
  let owner = try JSONDecoder().decode(Envelope<CloudOwner>.self, from: ownerData).data
  guard current.ownerID == nil || current.ownerID == owner.id, let expiry = Self.date(status.expires_at), expiry > now() else { throw CloudFailure.invalid }
  var saved = current; saved.ownerID = owner.id; saved.email = owner.email; saved.expiresAt = status.expires_at
  try vault.save(saved); connection = saved; lastError = nil
 }
 @MainActor func cancelPairing() async throws {
  guard !connecting, !syncing, let c = connection, c.ownerID == nil, let endpoint = CloudEndpoint(c.endpoint) else { return }
  connecting = true; defer { connecting = false; didChange?() }
  _ = try await CloudTransport.shared.request(endpoint, "/api/v1/device-pairing", method: "DELETE", token: c.token)
  try vault.save(nil); connection = nil; lastError = nil
 }
 func forgetConnection() throws {
  guard !syncing, !connecting else { throw CloudFailure.invalid }
  try vault.save(nil); connection = nil; lastError = nil; didChange?()
 }
 func requireAccount() throws {
  guard let c = connection, c.ownerID != nil, let expiry = Self.date(c.expiresAt), expiry > now() else {
   throw CloudFailure(L("Nejprve připoj a potvrď tento Mac v Cloudové knihovně."))
  }
 }
 private func entries() -> [URL] { ((try? fm.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent } }
 private func jobs() -> [(URL, CloudJob)] {
  guard let c = connection, let owner = c.ownerID else { return [] }
  return entries().compactMap { directory in
   guard let job = readJob(directory), job.endpoint == c.endpoint, job.ownerID == owner, directory.lastPathComponent == job.sessionID.uuidString.lowercased() else { return nil }
   return (directory, job)
  }
 }
 private func committedFile(_ id:UUID,_ c:CloudConnection)->URL {
  let name=SHA256.hash(data:Data((c.endpoint+(c.ownerID?.uuidString ?? "")+id.uuidString).utf8)).map{String(format:"%02x",$0)}.joined()
  return queue.appendingPathComponent(".committed").appendingPathComponent(name)
 }
 func isCommitted(_ id:UUID,folder:UUID?)->Bool {
  guard let c=connection,let data=try? Data(contentsOf:committedFile(id,c)),data.count<1024,
        let receipt=try? JSONDecoder().decode(CommittedUpload.self,from:data) else{return false}
  return receipt.owner==c.ownerID && receipt.origin==c.endpoint && receipt.id==id && receipt.folder==folder && receipt.digest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil
 }
 @discardableResult func enqueue(_ draft: Draft, root: URL,sessionID:UUID=UUID(),folders:[Topic]?=nil,base:[String]?=nil) throws ->UUID {
  try requireAccount(); guard let c = connection, let owner = c.ownerID else { throw CloudFailure.invalid }
  guard (1...30).contains(draft.images.count) else { throw CloudFailure(L("Cloudová relace může obsahovat 1 až 30 snímků. Lokální ukládání tento limit nemá.")) }
  let id = sessionID, title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
  // Nová cloudová relace musí patřit do cloudové složky.
  guard base != nil || draft.topic?.cloudFolderID != nil else { throw CloudFailure(L("Do cloudu lze ukládat jen do cloudové složky. Vyber cloudovou složku; poznámka zůstává uložená lokálně."),code:"folder_required") }
  if base == nil && isCommitted(id,folder:draft.topic?.cloudFolderID){return id}
  if let base { guard draft.images.count > base.count else { throw CloudFailure(L("Přidej do cloudové relace alespoň jeden nový snímek.")) } }
  let captions = draft.images.map { draft.imageNotes?[$0] ?? "" }
  func valid(_ s: String, _ points: Int, _ bytes: Int) -> Bool { !s.contains("\0") && s.unicodeScalars.count <= points && s.utf8.count <= bytes }
  let heading = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Screenshot", config = draft.topic?.name ?? "", template = draft.topic?.markdownTemplate ?? defaultMarkdownTemplate
  guard valid(heading,500,2000), valid(draft.comment,100000,100000), valid(config,200,800), valid(template,100000,100000),
        captions.allSatisfy({valid($0,20000,20000)}), captions.reduce(0,{$0 + $1.utf8.count}) <= 300000 else { throw CloudFailure(L("Text relace překračuje cloudový limit. Lokální data zůstávají zachovaná.")) }
  let staging = queue.appendingPathComponent("." + id.uuidString, isDirectory: true)
  try? fm.removeItem(at: staging)
  try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: staging) }
  var images: [CloudManifest.Image] = []; var bytes = 0
  for (index, filename) in draft.images.enumerated() {
   guard URL(fileURLWithPath: filename).lastPathComponent == filename, !filename.contains("/") else { throw CloudFailure.invalid }
   let data: Data
   if let base, index < base.count {
    // Původní snímky se posílají bajtově shodné se serverem, bez nového kódování.
    var raw = try boundedData(root.appendingPathComponent(filename), max: 52428800)
    // Převzatá místní kopie může mít originál; serverové bajty z něj vzniknou převodem.
    if sessionFingerprint(raw) != base[index], let normalized = try? cloudImage(root.appendingPathComponent(filename)), sessionFingerprint(normalized) == base[index] { raw = normalized }
    data = raw
    guard sessionFingerprint(data) == base[index] else { throw CloudFailure(L("U cloudové relace lze jen přidávat nové snímky. Původní snímky nelze upravit, odebrat ani přeřadit.")) }
   } else { data = try cloudImage(root.appendingPathComponent(filename)) }
   bytes += data.count
   guard bytes <= 100000000 else { throw CloudFailure(L("Relace překračuje limit 100 MB pro jeden cloudový přenos.")) }
   try data.write(to: staging.appendingPathComponent("\(index + 1).png"), options: .atomic)
   images.append(.init(index:index + 1,bytes:data.count,sha256:sessionFingerprint(data)))
  }
  if let folder=draft.topic?.cloudFolderID {
   guard draft.topic?.cloudOwnerID == owner,draft.topic?.cloudOrigin == c.endpoint,
         (folders ?? CloudFolders.shared.topics).contains(where:{$0.cloudFolderID == folder}) else {throw CloudFailure.invalid}
  }
  let manifest = CloudManifest(title:heading,comment:draft.comment,configuration:config,template:template,captions:captions,images:images,folder_id:draft.topic?.cloudFolderID,base_images:base?.count)
  let job = CloudJob(schemaVersion:1,endpoint:c.endpoint,ownerID:owner,sessionID:id,manifest:manifest)
  let final=queue.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)
  if fm.fileExists(atPath:final.path) {
   guard let existing=readJob(final),existing.ownerID==owner,existing.endpoint==c.endpoint,existing.manifest==manifest else{
    throw base == nil ? CloudFailure.invalid:CloudFailure(L("Předchozí doplnění této relace ještě čeká na nahrání. Zkus to znovu po jeho dokončení."))
   }
   return id
  }
  try JSONEncoder().encode(job).write(to:staging.appendingPathComponent("job.json"),options:.atomic)
  try fm.moveItem(at:staging,to:final); didChange?();return id
 }
 /// Rozpracované doplnění relace, které ještě není potvrzené serverem.
 func hasPending(_ id:UUID)->Bool{jobs().contains{$0.1.sessionID==id} || edits().contains{$0.1.sessionID==id}}
 // Úprava textu cloudové relace (PATCH) čeká ve frontě jako soubor, aby se neztratila bez sítě.
 struct CloudEdit:Codable {
  struct Fields:Codable,Equatable{var title:String;var comment:String;var captions:[String]}
  let endpoint:String;let ownerID:UUID;let sessionID:UUID
  var fields:Fields;var revision:String?;let base:Fields
 }
 private var editsDirectory:URL{queue.appendingPathComponent(".edits",isDirectory:true)}
 private func edits()->[(URL,CloudEdit)] {
  guard let c=connection,let owner=c.ownerID else{return []}
  return ((try? fm.contentsOfDirectory(at:editsDirectory,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles])) ?? []).sorted{$0.lastPathComponent<$1.lastPathComponent}.compactMap{url in
   guard let data=try? Data(contentsOf:url),data.count<=2000000,let edit=try? JSONDecoder().decode(CloudEdit.self,from:data),edit.endpoint==c.endpoint,edit.ownerID==owner else{return nil}
   return (url,edit)
  }
 }
 /// Uložení znovu otevřené cloudové relace bez nových snímků: jen text, obrázky se nesmí změnit.
 @discardableResult func enqueueEdit(_ draft:Draft,root:URL,sessionID:UUID,base shas:[String],original:CloudEdit.Fields,revision:String?)throws->Bool {
  try requireAccount();guard let c=connection,let owner=c.ownerID else{throw CloudFailure.invalid}
  guard draft.images.count==shas.count else{throw CloudFailure(L("U cloudové relace lze jen přidávat nové snímky. Původní snímky nelze upravit, odebrat ani přeřadit."))}
  for (index,filename) in draft.images.enumerated() {
   let url=root.appendingPathComponent(filename),raw=try boundedData(url,max:52428800)
   guard sessionFingerprint(raw)==shas[index] || (try? cloudImage(url)).map(sessionFingerprint)==shas[index] else{throw CloudFailure(L("U cloudové relace lze jen přidávat nové snímky. Původní snímky nelze upravit, odebrat ani přeřadit."))}
  }
  let title=draft.title?.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:"\n",with:" ") ?? "",fields=CloudEdit.Fields(title:title.isEmpty ? "Screenshot":title,comment:draft.comment,captions:draft.images.map{draft.imageNotes?[$0] ?? ""})
  func valid(_ s:String,_ points:Int,_ bytes:Int)->Bool{!s.contains("\0") && s.unicodeScalars.count<=points && s.utf8.count<=bytes}
  guard valid(fields.title,500,2000),valid(fields.comment,100000,100000),fields.captions.allSatisfy({valid($0,20000,20000)}),fields.captions.reduce(0,{$0+$1.utf8.count})<=300000 else{throw CloudFailure(L("Text relace překračuje cloudový limit. Lokální data zůstávají zachovaná."))}
  let file=editsDirectory.appendingPathComponent(sessionID.uuidString.lowercased()+".json")
  // Dřívější čekající úprava si drží původní základ pro sloučení.
  let pending=(try? Data(contentsOf:file)).flatMap{try? JSONDecoder().decode(CloudEdit.self,from:$0)}
  let base=pending?.base ?? original
  guard fields != base else{try? fm.removeItem(at:file);return false}
  try fm.createDirectory(at:editsDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try JSONEncoder().encode(CloudEdit(endpoint:c.endpoint,ownerID:owner,sessionID:sessionID,fields:fields,revision:pending?.revision ?? revision,base:base)).write(to:file,options:.atomic)
  didChange?();return true
 }
 /// Úpravy textu se pošlou PATCHem; při změně jinde se sloučí, nebo zůstanou místní s _cloud.md.
 @MainActor private func sendEdits(endpoint:CloudEndpoint,token:String)async throws {
  for (file,original) in edits() {
   // Commit doplnění by souběžný PATCH přepsal; úprava počká, až se doplnění nahraje.
   if jobs().contains(where:{$0.1.sessionID==original.sessionID}){continue}
   var edit=original,attempts=0
   let path="/api/v1/sessions/"+edit.sessionID.uuidString.lowercased()
   while attempts<3 {
    attempts+=1
    var body:[String:Any]=["title":edit.fields.title,"comment":edit.fields.comment,"captions":edit.fields.captions];body["revision"]=edit.revision ?? NSNull()
    do{_ = try await CloudTransport.shared.request(endpoint,path,method:"PATCH",token:token,body:JSONSerialization.data(withJSONObject:body));try? fm.removeItem(at:file);break}
    catch let failure as CloudFailure where failure.status==409 && failure.code=="session_changed" {
     let remote=try JSONDecoder().decode(Envelope<EditedSession>.self,from:await CloudTransport.shared.request(endpoint,path,token:token)).data
     let theirs=CloudEdit.Fields(title:remote.title,comment:remote.comment,captions:remote.captions)
     guard let merged=Self.merge(edit.fields,base:edit.base,remote:theirs) else {
      // Konflikt: místní verze zůstane v souboru, cloudová se stáhne vedle jako _cloud.md.
      parkEdit(file,edit);onEditConflict?(edit.sessionID,edit.fields)
      lastError=LF("Relace „%@“ byla mezitím změněna jinde. Tvoje úprava zůstala v místním souboru, cloudová verze je vedle jako _cloud.md.",edit.fields.title);break
     }
     edit.fields=merged;edit.revision=remote.revision?.value
     try JSONEncoder().encode(edit).write(to:file,options:.atomic)
    }
    catch let failure as CloudFailure where failure.status==409 && ["session_trashed","folder_trashed"].contains(failure.code ?? "") {
     parkEdit(file,edit);lastError=L("Relace je na webu v koši. Úprava zůstala odložená ve frontě.");break
    }
    catch let failure as CloudFailure where failure.status==404 || failure.status==405 {
     parkEdit(file,edit);lastError=L("Úpravu relace se nepodařilo nahrát: server ji nepodporuje nebo relace neexistuje. Úprava zůstala odložená ve frontě.");break
    }
   }
  }
 }
 /// Sloučení po pole: co změnil jen jeden, vyhraje; stejné pole změněné oběma je konflikt.
 static func merge(_ local:CloudEdit.Fields,base:CloudEdit.Fields,remote:CloudEdit.Fields)->CloudEdit.Fields? {
  func pick(_ mine:String,_ old:String,_ theirs:String)->String?{mine==old ? theirs:(theirs==old || theirs==mine ? mine:nil)}
  guard let title=pick(local.title,base.title,remote.title),let comment=pick(local.comment,base.comment,remote.comment) else{return nil}
  var captions=remote.captions
  for i in local.captions.indices where i<captions.count{guard let value=pick(local.captions[i],i<base.captions.count ? base.captions[i]:"",captions[i]) else{return nil};captions[i]=value}
  return CloudEdit.Fields(title:title,comment:comment,captions:captions)
 }
 private func parkEdit(_ file:URL,_ edit:CloudEdit) {
  let parked=queue.appendingPathComponent(".conflicts",isDirectory:true)
  try? fm.createDirectory(at:parked,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try? fm.moveItem(at:file,to:parked.appendingPathComponent("edit-"+edit.sessionID.uuidString.lowercased()+"-"+String(Int(now().timeIntervalSince1970))+".json"))
 }
 var onEditConflict:((UUID,CloudEdit.Fields)->Void)?
 func pendingExtension(_ id:UUID)->Bool{jobs().contains{$0.1.sessionID==id && $0.1.manifest.base_images != nil}}
 @MainActor func sync() async {
  guard !syncing, !connecting, now() >= retryAt, let c = connection, let owner = c.ownerID, let endpoint = CloudEndpoint(c.endpoint) else { return }
  syncing = true; lastError = nil; didChange?(); defer { syncing = false; didChange?() }
  do {
   let me = try await CloudTransport.shared.request(endpoint,"/api/v1/me",token:c.token)
   guard try JSONDecoder().decode(Envelope<CloudOwner>.self,from:me).data.id == owner else { throw CloudFailure.invalid }
   var rebased:[UUID:Int]=[:]
   while let (directory, original) = jobs().first {
    // Starší úloha bez složky by server odmítl, proto se odloží.
    if original.manifest.folder_id == nil && original.manifest.base_images == nil {
     try park(directory,original);lastError = L("Relace bez cloudové složky už nejde nahrát. Zůstala odložená ve frontě.");continue
    }
    do { try await upload(directory,original,endpoint:endpoint,connection:c,owner:owner) }
    catch let failure as CloudFailure where failure.status == 409 && failure.code == "session_changed" && original.manifest.base_images != nil && rebased[original.sessionID, default:0] < 3 {
     // Jiný Mac relaci mezitím doplnil, nové snímky se přesunou za jeho.
     rebased[original.sessionID, default:0] += 1
     try await rebase(directory,original,endpoint:endpoint,token:c.token)
    }
    catch let failure as CloudFailure where failure.status == 400 && failure.code == "folder_required" {
     try park(directory,original);lastError = L("Relace bez cloudové složky už nejde nahrát. Zůstala odložená ve frontě.")
    }
    catch let failure as CloudFailure where failure.status == 409 && failure.code == "folder_trashed" {
     try park(directory,original)
     lastError = L("Cloudová složka je v Koši na webu. Obnov ji na webu a snímky ulož znovu; nové snímky zůstaly odložené ve frontě.")
    }
    catch let failure as CloudFailure where failure.status == 409 && failure.code == "session_trashed" {
     // Relace je na webu v koši; úloha se odloží jako ostatní konflikty.
     try park(directory,original)
     lastError = L("Relace je na webu v koši. Obnov ji na webu a snímky přidej znovu; nové snímky zůstaly odložené ve frontě.")
    }
    catch let failure as CloudFailure where (failure.status == 409 && failure.code == "job_conflict") || (failure.status == 404 && original.manifest.base_images != nil) {
     // Neodeslatelná úloha se odloží stranou, aby neblokovala frontu.
     try park(directory,original)
     lastError = original.manifest.base_images == nil ? L("Jedna relace už v cloudu existuje v jiné podobě. Místní kopie zůstala odložená ve frontě.") : L("Relaci nelze v cloudu doplnit. Nové snímky zůstaly odložené ve frontě.")
    }
   }
   try await sendEdits(endpoint:endpoint,token:c.token)
   if let parked = lastError { throw CloudFailure(parked) }
  } catch {
   lastError = (error as? CloudFailure)?.message ?? L("Přenos se nezdařil. Lokální fronta zůstává zachovaná pro další pokus.")
   if let failure = error as? CloudFailure, [402, 413].contains(failure.status) { onQuotaFailure?(failure.message) }
   let delay = max(5, (error as? CloudFailure)?.retryAfter ?? 15)
   retryAt = now().addingTimeInterval(delay + Double.random(in:0...2))
  }
 }
 @MainActor private func upload(_ directory:URL,_ original:CloudJob,endpoint:CloudEndpoint,connection c:CloudConnection,owner:UUID) async throws {
  var job = original; let path = "/api/v1/uploads/" + job.sessionID.uuidString.lowercased()
  let created = try await CloudTransport.shared.request(endpoint,path,method:"PUT",token:c.token,body:JSONEncoder().encode(job.manifest))
  var state = try JSONDecoder().decode(Envelope<UploadStatus>.self,from:created).data
  func validate(_ state: UploadStatus) throws {
   guard state.session_id == job.sessionID, state.manifest_digest.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil,
         job.manifestDigest == nil || job.manifestDigest == state.manifest_digest,
         Set(state.confirmed_indices).count == state.confirmed_indices.count,
         state.confirmed_indices.allSatisfy({$0 >= 1 && $0 <= job.manifest.images.count}), ["uploading","committed"].contains(state.state) else { throw CloudFailure.invalid }
  }
  try validate(state)
  if job.manifestDigest == nil {
   job.manifestDigest = state.manifest_digest
   try JSONEncoder().encode(job).write(to:directory.appendingPathComponent("job.json"),options:.atomic)
  }
  if state.state != "committed" {
   for image in job.manifest.images where !state.confirmed_indices.contains(image.index) {
    let file = directory.appendingPathComponent("\(image.index).png"), data = try Data(contentsOf:file,options:.mappedIfSafe)
    guard data.count == image.bytes, sessionFingerprint(data) == image.sha256 else { throw CloudFailure.invalid }
    _ = try await CloudTransport.shared.request(endpoint,path + "/images/\(image.index)",method:"PUT",token:c.token,file:file)
   }
   let committed = try await CloudTransport.shared.request(endpoint,path + "/commit",method:"POST",token:c.token)
   state = try JSONDecoder().decode(Envelope<UploadStatus>.self,from:committed).data; try validate(state)
  }
  guard state.state == "committed", job.manifestDigest == state.manifest_digest,
        Set(state.confirmed_indices) == Set(job.manifest.images.map(\.index)) else { throw CloudFailure.invalid }
  // Doplněná relace přepíše účtenku novým digestem; ID relace zůstává.
  let receipt=committedFile(job.sessionID,c)
  try fm.createDirectory(at:receipt.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try JSONEncoder().encode(CommittedUpload(owner:owner,origin:c.endpoint,id:job.sessionID,folder:job.manifest.folder_id,digest:state.manifest_digest)).write(to:receipt,options:.atomic)
  try fm.removeItem(at:directory)
 }
 private func park(_ directory:URL,_ job:CloudJob)throws {
  let parked=queue.appendingPathComponent(".conflicts",isDirectory:true)
  try fm.createDirectory(at:parked,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  try fm.moveItem(at:directory,to:parked.appendingPathComponent(job.sessionID.uuidString.lowercased()+"-"+String(Int(now().timeIntervalSince1970))))
 }
 @MainActor private func rebase(_ directory:URL,_ job:CloudJob,endpoint:CloudEndpoint,token:String) async throws {
  guard let oldBase=job.manifest.base_images else { throw CloudFailure.invalid }
  let path="/api/v1/sessions/"+job.sessionID.uuidString.lowercased()
  let remote=try JSONDecoder().decode(Envelope<RemoteSession>.self,from:await CloudTransport.shared.request(endpoint,path,token:token)).data
  guard remote.id==job.sessionID,remote.captions.count==remote.images.count,(1...30).contains(remote.images.count),
        remote.images.enumerated().allSatisfy({$0.element.index==$0.offset+1 && $0.element.path==path+"/images/\($0.offset+1)"}) else { throw CloudFailure.invalid }
  let added=Array(job.manifest.images[oldBase...]),addedCaptions=Array(job.manifest.captions[oldBase...])
  guard remote.images.count+added.count<=30 else { throw CloudFailure(L("Relace by po doplnění překročila cloudový limit 30 snímků.")) }
  let staging=queue.appendingPathComponent(".rebase-"+job.sessionID.uuidString.lowercased(),isDirectory:true)
  try? fm.removeItem(at:staging);try fm.createDirectory(at:staging,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:staging)}
  var images:[CloudManifest.Image]=[]
  for image in remote.images {
   let data=try await CloudTransport.shared.request(endpoint,image.path,token:token,limit:52428800)
   guard connection?.token==token,data.starts(with:[137,80,78,71,13,10,26,10]) else { throw CloudFailure.invalid }
   try data.write(to:staging.appendingPathComponent("\(image.index).png"),options:.atomic)
   images.append(.init(index:image.index,bytes:data.count,sha256:sessionFingerprint(data)))
  }
  for image in added {
   let index=images.count+1
   try fm.copyItem(at:directory.appendingPathComponent("\(image.index).png"),to:staging.appendingPathComponent("\(index).png"))
   images.append(.init(index:index,bytes:image.bytes,sha256:image.sha256))
  }
  // Popisky původních snímků zůstávají z tohoto Macu, cizí nové snímky přebírají serverové.
  let captions=remote.captions.indices.map{$0<oldBase ? job.manifest.captions[$0]:remote.captions[$0]}+addedCaptions
  let manifest=CloudManifest(title:job.manifest.title,comment:job.manifest.comment,configuration:job.manifest.configuration,template:job.manifest.template,captions:captions,images:images,folder_id:job.manifest.folder_id,base_images:remote.images.count)
  guard manifest.valid else { throw CloudFailure(L("Relace by po doplnění překročila cloudový limit 30 snímků.")) }
  try JSONEncoder().encode(CloudJob(schemaVersion:1,endpoint:job.endpoint,ownerID:job.ownerID,sessionID:job.sessionID,manifest:manifest)).write(to:staging.appendingPathComponent("job.json"),options:.atomic)
  _ = try fm.replaceItemAt(directory,withItemAt:staging)
 }
}

private struct CloudShareLink: Decodable { let url: String }
extension CloudLibrary {
 private var shareAccount: String? { connection.flatMap { c in c.ownerID.map { c.endpoint + "|" + $0.uuidString } } }
 var shareRetryAt: Date { shareRetry.flatMap { $0.account == shareAccount ? $0.until : nil } ?? .distantPast }
 /// ID relace pro Kopírovat odkaz: cloudová složka tohoto účtu, server relaci má a index ji nevede v koši.
 func shareableSessionID(_ draft: Draft, index: SessionIndex, serverImages: (PreviousSessionTarget, Topic) -> (UUID, [String])?) -> UUID? {
  guard let previous = draft.previous, let topic = draft.topic, let folder = topic.cloudFolderID, let c = connection, let owner = c.ownerID,
        topic.cloudOwnerID == owner, topic.cloudOrigin == c.endpoint,
        let id = previous.session.flatMap({ UUID(uuidString: $0) }) ?? cloudSessionID(previous.original) else { return nil }
  let lower = id.uuidString.lowercased(), folderKey = folder.uuidString.lowercased()
  guard !index.all.contains(where: { $0.id == lower && $0.folder == folderKey && ($0.trashed == true || $0.askDelete == true || $0.missingSince != nil) }) else { return nil }
  if let (server, _) = serverImages(previous, topic), server == id { return id }
  return isCommitted(id, folder: folder) ? id : nil
 }
 /// Veřejná URL sdílené relace; server vrací pro aktivní odkaz pořád stejnou.
 @MainActor func shareLink(_ id: UUID) async throws -> URL {
  try requireAccount(); guard let c = connection, let account = shareAccount, let endpoint = CloudEndpoint(c.endpoint), endpoint == self.endpoint else { throw CloudFailure.invalid }
  func limited(_ wait: TimeInterval) -> CloudFailure { CloudFailure(LF("Příliš mnoho požadavků na sdílení. Zkus to znovu za %ld s.", max(1, Int(ceil(wait)))), status: 429, retryAfter: wait, code: "rate_limited") }
  let wait = shareRetryAt.timeIntervalSince(now()); guard wait <= 0 else { throw limited(wait) }
  let path = "/api/v1/sessions/" + id.uuidString.lowercased() + "/share", body = Data(#"{"audience":"public"}"#.utf8), data: Data
  do { data = try await CloudTransport.shared.request(endpoint, path, method: "POST", token: c.token, body: body, limit: 65536) }
  catch let failure as CloudFailure {
   // Vlastní hlášky sdílení; obecné hlášky přenosu mluví o nahrávání.
   let message: String
   switch (failure.status, failure.code) {
    case (401, _): throw failure
    case (403, _): message = L("Tuto relaci nemůžeš sdílet. Zkontroluj na webu, že má tento Mac oprávnění zapisovat do knihovny.")
    case (404, _): message = L("Relace v cloudu není dostupná nebo je sdílení vypnuté.")
    case (409, "session_trashed"): message = L("Relace je v koši. Obnov ji na webu a odkaz zkopíruj znovu.")
    case (413, _): message = L("Je dosažen limit sdílených odkazů. Odvolej nepotřebný odkaz na webu a zkus to znovu.")
    case (429, _): let delay = failure.retryAfter > 0 ? failure.retryAfter : 30; shareRetry = (account, now().addingTimeInterval(delay)); throw limited(delay)
    case (0, _), (500..., _): message = L("Sdílení je teď dočasně nedostupné. Zkus to znovu za chvíli.")
    default: message = LF("Odkaz se nepodařilo vytvořit (HTTP %ld).", failure.status)
   }
   throw CloudFailure(message, status: failure.status, code: failure.code)
  } catch { throw CloudFailure(L("Odkaz se nepodařilo získat. Zkontroluj připojení k internetu a zkus to znovu."), code: "network") }
  guard let link = try? JSONDecoder().decode(Envelope<CloudShareLink>.self, from: data).data,
        let url = Self.shareURL(link.url, endpoint: endpoint) else { throw CloudFailure.invalid }
  return url
 }
 /// Přijme jen `/s/sn_share_v1_<43 znaků>` na stejném originu jako API (schéma, host bez velikosti písmen, efektivní port).
 static func shareURL(_ raw: String, endpoint: CloudEndpoint) -> URL? {
  func origin(_ url: URL) -> String? {
   guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = p.scheme?.lowercased(), let host = p.host?.lowercased(), !host.isEmpty else { return nil }
   return scheme + "://" + host + ":" + String(p.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1))
  }
  guard let url = URL(string: raw), let p = URLComponents(url: url, resolvingAgainstBaseURL: false), p.user == nil, p.password == nil, p.query == nil, p.fragment == nil,
        let mine = origin(url), mine == origin(endpoint.url),
        p.percentEncodedPath.range(of: "^/s/sn_share_v1_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else { return nil }
  return url
 }
}
/// Zapíše odkaz do schránky jako prostý text.
func copyShareLink(_ url: URL, to pasteboard: NSPasteboard = .general) { pasteboard.clearContents(); pasteboard.setString(url.absoluteString, forType: .string) }
