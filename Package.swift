// swift-tools-version:5.9
import PackageDescription

// Appka se skládá do .app v build.sh; SwiftPM jen kompiluje binárky.
// Release zůstává bez optimalizací jako dřívější swiftc build.
let unoptimized: [SwiftSetting] = [.unsafeFlags(["-Onone"], .when(configuration: .release))]

let package = Package(
  name: "ScreenshotNote",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ScreenshotNote", targets: ["ScreenshotNote"]),
    .executable(name: "screenshot-note-bridge", targets: ["ScreenshotNoteBridge"]),
  ],
  targets: [
    .target(name: "BridgeWire", swiftSettings: unoptimized),
    .executableTarget(name: "ScreenshotNoteBridge", dependencies: ["BridgeWire"], swiftSettings: unoptimized),
    // Dočasně jeden modul včetně testů; oddělení je další krok.
    .executableTarget(
      name: "ScreenshotNote",
      dependencies: ["BridgeWire"],
      path: "Sources",
      exclude: ["BridgeWire", "ScreenshotNoteBridge"],
      swiftSettings: unoptimized
    ),
  ],
  swiftLanguageVersions: [.v5]
)
