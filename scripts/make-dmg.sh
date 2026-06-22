#!/usr/bin/env bash
# 一键打包精致 DMG：构建 Release → 自绘背景 → dmgbuild 出包
# dmgbuild 直接写 .DS_Store（不依赖 Finder AppleScript），布局稳定可靠。
# 用法：scripts/make-dmg.sh [输出路径]   默认 $PWD/Sail.dmg
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根目录

APP_NAME="Sail"
VOL="Sail"
OUT="${1:-$PWD/Sail.dmg}"
DD="build/Release-dd"
APP="$DD/Build/Products/Release/$APP_NAME.app"
VENV="build/dmgvenv"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "▶ 准备内核（在线拉取并内置）…"
scripts/fetch-kernel.sh

echo "▶ 准备 geo 规则集（在线拉取并内置）…"
scripts/fetch-georules.sh

echo "▶ 构建 Release…"
# stdout 静音（编译日志太吵）；stderr 保留 + set -e：真出错仍会报错并中止
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" build >/dev/null
[ -d "$APP" ] || { echo "✗ 未找到 $APP"; exit 1; }

# 编译特权 helper 进 bundle（精简 Swift），并整体重签（含 helper / 内核），保持 ad-hoc 签名完整
echo "▶ 编译并内嵌特权 helper…"
mkdir -p "$APP/Contents/Helpers"
# 部署目标必须钉死 14.0：不带 -target 会跟构建机(CI=macOS 26)走，链到 26-only 的
# libswift_DarwinFoundation3.dylib，低于 26 的机器加载即崩、TUN 起不来（v1.1.5/1.1.6 的坑）。
env MACOSX_DEPLOYMENT_TARGET=14.0 xcrun swiftc -O -target arm64-apple-macos14.0 Helper/main.swift -o "$APP/Contents/Helpers/sail-helper"
# 自检：产物若仍链接 macOS 26 专属库，直接中止打包，绝不发出在旧系统崩溃的包。
if otool -L "$APP/Contents/Helpers/sail-helper" | grep -qi DarwinFoundation3; then
  echo "✗ sail-helper 链接了 macOS 26 专属库，旧系统会崩，打包中止"; exit 1
fi
echo "  sail-helper minos=$(otool -l "$APP/Contents/Helpers/sail-helper" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')（应为 14.0）"
codesign --force --sign - "$APP/Contents/Helpers/sail-helper"
codesign --force --deep --sign - "$APP"

# 准备 dmgbuild（独立 venv，避免污染系统 Python）
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "▶ 准备 dmgbuild…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install dmgbuild
fi

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '')"

echo "▶ 生成背景图…"
BG="$TMP/bg.png"
cat > "$TMP/bg.swift" << 'SWIFT'
import AppKit
let outPath = CommandLine.arguments[1]
let ver = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
let W = 1280.0, H = 920.0   // 2x of 640x460
// 直接画进 bitmap 上下文，不用 NSImage.lockFocus —— 后者依赖窗口服务，headless CI 上会失败
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
func rounded(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont {
    let b = NSFont.systemFont(ofSize: s, weight: w)
    if let d = b.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: d, size: s) ?? b }
    return b
}
let green = NSColor(srgbRed: 0.18, green: 0.78, blue: 0.44, alpha: 1)
NSGradient(colors: [.white, NSColor(srgbRed: 0.91, green: 0.965, blue: 0.93, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
if let glow = NSGradient(colors: [green.withAlphaComponent(0.16), green.withAlphaComponent(0)]) {
    glow.draw(fromCenter: NSPoint(x: W/2, y: H - 120), radius: 0,
              toCenter: NSPoint(x: W/2, y: H - 120), radius: 520, options: [])
}
func center(_ s: String, _ f: NSFont, _ c: NSColor, _ yTop: CGFloat) {
    let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c]
    let sz = s.size(withAttributes: a)
    s.draw(at: NSPoint(x: (W - sz.width)/2, y: H - yTop - sz.height), withAttributes: a)
}
center("Sail", rounded(76, .bold), NSColor(srgbRed: 0.11, green: 0.12, blue: 0.13, alpha: 1), 70)
center(ver.isEmpty ? "优雅的 sing-box 客户端" : "优雅的 sing-box 客户端 · v\(ver)",
       rounded(26, .medium), NSColor(srgbRed: 0.55, green: 0.58, blue: 0.56, alpha: 1), 196)
// 箭头：图标中心 y=240(window) → image cy=440
let cy = 440.0
green.withAlphaComponent(0.9).setStroke()
let t = NSBezierPath(); t.lineWidth = 8; t.lineCapStyle = .round
t.move(to: NSPoint(x: 512, y: cy)); t.line(to: NSPoint(x: 762, y: cy)); t.stroke()
let h = NSBezierPath(); h.lineWidth = 8; h.lineCapStyle = .round; h.lineJoinStyle = .round
h.move(to: NSPoint(x: 714, y: cy+38)); h.line(to: NSPoint(x: 772, y: cy)); h.line(to: NSPoint(x: 714, y: cy-38)); h.stroke()
center("将 Sail 拖入「应用程序」完成安装", rounded(28, .semibold),
       NSColor(srgbRed: 0.42, green: 0.45, blue: 0.43, alpha: 1), 760)
NSGraphicsContext.restoreGraphicsState()
// 关键：把 1280x920 像素的位图标成 640x460 点（= 144 DPI / @2x）。
// Finder 画 DMG 背景时按「点」尺寸铺，否则会把图当 1280pt 宽 → 标题溢出到窗外。
rep.size = NSSize(width: 640, height: 460)
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: outPath))
SWIFT
# 写成临时文件再跑（比 `swift -` 从 stdin 读更稳）；渲染失败非致命 → 退回无背景 DMG，保证仍能出包
if ! swift "$TMP/bg.swift" "$BG" "$VER"; then
  echo "⚠ 背景图生成失败，改用无背景 DMG"; BG=""
fi

echo "▶ 打包 DMG…"
SETTINGS="$TMP/settings.py"
cat > "$SETTINGS" << 'PY'
import os
app = os.environ["APP_PATH"]
appname = os.path.basename(app)
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {appname: (160, 240), "Applications": (480, 240)}
_bg = os.environ.get("BG_PATH", "")
if _bg:
    background = _bg
window_rect = ((220, 120), (640, 460))
default_view = "icon-view"
icon_size = 128
text_size = 13
PY

rm -f "$OUT"
APP_PATH="$APP" BG_PATH="$BG" "$VENV/bin/dmgbuild" -s "$SETTINGS" "$VOL" "$OUT"
echo "✓ DMG：$OUT ($(du -h "$OUT" | cut -f1))"

# 额外产出 Sail.app.zip，供 app 内自动更新下载（ditto 保留符号链接 / 资源叉 / 签名）
ZIP="$(dirname "$OUT")/$APP_NAME.app.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "✓ ZIP：$ZIP ($(du -h "$ZIP" | cut -f1))"
