// A2PanelMacOS —— 装配层(10 票):把会话、菜单、确认器接在一起,一行业务逻辑都不加。
//
// ============================================================================
// 「退出仅断连」在这里的落实(ADR 0008:「退出即还原」废除)
// ============================================================================
// `applicationWillTerminate` 只做一件事:`session.stop()`。
//   * **不**还原系统代理(那是 `a2 proxy off` 这条显式命令的事);
//   * **不**停 mihomo(它挂自己的 `com.a2.mihomo` unit,数据面不随控制面起落);
//   * **不**通知内核「我要走了」—— 断连本身就是信号:内核收到断线立即把 dangerous 降回默拒
//     (08 票已实现,壳这侧只要真的断掉即可)。
// 旧宿主在这里有一整套「退出前还原 + 持久化标记 + 下次启动自愈」的编排,新架构把它整族拆掉了
// (对等映射表 07 票 D 组:整族淘汰,理由成文)。
//
// ============================================================================
// 「壳不隐式拉起任何东西」在 16 票之后的准确形态(ADR 0012 第 2 条修订)
// ============================================================================
// 10 票时这条边界的落实方式是**壳里根本没有装内核的路**:连不上就连不上,菜单如实说,
//   用户自己去开终端敲 `a2 service install`。
// 16 票起壳自带执行器(`.app` 里那份内嵌内核 bin),于是边界的措辞必须改准 ——
//   **变的是「显式」可以从哪里发起,不是那条边界松了**:
//     * 启动**不自动装**、连不上**不自动起**、退出**不自动停**,一条都没变;
//     * 改变系统状态的仍然只有**用户的一次显式点击**:首启说明框上那个按钮,或菜单里那一项。
//       首启弹不弹由一个纯函数决定(`A2BootstrapDecision`,四个输入全组合有断言);
//       用户点过「稍后」就再不自动问,菜单项常驻可随时再装。
//     * 壳仍然**不含业务逻辑**:它只发四条白名单命令、解析机读 JSON、呈现结果
//       (ADR 0012 第 3 条;装什么、幂等不幂等、要不要重启,全在内核的 `service install` 里)。
// 反过来,**隐式那条仍然禁止**:没有"发现连不上就悄悄装一个"、没有定时自查、没有静默升级。
//
// ============================================================================
// 线程纪律
// ============================================================================
// 会话跑在自己的线程上;它的回调**可能在任何线程**。所以这里每个回调都立刻 `DispatchQueue.main.async`
// 投递,自己不做任何事 —— 内核对慢消费者会主动断连(推送积压 > 4 MiB),读循环不能被 UI 拖住。
// 引导执行器同理:子进程在后台队列上跑,结果经 `A2BootstrapCoordinator` 的 `deliver` 投回主线程。

import AppKit
import Foundation
import A2Contract
import A2Panel

@MainActor
public final class A2PanelAppDelegate: NSObject, NSApplicationDelegate {

    private var session: A2PanelSession?
    private var menuBar: A2MenuBarController?
    private var confirmations: A2ConfirmationPresenter?
    private let about = A2AboutWindow()

    /// 引导执行器的编排者。没有内嵌 bin 时它也在,只是**什么都不做**(`runner == nil`)。
    private var bootstrap: A2BootstrapCoordinator?
    /// 最近一次的两份状态。菜单是它们俩的纯函数,任一变了都重渲染一整份。
    private var panelState = A2PanelState()
    private var bootstrapState = A2BootstrapState.hidden
    /// 首启说明框**至多弹一次**(每次启动)。判据本身是纯函数,这个标记只防"同一次启动里弹两遍"。
    private var firstRunPromptShown = false

    public override init() { super.init() }

