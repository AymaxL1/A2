// A2PanelMacOS —— **渲染器 B**(`A2MenuModel → PNG`,10 票自 14 票原封平移)。
//
// ============================================================================
// 它证明什么、不证明什么(这一段必须先读)
// ============================================================================
// 证明:模型本身(标题 / 顺序 / 勾选 / 置灰 / 每项绑的能力 id 与参数),以及
//       「同一个 `A2MenuModel` 同时喂给渲染器 A(真 NSMenu)与渲染器 B(本文件)」这条共享路径 ——
//       模型一旦回归,两个渲染器一起错,快照当场变红。
// **不证明**:AppKit 把真 NSMenu 画成什么样。行高、字体、分隔线粗细、子菜单箭头、深浅色配色、
//       高亮态……那些全部由系统绘制,本文件只是**另一种**呈现方式,与真菜单像素上毫无关系。
//       尤其:真菜单的子菜单是**弹出**的,这里画成**缩进展开**——一眼可见的形态差异。
//       「菜单在屏幕上真的长这样」只能由人眼确认,门禁给不了这条结论。
//
// ============================================================================
// 像素尺寸必须显式定死(14 票的实测教训,原样保留)
// ============================================================================
// `bitmapImageRepForCachingDisplay(in:)` 给的是 **backing store 像素**:在 Retina 上请求 240×80,
//   实际拿到 480×160;换一台显示器(或换缩放档)就又是另一个数 —— 像素断言当场红。
// 正确做法(连渲两次字节完全一致):
//   显式 `NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide:…, pixelsHigh:…)`
//   → `rep.size = NSSize(width: w, height: h)`(**1 point = 1 pixel**,把 backing scale 钉死为 1)
//   → `NSGraphicsContext(bitmapImageRep:)` → `view.displayIgnoringOpacity(_:in:)`
//   → `rep.representation(using: .png…)`。
//
// 配色一律写死 RGB、不用 `.labelColor` 之类语义色:语义色跟随系统深浅外观,门禁跑在什么外观下不由我们决定。
// 色彩空间用**设备无关**的 `.calibratedRGB`,不能用 `.deviceRGB`(golden 是入库的,天然要跨机器比对)。
//
// 依赖边:A2PanelMacOS → A2Panel + AppKit。

import AppKit
import A2Panel

/// **渲染器 B**:把菜单模型画成一张定尺寸 PNG。
public enum A2MenuSnapshotRenderer {

    /// 版面常量(全部整数像素,避免半像素落在不同行上导致的抗锯齿抖动)。
    public enum Layout {
        public static let width = 460
        public static let rowHeight = 22
        public static let separatorHeight = 9
        public static let verticalPadding = 10
        public static let leftPadding = 12
        public static let rightPadding = 12
        public static let indentStep = 18
        /// 勾选标记占位宽(无论勾没勾都占,保证标题左边缘对齐 → 勾选态变化只影响一个字形,diff 好读)。
        public static let checkColumn = 16
    }

