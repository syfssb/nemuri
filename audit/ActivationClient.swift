import Foundation

// 联网激活层（DEVICE-LICENSING-PLAN §6.6 / 契约 (d)）。
//
// ★这是【全 app 唯一】发起出网请求的 URLSession（除「关于」里手动 Sparkle 检查更新外）。
//   放在 App target（未沙盒化、hardened runtime `--options runtime` 不拦出网，无需 network entitlement）。
//   必须进开源审计子集（publish-open.sh 白名单纳入），README 诚实写明「仅激活那一次联网」。
//
// 约束（§6.6）：
//   - 只 POST {base}/api/activate（契约 (d1)）；base 来自 Info.plist NemuriActivationBaseURL，默认 https://pro.nemuri.app
//   - 仅 HTTPS + host 白名单（pro.nemuri.app）；禁一切重定向（跨 host 钓鱼防护，app-ux Defect D）
//   - 无 cookie、无缓存（ephemeral session）；超时 10s
//   - 仅瞬态 transport 错误自动重试 1 次（服务端对 (order,deviceId) 幂等 §4.3 → 重试安全，不烧第二个 seat）
//   - transport 可注入（`ActivationTransport`）→ 单测无需真服务器
//
// 【红线】本层只把 HTTP 结果翻成 `ActivationOutcome` 值；它【绝不】读写 license 缓存、绝不改 isPro。
//   「网络错误绝不降级付费用户」由上层 LicenseManager 编排保证（只有 .success 才写 stored）。

// MARK: - 可注入传输（测试缝）

/// 单一出网原语。默认实现包一个 ephemeral、禁重定向的 URLSession；测试注入桩。
public protocol ActivationTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// 生产实现：ephemeral（无 cookie/无缓存）+ session 级 delegate 阻断所有重定向 + 10s 超时。
public final class DefaultActivationTransport: NSObject, ActivationTransport, URLSessionTaskDelegate {
    private var session: URLSession!

    public override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 10
        cfg.timeoutIntervalForResource = 20
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.httpAdditionalHeaders = nil
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    /// 阻断【所有】HTTP 重定向：激活端点从不 302；返回 nil = 不跟随（消灭跨 host 钓鱼/开放重定向整类风险）。
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - 结果类型

/// `/api/activate` 成功 200 载荷（契约 (d1)）。
public struct ActivationSuccess: Equatable {
    public let seatToken: String   // v2 device token（上层必须本地验签 == deviceBound 才落盘，§6.6 防坏响应）
    public let seatId: String
    public let seatLimit: Int
    public let seatsUsed: Int
    public let idempotent: Bool
}

/// `/api/activate` 结果（HTTP 状态 + error code → 枚举；客户端只按 status+code 分流，绝不 parse message）。
public enum ActivationOutcome: Equatable {
    case success(ActivationSuccess)
    /// 409 seat_limit_reached。manageURL 一律【客户端本地拼】https://pro.nemuri.app/manage（不信服务端下发 URL）。
    case seatLimitReached(seatLimit: Int, seatsUsed: Int, manageURL: URL)
    case invalidCode        // 400 invalid_code（码不存在/格式错）
    case notSeatManaged     // 400 not_seat_managed（v1 老单，硬拒 → 该买家走离线）
    case invalidDevice      // 400 invalid_device（deviceId 非 43 字符 base64url，正常不该发生）
    case licenseRevoked     // 403 license_revoked（退款/拒付/设备已 revoke）
    case rateLimited        // 429 rate_limited
    case serverError        // 5xx / 未知状态 / 响应体解不出（含 200 但字段缺失）
    case transportFailure   // 超时/DNS/连不上/取消（重试 1 次后仍失败）
}

// MARK: - 客户端

public final class ActivationClient {
    /// 唯一允许出网的 host。
    public static let allowedHost = "pro.nemuri.app"
    /// 「Manage Devices」深链一律本地拼此常量（消解开放重定向 app-ux Defect D）。
    public static let manageURL = URL(string: "https://pro.nemuri.app/manage")!
    private static let defaultBase = URL(string: "https://pro.nemuri.app")!

