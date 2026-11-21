import AppKit
import Security
import CryptoKit
import ImageIO

struct CloudConnection: Codable {
 let endpoint: String
 let token: String
 let id: UUID
 let comparisonCode: String
 let verificationURI: String
 var expiresAt: String
 var ownerID: UUID?
 var email: String?
 // Server zařízení odvolal nebo vrátil 401; je nutné nové párování.
 var revoked: Bool? = nil
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
