# Nemuri — open core

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

### Free — the manual keep-awake switch

![Nemuri Free panel: manual keep-awake, no agent detection](docs/panel-free.png)

Flip it on, your Mac stays awake with the lid closed. No detection, no automation —
you turn it off yourself. This is what the free app does.

### Pro — detection automation

![Nemuri Pro panel: watching two agents, auto-sleep when they finish](docs/panel-pro.png)

Pro watches your agents, keeps the Mac awake only while they actually work, tells you
when one is waiting for you, and puts the Mac back to sleep once they're done.
**The detection engine behind this panel is closed-source and is not in this repository.**
**The parts of [Nemuri](https://nemuri.app) that run as root, touch your config, or could phone home — published so you can check them yourself.**

Nemuri is a macOS menu bar tool that keeps your Mac awake while an AI agent
(Claude Code, Codex) is working — even with the lid closed — and puts it back to
sleep when the work is done.

To do that, Nemuri asks you to approve a **root helper**. That is a big ask. This
repository exists so you don't have to take our word for it.

---

## 🔍 What's in here (and what isn't)

**This repository is not the whole app.** It is the trust-critical subset.

| In this repo | Why it's here |
|---|---|
| `Sources/Helper` | The **root LaunchDaemon**. The only component running as root. |
| `Sources/Shared` | The XPC contract between app and helper — the helper's entire attack surface. |
| `Sources/Core` | `pmset`/sentinel/battery primitives (the never-stuck guarantees), the installer that edits your agent config, and the local IPC protocol. |
| `Sources/HookBridge` | `aw-hook` / `aw-codex` — the tiny binaries that get written into your `~/.claude/settings.json` and `~/.codex/config.toml`. |

**Not in this repo:** the detection engine (process/session/rollout heuristics),
the state machine, the offline license verification, and the SwiftUI app. Those
are closed-source — they're what Nemuri Pro sells.

So be precise about what this buys you: you can audit **what runs as root**, **what
gets written into your config**, and **whether anything opens a socket to the
internet**. You cannot build the full Nemuri app from this repository, and the
binary in the signed DMG is not built from this source tree alone.

That is a real limitation. We'd rather state it than blur it.

---

## ✅ What you can verify here

- **Minimal root surface.** The helper exposes exactly three XPC methods —
  `setSleepDisabled(Bool)`, `currentState()`, `ping()` — and shells out to
  `/usr/bin/pmset`. Nothing else. No arbitrary command execution, no file writes
  outside its sentinel, no network.
- **Never stuck asleep-disabled.** If the app crashes, is killed, or is
  uninstalled, `pmset disablesleep` must return to `0`. The watchdog, the
  60-second sentinel self-check, and the boot-time recovery are all in
  `Sources/Helper/main.swift`.
- **Zero network.** Grep this tree for `URLSession`, `Network`, `socket(`,
  `connect(`. The only sockets are `AF_UNIX` (local IPC). The helper never talks
  to the internet, and neither does license activation — Nemuri Pro is unlocked
  by an offline Ed25519-signed file, verified locally. It works in airplane mode.
- **Your config is backed up and reversible.** `Sources/Core/Installer.swift` is
  the code that edits `~/.claude/settings.json` and `~/.codex/config.toml`. It
  backs up before writing and can fully restore.

## 🛠 Build and audit it yourself

```bash
swift build   # builds the helper, the XPC contract, the hook bridges, and the core
```

Requires macOS 13+ and Swift 5.9+. This tree builds standalone — no closed-source
dependency, no network access at build time.

To read the root component first, start at `Sources/Helper/main.swift` (it's short
on purpose) and `Sources/Shared/AwakeShared.swift` (the XPC requirement string
that decides who is allowed to command the helper).

## 📦 Getting Nemuri

Releases (signed, notarized DMG) are published on this repository's
[Releases](https://github.com/syfssb/nemuri/releases) page, and via Homebrew once
v1.0 ships. The app is free to use for the manual keep-awake switch; the
detection automation is a one-time paid upgrade. See <https://nemuri.app>.

## 🤝 Contributing

Issues and PRs on the code in this repository are welcome — especially anything
touching the root helper, the recovery paths, or the config installer. If you
find a way to make the helper do something it shouldn't, please report it: open a
GitHub security advisory on this repo rather than a public issue.

Contributions are accepted under the Apache License 2.0 (see `LICENSE`).

## 📄 License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The closed-source parts of Nemuri (detection engine, app, licensing) are not
covered by this license and are not distributed here.
