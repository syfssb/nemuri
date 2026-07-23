# Nemuri

[English](README.md) · [简体中文](README.zh-CN.md) · **繁體中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

**Nemuri 是一款 macOS 選單列 app：Claude Code 或 Codex 在工作時，讓你的 Mac 保持清醒——闔上筆電也照跑——工作跑完再放它回去睡。**

丟給 agent 一個長任務，闔上筆電就走。任務會照跑，而不是在蓋子闔上那一刻凍結。等最後一個 agent 跑完，Mac 自己回去睡——闔上的 MacBook 不會為了一個一小時前就結束的任務，還在你背包裡發燙。

![Nemuri 選單列面板：看護兩個 agent，一個執行中、一個在等你，跑完自動入睡](docs/panel-pro.png)

## 下載

- **DMG**——[下載最新的簽章、公證版本](https://github.com/syfssb/nemuri/releases/latest)（macOS 13+，Apple Silicon & Intel）
- **Homebrew**——`brew install --cask syfssb/nemuri/nemuri`

沒上 Mac App Store：沙箱禁止真正闔蓋模式所需的特權助手。完整產品介紹見 <https://nemuri.app/zh-hant/>。

---

## 你會得到什麼

- **闔上筆電、不接外接螢幕，照樣跑。** 真正的闔蓋模式，靠韌體層級的 `disablesleep` 旗標，而不只是 `caffeinate`。
- **分得清在跑、在等你、跑完了。** agent 真的在做事時保持清醒，一停下來等你輸入就立刻提醒你，最後一個跑完幾分鐘後自己還原睡眠。*(Pro)*
- **Session 面板。** 哪個 agent、哪個專案、跑了多久。*(Pro)*
- **絕不卡死在醒著。** 當掉、重開機、結束、解除安裝——`disablesleep` 一律回到 `0`。四條復原路徑，每條都有自動化測試。
- **安靜。** 免帳號、零遙測、無背景連網。

## Free 與 Pro

買斷制，不是訂閱。開關永久免費；讀你 agent 的那一半是一次性解鎖。

| | Free | Pro——$19 / ¥133 買斷 |
|---|---|---|
| 闔上筆電保持清醒 | ✅ | ✅ |
| 永不卡死看門狗（四條復原路徑） | ✅ | ✅ |
| 電量保護（低於門檻放行睡眠） | ✅ | ✅ |
| 登入時啟動 | ✅ | ✅ |
| 最後一個 agent 跑完自動入睡 | | ✅ |
| agent 等你輸入時提醒 | | ✅ |
| Session 面板：agent、專案、執行時間、狀態 | | ✅ |
| 跨終端機的多 agent 追蹤 | | ✅ |

Free 是一個手動保持清醒的開關：開著就一直醒著，所以跑完記得關掉。Pro 會替你盯著 agent，把這件事顧好。

**一份 license，最多 3 台 Mac。** 新購買會線上啟用一次——由你觸發、把一台 Mac 綁定到你的 license——之後完全離線執行。到上限了？隨時到自助門戶 [pro.nemuri.app/manage](https://pro.nemuri.app/manage) 解綁一台。**2026-07-23** 之前購買的 license 保持原有條款：不限台數、完全離線、沒有任何啟用連網。

Free（左）是開關、電量保護與看門狗——session 區永遠就是這個樣子。Pro（右）會顯示誰在跑、誰在等你、還有多久入睡。

| Free | Pro |
|---|---|
| ![Nemuri Free 面板：Agent Mode 已開，沒有 session 清單，agent 偵測標示為 Pro 功能](docs/panel-free.png) | ![Nemuri Pro 面板：看護兩個 agent，一個在等你、一個在跑](docs/panel-pro.png) |

---

## 為什麼這個 repo 要公開

Nemuri 會請你核准一個 **root 助手**——一個以 root 執行、會翻動系統 `disablesleep` 旗標的背景程序。這個要求不小。這個 repo 就是 Nemuri 中攸關信任的那一部分，公開出來讓你可以自己讀，而不是只能相信我們。

**Free 與 Pro 跑的是這個 repo 裡的同一份程式碼。** 不管你買不買 Pro，需要你信任的那一部分，就公開在這裡。

| 本 repo 收錄 | 這是什麼 |
|---|---|
| `Sources/Helper` | root LaunchDaemon——唯一以 root 執行的元件。 |
| `Sources/Shared` | app 與助手之間的 XPC 契約——助手的全部攻擊面。 |
| `Sources/Core` | `pmset`／哨兵／電量原語（永不卡死的保證）、會改寫你 agent 設定的安裝器，以及本機 IPC 協定。 |
| `Sources/HookBridge` | `aw-hook` / `aw-codex`——會被寫進你 `~/.claude/settings.json` 與 `~/.codex/config.toml` 的那兩支極小的二進位檔。 |

**不在這裡的：** 偵測引擎、狀態機、離線授權驗簽，以及 SwiftUI app。這些都是閉源的——正是 Nemuri Pro 賣的東西。你沒辦法用這棵原始碼樹建出完整的 app，DMG 裡的那支二進位檔也不是只從這份原始碼建出來的。這是一個真實的限制，我們把它講清楚，而不是模糊帶過。

## 你可以驗證什麼

- **root 攻擊面最小。** 助手只公開三個 XPC 方法——`setSleepDisabled(Bool)`、`currentState()`、`ping()`——然後去呼叫 `/usr/bin/pmset`。不執行任意指令，不在哨兵以外寫任何檔案，不連網。
- **永不卡死。** app 當掉、被 kill 或被解除安裝時，`pmset disablesleep` 都會回到 `0`。看門狗、60 秒哨兵自我檢查、開機時的復原，全都在 `Sources/Helper/main.swift` 裡。
- **沒有隱藏的網路。** 在這棵樹裡 grep 一下 `URLSession`、`Network`、`socket(`、`connect(`——唯一的 socket 是 `AF_UNIX`（本機 IPC），root 助手從不碰網際網路。
- **設定有備份、可還原。** `Sources/Core/Installer.swift` 會改寫 `~/.claude/settings.json` 與 `~/.codex/config.toml`。它寫入前先備份，而且可以完整還原。

## 隱私

Nemuri 日常運行零網路。它只在你觸發時才連網際網路：按下「檢查更新…」時的一次更新查詢，以及你購買 Pro 時把這台 Mac 綁定到 license 的一次啟用。之後授權驗證全程在本機、對著內嵌的 Ed25519 公鑰進行——沒有遙測，沒有背景回連。裝置綁定上線之前購買的 license 完全離線啟用，一次網路呼叫都沒有。

## 自己建置

```bash
swift build   # root 助手、XPC 契約、core 原語，以及兩支 hook bridge
```

需要 macOS 13+ 與 Swift 5.9+。這棵樹可以獨立建置——沒有閉源相依套件，沒有第三方套件，建置過程也不連網。想先讀 root 元件，就從 `Sources/Helper/main.swift`（刻意寫短）與 `Sources/Shared/AwakeShared.swift`（決定誰有資格對助手下令的 XPC requirement）開始。

## 參與貢獻

歡迎針對本 repo 的程式碼提出 issue 與 PR——尤其是碰到 root 助手、復原路徑或設定安裝器的部分。找到辦法讓助手做出它不該做的事？請在本 repo 開一則 GitHub security advisory，而不是公開 issue。

貢獻以 Apache License 2.0 授權接受（見 `LICENSE`）。

## 授權

Apache License 2.0——見 [`LICENSE`](LICENSE) 與 [`NOTICE`](NOTICE)。

Nemuri 的閉源部分（偵測引擎、app、授權機制）不在本授權涵蓋範圍內，也不在此散布。
