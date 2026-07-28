// AAHostMacOS —— 宿主 GUI 入口。菜单栏常驻(accessory)+ 能力注册表 + UDS server。
//
// 入口用 @main @MainActor struct(顶层代码非 MainActor 上下文,不能在 main.swift 顶层构造 @MainActor 对象;S1/S2 已验证)。
// socket 路径读 Contracts 常量(AAPaths),父目录启动时自建,旧 socket 由 server bind 前 unlink。
// 本票(02)只做 list:菜单栏只读展示已注册能力 + UDS 应答 list;dangerous 确认弹窗归 03 票。

import AppKit
import AAContracts
import AAHostRuntime

/// 宿主日志助手:每行后 fflush(stdout 重定向到文件时为块缓冲,不 flush 会看不到实时日志)。
/// 串行化避免多线程 print 交错(accept/handle 都在后台线程)。
private let hostLogQueue = DispatchQueue(label: "aa.host.log")
func hostLog(_ msg: String) {
    hostLogQueue.sync {
        print("[AAHost] \(msg)")
        fflush(stdout)
    }
}

/// 启动期致命错误:打印明确 stderr + 非零退出。宿主宁可快速失败,也不「状态栏活着却无 UDS 监听」带病常驻
/// (那样 E2E 只能靠超时暴露)。退出码 1=启动失败。
func hostFatal(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("[AAHost] 致命错误: \(msg)\n".utf8))
    exit(1)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = Registry()
    var server: UDSServer!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1) socket 路径与父目录(路径常量集中在 Contracts.AAPaths);父目录建不出即快速失败,不带病常驻
        let sockPath = AAPaths.socketPath
        do {
            try FileManager.default.createDirectory(at: AAPaths.socketDirectoryURL, withIntermediateDirectories: true)
        } catch {
            hostFatal("socket 父目录创建失败(\(AAPaths.socketDirectoryURL.path)): \(error.localizedDescription)")
        }
        hostLog("socket 路径: \(sockPath)")

        // 2) 启动 UDS server(bind 前 unlink 旧 socket 在 server.start() 内做);启动失败即快速失败
        server = UDSServer(socketPath: sockPath, registry: registry)
        do {
            try server.start()
            hostLog("UDS server 已监听: \(sockPath)")
        } catch {
            hostFatal("UDS server 启动失败: \(error.localizedDescription)")
        }

        // 3) 菜单栏项(只读展示已注册能力)
        setupStatusItem()

        NSApp.setActivationPolicy(.accessory) // 无 Dock 图标,菜单栏常驻
        hostLog("启动完成。")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⚡"
        let menu = NSMenu()
        menu.addItem(withTitle: "AA 能力注册表", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for cap in registry.list() {
            // 只读项:nil action → 自动 disabled
            menu.addItem(withTitle: "\(cap.id)  ·  \(cap.risk.rawValue)  ·  \(cap.summary)",
                         action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

// 债务口径:此 @main 只是 vfsoverlay 过桥用(check.sh 单独把本库 target 编成可执行冒烟)。
// AAHostMacOS 终态是「库」(Host Port 的 macOS 实现);GUI 宿主终态是 XcodeGen app 壳(LSUIElement)。
// 归 12 票:@main 移进 app 壳、AppDelegate 转 public,本 target 保持库(见 Package.swift 同口径注释)。
@main
@MainActor
struct AAHostMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
