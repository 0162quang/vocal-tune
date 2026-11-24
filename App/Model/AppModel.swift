import AVFoundation
import Observation
import SwiftUI

enum RouteKind {
    case wired, bluetooth, speaker
    var title: String {
        switch self {
        case .wired: return "Tai nghe"
        case .bluetooth: return "Bluetooth"
        case .speaker: return "Loa ngoài"
        }
    }
    var icon: String {
        switch self {
        case .wired: return "headphones"
        case .bluetooth: return "airpods"
        case .speaker: return "speaker.wave.2.fill"
        }
    }
}

enum SheetKind: String, Identifiable {
    case advanced, scale, takes
    var id: String { rawValue }
}

@Observable @MainActor
final class AppModel {
    var settings = TuneSettings()
    var presetID: String? = "natural"
    var sheet: SheetKind?
    var monitorOn = false
    var isRecording = false
    var recordStart: Date?
    var route: RouteKind = .wired
    var forceMonitor = false
    var saverMode = false
    var thermalCritical = false
    var beatName: String?
    var beatPreviewing = false
    var takes: [Take] = []
    var busyText: String?
    var errorMessage: String?
    var showBeatImporter = false
    var playingTake: UUID?
    var exportNudgeMs = 0.0
    var latencyText = "—"

    @ObservationIgnored let audio = AudioIO()
    @ObservationIgnored let history = PitchHistory()
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var currentTakeDir: URL?
    @ObservationIgnored private var beatFileName: String?

    var monitorAllowed: Bool { route != .speaker || forceMonitor }
    var uiFPS: Double { saverMode ? 15 : 30 }
    var engineRunning: Bool { monitorOn || isRecording || beatPreviewing }

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var takesDir: URL { docs.appendingPathComponent("Takes", isDirectory: true) }
    private var beatsDir: URL { docs.appendingPathComponent("Beats", isDirectory: true) }

    init() {
        if let data = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(TuneSettings.self, from: data) {
            settings = s
        }
        try? FileManager.default.createDirectory(at: takesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: beatsDir, withIntermediateDirectories: true)
        loadTakes()
        observeSystem()
        adaptPerformance()
    }

    // MARK: Cài đặt

