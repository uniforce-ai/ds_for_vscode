struct StickNavigation {
    enum Mode { case menu, content }

    static func mode(roles: [String], openedWithOptions: Bool) -> Mode {
        let explicitMenu = roles.contains { ["AXMenu", "AXMenuItem", "AXDialog", "AXSheet"].contains($0) }
        if explicitMenu { return .menu }
        if roles.first == "AXTextArea" { return .content }
        if openedWithOptions { return .menu }
        return .content
    }
}
