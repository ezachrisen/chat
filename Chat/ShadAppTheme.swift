import SwiftUI
import ShadSwift

enum ChatShadTheme {
    static let theme: ShadThemeSet = .default

    static func blueAccent(for colorScheme: ColorScheme) -> Color {
        ShadThemeSet.blue.resolved(for: colorScheme).colors.primary
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
