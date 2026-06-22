# Security Policy / 安全策略

**English** | [中文](#中文)

## Supported versions

Security fixes are provided for the **latest released version** only. Please upgrade to the latest version before reporting.

## Reporting a vulnerability

**Do not report security vulnerabilities through public issues.**

Use one of these private channels instead:

- GitHub repo **Security → Report a vulnerability** (private security advisory)
- Email: i@unreadcode.com

Please include: affected version, reproduction steps, and impact (potential harm). We'll confirm and fix as soon as possible, and disclose publicly only after a fix ships.

## Sensitive surfaces

Sail involves several privileged / network-sensitive components — reports about these are especially welcome:

- **Privileged helper** (LaunchDaemon running sing-box as root, replacing setuid) — privilege escalation, command injection, binary replacement.
- **System proxy / TUN** — traffic bypass, leaks, DNS leaks.
- **clash_api** — bypassing the local API auth (random secret + Bearer), or other local processes reading/controlling it.
- **Kernel / geo downloads** — bypassing source/integrity verification (MITM package swap).

---

# 中文

[English](#security-policy--安全策略) | **中文**

## 支持的版本

仅对**最新发布版本**提供安全修复。请先升级到最新版再反馈。

## 报告漏洞

**请勿在公开 issue 中提交安全漏洞。**

请通过以下任一私密渠道报告：

- GitHub 仓库 **Security → Report a vulnerability**（私密安全公告）
- 邮件：i@unreadcode.com

请尽量附上：受影响版本、复现步骤、影响范围（可能的危害）。我会尽快确认并修复，修复发布后再公开披露。

## 需要重点关注的面

Sail 涉及若干特权 / 网络敏感组件，相关问题尤其欢迎反馈：

- **特权 helper**（LaunchDaemon，以 root 运行 sing-box，替代 setuid）——提权、命令注入、二进制被替换等。
- **系统代理 / TUN**——流量被旁路、泄漏、DNS 泄漏。
- **clash_api**——本地接口鉴权（随机 secret + Bearer）被绕过、被本机其它进程读取或控制。
- **内核 / geo 下载**——下载来源、完整性校验被绕过（中间人换包）。
