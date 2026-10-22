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
    typealias Size = (cols: Int, rows: Int)

    let instanceID: String
    /// 窗口放得下的行列，排好版之前连接要等它。
    private let connection = SocketLink<Size>()
    var link: SocketLink<Size>.State { connection.state }
    /// 这次连接里收到的进程状态：比工作区推送的实例状态早一步，窗口先用它。
    private(set) var status: TerminalStatus?
    @ObservationIgnored private(set) var view: KiteTerminalView?
    /// 上次给视图设的外观。
    @ObservationIgnored private var appliedDark: Bool?
    /// 这次连接时报给工作机的尺寸；连上之前窗口又变了，连上后补发。
    @ObservationIgnored private var connectedSize: Size?

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

    /// 前景色跟着浅色、深色外观换；底色透明，露出窗口本身的底。SwiftTerm 每次设色都整屏重画，外观没变就不设。
    func applyColors(dark: Bool) {
        guard let view, dark != appliedDark else { return }
        appliedDark = dark
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

    /// 窗口在就一直连着（见 SocketLink），进程结束后不再重连。
    func run(client: KitedClient) async {
        await connection.run(failure: "和工作机的终端连接断开", connect: { size in
            connectedSize = size
            return try await client.terminalSocket(instance: instanceID, cols: size.cols, rows: size.rows)
        }, receive: receive, reconnects: { status?.running != false })
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
                    connection.state = .connected
                    if let size = connection.size, size.cols != connectedSize?.cols || size.rows != connectedSize?.rows { sendResize(size) }
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
        guard connection.size?.cols != cols || connection.size?.rows != rows else { return }
        connection.laidOut((cols, rows))
        guard link == .connected else { return }
        sendResize((cols, rows))
    }

    private func sendResize(_ size: Size) {
        connection.socket?.send(.string(#"{"type":"resize","cols":\#(size.cols),"rows":\#(size.rows)}"#)) { _ in }
    }

}

extension TerminalSession: @preconcurrency TerminalViewDelegate {
    /// 按键和粘贴原样发给工作机。用带完成回调的 send：按调用顺序发出，不会像各开一个 Task 那样乱序。
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let socket = connection.socket, link == .connected, status?.running != false else { return }
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
