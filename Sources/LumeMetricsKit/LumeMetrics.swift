import Foundation

/// Lume install telemetry.
///
/// Integration is a single call, normally from the app entry point:
///
/// ```swift
/// import LumeMetricsKit
///
/// LumeMetrics.start()
/// ```
///
/// The SDK reads its write key from `Info.plist` (`LumeMetricsWriteKey`). When the key is
/// absent the SDK stays completely inert: nothing is stored, nothing is sent, nothing is logged.
///
/// Only two events exist: ``MetricEvent/Name/firstOpen`` (once per installation) and
/// ``MetricEvent/Name/appUpdated`` (once per new `CFBundleVersion`). No screens, sessions,
/// clicks or heartbeats are collected, and no personal data ever leaves the device.
public enum LumeMetrics {

    /// Starts telemetry using the configuration from `Info.plist`.
    ///
    /// Returns immediately; all work happens on a background task. Calling this more than once
    /// per process is safe — subsequent calls are ignored.
    public static func start() {
        launch(endpointOverride: nil)
    }

    /// Starts telemetry against an explicit endpoint, overriding `LumeMetricsEndpoint`.
    ///
    /// Intended for tests and local development only; production apps should call ``start()``.
    ///
    /// - Parameter endpoint: Endpoint to post events to, or `nil` to use the configured one.
    public static func start(endpoint: URL? = nil) {
        launch(endpointOverride: endpoint)
    }

    private static func launch(endpointOverride: URL?) {
        // Reading Info.plist and Bundle.main is a dictionary lookup; everything Sendable is
        // captured here so the actor never touches non-Sendable Foundation types.
        let configuration = Configuration(
            infoDictionary: Bundle.main.infoDictionary,
            endpointOverride: endpointOverride
        )
        guard let environment = AppEnvironment.current() else { return }

        let dependencies = Dependencies(
            configuration: configuration,
            environment: environment,
            installationStore: KeychainInstallationStore(service: environment.bundleId),
            queueStore: FileEventQueueStore.applicationSupport(bundleId: environment.bundleId),
            transport: URLSessionTransport(),
            installationOrigin: AppStoreInstallationOrigin.current
        )

        Task.detached(priority: .utility) {
            await MetricsCoordinator.shared.start(with: dependencies)
        }
    }
}
