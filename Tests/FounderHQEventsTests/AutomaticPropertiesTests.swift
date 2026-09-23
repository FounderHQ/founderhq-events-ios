import Foundation
import XCTest
@testable import FounderHQEvents
#if canImport(UIKit)
import UIKit
#endif

final class AutomaticPropertiesTests: XCTestCase {
    func testSanitizerRejectsInvalidKeysAndValuesAndKeepsFirstValidValue() {
        let result = sanitizeAutomaticProperties([
            ("", .string("empty key")), (String(repeating: "a", count: 65), .bool(true)),
            ("$reserved", .string("no")), ("nan", .number(.nan)),
            ("infinity", .number(.infinity)), ("negative_infinity", .number(-.infinity)),
            ("object", .object([:])), ("array", .array([])), ("null", .null),
            ("first", .null), ("first", .string(" valid ")), ("first", .string("later")),
            ("number", .number(12.5)), ("bool", .bool(false)), ("blank", .string(" \n ")),
            ("Case-Kept", .string(" yes ")),
            (String(repeating: "k", count: 64), .bool(true)),
            ("long", .string(" \n" + String(repeating: "x", count: 210) + " \n")),
        ])
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result["first"], .string("valid"))
        XCTAssertEqual(result["number"], .number(12.5))
        XCTAssertEqual(result["bool"], .bool(false))
        XCTAssertEqual(result["blank"], .string(""))
        XCTAssertEqual(result["Case-Kept"], .string("yes"))
        XCTAssertEqual(result["long"], .string(String(repeating: "x", count: 200)))
    }

    @MainActor
    func testSharedLimitPrioritizesDeclarativeBeforeCallback() {
        let helper = FounderHQAutomaticProperties(hook: { _ in
            Dictionary(uniqueKeysWithValues: (0..<30).map { ("callback_\($0)", $0 as Any) })
        })
        let declarative = (0..<19).map { ("view_\($0)", JSONValue.number(Double($0))) }
        let result = helper.properties(event: "$autocapture", declarative: declarative)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result["callback_0"], .number(0))
        for (key, value) in declarative { XCTAssertEqual(result[key], value) }
    }

    @MainActor
    func testThrowWarnsOncePerInstanceAndPreservesDeclarativeProperties() {
        let warnings = HookRecorder()
        let hook: FounderHQAutoProperties = { _ in throw HookFailure.failed }
        let helper = FounderHQAutomaticProperties(hook: hook, warning: { warnings.warn($0) })
        for _ in 0..<3 {
            XCTAssertEqual(helper.properties(event: "$autocapture", declarative: [("sku", .string("one"))]),
                           ["sku": .string("one")])
        }
        XCTAssertEqual(warnings.warnings.count, 1)
        let other = FounderHQAutomaticProperties(hook: hook, warning: { warnings.warn($0) })
        _ = other.properties(event: "$screen")
        XCTAssertEqual(warnings.warnings.count, 2)
    }

    @MainActor
    func testScreensReceiveContextExplicitPropertiesWinAndOtherEventsSkipHook() async throws {
        var contexts: [FounderHQAutoPropertiesContext] = []
        let recorder = HookRecorder()
        let client = makePropertiesClient(autoProperties: { context in
            contexts.append(context)
            return ["plan": "callback", "added": true, "$screen_name": "forbidden"]
        }, beforeSend: { event in
            recorder.record(event)
            return event
        }, lifecycle: true, sessions: true)
        await client.screenAndWait("Pricing", properties: ["plan": "explicit", "$screen_name": "forged", "$screen_id": "forged"])
        await client.captureAndWait("custom")
        await client.captureAndWait("$screen")
        await client.recordLifecycleAndWait("active")
        await client.identifyAndWait("user_42")
        await client.captureAndWait("$push_notification_opened")
        XCTAssertEqual(contexts.map(\.event), ["$screen"])
        XCTAssertEqual(contexts.first?.screenName, "Pricing")
        XCTAssertNil(contexts.first?.element)
        XCTAssertNil(contexts.first?.elementDescription)
        let events = try await propertiesQueue(client)
        let screen = try XCTUnwrap(events.first { $0.event == "$screen" })
        XCTAssertEqual(screen.properties["plan"], .string("explicit"))
        XCTAssertEqual(screen.properties["added"], .bool(true))
        XCTAssertEqual(screen.properties["$screen_name"], .string("Pricing"))
        XCTAssertNotEqual(screen.properties["$screen_id"], .string("forged"))
        XCTAssertEqual(recorder.events.count, events.count)
        XCTAssertTrue(recorder.events.contains { $0.event == "$session_start" })
        XCTAssertTrue(recorder.events.contains { $0.event == "$application_opened" })
        XCTAssertTrue(recorder.events.contains { $0.event == "$identify" })
        XCTAssertTrue(events.filter { $0.event != "$screen" }.allSatisfy { $0.properties["added"] == nil })
    }

    @MainActor
    func testNilAndThrowingHooksStillQueueScreens() async throws {
        for hook: FounderHQAutoProperties in [{ _ in nil }, { _ in throw HookFailure.failed }] {
            let client = makePropertiesClient(autoProperties: hook)
            await client.screenAndWait("First")
            await client.screenAndWait("Second")
            let events = try await propertiesQueue(client)
            XCTAssertEqual(events.map(\.event), ["$screen", "$screen"])
        }
    }

    @MainActor
    func testBeforeSendSeesFinishedEventAndCanChangeIt() async throws {
        let client = makePropertiesClient(autoProperties: { _ in ["added": true] }, beforeSend: { event in
            XCTAssertEqual(event.properties["added"], .bool(true))
            XCTAssertEqual(event.properties["plan"], .string("explicit"))
            XCTAssertEqual(event.properties["$platform"], .string("ios"))
            XCTAssertNotNil(UUID(uuidString: event.uuid))
            var changed = event
            changed.event = "renamed"
            changed.properties["added"] = .bool(false)
            return changed
        })
        await client.screenAndWait("Pricing", properties: ["plan": "explicit"])
        let events = try await propertiesQueue(client)
        XCTAssertEqual(events.map(\.event), ["renamed"])
        XCTAssertEqual(events.first?.properties["added"], .bool(false))
    }

    @MainActor
    func testBeforeSendNilThrowAndInvalidResultsDropEvents() async throws {
        let hooks: [FounderHQBeforeSend] = [
            { _ in nil }, { _ in throw HookFailure.failed },
            { var e = $0; e.uuid = "invalid"; return e },
            { var e = $0; e.timestamp = "tomorrow"; return e },
            { var e = $0; e.timestamp += "trailing"; return e },
            { var e = $0; e.event = ""; return e },
            { var e = $0; e.event = "$not_reserved"; return e },
            { var e = $0; e.distinctId = ""; return e },
            { var e = $0; e.properties["bad"] = .number(.infinity); return e },
        ]
        for hook in hooks {
            let client = makePropertiesClient(beforeSend: hook)
            await client.captureAndWait("custom")
            await client.screenAndWait("Pricing")
            let events = try await propertiesQueue(client)
            XCTAssertTrue(events.isEmpty)
        }
    }

    @MainActor
    func testPurchaseControlEventsBypassBeforeSend() async throws {
        let hooks: [FounderHQBeforeSend] = [
            { _ in nil },
            { _ in throw HookFailure.failed },
            { var event = $0; event.event = "reshaped"; event.properties = [:]; return event },
        ]
        for hook in hooks {
            let recorder = HookRecorder()
            let client = makePropertiesClient(beforeSend: { event in
                recorder.record(event)
                return try hook(event)
            })
            await client.readyForCapture()
            let prepared = try await client.preparePurchase(source: .storeKit)
            try await client.observePurchase(.init(
                source: .storeKit, store: "APP_STORE", transactionId: "test-transaction"
            ), prepared: prepared)
            XCTAssertTrue(recorder.events.isEmpty)
            let events = try await propertiesQueue(client)
            XCTAssertEqual(events.map(\.event), ["$mobile_purchase_prepared", "$mobile_purchase_claim"])
            XCTAssertTrue(events.allSatisfy { !$0.properties.isEmpty })
        }
    }

    @MainActor
    func testScreenOwnedPropertiesStayAuthoritativeWithoutNewOptions() async throws {
        let client = makePropertiesClient()
        await client.screenAndWait("Pricing", properties: [
            "$screen_name": "forged", "$screen_id": "forged", "plan": "explicit",
        ])
        let events = try await propertiesQueue(client)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.properties["$screen_name"], .string("Pricing"))
        XCTAssertNotEqual(event.properties["$screen_id"], .string("forged"))
        XCTAssertEqual(event.properties["plan"], .string("explicit"))
    }

    @MainActor
    func testAppearanceIsReadForEachScreenAndOmittedElsewhere() async throws {
        let appearance = TestAppearance()
        let client = makePropertiesClient(colorScheme: { appearance.scheme })
        await client.screenAndWait("Dark")
        appearance.scheme = "light"
        await client.screenAndWait("Light")
        appearance.scheme = nil
        await client.screenAndWait("Unknown")
        await client.captureAndWait("custom")
        let events = try await propertiesQueue(client)
        XCTAssertEqual(events.map { $0.properties["$prefers_color_scheme"] }, [.string("dark"), .string("light"), nil, nil])
    }

    @MainActor
    func testExplicitScreenPropertiesAreNotLimitedAndRemoteConfigKeepsHook() async throws {
        let client = makePropertiesClient(autoProperties: { _ in ["added": true] })
        await client.readyForCapture()
        await client.applyRemoteConfig(["capture_screens": false])
        await client.screenAndWait("Disabled")
        await client.applyRemoteConfig(["capture_screens": true])
        var explicit: JSONObject = Dictionary(uniqueKeysWithValues: (0..<25).map { ("key_\($0)", .number(Double($0))) })
        explicit["$prefers_color_scheme"] = .string("explicit")
        await client.screenAndWait("Enabled", properties: explicit)
        let events = try await propertiesQueue(client)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.properties["added"], .bool(true))
        XCTAssertEqual(events.first?.properties["$prefers_color_scheme"], .string("explicit"))
        for key in explicit.keys { XCTAssertNotNil(events.first?.properties[key]) }
    }

    #if canImport(UIKit)
    @MainActor
    func testUIKitAutomaticScreenUsesHookAndAppearanceMapping() async throws {
        var names: [String?] = []
        let client = makePropertiesClient(autoProperties: { names.append($0.screenName); return nil })
        await client.readyForCapture()
        FounderHQScreenCapture.install(client: client)
        let controller = UIViewController()
        controller.title = "Automatic"
        FounderHQScreenCapture.appeared(controller)
        await client.readyForCapture()
        XCTAssertEqual(names, ["Automatic"])
        XCTAssertEqual(founderHQColorScheme(.dark), "dark")
        XCTAssertEqual(founderHQColorScheme(.light), "light")
        XCTAssertNil(founderHQColorScheme(.unspecified))
    }

    @MainActor
    func testDefaultAppearanceReadsTheLastAppearedControllersRealTraits() throws {
        // Real UIKit traits, not an injected string: a window forced dark
        // must read as dark whatever the system says, and read so outside
        // any trait callback — the SDK reads it after an asynchronous hop.
        for (style, expected) in [(UIUserInterfaceStyle.dark, "dark"), (.light, "light")] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.overrideUserInterfaceStyle = style
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.loadViewIfNeeded()
            FounderHQScreenCapture.appeared(controller)
            XCTAssertEqual(founderHQSystemColorScheme(), expected)
        }
    }

    @MainActor
    func testScreenTrackingContinuesWhenEventsAreDisabledOrConsentIsOff() async throws {
        for automatic in [false, true] {
            var contexts: [FounderHQAutoPropertiesContext] = []
            let installer = TrackingScreenInstaller()
            let client = makePropertiesClient(autoProperties: {
                contexts.append($0)
                return nil
            }, elements: true, screens: false, screenCapture: installer)
            await client.readyForCapture()
            XCTAssertEqual(installer.installCount, 1)
            FounderHQScreenCapture.install(client: client)
            func observe(_ name: String) async {
                if automatic {
                    let controller = UIViewController()
                    controller.title = name
                    FounderHQScreenCapture.appeared(controller)
                    await client.readyForCapture()
                } else {
                    await client.screenAndWait(name)
                }
            }
            await observe("Capture disabled")
            let button = UIButton()
            client.captureInteraction("$autocapture", element: button, properties: [:])
            await client.readyForCapture()
            XCTAssertEqual(contexts.last?.screenName, "Capture disabled")
            await client.applyRemoteConfig(["capture_screens": true])
            await client.optOutAndWait()
            await observe("Consent disabled")
            await client.optInAndWait()
            client.captureInteraction("$autocapture", element: button, properties: [:])
            await client.readyForCapture()
            XCTAssertEqual(contexts.map(\.screenName), ["Capture disabled", "Consent disabled"])
            let events = try await propertiesQueue(client)
            XCTAssertTrue(events.allSatisfy { $0.event == "$autocapture" })
        }
    }

    @MainActor
    func testTapWithoutScreenHasNilContextAndDeclarativeCapAppliesToQueuedEvent() async throws {
        var contexts: [FounderHQAutoPropertiesContext] = []
        let client = makePropertiesClient(autoProperties: {
            contexts.append($0)
            return ["callback": "loses budget"]
        }, elements: true)
        await client.readyForCapture()
        let button = UIButton()
        button.fhqProperties = Dictionary(uniqueKeysWithValues: (0..<25).map { ("key_\($0)", $0) })
        FounderHQInteractionCapture.install(client: client, debug: false)
        FounderHQInteractionCapture.sent(action: NSSelectorFromString("buy"), sender: button, delivered: true)
        await client.readyForCapture()
        let events = try await propertiesQueue(client)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.properties.keys.filter { $0.hasPrefix("key_") }.count, 20)
        XCTAssertNil(event.properties["callback"])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertNil(contexts.first?.screenName)
        XCTAssertTrue(contexts.first?.element === button)
    }

    @MainActor
    func testTapAndRageContextsAndAllAncestorsNearestValidValueWins() async throws {
        var contexts: [FounderHQAutoPropertiesContext] = []
        let client = makePropertiesClient(autoProperties: {
            contexts.append($0)
            return ["product_id": "callback", "callback_only": true]
        }, elements: true)
        await client.screenAndWait("Shop")
        let root = UIView()
        root.fhqProperties = ["root_only": "yes", "product_id": "root", "fallback": "valid"]
        var parent = root
        for _ in 0..<8 {
            let child = UIView()
            parent.addSubview(child)
            parent = child
        }
        parent.fhqProperties = ["product_id": "parent", "fallback": NSNull()]
        let button = UIButton()
        button.fhqProperties = ["product_id": "nearest", "fallback": [1, 2]]
        button.accessibilityIdentifier = "buy"
        parent.addSubview(button)
        FounderHQInteractionCapture.install(client: client, debug: false)
        for _ in 0..<3 {
            FounderHQInteractionCapture.sent(action: NSSelectorFromString("buy"), sender: button, delivered: true)
        }
        await client.readyForCapture()
        let events = try await propertiesQueue(client).filter { $0.event != "$screen" }
        XCTAssertEqual(events.filter { $0.event == "$autocapture" }.count, 3)
        XCTAssertEqual(events.filter { $0.event == "$rageclick" }.count, 1)
        for (event, context) in zip(events, contexts.dropFirst()) {
            XCTAssertEqual(context.event, event.event)
            XCTAssertEqual(context.screenName, "Shop")
            XCTAssertTrue(context.element === button)
            if case .array(let elements) = event.properties["$elements"] {
                XCTAssertEqual(elements.first, context.elementDescription.map(JSONValue.object))
                XCTAssertEqual(elements.count, 5)
            } else { XCTFail("Missing elements") }
            XCTAssertEqual(event.properties["product_id"], .string("nearest"))
            XCTAssertEqual(event.properties["root_only"], .string("yes"))
            XCTAssertEqual(event.properties["fallback"], .string("valid"))
            XCTAssertEqual(event.properties["callback_only"], .bool(true))
            XCTAssertNil(event.properties["$prefers_color_scheme"])
        }
    }

    #endif
}

