#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime

/**
 Semantic tap capture. It listens in three places, because no single one sees
 every tap in a modern app:

 - `UIApplication.sendAction`, which every `UIControl` action and every bar
   button item passes through.
 - `UIGestureRecognizer.state`, which is how a tap on a plain `UIView`, a
   table row accessory, or a SwiftUI element reports itself. This follows the
   posthog-ios approach.
 - `UIWindow.sendEvent`, which is only read, never acted on. It tells the
   other two which touch they are inside, so one physical tap can never
   produce two `$autocapture` events.

 What it stores about the tapped element: the class name, the accessibility
 identifier, the accessibility label, the label a button, bar button, or
 segmented control renders, the enabled/selected state, the action selector or
 the recogniser class, and the class names of the view hierarchy above it.

 The rendered label is the wording the person chose to act on, so it is what
 makes a tap readable in a report. It is read only from a control that
 publishes a static title, and it matches what posthog-ios captures.

 What it refuses to store: anything a person typed, and the tap coordinates.
 Text fields, text views, and search bars are skipped whole, so a keystroke,
 a value, or a placeholder never reaches the queue.
 */
enum FounderHQInteractionCapture {
    /// A rage tap is three taps on one element inside this many seconds.
    private static let rageWindow =
        TimeInterval(FounderHQProtocolConstants.rageWindowMillis) / 1000
    private static let rageTapCount = FounderHQProtocolConstants.rageTapCount
    /// The tapped element and its parents together, capped as every SDK caps it.
    private static let maxElements = FounderHQProtocolConstants.elementAncestorLimit
    /// The cap posthog-js puts on a captured element text.
    private static let maxTextLength = FounderHQProtocolConstants.elementTextMaxLength

    private static weak var client: FounderHQEvents?
    private static var installed = false
    /// The hooks that really went in. Read by the tests, which is the only way
    /// to prove a runtime lookup like `setState:` still resolves.
    private(set) static var installedHooks: Set<String> = []
    private static var debug = false
    private static var recentTaps: [RecentTap] = []
    private static var lastRageTapAt: TimeInterval = 0

    /**
     The timestamp of the touch UIKit is delivering right now, or nil when the
     capture did not come from a touch at all — a `sendAction` the app made
     itself, for instance. UIKit delivers touches on the main thread and one
     at a time, so a plain static is enough state here.
     */
    private static var currentTouchToken: TimeInterval?
    /// The touch that already produced an `$autocapture` event.
    private static var lastReportedTouchToken: TimeInterval?

    static func install(client: FounderHQEvents, debug: Bool) {
        self.client = client
        self.debug = debug
        guard !installed else { return }
        installed = true
        exchange(
            UIApplication.self,
            #selector(UIApplication.sendAction(_:to:from:for:)),
            #selector(UIApplication.fhq_sendAction(_:to:from:for:)),
            label: "sendAction"
        )
        exchange(
            UIGestureRecognizer.self,
            NSSelectorFromString("setState:"),
            NSSelectorFromString("fhq_setState:"),
            label: "gesture recogniser state"
        )
        exchange(
            UIWindow.self,
            #selector(UIWindow.sendEvent(_:)),
            #selector(UIWindow.fhq_sendEvent(_:)),
            label: "sendEvent"
        )
    }

