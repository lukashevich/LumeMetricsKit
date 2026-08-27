import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("Event lifecycle")
struct EventLifecycleTests {

    @Test("A fresh installation sends exactly one firstOpen")
    func firstOpenOnFreshInstall() async throws {
        let store = FakeInstallationStore()
        let transport = FakeTransport()
        let queue = FakeQueueStore()
        await launch(makeDependencies(installationStore: store, queueStore: queue, transport: transport))

        #expect(transport.sentEvents.count == 1)
        let event = try #require(transport.sentEvents.first)
        #expect(event.event == .firstOpen)
        #expect(queue.state.value.isEmpty)

        let record = try #require(store.state.value)
        #expect(record.firstOpenRecorded)
        #expect(record.lastRecordedBuild == "10")
        #expect(UUID(uuidString: record.installationId) != nil)
        #expect(event.installationId == record.installationId)
    }

    @Test("A fresh installation does not also send appUpdated")
    func freshInstallDoesNotSendAppUpdated() async {
        let transport = FakeTransport()
        await launch(makeDependencies(transport: transport))

        #expect(transport.sentEvents.map(\.event) == [.firstOpen])
    }

    @Test("A second launch of the same build sends nothing")
    func secondLaunchIsSilent() async throws {
        let store = FakeInstallationStore()
        await launch(makeDependencies(installationStore: store))

        let transport = FakeTransport()
        let queue = FakeQueueStore()
        await launch(makeDependencies(installationStore: store, queueStore: queue, transport: transport))

        #expect(transport.attempts.value.isEmpty)
        #expect(queue.writeCount.value == 0)
        #expect(store.saveCount.value == 1)
    }

    @Test("A new CFBundleVersion sends appUpdated once, with the new version and build")
    func buildChangeSendsAppUpdated() async throws {
        let store = FakeInstallationStore()
        await launch(makeDependencies(
            environment: .stub(appVersion: "1.0.0", build: "10"),
            installationStore: store
        ))

        let updated = FakeTransport()
        await launch(makeDependencies(
            environment: .stub(appVersion: "1.1.0", build: "11"),
            installationStore: store,
            transport: updated
        ))

        #expect(updated.sentEvents.count == 1)
        let event = try #require(updated.sentEvents.first)
        #expect(event.event == .appUpdated)
        #expect(event.appVersion == "1.1.0")
        #expect(event.build == "11")

        // Relaunching the same build must stay silent.
        let relaunch = FakeTransport()
        await launch(makeDependencies(
            environment: .stub(appVersion: "1.1.0", build: "11"),
            installationStore: store,
            transport: relaunch
        ))
        #expect(relaunch.attempts.value.isEmpty)
    }

    @Test("appUpdated fires for every subsequent build, and installationId never changes")
    func repeatedUpdatesKeepInstallationId() async throws {
        let store = FakeInstallationStore()
        var identifiers: Set<String> = []
        var names: [MetricEvent.Name] = []

        for build in ["10", "11", "11", "12"] {
            let transport = FakeTransport()
            await launch(makeDependencies(
                environment: .stub(build: build),
                installationStore: store,
                transport: transport
            ))
            names.append(contentsOf: transport.sentEvents.map(\.event))
            identifiers.formUnion(transport.sentEvents.map(\.installationId))
        }

        #expect(names == [.firstOpen, .appUpdated, .appUpdated])
        #expect(identifiers.count == 1)
    }

    @Test("Downgrading the build also counts as a change")
    func buildDowngradeSendsAppUpdated() async {
        let store = FakeInstallationStore()
        await launch(makeDependencies(environment: .stub(build: "11"), installationStore: store))

        let transport = FakeTransport()
        await launch(makeDependencies(
            environment: .stub(build: "10"),
            installationStore: store,
            transport: transport
        ))

        #expect(transport.sentEvents.map(\.event) == [.appUpdated])
    }

    @Test("Calling start twice in one process cannot duplicate an event")
    func repeatedStartIsIdempotent() async {
        let transport = FakeTransport()
        let dependencies = makeDependencies(transport: transport)
        let coordinator = MetricsCoordinator()

        await coordinator.start(with: dependencies)
        await coordinator.start(with: dependencies)
        await coordinator.start(with: dependencies)

        #expect(transport.attempts.value.count == 1)
    }

    @Test("Concurrent start calls still produce a single event")
    func concurrentStartIsIdempotent() async {
        let transport = FakeTransport()
        let dependencies = makeDependencies(transport: transport)
        let coordinator = MetricsCoordinator()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { await coordinator.start(with: dependencies) }
            }
        }

        #expect(transport.attempts.value.count == 1)
    }

    @Test("An unreadable Keychain sends nothing rather than risking a duplicate firstOpen")
    func unreadableStoreIsSilent() async {
        let transport = FakeTransport()
        await launch(makeDependencies(
            installationStore: FakeInstallationStore(mode: .unreadable),
            transport: transport
        ))

        #expect(transport.attempts.value.isEmpty)
    }

    @Test("An unwritable Keychain sends nothing, so the event can be retried on a later launch")
    func unwritableStoreIsSilent() async {
        let transport = FakeTransport()
        let queue = FakeQueueStore()
        await launch(makeDependencies(
            installationStore: FakeInstallationStore(mode: .unwritable),
            queueStore: queue,
            transport: transport
        ))

        #expect(transport.attempts.value.isEmpty)
        #expect(queue.state.value.isEmpty)
    }
}