    private let base: URL
    private let transport: ActivationTransport

    public init(transport: ActivationTransport? = nil) {
        self.base = ActivationClient.resolvedBaseURL()
        self.transport = transport ?? DefaultActivationTransport()
    }

    /// Info.plist NemuriActivationBaseURL → 校验 https + host 白名单；不合法/缺失 → 默认。绝不 POST 到攻击者 host。
    static func resolvedBaseURL() -> URL {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "NemuriActivationBaseURL") as? String,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host == allowedHost
        else { return defaultBase }
        return url
    }

    // MARK: 主端点 POST /api/activate（契约 (d1)）

    public func activate(
        activationCode: String, deviceId: String, deviceLabel: String, appVersion: String
    ) async -> ActivationOutcome {
        let body: [String: Any] = [
            "activationCode": activationCode,
            "deviceId": deviceId,
            "deviceLabel": deviceLabel,
            "appVersion": appVersion,
        ]
        guard let request = makeRequest(path: "/api/activate", body: body) else { return .serverError }

        guard let (data, http) = await sendWithOneRetry(request) else { return .transportFailure }
        return Self.mapActivate(status: http.statusCode, data: data)
    }

    // MARK: 传输

    /// 发送 + 仅瞬态 transport 失败重试 1 次。返回 nil = transport 失败/非 HTTP 响应/取消。
    /// 取消（Task.isCancelled / URLError.cancelled）不重试（上层会丢弃结果）。
    private func sendWithOneRetry(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, resp) = try await transport.data(for: request)
                guard let http = resp as? HTTPURLResponse else { return nil } // 非 HTTP 响应 = 坏
                return (data, http)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return nil }
                if attempt >= 2 { return nil }
                // 否则瞬态错误再试一次（幂等由服务端 (order,deviceId) UNIQUE 保证）。
            }
        }
    }

    private func makeRequest(path: String, body: [String: Any]) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: base),
              url.scheme?.lowercased() == "https", url.host == Self.allowedHost,
              let payload = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = payload
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        req.httpShouldHandleCookies = false
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.timeoutInterval = 10
        return req
    }

    // MARK: 状态映射（只按 HTTP status + error code，绝不 parse message）

    static func mapActivate(status: Int, data: Data) -> ActivationOutcome {
        switch status {
        case 200:
            guard let obj = json(data),
                  let seatToken = obj["seatToken"] as? String, !seatToken.isEmpty,
                  let seatId = obj["seatId"] as? String,
                  let seatLimit = obj["seatLimit"] as? Int,
                  let seatsUsed = obj["seatsUsed"] as? Int
            else { return .serverError }
            let idempotent = (obj["idempotent"] as? Bool) ?? false
            return .success(ActivationSuccess(
                seatToken: seatToken, seatId: seatId,
                seatLimit: seatLimit, seatsUsed: seatsUsed, idempotent: idempotent))
        case 409:
            let obj = json(data)
            let seatLimit = (obj?["seatLimit"] as? Int) ?? 3
            let seatsUsed = (obj?["seatsUsed"] as? Int) ?? seatLimit
            // manageURL 一律本地拼（不用服务端下发的，防开放重定向）。
            return .seatLimitReached(seatLimit: seatLimit, seatsUsed: seatsUsed, manageURL: manageURL)
        case 429:
            return .rateLimited
        case 403:
            return .licenseRevoked
        case 400:
            switch errorCode(data) {
            case "invalid_code": return .invalidCode
            case "not_seat_managed": return .notSeatManaged
            case "invalid_device": return .invalidDevice
            default: return .serverError
            }
        case 500...599:
            return .serverError
        default:
            return .serverError
        }
    }

    private static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func errorCode(_ data: Data) -> String? {
        json(data)?["error"] as? String
    }
}

// 注：采 R2——dfp 只绑本机、与 orderId 无关（见 DeviceIdentity），故在线首激活只凭激活码即可本地
// 算出 deviceId，直接单次 POST /api/activate，无需 resolve 往返。服务端只此一个热端点（契约 (d1)）。
