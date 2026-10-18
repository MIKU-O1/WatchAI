import SwiftUI

enum Theme {
    static let mint = Color(red: 0.47, green: 0.94, blue: 0.73)
    static let background = Color(red: 0.035, green: 0.065, blue: 0.065)
    static let card = Color(red: 0.09, green: 0.13, blue: 0.13)
    static let secondary = Color(red: 0.56, green: 0.67, blue: 0.65)
}

struct VoiceOrb: View {
    var active = false
    var level: Float = 0
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Circle().fill(Theme.mint.opacity(0.06))
            Circle().stroke(Theme.mint.opacity(0.16), lineWidth: 1).padding(8)
            Circle().fill(
                RadialGradient(colors: [Theme.mint.opacity(0.8), Theme.mint.opacity(0.15)],
                               center: .topLeading, startRadius: 0, endRadius: compact ? 45 : 85)
            ).padding(compact ? 14 : 24)
                .scaleEffect(active ? 1 + Double(level) * 0.12 : 1)
            HStack(spacing: compact ? 3 : 5) {
                ForEach(0..<5) { index in
                    Capsule().fill(Color.white.opacity(0.9))
                        .frame(width: compact ? 3 : 4,
                               height: CGFloat([12, 24, 34, 24, 12][index]) * (compact ? 0.65 : 1) * (active ? 1 + CGFloat(level) : 1))
                }
            }
        }
        .frame(width: compact ? 64 : 140, height: compact ? 64 : 140)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
        .accessibilityHidden(true)
    }
}
