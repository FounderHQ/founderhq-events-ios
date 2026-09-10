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
}
