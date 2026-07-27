// PROTOTYPE — throwaway spike code
import AppKit
import SwiftUI

@MainActor
final class PetPanel: NSPanel {
    private var downAt: Date?
    private var downOrigin: NSPoint?
    var onTap: (() -> Void)?

    init(state: PetState) {
        let size = NSSize(width: 220, height: 220)
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screen.maxX - size.width - 60, y: screen.minY + 80)
        super.init(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false // 拖拽走 performDrag，见 mouseDown
        contentView = NSHostingView(rootView: PetView(state: state))
    }

    override var canBecomeKey: Bool { false }

    // 点击 = 快速按放（emote）；按住移动 = 拖拽窗口
    override func mouseDown(with event: NSEvent) {
        downAt = Date()
        downOrigin = NSEvent.mouseLocation
        performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downAt = nil; downOrigin = nil }
        guard let downAt, let downOrigin else { return }
        let moved = hypot(NSEvent.mouseLocation.x - downOrigin.x, NSEvent.mouseLocation.y - downOrigin.y)
        if Date().timeIntervalSince(downAt) < 0.3, moved < 4 {
            onTap?()
        }
    }
}
