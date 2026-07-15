import Foundation
import Darwin
import os
import AwakeCore
import AwakeShared

// Nemuri 特权助手（root LaunchDaemon，SMAppService 注册）。
// 唯一职责：执行 pmset disablesleep + 永不卡死看门狗。
// 「永不卡死」= app 崩溃/被杀/重启/卸载后，disablesleep 都必须自动回到 0（下有四条恢复路径）。
// 硬性不变量 2：零网络、零文件读写（哨兵除外）、零多余能力——root 面越小越可审计。

private let log = Logger(subsystem: "app.nemuri.helper", category: "helper")

/// 全部可变状态（连接计数、看门狗定时器、pmset 执行）都在这条串行队列上动。
private let queue = DispatchQueue(label: "app.nemuri.helper.state")

private let sentinelURL = URL(fileURLWithPath: AwakeIPC.sentinelPath)

private func ensureSentinelDirectory() throws {
    let dir = sentinelURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755],
        ofItemAtPath: dir.path
    )
}

private func sentinelOwnedByHelper() -> Bool {
    var info = stat()
    guard lstat(AwakeIPC.sentinelPath, &info) == 0 else { return false }
    // 兼容旧版本写出的 0644 哨兵：它仍然是 root 创建的普通文件，应触发恢复并删除。
    // 新版本写入继续强制 0600；这里只拒绝非 root、非普通文件、或 group/other 可写的漂移文件。
    return info.st_uid == 0
        && (info.st_mode & S_IFMT) == S_IFREG
        && (info.st_mode & 0o022) == 0
}

/// pmset 0 + 成功后删哨兵（幂等）。看门狗两条路径与正常关闭共用。
/// 恢复顺序：先 pmset 0 成功后再删哨兵——中途崩溃则下次开机凭残留哨兵再恢复一次，幂等无害。
@discardableResult
private func restoreSleep(reason: String) -> Int32 {
    let result = PmsetRunner.setSleepDisabled(false)
    if result.exitCode == 0 {
        try? FileManager.default.removeItem(at: sentinelURL)
        log.notice("恢复休眠成功（\(reason, privacy: .public)）")
    } else {
        log.error("恢复休眠失败（\(reason, privacy: .public)）exit=\(result.exitCode) output=\(result.stdout, privacy: .public)")
    }
    return result.exitCode
}

