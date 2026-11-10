import CoreGraphics

struct ConversationGeometry {
    static func acceptsComposer(_ input: CGRect, window: CGRect) -> Bool {
        guard input.width.isFinite, input.height.isFinite, input.minX.isFinite, input.minY.isFinite,
              window.width > 0, window.height > 0 else { return false }
        return input.width >= 180 && input.height >= 12 && input.height < window.height * 0.45
            && input.midY > window.minY + window.height * 0.4
            && window.insetBy(dx: -1, dy: -1).contains(input)
    }

    static func scrollPoint(composer: CGRect, window: CGRect) -> CGPoint? {
        guard acceptsComposer(composer, window: window) else { return nil }
        let contentTop = window.minY + 80
        let availableHeight = composer.minY - contentTop
        guard availableHeight >= 60 else { return nil }
        return CGPoint(x: composer.midX, y: composer.minY - min(160, availableHeight * 0.5))
    }
}
