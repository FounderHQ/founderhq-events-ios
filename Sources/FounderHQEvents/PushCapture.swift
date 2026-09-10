#if canImport(UIKit) && canImport(UserNotifications)
import Foundation
import UIKit
import UserNotifications
import ObjectiveC.runtime

/**
 Emits `$push_notification_opened` when the user taps a notification.

 iOS reports the tap to whatever object the app set as the notification centre
 delegate, so the SDK hooks `setDelegate:` and then the delegate's
 `didReceiveNotificationResponse` method. A delegate that does not implement
 that method gets ours added, which captures and then calls the completion
 handler, exactly as the system expects.

 What it stores: the action identifier, the category identifier, the request
 identifier, and whether the notification came from a push or a local trigger.
 What it refuses to store: the title, subtitle, body, badge, sound, the
 `userInfo` payload, and any text the user typed into a reply action.
 */
enum FounderHQPushCapture {
    private static weak var client: FounderHQEvents?
    private static var debug = false
    private static var installed = false
    private static var patchedDelegate: ObjectIdentifier?

    private static let responseSelector = NSSelectorFromString(
        "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
    )

    static func install(client: FounderHQEvents, debug: Bool) {
        self.client = client
        self.debug = debug
        // `UNUserNotificationCenter.current()` raises, and so kills the host
        // process, when the process has no app bundle behind it: a test
        // runner, a command line tool, or anything else UIKit does not treat
        // as an app. Such a process can never receive a notification either,
        // so the SDK stands down rather than risk taking it down.
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".appex") else {
            founderHQDebugLog(debug) {
                "push capture stood down: \(bundlePath) is not an app or an extension"
            }
            return
        }
        if !installed {
            installed = true
            if let original = class_getInstanceMethod(
                UNUserNotificationCenter.self,
                NSSelectorFromString("setDelegate:")
            ), let replacement = class_getInstanceMethod(
                UNUserNotificationCenter.self,
                NSSelectorFromString("fhq_setDelegate:")
            ) {
                method_exchangeImplementations(original, replacement)
            } else {
                founderHQDebugLog(debug) {
                    "push capture could not hook UNUserNotificationCenter.delegate"
                }
            }
        }
        // The app usually sets its delegate before the SDK starts, so patch the
        // one already in place as well as any set later.
        patch(UNUserNotificationCenter.current().delegate)
    }

    static func patch(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        guard let delegate = delegate as? NSObject else { return }
        let target: AnyClass = type(of: delegate)
        let identifier = ObjectIdentifier(target)
        if let patchedDelegate {
            if patchedDelegate != identifier {
                founderHQDebugLog(debug) {
                    "push capture stays on the first delegate class it saw"
                }
            }
            return
        }
        guard let swizzled = class_getInstanceMethod(
            NSObject.self,
            NSSelectorFromString(
                "fhq_userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
            )
        ), let added = class_getInstanceMethod(
            NSObject.self,
            NSSelectorFromString(
                "fhq_addedUserNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
            )
        ) else { return }
        patchedDelegate = identifier
        if let original = class_getInstanceMethod(target, responseSelector) {
            method_exchangeImplementations(original, swizzled)
        } else {
            class_addMethod(
                target,
                responseSelector,
                method_getImplementation(added),
                method_getTypeEncoding(added)
            )
        }
    }

    static func opened(_ response: UNNotificationResponse) {
        guard let client else { return }
        let request = response.notification.request
        var properties: [String: Any] = [
            "$push_action_identifier": response.actionIdentifier,
            "$push_source": request.trigger is UNPushNotificationTrigger ? "remote" : "local",
        ]
        if !request.identifier.isEmpty {
            properties["$push_notification_id"] = request.identifier
        }
        let category = request.content.categoryIdentifier
        if !category.isEmpty {
            properties["$push_category_identifier"] = category
        }
        client.capture("$push_notification_opened", properties: properties)
    }
}

private extension UNUserNotificationCenter {
    @objc(fhq_setDelegate:)
    func fhq_setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {
        FounderHQPushCapture.patch(delegate)
        fhq_setDelegate(delegate)
    }
}

private extension NSObject {
    /// Installed by exchange, so the call at the end reaches the app's method.
    @objc(fhq_userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)
    func fhq_userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        FounderHQPushCapture.opened(response)
        fhq_userNotificationCenter(
            center,
            didReceive: response,
            withCompletionHandler: completionHandler
        )
    }

    /// Installed on a delegate that has no method of its own to call through to.
    @objc(fhq_addedUserNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:)
    func fhq_addedUserNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        FounderHQPushCapture.opened(response)
        completionHandler()
    }
}
#endif
