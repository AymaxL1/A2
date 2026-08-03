// aahost —— GUI 宿主的**薄可执行壳**(11 票新建)。
//
// 为什么单独有这个 target:
//   07 票架构映射定 `AAHostMacOS` 是「库」(Host Port 的 macOS 实现),不能改成 executableTarget;
//   而 SPM 要产出可执行必须有一个真的 executable target。故把 `@main` 从 `AAHostMacOS/HostApp.swift`
//   搬到这里 —— 库保持是库,壳只负责「建 NSApplication、挂 AppDelegate、跑起来」这三行。
//   (原计划归 12 票,因 11 票换引擎需要真 executable target 而提前;见 HostApp.swift 同口径注释。)
//
// 12 票会把本可执行打进 XcodeGen 的 `.app` bundle(LSUIElement);到那时本文件不需要再动 ——
//   壳里已经没有任何业务逻辑,全部在 `AAHostMacOS` 库里。
//
// 文件名**刻意不叫 main.swift**:main.swift 的顶层代码不是 `@MainActor` 上下文,不能在那里构造
//   `@MainActor` 的 `AppDelegate`(S1/S2 已验证)。改用 `@main @MainActor struct` + 非 main.swift 文件名,
//   与 `Sources/aa/HelpAndMain.swift`、`Sources/aa-agent/AAAgentMain.swift` 同款做法。

import AppKit
import AAHostMacOS

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