    func binding<T>(_ kp: WritableKeyPath<TuneSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] },
                set: { self.settings[keyPath: kp] = $0; self.settingsChanged() })
    }

    func settingsChanged(keepPreset: Bool = false) {
        if !keepPreset { presetID = nil }
        pushToEngine()
        persistTask?.cancel()
        persistTask = Task { [settings] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
        }
    }

    func applyPreset(_ p: Preset) {
        var s = settings
        p.apply(&s)
        settings = s
        presetID = p.id
        settingsChanged(keepPreset: true)
    }

    private func pushToEngine() {
        audio.apply(settings: settings, lowPower: saverMode, monitorAllowed: monitorAllowed)
    }

    // MARK: Engine

    private func ensureEngine() async -> Bool {
        if audio.isRunning { return true }
        let granted: Bool
        switch AVAudioApplication.shared.recordPermission {
        case .granted: granted = true
        case .denied: granted = false
        default: granted = await AVAudioApplication.requestRecordPermission()
        }
        guard granted else {
            errorMessage = "VocalTune cần quyền micro. Vào Cài đặt > VocalTune > Micro để bật."
            return false
        }
        do {
            try audio.start(settings: settings, lowPower: saverMode, bufferFrames: saverMode ? 256 : 128)
            evaluateRoute()
            latencyText = String(format: "≈ %.0f ms", audio.latencyMs)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func releaseEngineIfIdle() {
        if !engineRunning && audio.isRunning { audio.stop(); latencyText = "—" }
    }

    func toggleMonitor() {
        if monitorOn { monitorOn = false; releaseEngineIfIdle(); return }
        Task { if await ensureEngine() { monitorOn = true } }
    }

    // MARK: Thu âm

    func toggleRecord() {
        if isRecording { stopRecording() } else { Task { await startRecording() } }
    }

    private func startRecording() async {
        guard await ensureEngine() else { return }
        let id = UUID()
        let dir = takesDir.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try audio.startRecording(dryURL: dir.appendingPathComponent("dry.caf"),
                                     wetURL: dir.appendingPathComponent("wet.caf"))
        } catch {
            errorMessage = error.localizedDescription
            releaseEngineIfIdle()
            return
        }
        currentTakeDir = dir
        beatPreviewing = false
        audio.startBeat()
        recordStart = Date()
        isRecording = true
    }

    private func stopRecording() {
        guard isRecording, let dir = currentTakeDir, let start = recordStart else { return }
        audio.stopRecording()
        audio.stopBeat()
        isRecording = false
        let take = Take(id: UUID(uuidString: dir.lastPathComponent) ?? UUID(), date: start,
                        duration: Date().timeIntervalSince(start), settings: settings,
                        beatFile: beatFileName, latencyCompMs: audio.recordingCompensation * 1000,
                        sampleRate: audio.sampleRate)
        if let d = try? JSONEncoder().encode(take) { try? d.write(to: dir.appendingPathComponent("meta.json")) }
        takes.insert(take, at: 0)
        currentTakeDir = nil; recordStart = nil
        releaseEngineIfIdle()
    }

    // MARK: Beat

    func importBeat(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let e): errorMessage = e.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = beatsDir.appendingPathComponent(url.lastPathComponent)
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: url, to: dest)
                try audio.loadBeat(dest)
                beatFileName = dest.lastPathComponent
                beatName = url.deletingPathExtension().lastPathComponent
            } catch { errorMessage = "Không đọc được file nhạc nền: \(error.localizedDescription)" }
        }
    }

    func removeBeat() {
        beatPreviewing = false
        audio.stopBeat()
        try? audio.loadBeat(nil)
        beatFileName = nil; beatName = nil
        releaseEngineIfIdle()
    }

    func toggleBeatPreview() {
        if beatPreviewing {
            beatPreviewing = false; audio.stopBeat(); releaseEngineIfIdle()
        } else {
            Task {
                guard await ensureEngine() else { return }
                beatPreviewing = true
                audio.startBeat()
            }
        }
    }

    // MARK: Takes

    private func loadTakes() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: takesDir, includingPropertiesForKeys: nil)) ?? []
        takes = dirs.compactMap { d in
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")) else { return nil }
            return try? JSONDecoder().decode(Take.self, from: data)
        }.sorted { $0.date > $1.date }
    }

    private func dir(_ t: Take) -> URL { takesDir.appendingPathComponent(t.id.uuidString, isDirectory: true) }

    private func saveMeta(_ t: Take) {
        if let d = try? JSONEncoder().encode(t) { try? d.write(to: dir(t).appendingPathComponent("meta.json")) }
    }

    func delete(_ t: Take) {
        try? FileManager.default.removeItem(at: dir(t))
        takes.removeAll { $0.id == t.id }
    }

    func rerender(_ t: Take) {
        let d = dir(t), s = settings
        busyText = "Đang render lại…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try OfflineRenderer.render(dryURL: d.appendingPathComponent("dry.caf"),
                                               wetURL: d.appendingPathComponent("wet.caf"),
                                               settings: s) { p in
                        Task { @MainActor in self.busyText = "Đang render lại… \(Int(p * 100))%" }
                    }
                }.value
                if let i = takes.firstIndex(where: { $0.id == t.id }) {
                    takes[i].settings = s; takes[i].rendered = true; saveMeta(takes[i])
                }
            } catch { errorMessage = error.localizedDescription }
            busyText = nil
        }
    }

    /// Mix ra file (gối beat nếu có). Trả về URL tạm để chia sẻ hoặc nghe thử.
    func mixFile(_ t: Take, format: ExportFormat) async throws -> URL {
        let d = dir(t)
        let beatURL = t.beatFile.map { beatsDir.appendingPathComponent($0) }
        let beat = (beatURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false) ? beatURL : nil
        let name = "VocalTune \(t.date.formatted(.dateTime.year().month().day().hour().minute())).\(format.rawValue)"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let shift = -t.latencyCompMs + exportNudgeMs
        let (vg, bg) = (Float(t.settings.vocalGain), Float(t.settings.beatGain))
        busyText = "Đang mix…"
        defer { busyText = nil }
        try await Task.detached(priority: .userInitiated) {
            try Exporter.mix(vocalURL: d.appendingPathComponent("wet.caf"), beatURL: beat,
                             vocalGain: vg, beatGain: bg, shiftMs: shift, format: format, to: out) { _ in }
        }.value
        return out
    }

    func togglePlay(_ t: Take) {
        if playingTake == t.id { player?.stop(); playingTake = nil; return }
        Task {
            do {
                if audio.isRunning { monitorOn = false; beatPreviewing = false; audio.stop() }
                let url = try await mixFile(t, format: .m4a)
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                player = try AVAudioPlayer(contentsOf: url)
                player?.play()
                playingTake = t.id
            } catch { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Hệ thống: route, ngắt quãng, nhiệt, pin

    func sceneChanged(active: Bool) {
        if !active && !isRecording {
            monitorOn = false; beatPreviewing = false
            player?.stop(); playingTake = nil
            releaseEngineIfIdle()
        }
    }

    private func evaluateRoute() {
        let t = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType
        switch t {
        case .builtInSpeaker?, .builtInReceiver?: route = .speaker
        case .bluetoothA2DP?, .bluetoothLE?, .bluetoothHFP?: route = .bluetooth
        default: route = .wired
        }
        pushToEngine()
    }

    private func adaptPerformance() {
        let state = ProcessInfo.processInfo.thermalState
        let saver = state.rawValue >= ProcessInfo.ThermalState.serious.rawValue || ProcessInfo.processInfo.isLowPowerModeEnabled
        thermalCritical = state == .critical
        if saver != saverMode {
            saverMode = saver
            if audio.isRunning { audio.setBufferFrames(saver ? 256 : 128) }
            pushToEngine()
        }
    }

    private func observeSystem() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.evaluateRoute() }
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.isRecording { self.stopRecording() }
                self.monitorOn = false; self.beatPreviewing = false
                self.releaseEngineIfIdle()
            }
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.adaptPerformance() }
        }
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.adaptPerformance() }
        }
    }

    // MARK: Telemetry cho UI

    func pullTelemetry() {
        guard audio.isRunning else { return }
        history.push(audio.telemetry())
    }
}
