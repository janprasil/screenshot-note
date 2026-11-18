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
 init(_ message: String, status: Int = 0, retryAfter: TimeInterval = 0) { self.message = message; self.status = status; self.retryAfter = retryAfter }
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
              body: Data? = nil, file: URL? = nil) async throws -> Data {
  guard path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#") else { throw CloudFailure.invalid }
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
  for try await byte in stream { if data.count >= 524288 { throw CloudFailure.invalid }; data.append(byte) }
  guard (200..<300).contains(http.statusCode) else {
   let retry = min(3600, max(0, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0))
   let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { $0["error"] as? [String: Any] }?["code"] as? String
   let message: String
   switch http.statusCode {
    case 401, 403: message = L("Zařízení nemá přístup. Zkontroluj připojení na webu nebo jej spáruj znovu.")
    case 402: message = L("Pro nahrávání aktivuj cloudový trial nebo tarif na webu.")
    case 413: message = L("Relace překračuje limit nahrávání nebo kapacitu cloudového tarifu.")
    case 415: message = L("Server nepřijal obrázek. Lokální relace zůstává ve frontě.")
    case 429: message = L("Příliš mnoho požadavků. Další pokus počká na povolený interval.")
    case 503: message = L("Cloudová služba není dostupná nebo ještě není aktivovaná. Lokální poznámky fungují dál.")
    case 409, 410: message = L("Přenos zatím nelze dokončit. Zkus jej později znovu; lokální data zůstávají zachovaná.")
    default: message = LF("Cloud vrátil chybu HTTP %ld.", http.statusCode)
   }
   throw CloudFailure(message, status: http.statusCode, retryAfter: max(retry, code == "upload_incomplete" ? 90 : 0))
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
struct CloudManifest: Codable {
 struct Image: Codable { let index: Int; let bytes: Int; let sha256: String }
 let title: String; let comment: String; let configuration: String; let template: String; let captions: [String]; let images: [Image]
}
extension CloudManifest {
 var valid: Bool {
  func text(_ s: String, _ points: Int, _ bytes: Int) -> Bool { !s.contains("\0") && s.unicodeScalars.count <= points && s.utf8.count <= bytes }
  return (1...30).contains(images.count) && captions.count == images.count && text(title,500,2000) && text(comment,100000,100000)
   && text(configuration,200,800) && text(template,100000,100000) && captions.allSatisfy { text($0,20000,20000) }
   && captions.reduce(0,{$0 + $1.utf8.count}) <= 300000 && images.enumerated().allSatisfy { index,image in
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

func cloudImage(_ file: URL) throws -> Data {
 guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
       CGImageSourceGetCount(source) == 1,
       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
       width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64000000,
       let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = CGColorSpace(name: CGColorSpace.sRGB),
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
 guard offset == data.count, clean.count <= 52428800 else { throw CloudFailure.invalid }; return clean
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
 private var nextPoll = Date.distantPast
 var lastError: String?
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
 var pendingCount: Int { jobs().count }
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
 func enqueue(_ draft: Draft, root: URL) throws {
  try requireAccount(); guard let c = connection, let owner = c.ownerID else { throw CloudFailure.invalid }
  guard (1...30).contains(draft.images.count) else { throw CloudFailure(L("Cloudová relace může obsahovat 1 až 30 snímků. Lokální ukládání tento limit nemá.")) }
  let id = UUID(), title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
  let captions = draft.images.map { draft.imageNotes?[$0] ?? "" }
  func valid(_ s: String, _ points: Int, _ bytes: Int) -> Bool { !s.contains("\0") && s.unicodeScalars.count <= points && s.utf8.count <= bytes }
  let heading = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Screenshot", config = draft.topic?.name ?? "", template = draft.topic?.markdownTemplate ?? defaultMarkdownTemplate
  guard valid(heading,500,2000), valid(draft.comment,100000,100000), valid(config,200,800), valid(template,100000,100000),
        captions.allSatisfy({valid($0,20000,20000)}), captions.reduce(0,{$0 + $1.utf8.count}) <= 300000 else { throw CloudFailure(L("Text relace překračuje cloudový limit. Lokální data zůstávají zachovaná.")) }
  let staging = queue.appendingPathComponent("." + id.uuidString, isDirectory: true)
  try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); defer { try? fm.removeItem(at: staging) }
  var images: [CloudManifest.Image] = []; var bytes = 0
  for (index, filename) in draft.images.enumerated() {
   guard URL(fileURLWithPath: filename).lastPathComponent == filename, !filename.contains("/") else { throw CloudFailure.invalid }
   let data = try cloudImage(root.appendingPathComponent(filename)); bytes += data.count
   guard bytes <= 100000000 else { throw CloudFailure(L("Relace překračuje limit 100 MB pro jeden cloudový přenos.")) }
   try data.write(to: staging.appendingPathComponent("\(index + 1).png"), options: .atomic)
   images.append(.init(index:index + 1,bytes:data.count,sha256:SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()))
  }
  let manifest = CloudManifest(title:heading,comment:draft.comment,configuration:config,template:template,captions:captions,images:images)
  let job = CloudJob(schemaVersion:1,endpoint:c.endpoint,ownerID:owner,sessionID:id,manifest:manifest)
  try JSONEncoder().encode(job).write(to:staging.appendingPathComponent("job.json"),options:.atomic)
  try fm.moveItem(at:staging,to:queue.appendingPathComponent(id.uuidString.lowercased(),isDirectory:true)); didChange?()
 }
 @MainActor func sync() async {
  guard !syncing, !connecting, now() >= retryAt, let c = connection, let owner = c.ownerID, let endpoint = CloudEndpoint(c.endpoint) else { return }
  syncing = true; lastError = nil; didChange?(); defer { syncing = false; didChange?() }
  do {
   let me = try await CloudTransport.shared.request(endpoint,"/api/v1/me",token:c.token)
   guard try JSONDecoder().decode(Envelope<CloudOwner>.self,from:me).data.id == owner else { throw CloudFailure.invalid }
   while let (directory, original) = jobs().first {
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
      guard data.count == image.bytes, SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == image.sha256 else { throw CloudFailure.invalid }
      _ = try await CloudTransport.shared.request(endpoint,path + "/images/\(image.index)",method:"PUT",token:c.token,file:file)
     }
     let committed = try await CloudTransport.shared.request(endpoint,path + "/commit",method:"POST",token:c.token)
     state = try JSONDecoder().decode(Envelope<UploadStatus>.self,from:committed).data; try validate(state)
    }
    guard state.state == "committed", job.manifestDigest == state.manifest_digest,
          Set(state.confirmed_indices) == Set(job.manifest.images.map(\.index)) else { throw CloudFailure.invalid }
    try fm.removeItem(at:directory)
   }
  } catch {
   lastError = (error as? CloudFailure)?.message ?? L("Přenos se nezdařil. Lokální fronta zůstává zachovaná pro další pokus.")
   let delay = max(5, (error as? CloudFailure)?.retryAfter ?? 15)
   retryAt = now().addingTimeInterval(delay + Double.random(in:0...2))
  }
 }
}