    private static func exchange(
        _ target: AnyClass,
        _ original: Selector,
        _ replacement: Selector,
        label: String
    ) {
        guard let originalMethod = class_getInstanceMethod(target, original),
              let replacementMethod = class_getInstanceMethod(target, replacement)
        else {
            founderHQDebugLog(debug) { "element capture could not hook \(label)" }
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
        installedHooks.insert(label)
    }

    /**
     Marks the calls made while UIKit delivers one touch event. Nested, because
     a window can send an event from inside another one.
     */
    static func duringTouchEvent(_ event: UIEvent, _ body: () -> Void) {
        guard event.type == .touches else {
            body()
            return
        }
        duringTouch(token: event.timestamp, body)
    }

    /// The part the tests can drive, because no test can build a `UIEvent`.
    static func duringTouch(token: TimeInterval, _ body: () -> Void) {
        let previous = currentTouchToken
        currentTouchToken = token
        defer { currentTouchToken = previous }
        body()
    }

    // MARK: - The capture paths

    static func sent(action: Selector, sender: Any?, delivered: Bool) {
        guard delivered, let sender = sender as? NSObject else { return }
        report(sender, action: action, gesture: nil)
    }

    /**
     `state` is the state the recogniser is declaring, taken from the setter
     rather than read back afterwards. UIKit's own state machine ignores a
     value it considers out of order and leaves `recognizer.state` behind, so
     reading it back can miss the very transition that just happened.
     */
    static func gestureChanged(
        _ recognizer: UIGestureRecognizer,
        declaring state: UIGestureRecognizer.State
    ) {
        guard reportsAnInteraction(recognizer, declaring: state),
              let view = recognizer.view
        else { return }
        // A control's own action already describes this tap, and it carries
        // more than the recogniser does, so the recogniser stands aside.
        guard !isControlOwned(view) else { return }
        report(view, action: nil, gesture: className(recognizer))
    }

    private static func report(_ element: NSObject, action: Selector?, gesture: String?) {
        // The hooks stay installed once they are in, so remote config turns
        // capture off here rather than by unswizzling: taking a swizzle back
        // out from under a live app is how other SDKs crash one.
        guard let client, client.elementCaptureEnabled else { return }
        guard !isTextInput(element), claimTouch() else { return }
        guard let properties = properties(for: element, action: action, gesture: gesture)
        else { return }
        client.capture("$autocapture", properties: properties)
        detectRageTap(element, properties: properties, client: client)
    }

    /**
     One physical tap, one event. A `UIButton` inside a view that also carries
     a tap recogniser reaches both hooks, and a SwiftUI element often carries
     several recognisers at once; whichever hook arrives first wins the touch
     and the rest stay quiet. A programmatic action has no touch to claim, so
     it always reports.
     */
    private static func claimTouch() -> Bool {
        guard let token = currentTouchToken else { return true }
        guard token != lastReportedTouchToken else { return false }
        lastReportedTouchToken = token
        return true
    }

    /**
     Which recogniser state means "the user just did something deliberate".

     A discrete recogniser, a tap included, ends when it recognises. A long
     press instead begins when it recognises and ends when the finger lifts,
     so it reports on `.began` and is excluded from the `.ended` rule below.
     Pans, pinches, rotations, swipes, and hovers also reach `.ended`, but they
     are scrolling and pointer noise rather than a chosen action, so they are
     left out entirely.
     */
    private static func reportsAnInteraction(
        _ recognizer: UIGestureRecognizer,
        declaring state: UIGestureRecognizer.State
    ) -> Bool {
        if recognizer is UILongPressGestureRecognizer { return state == .began }
        if recognizer is UIPanGestureRecognizer
            || recognizer is UIPinchGestureRecognizer
            || recognizer is UIRotationGestureRecognizer
            || recognizer is UISwipeGestureRecognizer
            || recognizer is UIHoverGestureRecognizer {
            return false
        }
        return state == .ended
    }

    private static func isControlOwned(_ view: UIView) -> Bool {
        var node: UIView? = view
        while let current = node {
            if current is UIControl { return true }
            node = current.superview
        }
        return false
    }

    /**
     A text field, text view, or search bar carries what the user typed, so the
     SDK never reports it — not even its label, which iOS fills in from the
     placeholder.
     */
    private static func isTextInput(_ sender: NSObject) -> Bool {
        sender is UITextInput || sender is UISearchBar || sender is UISearchTextField
    }

    private static func properties(
        for sender: NSObject,
        action: Selector?,
        gesture: String?
    ) -> [String: Any]? {
        var elements: [[String: Any]] = [
            descriptor(sender, action: action, gesture: gesture),
        ]
        var path: [String] = []
        if let view = sender as? UIView {
            var current: UIView? = view
            while let node = current {
                path.append(className(node))
                if node !== view, elements.count < maxElements {
                    elements.append(descriptor(node, action: nil, gesture: nil))
                }
                current = node.superview
            }
        }
        var properties: [String: Any] = ["$elements": elements]
        if let owner = owningViewController(sender) {
            let screen = className(owner)
            properties["$screen_name"] = screen
            path.append(screen)
        }
        guard !path.isEmpty else {
            properties["$element_path"] = className(sender)
            return properties
        }
        properties["$element_path"] = path.reversed().joined(separator: "/")
        return properties
    }

    private static func descriptor(
        _ element: NSObject,
        action: Selector?,
        gesture: String?
    ) -> [String: Any] {
        var entry: [String: Any] = ["class": className(element)]
        if let action {
            entry["action"] = NSStringFromSelector(action)
        }
        if let gesture {
            entry["gesture"] = gesture
        }
        if let identifier = sanitized(accessibilityIdentifier(of: element)) {
            entry["accessibility_identifier"] = identifier
        }
        if let label = sanitized(element.accessibilityLabel) {
            entry["accessibility_label"] = label
        }
        if let text = sanitized(renderedText(of: element)) {
            entry["text"] = text
        }
        if let control = element as? UIControl {
            entry["enabled"] = control.isEnabled
            entry["selected"] = control.isSelected
        }
        return entry
    }

    private static func detectRageTap(
        _ sender: NSObject,
        properties: [String: Any],
        client: FounderHQEvents
    ) {
        // The web SDK also needs the taps to land within 30 pixels of each
        // other. Here the element itself is the target, so identity replaces
        // the radius and no coordinate is ever read. The reference is weak on
        // purpose: iOS hands a new view the address a dead one just gave up,
        // and a bare pointer would fuse taps on two unrelated elements into a
        // rage tap that never happened.
        // Wall clock, not `systemUptime`: the uptime APIs are required-reason
        // ones, and no host app should have to amend its privacy manifest so
        // that we can time three taps.
        guard client.rageClickCaptureEnabled else { return }
        let now = Date().timeIntervalSince1970
        recentTaps = recentTaps.filter { now - $0.at <= rageWindow && $0.element === sender }
        recentTaps.append(RecentTap(element: sender, at: now))
        guard recentTaps.count >= rageTapCount,
              now - lastRageTapAt > rageWindow
        else { return }
        lastRageTapAt = now
        client.capture("$rageclick", properties: properties)
    }

    private final class RecentTap {
        weak var element: NSObject?
        let at: TimeInterval
        init(element: NSObject, at: TimeInterval) {
            self.element = element
            self.at = at
        }
    }

    private static func owningViewController(_ sender: NSObject) -> UIViewController? {
        var responder = (sender as? UIResponder)?.next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /**
     The words the tapped control renders, for the three kinds of control that
     publish a static title.

     - A `UIButton` gives the title it is showing now. A button built with
       `UIButton.Configuration`, which is how Xcode's own templates have built
       one since iOS 15, keeps its title there and returns nil from
       `title(for:)` — measured on iOS 26.2, where `configuration.title` read
       "Pay now" while `currentTitle` and `title(for: .normal)` were both nil.
       posthog-ios reads only `title(for:)` and so reports no text for most
       buttons written today; reading the configuration first closes that.
     - A `UISegmentedControl` gives the title of the selected segment, and
       nothing at all while no segment is selected.
     - A `UIBarButtonItem` gives its own title, which is how a bar button
       reaches the `sendAction` hook.

     Every source here is a title the app itself authored. None is the
     synthesised `accessibilityLabel`, which repeats whatever the button
     renders and would carry, say, a price into an event.

     Every other element gives nothing. A text field, a text view, and a
     search bar never reach here at all: `isTextInput` turns them away before
     any property of theirs is read.
     */
    private static func renderedText(of element: NSObject) -> String? {
        if let segmented = element as? UISegmentedControl {
            let selected = segmented.selectedSegmentIndex
            guard (0..<segmented.numberOfSegments).contains(selected) else { return nil }
            return segmented.titleForSegment(at: selected)
        }
        if let button = element as? UIButton { return buttonTitle(of: button) }
        if let item = element as? UIBarItem { return item.title }
        return nil
    }

    private static func buttonTitle(of button: UIButton) -> String? {
        if #available(iOS 15.0, *), let configuration = button.configuration {
            if let title = configuration.title { return title }
            if let attributed = configuration.attributedTitle {
                return String(attributed.characters)
            }
        }
        // What the button shows now comes first, so the text in the event is
        // the text the person actually read. `titleLabel` covers the shapes
        // those two miss. The per-state titles are the last resort: a button
        // that carries a title only for a state it is not in renders nothing,
        // and naming it is still better than reporting an unnamed button.
        return button.currentTitle
            ?? button.currentAttributedTitle?.string
            ?? button.titleLabel?.text
            ?? button.title(for: .normal)
            ?? button.title(for: .selected)
    }

    /**
     `UIView` picks up `accessibilityIdentifier` from a category rather than by
     declaring `UIAccessibilityIdentification`, so `as?` on that protocol fails
     at runtime and quietly loses the one field an app can actually control.
     These branches read it the way it is really published.
     */
    private static func accessibilityIdentifier(of element: NSObject) -> String? {
        if let view = element as? UIView { return view.accessibilityIdentifier }
        if let item = element as? UIBarItem { return item.accessibilityIdentifier }
        if let identifying = element as? any UIAccessibilityIdentification {
            return identifying.accessibilityIdentifier
        }
        guard element.responds(to: NSSelectorFromString("accessibilityIdentifier")) else {
            return nil
        }
        return element.value(forKey: "accessibilityIdentifier") as? String
    }

    private static func className(_ element: NSObject) -> String {
        String(describing: type(of: element))
    }

    /**
     Trims, folds every run of spaces and line breaks into one space, drops
     the zero-width characters a design system uses for layout, and cuts the
     result to `maxTextLength`. An empty result becomes nil, so a blank title
     never takes up room in the payload.
     */
    private static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "[ \\t\\r\\n]+",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]",
                with: "",
                options: .regularExpression
            )
        guard !folded.isEmpty else { return nil }
        return String(folded.prefix(maxTextLength))
    }
}

private extension UIApplication {
    @objc func fhq_sendAction(
        _ action: Selector,
        to target: Any?,
        from sender: Any?,
        for event: UIEvent?
    ) -> Bool {
        let delivered = fhq_sendAction(action, to: target, from: sender, for: event)
        FounderHQInteractionCapture.sent(action: action, sender: sender, delivered: delivered)
        return delivered
    }
}

private extension UIGestureRecognizer {
    @objc(fhq_setState:)
    func fhq_setState(_ state: UIGestureRecognizer.State) {
        fhq_setState(state)
        FounderHQInteractionCapture.gestureChanged(self, declaring: state)
    }
}

private extension UIWindow {
    @objc func fhq_sendEvent(_ event: UIEvent) {
        FounderHQInteractionCapture.duringTouchEvent(event) {
            self.fhq_sendEvent(event)
        }
    }
}
#endif
