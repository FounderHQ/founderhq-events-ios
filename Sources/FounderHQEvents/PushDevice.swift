import Foundation

/// The service that delivers to a push token.
public enum FounderHQPushProvider: String, Codable, Sendable {
    case apns
    case fcm
    case expo
}

/// The APNs environment a device token belongs to.
public enum FounderHQPushEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

/// The notification permission the app last saw. The SDK never asks for it.
public enum FounderHQPushPermission: String, Sendable {
    case authorized
    case denied
    case provisional
    case notDetermined = "not_determined"
}

/**
 The two FounderHQ keys of a notification payload. Nothing else in `userInfo`
 is read: not the alert, not the badge, not the app's own keys.
 */
public struct FounderHQPushPayload: Sendable, Equatable {
    /// `fhqOutboundMessageId`: the message this notification belongs to.
    public let messageId: String?
    /// `fhqLink`: the URL or deep link to open. The SDK never opens it.
    public let link: String?

    /**
     Reads the two keys from the top level of `userInfo`. A notification that
     Expo delivered keeps the app's data under `body` (a dictionary, or the
     same as JSON text), so a key that is not at the top level is read there.
     */
    public init(userInfo: [AnyHashable: Any]) {
        let messageIdKey = FounderHQProtocolConstants.pushPayloadMessageIdKey
        let linkKey = FounderHQProtocolConstants.pushPayloadLinkKey
        var messageId = Self.string(userInfo[messageIdKey])
        var link = Self.string(userInfo[linkKey])
        if messageId == nil || link == nil, let body = Self.expoBody(userInfo["body"]) {
            messageId = messageId ?? Self.string(body[messageIdKey])
            link = link ?? Self.string(body[linkKey])
        }
        self.messageId = messageId
        self.link = link
    }

    /// True when the payload has a FounderHQ key: it is a FounderHQ notification.
    var isFounderHQ: Bool { messageId != nil || link != nil }

    private static func expoBody(_ value: Any?) -> [AnyHashable: Any]? {
        if let body = value as? [AnyHashable: Any] { return body }
        guard let text = value as? String, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }
        return text
    }
}

/// Called on the main actor when the user opens a notification.
public typealias FounderHQPushOpenedHandler = @MainActor @Sendable (FounderHQPushPayload) -> Void

/**
 What travels with a push token. The order of the fields is the same in the
 iOS, Android, and React Native SDKs: provider, app ID, environment, enabled,
 permission.

     events.registerPushToken(deviceToken)                       // APNs
     events.registerPushToken(deviceToken, options: .apns(enabled: false))
     events.registerPushToken(fcmToken, options: .fcm())         // Firebase
 */
public struct FounderHQPushRegistrationOptions: Sendable, Equatable {
    /// The service that delivers to the token.
    public var provider: FounderHQPushProvider
    /// Bundle ID or Expo project. Leave it out and the server uses the app's own ID.
    public var appId: String?
    /// APNs only. Leave it out and the SDK reads it from the build's provisioning profile.
    public var environment: FounderHQPushEnvironment?
    /// Your app's own push switch for this device. Nil keeps the stored switch.
    public var enabled: Bool?
    /// The permission your app last saw. Nil lets the SDK read it from the system.
    public var permission: FounderHQPushPermission?

    public init(
        provider: FounderHQPushProvider,
        appId: String? = nil,
        environment: FounderHQPushEnvironment? = nil,
        enabled: Bool? = nil,
        permission: FounderHQPushPermission? = nil
    ) {
        self.provider = provider
        self.appId = appId
        self.environment = environment
        self.enabled = enabled
        self.permission = permission
    }

    /// A token from `didRegisterForRemoteNotificationsWithDeviceToken`.
    public static func apns(
        appId: String? = nil,
        environment: FounderHQPushEnvironment? = nil,
        enabled: Bool? = nil,
        permission: FounderHQPushPermission? = nil
    ) -> Self {
        .init(
            provider: .apns, appId: appId, environment: environment,
            enabled: enabled, permission: permission
        )
    }