    /// `<A2_HOME>/run/kernel.sock`,`A2_HOME` 缺省 `~/.a2`(与内核 `runtime/paths.ts` 同一条约定)。
    ///
    /// 壳**不隐式拉起 daemon**(ADR 0008 第 6 条 / ADR 0012 第 2 条):连不上就是连不上,菜单如实说。
    /// 16 票起菜单里多了一条**显式**的路(用户点「安装并启动内核」),但**没有**任何自动路径。
    public static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = env["A2_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".a2")
        return (home as NSString).appendingPathComponent("run/kernel.sock")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let socketPath = Self.defaultSocketPath()

        let menuBar = A2MenuBarController(
            onInvoke: { [weak self] capability, input in
                self?.session?.call(capability: capability, input: input)
            },
            onBootstrap: { [weak self] action in self?.bootstrap?.perform(action) },
            onAbout: { [weak self] in self?.about.show() },
            onQuit: { NSApp.terminate(nil) })
        self.menuBar = menuBar

        // 引导执行器:找包里那份内核 bin。**找不到就整块隐藏** —— `swift build` 出来的裸壳没有
        //   bundle 资源,那时菜单与 10 票逐字相同(不给点了会失败的入口)。
        let embedded = A2EmbeddedKernel.locate()
        let bootstrap = A2BootstrapCoordinator(
            runner: embedded.map { A2BootstrapProcessRunner(binary: $0) },
            socketPath: socketPath,
            firstRunPromptDismissed: A2BootstrapPresenter.firstRunPromptDismissed(),
            onChange: { [weak self] state in self?.bootstrapDidChange(state) })
        self.bootstrap = bootstrap

        // 先渲染一份「还没连上」的菜单:壳一起来就该有东西可看,而不是一个空图标。
        render()

        let confirmations = A2ConfirmationPresenter { [weak self] id, decision in
            self?.session?.resolve(confirmation: id, decision: decision)
        }
        self.confirmations = confirmations

        let session = A2PanelSession(
            configuration: .init(
                socketPath: socketPath,
                identity: A2ClientIdentity(name: "a2-panel", version: A2PanelBuild.version)),
            delegate: self)
        self.session = session
        session.start()

        // 问内嵌 bin 的版本 + 服务态,**各一次**(不轮询)。答案回来时再决定首启弹不弹。
        bootstrap.probe()
    }

    // MARK: - 引导(全部在主线程)

    private func bootstrapDidChange(_ state: A2BootstrapState) {
        bootstrapState = state
        render()
        maybePresentFirstRunPrompt()
    }

    /// 首启说明框。**判据是纯函数**(`A2BootstrapDecision`),这里只负责"弹"与"记住用户说了什么"。
    private func maybePresentFirstRunPrompt() {
        guard !firstRunPromptShown, bootstrapState.shouldPresentFirstRunPrompt else { return }
        firstRunPromptShown = true
        if A2BootstrapPresenter.presentFirstRunPrompt() {
            bootstrap?.perform(.install)
        } else {
            // 「稍后」:写标记,此后不再自动问。菜单项常驻,想装随时点。
            A2BootstrapPresenter.setFirstRunPromptDismissed(true)
            bootstrap?.markFirstRunPromptDismissed()
        }
    }

    private func render() {
        menuBar?.render(A2MenuModelBuilder.build(state: panelState, bootstrap: bootstrapState))
    }

    public func applicationWillTerminate(_ notification: Notification) {
        confirmations?.dismissAll()
        session?.stop()   // 只断连,别的什么都不做(见文件头)
    }
}

extension A2PanelAppDelegate: A2PanelSessionDelegate {
    nonisolated public func panelSession(_ session: A2PanelSession, didUpdate state: A2PanelState) {
        DispatchQueue.main.async { [weak self] in
            self?.panelState = state
            self?.render()
        }
    }

    nonisolated public func panelSession(_ session: A2PanelSession, present request: A2ConfirmationRequest) {
        DispatchQueue.main.async { [weak self] in
            self?.confirmations?.present(request)
        }
    }

    nonisolated public func panelSession(_ session: A2PanelSession, dismissConfirmations ids: [String]) {
        DispatchQueue.main.async { [weak self] in
            self?.confirmations?.dismiss(ids)
        }
    }

    nonisolated public func panelSession(_ session: A2PanelSession, log line: String) {
        // 壳的日志只写 stderr。**事件的权威落点在内核**(NDJSON 审计日志 + `a2 arbitration log` 可查)——
        //   壳缺席时那边照样记(08 票已实现),所以这里没有也不该有第二份日志文件。
        FileHandle.standardError.write(Data("[a2-panel] \(line)\n".utf8))
    }
}

/// 壳自报的版本(**不构成身份**,只进审计与展示 —— 内核 V1 不验签)。
public enum A2PanelBuild {
    public static let version = "0.1.0"
}
