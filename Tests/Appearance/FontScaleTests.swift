import Testing
@testable import AppearanceCore

@Test func defaultScalePreservesBaseSizes() {
    for base in [10.0, 12, 14, 16, 18, 20, 24] {
        #expect(Double(ChatFontScale.size(base, scale: 1)) == base)
    }
}

@Test func everySizeUsesTheSameMultiplier() {
    for base in [10.0, 12, 14, 16, 18, 20, 24] {
        #expect(abs(ChatFontScale.size(base, scale: 1.5) / base - 1.5) < 0.0001)
    }
}

@Test func invalidPreferencesHaveSafeBounds() {
    #expect(ChatFontScale.normalized(.nan) == 1)
    #expect(ChatFontScale.normalized(.infinity) == 1)
    #expect(ChatFontScale.normalized(-2) == 0.8)
    #expect(ChatFontScale.normalized(20) == 1.6)
}
