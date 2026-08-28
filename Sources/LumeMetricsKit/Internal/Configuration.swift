import Foundation

/// Resolved SDK configuration. Contains no personal data.
struct Configuration: Sendable, Equatable {

    /// `Info.plist` key holding the Lume write key.
    static let writeKeyInfoKey = "LumeMetricsWriteKey"
    /// `Info.plist` key holding an alternative ingest endpoint.
    static let endpointInfoKey = "LumeMetricsEndpoint"
    /// `Info.plist` key enabling non-sensitive diagnostic logging.
    static let debugLoggingInfoKey = "LumeMetricsDebugLogging"

    static let defaultEndpoint = URL(string: "https://lumeservice.onrender.com/v1/telemetry/events")!

    /// `nil` when no usable key is configured. The SDK is inert in that case.
    let writeKey: String?
    let endpoint: URL
    let debugLogging: Bool

    init(writeKey: String?, endpoint: URL, debugLogging: Bool = false) {
        self.writeKey = writeKey
        self.endpoint = endpoint
        self.debugLogging = debugLogging
    }

    /// Builds the configuration from an `Info.plist` dictionary.
    ///
    /// Missing or malformed values never trap: a blank write key becomes `nil`, and an
    /// unparsable endpoint falls back to ``defaultEndpoint``.
    init(infoDictionary: [String: Any]?, endpointOverride: URL? = nil) {
        let rawKey = (infoDictionary?[Self.writeKeyInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawEndpoint = (infoDictionary?[Self.endpointInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let configuredEndpoint = rawEndpoint
            .flatMap { $0.isEmpty ? nil : URL(string: $0) }
            .flatMap { url -> URL? in
                switch url.scheme?.lowercased() {
                case "http", "https": return url
                default: return nil
                }
            }

        self.init(
            writeKey: (rawKey?.isEmpty ?? true) ? nil : rawKey,
            endpoint: endpointOverride ?? configuredEndpoint ?? Self.defaultEndpoint,
            debugLogging: (infoDictionary?[Self.debugLoggingInfoKey] as? Bool) ?? false
        )
    }
}
