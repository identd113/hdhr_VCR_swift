import SwiftUI

// MARK: - StarburstShape

// 12-point starburst shape for the bonus-time badge.
struct StarburstShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, cy = rect.midY
        let outerR = min(rect.width, rect.height) / 2
        let innerR = outerR * 0.55
        let points = 12
        var path = Path()
        for i in 0..<(points * 2) {
            let angle = Double(i) * .pi / Double(points) - .pi / 2
            let r = i.isMultiple(of: 2) ? outerR : innerR
            let x = cx + CGFloat(cos(angle)) * r
            let y = cy + CGFloat(sin(angle)) * r
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Keyframe value types (file scope required for @KeyframesBuilder type inference)

// Holds scale + rotation for the pop-in keyframe animator.
// initialValue.scale=0 keeps the badge hidden until onAppear fires.
struct StarburstPopValues: Animatable {
    var scale: CGFloat = 0
    var rotation: Double = 0
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, rotation) }
        set { scale = newValue.first; rotation = newValue.second }
    }
}

// Holds scale + rotation for the celebration keyframe animator.
// initialValue.scale=1, rotation=0 → neutral; contributes nothing when idle.
struct StarburstCelebValues: Animatable {
    var scale: CGFloat = 1
    var rotation: Double = 0
    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(scale, rotation) }
        set { scale = newValue.first; rotation = newValue.second }
    }
}

// MARK: - StarburstBadge

// Sports bonus-time badge — orange starburst with football emoji and "+N min" label.
//
// Two stacked keyframeAnimators control the motion independently:
//   • Pop-in  (popCount)   — slams in from 0, spinning -240°, overshoots scale, springs to rest
//   • Celebration (celebCount) — compresses, explodes with full 360° spin, settles back to 1×
// SwiftUI multiplies stacked scaleEffects and adds stacked rotationEffects, so when both
// are at rest (scale=1, rotation=0°) they contribute nothing and the combined result is neutral.
struct StarburstBadge: View {
    let minutes: Int
    var size: CGFloat = 100

    @State private var popCount   = 0
    @State private var celebCount = 0
    @State private var tapCount   = 0

    var body: some View {
        StarburstShape()
            .fill(Color.orange)
            .frame(width: size, height: size)
            .overlay(
                Text("+\(minutes) min")
                    .font(.caption).bold().foregroundColor(.white)
            )
            // Pop-in: badge slams in spinning from far behind, overshoots scale, springs to rest.
            // initialValue.scale=0 keeps it hidden until the first pop fires from onAppear.
            .keyframeAnimator(initialValue: StarburstPopValues(), trigger: popCount) { content, v in
                content
                    .scaleEffect(v.scale)
                    .rotationEffect(.degrees(v.rotation))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    LinearKeyframe(CGFloat(1.30), duration: 0.01)
                    CubicKeyframe(CGFloat(0.82), duration: 0.18)
                    SpringKeyframe(CGFloat(1.0), spring: Spring(response: 0.32, dampingRatio: 0.38))
                }
                KeyframeTrack(\.rotation) {
                    LinearKeyframe(Double(-240), duration: 0.01)
                    CubicKeyframe(Double(18), duration: 0.22)
                    SpringKeyframe(Double(0), spring: Spring(response: 0.38, dampingRatio: 0.40))
                }
            }
            // Celebration: press-squish → explosion with full 360° spin → settle.
            // Stacks on top of pop-in (scales multiply, rotations add).
            // 360° end = 0° visually, so consecutive celebrations re-trigger cleanly.
            .keyframeAnimator(initialValue: StarburstCelebValues(), trigger: celebCount) { content, v in
                content
                    .scaleEffect(v.scale)
                    .rotationEffect(.degrees(v.rotation))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(CGFloat(0.45), duration: 0.10)
                    SpringKeyframe(CGFloat(1.65), spring: Spring(response: 0.28, dampingRatio: 0.28))
                    CubicKeyframe(CGFloat(0.90), duration: 0.12)
                    SpringKeyframe(CGFloat(1.0), spring: Spring(response: 0.30, dampingRatio: 0.65))
                }
                KeyframeTrack(\.rotation) {
                    LinearKeyframe(Double(0), duration: 0.10)    // hold during compress
                    LinearKeyframe(Double(360), duration: 0.45)  // full spin during explosion
                    LinearKeyframe(Double(360), duration: 0.20)  // settle at 360°
                    LinearKeyframe(Double(0), duration: 0.001)   // snap to 0 (same visual; resets stored value so next celebration starts clean)
                }
            }
            .onTapGesture {
                tapCount += 1
                if tapCount >= 5 { tapCount = 0; celebCount += 1 }
            }
            .onAppear    { popCount = 1 }
            .onDisappear { popCount = 0; celebCount = 0; tapCount = 0 }
    }
}
