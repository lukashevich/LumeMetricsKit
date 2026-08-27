import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("Offline queue and retry")
struct QueueAndRetryTests {

    @Test("An undeliverable event is queued and retried on the next start")
    func offlineEventIsRetriedNextLaunch() async throws {
        let store = FakeInstallationStore()
        let queue = FakeQueueStore()

        let offline = FakeTransport.always(.retry)
        await launch(makeDependencies(installationStore: store, queueStore: queue, transport: offline))

        #expect(queue.state.value.count == 1)
        let queued = try #require(queue.state.value.first)
        #expect(queued.event.event == .firstOpen)
        #expect(queued.attempts == 1)

        // Next launch: same build, so no new event — only the queued one goes out.
        let online = FakeTransport()
        await launch(makeDependencies(installationStore: store, queueStore: queue, transport: online))

        #expect(online.sentEvents.count == 1)
        #expect(online.sentEvents.first?.eventId == queued.event.eventId, "eventId must be stable across retries")
        #expect(queue.state.value.isEmpty)
    }

    @Test("A queued event keeps its original timestamp and identifiers")
    func retryPreservesPayload() async throws {
        let store = FakeInstallationStore()
        let queue = FakeQueueStore()
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)

        await launch(makeDependencies(
            installationStore: store,
            queueStore: queue,
            transport: .always(.retry),
            now: recorded
        ))

        let online = FakeTransport()
        await launch(makeDependencies(
            installationStore: store,
            queueStore: queue,
            transport: online,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        ))

        #expect(online.sentEvents.first?.occurredAt == ISO8601.string(from: recorded))
    }

    @Test("4xx other than 429 is dropped and never retried", arguments: [400, 401, 403, 404, 422])
    func clientErrorsAreDropped(status: Int) async {
        let queue = FakeQueueStore()
        let transport = FakeTransport.always(DeliveryResult(statusCode: status))
        await launch(makeDependencies(queueStore: queue, transport: transport))

        #expect(transport.attempts.value.count == 1)
        #expect(queue.state.value.isEmpty, "a permanently rejected event must not linger in the queue")
    }

    @Test("429 and 5xx are retried", arguments: [429, 500, 502, 503])
    func retryableStatusesAreQueued(status: Int) async {
        let queue = FakeQueueStore()
        await launch(makeDependencies(
            queueStore: queue,
            transport: .always(DeliveryResult(statusCode: status))
        ))

        #expect(queue.state.value.count == 1)
        #expect(queue.state.value.first?.attempts == 1)
    }

    @Test("A retryable event is abandoned after the attempt cap")
    func attemptsAreCapped() async {
        let store = FakeInstallationStore()
        let queue = FakeQueueStore()

        for _ in 0..<MetricsCoordinator.maximumAttempts {
            await launch(makeDependencies(
                installationStore: store,
                queueStore: queue,
                transport: .always(.retry)
            ))
        }

        #expect(queue.state.value.isEmpty, "the SDK must not retry forever")
    }

    @Test("A failed delivery stops the flush and preserves queue order")
    func failureStopsFlushAndKeepsOrder() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let existing = ids.map { QueuedEvent(event: makeEvent(eventId: $0)) }
        let queue = FakeQueueStore(existing)

        // First event delivers, second hits a 500; the third must be left untouched.
        let transport = FakeTransport(results: [.delivered, .retry])
        await launch(makeDependencies(
            installationStore: FakeInstallationStore(
                record: InstallationRecord(
                    installationId: "installation",
                    firstOpenRecorded: true,
                    lastRecordedBuild: "10"
                )
            ),
            queueStore: queue,
            transport: transport
        ))

        #expect(transport.attempts.value.count == 2)
        #expect(queue.state.value.map(\.event.eventId) == [ids[1].uuidString, ids[2].uuidString])
        #expect(queue.state.value.map(\.attempts) == [1, 0])
    }

    @Test("The queue never exceeds 100 events")
    func queueIsCapped() async throws {
        let existing = (0..<100).map { index in
            QueuedEvent(event: makeEvent(eventId: UUID(), installationId: "old-\(index)"))
        }
        let queue = FakeQueueStore(existing)

        await launch(makeDependencies(
            queueStore: queue,
            transport: .always(.retry)
        ))

        #expect(queue.state.value.count == FileEventQueueStore.maximumEventCount)
        // The oldest event was evicted to make room for the new firstOpen.
        #expect(!queue.state.value.contains { $0.event.installationId == "old-0" })
        #expect(queue.state.value.last?.event.event == .firstOpen)
    }

    @Test("Queued events are delivered to the configured endpoint with a bearer write key")
    func deliveryUsesConfiguration() async throws {
        let endpoint = URL(string: "https://staging.lume.test/v1/telemetry/events")!
        let transport = FakeTransport()
        await launch(makeDependencies(
            configuration: .stub(writeKey: "wk_live_abc", endpoint: endpoint),
            transport: transport
        ))

        let attempt = try #require(transport.attempts.value.first)
        #expect(attempt.endpoint == endpoint)
        #expect(attempt.writeKey == "wk_live_abc")
    }
}