    private enum Palette {
        static let background = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        static let headerText = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
        static let normalText = NSColor(srgbRed: 0.13, green: 0.13, blue: 0.15, alpha: 1.0)
        static let disabledText = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.65, alpha: 1.0)
        static let capabilityText = NSColor(srgbRed: 0.42, green: 0.47, blue: 0.58, alpha: 1.0)
        static let separatorLine = NSColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1.0)
    }

    /// 本模型渲染出来的 PNG 的**确定像素尺寸**。断言据此独立核验产物(读 PNG 的 IHDR 比对)。
    public static func pixelSize(for model: A2MenuModel) -> (width: Int, height: Int) {
        var h = Layout.verticalPadding * 2
        for (item, _) in model.rows {
            h += (item.kind == .separator) ? Layout.separatorHeight : Layout.rowHeight
        }
        return (Layout.width, h)
    }

    public enum RenderError: Error, CustomStringConvertible {
        case bitmapAllocationFailed(width: Int, height: Int)
        case graphicsContextFailed
        case pngEncodingFailed
        public var description: String {
            switch self {
            case .bitmapAllocationFailed(let w, let h): return "NSBitmapImageRep 分配失败(\(w)×\(h))"
            case .graphicsContextFailed:                return "NSGraphicsContext(bitmapImageRep:) 建立失败"
            case .pngEncodingFailed:                    return "PNG 编码失败(representation(using:.png) 返回 nil)"
            }
        }
    }

    /// AppKit 的字体/绘制栈需要一个 `NSApplication` 实例才完整初始化。
    ///
    /// `.prohibited` 保证它不进 Dock、不抢焦点 —— 快照渲染既可能发生在 `swift test` 进程里,
    /// 也可能发生在 `a2-panel-snapshot` 这个一次性工具里,两处都**绝不能**变成一个「窗口」。
    /// 幂等:多次调用只有第一次真的做事(`swift test` 里两条用例各调一次是常态)。
    @MainActor
    public static func prepareGraphicsStack() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    /// 渲染成 PNG 字节。同一模型在同一台机器上应当**逐字节可重现**(不可重现即为缺陷,不许靠调大阈值掩盖)。
    @MainActor
    public static func renderPNG(_ model: A2MenuModel) throws -> Data {
        let size = pixelSize(for: model)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: size.width, pixelsHigh: size.height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            throw RenderError.bitmapAllocationFailed(width: size.width, height: size.height)
        }
        // 关键一步:把 rep 的 **point 尺寸**设成与像素尺寸相同 → backing scale 恒为 1。
        rep.size = NSSize(width: size.width, height: size.height)

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { throw RenderError.graphicsContextFailed }
        let view = MenuSnapshotView(model: model,
                                    frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
        view.displayIgnoringOpacity(view.bounds, in: ctx)
        ctx.flushGraphics()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncodingFailed
        }
        return data
    }

    // ============ 像素比对(测试与重录工具共用一份判据)============

    /// 像素差判据(**阈值给理由,不拍脑袋**):
    ///
    /// 单通道容差 2/255 —— 只用来吸收「同一台机器、同一份字体下的量化舍入」这一类**看不见**的抖动。
    ///   为什么不是 0:0 会把任何一次 CoreGraphics 内部舍入变化都判成回归;
    ///   为什么不能更大:菜单渲染是**纯文字 + 直线**,任何真实回归(文案变了、勾选没了、少了一项、置灰了)
    ///   都表现为整块像素在背景色(255)与前景色(≈33)之间跳,单通道差值上百 —— 与 2 差两个数量级。
    public static let channelTolerance = 2
    /// 超容差像素的**允许数量 = 0**:同机确定性渲染下,正确答案就是一个都不该有。
    public static let allowedOverTolerancePixels = 0

    public struct PixelDiff: Sendable, Equatable {
        public let total: Int
        public let diff: Int
        public let over: Int
    }

    /// 逐像素比较两张 PNG。解码失败或尺寸不同 → nil(那本身就是一种失败,调用方要报出来)。
    public static func comparePNG(_ a: Data, _ b: Data) -> PixelDiff? {
        guard let ra = NSBitmapImageRep(data: a), let rb = NSBitmapImageRep(data: b),
              ra.pixelsWide == rb.pixelsWide, ra.pixelsHigh == rb.pixelsHigh,
              ra.samplesPerPixel == rb.samplesPerPixel,
              let pa = ra.bitmapData, let pb = rb.bitmapData else { return nil }
        let w = ra.pixelsWide, h = ra.pixelsHigh, spp = ra.samplesPerPixel
        let rowA = ra.bytesPerRow, rowB = rb.bytesPerRow
        var diff = 0, over = 0
        for y in 0..<h {
            for x in 0..<w {
                let ia = y * rowA + x * spp
                let ib = y * rowB + x * spp
                var maxDelta = 0
                for c in 0..<spp {
                    let d = abs(Int(pa[ia + c]) - Int(pb[ib + c]))
                    if d > maxDelta { maxDelta = d }
                }
                if maxDelta > 0 { diff += 1 }
                if maxDelta > channelTolerance { over += 1 }
            }
        }
        return PixelDiff(total: w * h, diff: diff, over: over)
    }

    /// 文本 golden 对不上时把差异行列出来 —— 这正是留一份文本快照的理由:图片 diff 说不出「哪一行变了」。
    public static func textDiffReport(golden: String, current: String) -> String {
        let g = golden.components(separatedBy: "\n")
        let n = current.components(separatedBy: "\n")
        var lines: [String] = ["文本 golden 差异(golden ←→ 当前):"]
        for i in 0..<max(g.count, n.count) {
            let gl = i < g.count ? g[i] : "(无此行)"
            let nl = i < n.count ? n[i] : "(无此行)"
            if gl != nl { lines.append("  第\(i + 1)行:\n    golden: \(gl)\n    当前  : \(nl)") }
        }
        return lines.joined(separator: "\n")
    }

    // ============ 自绘视图 ============

    /// 自绘的菜单外观。**不是** NSMenu,也不试图模仿 NSMenu 的像素 —— 它只是把模型摆出来给人看。
    private final class MenuSnapshotView: NSView {
        private let rows: [(item: A2MenuItemModel, depth: Int)]

        init(model: A2MenuModel, frame: NSRect) {
            self.rows = model.rows
            super.init(frame: frame)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("不支持 NIB 载入") }

        /// 翻转坐标系:从上往下画,与菜单的阅读顺序一致。
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            Palette.background.setFill()
            bounds.fill()

            let titleFont = NSFont.systemFont(ofSize: 13)
            let headerFont = NSFont.boldSystemFont(ofSize: 13)
            let capFont = NSFont.systemFont(ofSize: 9)

            var y = CGFloat(Layout.verticalPadding)
            for (item, depth) in rows {
                let indent = CGFloat(Layout.leftPadding + depth * Layout.indentStep)

                if item.kind == .separator {
                    Palette.separatorLine.setFill()
                    NSRect(x: indent, y: y + CGFloat(Layout.separatorHeight) / 2 - 0.5,
                           width: bounds.width - indent - CGFloat(Layout.rightPadding), height: 1).fill()
                    y += CGFloat(Layout.separatorHeight)
                    continue
                }

                // 标题行恒用 headerText:它在模型里 enabled=false(点不了),但那是「不可点」而非「不可用」。
                let textColor: NSColor = (item.kind == .header)
                    ? Palette.headerText
                    : (item.enabled ? Palette.normalText : Palette.disabledText)
                let font = (item.kind == .header) ? headerFont : titleFont

                if item.checked {
                    draw("✓", at: NSRect(x: indent, y: y + 3,
                                         width: CGFloat(Layout.checkColumn), height: 16),
                         font: titleFont, color: textColor, alignment: .left)
                }

                let titleX = indent + CGFloat(Layout.checkColumn)
                // 右侧能力 id 角标:让**不读 Swift 的人**也能一眼核对「这一项到底调哪个能力」。
                let capBadge = item.capabilityID.map { id -> String in
                    item.kind == .action ? id : "\(id)(只读)"
                }
                let capWidth: CGFloat = capBadge == nil ? 0 : 190
                let titleWidth = bounds.width - titleX - CGFloat(Layout.rightPadding) - capWidth
                draw(item.title, at: NSRect(x: titleX, y: y + 3, width: max(titleWidth, 40), height: 16),
                     font: font, color: textColor, alignment: .left)

                if let badge = capBadge {
                    draw(badge,
                         at: NSRect(x: bounds.width - CGFloat(Layout.rightPadding) - capWidth, y: y + 6,
                                    width: capWidth, height: 12),
                         font: capFont, color: Palette.capabilityText, alignment: .right)
                }
                y += CGFloat(Layout.rowHeight)
            }
        }

        private func draw(_ text: String, at rect: NSRect, font: NSFont, color: NSColor,
                          alignment: NSTextAlignment) {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ]).draw(in: rect)
        }
    }
}
