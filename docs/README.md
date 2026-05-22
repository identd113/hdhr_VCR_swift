# hdhr_VCR Swift — View Documentation

One doc per view. Each covers: intent, architecture, key behaviors, and what still needs doing.

| File | View | Purpose |
|---|---|---|
| [MenuContent.md](MenuContent.md) | `MenuContent.swift` | The entire menu bar dropdown UI — recording, scheduling, add show |
| [AddShowView.md](AddShowView.md) | `AddShowView.swift` | 3-step wizard: Device → Guide → Details |
| [CableGuideView.md](CableGuideView.md) | `CableGuideView.swift` | Cable-TV-style guide grid (rows = channels, cols = time) |
| [EditShowView.md](EditShowView.md) | `EditShowView.swift` | Form for editing an existing scheduled show |
| [SettingsView.md](SettingsView.md) | `SettingsView.swift` | App settings — draft/save pattern, all config knobs |

## Other docs in this repo

| File | Purpose |
|---|---|
| `cableView.md` (root) | Full failure log for the cable guide layout — read before touching CableGuideView layout structure |
| `guide_failure.md` (root) | Blank grid investigation log — documents the LazyVStack / bidirectional ScrollView failure |
| `CLAUDE.md` (root) | Full architecture reference — data flow, key functions, config format |
