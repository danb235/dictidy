import SwiftUI

/// Dictidy menu-bar glyph — the **Equalizer** waveform family.
///
/// A monochrome, template-style mark: it draws in the foreground color, so it adapts
/// automatically to light and dark menu bars. Every state is a variation of the same
/// five-bar waveform, so the icon always reads as "the same app, doing something".
///
/// All motion is driven by an integer `frame` counter — reuse the frame counters the app
/// already publishes: `AppState.recordingFrame` while listening and `AppState.spinnerFrame`
/// while working. No macOS-14-only `symbolEffect` is required, so it runs on the macOS 13 target.
///
/// Usage (in the `MenuBarExtra` label — see `MenuBarExtra+Icon.swift`):
///     WaveformIcon(mode: .recording, frame: state.recordingFrame)
///         .frame(width: 18, height: 18)
struct WaveformIcon: View {

    enum Mode { case idle, recording, processing, error, setup }

    var mode: Mode
    /// Steps once per animation tick. Ignored by `.idle` and `.error`; drives the pulse
    /// for `.setup` and the motion for `.recording` / `.processing`.
    var frame: Int = 0

    /// The resting waveform silhouette — symmetric half-heights (0…1 of the drawable height).
    private static let profile: [CGFloat] = [0.42, 0.68, 1.0, 0.68, 0.42]

    // Geometry as fractions of the icon side.
    private let barWidthRatio: CGFloat = 0.13
    private let spacingRatio:  CGFloat = 0.075
    private let maxHeightRatio: CGFloat = 0.82

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            content(side: side, barW: side * barWidthRatio)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.primary)   // template: inherits the menu-bar's label color
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(side: CGFloat, barW: CGFloat) -> some View {
        switch mode {
        case .idle, .recording, .processing:
            HStack(spacing: side * spacingRatio) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .frame(width: barW, height: barHeight(i, side: side))
                        .opacity(barOpacity(i))
                }
            }
        case .error:
            // Silence — every bar collapses to a flat, round-capped dot on the mid-line.
            HStack(spacing: side * spacingRatio) {
                ForEach(0..<5, id: \.self) { _ in
                    Capsule().frame(width: barW, height: barW)
                }
            }
        case .setup:
            // The center bar becomes an exclamation mark.
            VStack(spacing: side * 0.10) {
                Capsule().frame(width: barW, height: side * 0.44)
                Circle().frame(width: barW * 1.2, height: barW * 1.2)
            }
            .opacity(setupPulse)
        }
    }

    // MARK: - Per-bar animation

    private func barHeight(_ i: Int, side: CGFloat) -> CGFloat {
        let maxH = side * maxHeightRatio
        let base = WaveformIcon.profile[i]
        switch mode {
        case .recording:
            // Gentle, staggered equalizer — a calm 0.35…1.0 scale, offset per bar.
            let scale = 0.35 + 0.65 * tri(period: 16, offset: Double(i) * 0.13)
            return maxH * base * scale
        default:
            return maxH * base       // idle & processing keep the resting silhouette
        }
    }

    private func barOpacity(_ i: Int) -> Double {
        switch mode {
        case .processing:
            // Soft left-to-right shimmer — opacity travels across the bars.
            return 0.28 + 0.72 * Double(tri(period: 22, offset: Double(i) * 0.12))
        default:
            return 1
        }
    }

    /// Slow attention pulse for the setup state (needs a running `frame` to move; otherwise static).
    private var setupPulse: Double { 0.5 + 0.5 * Double(tri(period: 26)) }

    /// Triangle wave 0 → 1 → 0 derived from the integer frame counter.
    private func tri(period: Double, offset: Double = 0) -> CGFloat {
        let raw = (Double(frame) / period + offset).truncatingRemainder(dividingBy: 1)
        let p = raw < 0 ? raw + 1 : raw
        return CGFloat(1 - abs(2 * p - 1))
    }
}

#if DEBUG
struct WaveformIcon_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 22) {
            ForEach([WaveformIcon.Mode.idle, .recording, .processing, .error, .setup], id: \.self) { m in
                WaveformIcon(mode: m, frame: 6).frame(width: 32, height: 32)
            }
        }
        .padding(28)
        .background(Color.black)
        .previewLayout(.sizeThatFits)
    }
}
extension WaveformIcon.Mode: Hashable {}
#endif
