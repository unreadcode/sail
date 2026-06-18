import Foundation

/// 字节数格式化为带单位的可读字符串；perSec=true 追加「/s」。
/// < 10 且非 B 单位保留一位小数（如 5.7 MB），否则取整。
func formatBytes(_ bytes: Double, perSec: Bool = false) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var n = bytes
    var i = 0
    while n >= 1024 && i < units.count - 1 {
        n /= 1024
        i += 1
    }
    let value = n < 10 && i > 0 ? String(format: "%.1f", n) : String(Int(n.rounded()))
    return "\(value) \(units[i])\(perSec ? "/s" : "")"
}

/// 运行时长（秒）格式化为「天/小时/分/秒」的就近表示。
func formatUptime(_ sec: Int) -> String {
    let d = sec / 86400
    let h = (sec % 86400) / 3600
    let m = (sec % 3600) / 60
    if d > 0 { return "\(d) 天 \(h) 小时" }
    if h > 0 { return "\(h) 小时 \(m) 分" }
    return "\(m) 分 \(sec % 60) 秒"
}
