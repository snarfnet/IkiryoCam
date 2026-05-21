import SwiftUI

enum IkiryoTheme {
    static let void = Color(red: 0.015, green: 0.012, blue: 0.011)
    static let blood = Color(red: 0.72, green: 0.02, blue: 0.035)
    static let oldBlood = Color(red: 0.34, green: 0.012, blue: 0.02)
    static let sickGreen = Color(red: 0.46, green: 0.78, blue: 0.62)
    static let bone = Color(red: 0.88, green: 0.84, blue: 0.76)
    static let ash = Color(red: 0.58, green: 0.60, blue: 0.57)
    static let warning = Color(red: 1.0, green: 0.08, blue: 0.06)

    static let bloodGlow = LinearGradient(
        colors: [blood, oldBlood, Color.black],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct IkiryoBackground: View {
    var pulse: Bool = false

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            ZStack {
                Image("IkiryoHallway")
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.04 + (pulse ? 0.012 * sin(t * 1.7) : 0))
                    .saturation(0.62)
                    .contrast(1.18)
                    .brightness(-0.08)
                    .ignoresSafeArea()

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.2),
                        Color.black.opacity(0.66),
                        Color.black.opacity(0.92)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.7),
                        Color.black.opacity(0.96)
                    ],
                    center: .center,
                    startRadius: 80,
                    endRadius: 430
                )
                .ignoresSafeArea()

                Color(red: 0.1, green: 0.5, blue: 0.36)
                    .opacity(0.08 + 0.025 * sin(t * 6.0))
                    .blendMode(.screen)
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .opacity(0.28)
                    .ignoresSafeArea()

                GrainOverlay(seed: t)
                    .opacity(0.16)
                    .ignoresSafeArea()
            }
        }
        .background(IkiryoTheme.void)
    }
}

struct IkiryoPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.48))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        IkiryoTheme.bone.opacity(0.28),
                                        IkiryoTheme.warning.opacity(0.42),
                                        IkiryoTheme.sickGreen.opacity(0.18)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: IkiryoTheme.warning.opacity(0.25), radius: 22, y: 8)
            )
    }
}

struct IkiryoPrimaryButton: ButtonStyle {
    var disabled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .serif).weight(.black))
            .foregroundStyle(disabled ? IkiryoTheme.ash : Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(disabled ? Color.white.opacity(0.08) : IkiryoTheme.bloodGlow)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(disabled ? 0.08 : 0.24), lineWidth: 1)
                    )
            )
            .shadow(color: disabled ? .clear : IkiryoTheme.warning.opacity(0.42), radius: configuration.isPressed ? 8 : 18, y: 8)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 5
            }
            context.stroke(path, with: .color(.white.opacity(0.16)), lineWidth: 0.6)
        }
    }
}

struct GrainOverlay: View {
    let seed: TimeInterval

    var body: some View {
        Canvas { context, size in
            let count = 260
            for index in 0..<count {
                let x = abs(sin(seed * 3.1 + Double(index) * 12.9898)).truncatingRemainder(dividingBy: 1) * size.width
                let y = abs(sin(seed * 2.7 + Double(index) * 78.233)).truncatingRemainder(dividingBy: 1) * size.height
                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(index.isMultiple(of: 3) ? 0.34 : 0.14)))
            }
        }
    }
}
