#!/usr/bin/env bash
# 由 scripts/appicon-source.png（全幅美术图）生成符合 macOS 规范的 AppIcon。
# macOS 26 以下不会自动给图标套圆角，必须把「圆角矩形 + 四角透明 + 留白」烤进 PNG，
# 否则旧系统会露出白色直角方块。按 Apple 网格：1024 画布内 824 圆角矩形居中、
# 圆角半径 ~185、四周留 100px 透明边（阴影空间）。幂等：重复跑结果一致。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="scripts/appicon-source.png"
SET="Sail/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master.png"
[ -f "$SRC" ] || { echo "✗ 缺少源图 $SRC"; exit 1; }

echo "▶ 生成 1024 主图（圆角 + 留白）…"
swift - "$SRC" "$MASTER" << 'SWIFT'
import AppKit
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let out = CommandLine.arguments[2]
let S = 1024.0, inset = 100.0, side = S - inset * 2   // 824 内容区
let radius = side * 0.2247                            // ≈185，macOS 连续圆角观感
let canvas = NSImage(size: NSSize(width: S, height: S))
canvas.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.imageInterpolation = .high
let rect = NSRect(x: inset, y: inset, width: side, height: side)
// 轻微投影，旧系统下也有立体感（透明边就是给它留的）
ctx.cgContext.setShadow(offset: CGSize(width: 0, height: -8),
                        blur: 28, color: NSColor.black.withAlphaComponent(0.18).cgColor)
let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
clip.fill()                          // 先用阴影画一次形状垫底
ctx.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
clip.addClip()                       // 裁成圆角，把源图铺进去
src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT

echo "▶ 重采样各尺寸…"
gen() { sips -z "$2" "$2" "$MASTER" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
cp "$MASTER" "$SET/icon_512x512@2x.png"
echo "✓ AppIcon 已重建 → $SET"
