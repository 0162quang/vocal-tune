import SwiftUI

/// Hệ thiết kế: nền đen thuần (OLED), bề mặt phẳng, viền mảnh. Không blur, không bóng đổ lớn.
enum Theme {
    static let bg = Color.black
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.075)
    static let surface2 = Color(red: 0.09, green: 0.09, blue: 0.12)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.55)
    static let accent = Color(red: 0.55, green: 0.36, blue: 0.98)
    static let accent2 = Color(red: 0.93, green: 0.28, blue: 0.60)
    static let cyan = Color(red: 0.13, green: 0.83, blue: 0.93)
    static let good = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warn = Color(red: 1.0, green: 0.70, blue: 0.20)
    static let rec = Color(red: 1.0, green: 0.23, blue: 0.30)

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent2], startPoint: .leading, endPoint: .trailing)
    }
}

struct Chip: View {
    let icon: String?
    let text: String
    var tint: Color = Theme.textDim
    var filled = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)) }
            Text(text).font(.system(size: 13, weight: .semibold, design: .rounded)).lineLimit(1)
        }
        .foregroundStyle(filled ? Color.black : tint)
        .padding(.horizontal, 11).frame(minHeight: 34)
        .background(filled ? tint : Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

extension View {
    func card() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

func noteLabel(_ midi: Int) -> String {
    "\(noteNames[((midi % 12) + 12) % 12])\(midi / 12 - 1)"
}
