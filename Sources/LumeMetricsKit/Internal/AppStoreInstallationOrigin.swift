import Foundation
import StoreKit

/// Determines whether the build was originally downloaded from the App Store
/// or arrived through an update. The transaction is signed by Apple; no user
/// identifier or receipt data leaves the device.
enum InstallationOrigin: Sendable {
    case newInstallation
    case existingInstallation
    case unavailable
}

enum AppStoreInstallationOrigin {
    static func current(for environment: AppEnvironment) async -> InstallationOrigin {
        guard #available(iOS 16.0, macOS 13.0, *) else {
            return .unavailable
        }

        do {
            let result = try await AppTransaction.shared
            guard case let .verified(transaction) = result,
                  transaction.bundleID == environment.bundleId else {
                return .unavailable
            }

            // App Store transactions use CFBundleVersion on iOS and
            // CFBundleShortVersionString on macOS for originalAppVersion.
            let currentVersion = environment.platform == .ios
                ? environment.build
                : environment.appVersion
            return transaction.originalAppVersion == currentVersion
                ? .newInstallation
                : .existingInstallation
        } catch {
            return .unavailable
        }
    }
}
