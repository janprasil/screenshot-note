import Foundation

// Paměťové úložiště přihlášení pro náhledy designu a testy.
final class CloudMemoryVault: CloudCredentialStore {
 var value: CloudConnection?
 var fail = false
 func load() throws -> CloudConnection? { value }
 func save(_ value: CloudConnection?) throws { if fail { throw CloudFailure.keychain }; self.value = value }
}
