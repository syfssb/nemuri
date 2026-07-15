// swift-tools-version:5.9
// Nemuri open core —— 可审计子集（root helper + XPC 契约 + 配置安装器 + hook 桥）。
// 本包不含检测引擎 / 状态机 / license 验签 / SwiftUI app（闭源，见 README「What's in here」）。
// 零第三方依赖：审计者不必信任任何外部包，也不需要网络即可构建。
import PackageDescription

let package = Package(
    name: "NemuriOpen",
    platforms: [.macOS(.v13)],
    targets: [
        // pmset/哨兵/电量原语（永不卡死的证明）+ Installer（改用户 agent 配置，先备份可撤销）
        // + Socket/Events（本地 AF_UNIX IPC 协议，无任何网络）。
        .target(name: "AwakeCore", path: "Sources/Core"),
        // App ↔ Helper 的唯一契约面：XPC 协议 + 代码签名 requirement（谁有资格指挥 root helper）。
        .target(name: "AwakeShared", path: "Sources/Shared"),
        // root LaunchDaemon：只暴露 setSleepDisabled/currentState/ping 三个方法 + 看门狗 + 开机兜底。
        .executableTarget(name: "AwakeHelper", dependencies: ["AwakeShared", "AwakeCore"], path: "Sources/Helper"),
        // 会被写进用户 agent 配置的极小 CLI：转发一行协议 JSON 到 app 的 unix socket。
        .executableTarget(name: "aw-hook", dependencies: ["AwakeCore"], path: "Sources/HookBridge/aw-hook"),
        .executableTarget(name: "aw-codex", dependencies: ["AwakeCore"], path: "Sources/HookBridge/aw-codex"),
    ]
)
