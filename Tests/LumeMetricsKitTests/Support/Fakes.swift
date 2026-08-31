import Foundation
@testable import LumeMetricsKit

/// Minimal lock box so the fakes are `Sendable` without needing to be actors.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&storage) }
    }
}

struct FakeStoreError: Error {}

/// In-memory stand-in for the Keychain, with injectable failure modes.
struct FakeInstallationStore: InstallationStore {
    enum Mode: Sendable {
        case working
        case unreadable
        case unwritable
    }

    let state: Box<InstallationRecord?>
    let mode: Mode
    let saveCount = Box(0)

    init(record: InstallationRecord? = nil, mode: Mode = .working) {
        state = Box(record)
        self.mode = mode
    }

    func load() throws -> InstallationRecord? {
        if case .unreadable = mode { throw FakeStoreError() }
        return state.value
    }

    func save(_ record: InstallationRecord) throws {
        if case .unwritable = mode { throw FakeStoreError() }
        saveCount.mutate { $0 += 1 }
        state.value = record
    }
}

/// In-memory stand-in for the on-disk queue.
struct FakeQueueStore: EventQueueStore {
    let state: Box<[QueuedEvent]>
    let writeCount = Box(0)

    init(_ events: [QueuedEvent] = []) { state = Box(events) }

    func load() -> [QueuedEvent] { state.value }

    func replace(with events: [QueuedEvent]) {
        writeCount.mutate { $0 += 1 }
        state.value = events
    }
}

/// Transport that replays a scripted list of results and records what it was asked to send.
struct FakeTransport: EventTransport {
    struct Attempt: Sendable {
        let event: MetricEvent
        let endpoint: URL
        let writeKey: String
    }

    let attempts = Box<[Attempt]>([])
    private let scripted: Box<[DeliveryResult]>
    private let fallback: DeliveryResult

    init(results: [DeliveryResult] = [], fallback: DeliveryResult = .delivered) {
        scripted = Box(results)
        self.fallback = fallback
    }

    static func always(_ result: DeliveryResult) -> FakeTransport {
        FakeTransport(fallback: result)
    }

    var sentEvents: [MetricEvent] { attempts.value.map(\.event) }

    func send(_ event: MetricEvent, to endpoint: URL, writeKey: String) async -> DeliveryResult {
        attempts.mutate { $0.append(Attempt(event: event, endpoint: endpoint, writeKey: writeKey)) }
        return scripted.mutate { results in
            results.isEmpty ? fallback : results.removeFirst()
        }
    }
}

extension AppEnvironment {
    static func stub(
        bundleId: String = "app.lume.example",
        appVersion: String = "1.0.0",
        build: String = "10",
        platform: Platform = .current
    ) -> AppEnvironment {
        AppEnvironment(
            bundleId: bundleId,
            appVersion: appVersion,
            build: build,
            platform: platform
        )
    }
}

extension Configuration {
    static func stub(
        writeKey: String? = "wk_test_123",
        endpoint: URL = URL(string: "https://example.test/v1/telemetry/events")!
    ) -> Configuration {
        Configuration(writeKey: writeKey, endpoint: endpoint)
    }
}

/// Builds dependencies with deterministic time and identifiers.
func makeDependencies(
    configuration: Configuration = .stub(),
    environment: AppEnvironment = .stub(),
    installationStore: FakeInstallationStore = FakeInstallationStore(),
    queueStore: FakeQueueStore = FakeQueueStore(),
    transport: FakeTransport = FakeTransport(),
    installationOrigin: InstallationOrigin = .newInstallation,
    now: Date = Date(timeIntervalSince1970: 1_772_000_000)
) -> Dependencies {
    let counter = Box(0)
    return Dependencies(
        configuration: configuration,
        environment: environment,
        installationStore: installationStore,
        queueStore: queueStore,
        transport: transport,
        installationOrigin: { _ in installationOrigin },
        now: { now },
        newIdentifier: {
            let index = counter.mutate { value -> Int in
                value += 1
                return value
            }
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
    )
}

/// One launch of the app: a brand new coordinator over the given dependencies.
func launch(_ dependencies: Dependencies) async {
    await MetricsCoordinator().start(with: dependencies)
}

func makeEvent(
    name: MetricEvent.Name = .firstOpen,
    eventId: UUID = UUID(),
    installationId: String = "installation",
    environment: AppEnvironment = .stub(),
    occurredAt: Date = Date(timeIntervalSince1970: 1_772_000_000)
) -> MetricEvent {
    MetricEvent(
        name: name,
        eventId: eventId,
        installationId: installationId,
        environment: environment,
        occurredAt: occurredAt
    )
}