    /// A Firebase Cloud Messaging registration token.
    public static func fcm(
        appId: String? = nil,
        enabled: Bool? = nil,
        permission: FounderHQPushPermission? = nil
    ) -> Self {
        .init(provider: .fcm, appId: appId, enabled: enabled, permission: permission)
    }

    /// An Expo push token.
    public static func expo(
        appId: String? = nil,
        enabled: Bool? = nil,
        permission: FounderHQPushPermission? = nil
    ) -> Self {
        .init(provider: .expo, appId: appId, enabled: enabled, permission: permission)
    }
}

/// What the SDK keeps about this device's push registration.
struct FounderHQPushDeviceState: Codable, Sendable, Equatable {
    var token: String?
    var provider: FounderHQPushProvider?
    var appId: String?
    var environment: FounderHQPushEnvironment?
    /// The app's own switch. Nil until the app sets it; `reset()` clears it.
    var enabled: Bool?
    /**
     Removals the server has not accepted yet. One leaves the list only when
     ingest accepts it, so a logout while offline is not lost with the queue.
     Optional, so a state file written before this field still decodes.
     */
    var pendingRemovals: [FounderHQPendingPushRemoval]?

    init(
        token: String? = nil,
        provider: FounderHQPushProvider? = nil,
        appId: String? = nil,
        environment: FounderHQPushEnvironment? = nil,
        enabled: Bool? = nil,
        pendingRemovals: [FounderHQPendingPushRemoval]? = nil
    ) {
        self.token = token
        self.provider = provider
        self.appId = appId
        self.environment = environment
        self.enabled = enabled
        self.pendingRemovals = pendingRemovals
    }

    /**
     Reads what it can. A provider this build does not know makes the token
     useless, so the token goes with it and the app registers again. An
     unknown environment is left out. A removal the SDK cannot read is left
     out, and the other removals stay.
     */
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try? values.decodeIfPresent(FounderHQPushProvider.self, forKey: .provider)
        let token = try? values.decodeIfPresent(String.self, forKey: .token)
        self.provider = provider
        self.token = provider == nil ? nil : token
        appId = provider == nil ? nil : (try? values.decodeIfPresent(String.self, forKey: .appId))
        environment = provider == nil ? nil : (try? values.decodeIfPresent(
            FounderHQPushEnvironment.self, forKey: .environment
        ))
        enabled = try? values.decodeIfPresent(Bool.self, forKey: .enabled)
        pendingRemovals = (try? values.decodeIfPresent(
            [FounderHQLenient<FounderHQPendingPushRemoval>].self, forKey: .pendingRemovals
        ))?.compactMap(\.value)
    }

    var isEmpty: Bool {
        token == nil && enabled == nil && (pendingRemovals ?? []).isEmpty
    }
}

struct FounderHQPendingPushRemoval: Codable, Sendable, Equatable {
    /// The event id. It stays the same on every send, so ingest counts it once.
    var uuid: String
    var token: String
    var provider: FounderHQPushProvider?
    /// The person the device is removed from.
    var distinctId: String
    /**
     When the person signed out. Every send carries this time and not the time
     of the send: the server compares it with the device's last registration,
     so a removal that arrives late cannot remove a device that the person
     registered again after it. Nil only in a state an earlier build wrote.
     */
    var timestamp: String?

    /// The same device of the same person. A removal with no provider matches each one.
    func matches(token: String, provider: FounderHQPushProvider, distinctId: String) -> Bool {
        self.token == token && self.distinctId == distinctId
            && (self.provider == nil || self.provider == provider)
    }
}

/// Decodes a value, or nil when the stored value does not have its shape.
struct FounderHQLenient<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

/// A person keeps at most this many removals waiting for the server.
let founderHQMaxPendingPushRemovals = 10

/// Lowercase hex of the `Data` APNs hands to the app delegate.
func founderHQPushTokenHex(_ deviceToken: Data) -> String {
    deviceToken.map { String(format: "%02x", $0) }.joined()
}

/// What `founderHQNormalizedPushToken` answers.
enum FounderHQPushTokenResult: Equatable {
    /// The token as the server stores it.
    case valid(String)
    /// Why the server would refuse it. Never holds the token.
    case invalid(reason: String)
}

