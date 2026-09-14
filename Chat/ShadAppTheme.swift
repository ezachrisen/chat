import SwiftUI
import ShadSwift
import AppKit

enum ChatShadTheme {
    static let theme: ShadThemeSet = .default.typography(.system)

    static func scaledTheme(_ scale: Double) -> ShadThemeSet {
        // Always derive from the base typography, never from an inherited scale.
        var typography = ShadTypography.system
        typography.xs = ChatFontScale.size(typography.xs, scale: scale)
        typography.sm = ChatFontScale.size(typography.sm, scale: scale)
        typography.base = ChatFontScale.size(typography.base, scale: scale)
        typography.lg = ChatFontScale.size(typography.lg, scale: scale)
        typography.xl = ChatFontScale.size(typography.xl, scale: scale)
        typography.xxl = ChatFontScale.size(typography.xxl, scale: scale)
        return theme.typography(typography)
    }

    static func blueAccent(for colorScheme: ColorScheme) -> Color {
        ShadThemeSet.blue.resolved(for: colorScheme).colors.primary
    }
}

private struct ChatThemeModifier: ViewModifier {
    @AppStorage(ChatFontScale.defaultsKey) private var scale = ChatFontScale.defaultValue

    func body(content: Content) -> some View {
        content
            .font(.system(size: ChatFontScale.size(14, scale: scale)))
            .shadTheme(ChatShadTheme.scaledTheme(scale))
    }
}

private struct ChatSystemFontModifier: ViewModifier {
    let style: NSFont.TextStyle
    let weight: Font.Weight
    @AppStorage(ChatFontScale.defaultsKey) private var scale = ChatFontScale.defaultValue

    func body(content: Content) -> some View {
        content.font(.system(
            size: ChatFontScale.size(NSFont.preferredFont(forTextStyle: style).pointSize, scale: scale),
            weight: weight
        ))
    }
}

extension View {
    func chatTheme() -> some View {
        modifier(ChatThemeModifier())
    }

    func chatSystemFont(_ style: NSFont.TextStyle, weight: Font.Weight = .regular) -> some View {
        modifier(ChatSystemFontModifier(style: style, weight: weight))
    }
}

struct ShadBlueIconTile: View {
    let systemName: String

    @Environment(\.shadTheme) private var theme

    init(systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        let blueAccent = ChatShadTheme.blueAccent(for: theme.colorScheme)

        ShadIconView(.custom(systemName), size: theme.typography.base)
            .foregroundStyle(blueAccent)
            .frame(
                width: theme.spacing(8.5),
                height: theme.spacing(8.5)
            )
            .background(
                ShadRoundedRectangle(cornerRadius: theme.radius.lg)
                    .fill(blueAccent.opacity(0.15))
            )
            .accessibilityHidden(true)
    }
}
