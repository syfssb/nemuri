# Nemuri — open core

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

### Free —— 手動保持清醒

![Nemuri Free 面板：手動保持清醒，無 agent 偵測](docs/panel-free.png)

打開它，闔蓋也不睡。沒有偵測、沒有自動化——需要你自己關掉。這就是免費版做的事。

### Pro —— 偵測自動化

![Nemuri Pro 面板：正在看護兩個 agent，跑完自動睡](docs/panel-pro.png)

Pro 看護你的 agent：只在它們真正幹活時保持清醒，有 agent 等你確認時通知你，跑完了把 Mac 放回去睡。
**這塊面板背後的偵測引擎是閉源的，不在本 repo 裡。**
**[Nemuri](https://nemuri.app/zh-hant/) 之中以 root 執行、會動到你設定檔、有可能偷偷連網的那些部分——全部公開出來，讓你可以自己查證。**

Nemuri 是一款 macOS 選單列工具：AI agent（Claude Code、Codex）在工作時讓你的 Mac 保持清醒——闔上筆電也照跑——工作跑完再放它回去睡。

要做到這件事，Nemuri 得請你核准一個 **root 助手**。這個要求不小。這個 repo 存在的意義，就是讓你不必只能選擇相信我們。

---

## 🔍 這裡有什麼（以及沒有什麼）

**這個 repo 不是完整的 app**，它是攸關信任的那個子集。

| 本 repo 收錄 | 為什麼放在這裡 |
|---|---|
| `Sources/Helper` | **root LaunchDaemon**。唯一以 root 執行的元件。 |
| `Sources/Shared` | app 與助手之間的 XPC 契約——助手的全部攻擊面。 |
| `Sources/Core` | `pmset`／哨兵／電量原語（永不卡死的保證）、會改寫你 agent 設定的安裝器，以及本機 IPC 協定。 |
| `Sources/HookBridge` | `aw-hook` / `aw-codex`——會被寫進你 `~/.claude/settings.json` 與 `~/.codex/config.toml` 的那兩支極小的二進位檔。 |

**不在這個 repo 裡的：** 偵測引擎（處理程序／session／rollout 啟發式）、狀態機、離線授權驗簽，以及 SwiftUI app。這些都是閉源的——它們正是 Nemuri Pro 賣的東西。

所以請準確理解這份公開究竟給了你什麼：你可以稽核 **什麼東西以 root 執行**、**什麼東西被寫進你的設定**，以及 **有沒有任何程式碼開了通往網際網路的 socket**。你沒辦法用這個 repo 建置出完整的 Nemuri app，簽章 DMG 裡的那支二進位檔，也不是只從這棵原始碼樹建出來的。

這是一個真實的限制。與其模糊帶過，我們寧可講清楚。

---

## ✅ 你可以在這裡驗證什麼

- **root 攻擊面最小。** 助手剛好只公開三個 XPC 方法——`setSleepDisabled(Bool)`、`currentState()`、`ping()`——然後去呼叫 `/usr/bin/pmset`。沒有別的了。不執行任意指令，不在哨兵以外寫任何檔案，不連網。
- **永不卡死在封鎖睡眠狀態。** 不管 app 當掉、被 kill，還是被解除安裝，`pmset disablesleep` 都必須回到 `0`。看門狗、60 秒哨兵自我檢查、開機時的復原，全都在 `Sources/Helper/main.swift` 裡。
- **零網路。** 在這棵樹裡 grep 一下 `URLSession`、`Network`、`socket(`、`connect(`。唯一的 socket 是 `AF_UNIX`（本機 IPC）。助手從不與網際網路對話，授權啟用也一樣——Nemuri Pro 是由一份離線的 Ed25519 簽章檔案解鎖，在本機驗簽。飛航模式下也能用。
- **你的設定有備份、可還原。** `Sources/Core/Installer.swift` 就是那段會改寫 `~/.claude/settings.json` 與 `~/.codex/config.toml` 的程式碼。它寫入前先備份，而且可以完整還原。

## 🛠 自己建置、自己稽核

```bash
swift build            # 建置助手、hook bridge 與 core
```

需要 macOS 13+ 與 Swift 5.9+。這棵樹可以獨立建置——沒有閉源相依套件，建置過程也不連網。

想先讀那個 root 元件，就從 `Sources/Helper/main.swift`（它是刻意寫短的）與 `Sources/Shared/AwakeShared.swift`（那串決定誰有資格對助手下令的 XPC requirement 字串）開始。

## 📦 取得 Nemuri

正式版本（經過簽章與公證的 DMG）發布在本 repo 的 [Releases](https://github.com/syfssb/nemuri/releases) 頁面；v1.0 推出之後也會提供 Homebrew 安裝。手動保持清醒的開關可以免費使用；偵測自動化是一次買斷的付費升級。詳見 <https://nemuri.app/zh-hant/>。

## 🤝 參與貢獻

歡迎針對本 repo 的程式碼提出 issue 與 PR——尤其是碰到 root 助手、復原路徑或設定安裝器的部分。如果你找到辦法讓助手做出它不該做的事，請告訴我們：請在本 repo 開一則 GitHub security advisory，而不是公開 issue。

貢獻以 Apache License 2.0 授權接受（見 `LICENSE`）。

## 📄 授權

Apache License 2.0——見 [`LICENSE`](LICENSE) 與 [`NOTICE`](NOTICE)。

Nemuri 的閉源部分（偵測引擎、app、授權機制）不在本授權的涵蓋範圍內，也不在此散布。

---

完整說明見 <https://nemuri.app/zh-hant/>。
