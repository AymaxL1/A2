// A2Panel ——「给 AI 助手的使用说明」的**文本生成**(14 票 / 05 票定稿,08 票改判已装版)。
// 纯函数,零 AppKit。
//
// 这段文本是 a2 面向 agent 的入口:小白把它贴给自己的 AI 助手,助手从此知道 CLI 在哪、
// 怎么调、边界是什么。**第一读者是 agent**,人以第三人称出现。
//
// 三段文本,各有各的处境:
//   * 服务未装 → 「未安装版」(05 票原样):只教 agent 引导用户点菜单装,**明文禁止绕后调 .app 内嵌 bin**;
//   * 服务已装 → 「入口版」(**08 票改判**):从"全文副本"缩成**一句指针** —— 全文改由内核自报
//     (`a2 guide`)。理由:说明要随内核一起升级,而剪贴板里那份是复制那一刻的快照;两处各写一份
//     的口径迟早会分家,贴出去的还未必是本机这版内核的说法。壳这边少一份会漂的长文,
//     agent 则永远读到当下这台机器上真正生效的那一份;
//   * 「安装 mihomo」入口 → `installMihomoPrompt`(08 票新增):用户点一下,复制一段**给 agent 的
//     指令**(先读说明、再按 mihomo status 的 guidance 走),把小白主流程从菜单接回对话里。
// 未安装版的文案仍与 `.scratch/mihomo-embedded/assets/agent-guidance-copy-mock.html`(标签页①)同源。

import Foundation

public enum A2AssistantGuide {

    /// 生成要复制的那段文本。
    ///
    /// **08 票起只剩一个入参**:已装版不再拼当前状态(内核态 / mihomo 态 / 系统代理态),
    /// 因为那些事实 agent 自己跑一条 `status` 就问得到,而且问到的是**此刻**的,不是复制那一刻的。
    /// 留着一堆只为拼快照而存在的参数,只会让人以为这段文本还在反映什么。
    public static func text(serviceInstalled: Bool) -> String {
        serviceInstalled ? installedText() : notInstalledText()
    }

    /// 「安装 mihomo(复制指令给 AI 助手)」那一项呈现并复制的东西(08 票初稿→2026-08-22 用户改判)。
    ///
    /// 与上面两段的分野:那两段是**说明**(我是什么、怎么调),这一段是**指令**(请你替我做这件事)。
    /// 初稿只把 agent 引到 guidance 上(「照 status 说的办」),用户裁定改**明文**:五步流程原文写出来,
    /// 人复制之前自己就能读懂要发生什么 —— prompt 是给人过目再贴的,不该把内容藏在命令输出里。
    /// 防漂的锚仍在:每步动手前以 `mihomo status` 的 guidance 为准(比如已启用的机器,guidance 会直接跳到配置)。
    public static let installMihomoPrompt = [
        "【请帮我把代理用起来】",
        "1. 先运行 ~/.a2/bin/a2 guide,阅读本机 A2 的使用说明(给 AI 助手的)。",
        "2. 然后按下面流程把内置代理配好。每步动手前先跑 ~/.a2/bin/a2 mihomo status --json,",
        "   以它输出里的 guidance 为准(与下面冲突时听 guidance 的,它知道本机现状):",
        "   ① 看现状:~/.a2/bin/a2 mihomo status --json",
        "   ② 与我确认后启用内置代理内核:~/.a2/bin/a2 mihomo enable --mode=embedded --json",
        "      (首次会下载 mihomo,约 15 MB)",
        "   ③ 问我要机场订阅链接(或节点信息),读取后把其中的节点(proxies)合并写进",
        "      mihomo 的配置文件 —— 路径以 status 输出为准;只搬节点与所需分组,",
        "      不要把订阅里的 rules 整份搬来覆盖已有策略",
        "   ④ 重启生效:~/.a2/bin/a2 mihomo restart --json",
        "   ⑤ 验证可用:~/.a2/bin/a2 proxy status --json,并把结果告诉我",
        "要做选择、要下载、要改动我的东西时,先征得我的同意。",
    ].joined(separator: "\n")

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
            "   那份说明会告诉你 CLI 在哪、以及怎么读到完整用法,你就可以开始工作了。",
            "",
            "注意:不要尝试直接调用 .app 包内的二进制替用户安装——安装 A2 是用户本人的一次显式点击。",
        ].joined(separator: "\n")
    }

    /// 已装版 = **一句指针**(08 票逐字定稿)。全文在内核里(`a2 guide`),这里不再抄第二份。
    static func installedText() -> String {
        [
            "【给 AI 助手的 A2 使用说明 · 入口】",
            "本机装有 A2(agent-first 的代理管理工具)。完整使用说明内置在 CLI 里,请先运行:",
            "  ~/.a2/bin/a2 guide",
            "照说明操作即可。(CLI 完整路径 ~/.a2/bin/a2,刻意不在 PATH 上。)",
        ].joined(separator: "\n")
    }
}
