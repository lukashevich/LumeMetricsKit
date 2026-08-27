import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("On-disk queue")
struct FileEventQueueStoreTests {

    private func makeStore() throws -> (FileEventQueueStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LumeMetricsKitTests-\(UUID().uuidString)", isDirectory: true)
        return (FileEventQueueStore(directory: directory), directory)
    }

    @Test("The queue survives a write/read round trip")
    func roundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = [
            QueuedEvent(event: makeEvent(name: .firstOpen), attempts: 0),
            QueuedEvent(event: makeEvent(name: .appUpdated), attempts: 2),
        ]
        store.replace(with: events)

        #expect(store.load() == events)
    }

    @Test("Reading a queue that was never written yields an empty queue")
    func missingFileIsEmpty() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load().isEmpty)
    }

    @Test("Replacing with an empty queue removes the file")
    func emptyQueueRemovesFile() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.replace(with: [QueuedEvent(event: makeEvent())])
        let file = directory.appendingPathComponent("queue.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        store.replace(with: [])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("A corrupt queue file is treated as empty rather than crashing")
    func corruptFileIsEmpty() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("queue.json"))

        #expect(store.load().isEmpty)
    }

    @Test("The store never persists more than 100 events")
    func capEnforcedOnDisk() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let events = (0..<150).map {
            QueuedEvent(event: makeEvent(installationId: "install-\($0)"))
        }
        store.replace(with: events)

        let loaded = store.load()
        #expect(loaded.count == FileEventQueueStore.maximumEventCount)
        #expect(loaded.first?.event.installationId == "install-50", "the oldest events are dropped")
        #expect(loaded.last?.event.installationId == "install-149")
    }

    @Test("The persisted queue is compact JSON")
    func persistedFormIsCompact() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        store.replace(with: [QueuedEvent(event: makeEvent())])
        let data = try Data(contentsOf: directory.appendingPathComponent("queue.json"))
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(!text.contains("\n"))
        #expect(data.count < 512)
    }

    @Test("An offline event written to disk is retried from disk on the next launch")
    func diskBackedRetry() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let installations = FakeInstallationStore()
        var dependencies = makeDependencies(
            installationStore: installations,
            transport: .always(.retry)
        )
        dependencies.queueStore = store
        await launch(dependencies)

        #expect(store.load().count == 1)
        let queuedId = store.load().first?.event.eventId

        let online = FakeTransport()
        var next = makeDependencies(installationStore: installations, transport: online)
        next.queueStore = store
        await launch(next)

        #expect(online.sentEvents.first?.eventId == queuedId)
        #expect(store.load().isEmpty)
    }
}
