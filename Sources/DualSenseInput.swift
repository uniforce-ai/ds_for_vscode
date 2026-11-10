import Foundation

/// Buttons and sticks decoded from a DualSense input report.
/// GameController stops delivering presses while this menu-bar app is in the background.
struct DualSenseInput: Equatable {
    enum Button: Hashable {
        case square, cross, circle, triangle
        case dpadUp, dpadDown, dpadLeft, dpadRight
        case l1, r1, options
    }

    var buttons: Set<Button> = []
    var leftX: Float = 0
    var leftY: Float = 0
    var rightTrigger: Float = 0

    /// USB report 0x01, or Bluetooth enhanced report 0x31.
    static func parse(_ bytes: [UInt8]) -> DualSenseInput? {
        guard let first = bytes.first else { return nil }
        let offset: Int
        switch first {
        case 0x01 where bytes.count >= 11: offset = 1
        case 0x31 where bytes.count >= 12: offset = 2
        default: return nil
        }

        func byte(_ index: Int) -> UInt8 {
            let position = offset + index
            return position < bytes.count ? bytes[position] : 0
        }
        func axis(_ raw: UInt8) -> Float {
            (Float(raw) - 127.5) / 127.5
        }

        var input = DualSenseInput()
        input.leftX = axis(byte(0))
        input.leftY = -axis(byte(1))
        input.rightTrigger = Float(byte(5)) / 255

        let face = byte(7)
        switch face & 0x0F {
        case 0: input.buttons.insert(.dpadUp)
        case 1: input.buttons.formUnion([.dpadUp, .dpadRight])
        case 2: input.buttons.insert(.dpadRight)
        case 3: input.buttons.formUnion([.dpadRight, .dpadDown])
        case 4: input.buttons.insert(.dpadDown)
        case 5: input.buttons.formUnion([.dpadDown, .dpadLeft])
        case 6: input.buttons.insert(.dpadLeft)
        case 7: input.buttons.formUnion([.dpadLeft, .dpadUp])
        default: break
        }
        if face & 0x10 != 0 { input.buttons.insert(.square) }
        if face & 0x20 != 0 { input.buttons.insert(.cross) }
        if face & 0x40 != 0 { input.buttons.insert(.circle) }
        if face & 0x80 != 0 { input.buttons.insert(.triangle) }

        let shoulder = byte(8)
        if shoulder & 0x01 != 0 { input.buttons.insert(.l1) }
        if shoulder & 0x02 != 0 { input.buttons.insert(.r1) }
        if shoulder & 0x20 != 0 { input.buttons.insert(.options) }
        return input
    }
}
