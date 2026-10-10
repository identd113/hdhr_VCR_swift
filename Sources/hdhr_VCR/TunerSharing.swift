// The menu header's note about tuners that aren't (only) this app's. A device's `status.json` shows every tuner in
// use — ours and anyone else's: another Mac running this app against the same HDHomeRun, or a third-party client.
// `hw` is that hardware count; `app` is what this instance itself holds (recordings + its own VLC streams).
//   hw > app → the surplus is another device's; say so (it used to read "⚠ app expects N", which sounded like a fault).
//   hw < app → a recording/stream we just started that status.json hasn't caught up with yet.
// nil = nothing to add (counts agree, or status.json hasn't been polled yet).
enum TunerSharing {
    static func note(hardwareCount hw: Int?, appCount app: Int) -> String? {
        guard let hw, hw != app else { return nil }
        if hw > app {
            let n = hw - app
            return "in use by another device" + (n > 1 ? " (\(n))" : "")
        }
        return "starting…"
    }
}
