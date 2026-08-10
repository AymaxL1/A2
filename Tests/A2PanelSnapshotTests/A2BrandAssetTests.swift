// 19 票:**入库的图标素材 × 设计规格**(门禁里那层便宜的守卫)。
//
// ============================================================================
// 它证明什么、不证明什么
// ============================================================================
// 证明:`assets/branding/` 里那批产物**确实是规格里那张图** —— Big Sur 网格(1024 画布 / 824 圆角方 /
//       边距 100)、圆角半径 184 的圆弧、陶土橙 #C36446 与米白 #FDF9F1、A 与上标 2 的比例与齐平关系、
//       十档 iconset 与 .icns 的十个 chunk、菜单栏 template 是纯黑 + alpha。
// **不证明**:好不好看。那只能人眼看(README 留了一条人工项)。
//
// 它挡的是这类事:改了 `Scripts/gen-app-icon.swift` 的设计常量却没重跑脚本;重跑了脚本却漏掉某一档;
// 有人拿别的图覆盖了产物;template 被当成普通彩色图重出(那一刻深色菜单栏就废了)。
// **逐字节那一层判据不在这里**(它要重跑生成脚本,得有 swift 工具链且要几秒):
//   `swift Scripts/gen-app-icon.swift --verify`,口径写在那个脚本的文件头。
//
// 产物路径由 `#filePath` 推仓库根 —— 与快照 golden、契约金标同一条口径。

import CoreGraphics
import Foundation
import ImageIO
import Testing

@Suite("19 品牌产物(入库图标素材 × 设计规格:网格 / 圆角 / 色值 / 字形比例 / 十档 / template)")
struct A2BrandAssetTests {

