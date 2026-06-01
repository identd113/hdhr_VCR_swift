# ShowFormSection.swift — Shared Show Form Fields

## Intent

`ShowFormSection` is a reusable `Group` of `Form` rows shared between `AddShowView` step 3 (Details) and `EditShowView`. It contains the fields that are common to both: title, type, air days, transcode, Bonus Time, and folder. Extracting this into a shared component ensures both views stay in sync when new fields are added.

---

## Fields

```
Title        — TextField bound to show.show_title
Type         — Segmented Picker (ShowState.allCases): Single | DateTime | SeriesID(Channel) | SeriesID(All)
               Tooltip: explains each mode
Day/Days     — Weekday toggle buttons (only for .single and .dateTime)
               Tooltip: single-day vs. multi-day selection intent
Transcode    — Picker: None | Heavy | Mobile | Internet 720
               Tooltip: None keeps raw MPEG; others transcode for size/device
Bonus Time   — Toggle (only when state.config.Sports_padding_enabled); bound to show.show_bonus_time
Folder       — Last path component of recordFolder + a button (label from folderButtonLabel param)
```

---

## Day Toggle Behavior

- For `.single`: selecting a day deselects all others (`airDays = on ? [day] : []`). Enforces exactly 0 or 1 day.
- For `.dateTime`: any combination is allowed (`airDays.insert` / `airDays.remove`).
- Day buttons are hidden for `.seriesChannel` and `.seriesAll` — SeriesID shows record on any day.

---

## Bonus Time Toggle

Only shown when `state.config.Sports_padding_enabled`. The label reads `"+N min past guide end"` where N is `state.config.Sports_padding_minutes`. The toggle sets `show.show_bonus_time`. The `withAnimation(.spring(...))` wrapper on the setter makes the `StarburstBadge` in the parent's ZStack animate in/out when the toggle changes.

---

## `WhiteOutlineButtonStyle`

A custom `ButtonStyle` defined in the same file. Used for "Watch in VLC" and "Watch in App" buttons in the summary panels, where a white fill + colored border is needed. Standard SwiftUI `.bordered` can't express a different fill vs. border color, hence the custom style.

```swift
struct WhiteOutlineButtonStyle: ButtonStyle {
    var borderColor: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(borderColor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(borderColor, lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.65 : isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
```

VLC buttons pass `borderColor: Color(red: 1.0, green: 0.482, blue: 0.0)` (VLC's brand orange).

---

## Callbacks

`ShowFormSection` does not call `state` directly. Mutations that need side effects go through callbacks:
- `onSeriesTypeChange()` — called from `onChange(of: seriesType)` — the parent applies flag changes (e.g., `EditShowView.applySeriesType()`)
- `onChooseFolder()` — called when the folder button is tapped — the parent runs `NSOpenPanel`

This keeps the component free of direct `AppState` mutations and makes it testable.

---

## Adding New Fields

When adding a new field to `Show` that should appear in both Add and Edit flows, add it here. The field will automatically appear in both views. If the field is only relevant to one flow (e.g., a field that only makes sense on first-add), put it directly in the parent view instead.
