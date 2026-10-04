// GENERATED from @founderhq/events-core src/protocol.ts — do not edit.
// Regenerate with: pnpm --filter @founderhq/events-core generate:native

public enum FounderHQProtocolConstants {
    public static let reservedEventNames: [String] = [
    "$identify",
    "$groupidentify",
    "$set",
    "$pageview",
    "$pageleave",
    "$session_start",
    "$screen",
    "$autocapture",
    "$rageclick",
    "$dead_click",
    "$outbound_click",
    "$web_vitals",
    "$application_installed",
    "$application_updated",
    "$application_opened",
    "$application_backgrounded",
    "$push_notification_opened",
    "$push_device_registered",
    "$push_device_removed",
    ]

    public static let campaignProperties: [String] = [
    "utm_source",
    "utm_medium",
    "utm_campaign",
    "utm_term",
    "utm_content",
    "gclid",
    "gad_source",
    "gclsrc",
    "dclid",
    "gbraid",
    "wbraid",
    "fbclid",
    "msclkid",
    "twclid",
    "li_fat_id",
    "mc_cid",
    "igshid",
    "ttclid",
    "rdt_cid",
    "epik",
    "qclid",
    "sccid",
    "irclid",
    "_kx",
    ]

    public static let illegalDistinctIds: [String] = [
    "",
    "anonymous",
    "guest",
    "id",
    "undefined",
    "null",
    "none",
    "nil",
    "nan",
    "[object object]",
    "\"undefined\"",
    "\"null\"",
    ]

    /// Longest element text an event may carry.
    public static let elementTextMaxLength = 255

    /// How many ancestors of the tapped element travel with it.
    public static let elementAncestorLimit = 5

    /// Taps on one element inside the window that make a rage tap.
    public static let rageTapCount = 3

    /// The rage-tap window, and the quiet time before a second one may fire.
    public static let rageWindowMillis = 1000

    /// Registers a device for push. A control event: never stored as analytics.
    public static let pushDeviceRegisteredEvent = "$push_device_registered"

    /// Removes a device from a person. A control event too.
    public static let pushDeviceRemovedEvent = "$push_device_removed"

    public static let pushNotificationOpenedEvent = "$push_notification_opened"

    /// The $push_ property keys.
    public enum PushProperty {
        public static let token = "$push_token"
        public static let provider = "$push_provider"
        public static let platform = "$push_platform"
        public static let appId = "$push_app_id"
        public static let environment = "$push_environment"
        public static let enabled = "$push_enabled"
        public static let permission = "$push_permission"
        public static let messageId = "$push_message_id"
        public static let p256dh = "$push_p256dh"
        public static let auth = "$push_auth"
        public static let appKey = "$push_app_key"
    }

    /// The values of $push_provider.
    public static let pushProviders: [String] = [
    "fcm",
    "apns",
    "expo",
    ]

    /// The values of $push_platform.
    public static let pushPlatforms: [String] = [
    "ios",
    "android",
    "web",
    ]

    /// The values of $push_environment.
    public static let pushEnvironments: [String] = [
    "sandbox",
    "production",
    ]

    /// The values of $push_permission.
    public static let pushPermissions: [String] = [
    "authorized",
    "denied",
    "provisional",
    "not_determined",
    ]

    /// The key of a push payload that holds the FounderHQ message id.
    public static let pushPayloadMessageIdKey = "fhqOutboundMessageId"

    /// The key of a push payload that holds the link to open.
    public static let pushPayloadLinkKey = "fhqLink"

    /// The key of a push payload that holds the image URL.
    public static let pushPayloadImageUrlKey = "fhqImageUrl"
}