final class HelperService: NSObject, AwakeHelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Int32) -> Void) {
        queue.async {
            guard disabled else {
                reply(restoreSleep(reason: "XPC 请求恢复"))
                return
            }
            // 顺序不能反：先写哨兵再 exec pmset 1——中途崩溃只会多一次无害的开机恢复；
            // 反过来（先 pmset 后哨兵）崩溃会留下无人认领的 disablesleep=1。
            do {
                try ensureSentinelDirectory()
                try Data().write(to: sentinelURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o600],
                    ofItemAtPath: sentinelURL.path
                )
            } catch {
                log.error("哨兵写入失败，拒绝禁休眠：\(String(describing: error), privacy: .public)")
                reply(-1) // 保险装不上就不开危险开关（不变量 1 优先于功能）
                return
            }
            let result = PmsetRunner.setSleepDisabled(true)
            if result.exitCode == 0 {
                log.notice("禁休眠已生效")
            } else {
                // pmset 失败 → 哨兵成了孤儿，删掉避免下次开机白跑一趟恢复
                try? FileManager.default.removeItem(at: sentinelURL)
                log.error("禁休眠失败 exit=\(result.exitCode) output=\(result.stdout, privacy: .public)")
            }
            reply(result.exitCode)
        }
    }

    func currentState(reply: @escaping (Int32, Bool) -> Void) {
        queue.async {
            let result = PmsetRunner.readPowerSettings()
            guard result.exitCode == 0, let disabled = parseSleepDisabled(from: result.stdout) else {
                reply(result.exitCode == 0 ? -1 : result.exitCode, false)
                return
            }
            reply(0, disabled)
        }
    }

    func ping(reply: @escaping () -> Void) {
        reply()
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    /// 活跃 XPC 连接（只在 queue 上碰）
    private var connections = Set<ObjectIdentifier>()
    /// 看门狗路径 1 的宽限定时器（只在 queue 上碰）
    private var watchdog: DispatchWorkItem?
    /// 哨兵自检 timer（B2 兜底强化，常驻 60s 一拍，handler 在 queue 上）：看门狗到点与开机兜底
    /// 的 restoreSleep 原本都是单发，pmset 一次失败只 log 一条 → disablesleep=1 永久残留。
    /// 一个 timer 同时兜住这两条失败路径：判定是 AwakeCore 纯函数 sentinelSelfCheckShouldRestore
    ///（NemuriChecks 钉死真值表，活体验收 accept-m1.sh retry-test），restoreSleep 幂等；
    /// 不新增 XPC 方法、不扩大 root 能力面（不变量 2），常态只是每分钟一次 lstat。
    private let sentinelTimer: DispatchSourceTimer

    override init() {
        sentinelTimer = DispatchSource.makeTimerSource(queue: queue)
        super.init()
        sentinelTimer.schedule(
            deadline: .now() + AwakeIPC.sentinelSelfCheckIntervalSeconds,
            repeating: AwakeIPC.sentinelSelfCheckIntervalSeconds,
            leeway: .seconds(5))
        sentinelTimer.setEventHandler { [weak self] in self?.sentinelSelfCheck() }
        sentinelTimer.resume()
    }

    /// 自检一拍（queue 上）：无连接、无宽限在途、哨兵仍在 → 重试恢复。宽限在途时不动
    ///（15s 宽限语义不变，先交给看门狗；它到点后无论成败都置 watchdog=nil，失败由这里接手）。
    private func sentinelSelfCheck() {
        guard sentinelSelfCheckShouldRestore(
            connectionsEmpty: connections.isEmpty,
            watchdogPending: watchdog != nil,
            sentinelOwned: sentinelOwnedByHelper()) else { return }
        log.notice("哨兵自检：无连接且哨兵仍在，重试恢复休眠")
        restoreSleep(reason: "哨兵自检兜底")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // 对端校验由 NSXPCListener.setConnectionCodeSigningRequirement 承载（见入口处），
        // 不满足 requirement 的连接根本到不了这里。
        let id = ObjectIdentifier(newConnection)
        newConnection.exportedInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
        newConnection.exportedObject = service
        // invalidated（app 退出/被杀）与 interrupted 都算断开；Set.remove 幂等，两个都挂无妨
        let dropped: () -> Void = { [weak self] in self?.connectionDropped(id) }
        newConnection.invalidationHandler = dropped
        newConnection.interruptionHandler = dropped
        // 计数必须在 resume 之前落队（sync）：否则 handler 可能先跑，晚到的 insert 会复活死连接
        queue.sync {
            connections.insert(id)
            watchdog?.cancel() // 有活人连着，取消倒计时
            watchdog = nil
        }
        newConnection.resume()
        return true
    }

    /// 看门狗路径 1：最后一个连接断开且禁休眠仍生效 → 宽限 15s → 自动恢复；期间新连接会取消。
    /// 到点执行失败（pmset 瞬时出错）不在这里重试：哨兵未删、watchdog 已置 nil，
    /// 下一拍哨兵自检（≤60s）会接手重试，直到恢复成功删掉哨兵为止。
    private func connectionDropped(_ id: ObjectIdentifier) {
        queue.async { [self] in
            connections.remove(id)
            guard connections.isEmpty,
                  sentinelOwnedByHelper() else { return }
            log.notice("最后一个 XPC 连接断开且禁休眠仍生效，\(Int(AwakeIPC.watchdogGraceSeconds)) 秒后自动恢复")
            watchdog?.cancel()
            let task = DispatchWorkItem { [weak self] in
                self?.watchdog = nil
                // 到点再确认一次哨兵还在（正常关闭路径可能已恢复过了）
                guard sentinelOwnedByHelper() else { return }
                restoreSleep(reason: "看门狗：app 连接断开")
            }
            watchdog = task
            queue.asyncAfter(deadline: .now() + AwakeIPC.watchdogGraceSeconds, execute: task)
        }
    }
}

// ---- 入口（top-level code）----

// 看门狗路径 2：开机（RunAtLoad）/ 每次被 launchd 拉起时，哨兵还在 = 上次没善终 → 立即恢复。
// 必须在 listener.resume() 之前跑完，避免与排队进来的 setSleepDisabled(true) 乱序。
// 此处失败同样不重试：哨兵未删，常驻哨兵自检（ListenerDelegate 内，60s 一拍）会持续接手。
try? ensureSentinelDirectory()
if sentinelOwnedByHelper() {
    log.notice("开机兜底恢复：启动时发现哨兵文件，恢复休眠")
    restoreSleep(reason: "开机兜底")
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: AwakeIPC.machServiceName)
// XPC 对端校验：macOS 13+ 公开 API，签名有效且满足 requirement 才放行（内核 audit token，
// 无私有 KVC）。ad-hoc 阶段 requirement 只锁 identifier，自签同名可冒充——已知局限，
// 正式分发前会收紧为 anchor apple generic + team ID（只改 AwakeIPC.codeSigningRequirement 一个字符串）。
listener.setConnectionCodeSigningRequirement(AwakeIPC.codeSigningRequirement)
listener.delegate = delegate
listener.resume()
dispatchMain()
