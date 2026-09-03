// A2PanelMacOS —— URL 分流在 macOS 上的**机械件**(03 票):把链接交出去、弹一条通知。
//
// 这个文件里没有一个判断是关于 URL 的:它收到的是一条字符串和一个 bundle id,做的是
// 「解析 app → 交给它」。要开哪个浏览器、什么时候开,全在 `A2Panel` 的 `A2URLForwarder` 里
// (那一层是纯逻辑,单测逐条钉着);这里只负责调 AppKit,以便测试**永远不会**真开浏览器、真弹通知。
//
// 两条纪律写在代码里:
//   * **永不把链接交回给自己**:A2 Panel 自己就可能是系统默认浏览器,把 URL 交给"我自己"
//     等于原地打转(spec §8 同一条理由的另一面:兜底身份必须显式,永不查系统默认)。
//   * **通知是 best-effort**:没授权就静默跳过。授权仪式是人工项(不在 03 票),
//     而"链接打开了没有"这件事不该取决于用户有没有点过那个系统弹框。

import AppKit
import Foundation
import UserNotifications
import A2Panel

/// `NSWorkspace` 版的兜底浏览器执行件。
///
/// **线程**:这两条会在会话线程或看门狗线程上被调到(内核不可达时收场的是后者),所以有意只用
/// `NSWorkspace` 里那些不要求主线程的入口 —— `urlForApplication(withBundleIdentifier:)` 是
/// LaunchServices 查询,`open(_:withApplicationAt:configuration:)` 本身就是异步式接口。
/// 反过来说:**不要**在这里碰任何 AppKit 的界面对象。
public final class A2WorkspaceFallbackBrowser: A2FallbackBrowserOpening {

    public init() {}

    /// 交给指定 bundle id 的 app。
    ///
    /// 先把 bundle id 解析成 app URL 再开(而不是 `open -b` 那种交给系统去猜):解析不到就是解析不到,
    /// 调用方据此退到下一级 —— 比让 LaunchServices 静默挑一个"它觉得合适的"app 诚实。
    public func open(_ url: String, withBundleID bundleID: String) -> Bool {
        // `URL(string:)` 只是把字符串装进 AppKit 要的类型里,**不是解析 URL 做判断**:
        // 装进去的与用户点的逐字节相同,壳既不看 host 也不看 scheme。
        guard let target = URL(string: url) else { return false }
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        // 交给自己 = 打转(用户可能把兜底浏览器错配成 com.a2.panel,或本机默认浏览器就是我们)。
        guard application.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL else {
            return false
        }
        NSWorkspace.shared.open([target], withApplicationAt: application,
                                configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    /// 最后手段:交给系统缺省 handler。调用方那侧有熄火窗防打转(`A2URLRouter.systemDefaultCooldown`)。
    public func openWithSystemDefault(_ url: String) -> Bool {
        guard let target = URL(string: url) else { return false }
        return NSWorkspace.shared.open(target)
    }
}

/// `NSWorkspace` 版的**默认 handler 设置件**(url-router 施工 04 票,spec §5)。
///
/// ============================================================================
/// 这里只有两行真正做事的代码,而它们的选型是本票的地基
/// ============================================================================
/// **必须走新 API** `setDefaultApplication(at:toOpenURLsWithScheme:completionHandler:)`(macOS 12+):
/// 它的 completion **在用户点完系统弹框之后**才回调(01 研究票钉死的 SDK 头注原文)——
/// 「结果可被发起方感知」正是 ADR 0015 那三条判据的第三条,也是"系统弹框能当确认器"的全部前提。
///
/// **禁旧 LS API**(`LSSetDefaultHandlerForURLScheme` 那一族):已弃用,而且返回码即时给出、
/// **不含用户在弹框上点了什么** —— 用它就等于把这条路的地基抽掉,却看不出任何症状
/// (命令会"成功",而系统状态没变)。有源码级断言盯着那个记号,改不回去。
///
/// **线程**:`urlForApplication(withBundleIdentifier:)` 是 LaunchServices 查询,
/// `setDefaultApplication` 本身就是异步式接口 —— 两条都不要求主线程,与本文件其余部分同一条纪律
/// (会话线程上被调到,**不要**在这里碰任何 AppKit 界面对象)。
public final class A2WorkspaceDefaultHandlerSetter: A2DefaultHandlerSetting {

    public init() {}

    public func locateApplication(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    public func setDefaultApplication(
        at applicationURL: URL, toOpenURLsWithScheme scheme: String,
        completion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        // 尾随闭包写法**不是风格选择**:这个方法在 Swift 里同时导入了 async 版与 completion 版,
        // 显式写 `completionHandler:` 标签编译不过(会被判成"多了一个参数")。
        NSWorkspace.shared.setDefaultApplication(at: applicationURL, toOpenURLsWithScheme: scheme) {
            completion($0)
        }
    }
}

/// `UNUserNotificationCenter` 版的通知件(**best-effort**)。
public final class A2UserNotificationNotifier: A2URLRouterNotifying {

    public init() {}

    public func notifyFallback(title: String, body: String) {
        // `UNUserNotificationCenter.current()` 在**没有 bundle 身份**的进程里会直接终止进程
        // (`swift build` 出来的裸壳就是这种)。所以先问一句有没有 bundle id ——
        // 这不是防御性编程,是那个 API 的真实前提。
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // **不主动要授权**:那是人工项(03 票不做)。没给就静默跳过 ——
            // 通知只是"失效可见性",链接该开的已经开了。
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request, withCompletionHandler: nil)
        }
    }
}
