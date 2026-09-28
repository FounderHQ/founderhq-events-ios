# FounderHQEvents for iOS

## Installation

In Xcode, choose **File → Add Package Dependencies** and enter:

`https://github.com/FounderHQ/founderhq-events-ios`

Select version **1.1.1** or later. Swift Package Manager is the recommended installation method.

For CocoaPods:

```ruby
pod 'FounderHQEvents', '~> 1.1.1'
```

For installation directly from the release tag:

```ruby
pod 'FounderHQEvents', :git => 'https://github.com/FounderHQ/founderhq-events-ios.git', :tag => 'v1.1.1'
```

Both installation methods use the same Swift implementation. Requires iOS 15 or later.

## Usage

Install with Swift Package Manager or CocoaPods. The SDK provides automatic
application lifecycle and UIKit screen capture, a SwiftUI `founderHQScreen`
modifier, durable identity/queue/consent, and the same capture/profile API as
the web SDK. Advertising identifiers are never collected.

Version 1.1.1 sends protocol v2 requests to `POST /i/v2/e`, emits
`$session_start`, uses UUIDv7 sessions and screen-scoped `$screen_id` values,
and reports screen/viewport dimensions in physical pixels. Automatic facts use
the canonical `$` taxonomy and deep links recognize all 24 campaign keys.

Pass `account` in `FounderHQEventsConfiguration` to install context before the
first automatic event. `setAccount`, `setAccountProperties`, `clearAccount`
(or `resetAccounts`) update the app-scoped context, while
`identify(_:properties:account:)` changes identity and account atomically.
Account changes rotate only the account span; queued snapshots and the person
session remain unchanged. `reset()` clears both identity and account context.

