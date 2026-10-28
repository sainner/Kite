import Foundation

/// 流式正文的放字节奏：收到的字先攒着，按稳定的速度一点点放给对话，不跟着模型和网络分块的节奏一坨一坨地蹦。
/// 速度跟着攒下的多少走（攒的字约 lag 秒放完），速度本身再缓一下，一大块到了也是加速着放出去，再快也有个上限；
/// 写完以后照样放完，停下以后剩下的很快给出。中文按字放，英文一个词一起放；不劈开一个字（表情、组合字符）。
/// 只管主对话里 agent 的话：思考那一行只说小标题，工具的参数和输出照收到的显示。
struct StreamPacer {
    /// 一段正在放的话：放出来多少（UTF-16 长度），这会儿每秒放几个字，不够一个字的零头。
    private struct Lane {
        var shown: Int
        var speed: Double = 0
        var carry: Double = 0
    }

    /// 生成中攒下的字约多少秒放完，屏幕上的字比收到的晚这么多。
    static let lag: Double = 0.18
    /// 速度多久跟上：一大块到了，先加速再放，不一下冲出去。
    static let easing: Double = 0.1
    /// 生成中每秒至少放几个字，末尾几个不拖着；写完以后至少几个。
    static let slowest: Double = 24
    static let finishingSlowest: Double = 240
    /// 每秒最多放几个字。Claude 思考完，正文开头常常一千多字同时到（2026-10-28 实测一次 1307 字），
    /// 不设上限就是一下冒出一大段、整片一起淡入，像中间蒙了一层。
    static let fastest: Double = 600
    /// 攒得再多也约这么多秒放完：一直来得比最快的速度还快时，不越拖越晚。
    static let longest: Double = 1.5
    /// 停下以后，剩下的约多少秒放完、每秒至少几个字。
    static let drainLag: Double = 0.08
    static let drainSlowest: Double = 240
    /// 隔多久放一次：同原来按 33 ms 合并刷新，正文每补一次字的开销不变。
    static let tick: Duration = .milliseconds(33)

    private var lanes: [Int: Lane] = [:]

    var isEmpty: Bool { lanes.isEmpty }
    var indices: [Int] { Array(lanes.keys) }

    /// 记录 index 收到了新字。还没在放的从眼下显示的长度 shown 起放。
    mutating func received(_ index: Int, shown: Int) {
        if lanes[index] == nil { lanes[index] = Lane(shown: shown) }
    }

    /// 这段话放到了哪；没在放的为 nil，照收到的显示。
    func shown(_ index: Int) -> Int? { lanes[index]?.shown }

    /// 不再放慢，都照收到的显示（换了快照、断了连接）。
    mutating func reset() { lanes = [:] }

    /// 走 elapsed 秒。text 给出这段话收到的全文和生成状态（streaming、complete，其余算停下）。返回放了字的和放完了的；
    /// 放完（不再生成、字都放出来了）的不再管，照收到的显示。
    mutating func advance(_ elapsed: Double, text: (Int) -> (full: String, generation: String?)?) -> [Int] {
        var moved: [Int] = []
        for (index, var lane) in lanes {
            guard let (full, generation) = text(index) else {
                lanes[index] = nil
                continue
            }
            let streaming = generation == "streaming"
            let start = String.Index(utf16Offset: min(lane.shown, full.utf16.count), in: full)
            let backlog = full[start...].count
            guard backlog > 0 else {
                lane.speed = 0
                lane.carry = 0
                if streaming {
                    lanes[index] = lane
                } else {
                    lanes[index] = nil
                    moved.append(index)
                }
                continue
            }
            if streaming || generation == "complete" {
                let lagging = max(Double(backlog) / Self.lag, streaming ? Self.slowest : Self.finishingSlowest)
                let target = max(min(lagging, Self.fastest), Double(backlog) / Self.longest)
                lane.speed += (target - lane.speed) * min(1, elapsed / Self.easing)
            } else {
                lane.speed = max(lane.speed, Double(backlog) / Self.drainLag, Self.drainSlowest)
            }
            let step = lane.speed * elapsed + lane.carry
            let count = min(Int(step), backlog)
            lane.carry = count < backlog ? step - Double(count) : 0
            guard count > 0 else {
                lanes[index] = lane
                continue
            }
            let end = Self.wordEnd(full, full.index(start, offsetBy: count))
            lane.shown = end.utf16Offset(in: full)
            lanes[index] = !streaming && end == full.endIndex ? nil : lane
            moved.append(index)
        }
        return moved
    }

    /// 全文 full 放出来的那截。
    static func prefix(_ full: String, _ shown: Int) -> String {
        guard shown < full.utf16.count else { return full }
        return String(full[..<String.Index(utf16Offset: shown, in: full)])
    }

    /// 落在英文词、数字中间时放到这个词的末尾，最多多放 24 个字（长网址、哈希不一下全出来）。
    private static func wordEnd(_ text: String, _ index: String.Index) -> String.Index {
        func word(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
        guard index > text.startIndex, index < text.endIndex, word(text[text.index(before: index)]) else { return index }
        var end = index
        var extra = 0
        while end < text.endIndex, extra < 24, word(text[end]) {
            end = text.index(after: end)
            extra += 1
        }
        return end
    }
}
