// PROTOTYPE — S1 宠物悬浮窗 spike。抛弃式代码，不进产品。
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = PetState()
    var petPanel: PetPanel!
    var controlWindow: NSWindow!
    var statusItem: NSStatusItem!
    var hitTestTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        petPanel = PetPanel(state: state)
        petPanel.onTap = { [weak self] in self?.state.emote() }
        state.panel = petPanel
        state.applyToPanel()
        petPanel.orderFrontRegardless()

        controlWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "S1 spike 控制台"
        controlWindow.contentView = NSHostingView(rootView: ControlView(state: state))
        controlWindow.isReleasedWhenClosed = false
        controlWindow.center()
        controlWindow.makeKeyAndOrderFront(nil)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐾"
        let menu = NSMenu()
        let showItem = NSMenuItem(title: "显示控制台", action: #selector(showControls), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // 自动命中档：30Hz 轮询全局鼠标位置（免辅助功能权限），等价 Electron setIgnoreMouseEvents(forward)
        hitTestTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickHitTest() }
        }

        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.state.note("系统从睡眠唤醒") }
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.state.note("显示器参数变化（插拔/分辨率）") }
        }

        NSApp.activate(ignoringOtherApps: true)
        state.note("启动完成。验收清单见 Spikes/S1PetOverlay/README.md")
    }

    private func tickHitTest() {
        guard state.autoHitTest else { return }
        // 宠物命中区域 = 面板中心半径 90pt 的圆（与 PetView contentShape 一致量级）
        let mouse = NSEvent.mouseLocation
        let center = NSPoint(x: petPanel.frame.midX, y: petPanel.frame.midY)
        let hovering = hypot(mouse.x - center.x, mouse.y - center.y) < 90
        if hovering != state.hoveringPet {
            state.hoveringPet = hovering
            state.applyToPanel()
            state.note(hovering ? "悬停宠物 → 接收点击" : "离开宠物 → 穿透")
        }
    }

    @objc func showControls() {
        controlWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
@MainActor
struct S1Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // 无 Dock 图标，贴近产品最终形态；控制台经菜单栏 🐾 找回
        app.run()
    }
}
