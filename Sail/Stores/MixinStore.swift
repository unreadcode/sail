import Foundation
import Observation

/// Mixin 配置覆盖：用户提供一段 JSON，深合并进 KernelRunner 生成的 sing-box 配置，
/// 让高级用户无需改代码即可覆盖/补充任意字段（DNS、experimental、inbounds 细项等）。
/// 借鉴 GUI.for.SingBox 的 Mixin。局限同其设计：数组按整体替换，不做拼接。
@MainActor
@Observable
final class MixinStore {
    static let shared = MixinStore()

    /// 冲突时谁优先。
    enum Priority: String, Codable, CaseIterable, Identifiable {
        case mixinWins      // Mixin 覆盖生成值
        case generatedWins  // 生成值优先，Mixin 只补缺失键
        var id: String { rawValue }
        var label: String { self == .mixinWins ? "Mixin 覆盖" : "生成优先(仅补缺)" }
    }

    private(set) var enabled = false
    private(set) var priority: Priority = .mixinWins
    private(set) var text = ""

    private var fileURL: URL { KernelPaths.supportDir.appendingPathComponent("mixin.json") }

    private init() { load() }

    /// 文本解析为 JSON 对象；空文本或非法返回 nil。
    static func parseObject(_ s: String) -> [String: Any]? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// 当前文本是否可用作 mixin（空 = 合法但无覆盖；非空须是 JSON 对象）。
    var textIsValid: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.parseObject(text) != nil
    }

    /// 把 mixin 合并进生成的配置；未启用 / 文本非法 / 空 → 原样返回。
    func apply(to config: [String: Any]) -> [String: Any] {
        guard enabled, let overlay = Self.parseObject(text) else { return config }
        return Self.deepMerge(config, overlay, overlayWins: priority == .mixinWins)
    }

    /// 深合并：两边都是对象则递归合并；否则按 overlayWins 决定取 overlay 还是保留 base。
    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any], overlayWins: Bool) -> [String: Any] {
        var result = base
        for (k, v) in overlay {
            if let bv = result[k] as? [String: Any], let ov = v as? [String: Any] {
                result[k] = deepMerge(bv, ov, overlayWins: overlayWins)
            } else if overlayWins || result[k] == nil {
                result[k] = v
            }
        }
        return result
    }

    // MARK: 修改（落盘 + 按需重启内核应用）

    func setText(_ s: String) { guard s != text else { return }; text = s; save() }
    func setEnabled(_ on: Bool) { guard on != enabled else { return }; enabled = on; persistAndApply() }
    func setPriority(_ p: Priority) { guard p != priority else { return }; priority = p; persistAndApply() }

    /// 编辑完点「应用」：落盘并（启用且运行中时）重启内核生效。
    func applyNow() { save(); if KernelRunner.shared.isRunning { Task { await KernelRunner.shared.restart() } } }

    private func persistAndApply() {
        save()
        if KernelRunner.shared.isRunning { Task { await KernelRunner.shared.restart() } }
    }

    // MARK: 持久化

    private struct Persisted: Codable { var enabled = false; var priority = Priority.mixinWins; var text = "" }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let p = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        enabled = p.enabled; priority = p.priority; text = p.text
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: KernelPaths.supportDir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Persisted(enabled: enabled, priority: priority, text: text))
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        } catch { /* 尽力而为 */ }
    }
}
