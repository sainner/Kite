import SwiftUI

/// /threads/:id/raw 的一页，见 docs/kited.md。
struct RawTranscriptPage: Decodable {
    let journal: Int
    let claude: Int
    let reset: Bool
    let entries: [RawTranscriptEntry]
}

struct RawTranscriptEntry: Decodable, Identifiable {
    let source: String
    let index: Int
    var at: Double?
    let label: String
    let text: String
    var id: String { "\(source):\(index)" }
}

/// 代理窗口的调试模式：对话区换成这个代理的原生记录（harness 的 journal、Claude 的会话文件），逐条原样。开着时 WorkThread.raw 不为空。
/// 看着时才读：先读全部，之后线程来了事件就接着读新增的；事件停下后再补读几秒，Claude 的会话文件可能比事件晚落盘。
@Observable final class RawTranscript {
    private(set) var entries: [RawTranscriptEntry] = []
    /// 读取失败的说明，由标题栏的信息区显示（见 AppModel.threadNotice）。
    private(set) var error: String?
    @ObservationIgnored private var journal = 0
    @ObservationIgnored private var claude = 0
    @ObservationIgnored private var activity = Date.distantPast
    @ObservationIgnored private var fetched: Date?

    /// 线程来了事件，见 WorkThread.apply。
    func poke() { activity = .now }

    func follow(_ thread: WorkThread) async {
        while !Task.isCancelled {
            if fetched.map({ activity.addingTimeInterval(3) > $0 }) ?? true {
                fetched = .now
                await load(thread)
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func load(_ thread: WorkThread) async {
        guard let client = thread.client else { return }
        do {
            let page = try await client.request("/threads/\(thread.id.pathComponent)/raw?journal=\(journal)&claude=\(claude)",
                                                as: RawTranscriptPage.self)
            guard !Task.isCancelled else { return }
            if page.reset { entries = page.entries } else if !page.entries.isEmpty { entries += page.entries }
            journal = page.journal
            claude = page.claude
            error = nil
        } catch {
            if !Task.isCancelled { self.error = "读取原始记录失败：\(error.localizedDescription)" }
        }
    }
}

/// 原始记录列表：每条一行（时间、来源、摘要），点开看缩进好的原文，可以选中复制。停在最底下时新来的条目跟着往下滚。
/// insets 是要让出的标题栏、输入区，原生外框铺满窗口时给；放在 SwiftUI 窗口正文里的由安全区让出。
struct RawTranscriptView: View {
    let raw: RawTranscript
    var insets = EdgeInsets()
    @Environment(WorkThread.self) private var thread
    @State private var expanded: Set<String> = []
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    private static let clock: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(raw.entries) { entry in row(entry) }
            }
            .frame(maxWidth: Metrics.transcriptWidth)
            .padding(Metrics.padding)
            .frame(maxWidth: .infinity)
        }
        .contentMargins(.top, insets.top, for: .scrollContent)
        .contentMargins(.bottom, insets.bottom, for: .scrollContent)
        .scrollPosition($position)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - 40
        } action: { _, bottom in atBottom = bottom }
        .onChange(of: raw.entries.count) { if atBottom { position.scrollTo(edge: .bottom) } }
        .task(id: ObjectIdentifier(raw)) { await raw.follow(thread) }
    }

    private func row(_ entry: RawTranscriptEntry) -> some View {
        let open = expanded.contains(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.at.map { Date(timeIntervalSince1970: $0 / 1000).formatted(Self.clock) } ?? "--:--:--")
                        .font(Theme.status.monospacedDigit()).foregroundStyle(.tertiary)
                    Text(entry.source).font(Theme.status).foregroundStyle(.secondary)
                    Text(entry.label).font(Theme.code).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(Theme.status).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pointingPlain)
            if open {
                Text(entry.text)
                    .font(Theme.code)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }
}
