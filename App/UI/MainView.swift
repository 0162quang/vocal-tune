import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var m = model
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                TopBar()
                PitchRollView().frame(minHeight: 240)
                PresetStrip()
                KnobRow()
                ChipRow()
                RecordBar()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if let t = model.busyText {
                Text(t).font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.surface2, in: Capsule()).overlay(Capsule().stroke(Theme.hairline))
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 60)
            }
        }
        .sheet(item: $m.sheet) { kind in
            Group {
                switch kind {
                case .advanced: AdvancedSheet()
                case .scale: ScaleSheet()
                case .takes: TakesSheet()
                }
            }
            .environment(model)
            .presentationDetents(kind == .scale ? [.medium] : [.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.surface)
        }
        .fileImporter(isPresented: $m.showBeatImporter, allowedContentTypes: [.audio]) { model.importBeat($0) }
        .alert("Có lỗi", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }
}

struct TopBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 8) {
            Text("VocalTune").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(Theme.gradient)
            Spacer()
            if model.thermalCritical { Chip(icon: "thermometer.high", text: "Nóng", tint: Theme.rec) }
            else if model.saverMode { Chip(icon: "leaf.fill", text: "Tiết kiệm", tint: Theme.good) }
            Chip(icon: model.route.icon, text: model.route == .speaker && !model.monitorAllowed ? "Loa · tắt monitor" : model.route.title,
                 tint: model.route == .wired ? Theme.good : Theme.warn)
            Chip(icon: "waveform", text: model.latencyText)
        }
        .frame(height: 44)
    }
}

struct PresetStrip: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Preset.all) { p in
                    Button { model.applyPreset(p) } label: {
                        Chip(icon: nil, text: p.name, tint: Theme.accent, filled: model.presetID == p.id)
                    }.buttonStyle(.plain)
                }
            }
        }
        .frame(height: 40)
    }
}

struct KnobRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            KnobView(title: "Retune", value: model.binding(\.retuneMs), range: 0...400, defaultValue: 80) { $0 < 1 ? "0" : "\(Int($0))ms" }
            Spacer(minLength: 0)
            KnobView(title: "Amount", value: model.binding(\.amount), range: 0...1, defaultValue: 1) { "\(Int($0 * 100))%" }
            Spacer(minLength: 0)
            KnobView(title: "Formant", value: model.binding(\.formantSemis), range: -4...4, defaultValue: 0) { String(format: "%+.1f", $0) }
            Spacer(minLength: 0)
            KnobView(title: "Reverb", value: model.binding(\.reverbMix), range: 0...1, defaultValue: 0.15) { "\(Int($0 * 100))%" }
        }
        .padding(.horizontal, 6).padding(.vertical, 10).card()
    }
}

struct ChipRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { model.sheet = .scale } label: {
                    let s = model.settings
                    Chip(icon: "pianokeys", text: "\(noteNames[s.keyRoot]) \(s.scale.title)", tint: Theme.text)
                }
                Menu {
                    if model.beatName == nil {
                        Button("Chọn file nhạc nền", systemImage: "folder") { model.showBeatImporter = true }
                    } else {
                        Button(model.beatPreviewing ? "Dừng nghe thử" : "Nghe thử", systemImage: model.beatPreviewing ? "pause" : "play") { model.toggleBeatPreview() }
                        Button("Đổi nhạc nền", systemImage: "folder") { model.showBeatImporter = true }
                        Button("Bỏ nhạc nền", systemImage: "trash", role: .destructive) { model.removeBeat() }
                    }
                } label: {
                    Chip(icon: model.beatPreviewing ? "pause.fill" : "music.note", text: model.beatName ?? "Beat", tint: Theme.cyan)
                }
                Button { model.toggleMonitor() } label: {
                    Chip(icon: "ear", text: "Monitor", tint: Theme.good, filled: model.monitorOn)
                }
                Button { model.sheet = .advanced } label: {
                    Chip(icon: "slider.horizontal.3", text: "Nâng cao", tint: Theme.text)
                }
            }.buttonStyle(.plain)
        }
        .frame(height: 38)
    }
}

struct RecordBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            Group {
                if let start = model.recordStart {
                    TimelineView(.periodic(from: start, by: 1)) { ctx in
                        let s = Int(ctx.date.timeIntervalSince(start))
                        Text(String(format: "%02d:%02d", s / 60, s % 60))
                    }
                } else { Text("00:00") }
            }
            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(model.isRecording ? Theme.rec : Theme.textDim)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { model.toggleRecord() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.85), lineWidth: 4).frame(width: 76, height: 76)
                    RoundedRectangle(cornerRadius: model.isRecording ? 8 : 30, style: .continuous)
                        .fill(Theme.rec).frame(width: model.isRecording ? 30 : 60, height: model.isRecording ? 30 : 60)
                }
                .animation(.easeOut(duration: 0.15), value: model.isRecording)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.impact, trigger: model.isRecording)
            .accessibilityLabel(model.isRecording ? "Dừng thu" : "Bắt đầu thu")

            Button { model.sheet = .takes } label: {
                Image(systemName: "square.stack").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Theme.text).frame(width: 52, height: 52)
                    .background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.hairline))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("Các bản thu")
        }
        .frame(height: 84)
    }
}
