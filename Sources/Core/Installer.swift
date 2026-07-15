import Foundation
import CryptoKit

// 一键安装/卸载引擎：把 aw-hook / aw-codex 接进用户的 agent 配置。
// 硬性不变量：改用户配置前必须备份，且可完整撤销（下方 uninstall 是 install 的逆操作）。
// home 一律作参数传入——fake HOME 可测的关键（scripts/accept-m3.sh installer-test）。
// 设计：改前必备份；Claude settings.json 深合并（用户内容一字不动）；Codex config.toml
// 行级编辑（零 TOML 依赖，注释与未知段落原样保留）；卸载精确摘除，与原文件 diff 为空。

public enum InstallerError: LocalizedError {
    case malformedJSON(String)
    case malformedTOML(String)
    case configurationChanged(String)

    // 供 CLI（NemuriChecks installer）打印；App 侧 SettingsView 按 case 走五语言本地化文案
    public var errorDescription: String? {
        switch self {
        case let .malformedJSON(path):
            return "无法解析 \(path)（不是合法 JSON 对象），为避免破坏用户配置已中止"
        case let .malformedTOML(path):
            return "无法解析 \(path)（root 区存在未闭合的多行值），为避免破坏用户配置已中止"
        case let .configurationChanged(path):
            return "\(path) 在预览期间发生变化，请重新确认 diff"
        }
    }
}

/// 安装计划：before/after 全文，UI 用 lineDiff 展示确认后才落盘（硬性不变量 4）。
public struct InstallPlan {
    public let path: String
    public let before: String
    public let after: String
    public let existedBefore: Bool
    public var changed: Bool { before != after }
}

public struct CodexNotifyChain: Codable, Equatable {
    public let version: Int
    public let originalNotify: [String]

    public var notify: [String] { originalNotify }

    public init(version: Int = 1, originalNotify: [String]) {
        self.version = version
        self.originalNotify = originalNotify
    }
}

public struct AutoInstallReport: Equatable {
    public let claudeAttempted: Bool
    public let claudeOK: Bool
    public let codexAttempted: Bool
    public let codexOK: Bool
    public let claudeError: String?
    public let codexError: String?

    public init(claudeAttempted: Bool, claudeOK: Bool, codexAttempted: Bool, codexOK: Bool,
                claudeError: String?, codexError: String?) {
        self.claudeAttempted = claudeAttempted
        self.claudeOK = claudeOK
        self.codexAttempted = codexAttempted
        self.codexOK = codexOK
        self.claudeError = claudeError
        self.codexError = codexError
    }

    public var anyOK: Bool { claudeOK || codexOK }
    public var anyAttempted: Bool { claudeAttempted || codexAttempted }
    public var hasError: Bool { claudeError != nil || codexError != nil }
    public var installedAgentNames: [String] {
        var names: [String] = []
        if claudeOK { names.append("Claude Code") }
        if codexOK { names.append("Codex") }
        return names
    }
    public var failedAgentNames: [String] {
        var names: [String] = []
        if claudeAttempted && !claudeOK { names.append("Claude Code") }
        if codexAttempted && !codexOK { names.append("Codex") }
        return names
    }
}

public enum AutoInstallOutcome: Equatable {
    case skippedFree
    case skippedAlreadyAttempted
    case attempted(AutoInstallReport)
}

public enum IntegrationAutoInstaller {
    public static let markerKey = "didAutoInstallIntegrationsForPro.v1"
    /// U6：已通知过的失败指纹——同一错误只弹一次通知，后续启动静默重试
    public static let failureFingerprintKey = "autoInstallNotifiedFailureFingerprint.v1"
    /// U6：上次自动安装的失败详情——「查看错误」终于有处可看（设置 → 集成 tab 展示），
    /// 成功/无错的下一次尝试会清掉
    public static let claudeErrorKey = "autoInstallLastClaudeError.v1"
    public static let codexErrorKey = "autoInstallLastCodexError.v1"

