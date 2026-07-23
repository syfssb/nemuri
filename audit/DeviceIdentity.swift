import Foundation
import IOKit
import CryptoKit

// 设备指纹（dfp）派生 + 粗粒度机型 label（设备绑定 License，DEVICE-LICENSING-PLAN §6.2 / 契约 (b)）。
//
// 本文件是【全 app 唯一】读取硬件标识（IOKit IOPlatformUUID / sysctl hw.model）的地方——所有 IOKit
// 依赖锁在 App target，AwakePro/License.swift 保持纯逻辑、零 IOKit（只收已算好的 localDfp 做比较）。
//
// dfp 派生（R2·纯客户端派生：服务端不重算 dfp、只嵌入 app 上送的值；激活与复验两处用同一算法）：
//   domainSep = "nemuri.device.v1"(16 ASCII) ++ 0x00        // 17 字节，域分隔常量 salt
//   material  = domainSep ++ utf8(IOPlatformUUID)           // 纯拼接，无分隔符
//   dfp       = base64url_nopad( SHA-256(material) )        // 32 字节摘要 → 43 字符
//
// 隐私：只上送哈希，裸 IOPlatformUUID / 序列号【永不出网】。dfp 只绑本机、与 order 无关——
// 同机激活/复验恒定（幂等去重成立），异机必不同（拷贝 token 换机即 deviceMismatch）。
// （R2 权衡：放弃「同机跨购买不可关联」这一隐私加分——服务端本就有 orderId↔email↔label 映射、边际价值小；
//  换来「首激活只凭激活码即可本地算出 dfp、单端点搞定」，消除 orderId 鸡生蛋、无需 resolve 往返。）
enum DeviceIdentity {

    /// 域分隔前缀：`"nemuri.device.v1"` 的 16 个 ASCII 字节 + 一个 NUL（0x00），共 17 字节。
    /// 只有 label 后的 NUL 把 domainSep 与其后隔开；orderId 与 UUID 均为定长/定形，直接拼接无歧义。
    private static let domainSep: [UInt8] = Array("nemuri.device.v1".utf8) + [0x00]

    // MARK: - dfp 派生

    /// 纯函数：给定稳定机器标识串，按契约派生 dfp。零 IOKit、可单测。
    /// `machineId` = IOPlatformUUID（正常）或回退随机 id（原样、不 case-fold、不 trim）。
    static func deriveDfp(machineId: String) -> String {
        var material = Data(domainSep)             // domainSep（17 字节）
        material.append(Data(machineId.utf8))      // ++ utf8(machineId)，无分隔符
        let digest = SHA256.hash(data: material)   // 32 字节
        return base64urlNoPad(Data(digest))        // → 43 字符 [A-Za-z0-9_-]
    }

    /// 读硬件（IOPlatformUUID → 回退）后派生本机 dfp。这是 App 层唯一入口，喂给
    /// `LicenseVerify.verify(localDfp:)` 与 `ActivationClient` 的 `deviceId`。
    static func localDfp() -> String {
        deriveDfp(machineId: stableMachineId())
    }

    // MARK: - 稳定机器标识

    /// 稳定机器标识：优先 IOPlatformUUID（跨重装/重装系统稳定 → 重装不换 id、不烧名额）；
    /// 读不到（极罕见）→ 持久化的随机 128-bit 回退 id。
    static func stableMachineId() -> String {
        if let uuid = ioPlatformUUID() { return uuid }
        return fallbackMachineId()
    }

    /// IORegistry `IOPlatformExpertDevice` 的 `IOPlatformUUID`（大写连字符 UUID 原样返回，
    /// 不 case-fold、不 trim）。读不到 / 空串 → nil。无需任何 entitlement。
    private static func ioPlatformUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let cf = IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String, !cf.isEmpty else { return nil }
        return cf
    }

    /// 回退 id（§6.2）：首启生成随机 128-bit（大写连字符 UUID，镜像 IOPlatformUUID 形态），持久化并置
    /// `NSURLIsExcludedFromBackupKey`——否则迁移助理把该文件搬到新机，会静默复用旧 seat（app-ux 审查 Defect C）。
    /// 回退用户「换机迁移」记为已知有界边界。
    private static func fallbackMachineId() -> String {
        let path = fallbackIdPath()
        if let data = FileManager.default.contents(atPath: path),
           let existing = String(data: data, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let fresh = UUID().uuidString
        persistFallbackId(fresh, at: path)
        return fresh
    }

    private static func fallbackIdPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Library/Application Support/Nemuri/device-fallback-id"
    }

    /// 写回退 id（0600、atomic），并置排除 iCloud/迁移备份。写失败不致命：下次启动再生成一个
    /// 新的即可（回退路径本就罕见，重生成只影响该机 dfp 稳定性，绝不影响正常 IOPlatformUUID 机器）。
    private static func persistFallbackId(_ id: String, at path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = id.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutableURL.setResourceValues(values)
        } catch {
            // 写失败静默：见上，非致命。
        }
    }

    // MARK: - 粗粒度机型 label（不含主机名/真名 PII）

    /// 激活时上送的 `deviceLabel`：粗粒度机型（如 `"MacBook Pro"`），【绝不】含 `Host.current().localizedName`
    /// （常含机主真名，是新增 PII 出网，§6.2）。仅门户 UI 展示、落 `devices.device_label`，不进 token、非安全字段。
    /// - Intel 机型标识（`"MacBookPro18,3"`）→ 映射营销家族名（`"MacBook Pro"`）。
    /// - Apple Silicon 通用标识（`"Mac14,7"`，无家族前缀）→ 原样返回标识，保留可区分性（便于门户里认出是哪台）。
    /// - 读不到 → `"Mac"`。
    static func coarseModelLabel() -> String {
        let identifier = hwModel()
        guard !identifier.isEmpty else { return "Mac" }
        return marketingFamily(fromModelIdentifier: identifier) ?? identifier
    }

    /// sysctl `hw.model` → 机型标识（`"MacBookPro18,3"` / `"Mac14,7"`）。读不到 → 空串。
    private static func hwModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// 机型标识 → 营销家族名。取标识里去掉尾部 `<数字>,<数字>` 后的字母前缀映射；仅当前缀是明确家族
    /// （非通用 `"Mac"`）才返回，否则 nil（调用方回退原标识，保区分性）。
    private static func marketingFamily(fromModelIdentifier identifier: String) -> String? {
        // 取前导字母段（到第一个数字为止）。
        let alphaPrefix = String(identifier.prefix { $0.isLetter })
        switch alphaPrefix {
        case "MacBookPro": return "MacBook Pro"
        case "MacBookAir": return "MacBook Air"
        case "MacBook":    return "MacBook"
        case "Macmini":    return "Mac mini"
        case "MacPro":     return "Mac Pro"
        case "MacStudio":  return "Mac Studio"
        case "iMacPro":    return "iMac Pro"
        case "iMac":       return "iMac"
        // "Mac"（Apple Silicon 通用，如 "Mac14,7"）过于笼统 → nil，让调用方保留原标识。
        default:           return nil
        }
    }

    // MARK: - base64url_nopad（与服务端 lib/base64url.mjs 逐字节一致）

    /// RFC 4648 §5 base64url，无 `=` padding：标准 base64 → `+`→`-`、`/`→`_`、剥掉所有 `=`。
    /// 32 字节 SHA-256 摘要 → 44 字符标准 base64（含 1 个 `=`）→ 剥后恰好 43 字符。
    private static func base64urlNoPad(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
