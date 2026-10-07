import Foundation
import os

/// 真机耗时计时：begin 开始一轮，之后的 mark 和 span 记下相对本轮开始的毫秒数，用于分析连接、重连等流程的时间分布。
/// 仅 Debug 构建记录，写入 Caches/timing-trace.log；每轮只记开始后一分钟内的事件。当前每次回到前台开始一轮。
/// 取回方法见 app/README.md 的「预览和验证」。
nonisolated enum TimingTrace {
    private struct State { var origin = ContinuousClock.now; var round = 0 }
    private static let state = OSAllocatedUnfairLock(initialState: State())
    private static let window: Duration = .seconds(60)

    static func begin(_ event: String) {
        #if DEBUG
        state.withLock { state in
            state.origin = .now
            state.round += 1
            write("—— 第 \(state.round) 轮：\(event)")
        }
        #endif
    }

    static func mark(_ event: String) {
        #if DEBUG
        state.withLock { state in
            let elapsed = ContinuousClock.now - state.origin
            guard state.round > 0, elapsed < window else { return }
            write("+\(milliseconds(elapsed))ms  \(event)")
        }
        #endif
    }

    /// 返回从现在起计时的闭包，调用时记下事件与本段耗时。
    static func span(_ event: String) -> @Sendable (String) -> Void {
        let start = ContinuousClock.now
        return { result in mark("\(event) \(result)（\(milliseconds(ContinuousClock.now - start))ms）") }
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    }

    private static func write(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: .now))  \(text)\n"
        Logger(subsystem: "Kite", category: "Reconnect").info("\(text, privacy: .public)")
        let url = URL.cachesDirectory.appending(path: "timing-trace.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
