import Foundation

/// The product's name, in one place. Every user-facing name, file name and environment variable the Swift code uses is derived
/// from `name`. A rename (in a fork) also changes Package.swift `productName`, scripts/product.env, web/index.html and web/manifest.webmanifest.
public enum Product {
    /// What people read: window titles, version lines, log lines.
    public static let name = "Afterword"

    /// `name` without spaces or punctuation: the app executable and bundle (`<executable>.app`), release zips
    /// (`<executable>-<build>.zip`) and the Application Support folder. Must equal `productName` in Package.swift.
    public static var executable: String { name.filter { $0.isLetter || $0.isNumber } }

    /// Prefix of every environment variable: `<PREFIX>_ROOT`, `<PREFIX>_MEDIA_ROOT`, `<PREFIX>_APPLICATIONS_DIR`,
    /// `<PREFIX>_UPDATE_SERVER`.
    public static var environmentPrefix: String { executable.uppercased() }

    /// The identifier used when the running process has none (the command line tool, Linux, an unbundled debug build).
    /// scripts/bundle.sh stamps the app's real one (`BUNDLE_ID` in scripts/product.env).
    public static var defaultBundleIdentifier: String { "io.github." + executable.lowercased() }

    /// The running app's bundle identifier, else the default.
    public static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? defaultBundleIdentifier }

    /// The folder under `~/Library/Application Support` that holds the default archive.
    public static var supportFolder: String { executable }
}
