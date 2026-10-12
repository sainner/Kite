// Apple 本地识别：SpeechAnalyzer 的听写模块按真实语速吃 16 kHz 单声道 s16le 的 PCM，词表放进 contextualStrings。
// 每行输出一个 JSON：中间结果 {"partial", "at"}，定稿 {"final", "latency"}，出错 {"error"}。
// 用法：apple <audio.pcm> <words.txt>
import AVFoundation
import Foundation
import Speech

@main
struct AppleRecognition {
    static let chunkFrames: AVAudioFrameCount = 3200

    static func main() async {
        do {
            try await run()
        } catch {
            emit(["error": "\(error)"])
            exit(1)
        }
    }

    static func run() async throws {
        let arguments = CommandLine.arguments
        let pcm = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let words = try String(contentsOfFile: arguments[2], encoding: .utf8).split(separator: "\n").map(String.init)
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else {
            throw Failure("听写不支持中文")
        }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure("没有可用的音频格式")
        }
        let buffers = try convert(pcm, to: format)
        let start = Date()
        let collector = Task {
            var finalized = AttributedString(), volatile = AttributedString()
            for try await result in transcriber.results {
                if result.isFinal {
                    finalized += result.text
                    volatile = AttributedString()
                } else {
                    volatile = result.text
                }
                emit(["partial": String((finalized + volatile).characters), "at": Date().timeIntervalSince(start) * 1000])
            }
            return String(finalized.characters)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analysis = Task { try await analyzer.analyzeSequence(stream) }
        for (index, buffer) in buffers.enumerated() {
            let due = start.addingTimeInterval(Double(index) * Double(chunkFrames) / 16000)
            if due > Date() { try await Task.sleep(for: .seconds(due.timeIntervalSinceNow)) }
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        let end = Date()
        continuation.finish()
        if let last = try await analysis.value {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let final = try await collector.value
        emit(["final": final, "latency": Date().timeIntervalSince(end) * 1000])
    }

    /// 切成 200 毫秒一块，转成分析器要的格式。
    static func convert(_ pcm: Data, to format: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: format) else { throw Failure("建不了格式转换") }
        let frames = pcm.count / 2
        var result: [AVAudioPCMBuffer] = []
        var offset = 0
        while offset < frames {
            let count = min(Int(chunkFrames), frames - offset)
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)) else { throw Failure("分配不了缓冲") }
            input.frameLength = AVAudioFrameCount(count)
            pcm.withUnsafeBytes { raw in
                let samples = raw.bindMemory(to: Int16.self)
                for frame in 0..<count { input.int16ChannelData![0][frame] = samples[offset + frame] }
            }
            let capacity = AVAudioFrameCount(Double(count) * format.sampleRate / 16000) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw Failure("分配不了缓冲") }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            result.append(output)
            offset += count
        }
        return result
    }

    static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
