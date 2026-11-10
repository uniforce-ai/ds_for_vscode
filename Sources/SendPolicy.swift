import CoreGraphics

enum SendPolicy {
    private static let menuRoles: Set<String> = ["AXMenu", "AXMenuItem", "AXSheet", "AXDialog"]

    /// R2 may send only while a composer-like control is focused.
    /// A full-height editor text area is rejected so Enter is not typed into code.
    static func allows(enabled: Bool, trusted: Bool, dictating: Bool, roles: [String], focused: CGRect?, window: CGRect?) -> Bool {
        guard enabled, trusted, !dictating else { return false }
        if roles.contains(where: { menuRoles.contains($0) }) { return false }
        guard let first = roles.first else { return false }
        switch first {
        case "AXTextArea", "AXTextField":
            if let focused, let window {
                return ConversationGeometry.acceptsComposer(focused, window: window)
            }
            return true
        case "AXWebArea", "AXGroup":
            return true
        default:
            return false
        }
    }
}
