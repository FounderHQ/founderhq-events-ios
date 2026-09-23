import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The element is the UIKit object that caused the tap (a UIView or bar item).
/// Screens have no element or element description. Read UIKit objects on the main actor.
@MainActor
public struct FounderHQAutoPropertiesContext {
    public let event: String
    public let screenName: String?
    public let element: NSObject?
    public let elementDescription: JSONObject?
}

public typealias FounderHQAutoProperties = @MainActor @Sendable
    (FounderHQAutoPropertiesContext) throws -> [String: Any]?
public typealias FounderHQBeforeSend = @Sendable (FounderHQEvent) throws -> FounderHQEvent?

@MainActor
final class FounderHQAutomaticProperties {
    private let hook: FounderHQAutoProperties?
    private let warning: @Sendable (String) -> Void
    private var warned = false
    var screenName: String?

    nonisolated init(
        hook: FounderHQAutoProperties?,
        warning: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }
    ) {
        self.hook = hook
        self.warning = warning
    }

    func properties(
        event: String,
        element: NSObject? = nil,
        description: JSONObject? = nil,
        declarative: [(String, JSONValue)] = []
    ) -> JSONObject {
        var callback: JSONObject = [:]
        do {
            callback = json(try hook?(.init(
                event: event,
                screenName: screenName,
                element: element,
                elementDescription: description
            )) ?? [:])
        } catch {
            if !warned {
                warned = true
                warning("[FounderHQEvents] autoProperties threw; capturing the event without its callback properties")
            }
        }
        return sanitizeAutomaticProperties(declarative + callback.sorted { $0.key < $1.key })
    }
}

/// Priority determines which values survive both collisions and the shared cap.
func sanitizeAutomaticProperties(_ entries: [(String, JSONValue)]) -> JSONObject {
    var result: JSONObject = [:]
    for (key, value) in entries {
        guard !key.isEmpty, key.utf16.count <= 64, !key.hasPrefix("$"),
              result[key] == nil else { continue }
        switch value {
        case .string(let text):
            // UTF-16 matches the web limit; don't leave half of a surrogate pair.
            let units = text.trimmingCharacters(in: .whitespacesAndNewlines).utf16
            var prefix = Array(units.prefix(200))
            if let last = prefix.last, (0xD800...0xDBFF).contains(last) { prefix.removeLast() }
            result[key] = .string(String(decoding: prefix, as: UTF16.self))
        case .number(let number) where number.isFinite:
            result[key] = value
        case .bool:
            result[key] = value
        default:
            continue
        }
        if result.count == 20 { break }
    }
    return result
}

/// The appearance of what is on screen: the trait collection of the view
/// controller that appeared last, which includes a window's
/// `overrideUserInterfaceStyle`. A view's own traits are always defined;
/// `UITraitCollection.current` is not, outside UIKit's own callbacks, and
/// this is read after an asynchronous hop. Nil until a controller has
/// appeared, and then the property is omitted. No `UIApplication.shared`,
/// so it builds for app extensions.
@MainActor
public func founderHQSystemColorScheme() -> String? {
    #if canImport(UIKit)
    guard let view = FounderHQScreenCapture.lastAppearedView else { return nil }
    return founderHQColorScheme(view.traitCollection.userInterfaceStyle)
    #else
    return nil
    #endif
}

#if canImport(UIKit)
func founderHQColorScheme(_ style: UIUserInterfaceStyle) -> String? {
    switch style {
    case .dark: return "dark"
    case .light: return "light"
    default: return nil
    }
}
#endif
