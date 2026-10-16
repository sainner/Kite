import Foundation
import Observation
@preconcurrency import SwiftTerm
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 一个终端窗口和工作机上那个 PTY 之间的连接：画面交给 SwiftTerm，输入、尺寸发回工作机，协议见 kited 的 terminal/terminals.ts。
/// 进程在工作机上，窗口只是接上去看；断线后自动重连，重连时工作机先发当前画面，从那里接着显示。
@Observable
final class TerminalSession {
    enum Link: Equatable { case waiting, connecting, connected, failed(String) }

    let instanceID: String
    private(set) var link = Link.waiting
    /// 这次连接里收到的进程状态：比工作区推送的实例状态早一步，窗口先用它。
    private(set) var status: TerminalStatus?
    @ObservationIgnored private(set) var view: KiteTerminalView?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var urlSession: URLSession?
    /// 窗口放得下的行列；排好版之前没有，连接要等它。
    @ObservationIgnored private var size: (cols: Int, rows: Int)?
    @ObservationIgnored private var sizeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    init(instanceID: String) {
        self.instanceID = instanceID
    }

    func makeView() -> KiteTerminalView {
        if let view { return view }
        #if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        #else
        let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        #endif
        let view = KiteTerminalView(frame: .zero, font: font)
        view.terminalDelegate = self
        view.laidOut = { [weak self] cols, rows in self?.laidOut(cols: cols, rows: rows) }
        self.view = view
        return view
    }

    /// 前景色跟着浅色、深色外观换；底色透明，露出窗口本身的底。
    func applyColors(dark: Bool) {
        guard let view else { return }
        #if os(macOS)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.nativeForegroundColor = dark ? .white : .black
        view.nativeBackgroundColor = .clear
        view.caretColor = .controlAccentColor
        #else
        view.overrideUserInterfaceStyle = dark ? .dark : .light
        view.nativeForegroundColor = dark ? .white : .black
        view.nativeBackgroundColor = .clear
        view.caretColor = .tintColor
        view.keyboardAppearance = dark ? .dark : .light
        #endif
    }

    /// 窗口在就一直连着：断了等一会儿重连，进程结束后不再重连。由窗口的 task 驱动，窗口消失或换了连接时取消。
    func run(client: KitedClient) async {
        var backoff = 1.0
        while !Task.isCancelled {
            await sizeKnown()
            guard let size, !Task.isCancelled else { return }
            link = .connecting
            do {
                let (urlSession, socket) = try await client.terminalSocket(instance: instanceID, cols: size.cols, rows: size.rows)
                self.urlSession = urlSession
                self.socket = socket
                socket.resume()
                // receive 不理会任务取消，窗口关掉时由这里断开连接让它返回。
                try await withTaskCancellationHandler { try await receive(socket) } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
            } catch {
                if Task.isCancelled { break }
                link = .failed("和工作机的终端连接断开：\(error.localizedDescription)")
            }
            disconnect()
            if status?.running == false { return }
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
        disconnect()
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        socket = nil
        urlSession = nil
    }

    private struct Message: Decodable {
        let type: String
        var data: String? = nil
        var phase: String? = nil
        var exitCode: Int? = nil
        var signal: String? = nil
        var reason: String? = nil

        var status: TerminalStatus? {
            phase.map { TerminalStatus(phase: $0, exitCode: exitCode, signal: signal, reason: reason) }
        }
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        while true {
            switch try await socket.receive() {
            case .data(let data):
                view?.feed(byteArray: [UInt8](data)[...])
            case .string(let text):
                guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { continue }
                switch message.type {
                case "snapshot":
                    // 重连时画面从工作机给的当前状态重来，之前收到的不再接着用。
                    view?.getTerminal().resetToInitialState()
                    view?.feed(text: message.data ?? "")
                    status = message.status
                    link = .connected
                case "exit":
                    status = message.status
                default:
                    // size 是别的设备定了 PTY 尺寸；这里一直按自己窗口的尺寸显示，输入时工作机换回这台的尺寸。
                    break
                }
            @unknown default:
                break
            }
        }
    }

    private func laidOut(cols: Int, rows: Int) {
        guard size?.cols != cols || size?.rows != rows else { return }
        size = (cols, rows)
        for waiter in sizeWaiters.values { waiter.resume() }
        sizeWaiters = [:]
        guard let socket, link == .connected else { return }
        socket.send(.string(#"{"type":"resize","cols":\#(cols),"rows":\#(rows)}"#)) { _ in }
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

extension TerminalSession: @preconcurrency TerminalViewDelegate {
    /// 按键和粘贴原样发给工作机。用带完成回调的 send：按调用顺序发出，不会像各开一个 Task 那样乱序。
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let socket, link == .connected, status?.running != false else { return }
        socket.send(.data(Data(data))) { _ in }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { laidOut(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    #if !os(macOS)
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    #endif
}

/// SwiftTerm 只在行列数和原来不同时回调代理，第一次排版正好是默认的 80×25 时不回调；这里每次排版都报一次。
final class KiteTerminalView: TerminalView {
    var laidOut: ((Int, Int) -> Void)?

    #if os(macOS)
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        report()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        report()
    }
    #endif

    private func report() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let terminal = getTerminal()
        laidOut?(terminal.cols, terminal.rows)
    }
}