`FounderHQEventsDependencies` injects clock, UUID, storage, transport,
platform-facts, screen-capture, and appearance providers. The Swift suite consumes the shared capability
matrix, executes every applicable fixture action exactly, and compares every
captured request plus normalized persistence/directive state to the canonical
golden. Remote config can disable and re-arm mobile session, screen, and
application-lifecycle capture, including installing UIKit screen capture on a
false-to-true transition. It can also switch element capture off through
`autocapture` and rage clicks off through `capture_rageclicks`; see
[Remote config and element capture](#remote-config-and-element-capture). The
SDK fetches `GET /i/v1/analytics/config` with the publishable key, caches the
last valid response in injected storage, and exposes `refreshRemoteConfig()`;
set `remoteConfig: false` to disable fetching.

Screen events carry `$screen_name`, `$screen_id`, and
`$prefers_color_scheme` (`"dark"` or `"light"`). Appearance is read from the
trait collection of the view controller that appeared last, so a window's
`overrideUserInterfaceStyle` counts. Until a view controller has appeared, and
when the appearance is unspecified, the property is omitted. This also works
in app extensions. Other automatic events do not get this property.

## Delivery and capture settings

`FounderHQEventsConfiguration` controls how events leave the device and what
the SDK captures for you.

| Setting | Default | What it does |
| --- | --- | --- |
| `flushInterval` | `10` | Seconds between automatic flushes. |
| `maxQueueSize` | `1000` | Events kept offline before the oldest are dropped. |
| `maxRetries` | `5` | Rungs of the retry ladder a failed event may climb. See [The retry ladder](#the-retry-ladder). |
| `captureElementInteractions` | `false` | Captures `$autocapture` on taps and `$rageclick` on three taps of one element inside a second. The default until remote config says otherwise. |
| `tracingHeaders` | `nil` | Exact hostnames whose requests carry `x-founderhq-session-id`. |
| `capturePushNotificationOpened` | `true` | Emits `$push_notification_opened` when the user taps a notification. |
| `autoProperties` | `nil` | Adds properties to screens, taps, and rage taps on the main actor. |
| `beforeSend` | `nil` | Changes or drops finished events before queueing, except purchase controls. |
| `debug` | `false` | Logs what the SDK drops, refuses, or fails to install. |

### The retry ladder

An event that fails to send does not go out again on the next flush. It climbs
a ladder instead:

| Attempt | When |
| --- | --- |
| 1 | At once |
| 2 | 30 seconds later |
| 3 | 30 seconds later |
| 4 | 2 minutes later |
| 5 | 5 minutes later |
| 6 | The next time your app starts |

The first two rungs recover the common failure: a phone in a lift, in a
tunnel, or on a train. The longer rungs cost the customer almost nothing,
because an offline app has nothing else to do. The last rung waits for a
launch rather than a clock, so an event whose app was killed during an outage
still gets one more chance. An event the ingest API will never accept still
dies, because the ladder ends.

A flush skips an event that is still waiting and sends the ones behind it, so
one stuck event never holds up the queue. `eventTTL` outranks the ladder: an
event older than 24 hours is dropped even with rungs left. Both the attempt
count and the next eligible time are stored beside the queue, so the ladder
survives a relaunch.

`maxRetries` cuts the ladder from the front. `maxRetries: 2` waits 30 seconds,
waits 30 seconds again, and then gives up. `0` sends once and never retries.

### What element capture catches

Element capture listens on `UIApplication.sendAction`, which every `UIControl`
and bar button item passes through, and on gesture recognisers, which is how a
tap on a plain `UIView`, a table row, or a SwiftUI element reports itself. One
physical tap always produces at most one `$autocapture`, even when it reaches
both hooks.

Taps and long presses are captured. Pans, pinches, rotations, swipes, and
hovers are not: they are scrolling and pointer noise rather than a chosen
action.

### What element capture stores

Element capture records the element's class name, its accessibility
identifier, its accessibility label, its enabled and selected state, the
action selector or recogniser class, the class names of the views above it,
and the owning view controller. It never records tap coordinates.

It also records the title the tapped control renders, as `text`, for the three
kinds of control that publish a static one.

| Control | What `text` holds |
| --- | --- |
| `UIButton` | The configuration title (then attributed configuration title), then current title, current attributed title, title-label text, normal title, or selected title. |
| `UIBarButtonItem` | The item's title. |
| `UISegmentedControl` | The title of the selected segment, and nothing while no segment is selected. |
| Everything else | Nothing. |

A captured title is trimmed, every run of spaces and line breaks folds into
one space, zero-width characters are dropped, and the result is cut to 255
characters.

Nothing a person types is ever recorded. A `UITextField`, a `UITextView`, and
a `UISearchBar` are skipped whole, before any property of theirs is read, so
neither a value nor a placeholder can reach the queue.

Give an element an `accessibilityIdentifier` and you will always be able to
find it in the data.

### Remote config and element capture

An operator can switch element capture off for every install from the
dashboard. Two keys do it:

| Key | Effect when `false` |
| --- | --- |
| `autocapture` | No `$autocapture` and no `$rageclick`. |
| `capture_rageclicks` | No `$rageclick`; taps are still captured. |

`captureElementInteractions` is the default your app ships with, not a
ceiling. Once settings arrive, `autocapture` wins in both directions: it can
switch a tap stream off for every install at once, and on for an app that
shipped with the flag `false`. A shipped app cannot be rebuilt on demand, so a
wrong default has to be fixable from the dashboard. Switching on takes effect
at once — the SDK installs its hook without waiting for the next screen.

Anything already queued under a key that turns off is dropped from the queue,
so it never leaves the device. If `autocapture` arrives as a rules object
rather than a boolean, iOS leaves capture as the app set it: only a boolean
changes it.

### Tracing headers

List bare hostnames, with no scheme, path, port, or wildcard:

```swift
FounderHQEventsConfiguration(tracingHeaders: ["api.example.com"])
```

Requests to those hosts carry the current session id in
`x-founderhq-session-id`, which is what joins a backend event to the visit that
caused it. Requests to any other host are untouched, and the header never
carries a distinct id: the ingest API ignores an identity claimed in a header.

## Adding properties to automatic events

Use `autoProperties` to add your own properties to `$screen`, `$autocapture`,
and `$rageclick`:

```swift
let events = FounderHQEvents(
    apiKey: "fhq_pk_XXXX",
    configuration: .init(
        captureElementInteractions: true,
        autoProperties: { context in
            ["section": context.screenName == "Pricing" ? "sales" : "app"]
        }
    )
)
```

Screen context tracks every `screen()` call and automatic screen observation,
even when screen events are disabled or consent is off. Tracking does not emit
events or call `autoProperties` while capture is disabled.

The callback runs on the main actor. `FounderHQAutoPropertiesContext` gives
it `event`, the current `screenName` (or `nil`), `element`, and
`elementDescription`. For a tap, `element` is the actual UIKit object, a
`UIView` that reports the gesture/control action or the `UIBarButtonItem`
that reports the action (not necessarily the deepest visible child).
`elementDescription` is the same
`JSONObject` recorded in `$elements[0]`. Screens have neither element field.
The callback runs for automatic UIKit screens, `founderHQScreen`, explicit
`screen` calls, and each captured tap or rage tap. Return a `[String: Any]`
map or `nil`. If it throws, capture continues without its properties and the
SDK logs one warning per client, even with `debug` off.

Lifecycle, session, identity, push, purchase, and custom `capture()` events
do not call it. Calling `capture("$screen")` yourself does not call it either.
iOS does not capture `$dead_click`.

You can also attach properties to a UIKit view:

```swift
productCard.fhqProperties = ["product_id": "sku_1"]
buyButton.fhqProperties = ["action": "buy"]
productCard.addSubview(buyButton)
```

A tap on the button carries both properties at the top level. The SDK walks
from the control or gesture view that reports the tap through all ancestors,
including those beyond the five described in `$elements`. For a bar button
item it starts at its `customView`, if present.
The nearest valid value wins a clash. Set `fhqProperties = nil` to remove
properties. Keys are used as given; snake_case is the convention.

SwiftUI apps can add tap properties through `autoProperties` for now:

```swift
let configuration = FounderHQEventsConfiguration(
    captureElementInteractions: true,
    autoProperties: { context in
        guard context.event == "$autocapture", context.screenName == "Shop" else { return nil }
        if context.elementDescription?["accessibility_identifier"] == .string("buy") {
            return ["action": "buy"]
        }
        return ["section": "shop"]
    }
)
```

Give the screen a name with `founderHQScreen("Shop")`. Element descriptions
reflect the UIKit object reporting the tap. A declarative SwiftUI form is
planned. Text inputs remain excluded from automatic tap capture.

Later values win in this order: automatic properties → `autoProperties`
→ `fhqProperties` → explicit `screen(name, properties:)` values.
Explicit screen properties cannot replace the SDK’s `$screen_name` or
`$screen_id`. Both new sources share these limits:

- Keys must contain 1–64 UTF-16 code units and must not start with `$`.
- Values must be strings, finite numbers, or booleans. Other values are dropped.
- Strings are trimmed and cut to 200 UTF-16 code units without splitting a surrogate pair.
- Each event keeps up to 20 extra keys. Nearest views come first, then the
  callback. Keys within each map are sorted, since Swift dictionaries have
  no insertion order. The first valid value wins.

Callback and declarative strings are sent as given apart from the trimming
and length limit above; they are not scrubbed for card numbers, SSNs, or other
sensitive content. These limits do not change explicit `screen()` or `capture()` properties.
Remote config updates keep your callback. `autoProperties` cannot rename
or drop events.

## beforeSend

Use `beforeSend` to change or drop a finished event before it enters the
queue. Purchase control events bypass it:

```swift
let configuration = FounderHQEventsConfiguration(beforeSend: { event in
    guard event.event != "debug.action" else { return nil }
    var updated = event
    updated.properties.removeValue(forKey: "email")
    return updated
})
```

It receives a `FounderHQEvent`, after automatic, callback, declarative, and
explicit properties have been merged. Event properties use `JSONValue`,
for example `.string("sales")`, `.number(2)`, or `.bool(true)`.
Return the event, a changed copy, or `nil` to drop it. A thrown error drops
it too. Only hook results are validated; without a hook the SDK queues the
event it built unchanged.

- Only `uuid`, `event`, `distinct_id`, `timestamp`, `properties`, `session_id`,
  `window_id`, and `options.process_person_profile` survive. Unknown envelope
  and options keys (including `cookieless_mode`) are discarded by the typed
  `Codable` envelope.
- The event name is trimmed and must be nonempty. Its original name is allowed,
  including internal names. A rename must pass the public event-name rules on
  the trimmed name; an app cannot rename an event to `$mobile_purchase_claim`.
- `uuid` must have the RFC 4122 8-4-4-4-12 hex form, version 1–8 and variant
  8/9/a/b. `distinct_id` is trimmed, must contain 1–400 characters, and must
  pass the SDK's illegal-identity check. Invalid values drop the event.
- `timestamp` must be a real RFC 3339 calendar instant with seconds, optional
  fractional seconds, and `Z` or a `±HH:MM` offset. Whole seconds are valid;
  impossible dates such as 30 February and values without a zone are dropped.
- `properties` must be a JSON object with JSON-encodable values, and
  `options.process_person_profile` must be a boolean. Swift's typed event
  enforces the object and boolean types; decoding invalid types throws.
- An invalid or non-v7 `session_id` is removed while keeping the event.
  Optional `window_id` is kept only if it is a string of at most 200 characters.

`$mobile_purchase_prepared` and `$mobile_purchase_claim` never call
`beforeSend`: they enter the queue as built by the SDK so purchase attribution
cannot silently break. Other lifecycle, session, identity, push, and custom
events do call it. An `$identify` synthesized after an identity-rotation
directive also calls it, with properties the hook may already have transformed
once. Make hooks idempotent. Delivery retries of an already queued event keep
the original hook result.

The closure is `@Sendable` and runs synchronously on the SDK's state actor,
with no guarantee of a particular thread. Keep it short and use safe shared
state; it is not a main-actor callback. `autoProperties` and the UIKit
declarative-property walk run on the main actor. Changing or dropping automatic
events can affect sessions, identity, and screen reports.

## Privacy manifest

The package includes the required-reason declaration for its app-local
UserDefaults storage. Your app's privacy disclosures must also cover the event
properties and identity information it sends. If you inject shared App Group
storage, include the corresponding App Group access reason in your app's manifest.

## Running the tests

`swift test` covers everything that is not UIKit. The swizzles need a
simulator, and the tests for them live in
`Tests/FounderHQEventsTests/UIKitCaptureTests.swift`:

```bash
Tools/run-simulator-tests.sh       # every test, on the iOS simulator
Tools/run-interaction-host-app.sh  # the UIApplication.sendAction hook
```

The second script exists because an XCTest bundle has no `UIApplication`, so
the `sendAction` hook cannot be driven from a unit test. It builds a small app,
installs it on the simulator, taps a real control, and prints one line per
check.

## Release notes

### 1.1.1

- Documentation only; no change in behavior. The pod version and the SDK
  version sent on the wire are both `1.1.1`.

### 1.1.0

- Add `autoProperties` for screens, taps, and rage taps, plus UIKit
  `fhqProperties`. SwiftUI apps use the callback; a declarative form is planned.
- Keep up to 20 valid extra properties, with nearer views taking priority.
- Add `beforeSend` for changing or dropping finished events. Purchase controls
  bypass it. Identity-rotation retries pass through it; hooks should be idempotent.
  Thrown errors and invalid required fields drop the event; invalid optional
  session/window fields are removed.
- Screen events include `$prefers_color_scheme` as `"dark"` or `"light"` at
  capture time using extension-safe traits. An unavailable or unspecified appearance is omitted.
- Track the current screen even when screen events are disabled, and preserve
  SDK-owned screen names and IDs against explicit property overrides.
- Keep the existing nonisolated screen-capture installer protocol requirement.
- The pod version and the SDK version sent on the wire are both `1.1.0`.

### 1.0.2

- `$device_type` is now `mobile` or `tablet`, the same spelling as the web,
  Android, and React Native SDKs. The server reads the earlier `Mobile` /
  `Tablet` the same way, so older app versions keep working.

### 1.0.0

- Element interactions match the web, Android, and React Native SDKs: the same
  events, the same fields, the same scrubbing, and the same rage-tap rule.
- A button built with `UIButton.Configuration` now reports its title. Reading
  only `title(for:)`, as before, returned nothing for most buttons written
  since iOS 15.
- Remote config wins in both directions. `autocapture` can switch element
  capture on for an app that shipped with it off, and off for one that shipped
  with it on. `captureElementInteractions` is the default until settings
  arrive, not a ceiling.
- Each event carries the tapped control and up to four of its parents, matching
  the other SDKs. It carried five before.
- `PrivacyInfo.xcprivacy` now declares the data this SDK collects: product
  interaction and other usage data, for analytics, neither linked nor tracking.
  UserDefaults remains the one required-reason API it touches.
- New: `captureElementInteractions`, `capturePushNotificationOpened`,
  `tracingHeaders`, `maxQueueSize`, `eventTTL`, `maxRetries`, and `debug`.
  `flushInterval` now defaults to 10 seconds.

### 0.8.0

- The default host is now `https://i.getfounderhq.com`. `app.getfounderhq.com` no longer serves SDK ingest.
