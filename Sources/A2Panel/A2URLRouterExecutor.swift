// A2Panel —— **机械执行器**(url-router 施工 04 票,spec §5/§6.3;ADR 0008 第 5 条修订的第②条例外)。
//
// ============================================================================
// 这个文件的全部职责,以及它**明确不做**的事
// ============================================================================
// 内核经 UDS 推来一帧 `url-router-execute`,壳做且只做三件机械事:
//   ① 把 bundle id 解析成 app URL(解析不到就如实说"目标 app 不存在",**一个系统 API 都不调**);
//   ② 逐 scheme 调 `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:completionHandler:)`,
//      逐 scheme 收 completion;
//   ③ 把结果原样回传(NSError 的 domain/code/描述三件套照抄)。
//
// **零判断**是这一族的红线,它在代码里的落点是:本文件里没有一个 `if` 是关于"该不该做"的。
//   * 不判断 bundleID 是哪一个 —— 这一趟是接管还是还原,内核已经算好了写在帧上;
//     **本文件里连一个 bundle id 字面量都没有**(有源码级断言盯着);
//   * 不判断 scheme 该不该设(帧上写了哪些就设哪些);
//   * **不判断 NSError 是不是"用户取消"** —— 那需要认得 domain/code,而认它就等于让壳替内核
//     决定一次 dangerous 调用的收场。真值只有一份,在内核的映射表里。
//     (spec §11 遗留项:取消时的真实 domain/code 归 06 票真机回填。回填之后**也只加一处判断**,
//      而且要连同「谁来判」这个问题一起过一次 CR —— 眼下壳只报 confirmed / error。)
//   * 不自己设第二个钟:内核那侧有 120s 的窗,一件事只该有一个人计时。
//
// **禁旧 LS API**:`LSSetDefaultHandlerForURLScheme` 那一族已弃用,而且**结果不可感知**
// (返回码即时给出,不含用户在弹框上点了什么)—— 它不满足 ADR 0015 那三条判据的第三条,
// 用它就等于把"系统弹框当确认器"这条路的地基抽掉。有源码级断言盯着这个记号。
//
// ============================================================================
// 为什么执行动作经协议注入
// ============================================================================
// 真调一次 `setDefaultApplication` 会**真的改掉这台机器的默认浏览器并弹两个系统框**。
// 门禁里绝不能发生这种事,所以动作走 `A2DefaultHandlerSetting`,测试注入假件 ——
// 于是"帧 → 逐 scheme → 回执"这条链验得全,而 AppKit 的那一行只在真壳里跑。

import Foundation
import A2Contract

/// 把某个 scheme 的默认 handler 设成某个 app(实现者在 A2PanelMacOS 里调 `NSWorkspace`)。
public protocol A2DefaultHandlerSetting: AnyObject, Sendable {
    /// 把 bundle id 解析成 app 的位置。解析不到就是 `nil` —— **那是一句真话,不是错误**
    /// (目标 app 真的不在这台机器上),调用方据此如实回报而不调任何系统 API。
    func locateApplication(bundleID: String) -> URL?

    /// 把 `scheme` 的默认 handler 设成 `applicationURL`。
    ///
    /// **`completion` 在用户点完系统弹框之后才回调**(01 研究票钉死的事实,也是"系统弹框当确认器"
    /// 这条路的全部技术前提)。实现者必须保证它**恰好被调用一次**,可能在任意线程。
    func setDefaultApplication(
        at applicationURL: URL, toOpenURLsWithScheme scheme: String,
        completion: @escaping @Sendable ((any Error)?) -> Void)
}

/// 收到一帧执行指令之后,壳该怎么做(纯逻辑,可在 `swift test` 里逐条断言)。
///
/// **线程**:`run` 从会话线程调进来,`completion` 可能在任意线程被调到;内部那份逐 scheme 的账本
/// 上锁保护。锁里**不做 I/O**,也不回调外面。
public final class A2URLRouterExecutorRunner: @unchecked Sendable {

    private let setter: A2DefaultHandlerSetting
    private let log: (String) -> Void

    public init(setter: A2DefaultHandlerSetting, log: @escaping (String) -> Void = { _ in }) {
        self.setter = setter
        self.log = log
    }

