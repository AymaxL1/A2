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
// 线程纪律
// ============================================================================
// 会话跑在自己的线程上;它的回调**可能在任何线程**。所以这里每个回调都立刻 `DispatchQueue.main.async`
// 投递,自己不做任何事 —— 内核对慢消费者会主动断连(推送积压 > 4 MiB),读循环不能被 UI 拖住。

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

    public override init() { super.init() }

    /// `<A2_HOME>/run/kernel.sock`,`A2_HOME` 缺省 `~/.a2`(与内核 `runtime/paths.ts` 同一条约定)。
    ///
    /// 壳**不隐式拉起 daemon**(ADR 0008 第 6 条):连不上就是连不上,菜单如实说,
    /// 由用户自己去敲 `a2 service install`。
    public static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = env["A2_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".a2")
        return (home as NSString).appendingPathComponent("run/kernel.sock")
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = A2MenuBarController(
            onInvoke: { [weak self] capability, input in
                self?.session?.call(capability: capability, input: input)
            },
            onAbout: { [weak self] in self?.about.show() },
            onQuit: { NSApp.terminate(nil) })
        self.menuBar = menuBar
        // 先渲染一份「还没连上」的菜单:壳一起来就该有东西可看,而不是一个空图标。
        menuBar.render(A2MenuModelBuilder.build(state: A2PanelState()))

        let confirmations = A2ConfirmationPresenter { [weak self] id, decision in
            self?.session?.resolve(confirmation: id, decision: decision)
        }
        self.confirmations = confirmations

        let session = A2PanelSession(
            configuration: .init(
                socketPath: Self.defaultSocketPath(),
                identity: A2ClientIdentity(name: "a2-panel", version: A2PanelBuild.version)),
            delegate: self)
        self.session = session
        session.start()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        confirmations?.dismissAll()
        session?.stop()   // 只断连,别的什么都不做(见文件头)
    }
}

extension A2PanelAppDelegate: A2PanelSessionDelegate {
    nonisolated public func panelSession(_ session: A2PanelSession, didUpdate state: A2PanelState) {
        DispatchQueue.main.async { [weak self] in
            self?.menuBar?.render(A2MenuModelBuilder.build(state: state))
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
