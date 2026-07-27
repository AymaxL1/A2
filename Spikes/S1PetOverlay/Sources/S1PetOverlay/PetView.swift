// PROTOTYPE — throwaway spike code
import SwiftUI

struct PetView: View {
    @ObservedObject var state: PetState
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [interactive ? .orange.opacity(0.45) : .cyan.opacity(0.25), .clear],
                        center: .center, startRadius: 10, endRadius: 100
                    )
                )
            Text("🐈")
                .font(.system(size: 96))
                .scaleEffect(breathing ? 1.06 : 0.96)
                .rotationEffect(.degrees(Double(state.emoteCount % 2 == 0 ? 0 : 12)))
                .offset(y: breathing ? -4 : 4)
                .animation(.spring(response: 0.25, dampingFraction: 0.4), value: state.emoteCount)
        }
        .frame(width: 220, height: 220)
        .contentShape(Circle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    // 自动命中档下悬停=可交互，用光晕颜色给出视觉反馈
    private var interactive: Bool {
        state.autoHitTest ? state.hoveringPet : !state.manualClickThrough
    }
}
