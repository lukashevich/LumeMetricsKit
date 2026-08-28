# LumeMetricsKit

Minimal install telemetry for Lume apps on iOS and macOS. Two events, no third-party
dependencies, no personal data.

## Integration

Add the package in Xcode via **File → Add Package Dependencies…** and enter the repository URL,
or add it to your own `Package.swift`:

```swift
.package(url: "https://github.com/lukashevich/LumeMetricsKit.git", from: "1.0.0")
```

Then start it once, at launch:

```swift
import SwiftUI
import LumeMetricsKit

@main
struct LumeApp: App {
    init() {
        LumeMetrics.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```

That is the whole integration. `start()` returns immediately and does its work on a background
task, so it never delays launch.

## Configuration

Two keys in `Info.plist`:

| Key | Required | Value |
| --- | --- | --- |
| `LumeMetricsWriteKey` | yes | Your Lume write key. Sent as `Authorization: Bearer <key>`. |
| `LumeMetricsEndpoint` | no | Ingest URL. Defaults to `https://lumeservice.onrender.com/v1/telemetry/events`. |

```xml
<key>LumeMetricsWriteKey</key>
<string>wk_live_your_key_here</string>
<key>LumeMetricsEndpoint</key>
<string>https://lumeservice.onrender.com/v1/telemetry/events</string>
```

Without `LumeMetricsWriteKey` the SDK is completely inert: nothing is generated, stored, sent, or
logged. That makes it safe to ship the package into a target that has not been provisioned yet.

`bundleId` is always taken from `Bundle.main.bundleIdentifier` and cannot be overridden.

An optional `LumeMetricsDebugLogging` boolean key turns on `os.Logger` diagnostics (event names,
queue sizes, HTTP status codes only — never the write key, the installation id, or a request body).

## Events

Exactly two, ever:

| Event | When |
| --- | --- |
| `firstOpen` | Once per installation. |
| `appUpdated` | Once per new `CFBundleVersion` seen on the device. |

A fresh installation sends only `firstOpen` — it adopts the current build silently, so
`appUpdated` fires only for a build change actually observed on that device.

There is no screen, click, session, paywall, or heartbeat tracking, and no API to add any.

### Payload

```json
{
  "eventId": "9C1E9F1A-...",
  "event": "firstOpen",
  "installationId": "4D0A21B7-...",
  "bundleId": "app.lume.example",
  "appVersion": "1.2.0",
  "build": "142",
  "platform": "ios",
  "occurredAt": "2026-08-28T09:41:07Z"
}
```

`eventId` is stable across retries, and is also sent as an `Idempotency-Key` header, so the server
can deduplicate. `occurredAt` is ISO-8601 in UTC and reflects when the event happened, not when it
was finally delivered.

## Privacy

Collected: the fields above. `installationId` is a UUID generated on device and stored in the
Keychain.

Never collected: email, name, Apple ID, IDFA or any advertising identifier, device name, device
model, locale, IP-derived location, screen or interaction data. The SDK reads nothing outside its
own two `Info.plist` keys, the bundle's version keys, and its own Keychain item.

## Delivery, offline queue, and retries

- One HTTP `POST` per event, off the main thread.
- If the device is offline or the request fails, the event is written to a compact JSON queue in
  Application Support and retried on the next `LumeMetrics.start()`. There are no timers and no
  background tasks.
- The queue holds at most **100** events; the oldest are evicted first.
- `2xx` — delivered, removed from the queue.
- `4xx` other than `429` — permanently rejected and dropped, never retried.
- `429`, `5xx`, and transport errors — retried on later launches, and given up on after 8 attempts.
- A failed delivery pauses the rest of the flush for that launch instead of hammering the network.

The installation record is committed to the Keychain *before* the first delivery attempt, so a
crash, a force-quit, or an offline launch can only delay an event — never duplicate it. If the
Keychain is unreadable or unwritable, the SDK sends nothing rather than risk a duplicate
`firstOpen`.

Calling `LumeMetrics.start()` more than once in a process is a no-op after the first call, so it is
safe to call it from more than one place.

## Local development

```swift
LumeMetrics.start(endpoint: URL(string: "http://localhost:8080/v1/telemetry/events")!)
```

For tests and local servers only; it overrides `LumeMetricsEndpoint`. Production apps call
`start()`.

## Requirements

iOS 14+, macOS 11+, Swift 6. Foundation, URLSession, and Keychain only — no third-party
dependencies.

## Tests

```bash
swift test
```

Covers first launch, repeated launch, build updates, a missing write key, the offline queue and
its retry path, the 100-event cap, the attempt cap, status-code handling, the request shape, and
on-disk persistence. The real Keychain round-trip test is skipped automatically in processes where
the Keychain is unavailable; the store's failure paths are covered with fakes.
