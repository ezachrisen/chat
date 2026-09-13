import AppKit
import SwiftUI

struct MainWindowFramePersistenceView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = context.coordinator.attach(to:)
        return view
    }

    func updateNSView(_ nsView: WindowReaderView, context: Context) {
        nsView.onWindowChange = context.coordinator.attach(to:)
    }

    @MainActor
    final class Coordinator {
        private let persistence = MainWindowFramePersistence()

        func attach(to window: NSWindow) {
            persistence.attach(to: window)
        }
    }
}

final class WindowReaderView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard let newWindow else { return }
        onWindowChange?(newWindow)
    }
}

@MainActor
final class MainWindowFramePersistence: NSObject {
    private static let defaultsKey = "mainWindowFrame"

    private weak var window: NSWindow?

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }

        NotificationCenter.default.removeObserver(self)
        self.window = window

        let frame = restoredFrame(for: window)
        window.setFrame(frame, display: true)
        save(frame)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange),
            name: NSWindow.didMoveNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFrameDidChange),
            name: NSWindow.didResizeNotification,
            object: window
        )
    }

    @objc private func windowFrameDidChange() {
        guard let window else { return }
        save(window.frame)
    }

    private func restoredFrame(for window: NSWindow) -> NSRect {
        if let savedFrame, NSScreen.screens.contains(where: { $0.visibleFrame.contains(savedFrame) }) {
            return savedFrame
        }

        let displayFrame = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let size = NSSize(
            width: displayFrame.width / 3,
            height: displayFrame.height * 2 / 3
        )
        return NSRect(
            x: displayFrame.midX - size.width / 2,
            y: displayFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private var savedFrame: NSRect? {
        guard let value = UserDefaults.standard.string(forKey: Self.defaultsKey) else {
            return nil
        }

        let frame = NSRectFromString(value)
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return nil
        }
        return frame
    }

    private func save(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.defaultsKey)
    }
}
