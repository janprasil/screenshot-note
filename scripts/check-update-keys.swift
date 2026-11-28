// Ověří, že SPARKLE_ED_PUBLIC_KEY patří k SPARKLE_ED_PRIVATE_KEY.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("::error::\(message)\n".utf8))
    exit(1)
}
func key(_ name: String) -> Data {
    let value = (ProcessInfo.processInfo.environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, let data = Data(base64Encoded: value) else { fail("\(name) is missing or not base64") }
    return data
}
let secret = key("SPARKLE_ED_PRIVATE_KEY"), published = key("SPARKLE_ED_PUBLIC_KEY")
// Sparkle exportuje 32bajtový seed, starší klíče mají 96 bajtů s veřejným klíčem na konci.
let derived: Data
switch secret.count {
case 32:
    guard let pair = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else { fail("Invalid private key") }
    derived = pair.publicKey.rawRepresentation
case 96:
    derived = Data(secret.suffix(32))
default:
    fail("Unexpected private key length")
}
guard derived == published else { fail("SPARKLE_ED_PUBLIC_KEY does not match SPARKLE_ED_PRIVATE_KEY") }
print("Update keys match")
