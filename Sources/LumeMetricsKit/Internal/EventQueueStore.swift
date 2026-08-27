import Foundation

protocol EventQueueStore: Sendable {
    /// Returns the persisted queue, oldest first. Never throws: an unreadable queue is empty.
    func load() -> [QueuedEvent]
    /// Replaces the persisted queue. Failures are swallowed — telemetry must not break the app.
    func replace(with events: [QueuedEvent])
}

/// Compact, atomic, JSON-on-disk queue in Application Support.
struct FileEventQueueStore: EventQueueStore {

    /// Hard cap enforced by ``MetricsCoordinator``; the file itself is trimmed defensively too.
    static let maximumEventCount = 100

    private let directory: URL
    private let fileName = "queue.json"

    init(directory: URL) {
        self.directory = directory
    }

    static func applicationSupport(bundleId: String) -> FileEventQueueStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return FileEventQueueStore(
            directory: base
                .appendingPathComponent(bundleId, isDirectory: true)
                .appendingPathComponent("LumeMetricsKit", isDirectory: true)
        )
    }

    private var fileURL: URL {
        directory.appendingPathComponent(fileName, isDirectory: false)
    }

    func load() -> [QueuedEvent] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(QueueFile.self, from: data)
        else { return [] }
        return file.events.suffix(Self.maximumEventCount)
    }

    func replace(with events: [QueuedEvent]) {
        guard !events.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let file = QueueFile(events: Array(events.suffix(Self.maximumEventCount)))
        guard let data = try? JSONEncoder().encode(file) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Nothing to do: the events stay in memory for this launch and are simply lost after.
        }
    }

    /// Versioned envelope so a future format change can be detected instead of misparsed.
    private struct QueueFile: Codable {
        var version: Int = 1
        var events: [QueuedEvent]
    }
}
