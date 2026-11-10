import Foundation

enum CodexPhase: Equatable {
    case idle
    case working
    case needsInput
    case completed
    case error

    var title: String {
        switch self {
        case .idle: "空闲"
        case .working: "编写中"
        case .needsInput: "等待确认"
        case .completed: "本轮结束"
        case .error: "出错"
        }
    }
}

struct CodexLightState {
    private(set) var phase: CodexPhase = .idle
    private var seen: [String] = []
    private var completedUntil: Date?
    let completedHold: TimeInterval

    init(completedHold: TimeInterval = 3600) {
        self.completedHold = completedHold
    }

    /// Applies one hook. Repeated deliveries of the same turn are ignored.
    @discardableResult
    mutating func receive(_ signal: HookSignal, now: Date) -> Bool {
        let key = signal.dedupeKey
        if seen.contains(key) { return false }
        seen.append(key)
        if seen.count > 200 { seen.removeFirst(seen.count - 200) }

        switch signal.kind {
        case .userPromptSubmit, .preToolUse, .postToolUse:
            phase = .working
            completedUntil = nil
        case .permissionRequest:
            phase = .needsInput
            completedUntil = nil
        case .stop:
            phase = .completed
            completedUntil = now.addingTimeInterval(completedHold)
        case .interrupt, .sessionEnd:
            phase = .idle
            completedUntil = nil
        }
        return true
    }

    @discardableResult
    mutating func expire(now: Date) -> Bool {
        guard phase == .completed, let completedUntil, now >= completedUntil else { return false }
        phase = .idle
        self.completedUntil = nil
        return true
    }

    mutating func preview(_ phase: CodexPhase, now: Date) {
        self.phase = phase
        completedUntil = phase == .completed ? now.addingTimeInterval(completedHold) : nil
    }
}

enum CodexLights {
    static let idle = LightColor(red: 0.22, green: 0.24, blue: 0.28)
    static let working = LightColor(red: 0.12, green: 0.32, blue: 1)
    static let needsInput = LightColor(red: 1, green: 0.72, blue: 0)
    static let completed = LightColor(red: 0, green: 0.9, blue: 0.3)
    static let error = LightColor(red: 1, green: 0.1, blue: 0.08)
    static let dictating = LightColor(red: 0, green: 0.85, blue: 0.95)

    static func pattern(phase: CodexPhase, dictating: Bool) -> LightPattern {
        if dictating { return .breathing(self.dictating, period: 1.6) }
        switch phase {
        case .idle: return .breathing(idle, period: 4.2)
        case .working: return .breathing(working, period: 2.2)
        case .needsInput: return .solid(needsInput)
        case .completed: return .breathing(completed, period: 2.6)
        case .error: return .flash(error, period: 0.6)
        }
    }
}
