// 16 票:**首启弹框的触发判据**、**断→连边沿判据** + 两处文案(ADR 0012 第 2 条)。
//
// 判据是壳唯一一处"自己决定要不要打扰用户"的地方,所以它的五个输入的**全部 64 种组合**
// 都在这里逐一断言 —— 不是抽样,是穷举。改错任何一支(比如去掉 socket 那条、或去掉
// 「已经用过引导面」那条),这套用例都会当场红(变异验证在票面实施记里有记录)。

import Testing
import A2Panel

@Suite("16 首启弹框:触发判据(五输入 × 全组合穷举)")
struct A2BootstrapDecisionTests {

    /// 全部取值:`serviceState` 含 `nil`(问不出来),故 2 × 4 × 2 × 2 × 2 = 64 种。
    private static let states: [A2BootstrapServiceFacts.State?] =
        [nil] + A2BootstrapServiceFacts.State.allCases.map { Optional($0) }

    @Test("16 穷举 64 种组合:**有且只有**「有内嵌 bin + 没谢绝过 + 没用过引导面 + 确实未安装 + socket 不在」那一种弹")
    func exactlyOneCombinationTriggers() {
        var triggered: [String] = []
        for embedded in [false, true] {
            for state in Self.states {
                for socket in [false, true] {
                    for declined in [false, true] {
                        for used in [false, true] {
                            let fire = A2BootstrapDecision.shouldPresentFirstRunPrompt(
                                embeddedBinAvailable: embedded, serviceState: state,
                                socketPresent: socket, userDeclined: declined,
                                hasUsedBootstrap: used)
                            if fire {
                                triggered.append(
                                    "embedded=\(embedded) state=\(state.map(\.rawValue) ?? "nil")"
                                    + " socket=\(socket) declined=\(declined) used=\(used)")
                            }
                        }
                    }
                }
            }
        }
        #expect(triggered == ["embedded=true state=not_installed socket=false declined=false used=false"],
                "触发组合与预期不符:\(triggered)")
    }

    @Test("16 没有内嵌 bin 就不弹(dev / 测试态没有执行器,弹了也没有能点的按钮)")
    func hiddenWithoutEmbeddedBin() {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: false, serviceState: .notInstalled,
            socketPresent: false, userDeclined: false, hasUsedBootstrap: false) == false)
    }

    @Test("16 点过「稍后」就不再纠缠(ADR 0012 第 2 条的原话)")
    func declinedMeansNeverAgain() {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: true, serviceState: .notInstalled,
            socketPresent: false, userDeclined: true, hasUsedBootstrap: false) == false)
    }

    @Test("16 用过引导面就不再弹:卸载收场 / 安装失败让服务态回到未安装,说明框**不许**趁机蹦出来")
    func usedBootstrapMeansNeverAgain() {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: true, serviceState: .notInstalled,
            socketPresent: false, userDeclined: false, hasUsedBootstrap: true) == false)
    }

    @Test("16 服务态问不出来时闭嘴:宁可少弹一次,也不在读不到状态的机器上劝人装东西")
    func unknownServiceStateIsSilent() {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: true, serviceState: nil,
            socketPresent: false, userDeclined: false, hasUsedBootstrap: false) == false)
    }

    @Test("16 已装(不论跑没跑)都不弹说明框 —— 那时用户早知道这东西是什么了",
          arguments: [A2BootstrapServiceFacts.State.installedNotRunning, .running])
    func installedMeansNoPrompt(_ state: A2BootstrapServiceFacts.State) {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: true, serviceState: state,
            socketPresent: false, userDeclined: false, hasUsedBootstrap: false) == false)
    }

    @Test("16 socket 在(有内核在跑,哪怕是手工 `a2 daemon run` 起的)就不弹 —— 劝他顶掉自己那份是添乱")
    func liveSocketMeansNoPrompt() {
        #expect(A2BootstrapDecision.shouldPresentFirstRunPrompt(
            embeddedBinAvailable: true, serviceState: .notInstalled,
            socketPresent: true, userDeclined: false, hasUsedBootstrap: false) == false)
    }

    @Test("16 `A2BootstrapState` 的便捷属性与纯函数同一个答案(没有第二套判据)")
    func stateForwardsToTheSamePredicate() {
        let yes = A2BootstrapState(embeddedBinAvailable: true, serviceState: .notInstalled)
        #expect(yes.shouldPresentFirstRunPrompt == true)
        #expect(A2BootstrapState.hidden.shouldPresentFirstRunPrompt == false)
    }
}

@Suite("16 断→连边沿:唯一该重问服务态的时刻(事件驱动一次,不轮询)")
struct A2BootstrapRefreshEdgeTests {

    @Test("16 断 → 连:触发。那是「有人把内核跑起来了」的唯一可靠信号")
    func disconnectedToConnectedFires() {
        #expect(A2BootstrapDecision.shouldRefreshServiceState(
            previous: .disconnected("未连接"), current: .connected) == true)
    }

    @Test("16 连 → 连:不触发(同一条连接上的每一帧状态更新都会走这条路,触发就成了轮询)")
    func connectedToConnectedDoesNotFire() {
        #expect(A2BootstrapDecision.shouldRefreshServiceState(
            previous: .connected, current: .connected) == false)
    }

    @Test("16 连 → 断:不触发(内核没了,问它也没用)")
    func connectedToDisconnectedDoesNotFire() {
        #expect(A2BootstrapDecision.shouldRefreshServiceState(
            previous: .connected, current: .disconnected("与内核断开,正在重连")) == false)
    }

    @Test("16 断 → 断(换了个断开原因)也不触发 —— 重连循环里这一帧会反复来")
    func disconnectedToDisconnectedDoesNotFire() {
        #expect(A2BootstrapDecision.shouldRefreshServiceState(
            previous: .disconnected("未连接"), current: .disconnected("与内核断开,正在重连")) == false)
    }
}