    public static func runIfNeeded(
        fromDir: String,
        home: String,
        isPro: Bool,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AutoInstallOutcome {
        guard isPro else { return .skippedFree }
        guard !defaults.bool(forKey: markerKey) else { return .skippedAlreadyAttempted }
        let report = Installer.autoInstallIntegrations(fromDir: fromDir, home: home, environment: environment)
        persistErrors(report, defaults: defaults)
        // 只有真正尝试过 agent 配置目录，且成功/幂等或无错误，才落 marker：
        // - 用户手动卸载后不再静默装回；
        // - 桥缺失/瞬时 IO 导致双端失败时，保留下次启动重试机会；
        // - 首启尚未安装 Claude/Codex 时不能封死 marker，用户后装 agent 仍应自动补 hook。
        if report.anyAttempted && (report.anyOK || !report.hasError) {
            defaults.set(true, forKey: markerKey)
        }
        return .attempted(report)
    }

    /// U6：失败指纹 = 失败的 agent + 各自错误文案。指纹相同 ⟺ 还是同一个错，不值得再打扰。
    public static func failureFingerprint(_ report: AutoInstallReport) -> String? {
        var parts: [String] = []
        if report.claudeAttempted && !report.claudeOK {
            parts.append("claude:\(report.claudeError ?? "")")
        }
        if report.codexAttempted && !report.codexOK {
            parts.append("codex:\(report.codexError ?? "")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    /// U6：这次失败要不要弹通知。新指纹 → 记下并返回 true（弹一次）；同指纹 → false（静默重试）；
    /// 无失败 → 清指纹并返回 false——之后再出同样的错会被视为新一轮问题、重新提醒。
    /// 注意有落 defaults 的副作用：每次 attempted 结果只调一次。
    public static func shouldNotifyFailure(_ report: AutoInstallReport, defaults: UserDefaults = .standard) -> Bool {
        guard let fingerprint = failureFingerprint(report) else {
            defaults.removeObject(forKey: failureFingerprintKey)
            return false
        }
        guard defaults.string(forKey: failureFingerprintKey) != fingerprint else { return false }
        defaults.set(fingerprint, forKey: failureFingerprintKey)
        return true
    }

    /// U6：把本次尝试的错误详情落 defaults（尝试过才更新：成功清掉、失败覆盖；
    /// 未尝试的一侧不动——上次的错误在用户处理前应持续可见）。
    public static func persistErrors(_ report: AutoInstallReport, defaults: UserDefaults) {
        if report.claudeAttempted {
            if let error = report.claudeError {
                defaults.set(error, forKey: claudeErrorKey)
            } else {
                defaults.removeObject(forKey: claudeErrorKey)
            }
        }
        if report.codexAttempted {
            if let error = report.codexError {
                defaults.set(error, forKey: codexErrorKey)
            } else {
                defaults.removeObject(forKey: codexErrorKey)
            }
        }
    }
}

public enum Installer {
    public static let hookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"]
    /// codex ≥0.144 原生 hooks 的接入事件（2026-07-13 实测）：UserPromptSubmit = turn 开始
    ///（codex 首个 turn-start 精确信号）、Stop = turn 结束、SessionStart = 会话出现、
    /// PermissionRequest = 等审批。codex 无 SessionEnd/StopFailure 事件；turn 失败不发 Stop（实测），
    /// 卡 RUNNING 由 rollout inactive 证据 + 失联回收兜底。
    public static let codexHookEvents = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"]
    /// hooks.state 位置键用的 snake_case 事件标签（codex hook_event_key_label 的对应子集）
    static let codexHookEventLabels = [
        "SessionStart": "session_start",
        "UserPromptSubmit": "user_prompt_submit",
        "Stop": "stop",
        "PermissionRequest": "permission_request",
    ]

    // MARK: - 路径

    public static func supportDir(home: String) -> String { home + "/Library/Application Support/Nemuri" }
    public static func binDir(home: String) -> String { supportDir(home: home) + "/bin" }
    public static func awHookPath(home: String) -> String { binDir(home: home) + "/aw-hook" }
    public static func awHookCommand(home: String) -> String { shellQuoted(awHookPath(home: home)) }
    public static func awCodexPath(home: String) -> String { binDir(home: home) + "/aw-codex" }
    public static func codexChainPath(home: String) -> String { supportDir(home: home) + "/codex-chain.json" }
    public static func claudeConfigDir(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let raw = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return home + "/.claude" }
        let expanded = (raw as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
    public static func claudeSettingsPath(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        claudeConfigDir(home: home, environment: environment) + "/settings.json"
    }
    public static func codexConfigPath(home: String) -> String { home + "/.codex/config.toml" }
    public static func codexHooksPath(home: String) -> String { home + "/.codex/hooks.json" }
    /// codex hooks 的 command 是 shell 字符串（同 Claude），Application Support 路径含空格必须 quote；
    /// --hook 让 aw-codex 走 stdin hooks 模式（区别于 argv[1] 的 notify 模式）。
    public static func awCodexHookCommand(home: String) -> String { shellQuoted(awCodexPath(home: home)) + " --hook" }
    static func backupsDir(home: String) -> String { supportDir(home: home) + "/backups" }
    static func stateFilePath(home: String) -> String { supportDir(home: home) + "/install_state.json" }

    public static func claudeAgentPresent(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        isDirectory(claudeConfigDir(home: home, environment: environment))
    }

    public static func codexAgentPresent(home: String) -> Bool {
        isDirectory(home + "/.codex")
    }

    /// app 首次安装集成时把 hook 桥从 bundle 复制到 Application Support/Nemuri/bin/
    ///（hooks 指向这里而非 bundle，app 移动位置后集成不断）。
    public static func installBridgeBinaries(fromDir: String, home: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: binDir(home: home), withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir(home: home))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binDir(home: home))
        for name in ["aw-hook", "aw-codex"] {
            let src = fromDir + "/" + name
            let dst = binDir(home: home) + "/" + name
            guard fm.fileExists(atPath: src) else { continue } // swift run 场景无 bundle，别硬崩
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dst)
        }
    }

    public static func readCodexNotifyChain(home: String) -> CodexNotifyChain? {
        let url = URL(fileURLWithPath: codexChainPath(home: home))
        guard let data = try? Data(contentsOf: url),
              let chain = try? JSONDecoder().decode(CodexNotifyChain.self, from: data),
              chain.version == 1 else { return nil }
        return chain
    }

    public static func autoInstallIntegrations(
        fromDir: String,
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AutoInstallReport {
        let claudePresent = claudeAgentPresent(home: home, environment: environment)
        let codexPresent = codexAgentPresent(home: home)
        guard claudePresent || codexPresent else {
            return AutoInstallReport(
                claudeAttempted: false,
                claudeOK: false,
                codexAttempted: false,
                codexOK: false,
                claudeError: nil,
                codexError: nil)
        }

        var bridgeError: Error?
        do {
            try installBridgeBinaries(fromDir: fromDir, home: home)
        } catch {
            bridgeError = error
        }

        var claudeOK = false
        var codexOK = false
        var claudeError: String?
        var codexError: String?

        if let bridgeError {
            let message = bridgeError.localizedDescription
            if claudePresent { claudeError = message }
            if codexPresent { codexError = message }
        } else {
            if claudePresent, FileManager.default.isExecutableFile(atPath: awHookPath(home: home)) {
                do {
                    try installClaude(home: home, environment: environment)
                    claudeOK = true
                } catch {
                    claudeError = error.localizedDescription
                }
            } else if claudePresent {
                claudeError = "aw-hook is missing or not executable"
            }
            if codexPresent, FileManager.default.isExecutableFile(atPath: awCodexPath(home: home)) {
                do {
                    try installCodex(home: home)
                    codexOK = true
                } catch {
                    codexError = error.localizedDescription
                }
            } else if codexPresent {
                codexError = "aw-codex is missing or not executable"
            }
        }
        return AutoInstallReport(
            claudeAttempted: claudePresent, claudeOK: claudeOK,
            codexAttempted: codexPresent, codexOK: codexOK,
            claudeError: claudeError, codexError: codexError)
    }

    // MARK: - Claude（settings.json 深合并）

    public static func claudeInstalled(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: awHookPath(home: home)) else { return false }
        guard let obj = readJSONDict(claudeSettingsPath(home: home, environment: environment)) else { return false }
        let hooks = obj["hooks"] as? [String: Any] ?? [:]
        let target = awHookCommand(home: home)
        return hookEvents.allSatisfy { containsCommand(hooks[$0] as? [Any] ?? [], target) }
    }

    /// 深合并计划：只在六个事件数组里追加我们的 entry，已存在则跳过；用户既有内容一字不动。
    /// U4：优先做最小文本级插入——只在缺我们 entry 的位置动必要的字节，用户原排版（键序、
    /// 缩进、空行）逐字保留，DiffSheet 因此展示真实最小 diff、落盘不再重排整份文件。
    /// 采用前必须通过「解析等价」验证：插入结果解析后与整树深合并结果完全一致，否则回退
    /// serializeJSON 深合并重排（旧行为，语义始终正确——硬性不变量 4 的安全底座）。
    /// 旧版未加 shell 引号的 aw-hook command 需要原地升级（改值而非纯插入），同样走深合并回退。
    public static func claudePlan(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> InstallPlan {
        let path = claudeSettingsPath(home: home, environment: environment)
        let before = try? String(contentsOfFile: path, encoding: .utf8)
        var obj: [String: Any] = [:]
        if let before {
            guard let dict = parseJSONDict(before) else { throw InstallerError.malformedJSON(path) }
            obj = dict
        }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        let legacy = awHookPath(home: home)
        let target = awHookCommand(home: home)
        var changed = false
        var needsLegacyRewrite = false
        var missingEvents: [String] = []
        for event in hookEvents {
            var arr = hooks[event] as? [Any] ?? []
            let normalized = normalizeClaudeHookCommands(arr, legacy: legacy, target: target)
            arr = normalized.groups
            if normalized.changed { needsLegacyRewrite = true }
            if !normalized.containsTarget {
                missingEvents.append(event)
                arr.append(["hooks": [["type": "command", "command": target]]])
            }
            if normalized.changed || !normalized.containsTarget {
                hooks[event] = arr
                changed = true
            }
        }
        obj["hooks"] = hooks
        var after = changed ? serializeJSON(obj) : (before ?? serializeJSON(obj))
        if changed, !needsLegacyRewrite, let before,
           let minimal = claudeMinimalInsertedText(before: before, events: missingEvents, target: target),
           let minimalObj = parseJSONDict(minimal),
           NSDictionary(dictionary: minimalObj).isEqual(to: obj) {
            after = minimal
        }
        return InstallPlan(
            path: path,
            before: before ?? "",
            after: after,
            existedBefore: before != nil)
    }

    public static func installClaude(
        home: String,
        expectedBefore: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let plan = try claudePlan(home: home, environment: environment)
        if let expectedBefore, plan.before != expectedBefore {
            throw InstallerError.configurationChanged(plan.path)
        }
        guard plan.changed else { return } // 幂等：已装就一字不动
        var claudeState: [String: Any] = ["existed": plan.existedBefore]
        if plan.existedBefore {
            claudeState["backup"] = try writeBackup(plan.before, name: "settings.json", home: home)
        }
        let previousState = loadState(home: home)
        do {
            try updateState(home: home) { $0["claude"] = claudeState }
            try writeFile(plan.after, path: plan.path)
        } catch {
            try? writeState(previousState, home: home)
            throw error
        }
    }

    /// 卸载：hooks 数组精确摘除我们的 entry（其余保留）。字节级还原策略：
    /// 摘除后与安装时备份语义相等 → 原样写回备份字节（重新序列化会破坏用户原格式，diff 就不为空了）；
    /// 用户装后又改过 → 写序列化结果，保住用户改动。原本无此文件且摘净后为空 → 删除文件。
    public static func uninstallClaude(
        home: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let path = claudeSettingsPath(home: home, environment: environment)
        defer { try? updateState(home: home) { $0.removeValue(forKey: "claude") } }
        guard let current = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        guard var obj = parseJSONDict(current) else { throw InstallerError.malformedJSON(path) }
        let targets = Set([awHookPath(home: home), awHookCommand(home: home)])
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            guard var arr = hooks[event] as? [Any] else { continue }
            arr = arr.compactMap { group -> Any? in
                guard var g = group as? [String: Any], let inner = g["hooks"] as? [Any] else { return group }
                let filtered = inner.filter { item in
                    guard let command = (item as? [String: Any])?["command"] as? String else { return true }
                    return !targets.contains(command)
                }
                guard filtered.count != inner.count else { return group } // 组内没有我们的，不动
                if filtered.isEmpty { return nil } // 摘空的组整个撤掉（就是我们装的那个）
                g["hooks"] = filtered
                return g
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }

        let state = loadState(home: home)["claude"] as? [String: Any]
        let existed = state?["existed"] as? Bool ?? true
        if !existed && obj.isEmpty {
            try FileManager.default.removeItem(atPath: path)
            return
        }
        if let backupPath = state?["backup"] as? String,
           let backupText = try? String(contentsOfFile: backupPath, encoding: .utf8),
           let backupObj = parseJSONDict(backupText),
           NSDictionary(dictionary: obj).isEqual(to: backupObj) {
            try writeFile(backupText, path: path) // 语义相等 → 字节级还原
            return
        }
        try writeFile(serializeJSON(obj), path: path)
    }

    // MARK: - Claude settings.json 最小文本级插入（U4）

    /// 在用户原文上做最小插入：已有事件数组 → 追加一个元素；hooks 里缺事件键 → 补成员；
    /// 根上缺 hooks → 补整个 hooks 成员。除插入点（及前一元素/成员行尾的逗号）外不动任何字节。
    /// 前提：全文已通过 JSONSerialization 解析（strict JSON）。任何意外形态（值类型不符、
    /// 扫描失败）返回 nil，由 claudePlan 回退整树深合并——正确性由调用方的解析等价验证兜底，
    /// 这里只负责「排版好看」。
    static func claudeMinimalInsertedText(before: String, events: [String], target: String) -> String? {
        guard !events.isEmpty else { return nil }
        let bytes = Array(before.utf8)
        var scanner = JSONTextScanner(bytes: bytes, at: 0)
        guard let root = scanner.parseTopLevelObject() else { return nil }
        let unit = indentUnit(of: before)

        let compactGroup = "{ \"hooks\": [{ \"type\": \"command\", \"command\": \(jsonEncodedString(target)) }] }"
        func prettyGroup(base: String) -> String {
            "{\n"
                + base + unit + "\"hooks\": [\n"
                + base + unit + unit + "{\n"
                + base + unit + unit + unit + "\"type\": \"command\",\n"
                + base + unit + unit + unit + "\"command\": " + jsonEncodedString(target) + "\n"
                + base + unit + unit + "}\n"
                + base + unit + "]\n"
                + base + "}"
        }
        func eventMember(_ event: String, indent: String) -> String {
            let elem = indent + unit
            return "\(jsonEncodedString(event)): [\n" + elem + prettyGroup(base: elem) + "\n" + indent + "]"
        }
        func compactEventMember(_ event: String) -> String {
            "\(jsonEncodedString(event)): [\(compactGroup)]"
        }
        func hooksMember(_ events: [String], indent: String) -> String {
            let inner = indent + unit
            return "\"hooks\": {\n" + inner
                + events.map { eventMember($0, indent: inner) }.joined(separator: ",\n" + inner)
                + "\n" + indent + "}"
        }

        enum Edit {
            case insert(Int, String)
            case replace(Range<Int>, String)
            var position: Int {
                switch self {
                case let .insert(at, _): return at
                case let .replace(range, _): return range.lowerBound
                }
            }
        }
        var edits: [Edit] = []
        func lineIndent(at pos: Int) -> String {
            var start = pos
            while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
            var out = ""
            var j = start
            while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 {
                out.append(bytes[j] == 0x20 ? " " : "\t")
                j += 1
            }
            return out
        }
        func containsNewline(_ range: Range<Int>) -> Bool {
            bytes[range].contains(0x0A)
        }
        /// 向对象追加成员：非空多行 → 最后一个成员值后插 ",\n缩进成员"（成员缩进照抄末成员所在行）；
        /// 非空单行 → 插 ", 成员"；空对象 → 整体替换为多行对象。
        func appendMembers(to object: JSONTextScanner.ObjectInfo,
                           pretty: (String) -> [String], compact: () -> [String]) {
            if let last = object.members.last {
                if containsNewline(object.range) {
                    let indent = lineIndent(at: last.keyStart)
                    let text = pretty(indent).joined(separator: ",\n" + indent)
                    edits.append(.insert(last.valueRange.upperBound, ",\n" + indent + text))
                } else {
                    edits.append(.insert(last.valueRange.upperBound, ", " + compact().joined(separator: ", ")))
                }
            } else {
                let base = lineIndent(at: object.range.lowerBound)
                let indent = base + unit
                let text = pretty(indent).joined(separator: ",\n" + indent)
                edits.append(.replace(object.range, "{\n" + indent + text + "\n" + base + "}"))
            }
        }

        if let hooksValue = root.members.last(where: { $0.key == "hooks" }) {
            var hookScanner = JSONTextScanner(bytes: bytes, at: hooksValue.valueRange.lowerBound)
            guard let hooksObj = hookScanner.parseObject(), hooksObj.range == hooksValue.valueRange else { return nil }
            var newEvents: [String] = []
            for event in events {
                guard let member = hooksObj.members.last(where: { $0.key == event }) else {
                    newEvents.append(event)
                    continue
                }
                var arrScanner = JSONTextScanner(bytes: bytes, at: member.valueRange.lowerBound)
                guard let arr = arrScanner.parseArray(), arr.range == member.valueRange else { return nil }
                if let lastElement = arr.elements.last {
                    if containsNewline(arr.range) {
                        let indent = lineIndent(at: lastElement.lowerBound)
                        edits.append(.insert(lastElement.upperBound, ",\n" + indent + prettyGroup(base: indent)))
                    } else {
                        edits.append(.insert(lastElement.upperBound, ", " + compactGroup))
                    }
                } else {
                    edits.append(.replace(arr.range, "[\(compactGroup)]"))
                }
            }
            if !newEvents.isEmpty {
                appendMembers(to: hooksObj,
                              pretty: { indent in newEvents.map { eventMember($0, indent: indent) } },
                              compact: { newEvents.map(compactEventMember) })
            }
        } else {
            appendMembers(to: root,
                          pretty: { indent in [hooksMember(events, indent: indent)] },
                          compact: { ["\"hooks\": { " + events.map(compactEventMember).joined(separator: ", ") + " }"] })
        }

        var out = bytes
        for edit in edits.sorted(by: { $0.position > $1.position }) {
            switch edit {
            case let .insert(at, text): out.insert(contentsOf: Array(text.utf8), at: at)
            case let .replace(range, text): out.replaceSubrange(range, with: Array(text.utf8))
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 缩进单位探测：取全文第一个有缩进的行——首个缩进行几乎总是深度 1 的成员，其前导空白
    /// 即一个单位；tab 开头按 tab。探测只影响美观，不影响正确性（解析等价验证在调用方）。
    static func indentUnit(of text: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let ws = line.prefix { $0 == " " || $0 == "\t" }
            guard !ws.isEmpty, ws.count < line.count else { continue } // 纯空白行不算
            if ws.first == "\t" { return "\t" }
            return String(ws.prefix(8))
        }
        return "  "
    }

    /// JSON 字符串编码（与 serializeJSON 的 .withoutEscapingSlashes 风格一致：/ 不转义）
    static func jsonEncodedString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// strict JSON 文本结构扫描器（字节级）。目的不是再造 parser，而是定位「对象成员 / 数组
    /// 元素」的原文字节范围，让插入只动必要字节（U4）。输入必先过 JSONSerialization（调用方
    /// 保证），这里对任何意外仍防御性返回 nil。多字节 UTF-8 只会出现在字符串内，字节级扫描安全。
    struct JSONTextScanner {
        let bytes: [UInt8]
        private var i: Int

        init(bytes: [UInt8], at index: Int) {
            self.bytes = bytes
            self.i = index
        }

        struct Member {
            let key: String
            let keyStart: Int
            let valueRange: Range<Int>
        }

        struct ObjectInfo {
            let range: Range<Int>
            let members: [Member]
        }

        struct ArrayInfo {
            let range: Range<Int>
            let elements: [Range<Int>]
        }

        /// 根对象 + 尾随只许空白（strict JSON 本就如此，防御性再验一遍）
        mutating func parseTopLevelObject() -> ObjectInfo? {
            guard let object = parseObject() else { return nil }
            skipWhitespace()
            return i == bytes.count ? object : nil
        }

        mutating func parseObject() -> ObjectInfo? {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "{") else { return nil }
            let start = i
            i += 1
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                i += 1
                return ObjectInfo(range: start..<i, members: [])
            }
            var members: [Member] = []
            while true {
                skipWhitespace()
                let keyStart = i
                guard let key = scanString() else { return nil }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let valueRange = skipValue() else { return nil }
                members.append(Member(key: key, keyStart: keyStart, valueRange: valueRange))
                skipWhitespace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                guard bytes[i] == UInt8(ascii: "}") else { return nil }
                i += 1
                return ObjectInfo(range: start..<i, members: members)
            }
        }

        mutating func parseArray() -> ArrayInfo? {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "[") else { return nil }
            let start = i
            i += 1
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                i += 1
                return ArrayInfo(range: start..<i, elements: [])
            }
            var elements: [Range<Int>] = []
            while true {
                guard let valueRange = skipValue() else { return nil }
                elements.append(valueRange)
                skipWhitespace()
                guard i < bytes.count else { return nil }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1
                    continue
                }
                guard bytes[i] == UInt8(ascii: "]") else { return nil }
                i += 1
                return ArrayInfo(range: start..<i, elements: elements)
            }
        }

        private mutating func skipWhitespace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        /// 任意值的字节范围（起点在跳过前导空白后）
        private mutating func skipValue() -> Range<Int>? {
            skipWhitespace()
            guard i < bytes.count else { return nil }
            let start = i
            switch bytes[i] {
            case UInt8(ascii: "\""):
                guard scanString() != nil else { return nil }
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                guard skipContainer() else { return nil }
            default:
                // 字面量/数字：吞到值边界
                while i < bytes.count {
                    switch bytes[i] {
                    case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
                         0x20, 0x09, 0x0A, 0x0D:
                        return start < i ? start..<i : nil
                    default:
                        i += 1
                    }
                }
                return start < i ? start..<i : nil
            }
            return start..<i
        }

        /// 括号配平地跳过 {…}/[…]（字符串内的括号经 scanString 天然跳过）
        private mutating func skipContainer() -> Bool {
            var depth = 0
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard scanString() != nil else { return false }
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    i += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    i += 1
                    if depth == 0 { return true }
                    if depth < 0 { return false }
                default:
                    i += 1
                }
            }
            return false
        }

        /// 起点须是引号；解码转义（含 \uXXXX 与代理对）返回字符串值，扫过收尾引号
        private mutating func scanString() -> String? {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { return nil }
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if b != UInt8(ascii: "\\") {
                    out.append(b)
                    i += 1
                    continue
                }
                i += 1
                guard i < bytes.count else { return nil }
                let escaped = bytes[i]
                i += 1
                switch escaped {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard let scalar = scanUnicodeEscape() else { return nil }
                    out.append(contentsOf: Array(String(scalar).utf8))
                default:
                    return nil
                }
            }
            return nil
        }

        private mutating func scanUnicodeEscape() -> Unicode.Scalar? {
            guard let first = scanHex4() else { return nil }
            if (0xD800...0xDBFF).contains(first) { // 高代理：必须跟 \uDC00–DFFF
                guard i + 1 < bytes.count,
                      bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else { return nil }
                i += 2
                guard let second = scanHex4(), (0xDC00...0xDFFF).contains(second) else { return nil }
                return Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
            }
            if (0xDC00...0xDFFF).contains(first) { return nil } // 孤立低代理
            return Unicode.Scalar(first)
        }

        private mutating func scanHex4() -> Int? {
            var value = 0
            for _ in 0..<4 {
                guard i < bytes.count, let digit = Self.hexDigit(bytes[i]) else { return nil }
                value = value << 4 | digit
                i += 1
            }
            return value
        }

        private static func hexDigit(_ b: UInt8) -> Int? {
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(b - UInt8(ascii: "A")) + 10
            default: return nil
            }
        }
    }

    // MARK: - Codex（config.toml 行级编辑）

    public static func codexInstalled(home: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: awCodexPath(home: home)) else { return false }
        // notify 只认「首位 = aw-codex」。被第三方接管后我们只躺在它的 --previous-notify 参数里，
        // 事件不再直达（2026-07-13 实测 SkyComputerUseClient 不转发）——必须视为未安装，
        // 设置页才会露出「安装」入口用于重新接管。
        // 原生 hooks（turn-start 精确信号）同为安装物：条目缺失或信任 hash 失配（如其他工具
        // 增删条目导致位置键漂移）同样视为未安装，重装即自愈。
        return codexNotifyHealth(home: home) == .ours && codexHooksInstalled(home: home)
    }

    /// Codex notify 顶位健康状态（设置 → 集成 的接管警示依据）。
    public enum CodexNotifyHealth: Equatable {
        case ours                   // notify 首位 = aw-codex，精确层可达
        case takenOver(top: String) // 顶位被其他工具占用（aw-codex 至多在它的参数里，收不到事件）
        case notConfigured          // 无 notify 行 / 无 config / 解析失败
    }

    public static func codexNotifyHealth(home: String) -> CodexNotifyHealth {
        guard let text = try? String(contentsOfFile: codexConfigPath(home: home), encoding: .utf8) else {
            return .notConfigured
        }
        let lines = text.components(separatedBy: "\n")
        guard let range = scanRoot(lines).notifyRange,
              let notify = parseTomlStringArray(lines[range].joined(separator: "\n")),
              let top = notify.first, !top.isEmpty else { return .notConfigured }
        return top == awCodexPath(home: home) ? .ours : .takenOver(top: top)
    }

    /// 记录进 codex-chain.json 的原 notify 先剔除 aw-codex 自身：第三方接管时会把我们塞进它的
    /// --previous-notify 参数（实测 Codex Computer Use 如此），原样链回会造成事件回环/重复。
    /// 卸载还原不受影响——它用 originalLine 的原字节（硬性不变量 4）。
    public static func sanitizedCodexOriginalNotify(_ notify: [String], home: String) -> [String] {
        let our = awCodexPath(home: home)
        var result: [String] = []
        var index = 0
        while index < notify.count {
            let arg = notify[index]
            if arg == our { index += 1; continue }
            if arg == "--previous-notify", index + 1 < notify.count,
               let data = notify[index + 1].data(using: .utf8),
               let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String],
               parsed.contains(our) {
                let rest = parsed.filter { $0 != our }
                if !rest.isEmpty,
                   let encoded = try? JSONSerialization.data(withJSONObject: rest, options: [.withoutEscapingSlashes]),
                   let str = String(data: encoded, encoding: .utf8) {
                    result.append(arg)
                    result.append(str)
                }
                index += 2
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    // MARK: - Codex 原生 hooks（hooks.json 条目 + config.toml [hooks.state] 信任，codex ≥0.144）
    //
    // 2026-07-13 实测（本机 0.144.0-alpha.4，桌面版 bundle 引擎）：
    // - payload 走 stdin JSON（hook_event_name/session_id/cwd/turn_id…），session_id = rollout 会话 id；
    // - 未信任的 hook 被【静默跳过】（无提示无降级）——写对 [hooks.state] trusted_hash 是成败位；
    // - hash 与位置键算法复刻自 codex-rs 开源实现，并已对本机真实配置（Otty 四条目）逐一比中。

    /// 复刻 codex 的 hook 信任 hash（codex-rs hooks/engine/discovery.rs `command_hook_hash` +
    /// config/fingerprint.rs `version_for_toml`）：归一化身份
    /// {event_name, [matcher,] hooks:[{async, command, [statusMessage,] timeout, type}]}
    /// 按 key 字典序紧凑序列化后 sha256，前缀 "sha256:"。归一化规则（与源码一致）：
    /// timeout 缺省 600、下限 1；UserPromptSubmit/Stop 不吃 matcher；commandWindows 恒剔除。
    /// entry 是 hooks.json 里的 handler 对象（我们只写 {type,command}，但已存在条目可能带
    /// timeout/statusMessage——按实际字段算，才能和 codex 眼中的 current_hash 对上）。
    public static func codexHookTrustedHash(eventLabel: String, entry: [String: Any], matcher: String? = nil) -> String? {
        guard (entry["type"] as? String) == "command",
              let command = entry["command"] as? String, !command.isEmpty else { return nil }
        var timeout = 600
        if let t = entry["timeout"] as? Int { timeout = max(t, 1) }
        let isAsync = (entry["async"] as? Bool) == true
        var handler = "{\"async\":\(isAsync ? "true" : "false"),\"command\":\(jsonStringLiteral(command))"
        if let status = entry["statusMessage"] as? String {
            handler += ",\"statusMessage\":\(jsonStringLiteral(status))"
        }
        handler += ",\"timeout\":\(timeout),\"type\":\"command\"}"
        var identity = "{\"event_name\":\(jsonStringLiteral(eventLabel)),\"hooks\":[\(handler)]"
        // matcher 归一化：user_prompt_submit/stop 事件忽略 matcher（codex matcher_pattern_for_event）
        if let matcher, !["user_prompt_submit", "stop"].contains(eventLabel) {
            identity += ",\"matcher\":\(jsonStringLiteral(matcher))"
        }
        identity += "}"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// serde_json 兼容的 JSON 字符串字面量：只转义 " \ 与 <0x20 控制符（\b\t\n\f\r 用短形，
    /// 其余 \u00xx 小写 hex），斜杠与非 ASCII 原样——逐字节对齐 codex 的序列化，hash 才可比。
    static func jsonStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// hooks.state 位置键（codex hook_key）：<hooks.json 绝对路径>:<snake 事件标签>:<组索引>:<hook 索引>。
    /// ⚠️ 位置键是 codex 的现状设计（源码自注 TODO durable id）：其他工具增删条目会让索引漂移、
    /// 信任失配（codex 视为 Modified → 跳过）。codexHooksInstalled 按当前真实位置复核，失配即报
    /// 未安装，重装自愈。
    static func codexHookStateKey(home: String, eventLabel: String, groupIndex: Int, hookIndex: Int) -> String {
        "\(codexHooksPath(home: home)):\(eventLabel):\(groupIndex):\(hookIndex)"
    }

    static func codexHookStateHeader(key: String) -> String {
        "[hooks.state.\"\(tomlEscaped(key))\"]"
    }

    /// 我们的 command 在事件数组里的位置（组索引 + 组内 hook 索引）；不存在返回 nil。
    static func commandPosition(_ groups: [Any], _ command: String) -> (group: Int, hook: Int)? {
        for (g, group) in groups.enumerated() {
            guard let inner = (group as? [String: Any])?["hooks"] as? [Any] else { continue }
            for (h, item) in inner.enumerated()
            where (item as? [String: Any])?["command"] as? String == command {
                return (g, h)
            }
        }
        return nil
    }

    /// hooks.json 深合并计划 + 按合并后真实位置算好的信任键/hash（config.toml 编辑与安装态检查共用）。
    /// 与 Claude settings.json 同策略：只追加我们的 entry（独立 matcher 组，不与 Otty 等共组），
    /// 已存在则原位沿用；用户内容一字不动。
    struct CodexHooksPlan {
        let plan: InstallPlan
        /// key → trusted_hash（key 已含事件标签与位置索引）
        let hashes: [String: String]
    }

    static func codexHooksPlanDetailed(home: String) throws -> CodexHooksPlan {
        let path = codexHooksPath(home: home)
        let before = try? String(contentsOfFile: path, encoding: .utf8)
        var obj: [String: Any] = [:]
        if let before {
            guard let dict = parseJSONDict(before) else { throw InstallerError.malformedJSON(path) }
            obj = dict
        }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        let command = awCodexHookCommand(home: home)
        var changed = false
        for event in codexHookEvents {
            var arr = hooks[event] as? [Any] ?? []
            if !containsCommand(arr, command) {
                arr.append(["hooks": [["type": "command", "command": command]]])
                hooks[event] = arr
                changed = true
            }
        }
        obj["hooks"] = hooks
        var hashes: [String: String] = [:]
        for event in codexHookEvents {
            guard let label = codexHookEventLabels[event] else { continue }
            let groups = hooks[event] as? [Any] ?? []
            guard let position = commandPosition(groups, command),
                  let group = groups[position.group] as? [String: Any],
                  let entry = (group["hooks"] as? [Any])?[position.hook] as? [String: Any],
                  let hash = codexHookTrustedHash(
                      eventLabel: label, entry: entry, matcher: group["matcher"] as? String)
            else { continue }
            hashes[codexHookStateKey(
                home: home, eventLabel: label,
                groupIndex: position.group, hookIndex: position.hook)] = hash
        }
        return CodexHooksPlan(
            plan: InstallPlan(
                path: path,
                before: before ?? "",
                after: changed ? serializeJSON(obj) : (before ?? serializeJSON(obj)),
                existedBefore: before != nil),
            hashes: hashes)
    }

    /// 在 config.toml 文本上确保各位置键的 trusted_hash：段已存在 → 原位替换/插入 trusted_hash 行
    ///（记录原行，卸载还原）；不存在 → 文件末尾追加段（记录确切字节，卸载摘除）。
    /// 追加 [section] 到 EOF 对任何合法 TOML 都安全（段落按路径寻址、顺序无关）。
    static func applyCodexHookTrust(
        to text: String, hashes: [String: String]
    ) -> (after: String, replacedLines: [String: String], appendedChunk: String?) {
        var lines = text.components(separatedBy: "\n")
        var replaced: [String: String] = [:]
        var appendLines: [String] = []
        for (key, hash) in hashes.sorted(by: { $0.key < $1.key }) { // 排序保证输出确定
            let trustLine = "trusted_hash = \"\(hash)\""
            if let header = codexHookStateSectionIndex(lines, key: key) {
                var i = header + 1
                var handled = false
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") { break }
                    if t.hasPrefix("trusted_hash") {
                        if lines[i] != trustLine {
                            replaced[key] = lines[i]
                            lines[i] = trustLine
                        }
                        handled = true
                        break
                    }
                    i += 1
                }
                if !handled {
                    replaced[key] = "" // 空串标记「原段无 trusted_hash 行」：卸载时删行而非还原
                    lines.insert(trustLine, at: header + 1)
                }
            } else {
                appendLines.append(codexHookStateHeader(key: key))
                appendLines.append(trustLine)
            }
        }
        var after = lines.joined(separator: "\n")
        var chunk: String?
        if !appendLines.isEmpty {
            var c = appendLines.joined(separator: "\n") + "\n"
            if !after.isEmpty && !after.hasSuffix("\n") { c = "\n" + c }
            chunk = c
            after += c
        }
        return (after, replaced, chunk)
    }

    /// 卸载侧逆操作：先按确切字节摘我们追加的 chunk（装→卸字节级还原的快路径），
    /// 剩余键逐个处理——还原被替换的原行 / 删除我们插入的行 / 整段摘除（codex 事后重排过文件的兜底）。
    static func removeCodexHookTrust(
        from text: String, keys: [String], appendedChunks: [String], replacedLines: [String: String]
    ) -> String {
        var result = text
        for chunk in appendedChunks {
            if let range = result.range(of: chunk) { result.removeSubrange(range) }
        }
        var lines = result.components(separatedBy: "\n")
        for key in keys {
            guard let header = codexHookStateSectionIndex(lines, key: key) else { continue }
            if let original = replacedLines[key] {
                var i = header + 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") { break }
                    if t.hasPrefix("trusted_hash") {
                        if original.isEmpty { lines.remove(at: i) } else { lines[i] = original }
                        break
                    }
                    i += 1
                }
            } else {
                lines.removeSubrange(header..<hookStateSectionEnd(lines, header: header))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 段落终点（exclusive）：走到下个 [section] 或 EOF，再把尾随空行退回去——
    /// EOF 前的空行是文件的末尾换行/段落间隔，吞掉它字节级还原就差一个 \n。
    private static func hookStateSectionEnd(_ lines: [String], header: Int) -> Int {
        var end = header + 1
        while end < lines.count {
            let t = lines[end].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { break }
            end += 1
        }
        while end - 1 > header, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return end
    }

    static func codexHookStateSectionIndex(_ lines: [String], key: String) -> Int? {
        let header = codexHookStateHeader(key: key)
        return lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == header }
    }

    /// 段内 trusted_hash 值（TOML basic string 的裸值，不含引号）；段或行不存在返回 nil。
    static func codexTrustedHashInConfig(_ lines: [String], key: String) -> String? {
        guard let header = codexHookStateSectionIndex(lines, key: key) else { return nil }
        var i = header + 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }
            if t.hasPrefix("trusted_hash"), let eq = t.firstIndex(of: "=") {
                let value = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return nil }
                return String(value.dropFirst().dropLast())
            }
            i += 1
        }
        return nil
    }

    /// codex 原生 hooks 是否完整安装：四事件条目都在 + config.toml 里对应位置键的 trusted_hash
    /// 与复刻算法一致。位置漂移/命令变更 → false → 设置页露「安装」入口，重装自愈。
    /// 用户在 codex /hooks 里 enabled=false 禁用我们不算未安装——尊重用户在 codex 侧的显式选择。
    public static func codexHooksInstalled(home: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: awCodexPath(home: home)),
              let hooksText = try? String(contentsOfFile: codexHooksPath(home: home), encoding: .utf8),
              let obj = parseJSONDict(hooksText) else { return false }
        let hooks = obj["hooks"] as? [String: Any] ?? [:]
        let command = awCodexHookCommand(home: home)
        let configText = (try? String(contentsOfFile: codexConfigPath(home: home), encoding: .utf8)) ?? ""
        let configLines = configText.components(separatedBy: "\n")
        for event in codexHookEvents {
            guard let label = codexHookEventLabels[event],
                  let groups = hooks[event] as? [Any],
                  let position = commandPosition(groups, command),
                  let group = groups[position.group] as? [String: Any],
                  let entry = (group["hooks"] as? [Any])?[position.hook] as? [String: Any],
                  let expected = codexHookTrustedHash(
                      eventLabel: label, entry: entry, matcher: group["matcher"] as? String),
                  codexTrustedHashInConfig(
                      configLines,
                      key: codexHookStateKey(
                          home: home, eventLabel: label,
                          groupIndex: position.group, hookIndex: position.hook)) == expected
            else { return false }
        }
        return true
    }

    /// `[features] hooks = false`（或 root 点键 `features.hooks = false`）显式关闭检测。
    /// 0.144 起 hooks 特性 stable 默认开启（不写即开），显式 false 是用户在 codex 侧的主动决定：
    /// 我们不越权改写（Otty 等所有 hooks 都因此停摆，不只我们），只在设置页露警示。
    public static func codexHooksFeatureDisabled(home: String) -> Bool {
        guard let text = try? String(contentsOfFile: codexConfigPath(home: home), encoding: .utf8) else {
            return false
        }
        var section: String?
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                section = t
                continue
            }
            let compact = t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
            if section == "[features]" && compact.hasPrefix("hooks=") {
                return compact.hasPrefix("hooks=false")
            }
            if section == nil && compact.hasPrefix("features.hooks=") {
                return compact.hasPrefix("features.hooks=false")
            }
        }
        return false
    }

    /// 行级编辑计划 + 卸载所需记录。不解析整份 TOML：注释与未知段落原样保留。
    struct CodexPlan {
        let plan: InstallPlan
        let originalLine: String?  // 被替换的原 notify 行（卸载时精确还原）
        let originalNotify: [String]?
        let insertedChunk: String? // 追加/插入的确切字节（卸载时精确摘除）
    }

    static func codexPlanDetailed(home: String) throws -> CodexPlan {
        let path = codexConfigPath(home: home)
        let before = try? String(contentsOfFile: path, encoding: .utf8)
        let text = before ?? ""
        let ourLine = "notify = \(tomlStringArray([awCodexPath(home: home)]))" // notify 不展开 ~，必须绝对路径
        var lines = text.components(separatedBy: "\n")

        func plan(_ after: String) -> InstallPlan {
            InstallPlan(path: path, before: text, after: after, existedBefore: before != nil)
        }

        let scan = scanRoot(lines)
        // root 区有未闭合的多行值（本就非法的 TOML）：行级编辑必写坏文件，宁可中止（硬性不变量 4）
        if scan.unclosed { throw InstallerError.malformedTOML(path) }

        if let range = scan.notifyRange {
            let original = lines[range].joined(separator: "\n") // 多行数组按值整体记录（卸载原字节还原）
            guard let notify = parseTomlStringArray(original) else { throw InstallerError.malformedTOML(path) }
            if notify.first == awCodexPath(home: home) {
                return CodexPlan(plan: plan(text), originalLine: nil, originalNotify: nil, insertedChunk: nil) // 已装，幂等
            }
            lines.replaceSubrange(range, with: [ourLine]) // 多行值整体换成单行，不留悬空的 "…" 与 ]
            return CodexPlan(plan: plan(lines.joined(separator: "\n")), originalLine: original,
                             originalNotify: sanitizedCodexOriginalNotify(notify, home: home),
                             insertedChunk: nil)
        }
        // 无 root notify 行：root 键必须在首个 [section] 之前，有段落就插在段落前，
        // 否则追加到文件末尾。section 起点用括号感知的扫描结果——
        // 嵌套多行数组的续行（如 `  ["a"],`）不是 section，notify 不能插进用户数组中间。
        if let s = scan.firstSectionIndex {
            lines.insert(ourLine, at: s)
            return CodexPlan(plan: plan(lines.joined(separator: "\n")), originalLine: nil,
                             originalNotify: nil, insertedChunk: ourLine + "\n")
        }
        if text.isEmpty {
            return CodexPlan(plan: plan(ourLine + "\n"), originalLine: nil,
                             originalNotify: nil, insertedChunk: ourLine + "\n")
        }
        if text.hasSuffix("\n") {
            return CodexPlan(plan: plan(text + ourLine + "\n"), originalLine: nil,
                             originalNotify: nil, insertedChunk: ourLine + "\n")
        }
        return CodexPlan(plan: plan(text + "\n" + ourLine + "\n"), originalLine: nil,
                         originalNotify: nil, insertedChunk: "\n" + ourLine + "\n")
    }

    /// 组合安装计划：config.toml（notify 顶位 + [hooks.state] 信任）与 hooks.json（四事件条目）。
    /// 两文件的 before/after 都在确认 sheet 里展示（硬性不变量 4）；任一未变照常返回（changed=false）。
    struct CodexCombinedPlan {
        let notify: CodexPlan
        let hooksPlan: CodexHooksPlan
        let configAfter: String                   // notify 编辑之上再叠 hooks.state 信任
        let trustReplacedLines: [String: String]  // key → 被替换的原 trusted_hash 行（"" = 我们插入的新行）
        let trustAppendedChunk: String?           // 追加到 EOF 的确切字节
        var configChanged: Bool { configAfter != notify.plan.before }
    }

    static func codexCombinedPlanDetailed(home: String) throws -> CodexCombinedPlan {
        let notify = try codexPlanDetailed(home: home)
        let hooksPlan = try codexHooksPlanDetailed(home: home)
        let trust = applyCodexHookTrust(to: notify.plan.after, hashes: hooksPlan.hashes)
        return CodexCombinedPlan(
            notify: notify, hooksPlan: hooksPlan, configAfter: trust.after,
            trustReplacedLines: trust.replacedLines, trustAppendedChunk: trust.appendedChunk)
    }

    /// [config.toml 计划, hooks.json 计划]（顺序固定；设置页确认 sheet 逐文件展示）。
    public static func codexPlans(home: String) throws -> [InstallPlan] {
        let combined = try codexCombinedPlanDetailed(home: home)
        return [
            InstallPlan(
                path: combined.notify.plan.path,
                before: combined.notify.plan.before,
                after: combined.configAfter,
                existedBefore: combined.notify.plan.existedBefore),
            combined.hooksPlan.plan,
        ]
    }

    /// 兼容旧调用（Checks CLI 等）：config.toml 一侧的组合计划。
    public static func codexPlan(home: String) throws -> InstallPlan {
        try codexPlans(home: home)[0]
    }

    public static func installCodex(
        home: String, expectedBefore: String? = nil, expectedHooksBefore: String? = nil
    ) throws {
        let combined = try codexCombinedPlanDetailed(home: home)
        if let expectedBefore, combined.notify.plan.before != expectedBefore {
            throw InstallerError.configurationChanged(combined.notify.plan.path)
        }
        if let expectedHooksBefore, combined.hooksPlan.plan.before != expectedHooksBefore {
            throw InstallerError.configurationChanged(combined.hooksPlan.plan.path)
        }
        let configChanged = combined.configChanged
        let hooksChanged = combined.hooksPlan.plan.changed
        guard configChanged || hooksChanged else { return } // 幂等：已装就一字不动
        // 状态记录是「撤销我们累计足迹」的账本，重装必须【合并】而非覆盖：
        // hooks 位置漂移后的重装 notify 通常没动，若整体覆盖会把首次安装的 originalLine/
        // insertedChunk/备份指针弄丢，之后卸载就还原不了用户原始 notify 行。
        let previousState = loadState(home: home)
        var codexState = (previousState["codex"] as? [String: Any]) ?? [:]
        if codexState["existed"] == nil { codexState["existed"] = combined.notify.plan.existedBefore }
        if configChanged && combined.notify.plan.existedBefore && codexState["backup"] == nil {
            codexState["backup"] = try writeBackup(combined.notify.plan.before, name: "config.toml", home: home)
        }
        let notifyTouched = combined.notify.plan.after != combined.notify.plan.before
        if notifyTouched { // 本次真动了 notify（首装/重新接管）才更新还原记录
            if let original = combined.notify.originalLine {
                codexState["originalLine"] = original
                codexState.removeValue(forKey: "insertedChunk")
            } else if let chunk = combined.notify.insertedChunk {
                codexState["insertedChunk"] = chunk
                codexState.removeValue(forKey: "originalLine")
            }
        }
        if codexState["hooksExisted"] == nil { codexState["hooksExisted"] = combined.hooksPlan.plan.existedBefore }
        if hooksChanged && combined.hooksPlan.plan.existedBefore && codexState["hooksBackup"] == nil {
            codexState["hooksBackup"] = try writeBackup(combined.hooksPlan.plan.before, name: "hooks.json", home: home)
        }
        let previousKeys = codexState["hookStateKeys"] as? [String] ?? []
        codexState["hookStateKeys"] = Set(previousKeys).union(combined.hooksPlan.hashes.keys).sorted()
        var trustChunks = codexState["hookTrustChunks"] as? [String] ?? []
        if let chunk = combined.trustAppendedChunk { trustChunks.append(chunk) }
        if !trustChunks.isEmpty { codexState["hookTrustChunks"] = trustChunks }
        var trustReplaced = codexState["hookTrustReplaced"] as? [String: String] ?? [:]
        for (key, original) in combined.trustReplacedLines where trustReplaced[key] == nil {
            trustReplaced[key] = original // 首次记录才是真原行（后续替换的是我们自己写的行）
        }
        if !trustReplaced.isEmpty { codexState["hookTrustReplaced"] = trustReplaced }
        let previousChain = try? Data(contentsOf: URL(fileURLWithPath: codexChainPath(home: home)))
        var configWritten = false
        do {
            try updateState(home: home) { $0["codex"] = codexState }
            if notifyTouched { // notify 没动就别碰 chain——hooks-only 重装误删 chain = 卸载还原断链
                if let notify = combined.notify.originalNotify {
                    try writeCodexNotifyChain(CodexNotifyChain(originalNotify: notify), home: home)
                } else {
                    try? FileManager.default.removeItem(atPath: codexChainPath(home: home))
                }
            }
            if configChanged {
                try writeFile(combined.configAfter, path: combined.notify.plan.path)
                configWritten = true
            }
            if hooksChanged {
                try writeFile(combined.hooksPlan.plan.after, path: combined.hooksPlan.plan.path)
            }
        } catch {
            try? writeState(previousState, home: home)
            restoreCodexChain(previousChain, home: home)
            if configWritten { // hooks.json 写失败时尽力回滚 config.toml，不留半套安装
                if combined.notify.plan.existedBefore {
                    try? writeFile(combined.notify.plan.before, path: combined.notify.plan.path)
                } else {
                    try? FileManager.default.removeItem(atPath: combined.notify.plan.path)
                }
            }
            throw error
        }
    }

    /// 卸载：按状态文件记录精确还原——替换过的整行换回原行；追加过的按确切字节摘除；
    /// 无记录时兜底删掉指向我们的 notify 行。原生 hooks 一并摘除：hooks.json 摘我们的条目
    ///（其余保留，语义等于备份则原字节还原），config.toml 摘 [hooks.state] 信任段。
    /// 原本无此文件且摘净后为空 → 删除文件。
    public static func uninstallCodex(home: String) throws {
        let state = loadState(home: home)["codex"] as? [String: Any]
        // 先处理 hooks.json：位置键必须在摘条目【之前】按当前真实位置算出（state 缺失时的兜底键）
        let fallbackKeys = try uninstallCodexHooksJSON(home: home, state: state)

        let path = codexConfigPath(home: home)
        guard FileManager.default.fileExists(atPath: path) else {
            cleanupCodexInstallMetadata(home: home)
            return
        }
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let our = awCodexPath(home: home)
        let chain = readCodexNotifyChain(home: home)
        var result = current

        if let original = state?["originalLine"] as? String {
            var lines = result.components(separatedBy: "\n")
            if let range = scanRoot(lines).notifyRange,
               lines[range].joined(separator: "\n").contains(our) {
                lines.replaceSubrange(range, with: original.components(separatedBy: "\n"))
                result = lines.joined(separator: "\n")
            }
        } else if let notify = chain?.notify {
            var lines = result.components(separatedBy: "\n")
            if let range = scanRoot(lines).notifyRange,
               lines[range].joined(separator: "\n").contains(our) {
                lines.replaceSubrange(range, with: ["notify = \(tomlStringArray(notify))"])
                result = lines.joined(separator: "\n")
            }
        } else if let chunk = state?["insertedChunk"] as? String, let range = result.range(of: chunk) {
            result.removeSubrange(range)
        } else {
            var lines = result.components(separatedBy: "\n")
            if let range = scanRoot(lines).notifyRange,
               lines[range].joined(separator: "\n").contains(our) {
                lines.removeSubrange(range)
                result = lines.joined(separator: "\n")
            }
        }

        result = removeCodexHookTrust(
            from: result,
            keys: (state?["hookStateKeys"] as? [String]) ?? fallbackKeys.keys,
            appendedChunks: (state?["hookTrustChunks"] as? [String]) ?? [],
            replacedLines: (state?["hookTrustReplaced"] as? [String: String]) ?? [:])
        // 兜底清扫：位置漂移后重装会在旧位置键留下「携带我们 hash」的孤儿信任段（对 codex 无害
        // 但属于我们的残留物）。只清 hash 值属于我们的段——Otty 等其他工具的 hash 算自它们的
        // command，绝不会命中。
        result = sweepCodexHookTrustSections(
            from: result, hooksPath: codexHooksPath(home: home), ourHashes: fallbackKeys.hashes)

        let existed = state?["existed"] as? Bool ?? true
        if !existed && result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(atPath: path)
            cleanupCodexInstallMetadata(home: home)
            return
        }
        try writeFile(result, path: path)
        cleanupCodexInstallMetadata(home: home)
    }

    /// hooks.json 摘除我们的条目（其余一字不动）。返回摘除前按当前位置算出的 hooks.state 键
    ///（config.toml 清理在 state 记录缺失时兜底）与我们条目的 hash 集合（孤儿段清扫判据）。
    /// 字节级还原策略同 uninstallClaude：摘后语义等于安装备份 → 原字节写回；
    /// 无我们的条目 → 不碰文件；原本无文件且摘净 → 删除。
    static func uninstallCodexHooksJSON(
        home: String, state: [String: Any]?
    ) throws -> (keys: [String], hashes: Set<String>) {
        let command = awCodexHookCommand(home: home)
        // 默认形态（我们写入的 {type,command}）的四个 hash 永远进清扫集：
        // hooks.json 被整个删掉时也能清 config.toml 里的残留信任段
        var hashes = Set(codexHookEvents.compactMap { event -> String? in
            guard let label = codexHookEventLabels[event] else { return nil }
            return codexHookTrustedHash(eventLabel: label, entry: ["type": "command", "command": command])
        })
        let path = codexHooksPath(home: home)
        guard let current = try? String(contentsOfFile: path, encoding: .utf8) else { return ([], hashes) }
        guard var obj = parseJSONDict(current) else { throw InstallerError.malformedJSON(path) }
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var keys: [String] = []
        var removedAny = false
        for event in codexHookEvents {
            guard let label = codexHookEventLabels[event],
                  var arr = hooks[event] as? [Any] else { continue }
            if let position = commandPosition(arr, command) {
                keys.append(codexHookStateKey(
                    home: home, eventLabel: label,
                    groupIndex: position.group, hookIndex: position.hook))
                if let group = arr[position.group] as? [String: Any],
                   let entry = (group["hooks"] as? [Any])?[position.hook] as? [String: Any],
                   let hash = codexHookTrustedHash(
                       eventLabel: label, entry: entry, matcher: group["matcher"] as? String) {
                    hashes.insert(hash) // 条目被手动加过 timeout 等字段时 hash 与默认形态不同
                }
            }
            arr = arr.compactMap { group -> Any? in
                guard var g = group as? [String: Any], let inner = g["hooks"] as? [Any] else { return group }
                let filtered = inner.filter { item in
                    (item as? [String: Any])?["command"] as? String != command
                }
                guard filtered.count != inner.count else { return group }
                removedAny = true
                if filtered.isEmpty { return nil } // 摘空的组整个撤掉（就是我们装的那个）
                g["hooks"] = filtered
                return g
            }
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        guard removedAny else { return (keys, hashes) } // 没有我们的条目：用户文件一字不动
        if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }

        let existed = state?["hooksExisted"] as? Bool ?? true
        if !existed && obj.isEmpty {
            try FileManager.default.removeItem(atPath: path)
            return (keys, hashes)
        }
        if let backupPath = state?["hooksBackup"] as? String,
           let backupText = try? String(contentsOfFile: backupPath, encoding: .utf8),
           let backupObj = parseJSONDict(backupText),
           NSDictionary(dictionary: obj).isEqual(to: backupObj) {
            try writeFile(backupText, path: path) // 语义相等 → 字节级还原
            return (keys, hashes)
        }
        try writeFile(serializeJSON(obj), path: path)
        return (keys, hashes)
    }

    /// 清扫 config.toml 里「键在我们 hooks.json 命名空间下、trusted_hash 值属于我们」的信任段。
    /// 只认 hash 值：位置漂移留下的旧键必然还带着我们的 hash；其他工具（如 Otty）的 hash
    /// 算自它们自己的 command，永不误伤。
    static func sweepCodexHookTrustSections(
        from text: String, hooksPath: String, ourHashes: Set<String>
    ) -> String {
        guard !ourHashes.isEmpty else { return text }
        let headerPrefix = "[hooks.state.\"\(tomlEscaped(hooksPath)):"
        var lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(headerPrefix) else {
                i += 1
                continue
            }
            let end = hookStateSectionEnd(lines, header: i)
            var sectionHash: String?
            for line in lines[(i + 1)..<end] {
                let body = line.trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("trusted_hash"), let eq = body.firstIndex(of: "=") {
                    let value = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                        sectionHash = String(value.dropFirst().dropLast())
                    }
                }
            }
            if let sectionHash, ourHashes.contains(sectionHash) {
                lines.removeSubrange(i..<end)
            } else {
                i = end
            }
        }
        return lines.joined(separator: "\n")
    }

    /// root 区（首个 [section] 之前）内首个 `notify =` 行；注释行（# 开头）不算，
    /// 多行数组的续行不算（括号感知见 scanRoot）。
    public static func rootNotifyLineIndex(_ lines: [String]) -> Int? {
        scanRoot(lines).notifyRange?.lowerBound
    }

    /// root 区一趟扫描结果：notify 键的整个行范围（多行数组时 end > start）、
    /// 首个真 [section] 行、未闭合多行值标记（非法 TOML，编辑必须中止）。
    struct RootScan {
        var notifyRange: ClosedRange<Int>?
        var firstSectionIndex: Int?
        var unclosed: Bool
    }

    /// root 区括号感知扫描：多行值按键整体吞行到括号配平，续行（如 `  ["a"],`、`]`）
    /// 不会被误判成 section 起点或独立键——单行替换多行数组会留悬空行、写坏 TOML。
    /// ponytail: 不识别 """ 多行字符串——其内不配平的 [ ] 会误计成 unclosed 而拒装（安全侧：宁可拒装不写坏）。
    static func scanRoot(_ lines: [String]) -> RootScan {
        var scan = RootScan(notifyRange: nil, firstSectionIndex: nil, unclosed: false)
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { // 只会在值边界（配平处）走到这里，是真 section 起点
                scan.firstSectionIndex = i
                return scan
            }
            let start = i
            var depth = bracketDelta(lines[i])
            while depth > 0 && i + 1 < lines.count { // 多行值：吞续行直到括号配平
                i += 1
                depth += bracketDelta(lines[i])
            }
            if depth != 0 { // 到 EOF 仍不配平 / 多出的 ]：非法 TOML
                scan.unclosed = true
                return scan
            }
            if scan.notifyRange == nil, t.hasPrefix("notify"),
               t.dropFirst("notify".count).trimmingCharacters(in: .whitespaces).hasPrefix("=") {
                scan.notifyRange = start...i
            }
            i += 1
        }
        return scan
    }

    /// 单行 [ ] 净增量；字符串字面量（"…" 含 \" 转义、'…' 无转义）与 # 注释内的括号不计。
    static func bracketDelta(_ line: String) -> Int {
        var delta = 0
        var inBasic = false
        var inLiteral = false
        var escaped = false
        for ch in line {
            if inBasic {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inBasic = false }
                continue
            }
            if inLiteral {
                if ch == "'" { inLiteral = false }
                continue
            }
            switch ch {
            case "\"": inBasic = true
            case "'": inLiteral = true
            case "#": return delta // 注释起，行内其后不计
            case "[": delta += 1
            case "]": delta -= 1
            default: break
            }
        }
        return delta
    }

    static func parseTomlStringArray(_ assignment: String) -> [String]? {
        guard let equals = assignment.firstIndex(of: "=") else { return nil }
        let value = String(assignment[assignment.index(after: equals)...])
        var parser = TomlStringArrayParser(value)
        return parser.parse()
    }

    static func tomlStringArray(_ values: [String]) -> String {
        "[" + values.map { "\"\(tomlEscaped($0))\"" }.joined(separator: ", ") + "]"
    }

    private static func tomlEscaped(_ value: String) -> String {
        var out = ""
        for ch in value {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out
    }

    private struct TomlStringArrayParser {
        private let chars: [Character]
        private var index = 0

        init(_ text: String) {
            chars = Array(text)
        }

        mutating func parse() -> [String]? {
            skipTrivia()
            guard consume("[") else { return nil }
            var values: [String] = []
            skipTrivia()
            if consume("]") {
                skipTrivia()
                return isAtEnd ? values : nil
            }
            while true {
                skipTrivia()
                guard let string = parseString() else { return nil }
                values.append(string)
                skipTrivia()
                if consume(",") {
                    skipTrivia()
                    if consume("]") { break }
                    continue
                }
                guard consume("]") else { return nil }
                break
            }
            skipTrivia()
            return isAtEnd ? values : nil
        }

        private var isAtEnd: Bool { index >= chars.count }

        private mutating func consume(_ ch: Character) -> Bool {
            guard !isAtEnd, chars[index] == ch else { return false }
            index += 1
            return true
        }

        private mutating func skipTrivia() {
            while !isAtEnd {
                if chars[index].isWhitespace {
                    index += 1
                    continue
                }
                if chars[index] == "#" {
                    while !isAtEnd, chars[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
        }

        private mutating func parseString() -> String? {
            if consume("\"") { return parseBasicString() }
            if consume("'") { return parseLiteralString() }
            return nil
        }

        private mutating func parseBasicString() -> String? {
            var out = ""
            while !isAtEnd {
                let ch = chars[index]
                index += 1
                if ch == "\"" { return out }
                if ch != "\\" {
                    out.append(ch)
                    continue
                }
                guard !isAtEnd else { return nil }
                let escaped = chars[index]
                index += 1
                switch escaped {
                case "b": out.append("\u{08}")
                case "t": out.append("\t")
                case "n": out.append("\n")
                case "f": out.append("\u{0C}")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default:
                    out.append(escaped)
                }
            }
            return nil
        }

        private mutating func parseLiteralString() -> String? {
            var out = ""
            while !isAtEnd {
                let ch = chars[index]
                index += 1
                if ch == "'" { return out }
                out.append(ch)
            }
            return nil
        }
    }

    // MARK: - 共用底座

    private static func parseJSONDict(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return parsed as? [String: Any]
    }

    private static func readJSONDict(_ path: String) -> [String: Any]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parseJSONDict(text)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func serializeJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private static func writeCodexNotifyChain(_ chain: CodexNotifyChain, home: String) throws {
        try FileManager.default.createDirectory(atPath: supportDir(home: home), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDir(home: home))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(chain)
        let path = codexChainPath(home: home)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func containsCommand(_ groups: [Any], _ command: String) -> Bool {
        for group in groups {
            guard let g = group as? [String: Any], let inner = g["hooks"] as? [Any] else { continue }
            for item in inner where (item as? [String: Any])?["command"] as? String == command {
                return true
            }
        }
        return false
    }

    private static func normalizeClaudeHookCommands(_ groups: [Any], legacy: String, target: String)
        -> (groups: [Any], containsTarget: Bool, changed: Bool) {
        var containsTarget = containsCommand(groups, target)
        var convertedLegacy = false
        var changed = false
        let normalized = groups.compactMap { group -> Any? in
            guard var g = group as? [String: Any], let inner = g["hooks"] as? [Any] else { return group }
            var newInner: [Any] = []
            var groupChanged = false
            for item in inner {
                guard var hook = item as? [String: Any],
                      let command = hook["command"] as? String,
                      command == legacy else {
                    newInner.append(item)
                    continue
                }
                changed = true
                groupChanged = true
                if containsTarget || convertedLegacy {
                    continue
                }
                hook["command"] = target
                newInner.append(hook)
                containsTarget = true
                convertedLegacy = true
            }
            guard groupChanged else { return group }
            if newInner.isEmpty { return nil }
            g["hooks"] = newInner
            return g
        }
        return (normalized, containsTarget, changed)
    }

    /// Claude hook `command` 是 shell command 字符串；Application Support 路径含空格，必须 shell quote。
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func writeFile(_ content: String, path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 备份到 backups/<时间戳>-<名>；同秒重名自动加序号。返回备份路径。
    private static func writeBackup(_ content: String, name: String, home: String) throws -> String {
        let dir = backupsDir(home: home)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        var path = dir + "/\(stamp)-\(name)"
        var counter = 2
        while FileManager.default.fileExists(atPath: path) {
            path = dir + "/\(stamp)-\(counter)-\(name)"
            counter += 1
        }
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private static func loadState(home: String) -> [String: Any] {
        readJSONDict(stateFilePath(home: home)) ?? [:]
    }

    private static func updateState(home: String, _ mutate: (inout [String: Any]) -> Void) throws {
        var state = loadState(home: home)
        mutate(&state)
        try writeState(state, home: home)
    }

    private static func writeState(_ state: [String: Any], home: String) throws {
        try writeFile(serializeJSON(state), path: stateFilePath(home: home))
    }

    private static func restoreCodexChain(_ data: Data?, home: String) {
        let path = codexChainPath(home: home)
        guard let data else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        try? FileManager.default.createDirectory(atPath: supportDir(home: home), withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private static func cleanupCodexInstallMetadata(home: String) {
        try? updateState(home: home) { $0.removeValue(forKey: "codex") }
        try? FileManager.default.removeItem(atPath: codexChainPath(home: home))
    }
}

// MARK: - 行级 diff（安装确认 sheet 用）

public enum DiffLineKind { case context, added, removed }

public struct DiffLine: Equatable {
    public let kind: DiffLineKind
    public let text: String

    public init(kind: DiffLineKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// 全文行级 diff（配置文件都很小，直接 LCS 全量展示，不做 hunk）。
/// ponytail: O(n·m) DP，>500×500 行退化为整删整加——配置文件到不了这个量级。
public func lineDiff(before: String, after: String) -> [DiffLine] {
    let a = before.isEmpty ? [] : before.components(separatedBy: "\n")
    let b = after.isEmpty ? [] : after.components(separatedBy: "\n")
    guard a.count * b.count <= 250_000 else {
        return a.map { DiffLine(kind: .removed, text: $0) } + b.map { DiffLine(kind: .added, text: $0) }
    }
    // LCS 长度表
    var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
        for j in stride(from: b.count - 1, through: 0, by: -1) {
            dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
        }
    }
    var lines: [DiffLine] = []
    var i = 0, j = 0
    while i < a.count && j < b.count {
        if a[i] == b[j] {
            lines.append(DiffLine(kind: .context, text: a[i]))
            i += 1
            j += 1
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            lines.append(DiffLine(kind: .removed, text: a[i]))
            i += 1
        } else {
            lines.append(DiffLine(kind: .added, text: b[j]))
            j += 1
        }
    }
    while i < a.count { lines.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
    while j < b.count { lines.append(DiffLine(kind: .added, text: b[j])); j += 1 }
    return lines
}

/// cwd 末两级路径（面板行展示）："/Users/x/a/b" → "a/b"；不足两级原样。
public func lastTwoPathComponents(_ path: String) -> String {
    let parts = path.split(separator: "/")
    guard parts.count >= 2 else { return path }
    return parts.suffix(2).joined(separator: "/")
}