/**
 The token as the server stores it, or the reason the server would refuse it.
 The rules are the server's and must stay the same as `normalizePushToken` in
 apps/web/src/lib/comms/push-devices.ts:

 - every provider: 8 to 4096 characters after a trim, no whitespace inside;
 - `apns`: 64 to 200 hex characters, stored lowercase;
 - `expo`: `ExponentPushToken[...]` or `ExpoPushToken[...]`, with no bracket
   and no whitespace inside the brackets;
 - `fcm`: nothing more.

 The Android and React Native SDKs apply the same rules, and the three test
 suites share one table of cases.
 */
func founderHQNormalizedPushToken(
    _ token: String,
    provider: FounderHQPushProvider
) -> FounderHQPushTokenResult {
    let name = provider.rawValue
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    // The server counts UTF-16 units, as JavaScript does.
    guard (8...4096).contains(trimmed.utf16.count) else {
        return .invalid(reason: "a \(name) token has 8 to 4096 characters")
    }
    guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
        return .invalid(reason: "a \(name) token has no whitespace")
    }
    switch provider {
    case .apns:
        guard (64...200).contains(trimmed.utf16.count),
              trimmed.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return .invalid(reason: "an apns token is 64 to 200 hex characters") }
        return .valid(trimmed.lowercased())
    case .expo:
        let prefix = ["ExponentPushToken[", "ExpoPushToken["].first { trimmed.hasPrefix($0) }
        guard let prefix, trimmed.hasSuffix("]") else {
            return .invalid(
                reason: "an expo token looks like ExponentPushToken[...] or ExpoPushToken[...]"
            )
        }
        let inner = trimmed.dropFirst(prefix.count).dropLast()
        guard !inner.isEmpty, !inner.contains("["), !inner.contains("]") else {
            return .invalid(
                reason: "an expo token looks like ExponentPushToken[...] or ExpoPushToken[...]"
            )
        }
        return .valid(trimmed)
    case .fcm:
        return .valid(trimmed)
    }
}

/// `UNAuthorizationStatus` by raw value, so the mapping also builds where a case does not exist.
func founderHQPushPermission(authorizationStatus rawValue: Int) -> FounderHQPushPermission? {
    switch rawValue {
    case 0: return .notDetermined
    case 1: return .denied
    // 4 is `ephemeral`: an App Clip that may notify for a limited time.
    case 2, 4: return .authorized
    case 3: return .provisional
    default: return nil
    }
}

/**
 Works out which APNs environment this build's device tokens belong to.

 The answer is the `aps-environment` entitlement, and the only copy of it an
 app may read without private API is the one in its embedded provisioning
 profile:

 - A simulator build registers with the sandbox.
 - A build with a profile (development, ad hoc, enterprise) uses the profile's
   value.
 - An iOS build without a profile came from the App Store or TestFlight, which
   strip it, and those are production.
 - Anything else (a profile the SDK cannot read, a Mac build without one) is
   unknown. The SDK then sends no environment and the server tries production
   first, then the sandbox.
 */
enum FounderHQPushEnvironmentDetector {
    static func detect(bundle: Bundle = .main) -> FounderHQPushEnvironment? {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        if let profile = provisioningProfile(in: bundle) {
            return environment(provisioningProfile: profile)
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return .production
        #else
        return nil
        #endif
        #endif
    }

    static func provisioningProfile(in bundle: Bundle) -> Data? {
        let candidates = [
            bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
            bundle.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }

    /// The profile is a signed container; the plist inside it is plain text.
    static func environment(provisioningProfile: Data) -> FounderHQPushEnvironment? {
        guard let start = provisioningProfile.range(of: Data("<?xml".utf8)),
              let end = provisioningProfile.range(
                of: Data("</plist>".utf8),
                in: start.lowerBound..<provisioningProfile.endIndex
              ),
              let plist = try? PropertyListSerialization.propertyList(
                from: provisioningProfile.subdata(in: start.lowerBound..<end.upperBound),
                format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return nil }
        // iOS names the entitlement `aps-environment`; macOS prefixes it.
        let value = entitlements["aps-environment"] as? String
            ?? entitlements["com.apple.developer.aps-environment"] as? String
        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}
