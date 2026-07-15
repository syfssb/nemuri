import Foundation
import Darwin

// 本地 AF_UNIX socket（**无网络**：agent hook 事件只在本机进程间传递，不出机器）。
// 服务端放在 AwakeCore（无 AppKit 依赖，测试可直接起临时实例），
// 客户端 HookWire 供 aw-hook / aw-codex 复用（总预算 <100ms，绝不拖慢用户的 claude）。

/// sockaddr_un 填充。路径超过 sun_path 上限（104 字节）返回 nil。
private func makeAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = path.utf8CString // 含结尾 \0
    guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        bytes.withUnsafeBufferPointer { src in
            raw.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
        }
    }
    return addr
}

private func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, len) }
    }
}

// MARK: - 客户端（aw-hook / aw-codex）

public enum HookWire {
    /// 连 unix socket 写一行（自动补 \n）。非阻塞 connect + poll，全程受 budgetMs 预算约束；
    /// 任何失败只返回 false——调用方（hook 桥）静默退 0，绝不抛错、绝不阻塞。
    @discardableResult
    public static func send(line: String, socketPath: String, budgetMs: Int = 80) -> Bool {
        guard var addr = makeAddress(socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = DispatchTime.now() + .milliseconds(budgetMs)

        let rc = withSockaddr(&addr) { connect(fd, $0, $1) }
        if rc != 0 {
            guard errno == EINPROGRESS, waitWritable(fd, deadline) else { return false }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return false }
        }

        let bytes = Array((line + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            guard waitWritable(fd, deadline) else { return false }
            let n = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), bytes.count - sent)
            }
            if n > 0 {
                sent += n
            } else if errno != EAGAIN && errno != EINTR {
                return false
            }
        }
        return true
    }

    private static func waitWritable(_ fd: Int32, _ deadline: DispatchTime) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard deadline.uptimeNanoseconds > now else { return false }
        let remainMs = Int32(min(UInt64(Int32.max), (deadline.uptimeNanoseconds - now) / 1_000_000)) + 1
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, remainMs) > 0 else { return false }
        return pfd.revents & Int16(POLLOUT) != 0 && pfd.revents & Int16(POLLERR | POLLNVAL) == 0
    }
}

// MARK: - 服务端（app 内常驻）

/// 行分帧 unix socket 服务：建目录 → unlink 陈旧 socket → bind → chmod 0600 → accept 循环。
/// 每收到一行合法协议 JSON 回调一次 handler（内部队列，调用方自行回主线程）。
public final class SocketServer {
    private let listenFD: Int32
    private let path: String
    private let acceptQueue = DispatchQueue(label: "app.nemuri.socket-accept")
    private let readQueue = DispatchQueue(label: "app.nemuri.socket-read", attributes: .concurrent)
    /// 单条事件行上限：正常事件几百字节，超限即断开（0600 权限下防御性兜底）
    private static let maxLineBytes = 64 * 1024

    public init?(path: String, handler: @escaping (AgentEvent) -> Void) {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let attrs = try FileManager.default.attributesOfItem(atPath: dir)
            if (attrs[.posixPermissions] as? Int) != 0o700 {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
            }
        } catch {
            return nil
        }
        var stale = stat()
        if lstat(path, &stale) == 0 {
            guard stale.st_uid == getuid(), (stale.st_mode & S_IFMT) == S_IFSOCK else { return nil }
            unlink(path) // 上次异常退出的陈旧 socket
        }
        guard var addr = makeAddress(path) else { return nil }
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return nil }
        let oldMask = umask(0o077)
        let bound = withSockaddr(&addr) { bind(listenFD, $0, $1) }
        umask(oldMask)
        guard bound == 0, listen(listenFD, 16) == 0 else {
            close(listenFD)
            return nil
        }
        guard chmod(path, 0o600) == 0 else { // 只许本用户的 hook 桥连
            close(listenFD)
            unlink(path)
            return nil
        }
        let fd = listenFD
        acceptQueue.async { [readQueue] in
            while true {
                let conn = accept(fd, nil, nil)
                guard conn >= 0 else { return } // stop() close 后 accept 返错 → 退出循环
                readQueue.async { Self.drain(conn, handler: handler) }
            }
        }
    }

    /// 读一条连接到 EOF，按行解析转发。hook 桥都是「写一行就关」的短连接。
    private static func drain(_ fd: Int32, handler: (AgentEvent) -> Void) {
        defer { close(fd) }
        var uid = uid_t()
        var gid = gid_t()
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            guard buffer.count <= maxLineBytes else { return } // 超限：丢弃并断开
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: nl)
                buffer = Data(buffer.suffix(from: buffer.index(after: nl)))
                if let event = AgentEvent(line: Data(line)) { handler(event) }
            }
        }
        if !buffer.isEmpty, let event = AgentEvent(line: buffer) { handler(event) } // 无换行结尾的最后一行
    }

    public func stop() {
        close(listenFD)
        unlink(path)
    }
}
