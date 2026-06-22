import SwiftUI

// 节点展示用的共享小助手：协议配色 + 名称里国旗/emoji 的拆分。
// 原先定义在 NodesView.swift；节点页移除后挪到此处，供分组页 / 概览 / 托盘等复用。

enum ProtocolStyle {
    static func color(_ type: String) -> Color {
        switch type.lowercased() {
        case "tuic": .indigo
        case "anytls": .teal
        case "naive": .orange
        case "vmess": .blue
        case "vless": .purple
        case "trojan": .pink
        case "shadowsocks", "ss": .green
        case "hysteria2", "hysteria", "hy2": .mint
        default: .gray
        }
    }
}

enum NodeName {
    /// 拆出名称开头的国旗 / emoji 与其余文本。
    static func split(_ name: String) -> (flag: String, name: String) {
        var flag = ""
        var idx = name.startIndex
        while idx < name.endIndex {
            let ch = name[idx]
            let isFlag = ch.unicodeScalars.allSatisfy { s in
                (s.value >= 0x1F1E6 && s.value <= 0x1F1FF)
                    || (s.properties.isEmojiPresentation && s.value >= 0x1F000)
            }
            if isFlag {
                flag.append(ch)
                idx = name.index(after: idx)
            } else { break }
        }
        let rest = String(name[idx...]).trimmingCharacters(in: .whitespaces)
        return (flag, rest.isEmpty ? name : rest)
    }
}
