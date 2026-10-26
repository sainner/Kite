import CoreGraphics
import Foundation
import ImageIO
import Observation

/// 并排视图的一格：工作机上的哪个浏览器、视口多大（CSS 像素）。哪几格由各设备自己定，记在本机。
struct PreviewCell: Codable, Hashable, Identifiable {
    let browser: PreviewBrowser
    let width: Int
    let height: Int
    var id: String { "\(browser.rawValue) \(width)x\(height)" }
}

/// 一个预览窗口和工作机上那块画面（工作机浏览器里的页面、模拟器屏幕或 App 窗口）之间的连接，协议见 kited 的 preview/previews.ts。
/// 工作机发画面的状态和一帧帧 JPEG，这里发动作、窗口尺寸和实时还是逐帧；断线后自动重连，重连时工作机先发当前画面。
/// 并排视图的每一格各一条连接，带着格子的浏览器与视口尺寸。
@Observable
final class PreviewSession {
    /// 画面上的一点，单位是画面的逻辑尺寸（网页是 CSS 像素，模拟器是点）。
    struct Point: Hashable, Decodable {
        let x: Double
        let y: Double
    }

    let instanceID: String
    /// 并排的一格；画面视图没有。
    let cell: PreviewCell?
    /// 窗口放得下的逻辑尺寸，排好版之前连接要等它。
    private let connection = SocketLink<CGSize>()
    var link: SocketLink<CGSize>.State { connection.state }
    /// waiting 进程还没产生画面、starting 正在开（可能在下载浏览器）、ready、failed。
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
    @ObservationIgnored private var pending: FrameInfo?
    /// 指认时画面停在当前这一帧（见 hold），期间收到的只留最新的一帧，还没解码。
    @ObservationIgnored private var held = false
    @ObservationIgnored private var heldFrame: (data: Data, info: FrameInfo)?
    /// 在等工作机回答的指认，按问的那一点。
    @ObservationIgnored private var pointing: [Point: [CheckedContinuation<PointedElement?, Never>]] = [:]

    init(instanceID: String, live: Bool, cell: PreviewCell? = nil) {
        self.instanceID = instanceID
        self.live = live
        self.cell = cell
    }

    /// 窗口在就一直连着，见 SocketLink。
    func run(client: KitedClient) async {
        await connection.run(failure: "和工作机的预览连接断开", connect: { size in
            try await client.previewSocket(instance: instanceID, width: Int(size.width), height: Int(size.height), live: live, cell: cell)
        }, receive: receive, reconnects: {
            settling = false
            answerPoints()
            return true
        })
        answerPoints()
    }

    /// 断线时在等的指认都按没有元素答掉。
    private func answerPoints() {
        let waiting = pointing
        pointing = [:]
        for continuation in waiting.values.joined() { continuation.resume(returning: nil) }
    }

    private static let decoder = JSONDecoder()

    private typealias FrameInfo = (size: CGSize, point: Point?, settled: Bool?)

    /// 在主线程外解码好一张图：CGImageSource 给的图默认到画的时候才解码，会落在主线程上。设备网页视图的截图也用它。
    @concurrent nonisolated static func decode(_ data: Data) async -> CGImage? {
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
        var x: Double? = nil
        var y: Double? = nil
        var element: PointedElement? = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        while true {
            switch try await socket.receive() {
            case .data(let data):
                guard let pending else { continue }
                self.pending = nil
                if held { heldFrame = (data, pending) } else { await show(data, pending) }
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
                case "element":
                    guard let x = message.x, let y = message.y else { break }
                    for continuation in pointing.removeValue(forKey: Point(x: x, y: y)) ?? [] { continuation.resume(returning: message.element) }
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

    private func show(_ data: Data, _ info: FrameInfo) async {
        guard let image = await Self.decode(data) else { return }
        frame = image
        frameSize = info.size
        if let point = info.point { self.point = point }
        if info.settled != nil { settling = false }
    }

    /// 指认时画面停在当前这一帧：之后收到的帧先不换上，放开时换成最新的。实时画面期间让工作机先按逐帧发，免得一直截、传、解码看不见的帧。
    func hold(_ held: Bool) {
        guard held != self.held else { return }
        self.held = held
        if live, let socket = connection.socket { sendJSON(["type": "mode", "mode": held ? "step" : "live"], on: socket) }
        guard !held, let latest = heldFrame else { return }
        heldFrame = nil
        Task { await show(latest.data, latest.info) }
    }

    /// 指认：问工作机画面上这一点（画面坐标，取整）是哪个元素；没连着、没有元素时为 nil。
    func element(at point: CGPoint) async -> PointedElement? {
        guard let socket = connection.socket, link == .connected else { return nil }
        let point = Point(x: point.x.rounded(), y: point.y.rounded())
        return await withCheckedContinuation { continuation in
            pointing[point, default: []].append(continuation)
            sendJSON(["type": "point", "x": point.x, "y": point.y], on: socket)
        }
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
    /// 停下来 0.2 秒再报，工作机不必每帧重排页面、截一帧。并排的格子视口固定，只在第一次排好版时报一次，好接上。
    func laidOut(_ size: CGSize) {
        let rounded = CGSize(width: max(200, size.width.rounded()), height: max(200, size.height.rounded()))
        guard rounded != connection.size else { return }
        if cell != nil, connection.size != nil { return }
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
