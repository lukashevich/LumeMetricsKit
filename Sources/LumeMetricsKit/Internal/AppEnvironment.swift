import Foundation

/// Non-personal facts about the running app build.
struct AppEnvironment: Sendable, Equatable {
    let bundleId: String
    let appVersion: String
    let build: String
    let platform: Platform

    /// Stand-in for a version key the app does not declare. Carries no device information.
    static let unknownValue = "unknown"

    /// Reads the environment from a bundle.
    ///
    /// Returns `nil` when the bundle has no identifier: without it an event cannot be attributed
    /// to an app, so the SDK prefers sending nothing.
    static func current(bundle: Bundle = .main) -> AppEnvironment? {
        AppEnvironment(
            bundleIdentifier: bundle.bundleIdentifier,
            infoDictionary: bundle.infoDictionary
        )
    }

    init?(bundleIdentifier: String?, infoDictionary: [String: Any]?) {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        self.bundleId = bundleIdentifier
        self.appVersion = Self.string(infoDictionary, "CFBundleShortVersionString")
        self.build = Self.string(infoDictionary, "CFBundleVersion")
        self.platform = .current
    }

    init(bundleId: String, appVersion: String, build: String, platform: Platform) {
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.build = build
        self.platform = platform
    }

    private static func string(_ infoDictionary: [String: Any]?, _ key: String) -> String {
        let value = (infoDictionary?[key] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return unknownValue }
        return value
    }
}

/// Platform the event was produced on.
enum Platform: String, Codable, Sendable {
    case ios
    case macos

    static var current: Platform {
        #if os(macOS)
        return .macos
        #else
        // Covers iOS, iPadOS and Mac Catalyst, all of which report `os(iOS)`.
        return .ios
        #endif
    }
}
