# Nemuri

**English** · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

**Nemuri is a macOS menu bar app that keeps your Mac awake while Claude Code or Codex is working — even with the lid closed — and lets it sleep again once the run is done.**

Give an agent a long task, close the laptop, and walk away. The run keeps going instead of freezing the second the lid shuts. When the last agent finishes, your Mac goes back to sleep on its own — so a closed MacBook isn't cooking in your bag on a job that ended an hour ago.

![Nemuri menu bar panel: two agents tracked — one running, one waiting for you — with auto-sleep when they finish](docs/panel-pro.png)

## Download

- **DMG** — [download the latest signed, notarized release](https://github.com/syfssb/nemuri/releases/latest) (macOS 13+, Apple Silicon & Intel)
- **Homebrew** — `brew install --cask syfssb/nemuri/nemuri`

Not on the Mac App Store — the sandbox forbids the privileged helper that real clamshell mode needs. Full product tour: <https://nemuri.app>.

---

## What you get

- **Lid closed, no external display, keeps running.** Real clamshell mode via the firmware-level `disablesleep` flag, not just `caffeinate`.
- **Knows working from waiting from done.** Stays awake while an agent is actually working, alerts you the moment one stops for your input, and restores sleep a few minutes after the last one finishes. *(Pro)*
- **Session panel.** Which agent, which project, how long it's been running. *(Pro)*
- **Never leaves your Mac stuck awake.** Crash, reboot, quit, uninstall — `disablesleep` always returns to `0`. Four recovery paths, each with an automated test.
- **Quiet.** No accounts, no telemetry, no background network.

## Free vs Pro

Buy once, not a subscription. The switch is free forever; the part that reads your agents is a one-time unlock.

| | Free | Pro — $19 / ¥133, one-time |
|---|---|---|
| Keep awake with the lid closed | ✅ | ✅ |
| Never-stuck watchdog (all four recovery paths) | ✅ | ✅ |
| Battery guard (sleep below your threshold) | ✅ | ✅ |
| Launch at login | ✅ | ✅ |
| Auto-sleep when the last agent finishes | | ✅ |
| Alert when an agent waits for your input | | ✅ |
| Session panel: agent, project, runtime, state | | ✅ |
| Multi-agent tracking across terminals | | ✅ |

Free is a manual keep-awake switch: on means stay awake, so turn it off when your run is done. Pro watches your agents and handles that for you.

**One license, up to 3 Macs.** A new purchase activates online once — a call you trigger that binds a Mac to your license — then runs fully offline. Hit the limit? Unbind a Mac anytime from the self-serve portal at [pro.nemuri.app/manage](https://pro.nemuri.app/manage). Licenses bought before **2026-07-23** keep their original terms: unlimited Macs, fully offline, no activation call at all.

Free (left) is the switch, the battery guard, and the watchdog — the session area always reads exactly like this. Pro (right) shows who's running, who needs you, and how long until it sleeps.

| Free | Pro |
|---|---|
| ![Nemuri Free panel: Agent Mode on, no session list, agent detection marked as a Pro feature](docs/panel-free.png) | ![Nemuri Pro panel: watching two agents, one waiting for you, one running](docs/panel-pro.png) |

---

## Why this repo is open

Nemuri asks you to approve a **root helper** — a background process that runs as root and flips the system `disablesleep` flag. That's a big ask. This repository is the trust-critical part of Nemuri, published so you can read it instead of trusting us.

**Free and Pro run the exact same code from this repo.** Whether or not you ever pay for Pro, the part that needs your trust is the part published here.

| In this repo | What it is |
|---|---|
| `Sources/Helper` | The root LaunchDaemon — the only component that ever runs as root. |
| `Sources/Shared` | The XPC contract between app and helper — the helper's entire attack surface. |
| `Sources/Core` | The `pmset`/sentinel/battery primitives (the never-stuck guarantees), the installer that edits your agent config, and the local IPC protocol. |
| `Sources/HookBridge` | `aw-hook` / `aw-codex` — the tiny binaries written into your `~/.claude/settings.json` and `~/.codex/config.toml`. |

**Not here:** the detection engine, the state machine, the offline license verification, and the SwiftUI app. Those are closed-source — they're what Nemuri Pro sells. You can't build the full app from this tree, and the binary in the DMG isn't built from this source alone. That's a real limit, stated plainly rather than blurred.

## What you can verify

- **Minimal root surface.** The helper exposes three XPC methods — `setSleepDisabled(Bool)`, `currentState()`, `ping()` — and shells out to `/usr/bin/pmset`. No arbitrary commands, no writes outside its sentinel, no network.
- **Never stuck.** If the app crashes, is killed, or is uninstalled, `pmset disablesleep` returns to `0`. The watchdog, the 60-second sentinel self-check, and boot-time recovery are all in `Sources/Helper/main.swift`.
- **No hidden network.** Grep the tree for `URLSession`, `Network`, `socket(`, `connect(` — the only sockets are `AF_UNIX` (local IPC), and the root helper never reaches the internet.
- **Config backed up and reversible.** `Sources/Core/Installer.swift` edits `~/.claude/settings.json` and `~/.codex/config.toml`. It backs up before writing and can fully restore.

## Privacy

Nemuri runs with zero network in daily use. It reaches the internet only when you trigger it: an update check behind "Check for Updates," and a one-time activation when you buy Pro that binds this Mac to your license. After that, license checks are fully local against an embedded Ed25519 public key — no telemetry, no background check-ins. Licenses bought before device binding activate fully offline, with no call at all.

## Build it yourself

```bash
swift build   # the root helper, the XPC contract, the core primitives, and the two hook bridges
```

Requires macOS 13+ and Swift 5.9+. This tree builds standalone — no closed-source dependency, no third-party package, no network at build time. To read the root component first, start at `Sources/Helper/main.swift` (short on purpose) and `Sources/Shared/AwakeShared.swift` (the XPC requirement that decides who is allowed to command the helper).

## Contributing

Issues and PRs on the code here are welcome — especially anything touching the root helper, the recovery paths, or the config installer. Found a way to make the helper do something it shouldn't? Open a GitHub security advisory on this repo rather than a public issue.

Contributions are accepted under the Apache License 2.0 (see `LICENSE`).

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The closed-source parts of Nemuri (detection engine, app, licensing) are not covered by this license and are not distributed here.
