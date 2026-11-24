import SwiftUI

/// Lịch sử cao độ ~8 giây ở 30 mẫu/giây. Lớp thường (không phải Observable) để không kích hoạt render SwiftUI.
final class PitchHistory {
    struct Sample { var inMidi: Float; var outMidi: Float; var target: Float; var voiced: Bool }
    static let capacity = 240
    private(set) var samples: [Sample] = []
    var center: Float = 60

    init() { samples.reserveCapacity(Self.capacity) }

    func push(_ t: VTTelemetry) {
        let s = Sample(inMidi: t.inMidi, outMidi: t.outMidi, target: t.targetMidi, voiced: t.voiced != 0)
        if samples.count >= Self.capacity { samples.removeFirst() }
        samples.append(s)
        if s.voiced { center += (s.outMidi - center) * 0.04 }
    }
    func clear() { samples.removeAll(keepingCapacity: true) }
}

struct PitchRollView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / model.uiFPS, paused: !model.audio.isRunning)) { _ in
            Canvas { ctx, size in
                model.pullTelemetry()
                draw(ctx, size)
            }
        }
        .card()
        .accessibilityLabel("Biểu đồ cao độ")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let h = model.history
        let span: Float = 14
        let mask = model.settings.noteMask
        let lo = h.center - span / 2
        func y(_ m: Float) -> CGFloat { size.height * CGFloat(1 - (m - lo) / span) }
        let labelW: CGFloat = 38
        let plotW = size.width - labelW

        // Vạch nốt
        let first = Int(floor(lo)) - 1, last = Int(ceil(lo + span)) + 1
        for n in first...last {
            let yy = y(Float(n))
            if yy < -4 || yy > size.height + 4 { continue }
            let on = (mask >> UInt16(((n % 12) + 12) % 12)) & 1 == 1
            var p = Path(); p.move(to: CGPoint(x: labelW, y: yy)); p.addLine(to: CGPoint(x: size.width, y: yy))
            ctx.stroke(p, with: .color(Color.white.opacity(on ? 0.14 : 0.04)), lineWidth: 1)
            if on {
                ctx.draw(Text(noteLabel(n)).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textDim), at: CGPoint(x: 8, y: yy), anchor: .leading)
            }
        }

        let s = h.samples
        guard s.count > 1 else {
            ctx.draw(Text("Bật Monitor hoặc nhấn REC để bắt đầu").font(.system(size: 14))
                .foregroundStyle(Theme.textDim), at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }
        let dx = plotW / CGFloat(PitchHistory.capacity - 1)
        let x0 = size.width - dx * CGFloat(s.count - 1)

        // Nốt đích (bậc thang)
        var tgt = Path(); var started = false
        for (i, v) in s.enumerated() where v.voiced {
            let pt = CGPoint(x: x0 + dx * CGFloat(i), y: y(v.target))
            if started { tgt.addLine(to: pt) } else { tgt.move(to: pt); started = true }
        }
        ctx.stroke(tgt, with: .color(Theme.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))

        // Giọng gốc và giọng đã chỉnh; ngắt nét khi mất giọng
        func line(_ pick: (PitchHistory.Sample) -> Float) -> Path {
            var p = Path(); var open = false
            for (i, v) in s.enumerated() {
                if !v.voiced { open = false; continue }
                let pt = CGPoint(x: x0 + dx * CGFloat(i), y: y(pick(v)))
                if open { p.addLine(to: pt) } else { p.move(to: pt); open = true }
            }
            return p
        }
        ctx.stroke(line { $0.inMidi }, with: .color(Theme.cyan.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        ctx.stroke(line { $0.outMidi }, with: .linearGradient(Gradient(colors: [Theme.accent, Theme.accent2]),
                   startPoint: CGPoint(x: labelW, y: 0), endPoint: CGPoint(x: size.width, y: 0)),
                   style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

        // Nhãn nốt hiện tại và độ lệch
        if let l = s.last, l.voiced {
            let cents = Int(((l.inMidi - l.target) * 100).rounded())
            let ok = abs(cents) < 15
            let label = "\(noteLabel(Int(l.target.rounded())))  \(cents >= 0 ? "+" : "−")\(abs(cents))¢"
            ctx.draw(Text(label).font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(ok ? Theme.good : Theme.text), at: CGPoint(x: labelW + 8, y: 16), anchor: .leading)
        }
    }
}
