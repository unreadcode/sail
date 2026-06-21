<div align="center">

# Sail ⛵️

**A native macOS proxy client for [sing-box](https://github.com/SagerNet/sing-box)**

System proxy / TUN · Subscriptions · Rule-based routing · Live traffic & connections · Latency tests

<p>
  <a href="https://github.com/unreadcode/sail/stargazers"><img src="https://img.shields.io/github/stars/unreadcode/sail?style=flat&logo=github" alt="Stars"></a>
  <a href="https://github.com/unreadcode/sail/network/members"><img src="https://img.shields.io/github/forks/unreadcode/sail?style=flat&logo=github" alt="Forks"></a>
  <a href="https://github.com/unreadcode/sail/releases/latest"><img src="https://img.shields.io/github/v/release/unreadcode/sail?style=flat&logo=apple" alt="Release"></a>
  <a href="https://github.com/unreadcode/sail/releases"><img src="https://img.shields.io/github/downloads/unreadcode/sail/total?style=flat" alt="Downloads"></a>
  <a href="https://github.com/unreadcode/sail/issues"><img src="https://img.shields.io/github/issues/unreadcode/sail?style=flat" alt="Issues"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/unreadcode/sail?style=flat" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-000?style=flat&logo=apple" alt="Platform">
</p>

**English** | [简体中文](README.zh-CN.md)

</div>

---

## Requirements

- macOS 14.0+
- Apple Silicon (arm64). Intel is not supported.

## Installation

1. Download the latest `Sail.dmg` from [Releases](https://github.com/unreadcode/sail/releases), open it, and drag **Sail** into your Applications folder.
2. On first launch, run this once in Terminal to allow it to run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Sail.app
   ```

   Then open it normally by double-clicking (run the command once again after each manual update).

> Sail is ad-hoc signed rather than Apple-notarized, so macOS Gatekeeper blocks downloaded copies by default — the command above lifts that restriction. Alternatively, after being blocked, go to **System Settings → Privacy & Security** and click **Open Anyway**. The source is fully open for review and self-building.

## Build from source

```bash
git clone https://github.com/unreadcode/sail.git
cd sail

# 1) Fetch and embed the sing-box kernel + geo rule-sets
#    (binaries/data are not committed; pulled online on demand)
scripts/fetch-kernel.sh
scripts/fetch-georules.sh

# 2) Build
xcodebuild -project Sail.xcodeproj -scheme Sail -configuration Debug \
  -derivedDataPath build/Debug-dd build

# Or build a DMG in one shot (auto fetch-kernel + fetch-georules → Release → package)
scripts/make-dmg.sh
```

> If you build directly in Xcode without running `fetch-kernel.sh` first, the build **fails with an error** (a guard script phase) rather than silently producing a kernel-less package.

## Auto update

Sail silently checks for the latest GitHub release on launch. When a new version is available, it's flagged in the **tray menu** and under **Settings → About**. Click **Update** for a **one-click download and install** — it downloads, replaces, and relaunches automatically, with no manual steps.

> In-app updates are fetched by the app itself without the quarantine attribute, so **no `xattr` command is needed** (that line is only for your first download from a browser).

## Credits

- Kernel: [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- GEO rule-sets: [sing-geosite](https://github.com/SagerNet/sing-geosite) / [sing-geoip](https://github.com/SagerNet/sing-geoip)

## License

[GPL-3.0](LICENSE) © 2026 Unreadcode

This project and any derivative works must be distributed under GPL-3.0 with source available. The bundled sing-box is invoked as a separate process and retains its own GPL-3.0 license.
