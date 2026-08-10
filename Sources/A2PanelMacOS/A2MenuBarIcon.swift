// A2PanelMacOS —— 菜单栏那一格**长什么样**(19 票:文字「A2」换 template 图标)。
//
// ============================================================================
// 为什么拆成"取图"与"呈现决策"两件东西
// ============================================================================
// `A2MenuBarController` 一 init 就建真的 `NSStatusItem`(要窗口服务器、会往真菜单栏塞一格),
// 门禁里不该跑它。于是把两件能独立验的事拆出来:
//   * `A2MenuBarIcon.load(resourceURL:)` —— 从**给定目录**取那两张 template PNG,拼成一个
//     多 rep 的 `NSImage`。资源目录可注入,于是测试能拿入库产物真跑一遍(与 `A2EmbeddedKernel.locate`
//     同一种姿势);
//   * `A2MenuBarPresentation.resolve(...)` —— 纯函数:有没有图标 × 在不在接管,决定"画图标还是写字、
//     标题写什么"。四种组合各一条断言,不用起 AppKit 的任何窗口。
// 控制器自己只剩接线(取一次图 → 每次 render 调一次 resolve → 往 button 上抹)。
//
// ============================================================================
// 取不到资源是**常态**,不是异常
// ============================================================================
// `swift build` 出来的裸可执行、`swift test` 的测试宿主都没有 bundle 资源目录 ——
// 那时回落到 10 票以来的文字行为(「A2」/「A2 ●」),而不是显示一个空白格子。
// 与 `A2EmbeddedKernel.locate` 的口径逐字相同:**能力缺席即回落,不假装**。
//
// ============================================================================
// isTemplate 是这张图的**全部意义**
// ============================================================================
// template 图 AppKit 只看 alpha:菜单栏深浅外观、选中态反色,全由系统按 alpha 重新上色。
// 所以产物必须是**纯黑 + alpha、透明底**(`Scripts/gen-app-icon.swift` 画的就是这个),
// 而这里必须把 `isTemplate` 打开 —— 忘了打开就会在深色菜单栏上出现一块黑糊糊的方。
// @1x/@2x 两档合成一个 `NSImage`:每个 rep 的 `size` 都设成 18×18 **点**,于是 36px 那张
// 自动成为 2 倍图(不设的话它会被当成一张 36 点的大图,菜单栏里直接超框)。

import AppKit
import Foundation

/// 菜单栏 template 图标(18×18pt,@1x + @2x)。
public enum A2MenuBarIcon {

    /// 资源基名。**与 `Scripts/build-app.sh` 拷进 `Contents/Resources/` 的那两个文件同名** ——
    /// 与 `A2EmbeddedKernel.resourceName` 一样,改名字就是改两处,所以两边各自只有这一处。
    public static let resourceName = "a2-menubar-template"

    /// 点尺寸。18×18pt 是菜单栏 extra 的常规体量(@1x 18px / @2x 36px)。
    public static let pointSize: CGFloat = 18

    /// 从 `resourceURL` 取图。**任何一档缺失/解不动都返回 nil**(fail-closed:宁可回落文字,
    /// 也不显示一张只有一半分辨率、或者干脆空白的图)。
    public static func load(resourceURL: URL? = Bundle.main.resourceURL) -> NSImage? {
        guard let resourceURL else { return nil }
        let files = ["\(resourceName).png", "\(resourceName)@2x.png"]
        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        for file in files {
            guard let data = try? Data(contentsOf: resourceURL.appendingPathComponent(file)),
                  let rep = NSBitmapImageRep(data: data) else { return nil }
            // 点尺寸钉死 → 18px 那张 scale 1、36px 那张 scale 2。
            rep.size = NSSize(width: pointSize, height: pointSize)
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = "A2"
        return image
    }
}

/// 菜单栏那一格的呈现:画不画图标、标题写什么。**纯数据,零 AppKit 副作用**。
public struct A2MenuBarPresentation: Equatable {

    /// 代理接管中的指示符。19 票之前它是标题里那个「 ●」;现在图标与它**并存**
    /// (图标是身份,「●」是状态)—— 语义一个字没变。
    public static let indicator = "●"
    /// 没有图标时的回落文字(10 票以来的原样)。
    public static let fallbackTitle = "A2"

    /// 是否用 template 图标(false = 回落文字)。
    public let usesIcon: Bool
    /// 按钮标题(回落时是「A2」/「A2 ●」;有图标时是「」/「●」)。
    public let title: String

    public init(usesIcon: Bool, title: String) {
        self.usesIcon = usesIcon
        self.title = title
    }

    /// 两个输入,四种组合,没有第五种。
    public static func resolve(hasIcon: Bool, proxyTakenOver: Bool) -> A2MenuBarPresentation {
        if hasIcon {
            return A2MenuBarPresentation(usesIcon: true, title: proxyTakenOver ? indicator : "")
        }
        return A2MenuBarPresentation(
            usesIcon: false,
            title: proxyTakenOver ? "\(fallbackTitle) \(indicator)" : fallbackTitle)
    }

    /// `NSStatusBarButton` 的 `imagePosition`:图标与标题并存时图标在左。
    public var imagePosition: NSControl.ImagePosition {
        guard usesIcon else { return .noImage }
        return title.isEmpty ? .imageOnly : .imageLeading
    }
}
