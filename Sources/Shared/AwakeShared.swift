import Foundation

/// root 助手的 XPC 面。硬性不变量：Helper 最小权限——只做 pmset 执行 + 看门狗，不加任何其他能力。
/// 只许这三个方法——任何新增方法都在扩大 root 攻击面，禁止。
@objc public protocol AwakeHelperProtocol {
    /// 执行 pmset -a disablesleep 1/0。reply 传退出码（0 = 成功；-1 = 哨兵写入失败拒绝执行）。
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Int32) -> Void)
    /// 读 pmset -g 解析 SleepDisabled。reply(退出码, 是否禁休眠)；退出码非 0 时布尔值无意义。
    func currentState(reply: @escaping (Int32, Bool) -> Void)
    /// 存活探测；也用于按需拉起 helper，让它启动时的哨兵兜底检查有机会执行。
    func ping(reply: @escaping () -> Void)
}

/// App 与 Helper 共享的常量。
public enum AwakeIPC {
    /// LaunchDaemon 的 MachServices 名（= plist Label）
    public static let machServiceName = "app.nemuri.helper"
    /// SMAppService.daemon(plistName:) 使用的 plist 文件名（位于 Contents/Library/LaunchDaemons/）
    public static let helperPlistName = "app.nemuri.helper.plist"
    /// helper 校验 XPC 对端用的 app signing identifier（make-app.sh 里 codesign --identifier 固定）
    public static let appSigningIdentifier = "app.nemuri.Nemuri"
    /// helper 侧 NSXPCListener.setConnectionCodeSigningRequirement 用的 requirement 字符串。
    /// M4 收紧（2026-07-15，换 Developer ID 后）：不再只锁 identifier——那样任何本地进程
    /// `codesign -s - --identifier` 同名即可冒充。现要求对端由 Apple 根签发的 Developer ID
    /// Application 证书（field.1.2.840.113635.100.6.1.13 是该证书的标记 OID）+ 属于本 Team
    /// (subject.OU = 我们的 Team ID) + 固定 identifier。三条齐备才放行，自签冒充被拒。
    /// Team ID `C36DGH2H9S` = Developer ID Application: Yunfeng Sun 的 OU。
    public static let appTeamID = "C36DGH2H9S"
    public static let codeSigningRequirement =
        "anchor apple generic"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"
        + " and certificate leaf[subject.OU] = \"\(appTeamID)\""
        + " and identifier \"\(appSigningIdentifier)\""
    /// 哨兵文件：存在 = 禁休眠由本产品设置且尚未恢复。开机时若残留即说明上次没能正常收尾，
    /// helper 据此把 disablesleep 恢复为 0（永不卡死的兜底路径）。
    public static let sentinelPath = "/Library/Application Support/Nemuri/sleep_disabled.flag"
    /// 看门狗路径 1 宽限期（秒）：最后一个 XPC 连接断开后多久自动恢复休眠
    public static let watchdogGraceSeconds: TimeInterval = 15
    /// 哨兵自检间隔（秒，B2）：helper 常驻自检 timer 的周期，兜住 restoreSleep 单发失败
    ///（看门狗到点/开机兜底的 pmset 失败此前不重试）。必须大于 watchdogGraceSeconds：
    /// 正常 kill 路径仍由看门狗按宽限处理，自检只兜失败残留（Checks 有断言）。
    public static let sentinelSelfCheckIntervalSeconds: TimeInterval = 60
}
