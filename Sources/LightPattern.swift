import Foundation

struct LightColor: Equatable {
    var red: Float
    var green: Float
    var blue: Float

    func scaled(by factor: Float) -> LightColor {
        LightColor(red: red * factor, green: green * factor, blue: blue * factor)
    }
}

enum LightPattern: Equatable {
    case off
    case solid(LightColor)
    case breathing(LightColor, period: Double)
    case flash(LightColor, period: Double)

    var isAnimated: Bool {
        switch self {
        case .off, .solid: false
        case .breathing, .flash: true
        }
    }

    func color(at time: Double) -> LightColor {
        switch self {
        case .off:
            return LightColor(red: 0, green: 0, blue: 0)
        case .solid(let color):
            return color
        case .breathing(let color, let period):
            let safe = max(period, 0.05)
            let phase = time.truncatingRemainder(dividingBy: safe) / safe
            let level = 0.5 - 0.5 * cos(2 * Double.pi * phase)
            return color.scaled(by: Float(0.08 + 0.92 * level))
        case .flash(let color, let period):
            let safe = max(period, 0.05)
            let phase = time.truncatingRemainder(dividingBy: safe) / safe
            return phase < 0.5 ? color : color.scaled(by: 0.05)
        }
    }
}
