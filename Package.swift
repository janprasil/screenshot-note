// swift-tools-version:5.9
import PackageDescription

// Appka se skládá do .app v build.sh; SwiftPM jen kompiluje binárky.
// Release zůstává bez optimalizací a bez debug info jako dřívější swiftc build.
let unoptimized: [SwiftSetting] = [.unsafeFlags(["-Onone", "-gnone"], .when(configuration: .release))]
// Testovací host linkuje tytéž objekty knihovny jako appka; -enable-testing jen zviditelní interní symboly.
let testable: [SwiftSetting] = [.unsafeFlags(["-Onone", "-gnone", "-enable-testing"], .when(configuration: .release))]

let package = Package(
  name: "ScreenshotNote",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "ScreenshotNote", targets: ["ScreenshotNote"]),
    .executable(name: "screenshot-note-bridge", targets: ["ScreenshotNoteBridge"]),
    .executable(name: "ScreenshotNoteTestHost", targets: ["ScreenshotNoteTestHost"]),
  ],
  targets: [
    .target(name: "BridgeWire", swiftSettings: unoptimized),
    .executableTarget(name: "ScreenshotNoteBridge", dependencies: ["BridgeWire"], swiftSettings: unoptimized),
    .target(name: "ScreenshotNoteKit", dependencies: ["BridgeWire"], swiftSettings: testable),
    .executableTarget(name: "ScreenshotNote", dependencies: ["ScreenshotNoteKit"], swiftSettings: unoptimized),
    // Testy mimo produkční binárku; do .app se nebalí.
    .executableTarget(name: "ScreenshotNoteTestHost", dependencies: ["ScreenshotNoteKit", "BridgeWire"], swiftSettings: unoptimized),
  ],
  swiftLanguageVersions: [.v5]
)
