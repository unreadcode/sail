import SwiftUI

/// 原生风格卡片容器：控件背景色 + 圆角 + 细描边
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    var fillHeight: Bool = false   // 撑满父容器高度（用于并排卡片等高）
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
    }
}

/// 分区小标题：竖条 + 全大写间距字
struct SectionHeader<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    init(_ label: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.label = label
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 13)
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing
        }
    }
}