@Suite("16 首启说明框与卸载确认的文案(装什么 / 怎么卸 / 两个按钮)")
struct A2BootstrapCopyTests {

    @Test("16 说明框说清**装什么**:launchd 用户服务 com.a2.kernel、建 ~/.a2、开机自启归系统")
    func promptSaysWhatGetsInstalled() {
        let body = A2BootstrapPrompt.body
        #expect(body.contains("com.a2.kernel"))
        #expect(body.contains("launchd"))
        #expect(body.contains("~/.a2"))
        #expect(body.contains("开机自启"))
        #expect(body.contains("崩溃自愈"), "自愈归系统 supervisor 这件事要写明(面板不做进程监督)")
    }

    @Test("16 说明框说清**怎么卸**(菜单那条路 + CLI 那条命令)")
    func promptSaysHowToUninstall() {
        #expect(A2BootstrapPrompt.body.contains("停止并卸载内核服务"))
        #expect(A2BootstrapPrompt.body.contains("a2 service uninstall"))
    }

    @Test("16 说明框说明**不进 PATH**(ADR 0012 第 7 条:面板不提供装 CLI)")
    func promptSaysItDoesNotTouchPath() {
        #expect(A2BootstrapPrompt.body.contains("PATH"))
    }

    @Test("16 说明框说明 unit 指的是拷贝,删掉 .app 服务照跑(ADR 0012 第 4 条)")
    func promptExplainsTheCopy() {
        #expect(A2BootstrapPrompt.body.contains("~/.a2/bin/a2"))
        #expect(A2BootstrapPrompt.body.contains("服务照跑"))
    }

    @Test("16 说明框说明「稍后」之后菜单项常驻(不再纠缠 ≠ 从此装不了)")
    func promptSaysLaterIsNotForever() {
        #expect(A2BootstrapPrompt.body.contains("稍后"))
        #expect(A2BootstrapPrompt.body.contains("随时点"))
    }

    @Test("16 两个按钮就是票面钉的那两个")
    func promptButtonsArePinned() {
        #expect(A2BootstrapPrompt.installTitle == "安装并启动")
        #expect(A2BootstrapPrompt.laterTitle == "稍后")
    }

    @Test("16 装不弹确认(首启已经说明过,菜单项是用户主动点的);卸**必须**弹")
    func onlyUninstallAsksForConfirmation() {
        #expect(A2BootstrapMenuAction.install.confirmation == nil)
        #expect(A2BootstrapMenuAction.uninstall.confirmation != nil)
    }

    @Test("16 卸载确认说清口径:只拆服务,~/.a2 与那份拷贝留下(ADR 0012 第 6 条)")
    func uninstallConfirmationStatesTheScope() throws {
        let confirmation = try #require(A2BootstrapMenuAction.uninstall.confirmation)
        #expect(confirmation.body.contains("com.a2.kernel"))
        #expect(confirmation.body.contains("~/.a2"))
        #expect(confirmation.body.contains("~/.a2/bin/a2"))
        #expect(confirmation.body.contains("留下"))
        #expect(confirmation.confirmTitle == "停止并卸载")
        #expect(confirmation.cancelTitle == "取消")
    }

    @Test("16 卸载确认里「先还原系统代理」留了余地:菜单那一项断连时并不存在,得同时给 CLI 那条路")
    func uninstallConfirmationOffersBothRestorePaths() throws {
        let confirmation = try #require(A2BootstrapMenuAction.uninstall.confirmation)
        #expect(confirmation.body.contains("关闭系统代理(还原)"))
        #expect(confirmation.body.contains("a2 proxy off"),
                "菜单上没有那一项的时候(面板没连上内核),用户得知道还有终端这条路")
    }

    @Test("16 弹框正文里**不许**有 Markdown:它进的是 NSAlert 的纯文本,星号会原样画在屏幕上",
          arguments: [A2BootstrapPrompt.body, A2BootstrapPrompt.title,
                      A2BootstrapMenuAction.uninstall.confirmation?.body ?? "",
                      A2BootstrapMenuAction.uninstall.confirmation?.title ?? ""])
    func alertCopyCarriesNoMarkdown(_ text: String) {
        #expect(!text.contains("**"), "弹框文案里有 Markdown 星号,会被字面渲染:\(text)")
        #expect(!text.contains("`"), "弹框文案里有反引号,同样会被字面渲染:\(text)")
    }

    @Test("16 路径记法统一:两处弹框都用 ~/.a2/bin/a2,不混用 $A2_HOME(给人看的文案只留一种写法)")
    func copyUsesOnePathNotation() throws {
        let confirmation = try #require(A2BootstrapMenuAction.uninstall.confirmation)
        for text in [A2BootstrapPrompt.body, confirmation.body] {
            #expect(!text.contains("$A2_HOME"), "面向用户的文案里混进了 $A2_HOME:\(text)")
        }
    }
}
