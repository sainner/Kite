import Foundation
import Observation

/// 窗口和工作机上一个实例之间一直连着的 WebSocket，终端和预览共用：窗口排好版、有了尺寸才连；断了等一会儿重连（1 秒起翻倍，最多 10 秒），
/// 重连时工作机先发当前状态。由窗口的 task 驱动，窗口消失或换了连接时取消。
@Observable
final class SocketLink<Size> {
    enum State: Equatable { case waiting, connecting, connected, failed(String) }

    /// 连上后收到工作机的第一条消息时，由会话置为 connected。
    var state = State.waiting
    @ObservationIgnored private(set) var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var urlSession: URLSession?
    /// 窗口放得下的尺寸；排好版之前没有，连接要等它。
    @ObservationIgnored private(set) var size: Size?
    @ObservationIgnored private var sizeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// failure 是断开时信息区说明的开头；reconnects 在每次断开后问还要不要重连。
    func run(failure: String, connect: (Size) async throws -> (URLSession, URLSessionWebSocketTask),
             receive: (URLSessionWebSocketTask) async throws -> Void, reconnects: () -> Bool = { true }) async {
        var backoff = 1.0
        while !Task.isCancelled {
            await sizeKnown()
            guard let size, !Task.isCancelled else { return }
            state = .connecting
            do {
                let (urlSession, socket) = try await connect(size)
                self.urlSession = urlSession
                self.socket = socket
                socket.resume()
                // receive 不理会任务取消，窗口关掉时由这里断开连接让它返回。
                try await withTaskCancellationHandler { try await receive(socket) } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            } catch {
                if Task.isCancelled { break }
                state = .failed("\(failure)：\(error.localizedDescription)")
            }
            disconnect()
            if !reconnects() { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
        disconnect()
    }

    /// 窗口排好版或尺寸变了；还没连的接着连。
    func laidOut(_ size: Size) {
        self.size = size
        for waiter in sizeWaiters.values { waiter.resume() }
        sizeWaiters = [:]
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        socket = nil
        urlSession = nil
    }

    private func sizeKnown() async {
        if size != nil { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if size != nil || Task.isCancelled { continuation.resume() } else { sizeWaiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.sizeWaiters.removeValue(forKey: id)?.resume() }
        }
    }
}
