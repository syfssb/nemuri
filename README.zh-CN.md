# Nemuri — open core

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

**[Nemuri](https://nemuri.app/zh/) 里以 root 运行、会动你配置、有可能偷偷联网的那些部分——全部公开出来，好让你自己去查。**

Nemuri 是一款 macOS 菜单栏工具：AI agent（Claude Code、Codex）干活期间保持你的 Mac 唤醒——合着盖也照跑——活干完了再让它回去休眠。

要做到这件事，Nemuri 需要你批准一个 **root helper**。这个要求不小。这个仓库存在的意义，就是让你不必只能选择相信我们。

---

## 🔍 这里有什么（以及没有什么）

**这个仓库不是完整的 app**，它是信任攸关的那个子集。

| 本仓库包含 | 为什么放在这里 |
|---|---|
| `Sources/Helper` | **root LaunchDaemon**。唯一以 root 运行的组件。 |
| `Sources/Shared` | app 与 helper 之间的 XPC 契约——helper 的全部攻击面。 |
| `Sources/Core` | `pmset`／哨兵／电量原语（永不卡死保险）、会改写你 agent 配置的安装器，以及本地 IPC 协议。 |
| `Sources/HookBridge` | `aw-hook` / `aw-codex`——会被写进你 `~/.claude/settings.json` 和 `~/.codex/config.toml` 的那两个极小的二进制。 |

**不在这个仓库里的：** 检测引擎（进程／会话／rollout 启发式）、状态机、离线许可证验签，以及 SwiftUI app。这些都是闭源的——它们正是 Nemuri Pro 卖的东西。

**Free 和 Pro 跑的是同一份代码，就是这个仓库里的这份。** root helper、`pmset`／哨兵／电量原语、配置安装器、hook 桥——两档共用一份，没有第二份。你买不买 Pro，需要你信任的那部分代码都公开在这里。

所以请准确理解这份公开究竟给了你什么：你可以审计 **什么东西以 root 运行**、**什么东西被写进你的配置**，以及 **有没有任何代码开了通往互联网的 socket**。你没法用这个仓库构建出完整的 Nemuri app，签名 DMG 里的那个二进制，也不是仅从这棵源码树构建出来的。

这是一个真实的局限。我们宁可把它说清楚，也不含糊过去。

---

## ✅ 你在这里能验证什么

- **root 攻击面最小。** helper 恰好只暴露三个 XPC 方法——`setSleepDisabled(Bool)`、`currentState()`、`ping()`——然后去调 `/usr/bin/pmset`。没有别的了。不执行任意命令，不在哨兵之外写任何文件，不联网。
- **永不卡死在禁休眠状态。** 无论 app 崩溃、被杀掉，还是被卸载，`pmset disablesleep` 都必须回到 `0`。看门狗、60 秒哨兵自检、开机时的恢复，全都在 `Sources/Helper/main.swift` 里。
- **零网络。** 在这棵树里 grep 一下 `URLSession`、`Network`、`socket(`、`connect(`。唯一的 socket 是 `AF_UNIX`（本地 IPC）。helper 从不与互联网通信，许可证激活也一样——Nemuri Pro 由一份离线的 Ed25519 签名文件解锁，本地验签。飞行模式下也能用。
- **你的配置有备份、可撤销。** `Sources/Core/Installer.swift` 就是那段会改写 `~/.claude/settings.json` 和 `~/.codex/config.toml` 的代码。它写入前先备份，而且可以完整还原。

## 🛠 自己构建、自己审计

```bash
swift build   # 构建 root helper、XPC 契约、core 原语，以及两个 hook 桥
```

需要 macOS 13+ 与 Swift 5.9+。这棵树可以独立构建——没有闭源依赖，没有任何第三方包，构建过程也不联网。

想先读那个 root 组件，就从 `Sources/Helper/main.swift`（它是刻意写短的）和 `Sources/Shared/AwakeShared.swift`（那串决定谁有资格给 helper 下命令的 XPC requirement 字符串）开始。

## 📦 获取 Nemuri

Nemuri 以签名并 notarized 的 DMG 发布，发布在本仓库的 [Releases](https://github.com/syfssb/nemuri/releases) 页面。**v1.0 还没发布**——在本仓库点 Watch → Releases，发布时 GitHub 会通知你。完整产品说明见 <https://nemuri.app/zh/>。

### Free —— 手动保持唤醒

![Nemuri Free 面板：Agent Mode 已开，没有会话列表，agent 检测标为 Pro 功能](docs/panel-free.png)

打开它，合着盖也不睡，不用外接显示器。免费版就到这里：没有检测，也没有自动化。它会一直保持唤醒，直到你自己把它关掉；会话列表永远是空的——面板会如实告诉你这一点，而不是假装有。

### Pro —— 检测自动化

![Nemuri Pro 面板：正在看护两个 agent，一个在等你确认、一个在跑，跑完恢复休眠](docs/panel-pro.png)

Pro **只在你的 agent 真的在干活时**才保持唤醒，所以你可以一直开着不用管它。它会告诉你哪个 agent 在跑、哪个在等你确认，并在最后一个跑完之后把休眠恢复回来。¥133 买断，一份 license 装你所有的 Mac。**这块面板背后的检测引擎是闭源的，不在本仓库里。**

**两档都有：** 永不卡死的四条恢复路径、电量保护、开机自启，以及同样的更新。更新是手动的，这是故意的：一个定时替你查更新的程序，本身就是在自己联网——而这恰恰是这个仓库要排除的事。想更新时去「设置 → 关于」里点「检查更新…」，那一次、也只有那一次，Nemuri 才碰网络。Free 也一样，走同一条通道。

## 🤝 参与贡献

欢迎针对本仓库的代码提 issue 和 PR——尤其是碰到 root helper、恢复路径或配置安装器的部分。如果你找到了让 helper 做出它不该做的事的办法，请告诉我们：请在本仓库开一个 GitHub security advisory，而不是公开 issue。

贡献以 Apache License 2.0 授权接受（见 `LICENSE`）。

## 📄 许可证

Apache License 2.0——见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。

Nemuri 的闭源部分（检测引擎、app、许可证）不在本许可证覆盖范围内，也不在此分发。
