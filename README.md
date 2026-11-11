![Threadlight 图标](Assets/app-icon.png)

# Threadlight · 对话灯｜Codex / Claude Code 菜单栏状态监控

在 macOS 菜单栏，随时查看 Codex 和 Claude Code 对话的运行状态。

A lightweight macOS menu bar monitor for Codex and Claude Code sessions. Track running tasks and unread completions, with a pinnable task list and optional launch at login. Runs locally without network requests or telemetry.

**[下载 DMG（Apple 芯片）](https://github.com/shawnweasley/threadlight-codex-claude/releases/download/v0.1.1/Threadlight-0.1.1-macOS-arm64.dmg)** · [版本说明](https://github.com/shawnweasley/threadlight-codex-claude/releases/tag/v0.1.1)

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
[![MIT License](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

## 预览

**菜单栏**

![菜单栏截图](Assets/menu-bar.png)

**固定列表**

![固定任务列表截图](Assets/task-list.png)

*菜单栏为实际截图，列表使用演示任务。*

## 功能

- **一眼看状态**：旋转圆环表示运行中，绿色勾号表示已结束。
- **独立分批编号**：Codex 用 `1 2 3`，Claude Code 用 `α β γ`；各自列表清空后重新从 `1` / `α` 开始，仍有旧对话时继续递增。
- **保留完成未读**：查看后移出列表，同一批次内再次运行时沿用原编号。
- **统计独立对话**：Codex 包括手动创建和由代理创建的独立桌面对话，不包含内部子代理；显示运行中及完成未读的对话，不是所有打开的聊天数量。
- **可固定的置顶列表**：支持拖动、调整宽度，窄窗口自动隐藏右侧状态文字。
- **可选自启动**：在菜单栏下拉菜单勾选“允许开机自启动”，登录 Mac 时自动启动；取消勾选即可关闭。
- **本地只读**：无网络请求、无遥测，不修改 Codex 或 Claude 的设置。

Claude 仅支持桌面端 **Code** 会话。

## 安装

需要 **macOS 13+**。当前 DMG 为 **Apple 芯片版**。

1. [下载 DMG 安装包](https://github.com/shawnweasley/threadlight-codex-claude/releases/download/v0.1.1/Threadlight-0.1.1-macOS-arm64.dmg)，将应用拖入「应用程序」。
2. 启动「对话灯」，从菜单栏查看任务，或选择「固定列表」。

当前为预览版，采用本地签名，尚未经过 Apple 公证。

## 开发

需要 Swift 6 / Xcode 16+，无第三方 Swift 包依赖。

```bash
swift test
./scripts/build-dmg.sh
```

生成的安装包位于 `dist/`。更多信息见[贡献指南](CONTRIBUTING.md)和[隐私说明](docs/PRIVACY.md)。

## 许可与致谢

代码采用 [MIT License](LICENSE)。感谢 [codex-status-bar](https://github.com/yuriipalam/codex-status-bar) 带来的最初灵感；实现来源见[说明](docs/PROVENANCE.md)。Codex 图标为第三方资源，见[声明](THIRD_PARTY_NOTICES.md)。本项目与 OpenAI、Anthropic 无官方关联。

认可并支持 [LINUX DO](https://linux.do/) 社区：真诚、友善、团结、专业。
