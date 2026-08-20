// A2Panel ——「给 AI 助手的使用说明」的**文本生成**(14 票 / 05 票逐字定稿)。纯函数,零 AppKit。
//
// 这段文本是 a2 面向 agent 的入口:小白把它贴给自己的 AI 助手,助手从此知道 CLI 在哪、
// 怎么调、边界是什么。**第一读者是 agent**,人以第三人称出现。
//
// 两版随状态自适应(05 票裁定):
//   * 服务未装 → 「未安装版」:只教 agent 引导用户点菜单装,**明文禁止绕后调 .app 内嵌 bin**;
//   * 服务已装 → 「已安装版」:调用方式 + 当前状态块 + 常用命令 + 配置归 agent + 边界两条。
// 文案与 `.scratch/mihomo-embedded/assets/agent-guidance-copy-mock.html`(标签页①②)同源;
// 那份 mock 是**定稿**,这里改一个字都要回去对一次。

import Foundation

public enum A2AssistantGuide {

    /// 生成说明全文。`home` 取内核自报的那一个(`StatusResult.home`),连不上内核时退回缺省 `~/.a2`。
    public static func text(serviceInstalled: Bool,
                            connected: Bool,
                            kernelVersion: String?,
                            mihomo: A2BootstrapMihomoFacts?,
                            systemProxyOn: Bool?,
                            home: String?) -> String {
        serviceInstalled
            ? installedText(connected: connected, kernelVersion: kernelVersion,
                            mihomo: mihomo, systemProxyOn: systemProxyOn, home: home)
            : notInstalledText()
    }

    static func notInstalledText() -> String {
        [
            "【给 AI 助手的 A2 使用说明 · 尚未安装】",
            "",
            "用户已下载 A2 Panel,但尚未安装内核服务——A2 的 CLI 此刻还不存在。",
            "",
            "请这样帮助用户:",
            "1. 请用户点击菜单栏的 A² 图标 →「安装并启动内核」,一次点击即完成",
            "   (含开机自启;若首启欢迎弹窗还开着,点「安装并启动」即可)。",
            "2. 安装完成后,请用户再点一次「复制 AI 助手使用说明」,把新的说明粘贴给你——",
            "   那份说明含 CLI 路径与当前状态,你就可以开始工作了。",
            "",
            "注意:不要尝试直接调用 .app 包内的二进制替用户安装——安装 A2 是用户本人的一次显式点击。",
        ].joined(separator: "\n")
    }

    static func installedText(connected: Bool,
                              kernelVersion: String?,
                              mihomo: A2BootstrapMihomoFacts?,
                              systemProxyOn: Bool?,
                              home: String?) -> String {
        let root = home ?? "~/.a2"
        let bin = "\(root)/bin/a2"
        let kernelLine: String = {
            guard connected else { return "内核服务:未连接(装了但可能没在跑——让 agent 先跑 status 看看)" }
            return "内核服务:运行中" + (kernelVersion.map { "(v\($0))" } ?? "")
        }()
        let mihomoLine: String = {
            guard let mihomo else { return "代理内核 mihomo:状态未知(跑一次 mihomo status 即知)" }
            switch mihomo.mode {
            case .off:      return "代理内核 mihomo:未启用"
            case .observe:  return "代理内核 mihomo:observe(只读旁观本机已有 mihomo)"
            case .embedded:
                let state: String
                switch mihomo.embeddedState {
                case .running: state = mihomo.hasProxies ? "运行中" : "运行中 · 尚未配置节点"
                case .stopped: state = "未在运行"
                case .failed:  state = "故障(已暂停重拉)"
                }
                return "代理内核 mihomo:embedded · \(state)"
            }
        }()
        let proxyLine: String = {
            guard let systemProxyOn else { return "系统代理:状态未知" }
            return systemProxyOn ? "系统代理:已接管" : "系统代理:未接管"
        }()

        return [
            "【给 AI 助手的 A2 使用说明】(A2 Panel 生成)",
            "",
            "本机装有 A2——agent-first 的代理管理工具。用户期望你通过它了解并管理本机代理。",
            "",
            "■ 调用方式",
            "· CLI 完整路径:\(bin)(刻意不在 PATH 上,请始终用完整路径调用)",
            "· 每条命令都加 --json:stdout 上只有一条 JSON 包封,成功失败同一形状;",
            "  失败时读 error.code 与 error.guidance——guidance 里有修复步骤与命令原文,照做即可。",
            "· 全貌以本机为准:\(bin) help;\(bin) capabilities list --json",
            "",
            "■ 当前状态(复制那一刻由面板拼入)",
            "· \(kernelLine)",
            "· \(mihomoLine)",
            "· \(proxyLine)",
            "",
            "■ 常用命令",
            "\(bin) status --json                 # 内核状态",
            "\(bin) mihomo status --json          # 代理内核状态(含配置路径与下一步指引)",
            "\(bin) mihomo restart --json         # 改完配置后重启生效",
            "\(bin) proxy status --json           # 代理运行面",
            "\(bin) proxy system enable --json    # 接管系统代理(disable 对称)",
            "",
            "■ 配置归你(agent)管",
            "mihomo 的配置是一份 YAML,路径以 mihomo status 的输出为准。你可以直接读改它;",
            "改完执行 mihomo restart 生效。把机场订阅的节点合并进配置也是你的活:直接读订阅 YAML、",
            "把 proxies 段并进配置——只搬节点,别把订阅里的 rules 整份搬来覆盖用户已有策略。",
            "",
            "■ 边界(务必遵守)",
            "· dangerous 档操作会被内核默拒并附「人类如何完成」的指引:转告用户,不要试图绕过。",
            "· 本机若有用户自己装的 mihomo(非 A2 管理):不要动它——A2 对它只读,你也应当只读。",
        ].joined(separator: "\n")
    }
}
