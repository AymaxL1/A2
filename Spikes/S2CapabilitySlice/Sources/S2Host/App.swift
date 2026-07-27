// PROTOTYPE — S2Host GUI app。菜单栏 ⚡ + 能力注册表 + UDS server + dangerous 宿主确认弹窗。
// 入口用 @main @MainActor struct（顶层代码不是 MainActor 上下文，不能在 main.swift 顶层构造 @MainActor 对象；S1 已验证）。
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = Registry()
    var server: UDSServer!
    var statusItem: NSStatusItem!

    /// 环境变量 S2_AUTO_DENY_SECONDS：设置时 dangerous 弹窗于 N 秒后自动拒绝（无人值守测试用，夜里不留挂着的对话框）。
    let autoDenySeconds: Double? = {
        if let s = ProcessInfo.processInfo.environment["S2_AUTO_DENY_SECONDS"], let v = Double(s) { return v }
        return nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) socket 路径：~/Library/Application Support/S2Spike/aa.sock（目录自建）
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSup.appendingPathComponent("S2Spike", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sockPath = dir.appendingPathComponent("aa.sock").path
        s2log("socket 路径: \(sockPath)")
        if let secs = autoDenySeconds {
            s2log("S2_AUTO_DENY_SECONDS=\(secs) → dangerous 弹窗将于 \(secs)s 后自动拒绝")
        }

        // 2) 注入 dangerous 确认回调（后台线程调用 → 切回主线程弹 NSAlert）
        registry.confirmDangerous = { [weak self] cap in
            self?.confirmDangerousOnMain(cap) ?? false
        }

        // 3) 启动 UDS server
        server = UDSServer(socketPath: sockPath, registry: registry)
        do {
            try server.start()
            s2log("UDS server 已监听: \(sockPath)")
        } catch {
            s2log("UDS server 启动失败: \(error.localizedDescription)")
        }

        // 4) 菜单栏
        setupStatusItem()

        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标，菜单栏常驻
        s2log("启动完成。人工验收清单见 Spikes/S2CapabilitySlice/README.md")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        let menu = NSMenu()
        menu.addItem(withTitle: "S2 能力注册表（PROTOTYPE）", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for cap in registry.capabilities {
            // 只读项：nil action → 自动 disabled
            menu.addItem(withTitle: "\(cap.id)  ·  \(cap.risk)  ·  \(cap.summary)",
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// 从后台连接处理线程调用；同步切回主线程弹窗并取回结果（阻塞该连接直到用户/自动拒绝决定）。
    private func confirmDangerousOnMain(_ cap: Capability) -> Bool {
        var approved = false
        let work = { approved = self.showConfirmAlert(cap) }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
        s2log("dangerous 确认结果 [\(cap.id)]: \(approved ? "approved" : "denied")")
        return approved
    }

    /// 主线程弹 dangerous 确认框。支持 S2_AUTO_DENY_SECONDS 定时自动拒绝。
    private func showConfirmAlert(_ cap: Capability) -> Bool {
        NSApp.activate(ignoringOtherApps: true) // accessory app 需 activate 才能把弹窗带到前台
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "确认执行危险能力：\(cap.id)"
        alert.informativeText = "\(cap.summary)\n\n这是 dangerous 档能力，确认只在宿主 GUI 完成，CLI 不会代你决定。"
        alert.addButton(withTitle: "确认执行") // .alertFirstButtonReturn
        alert.addButton(withTitle: "拒绝")      // .alertSecondButtonReturn；语义必须明示 deny，「取消」会被读成「关掉对话框」

        // 自动拒绝定时器：必须加进 .modalPanel 模式，否则 runModal 的模态循环里不会触发
        var timer: Timer?
        if let secs = autoDenySeconds {
            let t = Timer(timeInterval: secs, repeats: false) { _ in
                s2log("自动拒绝计时到（\(secs)s），关闭弹窗")
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
            }
            RunLoop.main.add(t, forMode: .modalPanel)
            RunLoop.main.add(t, forMode: .default)
            timer = t
        }

        let resp = alert.runModal()
        timer?.invalidate()
        return resp == .alertFirstButtonReturn
    }
}

@main
@MainActor
struct S2Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
