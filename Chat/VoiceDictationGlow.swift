import ShadSwift
import SwiftUI

struct VoiceDictationGlow: ViewModifier {
    let isActive: Bool
    @Environment(\.shadTheme) private var theme

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let cycle = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 3.6) / 3.6

                        ShadRoundedRectangle(cornerRadius: theme.radius.lg)
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        theme.colors.warning,
                                        theme.colors.info,
                                        theme.colors.primary,
                                        theme.colors.warning,
                                    ],
                                    center: .center,
                                    angle: .degrees(cycle * 360)
                                ),
                                lineWidth: theme.borderWidth * 2
                            )
                            .shadow(
                                color: theme.colors.warning.opacity(0.36),
                                radius: theme.spacing.md
                            )
                            .shadow(
                                color: theme.colors.info.opacity(0.34),
                                radius: theme.radius.lg
                            )
                            .shadow(
                                color: theme.colors.primary.opacity(0.30),
                                radius: theme.spacing.lg
                            )
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(theme.interactionAnimation, value: isActive)
    }
}
