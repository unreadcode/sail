import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// 订阅页面：纯订阅信息，平铺卡片展示（不含节点；选节点在首页下拉里）。
struct SubscriptionsView: View {
    @State private var store = SubscriptionStore.shared
    @State private var showingAdd = false
    @State private var qrSub: Subscription?
    @State private var editSub: Subscription?

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: .infinity), spacing: 18)]

    var body: some View {
        Group {
            if store.subscriptions.isEmpty {
                EmptyState { showingAdd = true }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summaryHeader
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(Array(store.subscriptions.enumerated()), id: \.element.id) { index, sub in
                                SubscriptionCard(
                                    sub: sub,
                                    // 当前订阅高亮：显式选中的；未显式选择时回退到第一个订阅（见 selectedSubscription）
                                    selected: store.selectedSubscription?.id == sub.id,
                                    index: index,
                                    onEdit: { editSub = sub },
                                    onQR: { qrSub = sub }
                                )
                            }
                        }
                    }
                    .padding(22)
                    .animation(.snappy(duration: 0.25), value: store.subscriptions)
                }
                .scrollIndicators(.hidden)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if !store.subscriptions.isEmpty {
                    Button { Task { await store.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("全部刷新")
                }
                Button { importFromClipboard() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .help("从剪贴板导入订阅")
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .help("添加订阅")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddSubscriptionSheet { name, url, ua, timeout, autoUpdate, interval, viaProxy in
                Task { await store.add(name: name, url: url, userAgent: ua, timeoutSec: timeout,
                                       autoUpdate: autoUpdate, updateIntervalMin: interval, updateViaProxy: viaProxy) }
            }
        }
        .sheet(item: $qrSub) { QRCodeSheet(subscription: $0) }
        .sheet(item: $editSub) { sub in
            EditSubscriptionSheet(subscription: sub) { name, url, ua, timeout, autoUpdate, interval, viaProxy in
                Task { await store.update(sub.id, name: name, url: url, userAgent: ua, timeoutSec: timeout,
                                          autoUpdate: autoUpdate, updateIntervalMin: interval, updateViaProxy: viaProxy) }
            }
        }
    }

    /// 读剪贴板里的订阅链接直接导入（仅当是 http(s) 链接时）。
    private func importFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("http") else { return }
        Task { await store.add(name: "", url: raw) }
    }

    private var summaryHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("我的订阅")
                .font(.system(size: 21, weight: .bold, design: .rounded))
            Text("\(store.subscriptions.count)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5), in: Capsule())
            Spacer(minLength: 0)
            Label("\(store.allNodes.count) 个节点", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

// MARK: - 订阅卡片

private struct SubscriptionCard: View {
    let sub: Subscription
    let selected: Bool
    var index: Int = 0
    var onEdit: () -> Void
    var onQR: () -> Void

    @State private var store = SubscriptionStore.shared
    @State private var hovering = false
    @State private var shown = false
    @State private var confirmingDelete = false

    static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            if sub.hasTraffic { trafficBlock }
            Spacer(minLength: 4)
            footer
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.07 : 0))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: selected ? Color.accentColor.opacity(0.16) : .black.opacity(hovering ? 0.10 : 0.04),
                radius: hovering ? 11 : 6, y: hovering ? 5 : 3)
        .scaleEffect(hovering ? 1.012 : 1)
        .contentShape(Rectangle())
        .onTapGesture { Task { await store.selectSubscription(sub.id) } }
        .onHover { hovering = $0 }
        .help("点击设为当前订阅")
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 14)
        .animation(.smooth(duration: 0.4).delay(min(Double(index) * 0.05, 0.4)), value: shown)
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.22), value: selected)
        .onAppear { shown = true }
        .contextMenu {
            Button { Task { await store.selectSubscription(sub.id) } } label: {
                Label("使用", systemImage: "checkmark.circle")
            }
            .disabled(sub.nodes.isEmpty)
            Button { Task { await store.refresh(sub.id, viaProxy: sub.updateViaProxy) } } label: {
                Label("更新", systemImage: "arrow.clockwise")
            }
            Button { Task { await store.refresh(sub.id, viaProxy: true) } } label: {
                Label("更新（代理）", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!KernelRunner.shared.isRunning)
            Divider()
            Button { onEdit() } label: { Label("编辑信息", systemImage: "pencil") }
            Button { onQR() } label: { Label("分享二维码", systemImage: "qrcode") }
            Button { copyToPasteboard(sub.url) } label: { Label("复制链接", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { confirmingDelete = true } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .confirmationDialog("删除订阅「\(sub.name.isEmpty ? "未命名" : sub.name)」？",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { store.remove(sub.id) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除该订阅及其节点，此操作不可撤销。")
        }
    }

    // 头部：图标 + 名称 / 节点数 + 状态
    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.72)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color(nsColor: .quaternaryLabelColor).opacity(0.4)))
                    .frame(width: 38, height: 38)
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? .white : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(sub.name.isEmpty ? "获取中…" : sub.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .lineLimit(1)
                Text(sub.lastError == nil ? "\(sub.nodes.count) 个节点" : "更新失败")
                    .font(.system(size: 11))
                    .foregroundStyle(sub.lastError == nil ? Color.secondary : Color.red)
            }
            Spacer(minLength: 0)
            trailingControls
        }
    }

    private var trailingControls: some View {
        HStack(spacing: 7) {
            if store.isBusy(sub.id) {
                Spinner(size: 14)
            } else {
                if selected {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.accentColor)
                }
                Button { Task { await store.refresh(sub.id, viaProxy: sub.updateViaProxy) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(hovering ? 0.5 : 0),
                                    in: Circle())
                }
                .buttonStyle(.plain)
                .help("更新订阅")
            }
        }
    }

    // 流量：已用大字 + 剩余 + 渐变进度条
    private var trafficBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(formatBytes(Double(sub.used)))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                Text("/ \(formatBytes(Double(sub.total)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("剩 \(formatBytes(Double(max(0, sub.total - sub.used))))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            UsageBar(fraction: sub.usedFraction).frame(height: 6)
        }
    }

    // 到期（带紧迫度配色）/ 相对更新时间
    private var footer: some View {
        HStack(spacing: 12) {
            if let expire = sub.expire { expiryLabel(expire) }
            Spacer(minLength: 0)
            if let updated = sub.updatedAt {
                Label(Self.relativeFmt.localizedString(for: updated, relativeTo: Date()),
                      systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
    }

    private func expiryLabel(_ date: Date) -> some View {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let color: Color = days < 0 ? .red : (days <= 7 ? .orange : .secondary)
        let text = days < 0 ? "已过期" : "到期 \(Self.dateFmt.string(from: date))"
        return Label(text, systemImage: days < 0 ? "exclamationmark.triangle" : "calendar")
            .foregroundStyle(color)
    }

    private var borderColor: Color {
        if selected { return Color.accentColor.opacity(0.85) }
        if hovering { return Color.accentColor.opacity(0.35) }
        return Color(nsColor: .separatorColor).opacity(0.5)
    }
}

// MARK: - 流量条

private struct UsageBar: View {
    let fraction: Double

    private var colors: [Color] {
        switch fraction {
        case ..<0.7: [Color.accentColor.opacity(0.65), Color.accentColor]
        case ..<0.9: [.yellow, .orange]
        default: [.orange, .red]
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.45))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * min(1, fraction)))
            }
        }
    }
}

