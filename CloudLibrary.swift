import AppKit

struct CloudProject: Equatable {
 let url: URL
 let key: String

 init?(url rawURL: String, key: String) {
  guard var parts = URLComponents(string: rawURL), let host = parts.host,
        parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
        parts.path.isEmpty || parts.path == "/",
        parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
        Self.isPublicKey(key) else { return nil }
  parts.path = ""
  guard let url = parts.url else { return nil }
  self.url = url
  self.key = key
 }

 private static func isPublicKey(_ key: String) -> Bool {
  if key.hasPrefix("sb_publishable_") { return true }
  // The local Supabase CLI also provides a legacy anonymous JWT.
  let parts = key.split(separator: ".")
  guard parts.count == 3 else { return false }
  var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
  guard let data = Data(base64Encoded: payload),
        let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
  return claims["role"] as? String == "anon"
 }
}

private struct CloudAccount: Decodable {
 struct User: Decodable { let id: UUID; let email: String? }
 let accessToken: String
 let refreshToken: String
 let expiresAt: Double
 let user: User
}

private struct CloudSession: Codable {
 let id: String
 let ownerID: String
 let title: String
 let comment: String
 let configuration: String
 let template: String
 let captions: [String]

 enum CodingKeys: String, CodingKey {
  case id, title, comment, configuration, template, captions
  case ownerID = "owner_id"
 }

 func objectPath(index: Int) -> String { "\(ownerID)/\(id)/\(index + 1).png" }
}

private struct CloudJob: Codable {
 let project: String
 let session: CloudSession
}

private struct CloudHTTPError: LocalizedError {
 let status: Int
 var errorDescription: String? { LF("Cloud vrátil chybu HTTP %ld.", status) }
}

private final class CloudTransport: NSObject, URLSessionTaskDelegate {
 static let shared = CloudTransport()
 lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
 func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                 newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
  completionHandler(nil)
 }
}

final class CloudLibrary {
 static let shared = CloudLibrary()
 private let queue: URL
 private var project: CloudProject?
 private var account: CloudAccount?
 private(set) var syncing = false
 var lastError: String?
 var didChange: (() -> Void)?

 init(queue: URL = draftRoot.deletingLastPathComponent().appendingPathComponent("Cloud Outbox", isDirectory: true)) {
  self.queue = queue
 }

 var signedInEmail: String? { account.map { $0.user.email ?? $0.user.id.uuidString } }
 var pendingCount: Int {
  guard let project, let account else { return 0 }
  return jobs(project: project, account: account).count
 }

 func signIn(project: CloudProject, email: String, password: String) async throws {
  let newAccount = try await authenticate(project, grant: "password", fields: ["email": email, "password": password])
  self.project = project
  account = newAccount
  didChange?()
 }

 func signOut() {
  guard !syncing else { return }
  account = nil
  project = nil
  lastError = nil
  didChange?()
 }

 func requireAccount() throws {
  guard account != nil else {
   throw NSError(domain: "ScreenshotNote.Cloud", code: 1, userInfo: [NSLocalizedDescriptionKey:
    L("Nejprve se přihlas do Cloudové knihovny v nabídce aplikace.")])
  }
 }

 func enqueue(_ draft: Draft, root: URL) throws {
  try requireAccount()
  guard let account, let project else { return }
  let id = UUID().uuidString.lowercased()
  let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
  let session = CloudSession(id: id, ownerID: account.user.id.uuidString.lowercased(),
                             title: title.flatMap { $0.isEmpty ? nil : $0 } ?? "Screenshot",
                             comment: draft.comment, configuration: draft.topic?.name ?? "",
                             template: draft.topic?.markdownTemplate ?? defaultMarkdownTemplate,
                             captions: draft.images.map { draft.imageNotes?[$0] ?? "" })
  let staging = queue.appendingPathComponent(".\(id)", isDirectory: true)
  try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  defer { try? fm.removeItem(at: staging) }
  for (index, filename) in draft.images.enumerated() {
   try fm.copyItem(at: root.appendingPathComponent(filename), to: staging.appendingPathComponent("\(index + 1).png"))
  }
  let job = CloudJob(project: project.url.absoluteString, session: session)
  try JSONEncoder().encode(job).write(to: staging.appendingPathComponent("job.json"), options: .atomic)
  try fm.moveItem(at: staging, to: queue.appendingPathComponent(id, isDirectory: true))
  didChange?()
 }

