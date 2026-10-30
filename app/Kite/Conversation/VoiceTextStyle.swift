import Foundation

/// 输入框里语音输入的那段字怎么显示（见 ThreadControlsModel.voiceStyle）：还在录时整段是灰的；说完了等整理时灰字呼吸（waiting，
/// 同 WaitingBreath 的节奏）；整理后的字到了扫掠的头在 head，前面是整理后的字，照正文显示，后面是还没扫到的定稿，仍是灰的。
/// 扫掠本身同工具行（PixelSweep），见 VoiceSweepView。
/// 原生输入框只改显示的颜色，不动字本身，不进撤销，也不带到接着打的字上。
nonisolated struct VoiceTextStyle: Equatable {
    /// 语音输入的那段字，UTF-16 范围。
    let range: NSRange
    /// 扫掠走到哪了（输入框里的 UTF-16 位置）；还在录、等整理时为 nil。
    let head: Int?
    /// 说完了、等整理。
    let waiting: Bool

    /// 灰的时候正文的颜色留几成。
    static let dim = 0.45

    /// 灰的那段：还在录时整段，整理时扫掠头后面那段。
    var gray: NSRange? {
        let start = max(head ?? range.location, range.location), end = NSMaxRange(range)
        return start < end ? NSRange(location: start, length: end - start) : nil
    }
}
