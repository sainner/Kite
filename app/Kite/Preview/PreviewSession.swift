import CoreGraphics
import Foundation
import ImageIO
import Observation

/// 一个预览窗口和工作机上那块画面（工作机浏览器里的页面或模拟器屏幕）之间的连接，协议见 kited 的 preview/previews.ts。
/// 工作机发画面的状态和一帧帧 JPEG，这里发动作、窗口尺寸和实时还是逐帧；断线后自动重连，重连时工作机先发当前画面。
@Observable
final class PreviewSession {
    /// 画面上的一点，单位是画面的逻辑尺寸（网页是 CSS 像素，模拟器是点）。
    struct Point: Equatable, Decodable {
        let x: Double
        let y: Double
    }

    let instanceID: String
    /// 窗口放得下的逻辑尺寸，排好版之前连接要等它。
    private let connection = SocketLink<CGSize>()
    var link: SocketLink<CGSize>.State { connection.state }
    /// waiting 没选端口、starting 正在开（可能在下载浏览器）、ready、failed。
    private(set) var phase = "starting"
    private(set) var error: String?
    /// 网页的地址与标题。
    private(set) var url: URL?
    private(set) var pageTitle: String?
    private(set) var frame: CGImage?
    /// 这一帧的逻辑尺寸，点按的坐标照它换算。
    private(set) var frameSize = CGSize.zero
    /// 刚点的位置：逐帧模式在画面上标出来。
    private(set) var point: Point?
    /// 逐帧模式下等画面稳定：等的期间再点会被丢掉。
    private(set) var settling = false
    /// 刚才的输入因为在等画面稳定被丢掉了。
    private(set) var dropped = false
    /// 实时画面还是逐帧。
    private(set) var live = false
    /// 尺寸停下来一会儿再报给工作机，见 laidOut。
    @ObservationIgnored private var resizing: Task<Void, Never>?
    /// 下一条二进制消息是哪一帧。
    @ObservationIgnored private var pending: (size: CGSize, point: Point?, settled: Bool?)?

    init(instanceID: String, live: Bool) {
        self.instanceID = instanceID
        self.live = live
    }

    /// 窗口在就一直连着，见 SocketLink。
    func run(client: KitedClient) async {
        await connection.run(failure: "和工作机的预览连接断开", connect: { size in
            try await client.previewSocket(instance: instanceID, width: Int(size.width), height: Int(size.height), live: live)
        }, receive: receive, reconnects: {
            settling = false
            return true
        })
    }

    private static let decoder = JSONDecoder()

    /// 在主线程外解码好一帧：CGImageSource 给的图默认到画的时候才解码，会落在主线程上。
    @concurrent nonisolated private static func decode(_ data: Data) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private struct Message: Decodable {
        let type: String
        var phase: String? = nil
        var error: String? = nil
        var message: String? = nil
        var url: String? = nil
        var pageTitle: String? = nil
        var width: Double? = nil
        var height: Double? = nil
        var settled: Bool? = nil
        var point: Point? = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        while true {
            switch try await socket.receive() {
            case .data(let data):
                guard let pending else { continue }
                self.pending = nil
                guard let image = await Self.decode(data) else { continue }
                frame = image
                frameSize = pending.size
                if let point = pending.point { self.point = point }
                if pending.settled != nil { settling = false }
            case .string(let text):
                guard let message = try? Self.decoder.decode(Message.self, from: Data(text.utf8)) else { continue }
                switch message.type {
                case "state":
                    connection.state = .connected
                    phase = message.phase ?? phase
                    error = message.error
                    url = message.url.flatMap(URL.init(string:))
                    pageTitle = message.pageTitle
                case "frame":
                    pending = (CGSize(width: message.width ?? 0, height: message.height ?? 0), message.point, message.settled)
                case "waiting":
                    settling = true
                    dropped = false
                case "dropped":
                    dropped = true
                case "error":
                    settling = false
                    error = message.message
                default:
                    break
                }
            @unknown default:
                break
            }
        }
    }

    /// 做一个动作。逐帧时等画面稳定再来一帧，等的期间再点工作机会丢掉；实时时画面变了就来。
    func send(_ action: [String: Any]) {
        guard let socket = connection.socket, link == .connected else { return }
        if !live {
            if settling { dropped = true; return }
            settling = true
            dropped = false
        }
        if let x = action["x"] as? Double, let y = action["y"] as? Double { point = Point(x: x, y: y) }
        sendJSON(["type": "action", "action": action, "wait": !live], on: socket)
    }

    /// 换实时还是逐帧；换成逐帧时工作机补发一帧当前画面。
    func setLive(_ live: Bool) {
        guard live != self.live else { return }
        self.live = live
        settling = false
        if let socket = connection.socket { sendJSON(["type": "mode", "mode": live ? "live" : "step"], on: socket) }
    }

    /// 要一帧当前画面：逐帧模式下画面自己变了（定时器、动画）时用。
    func refresh() {
        if let socket = connection.socket { sendJSON(["type": "frame"], on: socket) }
    }

    /// 窗口排好版、尺寸变了时报给工作机：网页的视口跟着最近操作的那台设备。拖缝、窗口动画时尺寸每帧都变，
    /// 停下来 0.2 秒再报，工作机不必每帧重排页面、截一帧。
    func laidOut(_ size: CGSize) {
        let rounded = CGSize(width: max(200, size.width.rounded()), height: max(200, size.height.rounded()))
        guard rounded != connection.size else { return }
        connection.laidOut(rounded)
        resizing?.cancel()
        resizing = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let socket = connection.socket, link == .connected else { return }
            sendJSON(["type": "resize", "width": Int(rounded.width), "height": Int(rounded.height)], on: socket)
        }
    }

    /// 用带完成回调的 send：按调用顺序发出。
    private func sendJSON(_ object: [String: Any], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
