import AppKit
import ApplicationServices

final class ConversationLocator {
    private var cachedWindow: AXUIElement?
    private var cachedComposer: AXUIElement?
    private var nextSearch = Date.distantPast

    func reset() {
        cachedWindow = nil
        cachedComposer = nil
        nextSearch = .distantPast
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = attribute(element, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private func composerPoint(_ element: AXUIElement, window: CGRect) -> CGPoint? {
        guard attribute(element, kAXRoleAttribute) as? String == "AXTextArea",
              (attribute(element, "AXHidden") as? Bool) != true,
              let input = frame(element) else { return nil }
        return ConversationGeometry.scrollPoint(composer: input, window: window)
    }

    func point(in target: NSRunningApplication) -> CGPoint? {
        let app = AXUIElementCreateApplication(target.processIdentifier)
        guard let window = elementAttribute(app, kAXFocusedWindowAttribute), let bounds = frame(window) else { return nil }
        if cachedWindow.map({ !CFEqual($0, window) }) ?? true {
            reset()
            cachedWindow = window
        }
        if let focused = elementAttribute(app, kAXFocusedUIElementAttribute), let point = composerPoint(focused, window: bounds) {
            cachedComposer = focused
            return point
        }
        if let composer = cachedComposer, let point = composerPoint(composer, window: bounds) { return point }
        cachedComposer = nil
        guard Date() >= nextSearch else { return nil }
        nextSearch = Date().addingTimeInterval(0.6)
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast(), visited < 500 {
            visited += 1
            if let point = composerPoint(element, window: bounds) {
                cachedComposer = element
                return point
            }
            guard depth < 24, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for child in children.suffix(100) { stack.append((child, depth + 1)) }
        }
        return nil
    }
}
