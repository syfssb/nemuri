import Foundation
import AwakeCore

// aw-hook：Claude Code hooks → Nemuri 本地 socket 的桥。
// 铁律：绝不拖慢用户的 claude——组一行协议 JSON → 连本地 socket 写入（预算 <100ms）→
// 任何失败（坏输入/无 socket/超时）静默 exit 0。

let stdinData = FileHandle.standardInput.readDataToEndOfFile()
// 防御性解析：超长（正常 hook JSON 几 KB）、非 JSON、缺事件名 → 静默放弃
guard stdinData.count <= 4 * 1024 * 1024,
      let parsed = try? JSONSerialization.jsonObject(with: stdinData),
      let obj = parsed as? [String: Any],
      let hookName = obj["hook_event_name"] as? String, !hookName.isEmpty else { exit(0) }

let eventMap = [
    "SessionStart": "session_start",
    "UserPromptSubmit": "user_prompt_submit",
    "Stop": "stop",
    "StopFailure": "stop_failure",
    "Notification": "notification",
    "SessionEnd": "session_end",
]
// 未知 hook 事件原样转发：app 侧会忽略未知事件，避免 Claude 新增 hook 误触发 RUNNING。
let event = eventMap[hookName] ?? hookName

let sessionID = obj["session_id"] as? String
// session_id 缺失兜底：hook 由 claude 直接调起，ppid 即 claude 进程，稳定可当会话键
let session = (sessionID?.isEmpty == false) ? sessionID! : "ppid-\(getppid())"
var message = obj["message"] as? String
if let m = message, m.count > 200 { message = String(m.prefix(200)) }

let line = AgentEvent(
    source: "claude",
    event: event,
    session: session,
    cwd: obj["cwd"] as? String ?? "",
    ts: Int(Date().timeIntervalSince1970),
    message: message
).jsonLine()

let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
_ = HookWire.send(line: line, socketPath: nemuriSocketPath(home: home))
exit(0)
