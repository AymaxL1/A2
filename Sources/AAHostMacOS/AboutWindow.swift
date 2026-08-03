// AAHostMacOS —— 关于页(15 票:ADR 0007 的 GPL 义务呈现面)。
//
// ============================================================================
// 为什么是独立类型,而不是塞进 applicationDidFinishLaunching 的内联闭包
// ============================================================================
// **14 票会重建整个菜单栏菜单。** 关于页若是 setupStatusItem 里的一段内联代码,那次重建就得把它连人带货
//   重写一遍(而重写 GPL 呈现面 = 重新承担一次法律义务的正确性风险)。做成独立类型后,14 票只需要
//   `AboutWindowController(registry:).makeMenuItem()` 拿走那一项,本文件一个字不动。
//
// ============================================================================
// 数据一律经**能力面**取,绝不直读 MihomoKernelResource
// ============================================================================
// 本仓库铁律:GUI 与 CLI 同源、薄壳无私有逻辑。所以关于页展示的内核版本/许可证/源码地址/子进程红线
//   全部来自 `registry.invoke("proxy.license")` —— 与 `aa proxy license --json` 走的是同一条路径、
//   同一份数据。好处不是洁癖:
//     ① 门禁能在 headless 下验到它(经 UDS 调 `aa proxy license`),不必去点 GUI;
//     ② GUI 与 CLI 不可能各自显示出不同的版本号(它们物理上就是同一个字符串)。
//   代价:关于页多一次注册表往返(safe 档纯静态读取,零成本),且必须容忍能力缺失/失败 —— 见 render 的兜底分支。
//
// 应用版本从 `Bundle.main` 的 `CFBundleShortVersionString` 读,**不硬编码**:那个值由
//   `Scripts/build-app.sh` 的 $APP_VERSION 写进 Info.plist,是单一来源。非 `.app` 形态
//   (`swift build` 出来的裸可执行)根本没有 Info.plist,此时如实显示「未知(非 .app 形态)」——
//   不许拿源码里的字面量冒充,那会让人以为裸可执行也是个有版本的发布物。

import AppKit
import AAContracts
import AAHostRuntime

/// 关于窗口的构造与展示。独立、可单独调用:`AboutWindowController(registry:)` → `makeMenuItem()` 或 `show()`。
///
/// 生命周期:调用方(AppDelegate)须持有本对象 —— 菜单项的 target 是弱引用,不持有会让菜单项点了没反应。
/// 窗口本身 `isReleasedWhenClosed = false` 并被本对象持有,关掉再打开是同一个窗口(不重复建)。
@MainActor
final class AboutWindowController: NSObject {
    private let registry: Registry
    private let bundle: Bundle
    private var window: NSWindow?

    /// - Parameters:
    ///   - registry: 能力注册表。关于页的全部内核信息经它调 `proxy.license` 取得(不绕过注册表直读常量)。
    ///   - bundle: 读应用名/版本的 bundle,缺省 `.main`。参数化只为可测:注入一个假 bundle 就能验「非 .app 形态」分支。
    init(registry: Registry, bundle: Bundle = .main) {
        self.registry = registry
        self.bundle = bundle
        super.init()
    }

