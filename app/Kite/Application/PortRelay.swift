import Foundation
import Network

/// 设备上为工作机端口开的转发，按目标共用：同一台工作机的同一个端口只开一个，几个网页视图看到的是同一个本机地址。
/// 设备打开着工作区期间，本工作区每个运行中终端与预览的端口都开着（见 PortForwarding），网页视图另外用着它看的那个端口（见 PortPreview）。
/// 最后一个用它的离开后稍等一会儿才关，视图重建（重新加载、工作区的端口有增减）时接着用，端口号不变。
final class PortRelays {
    static let shared = PortRelays()
    private static let linger = Duration.seconds(2)

    private struct Key: Hashable {
        let host: String
        let port: UInt16
    }
    private final class Entry {
        let opening: Task<PortRelay, any Error>
        var relay: PortRelay?
        var holders = 0
        init(_ opening: Task<PortRelay, any Error>) { self.opening = opening }
    }
    private var entries: [Key: Entry] = [:]

    /// 用着通向工作机 host 上 port 的转发，直到调用的任务取消；开好时交给 opened。开不起来时抛错，下次再用时重开。
    func hold(host: String, port: UInt16, opened: (PortRelay) -> Void = { _ in }) async throws {
        let key = Key(host: host, port: port)
        let entry: Entry
        // 监听失败停下的转发不再给人用
        if let existing = entries[key], existing.relay?.isStopped != true { entry = existing }
        else {
            entry = Entry(Task { try await PortRelay.start(host: host, port: port) { try await Tailnet.shared.socksProxy() } })
            entries[key] = entry
        }
        entry.holders += 1
        defer { release(entry, key) }
        let relay: PortRelay
        do { relay = try await entry.opening.value }
        catch {
            if entries[key] === entry { entries[key] = nil }
            throw error
        }
        entry.relay = relay
        guard !Task.isCancelled else { return }
        opened(relay)
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// 同时用着几个端口的转发，直到调用的任务取消；开不起来的跳过。
    func hold(host: String, ports: [UInt16]) async {
        await withDiscardingTaskGroup { group in
            for port in ports { group.addTask { try? await self.hold(host: host, port: port) } }
        }
    }

    private func release(_ entry: Entry, _ key: Key) {
        entry.holders -= 1
        guard entry.holders == 0 else { return }
        Task {
            try? await Task.sleep(for: Self.linger)
            guard entry.holders == 0 else { return }
            if entries[key] === entry { entries[key] = nil }
            (try? await entry.opening.value)?.stop()
        }
    }
}

/// 把设备回环上的一个端口转到工作机组网地址上的同号端口，给网页视图看工作机上运行的网页（docs/成果查看与位置.md「运行中的网页」）。
/// 网页只连本机回环：拿不到组网身份，经这里也只能到这一个目标。每条连接各自经组网节点的 SOCKS 代理拨出，
/// 节点重启（iOS 回到前台）后新连接照常可用。只听回环，本机其他程序经它也只能到同一个目标。
nonisolated final class PortRelay: @unchecked Sendable {
    /// 实际监听的端口：尽量和工作机上的相同，页面看到的地址就和在工作机上一样；被占用时由系统另分一个。
    let port: UInt16
    /// IPv4 与 IPv6 回环上同号各一个，页面里写 localhost、127.0.0.1 或 [::1] 的地址都到同一个目标。
    private let listeners: [NWListener]
    private let target: (host: String, port: UInt16)
    private let proxy: @Sendable () async throws -> SocksProxy
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    private init(listeners: [NWListener], port: UInt16, target: (String, UInt16), proxy: @escaping @Sendable () async throws -> SocksProxy,
                 queue: DispatchQueue) {
        self.listeners = listeners
        self.port = port
        self.target = target
        self.proxy = proxy
        self.queue = queue
    }

    static func start(host: String, port: UInt16, proxy: @escaping @Sendable () async throws -> SocksProxy) async throws -> PortRelay {
        let queue = DispatchQueue(label: "PortRelay")
        // 同号被本机别的程序占着（哪怕只占了一边）就换系统另分的号：只开一边时 localhost 会连到那个程序上
        var listeners = try? await pair(on: port, queue: queue)
        for _ in 0..<5 where listeners == nil { listeners = try? await pair(on: 0, queue: queue) }
        guard let listeners, let bound = listeners.first?.port?.rawValue else { throw KitedError(message: "本机转发端口没有打开") }
        let relay = PortRelay(listeners: listeners, port: bound, target: (host, port), proxy: proxy, queue: queue)
        for listener in relay.listeners {
            listener.newConnectionHandler = { [weak relay] connection in
                guard let relay else { connection.cancel(); return }
                relay.accept(connection)
            }
            listener.stateUpdateHandler = { [weak relay] state in
                if case .failed = state { relay?.stop() }
            }
        }
        return relay
    }

    /// IPv4 与 IPv6 回环上同一个端口各开一个监听；local 为 0 时由系统分，IPv6 跟着 IPv4 分到的号。有一边开不了就都关掉。
    private static func pair(on local: UInt16, queue: DispatchQueue) async throws -> [NWListener] {
        let v4 = try await listen(.ipv4(.loopback), on: local, queue: queue)
        guard let bound = v4.port?.rawValue else { v4.cancel(); throw KitedError(message: "本机转发端口没有打开") }
        do { return [v4, try await listen(.ipv6(.loopback), on: bound, queue: queue)] }
        catch { v4.cancel(); throw error }
    }

    /// 在回环地址上开一个监听，等它就绪；local 为 0 时由系统分端口。接上转发之前到的连接直接断开。
    private static func listen(_ address: NWEndpoint.Host, on local: UInt16, queue: DispatchQueue) async throws -> NWListener {
        let parameters = NWParameters.tcp
        // 两边都要开地址复用：不开时 IPv4 回环上开了这个号，IPv6 回环上同号报地址已占用（macOS 27 实测）；开了也抢不进别的程序占着的端口。
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: address, port: local == 0 ? .any : NWEndpoint.Port(rawValue: local)!)
        let listener = try NWListener(using: parameters)
        let ready = Once()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: ready.run { continuation.resume() }
                    case .failed(let error): ready.run { continuation.resume(throwing: error) }
                    case .cancelled: ready.run { continuation.resume(throwing: CancellationError()) }
                    default: break
                    }
                }
                listener.newConnectionHandler = { $0.cancel() }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            throw error
        }
        return listener
    }

    var isStopped: Bool { lock.withLock { stopped } }

    func stop() {
        let all = lock.withLock {
            stopped = true
            defer { connections = [:] }
            return Array(connections.values)
        }
        listeners.forEach { $0.cancel() }
        all.forEach { $0.cancel() }
    }

    deinit { stop() }

    private func track(_ connection: NWConnection) -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            connections[ObjectIdentifier(connection)] = connection
            return true
        }
    }

    private func release(_ connection: NWConnection) {
        connection.cancel()
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    private func accept(_ inbound: NWConnection) {
        guard track(inbound) else { inbound.cancel(); return }
        inbound.start(queue: queue)
        Task {
            var outbound: NWConnection?
            defer {
                release(inbound)
                if let outbound { release(outbound) }
            }
            do {
                let proxy = try await proxy()
                let connection = NWConnection(host: NWEndpoint.Host(proxy.host), port: NWEndpoint.Port(rawValue: proxy.port)!, using: .tcp)
                outbound = connection
                guard track(connection) else { return }
                connection.start(queue: queue)
                try await connection.ready()
                try await Socks.connect(connection, host: target.host, port: target.port, password: proxy.password)
                async let up: Void = Self.pipe(from: inbound, to: connection)
                async let down: Void = Self.pipe(from: connection, to: inbound)
                _ = await (up, down)
            } catch {
                // 拨不通就断开这条连接，页面看到的是连接失败
            }
        }
    }

    /// 一个方向的字节照搬到另一边；对方写完时把写完也传过去，出错时两边都断。
    private static func pipe(from source: NWConnection, to sink: NWConnection) async {
        do {
            while true {
                let (data, complete) = try await source.receiveChunk()
                if let data, !data.isEmpty { try await sink.sendChunk(data) }
                if complete {
                    try await sink.sendChunk(nil, final: true)
                    return
                }
            }
        } catch {
            source.cancel()
            sink.cancel()
        }
    }
}

