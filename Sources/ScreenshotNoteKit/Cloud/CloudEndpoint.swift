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