    /// 造一个「关于 AA」菜单项(target=self)。14 票重建菜单时直接取用这一项,不必知道关于页怎么实现。
    func makeMenuItem(title: String = "关于 AA") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(showAbout(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func showAbout(_ sender: Any?) { show() }

    /// 展示关于窗口(不存在则先建)。accessory app(LSUIElement)没有 Dock 图标,
    /// 不先 activate 的话窗口会出现在别的 app 后面 —— 与 dangerous 确认框同一条既有经验。
    func show() {
        let w = window ?? makeWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.center()
    }

    // ============ 数据(经能力面)============

    /// 关于页要展示的内核信息。字段与 `proxy.license` 的输出一一对应。
    struct LicenseInfo {
        let kernelVersion: String
        let license: String
        let licenseTextPath: String
        let licenseTextAvailable: Bool
        let sourceURL: String
        let subprocessBoundary: String
    }

    /// 经注册表调 `proxy.license` 取内核信息。能力缺失 / 返回失败 / 形状不对 → nil(由 render 走兜底分支如实说明)。
    ///
    /// `proxy.license` 是 safe 档,`Registry.invoke` 对 safe 是同步直执行,故这里能直接拿到 `.success`;
    ///   `.pending` 只可能出现在 dangerous 档,真出现了说明能力的风险档被人改过 —— 那种情况按「取不到」处理,
    ///   宁可关于页显示「读取失败」,也不要在主线程上等一个永远不来的确认。
    private func fetchLicenseInfo() -> LicenseInfo? {
        guard case .success(let json) = registry.invoke(capabilityID: "proxy.license", input: nil),
              let obj = json.objectValue,
              let kernelVersion = obj["kernelVersion"]?.stringValue,
              let license = obj["license"]?.stringValue,
              let licenseTextPath = obj["licenseTextPath"]?.stringValue,
              let sourceURL = obj["sourceURL"]?.stringValue,
              let subprocessBoundary = obj["subprocessBoundary"]?.stringValue
        else { return nil }
        // licenseTextAvailable 缺失时按 false 处理(保守:宁可禁掉「打开全文」按钮,也不要点了没反应)。
        let available = obj["licenseTextAvailable"].flatMap { value -> Bool? in
            if case .bool(let b) = value { return b }
            return nil
        } ?? false
        return LicenseInfo(kernelVersion: kernelVersion, license: license,
                           licenseTextPath: licenseTextPath, licenseTextAvailable: available,
                           sourceURL: sourceURL, subprocessBoundary: subprocessBoundary)
    }

    /// 应用名:`CFBundleName` → 缺失回落到进程名(非 `.app` 形态时就是可执行文件名)。
    private var appName: String {
        (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    /// 应用版本:`CFBundleShortVersionString`。**不硬编码**;非 `.app` 形态读不到 → 如实说明。
    private var appVersionText: String {
        if let v = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, !v.isEmpty {
            return v
        }
        return "未知(非 .app 形态)"
    }

    // ============ 视图 ============

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "关于 \(appName)"
        // accessory app 里窗口被关掉后对象仍归本控制器持有(下次 show 复用同一个);
        //   不设 false 的话 AppKit 会在关闭时释放它,再 show 就是野指针。
        w.isReleasedWhenClosed = false
        w.contentView = makeContentView()
        return w
    }

    private func makeContentView() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(label(appName, size: 20, bold: true))
        stack.addArrangedSubview(label("版本 \(appVersionText)", size: 12, secondary: true))
        stack.addArrangedSubview(separator())

        if let info = fetchLicenseInfo() {
            stack.addArrangedSubview(label("内核:mihomo \(info.kernelVersion)", size: 13))
            stack.addArrangedSubview(label("许可证:\(info.license)", size: 13))
            stack.addArrangedSubview(label("源码获取:\(info.sourceURL)", size: 12, secondary: true, wraps: true))
            stack.addArrangedSubview(separator())
            // 子进程红线原文(ADR 0007 提炼句)。与 `proxy.license` 的 subprocessBoundary 是同一个字符串。
            stack.addArrangedSubview(label("集成红线", size: 12, bold: true))
            stack.addArrangedSubview(label(info.subprocessBoundary, size: 12, secondary: true, wraps: true))
            stack.addArrangedSubview(separator())

            // GPL-3.0 全文入口:点了用 NSWorkspace 打开随包那份 txt(系统默认文本编辑器)。
            //   文件不在盘上时按钮 disabled 并如实说明 —— 不做「点了没反应」这种假入口。
            let button = NSButton(title: "查看 mihomo 的 GPL-3.0 全文", target: self,
                                  action: #selector(openLicenseText(_:)))
            button.bezelStyle = .rounded
            button.isEnabled = info.licenseTextAvailable
            licenseTextPath = info.licenseTextPath
            stack.addArrangedSubview(button)
            if info.licenseTextAvailable {
                stack.addArrangedSubview(label(info.licenseTextPath, size: 10, secondary: true, wraps: true))
            } else {
                stack.addArrangedSubview(label("⚠️ 随包的 GPL-3.0 全文未找到(期望落点:\(info.licenseTextPath))",
                                               size: 10, secondary: true, wraps: true))
            }
        } else {
            // 兜底:能力面取不到就如实说,绝不退回「GUI 自己去读常量」——那正是本票要消灭的私有逻辑。
            stack.addArrangedSubview(label("内核许可证信息读取失败(能力 proxy.license 不可用)。",
                                           size: 13, wraps: true))
            stack.addArrangedSubview(label("可在终端执行 `aa proxy license --json` 复现同一失败。",
                                           size: 11, secondary: true, wraps: true))
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 380))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        return container
    }

    /// 「打开全文」按钮当前指向的路径(建视图时从能力输出写入)。空 = 没建过视图或能力不可用 → 点击 no-op。
    private var licenseTextPath: String = ""

    @objc private func openLicenseText(_ sender: Any?) {
        guard !licenseTextPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: licenseTextPath))
    }

    private func label(_ text: String, size: CGFloat, bold: Bool = false,
                       secondary: Bool = false, wraps: Bool = false) -> NSTextField {
        // `labelWithString` 建的是只读标签,默认**不可选中**;这里显式打开 isSelectable:
        //   源码地址与许可证路径是用户**需要复制走**的东西(GPL 义务的「获取指引」若不能复制就等于没给)。
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        if wraps {
            field.lineBreakMode = .byWordWrapping
            field.usesSingleLineMode = false
            field.preferredMaxLayoutWidth = 460
        }
        return field
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        return v
    }
}
