# FounderHQEvents for iOS

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

`https://github.com/FounderHQ/founderhq-events-ios`

Select version **0.8.0** or later. Swift Package Manager is the recommended installation method.

For CocoaPods:

```ruby
pod 'FounderHQEvents', '~> 0.8.0'
```

For installation directly from the release tag:

```ruby
pod 'FounderHQEvents', :git => 'https://github.com/FounderHQ/founderhq-events-ios.git', :tag => 'v0.8.0'
```

Both installation methods use the same Swift implementation. Requires iOS 15 or later.

## Usage

Install with Swift Package Manager or CocoaPods. The SDK provides automatic
application lifecycle and UIKit screen capture, a SwiftUI `founderHQScreen`
modifier, durable identity/queue/consent, and the same capture/profile API as
the web SDK. Advertising identifiers are never collected.

Version 0.8.0 sends PostHog-aligned protocol v2 requests to `POST /i/v2/e`, emits
`$session_start`, uses UUIDv7 sessions and screen-scoped `$screen_id` values,
and reports screen/viewport dimensions in physical pixels. Automatic facts use
the canonical `$` taxonomy and deep links recognize all 24 campaign keys.

Pass `account` in `FounderHQEventsConfiguration` to install context before the
first automatic event. `setAccount`, `setAccountProperties`, `clearAccount`
(or `resetAccounts`) update the app-scoped context, while
`identify(_:properties:account:)` changes identity and account atomically.
Account changes rotate only the account span; queued snapshots and the person
session remain unchanged. `reset()` clears both identity and account context.

`FounderHQEventsDependencies` injects clock, UUID, storage, transport, and
platform-facts providers. The Swift suite consumes the shared capability
matrix, executes every applicable fixture action exactly, and compares every
captured request plus normalized persistence/directive state to the canonical
golden. Remote config can disable and re-arm mobile session, screen, and
application-lifecycle capture, including installing UIKit screen capture on a
false-to-true transition. The SDK fetches `GET /i/v1/analytics/config` with the
publishable key, caches the last valid response in injected storage, and
exposes `refreshRemoteConfig()`; set `remoteConfig: false` to disable fetching.

## Privacy manifest

The package includes the required-reason declaration for its app-local
UserDefaults storage. Your app's privacy disclosures must also cover the event
properties and identity information it sends. If you inject shared App Group
storage, include the corresponding App Group access reason in your app's manifest.

## Release notes

### 0.8.0

- The default host is now `https://i.getfounderhq.com`. `app.getfounderhq.com` no longer serves SDK ingest.
