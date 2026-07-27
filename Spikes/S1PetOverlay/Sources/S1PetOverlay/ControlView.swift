// PROTOTYPE — throwaway spike code
import SwiftUI

struct ControlView: View {
    @ObservedObject var state: PetState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("S1 宠物悬浮窗 spike — 控制台").font(.headline)

            Toggle("自动命中档（悬停宠物=可点可拖，移开=穿透）", isOn: bind(\.autoHitTest, "自动命中档"))
            Toggle("手动点击穿透", isOn: bind(\.manualClickThrough, "手动穿透"))
                .disabled(state.autoHitTest)

            Picker("窗口层级", selection: bind(\.level, "层级")) {
                ForEach(PetState.Level.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("全空间 + 全屏辅助 + stationary", isOn: bind(\.allSpaces, "全空间"))

            Divider()
            Text(state.readout())
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("逗一下") { state.emote() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func bind<T>(_ path: ReferenceWritableKeyPath<PetState, T>, _ name: String) -> Binding<T> {
        Binding(
            get: { state[keyPath: path] },
            set: {
                state[keyPath: path] = $0
                state.applyToPanel()
                state.note("\(name) → \($0)")
            }
        )
    }
}
