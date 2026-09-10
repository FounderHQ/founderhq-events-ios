#if canImport(UIKit)
import Foundation
import UIKit
import XCTest
@testable import FounderHQEvents

/**
 The swizzles only exist on iOS, so `swift test` on macOS never sees them.
 This suite runs on a simulator and drives each hook the way UIKit does, so a
 broken selector lookup or a wrong method signature fails here rather than in
 a customer's app.
 */
final class UIKitCaptureTests: XCTestCase {
    private var client: FounderHQEvents?

    @MainActor
    func testEveryInteractionHookInstalls() async {
        _ = await makeClient(apiKey: "fhq_pk_uikit_install", elements: true)
        XCTAssertEqual(
            FounderHQInteractionCapture.installedHooks,
            ["sendAction", "gesture recogniser state", "sendEvent"]
        )
    }

    @MainActor
    func testATapOnAPlainViewIsCapturedWithNoTextAndNoCoordinates() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_gesture", elements: true)
        let controller = UIViewController()
        let card = UIView()
        card.accessibilityIdentifier = "plan-card"
        card.accessibilityLabel = "Growth plan"
        controller.view.addSubview(card)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        card.addGestureRecognizer(recognizer)

        recognize(recognizer, as: .ended)
        await client.readyForCapture()

        let events = try await queued(client)
        XCTAssertEqual(events.map { $0.name }, ["$autocapture"])
        let properties = try XCTUnwrap(events.first?.properties)
        let elements = try XCTUnwrap(properties["$elements"] as? [[String: Any]])
        let tapped = try XCTUnwrap(elements.first)
        XCTAssertEqual(tapped["class"] as? String, "UIView")
        XCTAssertEqual(tapped["accessibility_identifier"] as? String, "plan-card")
        XCTAssertEqual(tapped["accessibility_label"] as? String, "Growth plan")
        XCTAssertEqual(tapped["gesture"] as? String, "UITapGestureRecognizer")
        XCTAssertNil(tapped["action"])
        XCTAssertEqual(properties["$screen_name"] as? String, "UIViewController")
        XCTAssertEqual(properties["$element_path"] as? String, "UIViewController/UIView/UIView")

