// PROTOTYPE — throwaway spike code
import AppKit
import SwiftUI

@MainActor
final class PetState: ObservableObject {
    enum Level: String, CaseIterable, Identifiable {
        case floating, statusBar, screenSaver
        var id: String { rawValue }
        var nsLevel: NSWindow.Level {
            switch self {
            case .floating: return .floating
            case .statusBar: return .statusBar
            case .screenSaver: return .screenSaver
            }
        }
    }

    @Published var manualClickThrough = false
    @Published var autoHitTest = true
    @Published var hoveringPet = false
    @Published var level: Level = .floating
    @Published var allSpaces = true
    @Published var emoteCount = 0
    @Published var lastEvent = "启动"

    weak var panel: NSPanel?

    func note(_ event: String) {
        lastEvent = event
        print("[\(timestamp())] \(event)\n\(readout(indent: "  "))")
        fflush(stdout) // 日志常被重定向到文件，块缓冲会吞掉实时性
    }

    func emote() {
        emoteCount += 1
        note("宠物被点了一下（emote #\(emoteCount)）")
    }

    func applyToPanel() {
        guard let panel else { return }
        panel.level = level.nsLevel
        panel.collectionBehavior = allSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.managed]
        if autoHitTest {
            panel.ignoresMouseEvents = !hoveringPet
        } else {
            panel.ignoresMouseEvents = manualClickThrough
        }
    }

    func readout(indent: String = "") -> String {
        let p = panel
        let frame = p.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? "-"
        let screen = p?.screen.map { $0.localizedName } ?? "（不在任何屏上？）"
        return [
            "\(indent)穿透: \(p?.ignoresMouseEvents == true ? "是" : "否")（\(autoHitTest ? "自动命中档，悬停=\(hoveringPet)" : "手动档=\(manualClickThrough)")）",
            "\(indent)层级: \(level.rawValue)  全空间: \(allSpaces ? "开" : "关（默认 managed）")",
            "\(indent)位置: \(frame) @ \(screen)",
            "\(indent)emote: \(emoteCount) 次  最近事件: \(lastEvent)",
        ].joined(separator: "\n")
    }

    private func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
