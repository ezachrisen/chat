import SwiftUI
import AppKit
import Combine
import ShadSwift

final class SidebarDragState: ObservableObject {
    var rowFrames: [String: CGRect] = [:]
    @Published var source: String?
    @Published var target: String?

    func reset() {
        source = nil
        target = nil
    }
}

struct SidebarReorderModifier: ViewModifier {
    let key: String
    let siblings: [String]
    @Binding var savedOrder: String
    @EnvironmentObject private var drag: SidebarDragState
    @Environment(\.shadTheme) private var theme

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                drag.rowFrames[key] = frame
            }
            .onDisappear {
                drag.rowFrames.removeValue(forKey: key)
                if drag.source == key { drag.reset() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .global)
                    .onChanged { value in
                        drag.source = key
                        drag.target = siblings.first {
                            $0 != key && drag.rowFrames[$0]?.contains(value.location) == true
                        }
                    }
                    .onEnded { value in
                        if let target = siblings.first(where: {
                            $0 != key && drag.rowFrames[$0]?.contains(value.location) == true
                        }) {
                            move(to: target)
                        }
                        drag.reset()
                    }
            )
            .opacity(drag.source == key ? 0.5 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(drag.target == key ? theme.colors.ring : .clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .accessibilityAction(named: "Move up") { moveBy(-1) }
            .accessibilityAction(named: "Move down") { moveBy(1) }
            .help("Drag to reorder chats")
    }

    private func moveBy(_ offset: Int) {
        let ordered = SidebarOrder.sorted(siblings, saved: savedOrder)
        guard let index = ordered.firstIndex(of: key), ordered.indices.contains(index + offset) else { return }
        move(to: ordered[index + offset])
    }

    private func move(to target: String) {
        guard let updated = SidebarOrder.moving(key, to: target, keys: siblings, saved: savedOrder) else { return }
        savedOrder = updated
    }
}

struct SidebarResizeHandle: View {
    @ObservedObject var sidebar: ShadSidebarState
    @Binding var savedWidth: Double
    @State private var startingWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if startingWidth == nil { startingWidth = sidebar.width }
                        setWidth((startingWidth ?? sidebar.width) + value.translation.width)
                    }
                    .onEnded { _ in
                        savedWidth = Double(sidebar.width)
                        startingWidth = nil
                    }
            )
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sidebar.width)) points")
            .accessibilityAdjustableAction { direction in
                setWidth(sidebar.width + (direction == .increment ? 20 : -20))
                savedWidth = Double(sidebar.width)
            }
            .help("Drag to resize sidebar")
    }

    private func setWidth(_ width: CGFloat) {
        // ShadSidebarState.width is not published, so notify its layout explicitly.
        sidebar.objectWillChange.send()
        sidebar.width = min(480, max(220, width))
    }
}
