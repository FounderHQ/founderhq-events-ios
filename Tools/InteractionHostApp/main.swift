// A throwaway iOS app whose only job is to give the SDK a live
// `UIApplication`. The XCTest bundle runs without one, so
// `UIApplication.sendAction` — the hook that catches every UIControl and bar
// button tap — cannot be driven there. This app taps a real button, a real
// bar button item, and a real text field, then prints one line per check.
//
// Build and run it with `Tools/run-interaction-host-app.sh`.
// The script compiles this file together with the SDK sources, so there is
// no module to import.
import UIKit

private var failures = 0

private func check(_ passed: Bool, _ what: String) {
    if !passed { failures += 1 }
    print("\(passed ? "PASS" : "FAIL") \(what)")
}

private final class ProbeStorage: FounderHQStorage, @unchecked Sendable {
    private var dataValues: [String: Data] = [:]
    private var stringValues: [String: String] = [:]
    func data(forKey key: String) -> Data? { dataValues[key] }
    func string(forKey key: String) -> String? { stringValues[key] }
    func set(_ data: Data?, forKey key: String) { dataValues[key] = data }
    func set(_ value: String?, forKey key: String) { stringValues[key] = value }
}

private final class OfflineTransport: FounderHQTransport, @unchecked Sendable {
    func send(_: URLRequest) async throws -> FounderHQTransportResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private final class Delegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        Task { @MainActor in await self.run(on: controller) }
        return true
    }

    @objc private func handleTap() {}

    @MainActor
    private func run(on controller: UIViewController) async {
        let client = FounderHQEvents(
            apiKey: "fhq_pk_interaction_host",
            configuration: .init(
                flushAt: 1_000,
                flushInterval: 0,
                captureLifecycle: false,
                captureScreens: false,
                captureSessions: false,
                captureInstallUpdates: false,
                remoteConfig: false,
                captureElementInteractions: true,
                capturePushNotificationOpened: false,
                debug: true
            ),
            dependencies: .init(storage: ProbeStorage(), transport: OfflineTransport())
        )
        await client.readyForCapture()

        let button = UIButton(type: .system)
        button.accessibilityIdentifier = "checkout-button"
        button.setTitle("Pay £42.00 now", for: .normal)
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        controller.view.addSubview(button)
        button.sendActions(for: .touchUpInside)
        await client.readyForCapture()

        var events = await queued(client)
        check(events.map(\.name) == ["$autocapture"], "a real UIControl tap reaches sendAction")
        let element = (events.first?.properties["$elements"] as? [[String: Any]])?.first ?? [:]
        check(element["class"] as? String == "UIButton", "the element class is the control")
        check(
            element["accessibility_identifier"] as? String == "checkout-button",
            "the accessibility identifier survives"
        )
        check(element["action"] as? String == "handleTap", "the action selector survives")
        check(element["enabled"] as? Bool == true, "the enabled state survives")
        check(
            element["text"] as? String == "Pay £42.00 now",
            "the button title is captured"
        )

        // Three taps in a second on the same control are a rage tap.
        button.sendActions(for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        await client.readyForCapture()
        events = await queued(client)
        check(
            events.map(\.name) == [
                "$autocapture", "$autocapture", "$autocapture", "$rageclick",
            ],
            "three taps on one control raise a rage click"
        )

        // A text field's own action must never be reported.
        let field = UITextField()
        field.text = "ayush@example.com"
        field.placeholder = "Work email"
        field.accessibilityIdentifier = "email-field"
        field.addTarget(self, action: #selector(handleTap), for: .editingChanged)
        controller.view.addSubview(field)
        field.sendActions(for: .editingChanged)
        await client.readyForCapture()
        let afterTyping = await queued(client)
        check(afterTyping.count == events.count, "a text field keystroke is never captured")

        // Nothing the person typed may appear anywhere in the stored queue.
        let stored = String(
            decoding: (await client.persistedStateData()) ?? Data(),
            as: UTF8.self
        )
        check(
            !stored.contains("ayush@example.com"),
            "a text field's contents are never captured"
        )
        check(
            !stored.contains("Work email") && !stored.contains("email-field"),
            "a text field's placeholder and identifier are never captured"
        )

        // A modern button, built the way Xcode's own templates build one since
        // iOS 15. Its title lives on the configuration, and `title(for:)`
        // returns nil for it, so this is the shape that silently reported no
        // text until `renderedText` learned to read the configuration.
        if #available(iOS 15.0, *) {
            var modern = UIButton.Configuration.filled()
            modern.title = "Pay now"
            let configured = UIButton(configuration: modern)
            configured.accessibilityIdentifier = "configured-button"
            configured.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
            controller.view.addSubview(configured)
            configured.sendActions(for: .touchUpInside)
            await client.readyForCapture()
            let configuredEvents = await queued(client)
            let configuredElement =
                (configuredEvents.last?.properties["$elements"] as? [[String: Any]])?.first ?? [:]
            check(
                configuredElement["text"] as? String == "Pay now",
                "a UIButton.Configuration title is captured"
            )
            configured.removeFromSuperview()
        }

        print(failures == 0 ? "HOST APP RESULT: PASS" : "HOST APP RESULT: \(failures) FAILURE(S)")
        exit(failures == 0 ? 0 : 1)
    }

    private func queued(
        _ client: FounderHQEvents
    ) async -> [(name: String, properties: [String: Any])] {
        guard let data = await client.persistedStateData(),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = state["queue"] as? [[String: Any]]
        else { return [] }
        return queue.compactMap { event in
            guard let name = event["event"] as? String else { return nil }
            return (name, event["properties"] as? [String: Any] ?? [:])
        }
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(Delegate.self)
)
