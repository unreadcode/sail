import SwiftUI

/// 轻量旋转指示器（纯 SwiftUI 自绘）。
/// 用它取代不确定型 `ProgressView()`：后者桥接成 NSProgressIndicator 后会在
/// 动画每帧抛出「maximum length doesn't satisfy min <= max」退化约束警告并刷屏。
struct Spinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    var color: Color = .secondary
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.75).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
