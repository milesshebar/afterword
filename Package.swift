// swift-tools-version:5.9
import PackageDescription
import Foundation

// The product's name: the Mac app's executable, and so its bundle's file name. Must equal
// `Product.executable` in Sources/ArchiveCore/Product.swift and APP_EXECUTABLE in scripts/product.env.
let productName = "Afterword"

// Builds on macOS (Command Line Tools only, no Xcode) and on Linux (the web app's container: Ubuntu noble, swift:6.3).
// Zero third-party dependencies. On Linux the system SQLite comes in through the CSQLite module map (libsqlite3-dev);
// on macOS the SDK's own SQLite3 module is used, as before.
var products: [Product] = [
    .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
    .executable(name: "archivectl", targets: ["archivectl"]),
]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "ArchiveCore",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(name: "archivectl", dependencies: ["ArchiveCore"]),
]
var testSettings: [SwiftSetting] = []
#if os(macOS)
// With only the Command Line Tools installed, Swift Testing's macro plugin lives outside the default plugin search path, so the
// test target adds it when that folder exists (Xcode's toolchain finds it on its own). The SwiftUI app is macOS-only.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if FileManager.default.fileExists(atPath: testingPlugins) {
    testSettings = [.unsafeFlags(["-plugin-path", testingPlugins])]
}
products.append(.executable(name: productName, targets: ["ArchiveApp"]))
targets.append(.executableTarget(name: "ArchiveApp", dependencies: ["ArchiveCore"]))
#endif
targets.append(.testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"], swiftSettings: testSettings))

let package = Package(
    name: productName,
    platforms: [.macOS("14.0")],
    products: products,
    targets: targets
)
