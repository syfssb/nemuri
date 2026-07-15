import Foundation

/// 解析 `pmset -g` 全文：定位 SleepDisabled 行取 0/1，容忍任意空白/制表符。
/// 缺失该行或值非 0/1 时返回 nil。
public func parseSleepDisabled(from output: String) -> Bool? {
    for line in output.split(whereSeparator: \.isNewline) {
        let tokens = line.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2, tokens[0] == "SleepDisabled" else { continue }
        switch tokens[1] {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }
    return nil
}

/// 电量保护默认下限（%）：靠电池且低于此值时放行休眠，避免为了跑 agent 把电耗干。
public let batteryFloorPercent = 20

/// 电量保护判定（纯函数，Checks 有断言）：仅「电池供电 + 百分比严格低于下限」才放行休眠。
/// percent 读不到（nil）时不动作——保护动作宁可少触发，也不能凭空杀掉用户会话。
public func shouldReleaseSleep(isOnBattery: Bool, percent: Int?, floor: Int) -> Bool {
    guard isOnBattery, let percent else { return false }
    return percent < floor
}

/// Helper 哨兵自检判定（B2 兜底强化，纯函数，Checks 有断言）：60s 常驻自检 timer 用它决定
/// 是否重试恢复休眠，覆盖 restoreSleep 单发失败的两条路径——看门狗到点 pmset 失败、开机兜底
/// pmset 失败（此前都只 log 一条，disablesleep=1 永久残留，违反不变量 1）。
/// - connectionsEmpty：有活跃 XPC 连接 = app 正在看护，禁休眠是本意，绝不动它。
/// - watchdogPending：连接刚断、15s 宽限倒计时在途 → 先交给看门狗，自检不提前吃掉宽限
///   （宽限语义不变：期间新连接可取消恢复）；看门狗到点后无论成败都会置 nil，失败由下一拍自检接手。
/// - sentinelOwned：哨兵仍在 = 禁休眠由本产品设置且尚未恢复成功（restoreSleep 幂等，重试无害）。
public func sentinelSelfCheckShouldRestore(connectionsEmpty: Bool, watchdogPending: Bool, sentinelOwned: Bool) -> Bool {
    connectionsEmpty && !watchdogPending && sentinelOwned
}

/// B3③：OFF 态进程扫描的最小间隔（秒）。OFF 只预热 CPU 基线/记录、不发布不保醒——没必要
/// 每 5s 全量递归扫描（8000+ 文件的 projects/rollouts 树，与「不发烫不耗电」卖点相悖）。
public let offScanIntervalSeconds: TimeInterval = 30

/// 进程扫描节流判定（纯函数，Checks 有断言；NemuriApp.refresh 使用）。
/// - watching（Agent Mode 非 OFF）：全速，每拍（5s）都扫——检测时效语义不变。
/// - OFF：距上次扫描不足 offScanIntervalSeconds 就跳过本拍；从未扫过（nil）先扫一拍预热。
///   注意只降扫描频率：pmset 轮询/外部收敛/心跳仍 5s 一拍，OFF 期间 hook 事件照记（socket 独立）。
public func shouldHeuristicScan(watching: Bool, lastScanAt: Date?, now: Date) -> Bool {
    if watching { return true }
    guard let lastScanAt else { return true }
    return now.timeIntervalSince(lastScanAt) >= offScanIntervalSeconds
}

/// 一次命令执行的结果（stderr 并入 stdout，便于呈现 pmset 的报错）。
public struct PmsetResult {
    public let exitCode: Int32
    public let stdout: String
}

/// 封装 pmset 两条命令。同步阻塞，调用方必须放后台/串行队列，绝不能在主线程跑。
public enum PmsetRunner {
    /// /usr/bin/pmset -a disablesleep 1|0
    /// M1 起写路径只有 root 特权助手调用（root 直跑，无 sudo）；app 侧一律走 XPC（HelperClient）。
    public static func setSleepDisabled(_ disabled: Bool) -> PmsetResult {
        run("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    }

    /// /usr/bin/pmset -g（状态唯一真相源，由 parseSleepDisabled 解析）
    public static func readPowerSettings() -> PmsetResult {
        run("/usr/bin/pmset", ["-g"])
    }

    private static func run(_ path: String, _ arguments: [String]) -> PmsetResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path) // 一律绝对路径，不查 PATH
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return PmsetResult(exitCode: -1, stdout: "\(error)")
        }
        // 必须先读完管道再 waitUntilExit：反过来会在子进程写满管道缓冲时互相死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return PmsetResult(
            exitCode: process.terminationStatus,
            stdout: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
