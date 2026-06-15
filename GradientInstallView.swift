import SwiftUI

struct ContentView: View {
    var body: some View {
        GradientInstallView()
    }
}

struct GradientInstallView: View {

    private let totalSteps: CGFloat = 32
    private let launchPreviewProgress: CGFloat?

    @State private var progress: CGFloat = 0.0

    @State private var startTime = Date().timeIntervalSinceReferenceDate

    @State private var lastTap: CGPoint?
    @State private var tapStart: TimeInterval = -10
    @State private var shakeStart: TimeInterval = -10

    init() {
        let previewProgress = Self.previewProgressFromLaunchArguments()

        launchPreviewProgress = previewProgress
        _progress = State(initialValue: previewProgress ?? 0.0)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { timeline in

            let now = timeline.date.timeIntervalSinceReferenceDate
            let elapsed = now - startTime

            let tapPulse = max(0, 1.0 - (now - tapStart) * 2.2)

            let shakeElapsed = now - shakeStart
            let shake: CGFloat = {
                guard shakeElapsed < 0.42 else { return 0 }

                let decay = 1.0 - shakeElapsed / 0.42
                return CGFloat(sin(shakeElapsed * 52.0) * 6.0 * decay)
            }()

            GeometryReader { geo in
                ZStack {

                    Rectangle()
                        .fill(.white)
                        .colorEffect(
                            ShaderLibrary.liquidSpecBackground(
                                .float2(geo.size),
                                .float(progress),
                                .float(tapPulse),
                                .float2(
                                    (lastTap?.x ?? geo.size.width / 2) / max(geo.size.width, 1),
                                    (lastTap?.y ?? geo.size.height / 2) / max(geo.size.height, 1)
                                ),
                                .float(elapsed)
                            )
                        )
                        .ignoresSafeArea()
                        .zIndex(0)

                    DotPattern()
                        .opacity(progress > 0.55 ? 0.11 : 0.16)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .zIndex(9)
                        .animation(.easeInOut(duration: 0.35), value: progress)

                    VStack {
                        HStack {
                            Spacer()

                            Button {
                                reset(now: now)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.gray)
                                    .frame(width: 30, height: 30)
                                    .background(.gray.opacity(0.16))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.top, 56)
                        .padding(.trailing, 24)

                        Spacer()

                        Text("\(Int(round(progress * 100)))%")
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(
                                Color(
                                    red: 0.18 - progress * 0.02,
                                    green: 0.18 - progress * 0.02,
                                    blue: 0.20
                                )
                            )
                            .shadow(
                                color: Color.cyan.opacity(0.04 + progress * 0.16),
                                radius: 2 + progress * 9,
                                x: 0,
                                y: 0
                            )
                            .shadow(
                                color: Color.white.opacity(progress > 0.55 ? 0.16 : 0.04),
                                radius: progress > 0.55 ? 5 : 1,
                                x: 0,
                                y: 0
                            )
                            .animation(.easeInOut(duration: 0.35), value: progress)

                        Spacer()

                        Text("Устанавливаем защищенное\nсоединение. Нажимайте в разных\nчастях экрана")
                            .font(.system(size: 17, weight: .medium))
                            .multilineTextAlignment(.center)
                            .lineSpacing(1)
                            .foregroundStyle(Color(red: 0.20, green: 0.20, blue: 0.20))
                            .offset(x: shake)
                            .padding(.bottom, 82)
                    }
                    .zIndex(99)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let location = value.location

                            let isSameSpot: Bool = {
                                guard let lastTap else { return false }

                                return abs(location.x - lastTap.x) <= 17 &&
                                       abs(location.y - lastTap.y) <= 17
                            }()

                            tapStart = now

                            if isSameSpot {
                                shakeStart = now
                                return
                            }

                            lastTap = location

                            let step = 1.0 / totalSteps

                            withAnimation(.timingCurve(0.30, 0.02, 0.05, 1.0, duration: 1.45)) {
                                progress = min(progress + step, 1.0)
                            }
                        }
                )
            }
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
    }

    private func reset(now: TimeInterval) {
        withAnimation(.easeInOut(duration: 0.35)) {
            progress = launchPreviewProgress ?? 0
        }

        startTime = now
        lastTap = nil
        tapStart = -10
        shakeStart = -10
    }

    private static func previewProgressFromLaunchArguments() -> CGFloat? {
        let arguments = ProcessInfo.processInfo.arguments

        guard
            let flagIndex = arguments.firstIndex(of: "-PreviewProgress"),
            arguments.indices.contains(flagIndex + 1),
            let value = Double(arguments[flagIndex + 1])
        else {
            return nil
        }

        return CGFloat(min(max(value, 0), 1))
    }
}

struct DotPattern: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3
            let dotSize: CGFloat = 1

            var path = Path()

            var y: CGFloat = 0

            while y < size.height {
                var x: CGFloat = 0

                while x < size.width {
                    path.addEllipse(
                        in: CGRect(
                            x: x,
                            y: y,
                            width: dotSize,
                            height: dotSize
                        )
                    )

                    x += spacing
                }

                y += spacing
            }

            context.fill(path, with: .color(.black))
        }
    }
}
