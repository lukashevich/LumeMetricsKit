import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("Configuration")
struct ConfigurationTests {

    @Test("A missing write key disables the SDK completely")
    func missingWriteKeyIsInert() async {
        let store = FakeInstallationStore()
        let queue = FakeQueueStore()
        let transport = FakeTransport()

        await launch(makeDependencies(
            configuration: Configuration(infoDictionary: [:]),
            installationStore: store,
            queueStore: queue,
            transport: transport
        ))

        #expect(transport.attempts.value.isEmpty)
        #expect(store.state.value == nil, "no installation id may be generated without a write key")
        #expect(store.saveCount.value == 0)
        #expect(queue.writeCount.value == 0)
    }

    @Test("A missing write key leaves an existing queue untouched")
    func missingWriteKeyKeepsQueue() async {
        let queue = FakeQueueStore([QueuedEvent(event: makeEvent())])
        await launch(makeDependencies(
            configuration: .stub(writeKey: nil),
            queueStore: queue
        ))

        #expect(queue.state.value.count == 1)
        #expect(queue.writeCount.value == 0)
    }

    @Test("A blank or whitespace-only write key counts as missing", arguments: ["", "   ", "\n"])
    func blankWriteKeyIsMissing(raw: String) {
        let configuration = Configuration(infoDictionary: [Configuration.writeKeyInfoKey: raw])
        #expect(configuration.writeKey == nil)
    }

    @Test("A write key is trimmed of stray whitespace")
    func writeKeyIsTrimmed() {
        let configuration = Configuration(
            infoDictionary: [Configuration.writeKeyInfoKey: "  wk_live_abc\n"]
        )
        #expect(configuration.writeKey == "wk_live_abc")
    }

    @Test("The endpoint defaults to the Lume ingest URL")
    func defaultEndpoint() {
        let configuration = Configuration(infoDictionary: [Configuration.writeKeyInfoKey: "wk"])
        #expect(configuration.endpoint.absoluteString == "https://api.lume.app/v1/telemetry/events")
    }

    @Test("A configured endpoint is used")
    func configuredEndpoint() {
        let configuration = Configuration(infoDictionary: [
            Configuration.writeKeyInfoKey: "wk",
            Configuration.endpointInfoKey: "https://eu.lume.app/v1/telemetry/events",
        ])
        #expect(configuration.endpoint.absoluteString == "https://eu.lume.app/v1/telemetry/events")
    }

    @Test("An unusable endpoint falls back to the default", arguments: [
        "", "   ", "not a url", "ftp://lume.app/events", "/relative/path",
    ])
    func invalidEndpointFallsBack(raw: String) {
        let configuration = Configuration(infoDictionary: [
            Configuration.writeKeyInfoKey: "wk",
            Configuration.endpointInfoKey: raw,
        ])
        #expect(configuration.endpoint == Configuration.defaultEndpoint)
    }

    @Test("A non-string plist value is ignored instead of trapping")
    func wrongTypesAreIgnored() {
        let configuration = Configuration(infoDictionary: [
            Configuration.writeKeyInfoKey: 42,
            Configuration.endpointInfoKey: ["nested": true],
        ])
        #expect(configuration.writeKey == nil)
        #expect(configuration.endpoint == Configuration.defaultEndpoint)
    }

    @Test("The endpoint override wins over Info.plist")
    func overrideWins() {
        let override = URL(string: "http://localhost:8080/events")!
        let configuration = Configuration(
            infoDictionary: [
                Configuration.writeKeyInfoKey: "wk",
                Configuration.endpointInfoKey: "https://eu.lume.app/v1/telemetry/events",
            ],
            endpointOverride: override
        )
        #expect(configuration.endpoint == override)
    }

    @Test("Debug logging is off unless explicitly enabled")
    func debugLoggingDefault() {
        #expect(Configuration(infoDictionary: [:]).debugLogging == false)
        #expect(
            Configuration(infoDictionary: [Configuration.debugLoggingInfoKey: true]).debugLogging
        )
    }

    @Test("bundleId and version keys are read from the bundle's Info dictionary")
    func environmentFromInfoDictionary() throws {
        let environment = try #require(AppEnvironment(
            bundleIdentifier: "app.lume.example",
            infoDictionary: [
                "CFBundleShortVersionString": "3.2.1",
                "CFBundleVersion": "301",
            ]
        ))

        #expect(environment.bundleId == "app.lume.example")
        #expect(environment.appVersion == "3.2.1")
        #expect(environment.build == "301")
    }

    @Test("A bundle without an identifier yields no environment, so nothing is sent")
    func missingBundleIdentifier() {
        #expect(AppEnvironment(bundleIdentifier: nil, infoDictionary: [:]) == nil)
        #expect(AppEnvironment(bundleIdentifier: "", infoDictionary: [:]) == nil)
    }

    @Test("Missing version keys degrade to a placeholder instead of crashing")
    func missingVersionKeys() throws {
        let environment = try #require(
            AppEnvironment(bundleIdentifier: "app.lume.example", infoDictionary: nil)
        )
        #expect(environment.appVersion == AppEnvironment.unknownValue)
        #expect(environment.build == AppEnvironment.unknownValue)
    }

    @Test("An app with no build number never reports appUpdated")
    func unknownBuildNeverUpdates() async {
        let store = FakeInstallationStore()
        let environment = AppEnvironment.stub(build: AppEnvironment.unknownValue)
        await launch(makeDependencies(environment: environment, installationStore: store))

        let transport = FakeTransport()
        await launch(makeDependencies(
            environment: environment,
            installationStore: store,
            transport: transport
        ))
        #expect(transport.attempts.value.isEmpty)
    }
}
