struct TriggerGesture {
    enum Action { case queue, immediate }
    private var ready = false
    private var engaged = false
    private var fired = false

    mutating func cancel() {
        ready = false
        engaged = false
        fired = false
    }

    mutating func update(_ value: Float, allowed: Bool) -> Action? {
        guard value.isFinite, allowed else { cancel(); return nil }
        if value <= 0.08 {
            let action: Action? = ready && engaged && !fired ? .queue : nil
            ready = true
            engaged = false
            fired = false
            return action
        }
        guard ready else { return nil }
        if value >= 0.18 { engaged = true }
        if engaged && !fired && value >= 0.82 {
            fired = true
            return .immediate
        }
        return nil
    }
}
