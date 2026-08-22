// A2PanelMacOS —— 关于页(10 票:ADR 0007 **修订版**的 GPL 义务呈现面)。
//
// ============================================================================
// 与 15 票那份关于页的差别 —— 义务面收缩了,呈现面跟着降级
// ============================================================================
// 15 票的关于页是 GPL 义务的**落点**:仓库当时随包分发一份 GPL-3.0 的 mihomo 二进制,
//   所以关于页要报版本、许可证、源码获取地址、随包 GPL 全文入口,而且数据要经 `proxy.license` 能力取
//   (GUI 与 CLI 同源)。
// ADR 0007 修订版把前提拆了:**新架构不再分发 GPL 二进制**(mihomo 由安装脚本获取、挂自己的 unit),
//   义务面收缩为「调用外部程序」;`内核重签校验废除`;义务的**必有落点**改成
//   `a2 about` 子命令 + 随包静态文本 —— 一个**不依赖任何 UI**的落点。
//
// 于是本窗口:
//   * **降级为可选呈现面**(spec 原文:「关于页降级为外部程序声明」),不再是义务落点;
//   * 内容是**静态文本**,不经任何能力调用 —— 它声明的是「a2 会调用外部的 mihomo」这件结构事实,
//     与某一份随包二进制的版本无关(那份二进制已经不存在了);
//   * `a2 about` 的实现归 13 票(分发工件)。**本窗口如实写明权威落点是那条命令**,
//     不假装自己就是义务履行本身。
//
// 为什么仍然留一个窗口:菜单里「关于」是用户找版权/许可信息的第一直觉落点,
//   而 spec 只说它「降级」,没说删掉。删掉等于让 mac 用户在 UI 里找不到任何声明。

import AppKit

@MainActor
public final class A2AboutWindow {

    /// 外部程序声明的**静态正文**。与 `a2 about` 的随包静态文本是同一件事的两个呈现面;
    /// 权威落点是那条命令(13 票),这里明写出来,免得有人以为关掉 UI 就少了一份声明。
    public static let declaration = """
    A2 Panel(a2 内核的可选菜单栏客户端)

    本面板不含业务逻辑:它是 a2 内核的一个对等客户端,只做两件事 ——
      ① 投影内核推来的状态(菜单显示);
      ② 替你出面呈现 dangerous 操作的确认(确认器)。
    从菜单退出 A2 时,会先还原系统代理,再停止 a2 与它托管的 mihomo。

    ── 外部程序声明(GPL-3.0)──────────────────────────────
    a2 通过**独立子进程 / 本地 HTTP 控制面**调用外部程序 mihomo(Mihomo Meta),
    该程序以 GPL-3.0 授权。a2 **不分发** mihomo 二进制,也不与它链接:
    它由安装脚本按你的显式命令获取,或复用你机器上已有的那一份。

    mihomo 项目与源码获取:https://github.com/MetaCubeX/mihomo
    GPL-3.0 全文:https://www.gnu.org/licenses/gpl-3.0.txt

    权威声明落点是**命令行**(不依赖任何 UI):

        a2 about

    本窗口只是同一份声明的可选呈现面。
    """

    private var window: NSWindow?

    public init() {}

    public func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 A2 Panel"
        window.isReleasedWhenClosed = false
        window.center()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        // **可选中**:源码地址与许可证链接是用户需要复制走的东西 —— GPL 的「获取指引」
        //   若不能复制,等于没给(15 票就是这么定的,这条不因义务面收缩而放松)。
        text.isSelectable = true
        text.font = NSFont.systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.string = Self.declaration
        scroll.documentView = text
        window.contentView = scroll

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
