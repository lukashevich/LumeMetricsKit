import Foundation

/// Outcome of one delivery attempt.
enum DeliveryResult: Sendable, Equatable {
    /// Accepted by the server; drop the event.
    case delivered
    /// Temporary problem (offline, 429, 5xx); keep the event for the next `start()`.
    case retry
    /// Permanent rejection (4xx other than 429); drop the event, never retry.
    case reject
}

protocol EventTransport: Sendable {
    func send(_ event: MetricEvent, to endpoint: URL, writeKey: String) async -> DeliveryResult
}

/// `URLSession`-backed transport. One request per event, so per-event outcomes stay unambiguous.
final class URLSessionTransport: EventTransport {

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    func send(_ event: MetricEvent, to endpoint: URL, writeKey: String) async -> DeliveryResult {
        guard let body = try? JSONEncoder().encode(event) else { return .reject }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(writeKey)", forHTTPHeaderField: "Authorization")
        // Second dedup signal for servers that support it; identical across retries.
        request.setValue(event.eventId, forHTTPHeaderField: "Idempotency-Key")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retry }
            return DeliveryResult(statusCode: http.statusCode)
        } catch {
            return .retry
        }
    }
}

extension DeliveryResult {
    init(statusCode: Int) {
        switch statusCode {
        case 200...299:
            self = .delivered
        case 429:
            self = .retry
        case 400...499:
            self = .reject
        default:
            self = .retry
        }
    }
}
