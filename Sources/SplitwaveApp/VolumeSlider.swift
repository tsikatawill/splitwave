import SplitwaveCore
import SwiftUI

/// Volume slider with the app's live level drawn inside its track (F4, F11).
///
/// The faint fill is the volume; the bright fill is the sound actually playing, scaled by that
/// volume, so it rises and falls under the knob and never past it.
struct VolumeSlider: View {
    @Binding var volume: Float
    /// Returns the latest post-gain peak, or nil when there's no live route to meter.
    let peak: () -> Float?
    let gain: Float
    var isEnabled = true

    /// A reference box: the meter's fall-off state changes every frame, and keeping it out of
    /// SwiftUI's state means only the level capsule redraws, not the whole slider.
    @State private var meter = MeterState()
    @State private var dragging = false

    private let knob: CGFloat = 16
    private let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knob)
            let v = CGFloat(max(0, min(1, volume)))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: track)
                Capsule().fill(tint.opacity(0.35)).frame(width: knob / 2 + usable * v, height: track)
                level(width: knob / 2 + usable * v)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dragging ? 0.3 : 0.2), radius: dragging ? 2 : 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .offset(x: usable * v)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        dragging = true
                        volume = Float(max(0, min(1, (g.location.x - knob / 2) / usable)))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: knob + 4)
        .opacity(isEnabled ? 1 : 0.45)
        .allowsHitTesting(isEnabled)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((volume * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.05)
            case .decrement: volume = max(0, volume - 0.05)
            @unknown default: break
            }
        }
    }

    private var tint: Color { isEnabled ? .accentColor : .secondary }

    /// Redrawn ~30 times a second; everything else in the row stays put.
    private func level(width: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isEnabled)) { context in
            let raw = peak().map { LevelScale.fraction(peak: $0, gain: gain) } ?? 0
            let shown = meter.ballistics.update(raw, now: context.date)
            Capsule().fill(tint).frame(width: width * CGFloat(shown), height: track)
        }
    }
}

private final class MeterState {
    var ballistics = LevelBallistics()
}
