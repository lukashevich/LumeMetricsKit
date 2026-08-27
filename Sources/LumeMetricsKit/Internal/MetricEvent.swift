import Foundation

/// A single telemetry event.
///
/// The wire format is exactly this struct's JSON encoding. Every field is either anonymous
/// (`installationId`, `eventId`) or a property of the app build — never of the user or device.
struct MetricEvent: Codable, Sendable, Equatable {

    enum Name: String, Codable, Sendable {
        case firstOpen
        case appUpdated
    }

    /// Stable per-event identifier; unchanged across retries so the server can deduplicate.
    let eventId: String
    let event: Name
    let installationId: String
    let bundleId: String
    let appVersion: String
    let build: String
    let platform: Platform
    /// ISO-8601 in UTC, e.g. `2026-08-28T09:41:07Z`.
    let occurredAt: String

    init(
        name: Name,
        eventId: UUID,
        installationId: String,
        environment: AppEnvironment,
        occurredAt: Date
    ) {
        self.eventId = eventId.uuidString
        self.event = name
        self.installationId = installationId
        self.bundleId = environment.bundleId
        self.appVersion = environment.appVersion
        self.build = environment.build
        self.platform = environment.platform
        self.occurredAt = ISO8601.string(from: occurredAt)
    }
}

/// An event waiting to be delivered, plus its delivery bookkeeping.
struct QueuedEvent: Codable, Sendable, Equatable {
    let event: MetricEvent
    var attempts: Int

    init(event: MetricEvent, attempts: Int = 0) {
        self.event = event
        self.attempts = attempts
    }
}

enum ISO8601 {
    /// ISO-8601 in UTC with second precision.
    static func string(from date: Date) -> String {
        // Formatters are cheap relative to the two events an app ever sends, and creating one
        // per call keeps this free of shared mutable state.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