 @MainActor func sync() async {
  guard !syncing, let project, let account else { return }
  syncing = true
  lastError = nil
  didChange?()
  defer { syncing = false; didChange?() }
  while let (directory, job) = jobs(project: project, account: account).first {
   do {
    for index in job.session.captions.indices {
     let file = directory.appendingPathComponent("\(index + 1).png")
     _ = try await authorized(project, path: "storage/v1/object/screenshot-note/" + job.session.objectPath(index: index),
                              file: file, headers: ["Content-Type": "image/png", "x-upsert": "true"])
    }
    _ = try await authorized(project, path: "rest/v1/screenshot_sessions?on_conflict=id",
                             body: JSONEncoder().encode(job.session),
                             headers: ["Content-Type": "application/json", "Prefer": "resolution=ignore-duplicates"])
    try fm.removeItem(at: directory)
   } catch {
    lastError = error.localizedDescription
    break
   }
  }
 }

 private func jobs(project: CloudProject, account: CloudAccount) -> [(URL, CloudJob)] {
  let entries = (try? fm.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
  return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { directory in
   guard let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")),
         let job = try? JSONDecoder().decode(CloudJob.self, from: data),
         job.project == project.url.absoluteString,
         job.session.ownerID == account.user.id.uuidString.lowercased() else { return nil }
   return (directory, job)
  }
 }

 private func authenticate(_ project: CloudProject, grant: String, fields: [String: String]) async throws -> CloudAccount {
  let data = try await request(project, path: "auth/v1/token?grant_type=" + grant,
                               body: JSONEncoder().encode(fields), headers: ["Content-Type": "application/json"])
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(CloudAccount.self, from: data)
 }

 @MainActor private func authorized(_ project: CloudProject, path: String, body: Data? = nil,
                                    file: URL? = nil, headers: [String: String]) async throws -> Data {
  guard let current = account else { try requireAccount(); return Data() }
  let token: String
  if current.expiresAt < Date().timeIntervalSince1970 + 60 {
   let refreshed = try await authenticate(project, grant: "refresh_token", fields: ["refresh_token": current.refreshToken])
   account = refreshed
   token = refreshed.accessToken
  } else {
   token = current.accessToken
  }
  return try await request(project, path: path, token: token, body: body, file: file, headers: headers)
 }

 private func request(_ project: CloudProject, path: String, token: String? = nil, body: Data? = nil,
                      file: URL? = nil, headers: [String: String]) async throws -> Data {
  var request = URLRequest(url: URL(string: project.url.absoluteString + "/" + path)!)
  request.httpMethod = "POST"
  request.timeoutInterval = 45
  request.setValue(project.key, forHTTPHeaderField: "apikey")
  if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
  for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
  let transport = CloudTransport.shared.session
  let (data, response): (Data, URLResponse)
  if let file { (data, response) = try await transport.upload(for: request, fromFile: file) }
  else { request.httpBody = body; (data, response) = try await transport.data(for: request) }
  let status = (response as? HTTPURLResponse)?.statusCode ?? 0
  guard (200..<300).contains(status) else { throw CloudHTTPError(status: status) }
  return data
 }
}

final class CloudSettings: NSObject, NSWindowDelegate {
 private var window: NSWindow?
 private let projectURL = CenteredTextField()
 private let key = CenteredTextField()
 private let email = CenteredTextField()
 private let password = NSSecureTextField()
 private let status = NSTextField(wrappingLabelWithString: "")
 private var signIn: AppButton!
 private var signOut: AppButton!
 private var retry: AppButton!
 private var signingIn = false
 private let library = CloudLibrary.shared

