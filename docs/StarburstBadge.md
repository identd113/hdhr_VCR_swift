# StarburstBadge.swift — Animated Bonus Time Badge

## Visual Appearance

### At rest
A solid **orange** 12-point starburst polygon, `size` × `size` (default 100pt, 150pt in EditShowView, 115pt in AddShowView details). The starburst has alternating outer and inner radii (`outerR` and `0.55 × outerR`), making it look like a sale/badge shape.

Centered inside the starburst: `"+N min"` in white `.caption` bold. At 100pt size this text is ~12pt, clearly legible. At the default orange color (SwiftUI `Color.orange`) the badge reads as warm and energetic.

No border, no shadow, no background behind the badge — it floats directly over whatever is behind it (form background, summary panel, etc.).

### Pop-in animation (on appear)
The badge slams in over ~0.4 seconds:
1. Instantly jumps to 130% scale + rotated -240° (behind the content plane)
2. Quickly shrinks to 82% scale + rotates +18° over 0.18s (cubic easing — swings past resting position)
3. Springs to 100% scale + 0° rotation (spring response 0.32, damping 0.38 — noticeably bouncy)

The net visual effect: the badge pops in spinning fast from the upper-right, overshoots slightly, then bounces to rest. The `initialValue.scale = 0` keeps it invisible before the first pop fires from `onAppear`.

### 5-tap celebration animation
After the 5th tap on the badge, while spinning a full 360°: compresses to 45% scale (press-squish), springs out to 165% (explosive pop), cubic-backs to 90% (slight undershoot), then springs to rest at 100% — see "Celebration Keyframes" below for exact timing/spring parameters and why the rotation reset makes repeated celebrations trigger cleanly.

### Transition
When Bonus Time is toggled off (badge removed from the hierarchy): `.scale(scale: 0.05).combined(with: .opacity)` removal transition — shrinks to nearly nothing and fades out simultaneously.

## Intent

`StarburstBadge` is an orange 12-point starburst that indicates Bonus Time is enabled on a show. It displays `"+N min"` where N is `state.config.Sports_padding_minutes`. Sports shows have Bonus Time enabled by default; any show type can use it. It appears:
- In `AddShowView` step 3 (Details), overlaid at the **bottom-right** corner of the form (115pt)
- In `AddShowView` and `FloatingGuideView` summary panels, overlaid at the **top-right** of the ZStack (100pt) — shown when the selected entry defaults to Bonus Time on (i.e., sports genre)
- In `EditShowView`, overlaid at the **top-right** corner of the form (150pt)

It has a pop-in animation on appear and a 5-tap celebration spin easter egg.

---

## `StarburstShape`

A `Shape` that draws a 12-point starburst by alternating outer and inner radius points around a circle. 24 points total (12 outer × 12 inner), connected with straight lines, closed subpath.

```swift
let outerR = min(rect.width, rect.height) / 2
let innerR = outerR * 0.55   // inner points at 55% of outer radius
let points = 12
for i in 0..<(points * 2) {
    let angle = Double(i) * .pi / Double(points) - .pi / 2   // start at top
    let r = i.isMultiple(of: 2) ? outerR : innerR
    ...
}
```

The `-π/2` offset rotates the shape so a point is at the top rather than at 3 o'clock.

---

## Two Stacked `keyframeAnimator` Instances

The badge uses two separate animators stacked on the same view:

```
StarburstShape + overlay
    .keyframeAnimator(trigger: popCount)    { scale × rotation }   ← pop-in
    .keyframeAnimator(trigger: celebCount)  { scale × rotation }   ← celebration
```

**Why two separate animators instead of one**: SwiftUI **multiplies** stacked `scaleEffect` values and **adds** stacked `rotationEffect` values. When both animators are at rest (`scale=1, rotation=0`), they contribute nothing — the combined result is exactly `1× scale, 0° rotation`. Separating the two animations this way means they are fully independent: the pop-in can finish and rest while a celebration is triggered, without needing to reset or merge keyframe tracks.

