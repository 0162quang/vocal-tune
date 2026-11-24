import AVFoundation

enum AudioError: LocalizedError {
    case noInput
    var errorDescription: String? { "Không tìm thấy micro. Kiểm tra quyền truy cập micro trong Cài đặt." }
}

/// Bao quanh AVAudioEngine. Callback thời gian thực chỉ gọi thẳng vào C, không đụng runtime Swift.
final class AudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var vocalMix: AVAudioMixerNode?
    private var dsp: UnsafeMutableRawPointer?
    private let scratchFrames = 4096
    private let scratch: UnsafeMutablePointer<Float>

    private(set) var sampleRate: Double = 48000
    private(set) var isRunning = false
    private(set) var beatFile: AVAudioFile?
    private var beatPlaying = false

    private var dryFile: AVAudioFile?
    private var wetFile: AVAudioFile?
    private var writerTimer: DispatchSourceTimer?
    private let writerQueue = DispatchQueue(label: "vocaltune.writer", qos: .utility)
    private var drainBuf: AVAudioPCMBuffer?

    init() {
        scratch = .allocate(capacity: scratchFrames)
        scratch.initialize(repeating: 0, count: scratchFrames)
    }
    deinit { scratch.deallocate() }

    var latencyMs: Double {
        guard let dsp else { return 0 }
        let d = Double(vt_latency(dsp)) / sampleRate
        let s = AVAudioSession.sharedInstance()
        return (d + s.ioBufferDuration * 2 + s.inputLatency + s.outputLatency) * 1000
    }

    /// Độ trễ cần trừ khi mix gối beat (giây).
    var recordingCompensation: Double {
        let s = AVAudioSession.sharedInstance()
        return s.inputLatency + s.outputLatency + s.ioBufferDuration
    }

    // MARK: Điều khiển engine

    func start(settings: TuneSettings, lowPower: Bool, bufferFrames: Int) throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement,
                                options: [.allowBluetoothA2DP, .defaultToSpeaker])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(Double(bufferFrames) / 48000.0)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let hw = engine.inputNode.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw AudioError.noInput }
        sampleRate = hw.sampleRate

        guard let handle = vt_create(Float(hw.sampleRate), Int32(settings.range.rawValue)) else { throw AudioError.noInput }
        dsp = handle
        var p = settings.vtParams(lowPower: lowPower)
        vt_set_params(handle, &p)

        // Mic -> DSP
        let scratchPtr = scratch
        let scratchCap = scratchFrames
        let sink = AVAudioSinkNode { _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard list.count > 0, let raw = list[0].mData else { return noErr }
            let src = raw.assumingMemoryBound(to: Float.self)
            let ch = Int(list[0].mNumberChannels)
            let n = Int(frames)
            if ch <= 1 {
                vt_capture(handle, src, Int32(n))
            } else {
                let m = min(n, scratchCap)
                for i in 0..<m { scratchPtr[i] = src[i * ch] }
                vt_capture(handle, scratchPtr, Int32(m))
            }
            return noErr
        }

        // DSP -> tai nghe
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: hw.sampleRate, channels: 2)!
        let source = AVAudioSourceNode(format: outFmt) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count > 0, let raw = list[0].mData else { return noErr }
            let p0 = raw.assumingMemoryBound(to: Float.self)
            vt_monitor(handle, p0, Int32(frames))
            if list.count > 1, let r1 = list[1].mData {
                memcpy(r1, p0, Int(frames) * MemoryLayout<Float>.size)
            }
            return noErr
        }

        let vocalMix = AVAudioMixerNode()
        let player = AVAudioPlayerNode()
        engine.attach(sink); engine.attach(source); engine.attach(vocalMix); engine.attach(player)
        engine.connect(engine.inputNode, to: sink, format: hw)
        engine.connect(source, to: vocalMix, format: outFmt)
        engine.connect(vocalMix, to: engine.mainMixerNode, format: outFmt)
        if let beat = beatFile {
            engine.connect(player, to: engine.mainMixerNode, format: beat.processingFormat)
        }
        vocalMix.outputVolume = Float(settings.vocalGain)
        player.volume = Float(settings.beatGain)

        engine.prepare()
        try engine.start()
        self.engine = engine; self.player = player; self.vocalMix = vocalMix
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        if dryFile != nil { stopRecording() }
        player?.stop(); beatPlaying = false
        engine?.stop()
        engine = nil; player = nil; vocalMix = nil
        if let dsp { vt_destroy(dsp) }
        dsp = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func apply(settings: TuneSettings, lowPower: Bool, monitorAllowed: Bool) {
        guard let dsp else { return }
        var p = settings.vtParams(lowPower: lowPower)
        vt_set_params(dsp, &p)
        vocalMix?.outputVolume = monitorAllowed ? Float(settings.vocalGain) : 0
        player?.volume = Float(settings.beatGain)
    }

    func setBufferFrames(_ frames: Int) {
        try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(Double(frames) / 48000.0)
    }

    func telemetry() -> VTTelemetry {
        var t = VTTelemetry()
        if let dsp { vt_get_telemetry(dsp, &t) }
        return t
    }

    // MARK: Beat

    func loadBeat(_ url: URL?) throws {
        let wasRunning = beatPlaying
        if wasRunning { stopBeat() }
        beatFile = try url.map { try AVAudioFile(forReading: $0) }
        // Đổi beat khi engine đang chạy: cần dựng lại graph cho node player.
        if isRunning, let engine, let player, let beat = beatFile {
            engine.connect(player, to: engine.mainMixerNode, format: beat.processingFormat)
        }
    }

    func startBeat() {
        guard isRunning, let player, let beat = beatFile else { return }
        player.stop()
        player.scheduleFile(beat, at: nil, completionHandler: nil)
        player.play()
        beatPlaying = true
    }

    func stopBeat() { player?.stop(); beatPlaying = false }
    var isBeatPlaying: Bool { beatPlaying }

    // MARK: Ghi âm (dry + wet)

    func startRecording(dryURL: URL, wetURL: URL) throws {
        guard let dsp else { throw AudioError.noInput }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        dryFile = try AVAudioFile(forWriting: dryURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        wetFile = try AVAudioFile(forWriting: wetURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        drainBuf = AVAudioPCMBuffer(pcmFormat: dryFile!.processingFormat, frameCapacity: 8192)

        let timer = DispatchSource.makeTimerSource(queue: writerQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        writerTimer = timer
        vt_set_recording(dsp, 1)
    }

    private func drain() {
        guard let dsp, let buf = drainBuf, let ch = buf.floatChannelData?[0] else { return }
        for (file, isDry) in [(dryFile, true), (wetFile, false)] {
            guard let file else { continue }
            while true {
                let n = isDry ? vt_read_dry(dsp, ch, 8192) : vt_read_wet(dsp, ch, 8192)
                if n <= 0 { break }
                buf.frameLength = AVAudioFrameCount(n)
                try? file.write(from: buf)
            }
        }
    }

    func stopRecording() {
        if let dsp { vt_set_recording(dsp, 0) }
        writerTimer?.cancel(); writerTimer = nil
        writerQueue.sync { self.drain() }
        dryFile = nil; wetFile = nil; drainBuf = nil
    }
}
