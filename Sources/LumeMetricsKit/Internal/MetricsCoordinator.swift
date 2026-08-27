import Foundation

/// Everything the coordinator needs, injected so it can run against fakes in tests.
struct Dependencies: Sendable {
    var configuration: Configuration
    var environment: AppEnvironment
    var installationStore: any InstallationStore
    var queueStore: any EventQueueStore
    var transport: any EventTransport
    var now: @Sendable () -> Date = { Date() }
    var newIdentifier: @Sendable () -> UUID = { UUID() }
}

/// Serialises the whole SDK lifecycle: decide, persist, deliver.
actor MetricsCoordinator {

    static let shared = MetricsCoordinator()

    /// Retryable events are given up on after this many failed launches.
    static let maximumAttempts = 8

    private var isStarted = false

    /// Runs one telemetry pass. Extra calls in the same process are ignored, so a duplicated
    /// `LumeMetrics.start()` can never duplicate an event.
    func start(with dependencies: Dependencies) async {
        guard !isStarted else { return }
        isStarted = true
        await run(dependencies)
    }

    private func run(_ dependencies: Dependencies) async {
        let log = Log(enabled: dependencies.configuration.debugLogging)

        // No key means the SDK is not configured for this app: stay completely inert.
        guard let writeKey = dependencies.configuration.writeKey else {
            log.debug("No write key configured; telemetry disabled.")
            return
        }

        var queue = dependencies.queueStore.load()

        if let pending = pendingEvents(dependencies, log: log) {
            queue.append(contentsOf: pending)
            if queue.count > FileEventQueueStore.maximumEventCount {
                let dropped = queue.count - FileEventQueueStore.maximumEventCount
                queue.removeFirst(dropped)
                log.debug("Queue over capacity; dropped \(dropped) oldest event(s).")
            }
        }

        guard !queue.isEmpty else { return }

        queue = await flush(queue, writeKey: writeKey, dependencies: dependencies, log: log)
        dependencies.queueStore.replace(with: queue)
    }

    // MARK: - Deciding what to send

    /// Returns newly created events, or `nil` when nothing new should be recorded.
    ///
    /// The installation record is written *before* any delivery attempt: that write is the commit
    /// point, so a crash or an offline device can only ever delay an event, not duplicate it.
    private func pendingEvents(_ dependencies: Dependencies, log: Log) -> [QueuedEvent]? {
        let existing: InstallationRecord?
        do {
            existing = try dependencies.installationStore.load()
        } catch {
            // Unreadable store: we cannot tell a new install from a known one, and guessing
            // would risk a duplicate `firstOpen`. Send nothing this launch.
            log.debug("Installation store unreadable; skipping event creation.")
            return nil
        }

        let build = dependencies.environment.build
        var record = existing ?? InstallationRecord(
            installationId: dependencies.newIdentifier().uuidString,
            firstOpenRecorded: false,
            lastRecordedBuild: nil
        )

        var names: [MetricEvent.Name] = []
        if !record.firstOpenRecorded {
            names.append(.firstOpen)
            record.firstOpenRecorded = true
        } else if let lastBuild = record.lastRecordedBuild, lastBuild != build {
            names.append(.appUpdated)
        }
        // A fresh install (and a record predating this field) adopts the current build silently,
        // so `appUpdated` only ever fires for a build change actually observed on this device.
        record.lastRecordedBuild = build

        guard record != existing else { return nil }

        do {
            try dependencies.installationStore.save(record)
        } catch {
            log.debug("Installation store unwritable; skipping event creation.")
            return nil
        }

        let occurredAt = dependencies.now()
        log.debug("Recorded \(names.map(\.rawValue).joined(separator: ",")).")
        return names.map { name in
            QueuedEvent(
                event: MetricEvent(
                    name: name,
                    eventId: dependencies.newIdentifier(),
                    installationId: record.installationId,
                    environment: dependencies.environment,
                    occurredAt: occurredAt
                )
            )
        }
    }

    // MARK: - Delivery

    /// Delivers the queue oldest-first and returns what still needs to be retried later.
    private func flush(
        _ queue: [QueuedEvent],
        writeKey: String,
        dependencies: Dependencies,
        log: Log
    ) async -> [QueuedEvent] {
        var remaining: [QueuedEvent] = []
        var index = 0

        while index < queue.count {
            var queued = queue[index]
            index += 1

            let result = await dependencies.transport.send(
                queued.event,
                to: dependencies.configuration.endpoint,
                writeKey: writeKey
            )

            switch result {
            case .delivered:
                log.debug("Delivered \(queued.event.event.rawValue).")
            case .reject:
                // 4xx other than 429: the server will never accept this event.
                log.debug("Rejected \(queued.event.event.rawValue); discarding.")
            case .retry:
                queued.attempts += 1
                if queued.attempts >= Self.maximumAttempts {
                    log.debug("Giving up on \(queued.event.event.rawValue) after \(queued.attempts) attempts.")
                } else {
                    remaining.append(queued)
                }
                // The next events would almost certainly hit the same failure; leave them
                // untouched for the next launch instead of hammering the network.
                remaining.append(contentsOf: queue[index...])
                log.debug("Delivery paused with \(remaining.count) event(s) queued.")
                return remaining
            }
        }

        return remaining
    }
}