    static let brandDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // A2PanelSnapshotTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("assets/branding")
    }()

    // ========================================================================
    // 母版:网格与圆角
    // ========================================================================

    @Test("19 母版是 1024 画布 + 824 居中圆角方(Big Sur 网格),四周 100px 是留给系统投影的余量",
          arguments: ["a2-icon-master-terracotta-1024.png", "a2-icon-master-black-1024.png"])
    func masterUsesBigSurGrid(_ name: String) throws {
        let bitmap = try Bitmap(Self.brandDirectory.appendingPathComponent(name))
        #expect(bitmap.width == 1024 && bitmap.height == 1024)
        let box = try #require(bitmap.opaqueBounds)
        #expect(box == PixelBox(minX: 100, minY: 100, maxX: 923, maxY: 923),
                "圆角方应当是 824×824 居中(边距各 100);实测 \(box)")
        // **素材自带投影就麻烦了**:四角与边距区必须是全透明的。
        for point in [(0, 0), (1023, 0), (0, 1023), (1023, 1023), (50, 512), (512, 50)] {
            #expect(bitmap[point.0, point.1].a == 0,
                    "(\(point.0),\(point.1)) 不透明 —— 素材里不该有投影/背景板")
        }
    }

    @Test("19 圆角**画在素材里**(macOS 不代裁),且轮廓吻合 R=184 的圆弧",
          arguments: ["a2-icon-master-terracotta-1024.png", "a2-icon-master-black-1024.png"])
    func cornerRadiusIsBakedIn(_ name: String) throws {
        let bitmap = try Bitmap(Self.brandDirectory.appendingPathComponent(name))
        let box = try #require(bitmap.opaqueBounds)
        let radius = 184.0
        // 角上那一块是透明的 —— 这一条就是「素材自带圆角」的判据(直角素材在这里必红)。
        #expect(bitmap[box.minX + 4, box.minY + 4].a == 0)
        // 圆弧对账:离顶 dy 处的左内缩应当是 R - sqrt(R² - (R-dy)²)。
        for dy in [16, 32, 64, 100, 150] {
            let inset = try #require(bitmap.firstOpaqueColumn(row: box.minY + dy)) - box.minX
            let expected = radius - (radius * radius - (radius - Double(dy)) * (radius - Double(dy))).squareRoot()
            #expect(abs(Double(inset) - expected) <= 2,
                    "离顶 \(dy) 行:实测内缩 \(inset),R=184 的圆弧应为 \(Int(expected.rounded()))")
        }
        // 半径处及以下已经是直边。
        #expect(bitmap.firstOpaqueColumn(row: box.minY + Int(radius) + 20) == box.minX)
    }

    // ========================================================================
    // 色值:两种色,没有第三种(除抗锯齿过渡)
    // ========================================================================

    @Test("19 陶土橙母版:面积最大的两种不透明色 = 底 #C36446 + 字 #FDF9F1(色值取自 v3 小样)")
    func terracottaPalette() throws {
        let bitmap = try Bitmap(Self.brandDirectory
            .appendingPathComponent("a2-icon-master-terracotta-1024.png"))
        let top = bitmap.dominantOpaqueColors(2)
        #expect(top.first?.color == RGB(195, 100, 70), "底色应为陶土橙 #C36446;实测 \(top)")
        #expect(top.last?.color == RGB(253, 249, 241), "字形应为米白 #FDF9F1;实测 \(top)")
    }

    @Test("19 黑底备选:底 #242424 + 字 #FDF9F1(存着不接线,与主选同一套几何)")
    func blackPalette() throws {
        let bitmap = try Bitmap(Self.brandDirectory
            .appendingPathComponent("a2-icon-master-black-1024.png"))
        let top = bitmap.dominantOpaqueColors(2)
        #expect(top.first?.color == RGB(36, 36, 36), "底色应为近黑 #242424;实测 \(top)")
        #expect(top.last?.color == RGB(253, 249, 241), "字形应为米白 #FDF9F1;实测 \(top)")
    }

    // ========================================================================
    // 字形:A 与上标 2 的比例关系(全部量自 v3 小样,写在生成脚本的 `Design` 里)
    // ========================================================================

    @Test("19 A² 的比例照 v3 小样:A 高占方 0.470、2 高占 A 高 0.315、2 顶与 A 顶齐平、记号居中",
          arguments: ["a2-icon-master-terracotta-1024.png", "a2-icon-master-black-1024.png"])
    func markProportions(_ name: String) throws {
        let bitmap = try Bitmap(Self.brandDirectory.appendingPathComponent(name))
        let square = try #require(bitmap.opaqueBounds)
        let side = Double(square.width)
        let parts = bitmap.components(matching: { $0 == RGB(253, 249, 241) }, minimumArea: 200)
        #expect(parts.count == 2, "米白的连通域应当恰好两块:A 与上标 2(实测 \(parts.count) 块)")
        let a = try #require(parts.first)                       // 面积最大者 = A
        let two = try #require(parts.dropFirst().first)

        #expect(abs(Double(a.height) / side - 0.470) <= 0.008,
                "A 的 cap 高 / 方边 应为 0.470(小样实测 0.472 与 0.465);实测 \(Double(a.height) / side)")
        #expect(abs(Double(two.height) / Double(a.height) - 0.315) <= 0.012,
                "上标 2 高 / A 高 应为 0.315;实测 \(Double(two.height) / Double(a.height))")
        #expect(abs(two.minY - a.minY) <= 2, "2 的顶与 A 的顶齐平(小样实测差 1px/109px)")
        #expect(two.minX > a.minX && two.maxX > a.maxX, "2 在 A 的右上角,且右边缘越过 A")
        // 记号(两块的并集)在圆角方里上下左右居中。
        let markMinX = min(a.minX, two.minX), markMaxX = max(a.maxX, two.maxX)
        let markMinY = min(a.minY, two.minY), markMaxY = max(a.maxY, two.maxY)
        #expect(abs(Double(markMinX + markMaxX) / 2 - Double(square.minX + square.maxX) / 2) <= 2)
        #expect(abs(Double(markMinY + markMaxY) / 2 - Double(square.minY + square.maxY) / 2) <= 2)
    }

    // ========================================================================
    // iconset 与 .icns
    // ========================================================================

    @Test("19 iconset 十档齐、每档像素尺寸对、且每档都按同一网格**原生重画**(不是缩图)")
    func iconsetHasAllTenSizes() throws {
        let expected: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        let dir = Self.brandDirectory.appendingPathComponent("AppIcon.iconset")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".png") }.sorted()
        #expect(files == expected.map(\.0).sorted(), "iconset 里的文件清单与十档对不上")

        for (name, pixels) in expected {
            let bitmap = try Bitmap(dir.appendingPathComponent(name))
            #expect(bitmap.width == pixels && bitmap.height == pixels, "\(name) 像素尺寸不对")
            let box = try #require(bitmap.opaqueBounds, "\(name) 整张透明")
            // 每一档的圆角方都占 824/1024,允许 1px 的取整/抗锯齿误差。
            let ratio = Double(box.width) / Double(pixels)
            #expect(abs(ratio - 824.0 / 1024.0) <= 1.5 / Double(pixels),
                    "\(name) 的圆角方占比 \(ratio) 偏离 Big Sur 网格 0.8047")
        }
    }

    @Test("19 iconset 的 1024 档与陶土橙母版**逐字节相同**(同源:同一次渲染的同一张图)")
    func largestIconsetEntryIsTheMaster() throws {
        let master = try Data(contentsOf: Self.brandDirectory
            .appendingPathComponent("a2-icon-master-terracotta-1024.png"))
        let entry = try Data(contentsOf: Self.brandDirectory
            .appendingPathComponent("AppIcon.iconset/icon_512x512@2x.png"))
        #expect(master == entry)
    }

    @Test("19 AppIcon.icns 结构完好:magic + 自述长度 = 实际长度 + 恰好十个尺寸 chunk")
    func icnsCarriesAllTenSizes() throws {
        let data = try Data(contentsOf: Self.brandDirectory.appendingPathComponent("AppIcon.icns"))
        #expect(String(bytes: data[0..<4], encoding: .ascii) == "icns")
        func be32(_ offset: Int) -> Int {
            (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
        }
        #expect(be32(4) == data.count, "icns 自述长度与文件实际长度不符 —— 文件被截断或被改过")

        var types: Set<String> = []
        var offset = 8
        while offset + 8 <= data.count {
            let type = String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? "?"
            let length = be32(offset + 4)
            guard length > 8 else { break }
            types.insert(type)
            offset += length
        }
        #expect(offset == data.count, "chunk 链没有正好走到文件末尾(偏移 \(offset) / \(data.count))")
        // iconutil 把 16/32 那两档存成 ARGB(ic04/ic05),其余八档存 PNG。十档 = 十个 chunk。
        let sizeChunks: Set<String> = ["ic04", "ic05", "ic07", "ic08", "ic09",
                                       "ic10", "ic11", "ic12", "ic13", "ic14"]
        #expect(types.intersection(sizeChunks) == sizeChunks,
                "缺档:\(sizeChunks.subtracting(types).sorted())")
    }

    // ========================================================================
    // 菜单栏 template
    // ========================================================================

    @Test("19 菜单栏 template:18/36 px、**纯黑 + alpha**(彩色一进去,深色菜单栏就废了)",
          arguments: [("a2-menubar-template.png", 18), ("a2-menubar-template@2x.png", 36)])
    func templateIsBlackPlusAlpha(_ entry: (String, Int)) throws {
        let bitmap = try Bitmap(Self.brandDirectory.appendingPathComponent(entry.0))
        #expect(bitmap.width == entry.1 && bitmap.height == entry.1)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let px = bitmap[x, y]
                #expect(px.r == 0 && px.g == 0 && px.b == 0,
                        "(\(x),\(y)) 有颜色 —— template 只许用 alpha 说话")
            }
        }
        #expect(bitmap.opaqueBounds != nil, "整张透明 = 菜单栏上什么都看不见")
    }

    @Test("19 菜单栏 template 的记号占满可视区(高 ≈ 边长的 0.72)且左右居中",
          arguments: [("a2-menubar-template.png", 18), ("a2-menubar-template@2x.png", 36)])
    func templateMarkFillsTheBox(_ entry: (String, Int)) throws {
        let bitmap = try Bitmap(Self.brandDirectory.appendingPathComponent(entry.0))
        let box = try #require(bitmap.opaqueBounds)
        let side = Double(entry.1)
        #expect(abs(Double(box.height) / side - 0.72) <= 0.07,
                "记号高 / 画布边长 应≈0.72;实测 \(Double(box.height) / side)")
        #expect(abs(Double(box.minX + box.maxX) / 2 - (side - 1) / 2) <= 1.0, "左右不居中")
        #expect(abs(Double(box.minY + box.maxY) / 2 - (side - 1) / 2) <= 1.5, "上下不居中")
    }
}

