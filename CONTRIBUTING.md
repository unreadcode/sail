# Contributing / 贡献指南

**English** | [中文](#中文)

Thanks for contributing to Sail — a native macOS SwiftUI client for sing-box.

## Development environment

- macOS 14.0+, Xcode (latest recommended)
- Apple silicon (arm64). Intel/universal is not supported yet.

## First build

The repo does **not** include the kernel binary or geo rule-sets (both are gitignored). Fetch them before building:

```bash
scripts/fetch-kernel.sh      # downloads the pinned sing-box → Sail/Resources/sing-box
scripts/fetch-georules.sh    # downloads geosite/geoip .srs → Sail/Resources/

# Build (Debug defaults to the host arch)
xcodebuild -project Sail.xcodeproj -scheme Sail -configuration Debug -derivedDataPath build/Debug-dd build
# Or open Sail.xcodeproj in Xcode and run

# One-shot DMG (auto fetch + Release build + package)
scripts/make-dmg.sh
```

> A fresh clone built without running `fetch-kernel.sh` first produces a "no kernel" package.

## Conventions

- **Write commit messages in Chinese**, briefly stating *what + why*.
- **No AI / generator attribution** of any kind (no `Co-Authored-By`, 🤖, "generated with", etc.).
- Keep the deployment target compatible with **macOS 14+**; don't use APIs/libs available only on newer versions.
- Don't commit the kernel binary (`Sail/Resources/sing-box`) or geo rule-sets (`*.srs`).
- Reuse existing helpers (`formatBytes`, `Card`, `Spinner`, `ProtocolStyle`…); match the style of existing pages.
- The project uses a file-system synchronized group — new `Sail/*.swift` files are picked up automatically, no need to edit `project.pbxproj`.

## Verifying

- UI changes: building successfully is enough.
- Kernel / config / networking changes: **test real runtime behavior** (kernel start/stop, connectivity, config correctness via `sing-box check` / `sing-box run`) — don't rely on compilation alone.

## Pull requests

1. Branch off `main`.
2. Self-test, then open a PR filling in the template (changes, verification, checklist).
3. Link related issues (`Closes #123`).

## Reporting issues

Use the [issue templates](https://github.com/unreadcode/sail/issues/new/choose) for bugs and feature requests. **Do not** file security vulnerabilities as public issues — see [SECURITY.md](SECURITY.md).

---

# 中文

[English](#contributing--贡献指南) | **中文**

感谢为 Sail 贡献！Sail 是原生 macOS SwiftUI 的 sing-box 代理客户端。

## 开发环境

- macOS 14.0+、Xcode（建议最新版）
- Apple 芯片（arm64）。Intel/universal 暂未支持。

## 首次构建

仓库**不含**内核二进制与 geo 规则集（均被忽略），构建前先拉取内置：

```bash
scripts/fetch-kernel.sh      # 下载锁定版本 sing-box → Sail/Resources/sing-box
scripts/fetch-georules.sh    # 下载 geosite/geoip .srs → Sail/Resources/

# 构建（Debug 默认本机架构）
xcodebuild -project Sail.xcodeproj -scheme Sail -configuration Debug -derivedDataPath build/Debug-dd build
# 或直接用 Xcode 打开 Sail.xcodeproj 运行

# 一键出 DMG（自动 fetch + 构建 Release + 打包）
scripts/make-dmg.sh
```

> fresh clone 后若没先跑 `fetch-kernel.sh` 直接构建，会打出「无内核」的包。

## 约定

- **commit message 用中文**，简述「做了什么 + 为什么」。
- **不得包含任何 AI / 生成工具署名痕迹**（无 `Co-Authored-By`、🤖、"generated with" 等）。
- 部署目标兼容 **macOS 14+**，不要引入仅高版本可用的 API / 库。
- 不要把内核二进制（`Sail/Resources/sing-box`）、geo 规则集（`*.srs`）提交入库。
- 复用既有助手（`formatBytes`、`Card`、`Spinner`、`ProtocolStyle` 等），风格对齐已有页面。
- 工程用 file-system synchronized group，新建 `Sail/*.swift` 会自动纳入，无需手动改 `project.pbxproj`。

## 验证

- UI 改动：构建通过即可。
- 涉及内核 / 配置 / 网络：请**实测真实运行行为**（内核启停、连接、配置正确性，可用 `sing-box check` / `sing-box run` 实测），不要只靠编译通过。

## 提交 PR

1. 从 `main` 切分支开发。
2. 自测通过后发 PR，按 PR 模板填写改动、验证、检查清单。
3. 关联相关 issue（`Closes #123`）。

## 报告问题

Bug 与功能建议请走 [Issues](https://github.com/unreadcode/sail/issues/new/choose) 的模板。安全漏洞请勿公开提 issue，见 [SECURITY.md](SECURITY.md)。
