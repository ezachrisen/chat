import Foundation

enum ChatFontScale {
    static let defaultsKey = "appearanceFontScale"
    static let defaultValue = 1.0
    static let range = 0.8...1.6

    static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    static func size(_ baseSize: CGFloat, scale: Double) -> CGFloat {
        baseSize * normalized(scale)
    }
}
