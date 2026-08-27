import Foundation
import os

/// Diagnostics that deliberately cannot leak secrets.
///
/// Only event names, queue sizes and HTTP status codes are ever logged — never the write key,
/// the installation id, or a request body. Off unless `LumeMetricsDebugLogging` is `true`.
struct Log: Sendable {

    private let logger: Logger?

    init(enabled: Bool) {
        logger = enabled
            ? Logger(subsystem: "app.lume.LumeMetricsKit", category: "telemetry")
            : nil
    }

    func debug(_ message: String) {
        logger?.debug("\(message, privacy: .public)")
    }
}
