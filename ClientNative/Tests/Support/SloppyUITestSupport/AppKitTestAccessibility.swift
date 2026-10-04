#if os(macOS)
import AppKit

@MainActor
public enum AppKitTestAccessibility {
    public static func enable() {
        _ = NSApplication.shared
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    public static func element(in view: NSView, identifier: String) -> NSObject? {
        func attribute(_ name: String, of object: NSObject) -> Any? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue()
        }

        func find(_ elements: [Any]) -> NSObject? {
            for element in elements {
                guard let object = element as? NSObject else { continue }
                if (attribute("accessibilityIdentifier", of: object) as? String) == identifier {
                    return object
                }
                if let match = find(attribute("accessibilityChildren", of: object) as? [Any] ?? []) {
                    return match
                }
            }
            return nil
        }
        return find(view.accessibilityChildren() ?? [])
    }

    public static func frame(of element: NSObject) -> NSRect? {
        (element as AnyObject).accessibilityFrame?()
    }

    public static func press(_ element: NSObject) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() == true
    }
}
#endif
