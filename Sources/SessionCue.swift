import Foundation

/// A Codex VS Code session event. Message text is never kept.
struct SessionCue: Equatable {
    enum Kind: Equatable {
        case started
        case completed
        case aborted

        var signalKind: HookSignal.Kind {
            switch self {
            case .started: .userPromptSubmit
            case .completed: .stop
            case .aborted: .interrupt
            }
        }
    }

    let kind: Kind
    let turnID: String
    let at: Date

    var signal: HookSignal {
        HookSignal(kind: kind.signalKind, sessionID: "", turnID: turnID)
    }

    /// Recent enough to show when the app attaches to an already-open session.
    func isFresh(now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        switch kind {
        case .started: return age >= -5 && age < 15 * 60
        case .completed: return age >= -5 && age < 3600
        case .aborted: return age >= -5 && age < 120
        }
    }

    static func cues(in data: Data) -> [SessionCue] {
        var cues: [SessionCue] = []
        var rest = data
        while let newline = rest.firstIndex(of: 0x0A) {
            let line = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            if let cue = cue(Data(line)) { cues.append(cue) }
        }
        return cues
    }

    static func cue(_ line: Data) -> SessionCue? {
        let trimmed = line.drop(while: { $0 == 0x20 || $0 == 0x09 })
        guard !trimmed.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let name = payload["type"] as? String else { return nil }
        let kind: Kind
        switch name {
        case "task_started": kind = .started
        case "task_complete": kind = .completed
        case "turn_aborted": kind = .aborted
        default: return nil
        }
        let turn = (payload["turn_id"] as? String) ?? ""
        guard turn.count <= 256 else { return nil }
        let at = (object["timestamp"] as? String).flatMap(parseDate) ?? Date()
        return SessionCue(kind: kind, turnID: turn, at: at)
    }

    private static func parseDate(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Tails today's Codex VS Code session log. The plugin writes task_started and
/// task_complete there; it does not call the light hook unless one is installed.
final class SessionWatch {
    var onEvent: ((SessionCue, Bool) -> Void)?
    private let root: URL
    private var currentPath: String?
    private var offset: UInt64 = 0
    private var pending = Data()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    func poll(now: Date = Date()) {
        guard let file = newest(on: now) else { return }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if file.path != currentPath {
            currentPath = file.path
            pending.removeAll(keepingCapacity: true)
            let window: UInt64 = 262_144
            let start = size > window ? size - window : 0
            try? handle.seek(toOffset: start)
            var chunk = handle.readDataToEndOfFile()
            offset = size
            if start > 0, let newline = chunk.firstIndex(of: 0x0A) {
                chunk = Data(chunk[chunk.index(after: newline)...])
            }
            if chunk.last != 0x0A { chunk.append(0x0A) }
            if let last = SessionCue.cues(in: chunk).last, last.isFresh(now: now) {
                onEvent?(last, false)
            }
            return
        }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        pending.append(handle.readDataToEndOfFile())
        offset = size
        for cue in SessionCue.cues(in: pending) {
            onEvent?(cue, true)
        }
        if let newline = pending.lastIndex(of: 0x0A) {
            pending.removeSubrange(...newline)
        }
    }

    private func newest(on day: Date) -> URL? {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        let folder = root
            .appendingPathComponent(String(format: "%04d", year))
            .appendingPathComponent(String(format: "%02d", month))
            .appendingPathComponent(String(format: "%02d", day))
        guard let names = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return names
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left < right
            }
    }
}