// ============================================================================
// 读图小工具(只用 CoreGraphics/ImageIO:与生成脚本同一套解码路径)
// ============================================================================

struct RGB: Equatable, Hashable, CustomStringConvertible {
    let r: Int, g: Int, b: Int
    init(_ r: Int, _ g: Int, _ b: Int) { self.r = r; self.g = g; self.b = b }
    var description: String { String(format: "#%02X%02X%02X", r, g, b) }
}

struct PixelBox: Equatable, CustomStringConvertible {
    let minX: Int, minY: Int, maxX: Int, maxY: Int
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }
    var description: String { "(\(minX),\(minY))-(\(maxX),\(maxY)) \(width)×\(height)" }
}

struct Bitmap {
    let width: Int, height: Int
    private let pixels: [UInt8]          // RGBA,行首在上(CGBitmapContext 的内存布局)

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw BitmapError.undecodable(url.lastPathComponent)
        }
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        pixels = buffer
    }

    enum BitmapError: Error { case undecodable(String) }

    subscript(x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), Int(pixels[i + 3]))
    }

    /// alpha > 8 的像素的包围盒(8 是抗锯齿噪声阈值)。
    var opaqueBounds: PixelBox? {
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where self[x, y].a > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : PixelBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    func firstOpaqueColumn(row y: Int) -> Int? {
        (0..<width).first { self[$0, y].a > 128 }
    }

    /// 完全不透明像素里出现次数最多的 `count` 种颜色(降序)。
    func dominantOpaqueColors(_ count: Int) -> [(color: RGB, pixels: Int)] {
        var histogram: [RGB: Int] = [:]
        for y in 0..<height {
            for x in 0..<width where self[x, y].a == 255 {
                let px = self[x, y]
                histogram[RGB(px.r, px.g, px.b), default: 0] += 1
            }
        }
        return histogram.sorted { $0.value > $1.value }.prefix(count)
            .map { (color: $0.key, pixels: $0.value) }
    }

    /// 颜色命中 `predicate` 的 4-邻接连通域,按面积降序;小于 `minimumArea` 的丢掉(抗锯齿碎屑)。
    func components(matching predicate: (RGB) -> Bool, minimumArea: Int) -> [PixelBox] {
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let px = self[x, y]
                if px.a == 255 && predicate(RGB(px.r, px.g, px.b)) { mask[y * width + x] = true }
            }
        }
        var seen = [Bool](repeating: false, count: width * height)
        var found: [(PixelBox, Int)] = []
        for start in 0..<(width * height) where mask[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minX = width, maxX = -1, minY = height, maxY = -1, area = 0
            while let p = stack.popLast() {
                let px = p % width, py = p / width
                area += 1
                minX = min(minX, px); maxX = max(maxX, px)
                minY = min(minY, py); maxY = max(maxY, py)
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let q = ny * width + nx
                    if mask[q] && !seen[q] { seen[q] = true; stack.append(q) }
                }
            }
            if area >= minimumArea {
                found.append((PixelBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY), area))
            }
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }
}
