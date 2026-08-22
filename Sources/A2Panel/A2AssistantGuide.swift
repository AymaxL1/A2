// A2Panel ——「初始化 A2(添加到 AI 助手)」的**提示词生成**。
// 纯函数,零 AppKit。
//
// 这段文本让 agent 创建一个名为 `a2` 的个人 skill。skill 刻意保持极薄:**只调用本机
// `~/.a2/bin/a2 guide` 并按输出工作**。以后新增能力、升级说明、编号菜单与安全边界全部只改 guide,
// 不在 skill 与壳里复制第二份。
//
// 四段文本,各有各的处境:
//   * 服务未装 → 先教 agent 引导用户点菜单装,**明文禁止绕后调 .app 内嵌 bin**;安装完成后建 skill;
//   * 服务已装 → 直接建/更新薄 skill,并立即调用一次完成初始化验收;
//   * 「安装 mihomo」入口 → `installMihomoPrompt`(08 票新增):用户点一下,复制一段**给 agent 的
//     指令**(先读说明、再按 mihomo status 的 guidance 走),把小白主流程从菜单接回对话里。
//   * 「开启系统代理」入口 → `systemProxyPrompt`:交给 agent 现场判断网络环境。

import Foundation

public enum A2AssistantGuide {

    /// 生成要复制的初始化提示词。只按 CLI 是否已经可用分流,不拼任何运行状态快照。
    public static func initializationPrompt(serviceInstalled: Bool) -> String {
        serviceInstalled ? installedInitializationPrompt() : notInstalledInitializationPrompt()
    }

    /// 「安装 mihomo(复制指令给 AI 助手)」那一项呈现并复制的东西。
    ///
    /// 三版演进,最后一版是用户 2026-08-22 的裁定:初稿只说「照 status 的 guidance 办」(黑箱);
    /// 二稿把五步流程写成明文(可读了,但**同一件事在壳里又写了一份**,与 08 票「说明收进 CLI」相抵);
    /// 定稿 = 分工规范化 —— `a2 guide` 讲 A2 本身,`a2 guide --mihomo` 讲怎么配代理,
    /// 壳这边只剩两行指路。要读明文的人跑那条命令就是了,而那份明文的步骤又是 `mihomo status`
    /// 的 guidance 现渲染的:**从壳到内核,同一件事只有一处出处**。
    public static let installMihomoPrompt = [
        "【请帮我把代理用起来】",
        "1. 先运行 ~/.a2/bin/a2 guide,了解本机的 A2 怎么用。",
        "2. 再运行 ~/.a2/bin/a2 guide --mihomo,按它说的把代理配好。",
        "要做选择、要下载、要改动我的东西时,先征得我的同意。",
    ].joined(separator: "\n")

    /// 「开启系统代理(复制指令给 AI 助手)」那一项呈现并复制的东西(2026-08-22 用户裁定)。
    ///
    /// 为什么开启走 agent 而**关闭留在菜单**:接管系统代理这件事在不同机器上差别很大
    /// (网络服务是 Wi-Fi 还是有线、要不要绕过某些域、端口取哪个……),需要现场判断 —— 那是 agent 的活。
    /// 而关闭是**救命按钮**:系统代理一旦指向死端口,机器就断网了,连 agent 自己都可能上不了网 ——
    /// 那一刻用户手上只剩菜单栏可点。所以那条**永远**是面板亲自发起,一次点击、不经任何人转手。
    ///
    /// 这段同样只有两行指路:命令原文归 `a2 guide`(壳里不留第二份)。
    public static let systemProxyPrompt = [
        "【请帮我开启系统代理】",
        "1. 先运行 ~/.a2/bin/a2 guide,了解本机的 A2 怎么用。",
        "2. 然后帮我把系统代理接管起来:先看现状,再按本机的网络环境操作,完成后验证能不能正常上网。",
        "要改我的网络设置前先问我。(要关掉的话我自己在菜单栏点「关闭系统代理(还原)」就行。)",
    ].joined(separator: "\n")

    static func notInstalledInitializationPrompt() -> String {
        [
            "【请帮我初始化 A2 · 尚未安装】",
            "",
            "用户已下载 A2 Panel,但尚未安装内核服务——A2 的 CLI 此刻还不存在。",
            "",
            "请这样帮助用户:",
            "1. 请用户点击菜单栏的 A² 图标 →「安装并启动内核」,一次点击即完成",
            "   (含开机自启;若首启欢迎弹窗还开着,点「安装并启动」即可)。",
            "2. 用户确认安装完成后,创建或更新名为 a2 的个人 skill,并安装到当前用户的全局 skill 目录;不要创建在当前项目或仓库里。",
            "   这个 skill 只做一件事:",
            "   每次使用时先运行 ~/.a2/bin/a2 guide,读取本机当前版本的说明并严格按输出继续。",
            "3. 不要把 guide 的正文、命令清单或流程复制进 skill;以后所有升级内容都以 a2 guide 为准。",
            "4. 创建完成后立刻使用一次 a2 skill,按 guide 的要求向用户展示下一步。",
            "",
            "注意:不要尝试直接调用 .app 包内的二进制替用户安装——安装 A2 是用户本人的一次显式点击。",
        ].joined(separator: "\n")
    }

    /// 已装版只负责生成/更新薄 skill。产品知识全部留在 `a2 guide`。
    static func installedInitializationPrompt() -> String {
        [
            "【请帮我初始化 A2】",
            "请按你所在环境的 skill 规范,创建或更新一个名为 a2 的个人 skill。",
            "必须把它安装到当前用户的用户级全局 skill 目录,让所有项目都能使用;不要创建在当前项目或仓库里。",
            "这个 skill 只做一件事:每次使用时先运行 ~/.a2/bin/a2 guide,读取本机当前版本的说明并严格按输出继续。",
            "不要把 guide 全文写死在 skill 里,也不要复制其中的命令清单、操作菜单或流程;以后所有功能与升级内容都只以 a2 guide 为准。",
            "完成后立刻使用 a2 skill。它应先调用 a2 guide,再按 guide 的要求给我列出编号菜单,等待我选择。",
            "(CLI 完整路径是 ~/.a2/bin/a2,刻意不在 PATH 上。)",
        ].joined(separator: "\n")
    }
}
