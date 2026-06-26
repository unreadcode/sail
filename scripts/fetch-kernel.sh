#!/usr/bin/env bash
# 下载锁定版本的 sing-box（darwin/arm64）内置到 Sail/Resources/sing-box。
# 仓库本身不含该二进制（被 .gitignore 忽略）——本地打包 / CI 构建前调用本脚本就位即可。
# 用法：scripts/fetch-kernel.sh [version]   默认用下方 PINNED；也可用环境变量 KERNEL_VERSION 覆盖。
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根目录

PINNED="1.13.14"   # ← 升级内核改这里
REPO="SagerNet/sing-box"
VER="${1:-${KERNEL_VERSION:-$PINNED}}"
VER="${VER#v}"     # 去掉前缀 v
DEST="Sail/Resources/sing-box"
ASSET="sing-box-${VER}-darwin-arm64"
URL="https://github.com/${REPO}/releases/download/v${VER}/${ASSET}.tar.gz"

ver_of() { "$1" version 2>/dev/null | awk '/ version /{print $3; exit}'; }

# 幂等：已是目标版本则跳过
if [ -x "$DEST" ] && [ "$(ver_of "$DEST")" = "$VER" ]; then
  echo "✓ sing-box ${VER} 已就位，跳过下载"
  exit 0
fi

echo "▶ 下载 sing-box ${VER} … ($URL)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fL --retry 3 -o "$TMP/kernel.tar.gz" "$URL"
tar -xzf "$TMP/kernel.tar.gz" -C "$TMP"
BIN="$TMP/${ASSET}/sing-box"
[ -f "$BIN" ] || { echo "✗ 解压后未找到 sing-box"; exit 1; }

# 校验：必须是 Mach-O；能跑则版本须相符（arm64 runner 上可跑，x86 runner 跳过运行校验）
file "$BIN" | grep -q "Mach-O" || { echo "✗ 不是 Mach-O 可执行文件，疑似下载损坏/被换包"; exit 1; }
chmod +x "$BIN"
got="$(ver_of "$BIN" || true)"
if [ -n "$got" ] && [ "$got" != "$VER" ]; then
  echo "✗ 版本不符：期望 $VER，实际 $got"; exit 1
fi

mkdir -p "$(dirname "$DEST")"
mv -f "$BIN" "$DEST"
echo "✓ sing-box ${VER} → $DEST ($(du -h "$DEST" | cut -f1))"
