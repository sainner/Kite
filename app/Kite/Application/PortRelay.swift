import Foundation
import Network

/// 把设备回环上的一个端口转到工作机组网地址上的同号端口，给网页视图看工作机上运行的网页（docs/成果查看与位置.md「运行中的网页」）。
/// 网页只连 localhost：拿不到组网身份，经这里也只能到这一个目标。每条连接各自经组网节点的 SOCKS 代理拨出，
/// 节点重启（iOS 回到前台）后新连接照常可用。只听回环，本机其他程序经它也只能到同一个目标。
nonisolated final class PortRelay: @unchecked Sendable {
    /// 实际监听的端口：尽量和工作机上的相同，页面看到的地址就和在工作机上一样；被占用时由系统另分一个。
    let port: UInt16
    private let listener: NWListener
    private let target: (host: String, port: UInt16)
    private let proxy: @Sendable () async throws -> SocksProxy
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false

    private init(listener: NWListener, port: UInt16, target: (String, UInt16), proxy: @escaping @Sendable () async throws -> SocksProxy,
                 queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.target = target
        self.proxy = proxy
        self.queue = queue
    }

    static func start(host: String, port: UInt16, proxy: @escaping @Sendable () async throws -> SocksProxy) async throws -> PortRelay {
        do { return try await listen(on: port, host: host, port: port, proxy: proxy) }
        catch { return try await listen(on: 0, host: host, port: port, proxy: proxy) }
    }

    private static func listen(on local: UInt16, host: String, port: UInt16,
                               proxy: @escaping @Sendable () async throws -> SocksProxy) async throws -> PortRelay {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: local == 0 ? .any : NWEndpoint.Port(rawValue: local)!)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "PortRelay")
        let ready = Once()
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
        guard let bound = listener.port?.rawValue else { listener.cancel(); throw KitedError(message: "本机转发端口没有打开") }
        let relay = PortRelay(listener: listener, port: bound, target: (host, port), proxy: proxy, queue: queue)
        listener.newConnectionHandler = { [weak relay] connection in
            guard let relay else { connection.cancel(); return }
            relay.accept(connection)
        }
        listener.stateUpdateHandler = { [weak relay] state in
            if case .failed = state { relay?.stop() }
        }
        return relay
    }

    func stop() {
        let all = lock.withLock {
            stopped = true
            defer { connections = [:] }
            return Array(connections.values)
        }
        listener.cancel()
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
