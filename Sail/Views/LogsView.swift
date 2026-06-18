import SwiftUI
import AppKit

/// 内核运行日志页面：实时展示 sing-box 输出，支持自动滚动、复制与清空。
struct LogsView: View {
    private let runner = KernelRunner.shared
    @State private var minLevel: LogLevel = .all

    /// 日志级别过滤（最低级别：选中项及更高才显示）。
    enum LogLevel: Int, CaseIterable, Identifiable {
        case all, info, warn, error
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .all: "全部"
            case .info: "信息"
            case .warn: "警告"
            case .error: "错误"
            }
        }
        /// 严重度阈值：行的严重度 >= 此值才显示。
        var threshold: Int {
            switch self {
            case .all: 0
            case .info: 1
            case .warn: 2
            case .error: 3
            }
        }
    }

    /// 取一行日志的严重度：trace/debug=0、info=1、warn=2、error=3、fatal/panic=4。
    /// sing-box 带时间戳的格式为 `+0800 2026-… 22:30:04 LEVEL …`，级别在第 4 段。
    /// 行内显式级别 → 严重度；无法识别级别（多为 panic/error 的堆栈续行）返回 nil，由调用方决定继承。
    static func explicitSeverity(of line: String) -> Int? {
        let clean = KernelRunner.stripANSI(line)
        let fields = clean.split(separator: " ", omittingEmptySubsequences: true)
        let token = fields.count > 3 ? fields[3].uppercased() : ""
        switch token {
        case "FATAL", "PANIC": return 4
        case "ERROR": return 3
        case "WARN", "WARNING": return 2
        case "INFO": return 1
        case "DEBUG", "TRACE": return 0
        default:
            if clean.contains("FATAL") || clean.contains(" ERROR") { return 3 }
            if clean.contains(" WARN") { return 2 }
            return nil
        }
    }

    private var filtered: [LogLine] {
        guard minLevel != .all else { return runner.logLines }
        // 续行（无显式级别）继承上一行级别：否则 error 的多行堆栈会被当「信息」，筛「错误」时丢失关键细节。
        var carried = 1
        return runner.logLines.filter { line in
            let sev = Self.explicitSeverity(of: line.text) ?? carried
            carried = sev
            return sev >= minLevel.threshold
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if runner.logLines.isEmpty {
                emptyState
            } else {
                logScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runner.isRunning ? Color.accentColor : Color.secondary)
                .frame(width: 7, height: 7)
            Text(runner.isRunning ? "运行中" : "已停止")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.secondary)
            Text(minLevel == .all ? "\(runner.logLines.count) 行"
                                  : "\(filtered.count) / \(runner.logLines.count) 行")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $minLevel) {
                ForEach(LogLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("按日志级别过滤（显示所选级别及更高）")

            Button { copyAll() } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .disabled(runner.logLines.isEmpty)

            Button { runner.clearLogs() } label: {
                Label("清空", systemImage: "trash")
            }
            .disabled(runner.logLines.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: 日志列表（自动滚到底部）

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filtered) { line in
                        Text(ANSI.attributed(line.text))
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay {
                    if filtered.isEmpty {
                        Text("没有「\(minLevel.label)」级别的日志")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            // 监听最后一行的 id 而非行数：日志封顶后行数恒为 800 不变，但新行仍在进来，
            // 用 last?.id 才能持续触底；切换过滤级别时 last 也会变，一并覆盖。
            .onChange(of: filtered.last?.id) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 4) {
                Text("暂无日志")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text(runner.isRunning ? "等待内核输出 …" : "启动内核后将在此显示运行日志")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 工具

    private func copyAll() {
        // 复制时剥离颜色码，得到纯文本
        let text = runner.logLines.map { KernelRunner.stripANSI($0.text) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// 把含 ANSI SGR 转义序列的字符串解析为带前景色的 AttributedString。
enum ANSI {
    static func attributed(_ line: String) -> AttributedString {
        var result = AttributedString()
        var color: Color? = nil
        var bold = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            var seg = AttributedString(buffer)
            if let color { seg.foregroundColor = color }
            if bold { seg.font = .system(size: 11.5, weight: .semibold, design: .monospaced) }
            result += seg
            buffer = ""
        }

        let chars = Array(line)
        var i = 0
        while i < chars.count {
            // ESC '[' … 'm' —— SGR 序列
            if chars[i] == "\u{1B}", i + 1 < chars.count, chars[i + 1] == "[" {
                flush()
                var j = i + 2
                var code = ""
                while j < chars.count, chars[j] != "m" {
                    code.append(chars[j]); j += 1
                }
                apply(code, color: &color, bold: &bold)
                i = (j < chars.count) ? j + 1 : j
            } else {
                buffer.append(chars[i]); i += 1
            }
        }
        flush()
        return result
    }

    private static func apply(_ code: String, color: inout Color?, bold: inout Bool) {
        let parts = code.split(separator: ";").map { Int($0) ?? 0 }
        if parts.isEmpty { color = nil; bold = false; return }
        var k = 0
        while k < parts.count {
            switch parts[k] {
            case 0: color = nil; bold = false
            case 1: bold = true
            case 22: bold = false
            case 39: color = nil
            case 30...37: color = basic(parts[k] - 30, bright: false)
            case 90...97: color = basic(parts[k] - 90, bright: true)
            case 38:
                if k + 2 < parts.count, parts[k + 1] == 5 {
                    color = xterm256(parts[k + 2]); k += 2
                } else if k + 4 < parts.count, parts[k + 1] == 2 {
                    color = Color(.sRGB,
                                  red: Double(parts[k + 2]) / 255,
                                  green: Double(parts[k + 3]) / 255,
                                  blue: Double(parts[k + 4]) / 255)
                    k += 4
                }
            default: break
            }
            k += 1
        }
    }

    /// 基础 8 色（30-37 / 90-97）——挑选在明暗背景下都清晰的近似色
    private static func basic(_ idx: Int, bright: Bool) -> Color {
        switch idx {
        case 0: return .secondary          // black
        case 1: return .red
        case 2: return .green
        case 3: return .orange             // yellow（白底上偏橙更清晰）
        case 4: return .blue
        case 5: return .purple             // magenta
        case 6: return .teal               // cyan（sing-box 的 INFO 用色）
        default: return .primary           // white
        }
    }

    /// xterm 256 调色板 → sRGB
    private static func xterm256(_ n: Int) -> Color {
        switch n {
        case 0...7: return basic(n, bright: false)
        case 8...15: return basic(n - 8, bright: true)
        case 16...231:
            let i = n - 16
            let r = i / 36, g = (i / 6) % 6, b = i % 6
            func comp(_ v: Int) -> Double { v == 0 ? 0 : Double(55 + v * 40) / 255 }
            return Color(.sRGB, red: comp(r), green: comp(g), blue: comp(b))
        default: // 232...255 灰阶
            let level = Double(8 + (n - 232) * 10) / 255
            return Color(.sRGB, red: level, green: level, blue: level)
        }
    }
}

#Preview {
    LogsView().frame(width: 800, height: 600)
}
