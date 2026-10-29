import Accelerate
import AVFoundation
import Synchronization
#if os(macOS)
import CoreAudio
#endif

/// 识别出来的字：中间结果和定稿都是到目前为止的全文，出错时给原因。定稿之后工作机可能再整理成书面的字：边生成边给到目前为止整理出的字（tidying），
/// 整理完给全文，带着它整理的那份定稿。整理后的字、出错和 ended 都是这段识别的最后一条；ended 是工作机没给整理后的字就收尾了。
enum VoiceText: Sendable {
    case partial(String)
    case final(String)
    case tidying(String)
    case tidied(String, from: String)
    case failed(String)
    case ended
}

/// 识别交给哪台工作机；thread 是正在输入的会话，新会话还没有实例时为空，工作机就不带对话。
struct VoiceTarget {
    let client: KitedClient
    let thread: String?
}

/// 语音输入的录音。一台设备只有一支麦克风，同一时间只有一处在录，owner 是正在录的那个会话窗口。
/// 录音时给点阵签名出响度 v，同时把声音推给工作机识别；停下后工作机给出定稿，字由 update 交给输入框。
@Observable
final class VoiceInput {
    nonisolated enum Failure: LocalizedError {
        case denied, noDevice, unsupported

        var errorDescription: String? {
            switch self {
            case .denied: "Kite 没有麦克风权限，请在系统设置的隐私与安全性里打开。"
            case .noDevice: "没有找到可用的麦克风。"
            case .unsupported: "麦克风的音频格式不受支持。"
            }
        }
    }

    /// 一段识别的字还要不要交出去：录着的时候发出了消息（restart），旧的那段作废。
    private final class Segment { var live = true }

    /// 正在录的控制区：麦克风一开就是它，连工作机期间也是；授权弹窗期间还是 nil。
    private(set) var owner: String?
    let level = AudioLevel()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sampleRate: Double = 0
    @ObservationIgnored private var stream: VoiceStream?
    @ObservationIgnored private var segment: Segment?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// 每次开始或停止加一。授权弹窗和连工作机会让出主线程，这期间又停止或换了别处开始时，迟到的那次开始按它作废。
    @ObservationIgnored private var generation = 0

    /// 开始录音，连上工作机后推流。返回 false 是连工作机期间停了、又开了一段或发了消息，这一次没推起来。
    @discardableResult
    func start(owner: String, target: VoiceTarget, update: @escaping @MainActor @Sendable (VoiceText) -> Void) async throws -> Bool {
        stop()
        let current = generation
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.denied }
        guard current == generation else { return false }
        #if os(macOS)
        // 设备拔掉后输入节点仍报旧格式，接着配置引擎会抛 ObjC 异常、Swift 接不住，所以先问系统有没有默认输入设备
        guard Self.hasInputDevice else { throw Failure.noDevice }
        #else
        let session = AVAudioSession.sharedInstance()
        // 别的 App 在放的声音压低而不打断；只录不放，声音不改走听筒
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        // 没走到录音开始就停掉引擎（没启动时 stop 什么也不做），交还音频会话
        var started = false
        defer { if !started { engine.stop(); deactivate() } }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noDevice }
        guard format.commonFormat == .pcmFormatFloat32 else { throw Failure.unsupported }
        let samples = level.samples
        samples.reset()
        let sink = AVAudioSinkNode(receiverBlock: Self.receiver(samples, interleaved: format.isInterleaved,
                                                                channels: Int(format.channelCount)))
        engine.attach(sink)
        if #available(macOS 27, iOS 27, *) {
            try engine.connectNode(input, to: sink, format: format)
        } else {
            engine.connect(input, to: sink, format: format)
        }
        try engine.start()
        // 先录起来，点阵当场随声音起伏，连工作机期间的声音攒在环形缓冲里，连上后一起推
        started = true
        self.engine = engine
        sampleRate = format.sampleRate
        self.owner = owner
        level.begin()
        observe(engine)
        let segment = Segment()
        self.segment = segment
        do {
            let (connection, socket) = try await target.client.voiceSocket(thread: target.thread)
            let stream = try VoiceStream(session: connection, socket: socket, samples: samples, sampleRate: format.sampleRate,
                                         update: Self.guarded(update, by: segment))
            // 连工作机期间停了、又开了一段（都换了 generation），或发了消息另起一段（segment 作废，新的那段自己连）
            guard current == generation, segment.live else {
                await stream.cancel()
                return false
            }
            self.stream = stream
            await stream.begin()
            return true
        } catch {
            if current == generation { stop() }
            throw error
        }
    }

    /// 录着的时候发出了消息：这一段识别作废，迟到的字不再交出去，工作机那边取消、不定稿；麦克风不停，从这一刻的声音起另开一段，
    /// 字交给 update，连不上工作机也经它报错。不是 owner 在录时什么也不做。
    func restart(owner: String, target: VoiceTarget, update: @escaping @MainActor @Sendable (VoiceText) -> Void) {
        guard owner == self.owner, engine != nil else { return }
        self.segment?.live = false
        if let stream { Task { await stream.cancel() } }
        stream = nil
        let current = generation
        let samples = level.samples, sampleRate = sampleRate, position = samples.position
        let segment = Segment()
        self.segment = segment
        let update = Self.guarded(update, by: segment)
        Task {
            do {
                let (connection, socket) = try await target.client.voiceSocket(thread: target.thread)
                let stream = try VoiceStream(session: connection, socket: socket, samples: samples, sampleRate: sampleRate,
                                             from: position, update: update)
                // 连工作机期间停了、或又发了一条
                guard current == generation, segment.live else {
                    await stream.cancel()
                    return
                }
                self.stream = stream
                await stream.begin()
            } catch {
                update(.failed(error.localizedDescription))
            }
        }
    }

    private static func guarded(_ update: @escaping @MainActor @Sendable (VoiceText) -> Void,
                                by segment: Segment) -> @MainActor @Sendable (VoiceText) -> Void {
        { text in if segment.live { update(text) } }
    }

    /// 停止录音，已录的声音交给工作机定稿；给出 owner 时只停它自己的。
    func stop(owner: String? = nil) {
        if let owner, owner != self.owner { return }
        generation += 1
        guard let engine else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        engine.stop()
        self.engine = nil
        self.owner = nil
        level.end()
        deactivate()
        if let stream { Task { await stream.finish() } }
        stream = nil
    }

    private func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// 换了输入设备或被来电等打断时直接停下，不在半路重配引擎。
    private func observe(_ engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        })
        #endif
    }

    /// 实时线程上把输入的第一个声道写进环形缓冲，不在这里分配内存或做变换。
    private nonisolated static func receiver(_ samples: SampleRing, interleaved: Bool, channels: Int) -> AVAudioSinkNodeReceiverBlock {
        { _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
            guard let data = buffers.first?.mData else { return noErr }
            samples.write(data.assumingMemoryBound(to: Float.self), frames: Int(frames), stride: interleaved ? channels : 1)
            return noErr
        }
    }

    #if os(macOS)
    private static var hasInputDevice: Bool {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown
    }
    #endif
}

