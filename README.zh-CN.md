# Nemuri

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

**Nemuri 是一款 macOS 菜单栏工具：Claude Code 或 Codex 在干活时，让你的 Mac 保持唤醒——合着盖也照跑——活干完了再让它回去睡。**

丢给 agent 一个长任务，合上笔记本走开。任务接着跑，而不是盖子一合就冻住。最后一个 agent 跑完，Mac 自己回去睡——省得合着盖的 MacBook 为一个一小时前就结束的任务，在包里白白发热。

![Nemuri 菜单栏面板：正在跟踪两个 agent——一个在跑、一个在等你——跑完自动恢复休眠](docs/panel-pro.png)

## 下载

- **DMG** —— [下载最新的签名并公证版本](https://github.com/syfssb/nemuri/releases/latest)（macOS 13+，Apple Silicon 与 Intel）
- **Homebrew** —— `brew install --cask syfssb/nemuri/nemuri`

不上 Mac App Store：沙盒禁止真正合盖模式所需的那个特权 helper。完整产品说明见 <https://nemuri.app/zh/>。

---

## 你能得到什么

- **合上盖、不接外接显示器，照样跑。** 真正的合盖模式，靠固件级的 `disablesleep` 开关，不只是 `caffeinate`。
- **分得清「在跑」「在等你」「跑完了」。** agent 真的在干活时保持唤醒，一停下等你输入就通知你，最后一个跑完几分钟后恢复休眠。*(Pro)*
- **会话面板。** 哪个 agent、哪个项目、跑了多久。*(Pro)*
- **绝不让 Mac 卡在唤醒状态。** 崩溃、重启、退出、卸载——`disablesleep` 总会回到 `0`。四条恢复路径，每条都有自动化测试。
- **安静。** 无账号、零遥测、无后台联网。

## Free vs Pro

一次买断，不是订阅。开关永久免费；读懂你 agent 的那部分，一次解锁。

| | Free | Pro —— ¥133 / $19，一次买断 |
|---|---|---|
| 合盖保持唤醒 | ✅ | ✅ |
| 永不卡死看门狗（四条恢复路径） | ✅ | ✅ |
| 电量保护（低于阈值放行休眠） | ✅ | ✅ |
| 开机自启 | ✅ | ✅ |
| 最后一个 agent 跑完自动休眠 | | ✅ |
| agent 停下等你输入时提醒 | | ✅ |
| 会话面板：agent、项目、运行时长、状态 | | ✅ |
| 跨终端多 agent 跟踪 | | ✅ |

Free 是一个手动的保持唤醒开关：开着就一直醒，所以跑完记得关掉。Pro 替你盯着 agent，这件事它自己搞定。

**一份 license，最多 3 台 Mac。** 新购买会在线激活一次——由你触发、把一台 Mac 绑定到你的 license——之后完全离线运行。到上限了？随时在自助门户 [pro.nemuri.app/manage](https://pro.nemuri.app/manage) 解绑一台。**2026-07-23** 之前购买的 license 保持原有条款：不限台数、完全离线、根本没有激活联网这一步。

Free（左）是开关、电量保护和看门狗——会话区永远就是这一句。Pro（右）显示谁在跑、谁在等你、还有多久睡。

| Free | Pro |
|---|---|
| ![Nemuri Free 面板：Agent Mode 已开，没有会话列表，agent 检测标为 Pro 功能](docs/panel-free.png) | ![Nemuri Pro 面板：正在看护两个 agent，一个在等你、一个在跑](docs/panel-pro.png) |

---

## 这个仓库为什么开源

Nemuri 要你批准一个 **root helper**——一个以 root 运行、负责翻动系统 `disablesleep` 开关的后台进程。这个要求不小。这个仓库就是 Nemuri 里信任攸关的那部分，公开出来，好让你自己读，而不是只能选择相信我们。

**Free 和 Pro 跑的是这个仓库里的同一份代码。** 你买不买 Pro，需要你信任的那部分都公开在这里。

| 本仓库包含 | 它是什么 |
|---|---|
| `Sources/Helper` | root LaunchDaemon——唯一以 root 运行的组件。 |
| `Sources/Shared` | app 与 helper 之间的 XPC 契约——helper 的全部攻击面。 |
| `Sources/Core` | `pmset`／哨兵／电量原语（永不卡死保险）、会改写你 agent 配置的安装器，以及本地 IPC 协议。 |
| `Sources/HookBridge` | `aw-hook` / `aw-codex`——写进你 `~/.claude/settings.json` 和 `~/.codex/config.toml` 的那两个极小的二进制。 |

**不在这里的：** 检测引擎、状态机、离线许可证验签，以及 SwiftUI app。这些是闭源的——正是 Nemuri Pro 卖的东西。你没法用这棵源码树构建出完整的 app，DMG 里的二进制也不是仅从这棵树构建的。这是一个真实的局限，我们把它说清楚，不含糊过去。

## 你能验证什么

- **root 攻击面最小。** helper 只暴露三个 XPC 方法——`setSleepDisabled(Bool)`、`currentState()`、`ping()`——然后去调 `/usr/bin/pmset`。不执行任意命令，不在哨兵之外写任何文件，不联网。
- **永不卡死。** app 崩溃、被杀、被卸载，`pmset disablesleep` 都会回到 `0`。看门狗、60 秒哨兵自检、开机恢复，全在 `Sources/Helper/main.swift` 里。
- **没有隐藏的网络。** 在这棵树里 grep `URLSession`、`Network`、`socket(`、`connect(`——唯一的 socket 是 `AF_UNIX`（本地 IPC），root helper 从不碰互联网。
- **配置有备份、可撤销。** `Sources/Core/Installer.swift` 会改写 `~/.claude/settings.json` 和 `~/.codex/config.toml`。它写入前先备份，可以完整还原。

## 隐私

Nemuri 日常运行零网络。它只在你触发时才碰互联网：点「检查更新…」时的一次更新查询，以及买 Pro 时那一次把这台 Mac 绑定到 license 的激活。之后许可证校验全程本地进行，对着内嵌的 Ed25519 公钥——没有遥测、没有后台回连。2026-07-23 之前购买的 license 完全离线激活，连这一次调用都没有。

## 自己构建

```bash
swift build   # 构建 root helper、XPC 契约、core 原语，以及两个 hook 桥
```

需要 macOS 13+ 与 Swift 5.9+。这棵树可以独立构建——没有闭源依赖，没有第三方包，构建过程也不联网。想先读那个 root 组件，就从 `Sources/Helper/main.swift`（刻意写短）和 `Sources/Shared/AwakeShared.swift`（决定谁有资格给 helper 下命令的那串 XPC requirement）开始。

## 参与贡献

欢迎针对本仓库的代码提 issue 和 PR——尤其是碰到 root helper、恢复路径或配置安装器的部分。如果你找到了让 helper 做出它不该做的事的办法，请在本仓库开一个 GitHub security advisory，而不是公开 issue。

贡献以 Apache License 2.0 授权接受（见 `LICENSE`）。

## 许可证

Apache License 2.0——见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。

Nemuri 的闭源部分（检测引擎、app、许可证）不在本许可证覆盖范围内，也不在此分发。
