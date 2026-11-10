import Foundation

/// The few Codex hook fields this app needs. Assistant text is never stored.
struct HookSignal: Equatable {
    enum Kind: String {
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case permissionRequest = "PermissionRequest"
        case stop = "Stop"
        case interrupt = "Interrupt"
        case sessionEnd = "SessionEnd"
    }

    let kind: Kind
    let sessionID: String
    let turnID: String

    var dedupeKey: String {
        let id = [sessionID, turnID].filter { !$0.isEmpty }.joined(separator: ":")
        return id.isEmpty ? kind.rawValue : "\(kind.rawValue):\(id)"
    }

    static func decode(_ data: Data) -> HookSignal? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let kind = Kind(rawValue: name) else { return nil }
        let session = (object["session_id"] as? String) ?? ""
        let turn = (object["turn_id"] as? String) ?? ""
        guard session.count <= 256, turn.count <= 256 else { return nil }
        return HookSignal(kind: kind, sessionID: session, turnID: turn)
    }
}
