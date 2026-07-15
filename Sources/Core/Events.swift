import Foundation

// 事件协议：精确层（agent 官方 hook/notify）与启发式层归一为同一形状，
// 每事件一行 JSON，经本地 AF_UNIX socket 送达 app（不出本机）。

/// 本地 socket 路径。aw-hook / aw-codex 与 app 共用；home 作参数以便 fake HOME 测试。
public func nemuriSocketPath(home: String) -> String {
    home + "/Library/Application Support/Nemuri/agent.sock"
}

/// 一条归一化事件。source: claude|codex|heuristic；event 取值见下方 mapEventToSignal
///（未知 hook 事件原样转发，app 侧按语义映射决定处理或忽略）。
public struct AgentEvent: Equatable {
    public let source: String
    public let event: String
    public let session: String
    public let cwd: String
    public let ts: Int
    public let message: String?

    public init(source: String, event: String, session: String, cwd: String, ts: Int, message: String? = nil) {
        self.source = source
        self.event = event
        self.session = session
        self.cwd = cwd
        self.ts = ts
        self.message = message
    }

    /// 防御性解析一行协议 JSON：source/event 缺失即丢弃（nil），其余字段全有兜底，未知字段忽略。
    public init?(line: Data) {
        guard let parsed = try? JSONSerialization.jsonObject(with: line),
              let obj = parsed as? [String: Any],
              let source = obj["source"] as? String, !source.isEmpty,
              let event = obj["event"] as? String, !event.isEmpty else { return nil }
        self.source = source
        self.event = event
        self.session = obj["session"] as? String ?? ""
        self.cwd = obj["cwd"] as? String ?? ""
        self.ts = obj["ts"] as? Int ?? 0
        self.message = obj["message"] as? String
    }

    /// 编码成一行协议 JSON（无换行；sortedKeys 保证输出确定，便于脚本断言）。
    public func jsonLine() -> String {
        var obj: [String: Any] = ["source": source, "event": event, "session": session, "cwd": cwd, "ts": ts]
        if let message { obj["message"] = message }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - 语义映射（agent 官方 hook/notify 事件 → 会话信号）

public enum SessionSignal: Equatable {
    case running
    case needsYou
    case gone
}

/// 精确层事件是否带「等你确认」（权限请求）语义：agent 停下来等你批准工具调用时，
/// 即便此前没在跑，也必须保持唤醒——否则你回到电脑前只看到一台睡着、没人批准的机器。
/// claude：Notification hook 双语义——既发权限请求（"Claude needs your permission to use Bash"）
/// 也发闲置提醒（"Claude is waiting for your input"），后者本质是闲置 REPL（坑点：闲置 REPL 不得
/// 触发保醒）。按 message 关键词区分；无 message 一律按闲置处理（保守，宁可少保醒也不为闲置对话
/// 禁休眠）。aw-hook 原样转发 message（截断 200 字符，关键词在头部不受影响）。
/// codex：permission_request 是专用等审批 hook（codex 0.144 实测），只在 turn 进行中工具调用等批准时触发，
/// 没有闲置变体（闲置 REPL 只发 session_start/stop）——事件名即语义，不依赖 message（tool_name 只是展示）。
public func isConfirmRequestEvent(source: String, event: String, message: String?) -> Bool {
    switch source {
    case "claude":
        guard event == "notification", let message else { return false }
        return message.lowercased().contains("permission")
    case "codex":
        return event == "permission_request"
    default:
        return false
    }
}

/// 精确层事件 → 会话信号。返回 nil = app 侧忽略。
/// claude：UserPromptSubmit = RUNNING；SessionStart/Stop/StopFailure/Notification = NEEDS_YOU
/// （Notification 里带权限语义的另标 confirmWaiting，判定见下方 isConfirmRequestEvent；
/// 消费方是闭源检测层，不在本模块）。
/// codex：notify 的 turn_complete + 原生 hooks（≥0.144，2026-07-13 实测）的
/// user_prompt_submit（turn 开始 = RUNNING，codex 从此有 turn-start 精确信号）/
/// stop（turn 结束）/ session_start（会话出现，闲置不算工作）/ permission_request（等审批，
/// 与 claude 权限 notification 同标 confirmWaiting）。
/// codex hooks 没有 SessionEnd/StopFailure：GONE 靠进程/rollout 层；turn 失败不发 Stop（实测），
/// 由 rollout inactive 证据与失联回收兜底。unknown 事件忽略。
public func mapEventToSignal(source: String, event: String) -> SessionSignal? {
    switch source {
    case "claude":
        switch event {
        case "session_start", "stop", "stop_failure", "notification": return .needsYou
        case "session_end": return .gone
        case "user_prompt_submit": return .running
        default: return nil
        }
    case "codex":
        switch event {
        case "user_prompt_submit": return .running
        case "turn_complete", "stop", "session_start", "permission_request": return .needsYou
        default: return nil
        }
    default:
        return nil // heuristic 层不走 socket（进程扫描在 app 内直连），未知 source 忽略
    }
}

// MARK: - Codex 原生 hooks payload（字段以 codex 0.144 实测为准，2026-07-13）

/// codex hooks 的 stdin JSON → 协议事件字段。字段与 Claude hooks 几乎同构：
/// `hook_event_name`（CamelCase）/`session_id`（= rollout 会话 id，与 notify thread-id 同源）/
/// `cwd`（会话真实目录）；事件专属：UserPromptSubmit 带 `prompt`、Stop 带 `last_assistant_message`、
/// PermissionRequest 带 `tool_name`。未知事件名原样转发（app 侧 mapEventToSignal 忽略），
/// 缺 hook_event_name 返回 nil（桥侧静默退 0）。
public func parseCodexHookPayload(_ obj: [String: Any]) -> (event: String, session: String, cwd: String, message: String?)? {
    guard let hookName = obj["hook_event_name"] as? String, !hookName.isEmpty else { return nil }
    let eventMap = [
        "SessionStart": "session_start",
        "UserPromptSubmit": "user_prompt_submit",
        "Stop": "stop",
        "PermissionRequest": "permission_request",
    ]
    let event = eventMap[hookName] ?? hookName
    var message: String?
    switch event {
    case "user_prompt_submit": message = obj["prompt"] as? String
    case "stop": message = obj["last_assistant_message"] as? String
    case "permission_request": message = obj["tool_name"] as? String
    default: break
    }
    if let m = message, m.count > 200 { message = String(m.prefix(200)) }
    return (
        event: event,
        session: (obj["session_id"] as? String) ?? "",
        cwd: obj["cwd"] as? String ?? "",
        message: message
    )
}