@MainActor
private final class TestAppearance { var scheme: String? = "dark" }

private enum HookFailure: Error { case failed }

private final class HookRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [FounderHQEvent] = []
    private var messages: [String] = []
    var events: [FounderHQEvent] { lock.lock(); defer { lock.unlock() }; return captured }
    var warnings: [String] { lock.lock(); defer { lock.unlock() }; return messages }
    func record(_ event: FounderHQEvent) { lock.lock(); defer { lock.unlock() }; captured.append(event) }
    func warn(_ message: String) { lock.lock(); defer { lock.unlock() }; messages.append(message) }
}

@MainActor
func makePropertiesClient(
    autoProperties: FounderHQAutoProperties? = nil,
    beforeSend: FounderHQBeforeSend? = nil,
    lifecycle: Bool = false,
    sessions: Bool = false,
    elements: Bool = false,
    clock: any FounderHQClock = FounderHQSystemClock(),
    transport: any FounderHQTransport = PropertiesTransport(),
    screens: Bool = true,
    optedOut: Bool = false,
    screenCapture: any FounderHQScreenCaptureInstalling = PropertiesScreens(),
    colorScheme: @escaping @MainActor @Sendable () -> String? = { nil }
) -> FounderHQEvents {
    FounderHQEvents(apiKey: "fhq_pk_properties", configuration: .init(
        flushAt: 1_000, flushInterval: 0, optOutByDefault: optedOut, captureLifecycle: lifecycle, captureScreens: screens,
        captureSessions: sessions, captureInstallUpdates: false, remoteConfig: false,
        captureElementInteractions: elements, capturePushNotificationOpened: false,
        autoProperties: autoProperties, beforeSend: beforeSend
    ), dependencies: .init(
        clock: clock, storage: PropertiesStorage(), transport: transport,
        platformFacts: PropertiesFacts(), screenCapture: screenCapture, colorScheme: colorScheme
    ))
}