// MARK: - 空状态

private struct EmptyState: View {
    var onAdd: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.1)).frame(width: 88, height: 88)
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                Text("还没有订阅")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("粘贴机场的订阅链接，自动解析节点")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button { onAdd() } label: {
                Label("添加订阅", systemImage: "plus")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 添加订阅弹窗

private struct AddSubscriptionSheet: View {
    var onAdd: (_ name: String, _ url: String, _ ua: String, _ timeout: Int, _ autoUpdate: Bool, _ interval: Int, _ viaProxy: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var ua = ""
    @State private var timeoutText = ""
    @State private var intervalText = ""
    @State private var autoUpdate = true
    @State private var updateViaProxy = false
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("添加订阅").font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            field("名称（可选）") {
                TextField("我的订阅", text: $name).textFieldStyle(.roundedBorder)
            }
            field("订阅链接") {
                TextField("https://…", text: $url, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(size: 12, design: .monospaced))
            }

            Button {
                withAnimation(.snappy(duration: 0.2)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                    Text("高级选项").font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(alignment: .leading, spacing: 14) {
                    field("User Agent") {
                        TextField("clash-verge/v2.5.0", text: $ua)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    HStack(spacing: 14) {
                        field("HTTP 超时（秒）") {
                            TextField("60", text: $timeoutText)
                                .textFieldStyle(.roundedBorder).frame(width: 80)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: timeoutText) { _, n in timeoutText = String(n.filter(\.isNumber).prefix(4)) }
                        }
                        field("更新间隔（分钟）") {
                            TextField("1440", text: $intervalText)
                                .textFieldStyle(.roundedBorder).frame(width: 90)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: intervalText) { _, n in intervalText = String(n.filter(\.isNumber).prefix(6)) }
                        }
                        Spacer(minLength: 0)
                    }
                    Toggle(isOn: $autoUpdate) {
                        Text("允许自动更新").font(.system(size: 13))
                    }
                    .toggleStyle(.switch)
                    Toggle(isOn: $updateViaProxy) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("使用内核代理更新").font(.system(size: 13))
                            Text("更新时经内核混合端口拉取（内核未运行时自动直连）")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    // 留空即用默认：UA=clash-verge/v2.5.0、超时 60s、间隔 1440min
                    let uaVal = ua.trimmingCharacters(in: .whitespaces)
                    onAdd(name, url,
                          uaVal.isEmpty ? "clash-verge/v2.5.0" : uaVal,
                          Int(timeoutText) ?? 60, autoUpdate, Int(intervalText) ?? 1440, updateViaProxy)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    @ViewBuilder
    private func field<T: View>(_ label: String, @ViewBuilder content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - 编辑信息弹窗

private struct EditSubscriptionSheet: View {
    let subscription: Subscription
    var onSave: (_ name: String, _ url: String, _ ua: String, _ timeout: Int, _ autoUpdate: Bool, _ interval: Int, _ viaProxy: Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var ua = ""
    @State private var timeoutText = ""
    @State private var intervalText = ""
    @State private var autoUpdate = true
    @State private var updateViaProxy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("编辑订阅").font(.system(size: 16, weight: .semibold, design: .rounded))
            }
            field("名称") {
                TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            }
            field("订阅链接") {
                TextField("https://…", text: $url, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .font(.system(size: 12, design: .monospaced))
            }
            field("User Agent") {
                TextField("clash-verge/v2.5.0", text: $ua)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack(spacing: 14) {
                field("HTTP 超时（秒）") {
                    TextField("60", text: $timeoutText)
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: timeoutText) { _, n in timeoutText = String(n.filter(\.isNumber).prefix(4)) }
                }
                field("更新间隔（分钟）") {
                    TextField("1440", text: $intervalText)
                        .textFieldStyle(.roundedBorder).frame(width: 90)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: intervalText) { _, n in intervalText = String(n.filter(\.isNumber).prefix(6)) }
                }
                Spacer(minLength: 0)
            }
            Toggle(isOn: $autoUpdate) {
                Text("允许自动更新").font(.system(size: 13))
            }
            .toggleStyle(.switch)
            Toggle(isOn: $updateViaProxy) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("使用内核代理更新").font(.system(size: 13))
                    Text("更新时经内核混合端口拉取（内核未运行时自动直连）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let uaVal = ua.trimmingCharacters(in: .whitespaces)
                    onSave(name, url,
                           uaVal.isEmpty ? "clash-verge/v2.5.0" : uaVal,
                           Int(timeoutText) ?? 60, autoUpdate, Int(intervalText) ?? 1440, updateViaProxy)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            name = subscription.name
            url = subscription.url
            ua = subscription.userAgent
            timeoutText = String(subscription.timeoutSec)
            intervalText = String(subscription.updateIntervalMin)
            autoUpdate = subscription.autoUpdate
            updateViaProxy = subscription.updateViaProxy
        }
    }

    @ViewBuilder
    private func field<T: View>(_ label: String, @ViewBuilder content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - 二维码弹窗

private struct QRCodeSheet: View {
    let subscription: Subscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(subscription.name).font(.system(size: 15, weight: .semibold, design: .rounded))
            if let img = Self.makeQR(subscription.url) {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Text("无法生成二维码").foregroundStyle(.secondary).frame(height: 220)
            }
            Text(subscription.url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: 240)
            HStack {
                Button("复制链接") { copyToPasteboard(subscription.url) }
                Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 300)
    }

    private static func makeQR(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

#Preview {
    SubscriptionsView().frame(width: 900, height: 620)
}