        let serialized = String(
            decoding: try JSONSerialization.data(withJSONObject: properties),
            as: UTF8.self
        )
        for banned in ["\"x\"", "\"y\"", "location", "frame", "text"] {
            XCTAssertFalse(serialized.contains(banned), "\(banned) in \(serialized)")
        }
    }

    /**
     An accessibility label is kept whether the app wrote it or iOS made it
     from the rendered words. Only a control that publishes a static title
     gets a `text` entry, so a plain `UILabel` still gets none.
     */
    @MainActor
    func testAnAccessibilityLabelIsKeptAndOnlyControlsGetATextEntry() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_label", elements: true)
        let controller = UIViewController()
        let headline = UILabel()
        headline.text = "Your invoice for £1,204.00"
        // UIKit only synthesises the label once accessibility is live, so the
        // test sets the value UIKit would hand back on a real screen.
        headline.accessibilityLabel = "Your invoice for £1,204.00"
        headline.accessibilityIdentifier = "invoice-headline"
        controller.view.addSubview(headline)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        headline.addGestureRecognizer(recognizer)

        recognize(recognizer, as: .ended)
        await client.readyForCapture()

        let events = try await queued(client)
        XCTAssertEqual(events.map { $0.name }, ["$autocapture"])
        let elements = try XCTUnwrap(
            events.first?.properties["$elements"] as? [[String: Any]]
        )
        let tapped = try XCTUnwrap(elements.first)
        XCTAssertEqual(tapped["accessibility_identifier"] as? String, "invoice-headline")
        XCTAssertEqual(tapped["accessibility_label"] as? String, "Your invoice for £1,204.00")
        XCTAssertNil(tapped["text"])
    }

    /// A button reports the words the person read before they tapped.
    @MainActor
    func testAButtonTitleIsCaptured() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_title", elements: true)
        let controller = UIViewController()
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout-button"
        button.setTitle("Pay £42.00 now", for: .normal)
        controller.view.addSubview(button)

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()

        let tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["class"] as? String, "UIButton")
        XCTAssertEqual(tapped["text"] as? String, "Pay £42.00 now")
        XCTAssertEqual(tapped["accessibility_identifier"] as? String, "checkout-button")
    }

    /**
     A button built with `UIButton.Configuration`, which is how Xcode has
     built one since iOS 15. Its title lives on the configuration and
     `title(for:)` returns nil, so reading only that reports no text for most
     buttons written today.
     */
    @MainActor
    func testAConfigurationButtonTitleIsCaptured() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_configured", elements: true)
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Pay now"
        let button = UIButton(configuration: configuration)

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()

        let tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["text"] as? String, "Pay now")
    }

    /// A button with no title for the state it is in falls back to another state's.
    @MainActor
    func testAButtonFallsBackToItsSelectedTitle() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_selected", elements: true)
        let button = UIButton(type: .system)
        button.setTitle("Following", for: .selected)

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()

        let tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["text"] as? String, "Following")
    }

    /// A bar button item reaches `sendAction` as itself, so it carries its own title.
    @MainActor
    func testABarButtonItemTitleIsCaptured() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_baritem", elements: true)
        let item = UIBarButtonItem(title: "Done", style: .done, target: self, action: nil)
        item.accessibilityIdentifier = "compose-done"

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: item,
            delivered: true
        )
        await client.readyForCapture()

        let tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["text"] as? String, "Done")
        XCTAssertEqual(tapped["accessibility_identifier"] as? String, "compose-done")
    }

    /// A segmented control reports the segment the person chose, and only that one.
    @MainActor
    func testASegmentedControlReportsTheSelectedSegmentOnly() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_segment", elements: true)
        let control = UISegmentedControl(items: ["Monthly", "Yearly"])
        control.selectedSegmentIndex = 1

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: control,
            delivered: true
        )
        await client.readyForCapture()

        var tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["text"] as? String, "Yearly")
        let serialized = try await serializedQueue(of: client)
        XCTAssertFalse(serialized.contains("Monthly"), serialized)

        control.selectedSegmentIndex = UISegmentedControl.noSegment
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: control,
            delivered: true
        )
        await client.readyForCapture()
        let events = try await queued(client)
        XCTAssertEqual(events.count, 2)
        tapped = try XCTUnwrap(
            (events.last?.properties["$elements"] as? [[String: Any]])?.first
        )
        XCTAssertNil(tapped["text"])
    }

    /// Line breaks fold into single spaces and a long title is cut to 255 characters.
    @MainActor
    func testACapturedTitleIsFoldedAndCut() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_fold", elements: true)
        let button = UIButton(type: .system)
        button.setTitle("  Start\n\n  your   free trial  ", for: .normal)
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()
        var tapped = try await firstElement(of: client)
        XCTAssertEqual(tapped["text"] as? String, "Start your free trial")

        let long = UIButton(type: .system)
        long.setTitle(String(repeating: "a", count: 400), for: .normal)
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: long,
            delivered: true
        )
        await client.readyForCapture()
        let events = try await queued(client)
        tapped = try XCTUnwrap(
            (events.last?.properties["$elements"] as? [[String: Any]])?.first
        )
        XCTAssertEqual((tapped["text"] as? String)?.count, 255)
    }

    /**
     What a person types is still refused outright. A text field, a text view,
     and a search bar are turned away before any property of theirs is read,
     so neither a value nor a placeholder can reach the queue.
     */
    @MainActor
    func testATextFieldsContentsAreNeverCaptured() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_typed", elements: true)
        let controller = UIViewController()

        let field = UITextField()
        field.text = "ayush@example.com"
        field.placeholder = "Work email"
        field.accessibilityIdentifier = "email-field"
        controller.view.addSubview(field)
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: field,
            delivered: true
        )

        let notes = UITextView()
        notes.text = "Card 4242 4242 4242 4242"
        controller.view.addSubview(notes)
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: notes,
            delivered: true
        )

        let search = UISearchBar()
        search.text = "divorce lawyer"
        controller.view.addSubview(search)
        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: search,
            delivered: true
        )

        await client.readyForCapture()
        let events = try await queued(client)
        XCTAssertEqual(events.map { $0.name }, [])
        let serialized = try await serializedQueue(of: client)
        for secret in [
            "ayush@example.com", "Work email", "4242", "divorce lawyer", "email-field",
        ] {
            XCTAssertFalse(serialized.contains(secret), "\(secret) in \(serialized)")
        }
    }

    /// Remote `autocapture: false` wins over a local `captureElementInteractions: true`.
    @MainActor
    func testRemoteConfigTurnsElementCaptureOff() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_remote_off", elements: true)
        let button = UIButton(type: .system)
        button.setTitle("Upgrade", for: .normal)

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()
        var names = try await queued(client).map { $0.name }
        XCTAssertEqual(names, ["$autocapture"])
        XCTAssertTrue(client.elementCaptureEnabled)

        await client.applyRemoteConfig(["autocapture": false])
        XCTAssertFalse(client.elementCaptureEnabled)
        XCTAssertFalse(client.rageClickCaptureEnabled)
        // What was already queued goes too, the way a disabled screen does.
        names = try await queued(client).map { $0.name }
        XCTAssertEqual(names, [])

        FounderHQInteractionCapture.sent(
            action: #selector(handleTap),
            sender: button,
            delivered: true
        )
        await client.readyForCapture()
        names = try await queued(client).map { $0.name }
        XCTAssertEqual(names, [])
    }

    /// Rage clicks can be switched off on their own, leaving taps captured.
    @MainActor
    func testRemoteConfigTurnsRageClicksOffOnTheirOwn() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_remote_rage", elements: true)
        await client.applyRemoteConfig(["capture_rageclicks": false])
        XCTAssertTrue(client.elementCaptureEnabled)
        XCTAssertFalse(client.rageClickCaptureEnabled)

        let controller = UIViewController()
        let stuck = UIView()
        controller.view.addSubview(stuck)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        stuck.addGestureRecognizer(recognizer)
        for tap in 0..<3 {
            FounderHQInteractionCapture.duringTouch(token: 5_000 + Double(tap)) {
                self.recognize(recognizer, as: .ended)
            }
        }
        await client.readyForCapture()
        let names = try await queued(client).map { $0.name }
        XCTAssertEqual(names, ["$autocapture", "$autocapture", "$autocapture"])
    }

    /**
     The operator's setting wins in both directions. A shipped app cannot be
     rebuilt on demand, so a wrong default has to be fixable from the
     dashboard. The local flag is only what holds until settings arrive.
     */
    @MainActor
    func testRemoteConfigTurnsElementCaptureOnWhereTheAppShippedItOff() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_remote_on", elements: false)
        XCTAssertFalse(client.elementCaptureEnabled)

        await client.applyRemoteConfig([
            "autocapture": true,
            "capture_rageclicks": true,
        ])
        XCTAssertTrue(client.elementCaptureEnabled)
        XCTAssertTrue(client.rageClickCaptureEnabled)

        // And with no setting at all, the app's own default holds.
        await client.applyRemoteConfig([:])
        XCTAssertFalse(client.elementCaptureEnabled)
    }

    /// A control's own action tells a richer story, so the recogniser stands aside.
    @MainActor
    func testARecogniserOnAControlIsLeftToTheActionHook() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_control", elements: true)
        let controller = UIViewController()
        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout-button"
        controller.view.addSubview(button)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        button.addGestureRecognizer(recognizer)

        recognize(recognizer, as: .ended)
        await client.readyForCapture()

        let events = try await queued(client)
        XCTAssertEqual(events.map { $0.name }, [])
    }

    @MainActor
    func testAScrollGestureAndATextFieldAreNeverCaptured() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_quiet", elements: true)
        let controller = UIViewController()

        let scroller = UIView()
        controller.view.addSubview(scroller)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleTap))
        scroller.addGestureRecognizer(pan)
        recognize(pan, as: .ended)

        let field = UITextField()
        controller.view.addSubview(field)
        let fieldTap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        field.addGestureRecognizer(fieldTap)
        recognize(fieldTap, as: .ended)

        await client.readyForCapture()
        let events = try await queued(client)
        XCTAssertEqual(events.map { $0.name }, [])
    }

    /**
     One physical tap can reach several recognisers at once, and on a control
     it reaches the action hook too. Only one `$autocapture` may come out.
     */
    @MainActor
    func testOnePhysicalTapNeverProducesTwoAutocaptureEvents() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_dedupe", elements: true)
        let controller = UIViewController()
        let row = UIView()
        row.accessibilityIdentifier = "row"
        controller.view.addSubview(row)
        let first = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let second = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        row.addGestureRecognizer(first)
        row.addGestureRecognizer(second)

        FounderHQInteractionCapture.duringTouch(token: 1_000.5) {
            self.recognize(first, as: .ended)
            self.recognize(second, as: .ended)
        }
        await client.readyForCapture()
        let afterOneTouch = try await queued(client)
        XCTAssertEqual(afterOneTouch.map { $0.name }, ["$autocapture"])

        // The next physical tap is a different touch, so it reports again.
        FounderHQInteractionCapture.duringTouch(token: 1_001.5) {
            self.recognize(first, as: .ended)
        }
        await client.readyForCapture()
        let afterSecondTouch = try await queued(client)
        XCTAssertEqual(afterSecondTouch.map { $0.name }, ["$autocapture", "$autocapture"])
    }

    @MainActor
    func testThreeTapsOnOneElementProduceARageClick() async throws {
        let client = await makeClient(apiKey: "fhq_pk_uikit_rage", elements: true)
        let controller = UIViewController()
        let stuck = UIView()
        stuck.accessibilityIdentifier = "stuck-tile"
        controller.view.addSubview(stuck)
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        stuck.addGestureRecognizer(recognizer)

        for tap in 0..<3 {
            FounderHQInteractionCapture.duringTouch(token: 2_000 + Double(tap)) {
                self.recognize(recognizer, as: .ended)
            }
        }
        await client.readyForCapture()

        let events = try await queued(client)
        XCTAssertEqual(
            events.map { $0.name },
            ["$autocapture", "$autocapture", "$autocapture", "$rageclick"]
        )
        let rage = try XCTUnwrap(events.last?.properties)
        let elements = try XCTUnwrap(rage["$elements"] as? [[String: Any]])
        XCTAssertEqual(elements.first?["accessibility_identifier"] as? String, "stuck-tile")
    }

    @MainActor
    func testALiteralURLSessionRequestCarriesTheSessionHeaderForListedHostsOnly() async {
        let client = await makeClient(
            apiKey: "fhq_pk_uikit_tracing",
            elements: false,
            tracingHeaders: ["api.example.com"]
        )
        let sessionId = client.currentTracingSessionId()
        XCTAssertNotNil(sessionId)

        let tagged = URLSession.shared.dataTask(
            with: URLRequest(url: URL(string: "https://api.example.com/orders")!)
        )
        tagged.cancel()
        XCTAssertEqual(
            tagged.originalRequest?.value(forHTTPHeaderField: FounderHQSessionIdHeader),
            sessionId
        )

        let untouched = URLSession.shared.dataTask(
            with: URLRequest(url: URL(string: "https://ads.example.net/pixel")!)
        )
        untouched.cancel()
        XCTAssertNil(
            untouched.originalRequest?.value(forHTTPHeaderField: FounderHQSessionIdHeader)
        )
    }

    // MARK: - Helpers

    @objc private func handleTap() {}

    /// Drives a recogniser to a state the way UIKit does, through `setState:`.
    @MainActor
    private func recognize(_ recognizer: UIGestureRecognizer, as state: UIGestureRecognizer.State) {
        recognizer.setValue(state.rawValue, forKey: "state")
    }

    @MainActor
    private func makeClient(
        apiKey: String,
        elements: Bool,
        tracingHeaders: [String]? = nil
    ) async -> FounderHQEvents {
        let client = FounderHQEvents(
            apiKey: apiKey,
            configuration: .init(
                flushAt: 1_000,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                captureElementInteractions: elements,
                tracingHeaders: tracingHeaders,
                capturePushNotificationOpened: false,
                debug: true
            ),
            dependencies: .init(
                storage: UIKitTestStorage(),
                transport: UIKitSilentTransport()
            )
        )
        self.client = client
        await client.readyForCapture()
        return client
    }

    @MainActor
    private func firstElement(of client: FounderHQEvents) async throws -> [String: Any] {
        let events = try await queued(client)
        let elements = try XCTUnwrap(events.first?.properties["$elements"] as? [[String: Any]])
        return try XCTUnwrap(elements.first)
    }

    private func serializedQueue(of client: FounderHQEvents) async throws -> String {
        let persisted = await client.persistedStateData()
        let data = try XCTUnwrap(persisted)
        return String(decoding: data, as: UTF8.self)
    }

    private func queued(
        _ client: FounderHQEvents
    ) async throws -> [(name: String, properties: [String: Any])] {
        let persisted = await client.persistedStateData()
        let data = try XCTUnwrap(persisted)
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let queue = try XCTUnwrap(state["queue"] as? [[String: Any]])
        return queue.compactMap { event in
            guard let name = event["event"] as? String else { return nil }
            return (name, event["properties"] as? [String: Any] ?? [:])
        }
    }
}

private final class UIKitTestStorage: FounderHQStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return dataValues[key]
    }
    func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stringValues[key]
    }
    func set(_ data: Data?, forKey key: String) {
        lock.lock(); dataValues[key] = data; lock.unlock()
    }
    func set(_ value: String?, forKey key: String) {
        lock.lock(); stringValues[key] = value; lock.unlock()
    }
}

/// Nothing may leave the simulator during a test, so every send fails.
private final class UIKitSilentTransport: FounderHQTransport, @unchecked Sendable {
    func send(_: URLRequest) async throws -> FounderHQTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}
#endif
