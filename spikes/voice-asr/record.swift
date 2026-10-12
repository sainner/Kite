// 照朗读稿（scripts.json）逐段录样本：每段一个目录，按麦克风原格式存 audio.caf（跑对比时再转 16 kHz 单声道），
// 以及原文、要认对的词和对话上下文。已经录过的段跳过，中途退出下次接着录。
// 用法（在自己的终端里跑，不能用 Claude Code 的 ! 前缀，第一次会请求麦克风权限）：
//   xcrun swift spikes/voice-asr/record.swift <样本目录>
import AVFoundation

struct Scripts: Decodable {
    struct Sample: Decodable {
        let context: String?
        let text: String
        let terms: [String]
    }

    let contexts: [String: String]
    let samples: [Sample]
}

/// 一段录音的文件。设备格式在启动后还可能变，文件等第一块采样到了才按它的格式建。
final class Recording: @unchecked Sendable {
    let url: URL
    var file: AVAudioFile?
    var error: Error?

    init(url: URL) { self.url = url }

    var seconds: Double { file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0 }
}

/// 录音线程上把每块采样写进文件，同一行刷新音量条；主线程在等回车。
func writer(_ recording: Recording) -> AVAudioNodeTapBlock {
    { buffer, _ in
        do {
            if recording.file == nil {
                let format = buffer.format
                recording.file = try AVAudioFile(forWriting: recording.url, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            }
            try recording.file?.write(from: buffer)
        } catch {
            recording.error = error
        }
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let decibels = 10 * log10(sum / Float(buffer.frameLength) + 1e-10)
        let bars = max(0, min(30, Int((decibels + 60) / 2)))
        print("\r● 录音中，念完按回车 " + String(repeating: "▮", count: bars) + String(repeating: " ", count: 30 - bars), terminator: "")
        fflush(stdout)
    }
}

let root = URL(fileURLWithPath: ((CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "~/kite-voice-samples") as NSString).expandingTildeInPath)
let scripts = try JSONDecoder().decode(Scripts.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("scripts.json")))
guard await AVAudioApplication.requestRecordPermission() else {
    print("没有麦克风权限：在系统设置 › 隐私与安全性 › 麦克风里打开这个终端。")
    exit(1)
}
print("""
样本存在 \(root.path)，共 \(scripts.samples.count) 段，录过的跳过。
念的时候按平时说话的语速；英文和文件名按平时的读法，里面的点、斜杠、横线不用念。
""")

samples: for (index, sample) in scripts.samples.enumerated() {
    let name = String(format: "%02d", index + 1)
    let directory = root.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent("reference.txt").path) { continue }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    while true {
        print("\n第 \(name)/\(scripts.samples.count) 段\(sample.context == nil ? "" : "（带对话上下文 \(sample.context!)）")：\n\n    \(sample.text)\n")
        print("回车开始录，s 跳过，q 结束：", terminator: "")
        let command = readLine()?.trimmingCharacters(in: .whitespaces) ?? "q"
        if command == "q" { break samples }
        if command == "s" { continue samples }
        for old in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where old.hasPrefix("audio.") {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        }
        // 每段新建引擎、不指定格式，跟着设备当时的格式走
        let engine = AVAudioEngine()
        guard engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            print("没有可用的麦克风。")
            exit(1)
        }
        let recording = Recording(url: directory.appendingPathComponent("audio.caf"))
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil, block: writer(recording))
        try engine.start()
        print("● 录音中，念完按回车", terminator: "")
        fflush(stdout)
        _ = readLine()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        let seconds = recording.seconds
        if let error = recording.error { print("\n写文件出错：\(error)") }
        if seconds < 0.3 {
            print("\n没录到声音（\(String(format: "%.1f", seconds)) 秒）。看看系统设置 › 隐私与安全性 › 麦克风里有没有打开这个终端，再重录。")
            continue
        }
        print(String(format: "\n录了 %.1f 秒。回车保存，r 重录：", seconds), terminator: "")
        if readLine()?.trimmingCharacters(in: .whitespaces) == "r" { continue }
        try (sample.text + "\n").write(to: directory.appendingPathComponent("reference.txt"), atomically: true, encoding: .utf8)
        try (sample.terms.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("terms.txt"), atomically: true, encoding: .utf8)
        if let key = sample.context, let context = scripts.contexts[key] {
            try (context + "\n").write(to: directory.appendingPathComponent("context.txt"), atomically: true, encoding: .utf8)
        }
        break
    }
}
print("\n录完了。跑对比：bun spikes/voice-asr/run.ts \(root.path) qwen,apple")
