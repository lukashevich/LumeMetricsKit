import Foundation
import Testing
@testable import LumeMetricsKit

@Suite("Public API")
struct PublicAPITests {

    @Test("start() and start(endpoint:) are callable and never throw or block")
    func startIsSafeToCall() {
        // The test host has no bundle identifier and no write key, so both calls are inert.
        // What this pins down is that the two overloads resolve unambiguously and that a
        // misconfigured host cannot crash an app at launch.
        LumeMetrics.start()
        LumeMetrics.start(endpoint: URL(string: "https://localhost:9/events")!)
        LumeMetrics.start(endpoint: nil)
    }

    @Test("The Keychain store round-trips an installation record", .enabled(if: keychainIsUsable))
    func keychainRoundTrip() throws {
        let store = KeychainInstallationStore(
            service: "app.lume.tests",
            account: "roundtrip-\(UUID().uuidString)"
        )
        #expect(try store.load() == nil)

        var record = InstallationRecord(
            installationId: UUID().uuidString,
            firstOpenRecorded: true,
            lastRecordedBuild: "10"
        )
        try store.save(record)
        #expect(try store.load() == record)

        record.lastRecordedBuild = "11"
        try store.save(record)
        #expect(try store.load()?.lastRecordedBuild == "11")
    }
}

/// The SPM test process is unsigned on some hosts, where the data-protection Keychain is
/// unavailable. The store's failure path is covered by the fakes, so the real store is only
/// exercised where the Keychain actually works.
private let keychainIsUsable: Bool = {
    let store = KeychainInstallationStore(
        service: "app.lume.tests.probe",
        account: "probe-\(UUID().uuidString)"
    )
    do {
        try store.save(
            InstallationRecord(installationId: "probe", firstOpenRecorded: false, lastRecordedBuild: nil)
        )
        return true
    } catch {
        return false
    }
}()
