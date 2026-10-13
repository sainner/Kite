import SwiftUI
import UIKit

/// 实验入口：启动参数 `-test v1|v2|v3` 选一项，跑完把报告写进 App 的 tmp（report-<项>.txt），写完再写 done-<项>。
/// build.sh 用 simctl 装、启动、等 done，再把报告取回。不合成触摸、键盘或滚动事件，只调接口、读状态。
@main
struct SpikeApp: App {
    var body: some Scene {
        WindowGroup {
            SpikeRoot()
        }
    }
}

struct SpikeRoot: View {
    private let test = UserDefaults.standard.string(forKey: "test") ?? "v1"

    var body: some View {
        switch test {
        case "v2": GeometrySpike()
        case "v3": EdgeSpike()
        default: ViewportSpikeHost()
        }
    }
}

/// 报告：一行一条，跑完写文件。
@MainActor final class Report {
    static let shared = Report()
    private var lines: [String] = []

    func line(_ text: String) {
        lines.append(text)
        print(text)
    }

    func finish(_ name: String) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        try? lines.joined(separator: "\n").write(to: directory.appendingPathComponent("report-\(name).txt"), atomically: true, encoding: .utf8)
        try? "".write(to: directory.appendingPathComponent("done-\(name)"), atomically: true, encoding: .utf8)
    }
}

/// 让出主线程几拍，让排版、提交、绘制走完。
@MainActor func spin(_ seconds: Double = 0.1) async {
    try? await Task.sleep(for: .seconds(seconds))
}
