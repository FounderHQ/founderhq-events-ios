import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/**
 Which delivered notification a notification key names, and which silent
 push asks to remove one. Pure functions: the client below adds the
 notification centre.

 A FounderHQ notification carries `fhqOutboundMessageId`. Its notification
 key is `fhqNotificationKey` when the sender set one; with none, the key is
 the message id. Apple also gives a notification sent with a collapse id
 that id as its request identifier, so the identifier is read too.
 */
enum FounderHQPushRemoval {
    /// The key a silent FounderHQ push asks to remove, or nil for any other push.
    static func removalKey(userInfo: [AnyHashable: Any]) -> String? {
        value(FounderHQProtocolConstants.pushPayloadRemoveNotificationKey, in: userInfo)
    }

    /// True when a delivered notification is a FounderHQ one named by `key`.
    static func matches(identifier: String, userInfo: [AnyHashable: Any], key: String) -> Bool {
        guard let messageId = value(
            FounderHQProtocolConstants.pushPayloadMessageIdKey,
            in: userInfo
        ) else { return false }
        if messageId == key || identifier == key { return true }
        return value(FounderHQProtocolConstants.pushPayloadNotificationKey, in: userInfo) == key
    }

    /// A key at the top level of `userInfo`, or under `body` as Expo delivers it.
    private static func value(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let text = string(userInfo[key]) { return text }
        if let body = userInfo["body"] as? [AnyHashable: Any] { return string(body[key]) }
        if let text = userInfo["body"] as? String, let data = text.data(using: .utf8),
           let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return string(body[key])
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}

extension FounderHQEvents {
    /**
     Takes a FounderHQ notification off the device: call it when the person
     has seen what the notification is about (they opened the order, the chat,
     the screen). `key` is the notification key the push was sent with, or the
     id of the message when it had none.

     It removes only notifications FounderHQ pushes showed for this app. It
     sends nothing and stores nothing. `completion` gets how many it removed,
     on an arbitrary queue; in a process that is not an app it gets 0.
     */
    public func dismissPushNotification(
        key: String,
        completion: (@Sendable (Int) -> Void)? = nil
    ) {
        let wanted = key.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(UserNotifications)
        // `UNUserNotificationCenter.current()` raises in a process with no
        // app bundle behind it (a test runner, a command line tool).
        let bundlePath = Bundle.main.bundlePath
        guard !wanted.isEmpty,
              bundlePath.hasSuffix(".app") || bundlePath.hasSuffix(".appex")
        else {
            completion?(0)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered
                .filter { notification in
                    FounderHQPushRemoval.matches(
                        identifier: notification.request.identifier,
                        userInfo: notification.request.content.userInfo,
                        key: wanted
                    )
                }
                .map(\.request.identifier)
            if !identifiers.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
            completion?(identifiers.count)
        }
        #else
        completion?(0)
        #endif
    }

    /**
     Removes a notification when FounderHQ asks from the server. Call it from
     `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
     with every remote notification:

         func application(
             _ application: UIApplication,
             didReceiveRemoteNotification userInfo: [AnyHashable: Any],
             fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
         ) {
             if founderHQ.handleRemoteNotification(userInfo: userInfo, completion: {
                 completionHandler(.noData)
             }) { return }
             // Your own handling.
         }

     Returns true when the push was a FounderHQ removal: the SDK then removes
     the notification and calls `completion` when it is done. Returns false
     for every other push, and does not call `completion`.

     The app needs the "Remote notifications" background mode. Apple delivers
     such a push when it chooses to, and not at all to an app the person
     closed from the app switcher.
     */
    @discardableResult
    public func handleRemoteNotification(
        userInfo: [AnyHashable: Any],
        completion: (@Sendable () -> Void)? = nil
    ) -> Bool {
        guard let key = FounderHQPushRemoval.removalKey(userInfo: userInfo) else {
            return false
        }
        dismissPushNotification(key: key) { _ in completion?() }
        return true
    }
}