    /// 执行一帧指令,做完了把回执交出去(**恰好一次**)。
    ///
    /// 顺序是语义的一部分:**先解析目标,再一个 scheme 一个 scheme 地设**。解析不到就直接收场 ——
    /// 那时 `perScheme` 是空的,而空表说的正是"压根没轮到",不是"试了没成"。
    public func run(
        _ command: A2URLRouterExecuteCommand,
        completion: @escaping @Sendable (A2URLRouterExecutorReportParams) -> Void
    ) {
        guard let application = setter.locateApplication(bundleID: command.bundleID) else {
            // 一个系统 API 都没调、一个框都没弹 —— spec §5 的「前置报错」在壳这一侧的落点。
            log("执行指令帧:目标 app 不存在(\(command.bundleID)),一个系统调用都没发")
            completion(A2URLRouterExecutorReportParams(
                execution: command.id,
                outcome: .error,
                perScheme: A2URLRouterPerScheme(),
                error: "目标 app 不存在:urlForApplication(withBundleIdentifier:) 解析不到 \(command.bundleID)"))
            return
        }

        let ledger = Ledger(expected: command.schemes, execution: command.id, completion: completion)
        log("执行指令帧:把 \(command.schemes.map(\.rawValue).joined(separator: "+")) 交给 \(command.bundleID),等系统弹框")
        for scheme in command.schemes {
            setter.setDefaultApplication(at: application, toOpenURLsWithScheme: scheme.rawValue) {
                [weak self] error in
                self?.log("执行指令帧:\(scheme.rawValue) 的 completion 回来了(\(error == nil ? "成了" : "带着错误"))")
                ledger.record(scheme, error)
            }
        }
    }

    /// 逐 scheme 的账本:**收齐了才收场,而且只收场一次**。
    ///
    /// 为什么要它:两个 scheme 是两次独立的异步回调,谁先谁后不定;没有这本账,
    /// 要么只报了先回来的那一个,要么同一条回执发两遍(内核那侧第二条会拿 `*_unknown`,
    /// 而那条错误看起来像壳出了 bug —— 实际上是壳的账没记对)。
    private final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private let expected: [A2URLRouterScheme]
        private let execution: String
        private var perScheme = A2URLRouterPerScheme()
        private var remaining: Int
        private var completion: ((A2URLRouterExecutorReportParams) -> Void)?

        init(
            expected: [A2URLRouterScheme], execution: String,
            completion: @escaping (A2URLRouterExecutorReportParams) -> Void
        ) {
            self.expected = expected
            self.execution = execution
            self.remaining = expected.count
            self.completion = completion
        }

        func record(_ scheme: A2URLRouterScheme, _ error: (any Error)?) {
            lock.lock()
            // 同一个 scheme 回两次(实现者违约)不该让计数穿底 —— 记新的,但只扣一次账。
            if perScheme[scheme] == nil { remaining -= 1 }
            perScheme = perScheme.setting(scheme, Self.report(error))
            let done = remaining <= 0
            let settle = done ? completion : nil
            if done { completion = nil }
            let snapshot = perScheme
            lock.unlock()

            guard let settle else { return }
            // **壳不判断"这是不是用户取消"**:它只知道全成了没有(见文件头零判断那一段)。
            let allOK = expected.allSatisfy { snapshot[$0]?.ok == true }
            settle(A2URLRouterExecutorReportParams(
                execution: execution,
                outcome: allOK ? .confirmed : .error,
                perScheme: snapshot))
        }

        /// NSError → 原样三件套。**不翻译、不归类、不猜**。
        private static func report(_ error: (any Error)?) -> A2URLRouterSchemeReport {
            guard let error else { return A2URLRouterSchemeReport(ok: true) }
            let nsError = error as NSError
            return A2URLRouterSchemeReport(
                ok: false,
                error: A2URLRouterExecutorError(
                    domain: nsError.domain,
                    code: nsError.code,
                    // `localizedDescription` 在任何 NSError 上都非空(系统会兜一句),
                    // 但契约要 min(1) —— 万一真是空串,给一句可读的占位而不是让内核解不动这一帧。
                    description: nsError.localizedDescription.isEmpty
                        ? "(系统没有给出描述)" : nsError.localizedDescription))
        }
    }
}
