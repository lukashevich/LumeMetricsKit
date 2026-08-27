import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("Event payload")
struct PayloadTests {

    @Test("The wire payload carries exactly the agreed fields")
    func payloadKeys() async throws {
        let transport = FakeTransport()
        await launch(makeDependencies(
            environment: .stub(bundleId: "app.lume.example", appVersion: "2.3.4", build: "42"),
            transport: transport
        ))

        let event = try #require(transport.sentEvents.first)
        let data = try JSONEncoder().encode(event)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(Set(json.keys) == [
            "eventId", "event", "installationId", "bundleId",
            "appVersion", "build", "platform", "occurredAt",
        ])
        #expect(json["event"] as? String == "firstOpen")
        #expect(json["bundleId"] as? String == "app.lume.example")
        #expect(json["appVersion"] as? String == "2.3.4")
        #expect(json["build"] as? String == "42")
        #expect(UUID(uuidString: try #require(json["eventId"] as? String)) != nil)
    }

    @Test("platform is ios or macos")
    func platformValue() throws {
        #expect(Platform.ios.rawValue == "ios")
        #expect(Platform.macos.rawValue == "macos")
        #if os(macOS)
        #expect(Platform.current == .macos)
        #else
        #expect(Platform.current == .ios)
        #endif
    }

    @Test("occurredAt is ISO-8601 in UTC")
    func occurredAtFormat() throws {
        let event = makeEvent(occurredAt: Date(timeIntervalSince1970: 1_772_000_000))
        #expect(event.occurredAt == "2026-02-25T06:13:20Z")

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        #expect(parser.date(from: event.occurredAt) != nil)
    }

    @Test("Each event gets its own eventId")
    func distinctEventIds() async throws {
        let store = FakeInstallationStore()
        let first = FakeTransport()
        await launch(makeDependencies(installationStore: store, transport: first))

        let second = FakeTransport()
        await launch(makeDependencies(
            environment: .stub(build: "11"),
            installationStore: store,
            transport: second
        ))

        let ids = (first.sentEvents + second.sentEvents).map(\.eventId)
        #expect(Set(ids).count == ids.count)
    }

    @Test("An event survives a persistence round trip unchanged")
    func codableRoundTrip() throws {
        let original = QueuedEvent(event: makeEvent(name: .appUpdated), attempts: 3)
        let decoded = try JSONDecoder().decode(
            QueuedEvent.self,
            from: try JSONEncoder().encode(original)
        )
        #expect(decoded == original)
    }
}
