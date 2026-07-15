import Foundation
import AwakeCore

// aw-codex：Codex → Nemuri 本地 socket 的桥，两种调用形态：
// 1. notify 模式（默认）：事件 JSON 在 argv[1]（agent-turn-complete → turn_complete）
// 2. hooks 模式（argv[1] == --hook，codex ≥0.144 原生 hooks）：事件 JSON 走 stdin，
//    UserPromptSubmit/Stop/SessionStart/PermissionRequest → codex 首个 turn-start 精确信号。
//    hooks 由 codex 各自并发调起、互不转发，此模式不碰 notify 链回。
// 铁律同 aw-hook：预算 <100ms，任何失败静默 exit 0；stdout 不写任何字节
//（codex 会解析 hook stdout 的 universal 输出，写错会干扰会话）。

let args = CommandLine.arguments
guard args.count >= 2 else { exit(0) }

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

if args[1] == "--hook" {
    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    guard stdinData.count <= 4 * 1024 * 1024,
          let parsed = try? JSONSerialization.jsonObject(with: stdinData),
          let obj = parsed as? [String: Any],
          let fields = parseCodexHookPayload(obj) else { exit(0) }
    let line = AgentEvent(
        source: "codex",
        event: fields.event,
        // session_id = rollout 会话 id（实测），与 notify thread-id/面板 rollout 行同键；
        // 缺失回退 ppid（hook 由 codex 直接调起，ppid 即 codex 进程）
        session: fields.session.isEmpty ? "ppid-\(getppid())" : fields.session,
        cwd: fields.cwd,
        ts: Int(Date().timeIntervalSince1970),
        message: fields.message
    ).jsonLine()
    _ = HookWire.send(line: line, socketPath: nemuriSocketPath(home: home))
    exit(0)
}

let eventJSON = args[1]

if let data = eventJSON.data(using: .utf8),
   let parsed = try? JSONSerialization.jsonObject(with: data),
   let obj = parsed as? [String: Any],
   let type = obj["type"] as? String, !type.isEmpty {
    let event: String
    var message: String?
    if type == "agent-turn-complete" {
        event = "turn_complete"
        message = obj["last-assistant-message"] as? String
    } else {
        // 未知 type 原样转发为 event=unknown（原 type 放 message），app 侧决定忽略
        event = "unknown"
        message = type
    }
    if let m = message, m.count > 200 { message = String(m.prefix(200)) }

    // codex ≥0.144 的 notify payload 自带 thread-id（= rollout 会话 id）与 cwd（会话真实目录）——
    // 2026-07-13 实测。优先用它们：会话键与 rollout 行精确对上；桌面引擎（进程 cwd=/）也能发出
    // 带真实项目目录的事件。旧版缺字段回退 ppid/进程 cwd（同一 codex 实例跨 turn 稳定）。
    let threadID = ((obj["thread-id"] as? String) ?? (obj["thread_id"] as? String))
        .flatMap { $0.isEmpty ? nil : $0 }
    let payloadCWD = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let line = AgentEvent(
        source: "codex",
        event: event,
        session: threadID ?? "ppid-\(getppid())",
        cwd: payloadCWD ?? FileManager.default.currentDirectoryPath,
        ts: Int(Date().timeIntervalSince1970),
        message: message
    ).jsonLine()

    _ = HookWire.send(line: line, socketPath: nemuriSocketPath(home: home))
}
forwardToOriginalNotify(eventJSON: eventJSON, home: home)
exit(0)

private func forwardToOriginalNotify(eventJSON: String, home: String) {
    guard let chain = Installer.readCodexNotifyChain(home: home),
          let executable = chain.notify.first, !executable.isEmpty,
          executable != Installer.awCodexPath(home: home) else { return }

    let process = Process()
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(chain.notify.dropFirst()) + [eventJSON]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = chain.notify + [eventJSON]
    }
    if let null = FileHandle(forWritingAtPath: "/dev/null") {
        process.standardInput = null
        process.standardOutput = null
        process.standardError = null
    }
    try? process.run()
}
