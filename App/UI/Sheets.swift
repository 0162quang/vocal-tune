import SwiftUI

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 15))
                Spacer()
                Text(format(value)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.textDim)
            }
            if step > 0 { Slider(value: $value, in: range, step: step).tint(Theme.accent) }
            else { Slider(value: $value, in: range).tint(Theme.accent) }
        }
        .padding(.vertical, 4)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textDim)
            content
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

struct AdvancedSheet: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: "Tuning") {
                    SliderRow(title: "Retune speed", value: model.binding(\.retuneMs), range: 0...400, step: 1) { $0 < 1 ? "0 ms (robot)" : "\(Int($0)) ms" }
                    SliderRow(title: "Correction amount", value: model.binding(\.amount), range: 0...1) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Humanize (flex)", value: model.binding(\.flexCents), range: 0...50, step: 1) { $0 < 1 ? "tắt" : "\(Int($0))¢" }
                    SliderRow(title: "Giữ vibrato", value: model.binding(\.vibratoKeep), range: 0...1) { "\(Int($0 * 100))%" }
                }
                SectionCard(title: "Giọng") {
                    SliderRow(title: "Formant", value: model.binding(\.formantSemis), range: -4...4, step: 0.1) { String(format: "%+.1f nửa cung", $0) }
                    Stepper("Transpose: \(model.settings.transpose > 0 ? "+" : "")\(model.settings.transpose) nửa cung",
                            value: model.binding(\.transpose), in: -12...12)
                    SliderRow(title: "Detune", value: model.binding(\.detune), range: -50...50, step: 1) { "\(Int($0))¢" }
                    SliderRow(title: "A4", value: model.binding(\.refA4), range: 415...466, step: 1) { "\(Int($0)) Hz" }
                    Picker("Dải giọng", selection: model.binding(\.range)) {
                        ForEach(VoiceRange.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Text("\(model.settings.range.detail). Đổi dải giọng có hiệu lực ở lần bật Monitor tiếp theo.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
                SectionCard(title: "Đầu vào") {
                    SliderRow(title: "Gain mic", value: model.binding(\.inputGainDb), range: -12...24, step: 1) { "\(Int($0)) dB" }
                    SliderRow(title: "Gate", value: model.binding(\.gateDb), range: -80 ... -30, step: 1) { $0 <= -80 ? "tắt" : "\(Int($0)) dB" }
                }
                SectionCard(title: "Hiệu ứng") {
                    SliderRow(title: "Compressor", value: model.binding(\.comp), range: 0...1) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Reverb", value: model.binding(\.reverbMix), range: 0...1) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Kích thước reverb", value: model.binding(\.reverbSize), range: 0...1) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Delay", value: model.binding(\.delayMix), range: 0...1) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Thời gian delay", value: model.binding(\.delayMs), range: 60...900, step: 10) { "\(Int($0)) ms" }
                    SliderRow(title: "Feedback", value: model.binding(\.delayFeedback), range: 0...0.85) { "\(Int($0 * 100))%" }
                }
                SectionCard(title: "Mix") {
                    SliderRow(title: "Giọng", value: model.binding(\.vocalGain), range: 0...1.5) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Beat", value: model.binding(\.beatGain), range: 0...1.2) { "\(Int($0 * 100))%" }
                    SliderRow(title: "Âm lượng ra", value: model.binding(\.outputGainDb), range: -12...6, step: 1) { "\(Int($0)) dB" }
                    Toggle("Cho phép monitor khi ra loa ngoài", isOn: Binding(get: { model.forceMonitor }, set: { model.forceMonitor = $0; model.settingsChanged(keepPreset: true) }))
                        .tint(Theme.accent)
                    Text("Dễ gây hú. Chỉ bật khi biết mình đang làm gì.").font(.system(size: 12)).foregroundStyle(Theme.textDim)
                }
            }
            .padding(16)
        }
    }
}

struct ScaleSheet: View {
    @Environment(AppModel.self) private var model
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 14) {
            Text("Key").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(0..<12, id: \.self) { i in
                    Button {
                        var t = model.settings; t.keyRoot = i
                        if t.scale == .custom { t.scale = .chromatic }
                        model.settings = t; model.settingsChanged()
                    } label: { Chip(icon: nil, text: noteNames[i], tint: Theme.accent, filled: s.keyRoot == i).frame(maxWidth: .infinity) }
                    .buttonStyle(.plain)
                }
            }
            Text("Scale").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ScaleType.allCases.filter { $0 != .custom }) { sc in
                        Button {
                            model.settings.scale = sc; model.settingsChanged()
                        } label: { Chip(icon: nil, text: sc.title, tint: Theme.cyan, filled: s.scale == sc) }.buttonStyle(.plain)
                    }
                }
            }
            Text("Nốt được phép (chạm để bật/tắt)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textDim)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(0..<12, id: \.self) { i in
                    let on = (s.noteMask >> UInt16(i)) & 1 == 1
                    Button {
                        var t = model.settings
                        var mask = t.noteMask; mask ^= (1 << UInt16(i))
                        if mask == 0 { mask = 1 << UInt16(i) }
                        t.customMask = mask; t.scale = .custom
                        model.settings = t; model.settingsChanged()
                    } label: { Chip(icon: nil, text: noteNames[i], tint: Theme.good, filled: on).frame(maxWidth: .infinity) }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(16)
    }
}

struct TakesSheet: View {
    @Environment(AppModel.self) private var model
    @State private var shareURL: URL?
    @State private var format: ExportFormat = .m4a

    var body: some View {
        @Bindable var m = model
        VStack(spacing: 0) {
            HStack {
                Text("Bản thu").font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Picker("", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 130)
            }.padding([.horizontal, .top], 16)
            VStack(alignment: .leading, spacing: 2) {
                SliderRow(title: "Chỉnh khớp giọng–beat khi xuất", value: $m.exportNudgeMs, range: -300...300, step: 5) { "\(Int($0)) ms" }
            }.padding(.horizontal, 16)
            if model.takes.isEmpty {
                Spacer(); Text("Chưa có bản thu nào").foregroundStyle(Theme.textDim); Spacer()
            } else {
                List {
                    ForEach(model.takes) { t in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(t.title).font(.system(size: 16, weight: .semibold))
                                    Text(String(format: "%d:%02d%@", Int(t.duration) / 60, Int(t.duration) % 60, t.rendered ? " · đã render lại" : ""))
                                        .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Button { model.togglePlay(t) } label: {
                                    Image(systemName: model.playingTake == t.id ? "stop.fill" : "play.fill").frame(width: 44, height: 44)
                                }.buttonStyle(.plain)
                            }
                            HStack(spacing: 8) {
                                Button { model.rerender(t) } label: { Chip(icon: "wand.and.stars", text: "Render lại (Studio)", tint: Theme.accent) }
                                Button {
                                    Task { shareURL = try? await model.mixFile(t, format: format) }
                                } label: { Chip(icon: "square.and.arrow.up", text: "Xuất", tint: Theme.cyan) }
                            }.buttonStyle(.plain)
                        }
                        .listRowBackground(Theme.surface2)
                        .swipeActions { Button("Xóa", role: .destructive) { model.delete(t) } }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: Binding(get: { shareURL.map { ShareItem(url: $0) } }, set: { if $0 == nil { shareURL = nil } })) { item in
            ShareSheet(url: item.url).presentationDetents([.medium])
        }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: URL { url } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
