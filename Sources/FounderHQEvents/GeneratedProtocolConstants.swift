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
}
