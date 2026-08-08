# StarburstBadge.swift — Animated Bonus Time Badge

## Visual Appearance

### At rest
A solid **orange** 12-point starburst polygon, `size` × `size` (default 100pt, 48pt in EditShowView, 65pt in AddShowView details — sized down from 150pt/115pt so the badge no longer overlaps the form's field rows). The starburst has alternating outer and inner radii (`outerR` and `0.55 × outerR`), making it look like a sale/badge shape.

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

`StarburstBadge` is an orange 12-point starburst that indicates Bonus Time is enabled on a show. It displays `"+N min"` where N is `state.config.Sports_padding_minutes`. Sports shows have Bonus Time enabled by default; any show type can use it. It appears in exactly two places (`AddShowView` step 2's `WKWebView`-based guide browsing has no SwiftUI overlay of its own to host it):
- In `AddShowView` step 3 (Details), overlaid at the **bottom-right** corner of the form (65pt)
- In `EditShowView`, overlaid at the **top-right** corner of the form (48pt — the Title field sits closer to the top edge here than in AddShowView's taller layout, so it needed a smaller size than AddShowView's to fully clear it)

It has a pop-in animation on appear and a 5-tap celebration spin easter egg.

Both are `.overlay`s pinned to a form corner with no reserved space of their own — earlier, larger sizes (150pt/115pt) sat on top of the Title/Type/Bonus Time/Folder rows underneath. The current sizes were chosen to stay in the corner without covering any field content.

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

## Web Guide Counterpart (`WebServer.swift`)

The web guide (served on `localhost:1980`, shared by external browsers and in-app `WKWebView` windows) has its own CSS/JS re-implementation of this badge — not the SwiftUI `StarburstBadge` type, since the guide is plain HTML/JS. Two style classes in `WebServer.swift`:
- `.sb-web` — small 28px inline badge (12-point starburst via `clip-path`, orange `#e86e00` fill)
- `.sb-web-lg` — 56px × 56px, `position:absolute; top:6px; right:44px`, `pointer-events:none`, `font-size:.42rem` — the large corner-badge variant, analogous to the native `StarburstBadge`'s corner overlay

`.sb-web-lg` is used at three spots, each an absolutely-positioned span in the top-right corner of its `position:relative` container:
- `#sum-bonus-star` — guide summary panel (`#sum-c`)
- `#rm-bonus-star` — Record modal (`.mac-sheet`)
- `#em-bonus-star` — Edit modal (`.mac-sheet`)

All three are toggled via JS (`toggleBonusStar()`, `toggleRmBonusStar()`, and the summary-panel renderer), setting `textContent` to `"+Nm"` and `display:inline-flex`/`none`. Like the native badge, sizing was reduced (from 110px) so it stays inside the corner without covering the panel/modal header or field text underneath. `right` is 44px rather than a smaller corner-hugging value specifically because `#sum-c`'s own `✕` close button (`closeSummary()`) is a flex item flush against that same top-right corner — an 8px right offset put the badge directly on top of it. 44px clears the close button in all three contexts (the two modals have no equivalent top-right control, so the extra left shift just leaves more empty margin there).

---

## Lifecycle Reset

```swift
.onAppear    { popCount = 1 }
.onDisappear { popCount = 0; celebCount = 0; tapCount = 0 }
```

`onDisappear` resets all counters. This is important for the AddShowView Details step — the user can go back from Details to Guide and re-enter Details. Without the reset, `popCount` would already be 1 and the `keyframeAnimator` wouldn't re-fire (the trigger value hasn't changed). The reset ensures the pop-in plays every time the badge appears.
