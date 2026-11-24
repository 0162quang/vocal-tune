import SwiftUI

/// Núm xoay: kéo dọc để chỉnh, chạm đúp để về mặc định, hỗ trợ VoiceOver (tăng/giảm).
struct KnobView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    let format: (Double) -> String

    @State private var startValue: Double?
    @State private var lastTick = -1
    private let haptic = UISelectionFeedbackGenerator()

    private var norm: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let r = min(size.width, size.height) / 2 - 5
                    let a0 = Angle.degrees(135), sweep = 270.0
                    func arc(_ t: Double) -> Path {
                        var p = Path()
                        p.addArc(center: c, radius: r, startAngle: a0, endAngle: a0 + .degrees(sweep * t), clockwise: false)
                        return p
                    }
                    let style = StrokeStyle(lineWidth: 5, lineCap: .round)
                    ctx.stroke(arc(1), with: .color(Color.white.opacity(0.10)), style: style)
                    if norm > 0.004 {
                        ctx.stroke(arc(norm), with: .linearGradient(
                            Gradient(colors: [Theme.accent, Theme.accent2]),
                            startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: size.width, y: 0)), style: style)
                    }
                    let ang = (135 + sweep * norm) * .pi / 180
                    let dot = CGPoint(x: c.x + (r - 12) * cos(ang), y: c.y + (r - 12) * sin(ang))
                    ctx.fill(Path(ellipseIn: CGRect(x: dot.x - 2.5, y: dot.y - 2.5, width: 5, height: 5)), with: .color(.white))
                }
                Text(format(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.text)
            }
            .frame(width: 70, height: 70)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    if startValue == nil { startValue = value; haptic.prepare() }
                    let span = range.upperBound - range.lowerBound
                    let v = (startValue ?? value) - Double(g.translation.height) / 180 * span
                    value = min(max(v, range.lowerBound), range.upperBound)
                    let tick = Int(norm * 20)
                    if tick != lastTick { lastTick = tick; haptic.selectionChanged() }
                }
                .onEnded { _ in startValue = nil })
            .onTapGesture(count: 2) { value = defaultValue }
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            let step = (range.upperBound - range.lowerBound) / 20
            value = min(max(value + (dir == .increment ? step : -step), range.lowerBound), range.upperBound)
        }
    }
}