func propertiesQueue(_ client: FounderHQEvents) async throws -> [FounderHQEvent] {
    struct State: Decodable { let queue: [FounderHQEvent] }
    let data = await client.persistedStateData()
    return try JSONDecoder().decode(State.self, from: XCTUnwrap(data)).queue
}

private struct PropertiesFacts: FounderHQPlatformFactsProvider {
    func properties() -> JSONObject { ["plan": .string("automatic")] }
}
struct PropertiesScreens: FounderHQScreenCaptureInstalling {
    func install(client: FounderHQEvents) {}
}
struct PropertiesTransport: FounderHQTransport {
    func send(_ request: URLRequest) async throws -> FounderHQTransportResponse { throw URLError(.notConnectedToInternet) }
}
private final class PropertiesStorage: FounderHQStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return dataValues[key] }
    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return stringValues[key] }
    func set(_ data: Data?, forKey key: String) { lock.lock(); defer { lock.unlock() }; dataValues[key] = data }
    func set(_ value: String?, forKey key: String) { lock.lock(); defer { lock.unlock() }; stringValues[key] = value }
}

private final class TrackingScreenInstaller: FounderHQScreenCaptureInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var installCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    // Intentionally nonisolated: existing conformers and callers retain this API.
    func install(client: FounderHQEvents) { lock.lock(); defer { lock.unlock() }; count += 1 }
}
