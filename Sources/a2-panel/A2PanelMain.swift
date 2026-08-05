// a2-panel —— 菜单栏壳的可执行入口(10 票;.app 显示名「A2 Panel」)。
//
// 壳里只有「建 NSApplication、挂 AppDelegate、run」三行,全部装配在 `A2PanelMacOS` 库里
// (与 11 票 `aahost` 的安排同一条理由:SPM 的可执行本身产不出 `.app` bundle,
//  bundle 由 `Scripts/build-app.sh` 手工组 + ad-hoc 签名产出)。
//
// ⚠️ 本文件**不叫 main.swift**:main.swift 的顶层代码是 nonisolated 上下文,
//    构造 `@MainActor` 的 AppDelegate 会直接编译报错。用 `@main @MainActor struct` 才拿得到主 actor 隔离。
//
// `.accessory` = LSUIElement 菜单栏形态(无 Dock 图标、无主菜单)。Info.plist 里也写了
// `LSUIElement`,两处都要:plist 管 Finder/Dock 怎么看待这个 bundle,这一行管进程自己的激活策略
// (裸可执行直接跑时没有 plist,靠的就是它)。

import AppKit
import A2PanelMacOS

@main
@MainActor
struct A2PanelMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = A2PanelAppDelegate()
        app.delegate = delegate
        app.run()
    }
}
