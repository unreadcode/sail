#!/usr/bin/env bash
# 下载 sing-box geo 规则集（.srs）内置到 Sail/Resources/。
# 与内核二进制一样不入库（被 .gitignore 忽略）——本地打包 / CI 构建前调用本脚本就位即可。
# 规则集取自 SagerNet 的 rule-set 滚动分支（无版本号，拉最新）；缺失时 app 运行期会退回远程规则集。
# 用法：scripts/fetch-georules.sh [--force]   默认幂等（已有合法 SRS 则跳过）；--force 强制刷新。
set -euo pipefail
cd "$(dirname "$0")/.."   # 仓库根目录

FORCE="${1:-}"
DESTDIR="Sail/Resources"
FILES=(geosite-cn.srs geoip-cn.srs geosite-category-ads-all.srs)

# 文件名 → 下载地址（geosite 与 geoip 分属两个仓库）
geo_url() {
  case "$1" in
    geosite-*) echo "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/$1" ;;
    geoip-*)   echo "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/$1" ;;
    *) return 1 ;;
  esac
}

# 完整性校验：sing-box .srs 以魔数 "SRS"(53 52 53) 开头且体积 > 64B；
# 挡住限速 HTML / 404 错误页 / 半截下载。
is_valid_srs() {
  [ -f "$1" ] || return 1
  [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = "535253" ] || return 1
  [ "$(stat -f%z "$1")" -gt 64 ] || return 1
}

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
mkdir -p "$DESTDIR"

for name in "${FILES[@]}"; do
  dest="$DESTDIR/$name"
  if [ "$FORCE" != "--force" ] && is_valid_srs "$dest"; then
    echo "✓ $name 已就位，跳过"
    continue
  fi
  url="$(geo_url "$name")"
  echo "▶ 下载 $name … ($url)"
  tmp="$TMPD/$name"
  curl -fL --retry 3 -o "$tmp" "$url"
  is_valid_srs "$tmp" || { echo "✗ $name 非合法 SRS（魔数/体积不符），疑似下载损坏/被换包"; exit 1; }
  mv -f "$tmp" "$dest"
  echo "✓ $name → $dest ($(du -h "$dest" | cut -f1))"
done
