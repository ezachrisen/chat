import SwiftUI

struct VoiceDictationGlow: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        let cycle = context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 3.6) / 3.6

                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                AngularGradient(
                                    colors: [
                                        Color(red: 1.00, green: 0.91, blue: 0.57),
                                        Color(red: 0.57, green: 0.82, blue: 1.00),
                                        Color(red: 0.80, green: 0.68, blue: 1.00),
                                        Color(red: 1.00, green: 0.91, blue: 0.57),
                                    ],
                                    center: .center,
                                    angle: .degrees(cycle * 360)
                                ),
                                lineWidth: 2
                            )
                            .shadow(
                                color: Color(red: 1.00, green: 0.91, blue: 0.57).opacity(0.36),
                                radius: 8
                            )
                            .shadow(
                                color: Color(red: 0.57, green: 0.82, blue: 1.00).opacity(0.34),
                                radius: 10
                            )
                            .shadow(
                                color: Color(red: 0.80, green: 0.68, blue: 1.00).opacity(0.30),
                                radius: 12
                            )
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