/// SOCKS5 的 CONNECT（RFC 1928），带 RFC 1929 的用户名、密码认证。
nonisolated private enum Socks {
    static func connect(_ connection: NWConnection, host: String, port: UInt16, password: String?) async throws {
        let method: UInt8 = password == nil ? 0 : 2
        try await connection.sendChunk(Data([5, 1, method]))
        let choice = try await connection.receiveExactly(2)
        guard choice == [5, method] else { throw KitedError(message: "组网代理不接受认证方式") }
        if let password {
            let user = Array("tsnet".utf8), secret = Array(password.utf8)
            try await connection.sendChunk(Data([1, UInt8(user.count)] + user + [UInt8(secret.count)] + secret))
            guard try await connection.receiveExactly(2).last == 0 else { throw KitedError(message: "组网代理认证失败") }
        }
        var request: [UInt8] = [5, 1, 0]
        if let address = IPv4Address(host) { request += [1] + address.rawValue }
        else if let address = IPv6Address(host) { request += [4] + address.rawValue }
        else { request += [3, UInt8(host.utf8.count)] + Array(host.utf8) }
        request += [UInt8(port >> 8), UInt8(port & 0xff)]
        try await connection.sendChunk(Data(request))
        let head = try await connection.receiveExactly(4)
        guard head[0] == 5, head[1] == 0 else { throw KitedError(message: "工作机的端口连不上（代理返回 \(head[1])）") }
        let length: Int
        switch head[3] {
        case 1: length = 4
        case 4: length = 16
        case 3: length = Int(try await connection.receiveExactly(1)[0])
        default: throw KitedError(message: "组网代理的回复无效")
        }
        _ = try await connection.receiveExactly(length + 2)
    }
}

nonisolated private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        guard lock.withLock({ defer { done = true }; return !done }) else { return }
        body()
    }
}

nonisolated private extension NWConnection {
    func ready() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume() }
                case .failed(let error), .waiting(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
        }
    }

    func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, complete)) }
            }
        }
    }

    func receiveExactly(_ count: Int) async throws -> [UInt8] {
        guard count > 0 else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: Array(data)) }
                else { continuation.resume(throwing: KitedError(message: "组网代理提前断开")) }
            }
        }
    }

    func sendChunk(_ data: Data?, final: Bool = false) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, contentContext: final ? .finalMessage : .defaultMessage, isComplete: final, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
