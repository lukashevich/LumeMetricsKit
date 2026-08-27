import Foundation
import Testing
@testable import LumeMetricsKit

/// Intercepts requests so the transport can be exercised without a network.
final class StubURLProtocol: URLProtocol {
    struct Capture: Sendable {
        var method: String?
        var url: URL?
        var headers: [String: String]
        var body: Data?
    }

    /// `nil` response simulates a transport-level failure (offline).
    static let response = Box<(status: Int, body: Data)?>((200, Data()))
    static let captured = Box<[Capture]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }

        Self.captured.mutate {
            $0.append(Capture(
                method: request.httpMethod,
                url: request.url,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            ))
        }

        guard let stubbed = Self.response.value, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stubbed.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stubbed.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("URLSession transport", .serialized)
struct URLSessionTransportTests {

    private func makeTransport() -> URLSessionTransport {
        StubURLProtocol.captured.value = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    @Test("The request is a JSON POST carrying the write key as a bearer token")
    func requestShape() async throws {
        StubURLProtocol.response.value = (202, Data())
        let transport = makeTransport()
        let endpoint = URL(string: "https://api.lume.test/v1/telemetry/events")!
        let event = makeEvent(name: .appUpdated)

        let result = await transport.send(event, to: endpoint, writeKey: "wk_live_abc")
        #expect(result == .delivered)

        let capture = try #require(StubURLProtocol.captured.value.first)
        #expect(capture.method == "POST")
        #expect(capture.url == endpoint)
        #expect(capture.headers["Authorization"] == "Bearer wk_live_abc")
        #expect(capture.headers["Content-Type"] == "application/json")
        #expect(capture.headers["Idempotency-Key"] == event.eventId)

        let body = try #require(capture.body)
        let decoded = try JSONDecoder().decode(MetricEvent.self, from: body)
        #expect(decoded == event)
    }

    @Test("A transport failure asks for a retry")
    func offlineIsRetryable() async {
        StubURLProtocol.response.value = nil
        let transport = makeTransport()

        let result = await transport.send(
            makeEvent(),
            to: URL(string: "https://api.lume.test/v1/telemetry/events")!,
            writeKey: "wk"
        )
        #expect(result == .retry)
    }

    @Test("HTTP status codes map onto the retry policy", arguments: [
        (200, DeliveryResult.delivered),
        (204, DeliveryResult.delivered),
        (400, DeliveryResult.reject),
        (401, DeliveryResult.reject),
        (413, DeliveryResult.reject),
        (429, DeliveryResult.retry),
        (500, DeliveryResult.retry),
        (503, DeliveryResult.retry),
    ])
    func statusMapping(status: Int, expected: DeliveryResult) async {
        StubURLProtocol.response.value = (status, Data())
        let transport = makeTransport()

        let result = await transport.send(
            makeEvent(),
            to: URL(string: "https://api.lume.test/v1/telemetry/events")!,
            writeKey: "wk"
        )
        #expect(result == expected)
    }
}