/// 一次录音到工作机的流：每 100 毫秒把新采样转成 16 kHz 单声道 s16le 推上去，收中间结果、定稿和整理后的字。协议见 kited 的 voice/sessions.ts。
private actor VoiceStream {
    private struct Event: Decodable {
        let type: String
        var text: String?
        var message: String?
    }

    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let samples: SampleRing
    private let update: @MainActor @Sendable (VoiceText) -> Void
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter
    /// 下一次从环形缓冲的哪里读。
    private var position: Int
    private var scratch = [Float](repeating: 0, count: SampleRing.capacity)
    private var pump: Task<Void, Never>?
    /// 定稿或出错之后不再报错，连接断开是正常收尾。
    private var settled = false
    /// 作废了（发了消息另起一段、连上时已经停了），之后什么都不交。
    private var cancelled = false
    /// 收到的定稿，整理后的字随它交出去。
    private var finalText = ""

    /// position 是从缓冲的哪里推起：开录时从头，发消息另起一段时从那一刻。
    init(session: URLSession, socket: URLSessionWebSocketTask, samples: SampleRing, sampleRate: Double, from position: Int = 0,
         update: @escaping @MainActor @Sendable (VoiceText) -> Void) throws {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: output) else { throw VoiceInput.Failure.unsupported }
        self.session = session
        self.socket = socket
        self.samples = samples
        self.position = position
        self.update = update
        self.source = source
        self.target = output
        self.converter = converter
    }

    func begin() {
        socket.resume()
        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.push()
            }
        }
        Task { await receive() }
    }

    /// 推完剩下的声音，告诉工作机说完了；定稿到了再断开。
    func finish() async {
        pump?.cancel()
        await push()
        try? await socket.send(.string(#"{"type":"finish"}"#))
    }

    func cancel() {
        cancelled = true
        pump?.cancel()
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    private func push() async {
        let (count, next) = samples.read(from: position, into: &scratch)
        position = next
        guard count > 0, let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(count)),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(count) * 16000 / source.sampleRate) + 32)
        else { return }
        input.frameLength = AVAudioFrameCount(count)
        scratch.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
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
        guard error == nil, output.frameLength > 0, let data = output.int16ChannelData?[0] else { return }
        try? await socket.send(.data(Data(bytes: data, count: Int(output.frameLength) * 2)))
    }

    private func receive() async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive(),
                      let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8)) else { continue }
                switch event.type {
                case "partial": await update(.partial(event.text ?? ""))
                case "final":
                    // 接着等整理后的字，工作机整理完或不整理都会关掉连接
                    settled = true
                    finalText = event.text ?? ""
                    await update(.final(finalText))
                case "tidying": await update(.tidying(event.text ?? ""))
                case "tidied":
                    await update(.tidied(event.text ?? "", from: finalText))
                    close()
                    return
                case "error":
                    settled = true
                    await update(.failed(event.message ?? "语音识别出错"))
                    close()
                    return
                default: break
                }
            }
        } catch {
            if !cancelled { await update(settled ? .ended : .failed("和工作机的语音连接断开：\(error.localizedDescription)")) }
            close()
        }
    }

    private func close() {
        pump?.cancel()
        socket.cancel(with: .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}

/// 最近一段采样，实时线程写，主线程取最近一截算响度，推流的一侧按位置接着读。
nonisolated final class SampleRing: Sendable {
    private struct State {
        var samples = [Float](repeating: 0, count: SampleRing.capacity)
        /// 一共写进来多少个，取余就是下一个写的位置。
        var written = 0
    }

    /// 48 kHz 下约 5 秒，连工作机期间的声音也放得下。
    static let capacity = 1 << 18
    private let state = Mutex(State())

    /// 一共写进来多少个：推流从这里接着读，就是从这一刻的声音起。
    var position: Int { state.withLock { $0.written } }

    func reset() {
        state.withLock { state in
            for index in state.samples.indices { state.samples[index] = 0 }
            state.written = 0
        }
    }

    func write(_ data: UnsafePointer<Float>, frames: Int, stride: Int) {
        state.withLock { state in
            for frame in 0..<frames {
                state.samples[state.written & (Self.capacity - 1)] = data[frame * stride]
                state.written += 1
            }
        }
    }

    /// 最近 count 个采样，从旧到新写进 output。
    func latest(_ count: Int, into output: inout [Float]) {
        state.withLock { state in
            let start = state.written - count
            for index in 0..<count { output[index] = state.samples[(start + index) & (Self.capacity - 1)] }
        }
    }

    /// 从 position 起到最新的采样，最多 output.count 个；落后太多时从还留着的最早一个读起。返回读了几个和下次从哪读。
    func read(from position: Int, into output: inout [Float]) -> (count: Int, next: Int) {
        state.withLock { state in
            let start = max(position, state.written - Self.capacity)
            let count = min(state.written - start, output.count)
            for index in 0..<count { output[index] = state.samples[(start + index) & (Self.capacity - 1)] }
            return (count, start + count)
        }
    }
}

/// 声音的响度（0～1），即点阵签名表达式里的 v。每帧取最近约 20 毫秒的采样算一次均方根；
/// 上限跟着最近的峰值走，说话轻重、麦克风增益不同都能撑满，静音时落回 0。
final class AudioLevel {
    /// 每帧取多少个采样，48 kHz 下约 21 毫秒。
    private static let window = 1024
    /// 上升快、回落慢，跟得上字头又不乱闪。
    private static let attack = 0.04
    private static let release = 0.2
    /// 上限每秒回落多少分贝，以及最低压到哪里：再低就把底噪也撑满了。
    private static let peakFall = 9.0
    private static let quietest = -42.0
    /// 上限往下多少分贝算 0。
    private static let span = 36.0

    nonisolated let samples = SampleRing()
    private var buffer = [Float](repeating: 0, count: AudioLevel.window)
    private var value = 0.0
    private var peak = AudioLevel.quietest
    private var updated: Date?
    private var active = false

    func begin() {
        active = true
        updated = nil
        value = 0
        peak = Self.quietest
    }

    /// 停下后按回落的速度落回 0。
    func end() { active = false }

    /// date 时刻的响度。同一帧里多个取景框来取只算一次。
    func level(at date: Date) -> Double {
        guard updated != date else { return value }
        let dt = updated.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? 0
        updated = date
        let target = active ? measure(dt: dt) : 0
        let tau = target > value ? Self.attack : Self.release
        value += (target - value) * (dt > 0 ? 1 - exp(-dt / tau) : 0)
        return value
    }

    private func measure(dt: Double) -> Double {
        samples.latest(Self.window, into: &buffer)
        let decibels = 20 * log10(Double(vDSP.rootMeanSquare(buffer)) + 1e-9)
        peak = max(decibels, peak - Self.peakFall * dt, Self.quietest)
        return min(max((decibels - (peak - Self.span)) / Self.span, 0), 1)
    }
}