 func show() {
  if let window { refresh(); presentScreenshotPanel(window); return }
  let panel = ScreenshotPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
                              styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
  panel.isReleasedWhenClosed = false
  panel.delegate = self
  window = panel
  let view = installDesignRoot(panel, headerHeight: 92)
  view.addSubview(designLabel(L("Cloudová knihovna"), NSRect(x: 26, y: 382, width: 470, height: 32), size: 23, weight: .semibold))
  view.addSubview(designLabel(L("Použij stejný účet jako ve webové knihovně."), NSRect(x: 26, y: 352, width: 490, height: 24), size: 12, color: AppPalette.secondary))
  for (label, field, y) in [("Adresa projektu", projectURL as NSTextField, 280), ("Veřejný klíč projektu", key, 218),
                            ("E-mail", email, 156), ("Heslo", password, 94)] {
   view.addSubview(sectionLabel(L(label), NSRect(x: 26, y: y + 36, width: 508, height: 18)))
   inputShell(field, frame: NSRect(x: 26, y: y, width: 508, height: 34), in: view)
  }
  projectURL.stringValue = UserDefaults.standard.string(forKey: "cloudProjectURL") ?? ""
  key.stringValue = UserDefaults.standard.string(forKey: "cloudPublishableKey") ?? ""
  status.frame = NSRect(x: 26, y: 50, width: 508, height: 34)
  status.font = .systemFont(ofSize: 12); status.textColor = AppPalette.secondary; view.addSubview(status)
  signIn = styledButton(L("Přihlásit se"), role: .primary, frame: NSRect(x: 384, y: 16, width: 150, height: 32), target: self, action: #selector(connect))
  signOut = styledButton(L("Odhlásit se"), role: .quiet, frame: NSRect(x: 26, y: 16, width: 120, height: 32), target: self, action: #selector(disconnect))
  retry = styledButton(L("Zkusit nahrát znovu"), frame: NSRect(x: 334, y: 16, width: 200, height: 32), target: self, action: #selector(sync))
  for button in [signIn!, signOut!, retry!] { view.addSubview(button) }
  library.didChange = { [weak self] in self?.refresh() }
  refresh()
  presentScreenshotPanel(panel)
 }

 private func refresh() {
  let connected = library.signedInEmail
  for field in [projectURL as NSTextField, key, email, password] { field.isEnabled = connected == nil && !signingIn }
  signIn.isHidden = connected != nil
  signIn.isEnabled = !signingIn
  signOut.isHidden = connected == nil
  signOut.isEnabled = !library.syncing
  retry.isHidden = connected == nil
  retry.isEnabled = !library.syncing && library.pendingCount > 0
  if let connected {
   status.stringValue = library.lastError ?? (connected + " · " + LF("Čekající relace: %ld", library.pendingCount))
  } else { status.stringValue = signingIn ? L("Přihlašuji…") : "" }
 }

 @objc private func connect() {
  window?.makeFirstResponder(nil)
  let trim = CharacterSet.whitespacesAndNewlines
  guard let project = CloudProject(url: projectURL.stringValue.trimmingCharacters(in: trim), key: key.stringValue.trimmingCharacters(in: trim)) else {
   status.stringValue = L("Zadej HTTPS adresu projektu a jeho veřejný klíč.")
   return
  }
  let address = email.stringValue.trimmingCharacters(in: trim), secret = password.stringValue
  guard !address.isEmpty, !secret.isEmpty else { status.stringValue = L("Vyplň e-mail a heslo."); return }
  password.stringValue = ""
  signingIn = true; refresh()
  Task { @MainActor in
   do {
    try await library.signIn(project: project, email: address, password: secret)
    UserDefaults.standard.set(project.url.absoluteString, forKey: "cloudProjectURL")
    UserDefaults.standard.set(project.key, forKey: "cloudPublishableKey")
    signingIn = false; refresh()
    await library.sync()
   } catch {
    signingIn = false; refresh()
    status.stringValue = L("Přihlášení se nezdařilo.") + " " + error.localizedDescription
   }
  }
 }

 func windowWillClose(_ notification: Notification) { password.stringValue = "" }

 @objc private func disconnect() { library.signOut() }
 @objc private func sync() { Task { @MainActor in await library.sync() } }
}
