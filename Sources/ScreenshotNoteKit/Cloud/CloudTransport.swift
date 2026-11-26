import AppKit
import Security
import CryptoKit
import ImageIO

struct CloudFailure: LocalizedError {
 let message: String
 let status: Int
 let retryAfter: TimeInterval
 var code: String? = nil
 // Strojový důvod chyby, např. "retention" u smazání po konci předplatného.
 var reason: String? = nil
 // Objekt `error` z odpovědi (např. aktuální stav u konfliktu).
 var details: Data? = nil
 init(_ message: String, status: Int = 0, retryAfter: TimeInterval = 0, code: String? = nil, reason: String? = nil, details: Data? = nil) { self.message = message; self.status = status; self.retryAfter = retryAfter; self.code = code; self.reason = reason; self.details = details }
 var errorDescription: String? { message }
 // Kvóta účtu (tarif nebo plné úložiště); 413 resource_limit je jen příliš velký požadavek.
 var isQuota: Bool { status == 402 || (status == 413 && code == "billing_storage_limit") }
 static var keychain: Self { Self(L("Přístup do Keychain se nezdařil. Připojení nebylo změněno.")) }
 static var invalid: Self { Self(L("Server vrátil neplatnou odpověď. Lokální data zůstávají zachovaná."),code:"invalid_response") }
 /// Viditelný obsah, ale role na akci nestačí; neopakovat.
 var isRoleForbidden: Bool { status == 403 && code == "role_forbidden" }
}

final class CloudTransport: NSObject, URLSessionTaskDelegate {
 static let shared = CloudTransport()
 // Seznam a detail relací: 30 řádků s komentáři do 100 KB nebo popisky do 300 KB, s rezervou.
 static let jsonLimit = 16777216
 static let imageLimit = 52428800
 private static func configuration(resource: TimeInterval) -> URLSessionConfiguration {
  let config = URLSessionConfiguration.ephemeral
  config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
  config.requestCachePolicy = .reloadIgnoringLocalCacheData; config.timeoutIntervalForResource = resource
  return config
 }
 lazy var session: URLSession = URLSession(configuration: Self.configuration(resource: 75), delegate: self, delegateQueue: nil)
 // Obrázky mají vlastní session s dlouhým celkovým limitem; nečinnost hlídá timeout požadavku.
 lazy var transferSession: URLSession = URLSession(configuration: Self.configuration(resource: 14400), delegate: self, delegateQueue: nil)
 func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                 newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
 func request(_ endpoint: CloudEndpoint, _ path: String, method: String = "GET", token: String? = nil,
              body: Data? = nil, file: URL? = nil, limit:Int=524288, headers:[String:String]=[:]) async throws -> Data {
  guard path.hasPrefix("/api/v1/"), !path.contains("#"), !path.contains(".."), (1...Self.imageLimit).contains(limit) else { throw CloudFailure.invalid }
  let bulk = file != nil || limit >= Self.imageLimit
  var req = URLRequest(url: endpoint.path(path)); req.httpMethod = method; req.timeoutInterval = bulk ? 70 : limit > 524288 ? 30 : 15
  if let token { guard CloudConnection.validToken(token) else { throw CloudFailure.invalid }; req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
  if let file {
   req.httpBodyStream = InputStream(url: file)
   let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
   req.setValue(String(bytes), forHTTPHeaderField: "Content-Length"); req.setValue("image/png", forHTTPHeaderField: "Content-Type")
  } else if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
  // Přílohy kontextu přepíšou typ obsahu a přidají délku a hash.
  for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
  let (stream, response) = try await (bulk ? transferSession : session).bytes(for: req)
  guard let http = response as? HTTPURLResponse else { throw CloudFailure.invalid }
  var data = Data()
  for try await byte in stream { if data.count >= limit { throw CloudFailure.invalid }; data.append(byte) }
  guard (200..<300).contains(http.statusCode) else {
   let retry = min(3600, max(0, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0))
   let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { $0["error"] as? [String: Any] }
   let code = error?["code"] as? String
   let message: String
   switch http.statusCode {
    case 403 where code == "role_forbidden": message = L("Na tuto akci nemáš v týmu oprávnění.")
    case 401, 403: message = L("Zařízení nemá přístup. Zkontroluj připojení na webu nebo jej spáruj znovu.")
    case 402: message = L("Nahrávání do cloudu vyžaduje aktivní tarif nebo trial. Poznámka zůstává uložená lokálně.")
    case 413 where code == "billing_storage_limit": message = L("V cloudu už pro tuto relaci nezbývá místo. Poznámka zůstává uložená lokálně; uvolni místo nebo zvyš tarif na webu.")
    case 413: message = L("Požadavek je pro cloud příliš velký (překračuje limit serveru). Opakování nepomůže; poznámka zůstává uložená lokálně.")
    case 415: message = L("Server nepřijal obrázek. Lokální relace zůstává ve frontě.")
    case 429: message = L("Příliš mnoho požadavků. Další pokus počká na povolený interval.")
    case 503: message = L("Cloud je teď nedostupný. Poznámky počkají na Macu a nahrají se později.")
    case 409, 410: message = L("Přenos zatím nelze dokončit. Zkus jej později znovu; lokální data zůstávají zachovaná.")
    default: message = LF("Cloud vrátil chybu HTTP %ld.", http.statusCode)
   }
   throw CloudFailure(message, status: http.statusCode, retryAfter: max(retry, code == "upload_incomplete" ? 90 : 0), code: code, reason: error?["reason"] as? String, details: error.flatMap { try? JSONSerialization.data(withJSONObject: $0) })
  }
  return data
 }
}
