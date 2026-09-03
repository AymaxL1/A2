// A2PanelMacOS —— 装配层(10 票):把会话、菜单、确认器接在一起,一行业务逻辑都不加。
//
// ============================================================================
// 「退出 A2」在这里的落实(2026-08-22 小白心智模型改判)
// ============================================================================
// `applicationShouldTerminate` 先执行一条可验的安全链:
//   * 若系统代理由 a2 接管,先显式执行 `a2 proxy off` 精确还原;
//   * 再执行 `a2 service stop`;daemon 的退出钩子负责收掉内嵌 mihomo;
//   * 两步成功才允许 AppKit 真正终止。任一步失败都留在 UI 并如实报错。
// `applicationWillTerminate` 只负责最后断开会话。
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
//     * 启动**不自动装**;但已安装且被 Panel 正常停下的服务会随下次打开 Panel 重新拉起;
//     * 改变系统状态的仍然只有**用户的一次显式点击**:首启说明框上那个按钮,或菜单里那一项。
//       首启弹不弹由一个纯函数决定(`A2BootstrapDecision`,四个输入全组合有断言);
//       用户点过「稍后」就再不自动问,菜单项常驻可随时再装。
//     * 壳仍然**不含业务逻辑**:它只发五条白名单命令、解析机读 JSON、呈现结果
//       (ADR 0012 第 3 条;装什么、幂等不幂等、要不要重启,全在内核的 `service install` 里)。
// 反过来,**隐式那条仍然禁止**:没有"发现连不上就悄悄装一个"、没有定时自查、没有静默升级。
//
// ============================================================================
// URL 分流(03 票):壳在这条路上只是一根管子
// ============================================================================
// 系统把链接交给 A2 Panel(它注册成了默认浏览器,注册本身归 05 票的 Info.plist)——
// 两条投递路都挂着:`kAEGetURL` 苹果事件(拿得到**原样字符串**)与 `application(_:open:)`
// (AppKit 已经装成 `URL` 的那条)。谁先谁后由 AppKit 定,同一条 URL 的重复投递由
// `A2URLForwarder` 按字符串相等去重。
// 收到之后这里**一个字节都不解析**,直接交给 `A2URLForwarder`(纯逻辑,四条硬边界的落点)。
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
    /// URL 转发与降级兜底(03 票)。会话在时转发经它入队,会话不在时它自己走兜底。
    private var urlForwarder: A2URLForwarder?

    /// 引导执行器的编排者。没有内嵌 bin 时它也在,只是**什么都不做**(`runner == nil`)。
    private var bootstrap: A2BootstrapCoordinator?
    /// 最近一次的两份状态。菜单是它们俩的纯函数,任一变了都重渲染一整份。
    private var panelState = A2PanelState()
    private var bootstrapState = A2BootstrapState.hidden
    /// 首启说明框**至多弹一次**(每次启动)。判据本身是纯函数,这个标记只防"同一次启动里弹两遍"。
    private var firstRunPromptShown = false
    private var terminationPending = false
    private var terminationReady = false

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
            onBootstrap: { [weak self] action, purge in self?.bootstrap?.perform(action, purge: purge) },
            onLocal: { [weak self] action in self?.performLocal(action) },
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
            delegate: self,
            // URL 接管的机械执行器(04 票)。装配也只有一行:动作走 NSWorkspace 的新 API,
            //   判断一条都不在这里 —— 全在 `A2URLRouterExecutorRunner`(纯逻辑,零判断有断言守着)。
            executor: A2URLRouterExecutorRunner(
                setter: A2WorkspaceDefaultHandlerSetter(),
                log: { [weak self] line in self?.writeLog(line) }))
        self.session = session
        session.start()

        // URL 分流(03 票)。装配就三行:转发走会话、兜底走 NSWorkspace、通知走 UNUserNotificationCenter。
        //   判断一条都不在这里 —— 全在 `A2URLForwarder`(纯逻辑,四条硬边界有断言守着)。
        urlForwarder = A2URLForwarder(
            router: session,
            opener: A2WorkspaceFallbackBrowser(),
            notifier: A2UserNotificationNotifier(),
            defaults: A2UserDefaultsURLRouterStore(),
            log: { [weak self] line in self?.writeLog(line) })
        // 两条投递路都挂上(见文件头「URL 分流」一节)。`kAEGetURL` 这条拿得到**原样字符串**,
        //   所以它是首选;`application(_:open:)` 那条由 AppKit 决定要不要走,重复投递会被去重。
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))

        // 问内嵌 bin 的版本 + 服务态,**各一次**(不轮询)。答案回来时再决定首启弹不弹。
        bootstrap.probe()
    }

    // MARK: - URL 事件(两条投递路,同一个出口)

    /// `kAEGetURL`:拿到的是**原样字符串**,原样往下传 —— 不解析、不改写、不记内容。
    @objc private func handleGetURLAppleEvent(_ event: NSAppleEventDescriptor,
                                              withReplyEvent reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            writeLog("收到一条 URL 事件,但取不出直接参数 —— 丢弃")
            return
        }
        urlForwarder?.handle(url)
    }

    /// LaunchServices 那条路(AppKit 已经把它装成 `URL`)。
    ///
    /// 这里只能拿到 `absoluteString`(原样字符串在 AppKit 里已经过了一手)—— 壳仍然不解析、不改写,
    /// 只是把手里这一份原样交出去。
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { urlForwarder?.handle(url.absoluteString) }
    }

    // MARK: - 引导(全部在主线程)

    private func bootstrapDidChange(_ state: A2BootstrapState) {
        bootstrapState = state
        render()
        maybePresentFirstRunPrompt()
    }

    /// 首启说明框。**判据是纯函数**(`A2BootstrapDecision`),这里只负责"弹"与"记住用户说了什么"。
    ///
    /// 「会话中途不再弹」那条不靠这里的 `firstRunPromptShown` —— 它只挡"同一次启动里弹两遍"。
    /// 真正管住它的是判据里的 `hasUsedBootstrap`(用户一点引导项就置位,见 `A2BootstrapCoordinator.perform`),
    /// 于是"卸载收场后又冒出来问装回去"这件事在**编排层**就不成立,有回归用例钉着。
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

    /// 面板本地动作(14 票 / 08 票加了第二条)。两条都只做一件事:把一段文本拷进剪贴板。
    /// 文本由纯函数生成(`A2AssistantGuide`);这里只负责取状态、上剪贴板、给反馈。
    private func performLocal(_ action: A2PanelLocalAction) {
        switch action {
        case .copyInitializeA2Prompt:
            let connected: Bool = {
                if case .connected = panelState.connection { return true }
                return false
            }()
            // 服务态问不到时按"连上了就算装了"退一步:连得上内核,CLI 当然存在。
            let serviceInstalled = bootstrapState.serviceState.map { $0 != .notInstalled } ?? connected
            presentForAssistant(A2AssistantGuide.initializationPrompt(serviceInstalled: serviceInstalled),
                                title: "初始化 A2（添加到 AI 助手）",
                                note: "复制后粘贴给你的 AI 助手;它会创建或更新名为 a2 的 skill。")
        case .copyInstallMihomoPrompt:
            presentForAssistant(A2AssistantGuide.installMihomoPrompt,
                                title: "把这段指令交给你的 AI 助手",
                                note: "它会先读本机的使用说明,再按内核当下给出的步骤配好代理;要动你的东西时会先问你。")
        case .copySystemProxyPrompt:
            presentForAssistant(A2AssistantGuide.systemProxyPrompt,
                                title: "把这段指令交给你的 AI 助手",
                                note: "接管系统代理要看本机网络环境行事,所以交给它。要关掉随时回菜单点「关闭系统代理(还原)」。")
        }
    }

    /// 呈现全文 + 上剪贴板(04 票「复制并反馈」→ 2026-08-22 用户改判为**先看清再复制**)。
    ///
    /// 旧行为是"点了就复制,再弹一句已复制":贴出去的是什么,人从头到尾没见过。而这两段文本
    /// 恰恰是**要交给 agent 去动这台机器**的东西 —— 看不见就等于闭着眼睛授权。于是改成:
    /// 弹窗里把全文原样摆出来(可选中、可滚动),人读完自己按「复制」。
    /// 「关闭」那一路**一个字节都不进剪贴板**:不想复制的人不该被塞一嘴。
    private func presentForAssistant(_ text: String, title: String, note: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = note
        alert.addButton(withTitle: "复制")
        alert.addButton(withTitle: "关闭")
        alert.accessoryView = Self.selectableTextView(text)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 弹窗里那块正文:**可选中、可滚动、不可编辑**。
    ///
    /// 用 `NSTextView` 而不是 `NSTextField`:人可能只想拷其中一条命令去自己敲,而 label 选不中。
    /// 高度按内容算并封顶 —— 说明全文比指令长得多,固定高度不是嫌它挤就是留一大片空白。
    private static func selectableTextView(_ text: String) -> NSView {
        let width: CGFloat = 460
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let textView = NSTextView()
        textView.string = text
        textView.font = font
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        textView.sizeToFit()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width,
                                                height: min(max(textView.frame.height + 8, 120), 380)))
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .lineBorder
        return scroll
    }

    public func applicationWillTerminate(_ notification: Notification) {
        confirmations?.dismissAll()
        session?.stop()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady { return .terminateNow }
        if terminationPending { return .terminateLater }
        terminationPending = true
        bootstrap?.shutdownForQuit(
            restoreSystemProxy: panelState.proxy.systemProxyTakenOver
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.terminationReady = true
                self.session?.stop()
                sender.reply(toApplicationShouldTerminate: true)
            case let .failure(failure):
                self.terminationPending = false
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "A2 尚未退出"
                alert.informativeText = failure.displayLine
                alert.addButton(withTitle: "知道了")
                alert.runModal()
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

extension A2PanelAppDelegate: A2PanelSessionDelegate {
    nonisolated public func panelSession(_ session: A2PanelSession, didUpdate state: A2PanelState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 断→连的**那一帧**重问一次服务态:那是"有人把内核跑起来了"的唯一可靠信号,
            //   也是"用户在面板之外装了服务"这条路上,面板唯一有机会纠正陈旧服务态的时刻。
            //   判据是纯函数(有断言),这里只负责在对的时刻调它。事件驱动一次,**不轮询**。
            let shouldRefresh = A2BootstrapDecision.shouldRefreshServiceState(
                previous: self.panelState.connection, current: state.connection)
            self.panelState = state
            self.render()
            // 03 票:快照里的兜底浏览器**顺手落盘**,并在"断→连"那一帧重置通知节流位。
            //   两件事都在 `A2URLForwarder` 里判(纯逻辑、幂等),这里只负责每次都喂给它。
            self.urlForwarder?.observe(state)
            if shouldRefresh { self.bootstrap?.refreshServiceStatus() }
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
        A2PanelAppDelegate.writeLogLine(line)
    }
}

extension A2PanelAppDelegate {
    /// 壳的日志只写 stderr。**事件的权威落点在内核**(NDJSON 审计日志 + `a2 arbitration log` 可查)——
    /// 壳缺席时那边照样记(08 票已实现),所以这里没有也不该有第二份日志文件。
    ///
    /// URL 分流那条路也走这里,且**永远不会带上 URL**:脱敏在源头做(`A2URLForwarder` 压根不把
    /// URL 交给日志),而不是在这里过滤 —— 过滤器迟早有一处会漏。
    nonisolated static func writeLogLine(_ line: String) {
        FileHandle.standardError.write(Data("[a2-panel] \(line)\n".utf8))
    }

    nonisolated func writeLog(_ line: String) { A2PanelAppDelegate.writeLogLine(line) }
}

/// 壳自报的版本(**不构成身份**,只进审计与展示 —— 内核 V1 不验签)。
public enum A2PanelBuild {
    public static let version = "0.1.0"
}
