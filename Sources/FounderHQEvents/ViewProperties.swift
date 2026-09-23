#if canImport(UIKit)
import UIKit
import ObjectiveC.runtime

@MainActor
private var propertiesKey: UInt8 = 0

public extension UIView {
    /// Properties for taps on this view or any of its descendants.
    var fhqProperties: [String: Any]? {
        get { objc_getAssociatedObject(self, &propertiesKey) as? [String: Any] }
        set { objc_setAssociatedObject(self, &propertiesKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

@MainActor
func founderHQDeclarativeProperties(_ view: UIView?) -> [(String, JSONValue)] {
    var entries: [(String, JSONValue)] = []
    var current = view
    while let node = current {
        // Swift dictionaries have no insertion order. Sort within each view so
        // the same keys survive the cap on every launch.
        entries += json(node.fhqProperties ?? [:]).sorted { $0.key < $1.key }
        current = node.superview
    }
    return entries
}

#endif