If you collapse them into a single `keyframeAnimator`, the two sequences would need to share trigger state and the "consecutive re-trigger" behavior of the celebration (which relies on ending at 360° and snapping to 0°) would be harder to implement cleanly.

---

## `StarburstPopValues` and `StarburstCelebValues`

Two file-scope `Animatable` structs (required at file scope rather than nested inside the view — Swift's `@KeyframesBuilder` type inference fails with nested types):

```swift
struct StarburstPopValues: Animatable {
    var scale: CGFloat = 0    // initialValue.scale=0 keeps badge hidden until onAppear
    var rotation: Double = 0
}
struct StarburstCelebValues: Animatable {
    var scale: CGFloat = 1    // initialValue at rest — contributes nothing
    var rotation: Double = 0
}
```

`StarburstPopValues.scale` starts at 0 — this keeps the badge invisible in its initial state. The first pop fires from `.onAppear { popCount = 1 }`, slamming the badge into view.

`StarburstCelebValues` starts at `(1, 0)` — neutral — so it contributes nothing until the first celebration is triggered.

---

## Pop-In Keyframes (`trigger: popCount`)

Fires once on `.onAppear`. Sequence:
1. **`LinearKeyframe(scale: 1.30, duration: 0.01)`** — jump immediately to overshoot scale (hides the initial `scale=0`)
2. **`CubicKeyframe(scale: 0.82, duration: 0.18)`** — compress below 1× (elastic dip)
3. **`SpringKeyframe(scale: 1.0, spring: response 0.32, dampingRatio 0.38)`** — spring to rest at 1×

Rotation track:
1. **`LinearKeyframe(-240°, duration: 0.01)`** — jump to -240° (badge slams in spinning from behind)
2. **`CubicKeyframe(18°, duration: 0.22)`** — swing past 0° to +18°
3. **`SpringKeyframe(0°, spring: response 0.38, dampingRatio 0.40)`** — spring to rest at 0°

The `0.01s` linear frames are essentially instant — they exist to set the starting value for the subsequent curves without an interpolation gap from `initialValue`.

---

## Celebration Keyframes (`trigger: celebCount`)

Fires after 5 taps on the badge. Sequence:
1. **Scale compress to 0.45 (0.10s)** — press-squish feeling
2. **Spring to 1.65 (response 0.28, dampingRatio 0.28)** — explosive pop outward
3. **Cubic back to 0.90 (0.12s)** — slight undershoot
4. **Spring to 1.0 (response 0.30, dampingRatio 0.65)** — settle

Rotation:
1. **Hold at 0° (0.10s)** — hold during the compress so it doesn't look jittery
2. **Linear to 360° (0.45s)** — full spin during the explosion
3. **Hold at 360° (0.20s)** — settle
4. **Snap to 0° (0.001s)** — 360° and 0° are visually identical, so this reset is invisible. It resets the stored value so the next celebration starts at 0° rather than at 360°+360°.

Without the final snap, `celebCount` increments drive the rotation to 360°, 720°, 1080°, etc. The value drifts and `SpringKeyframe` has increasing numeric error. The 0.001s snap is the correct fix.

---

## 5-Tap Easter Egg

```swift
.onTapGesture {
    tapCount += 1
    if tapCount >= 5 { tapCount = 0; celebCount += 1 }
}
```

After every 5th tap, `celebCount` increments, re-triggering `keyframeAnimator`. `tapCount` resets to 0 so the next 5 taps trigger another celebration.

---

## Lifecycle Reset

```swift
.onAppear    { popCount = 1 }
.onDisappear { popCount = 0; celebCount = 0; tapCount = 0 }
```

`onDisappear` resets all counters. This is important for the AddShowView Details step — the user can go back from Details to Guide and re-enter Details. Without the reset, `popCount` would already be 1 and the `keyframeAnimator` wouldn't re-fire (the trigger value hasn't changed). The reset ensures the pop-in plays every time the badge appears.
