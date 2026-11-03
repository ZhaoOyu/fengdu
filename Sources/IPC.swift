import Foundation
import Darwin

private func unixAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw FanError("通信路径过长") }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return address
}
private func setupSocket(_ fd: Int32, seconds: Int = 2) {
    var timeout = timeval(tv_sec: seconds, tv_usec: 0), one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}
private func sendJSON<T: Encodable>(_ value: T, fd: Int32) throws {
    var data = try JSONEncoder().encode(value); data.append(10)
    try data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let n = send(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            guard n > 0 else { throw FanError("控制连接写入失败") }; sent += n
        }
    }
}
private func receiveJSON<T: Decodable>(_ type: T.Type, fd: Int32) throws -> T {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 2048)
    while data.count <= 16384 {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw FanError("控制连接已中断或超时") }
        data.append(contentsOf: buffer.prefix(n))
        if let newline = data.firstIndex(of: 10) { return try JSONDecoder().decode(type, from: data.prefix(upTo: newline)) }
    }
    throw FanError("控制消息超出长度限制")
}
struct Reply: Codable { var snapshot: Snapshot?; var error: String? }
func request(_ command: Command, path: String, expectedUID: uid_t = 0) throws -> Snapshot {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw FanError("无法创建控制连接") }; defer { close(fd) }
    setupSocket(fd, seconds: 6)
    var address = try unixAddress(path)
    let result = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    guard result == 0 else { throw FanError("辅助控制程序尚未连接，请先授权") }
    var uid: uid_t = 0, gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { throw FanError("辅助程序身份验证失败") }
    try sendJSON(command, fd: fd)
    let reply = try receiveJSON(Reply.self, fd: fd)
    if let error = reply.error { throw FanError(error) }
    guard let snapshot = reply.snapshot else { throw FanError("辅助程序未返回有效读数") }
    return snapshot
}
private var helperStopping = false
func runHelper(directory: String, owner: uid_t, demo: Bool = false) throws {
    guard demo || geteuid() == 0 else { throw FanError("辅助控制程序需要管理员权限") }
    guard owner != 0 else { throw FanError("无效的会话用户") }
    let dirFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard dirFD >= 0 else { throw FanError("无法打开控制会话目录") }
    defer { close(dirFD) }
    var metadata = stat()
    guard fstat(dirFD, &metadata) == 0, metadata.st_uid == owner,
          metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700,
          URL(fileURLWithPath: directory).lastPathComponent.hasPrefix("fengdu-") else { throw FanError("不安全的控制会话目录") }
    // Pin the directory by descriptor, then remove user write permission before any
    // privileged pathname operations. This prevents symlink replacement races.
    if !demo {
        guard fchown(dirFD, 0, 0) == 0, fchmod(dirFD, 0o711) == 0 else { throw FanError("无法保护会话目录") }
    }
    guard fchdir(dirFD) == 0 else { throw FanError("无法进入控制会话目录") }
    defer { if !demo { rmdir(directory) } }
    var lockFD: Int32 = -1
    if !demo {
        lockFD = open("/private/tmp/io.github.fengdu.control.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        var s = stat()
        guard lockFD >= 0, fstat(lockFD, &s) == 0, s.st_uid == 0, s.st_mode & S_IFMT == S_IFREG,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw FanError("已有风度控制会话运行") }
    }
    defer { if lockFD >= 0 { close(lockFD) } }
    let hardware: FanHardware = demo ? DemoHardware() : try MacHardware()
    let engine = ControlEngine(hardware)
    let path = "control.sock", fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var didBind = false
    guard fd >= 0 else { throw FanError("无法创建本地控制服务") }; defer { close(fd); if didBind { unlinkat(dirFD, path, 0) } }
    var address = try unixAddress(path)
    let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    didBind = bound == 0
    guard didBind, chmod(path, 0o600) == 0,
          (demo || chown(path, owner, gid_t.max) == 0), listen(fd, 4) == 0 else { throw FanError("无法建立受保护的本地控制服务") }
    signal(SIGTERM) { _ in helperStopping = true }; signal(SIGINT) { _ in helperStopping = true }
    var lastClient = Date.timeIntervalSinceReferenceDate, lastPoll = lastClient
    while true {
        let now = Date.timeIntervalSinceReferenceDate
        if helperStopping || now - lastClient > 12 {
            do { try engine.restore(); break } catch { /* Retain the helper and retry restoration. */ }
        }
        if now - lastPoll >= 2 {
            if !demo && engine.mode == "curve" && (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical) {
                if !engine.owned.isEmpty { engine.protect("系统报告较高热压力，已恢复系统自动") }
            }
            engine.tick(now: now); lastPoll = now
        }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 300) > 0 else { continue }
        let client = accept(fd, nil, nil)
        guard client >= 0 else { continue }
        setupSocket(client, seconds: 1)
        var uid: uid_t = 0, gid: gid_t = 0
        if getpeereid(client, &uid, &gid) != 0 || uid != owner { close(client); continue }
        do {
            let command = try receiveJSON(Command.self, fd: client)
            if !demo && command.action == "curve" && (ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical) {
                throw FanError("系统热压力较高，请保持系统自动调节")
            }
            let snapshot = try engine.command(command)
            lastClient = Date.timeIntervalSinceReferenceDate
            try sendJSON(Reply(snapshot: snapshot), fd: client)
            if command.action == "quit" { helperStopping = true }
        } catch { try? sendJSON(Reply(error: error.localizedDescription), fd: client) }
        close(client)
    }
}
