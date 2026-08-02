# FloatingGuideView.swift — Standalone Guide Browser

## Visual Appearance

### Overall window
Minimum **1100×720**, no maximum. Resizable. Floating above other windows (via `FloatingWindowLevelSetter`). No title bar decorations beyond the standard macOS close/minimize/zoom buttons. Window title: `"Cable Guide"`.

### Content area
The full window is a `WKWebView` loading `http://localhost:{port}/` — the same web guide served to LAN browsers. Dark/light theme is synced from `NSApp.effectiveAppearance` via JS injection after page load.

The page uses a full-viewport flex column layout (`body{height:100vh;height:100dvh;display:flex;flex-direction:column}` — the `100dvh` fallback fixes mobile Safari's address-bar-chrome viewport sizing and is a no-op for this desktop-only `WKWebView` window). The guide grid (`.gw`) fills all remaining height below the toolbar and summary card, so the guide extends to the bottom edge of the window with no dead space regardless of window size.

**Watch in App / Watch in VLC buttons** appear in the summary panel for currently-airing shows, injected by the web server when it detects the `window.webkit.messageHandlers.watch` bridge. They are hidden for past or future shows.

## Intent

`FloatingGuideView` is a browse-only cable guide window that can be opened independently of the Add Show wizard. Window ID: `"cable-guide"`. The guide is always the web-based guide (`GuideWebView`). It is a single-instance `Window` scene, so only one floating guide can exist at a time (no duplicate windows — see [[feedback-no-duplicate-windows]]). The web server auto-starts on demand when the guide opens and stops when it closes; the lifecycle is reference-counted so the floating guide and the Add Show wizard's embedded guide view can be open at the same time without the server being torn down while one is still using it.

Window sizing and floating behavior: see "Overall window" above and `FloatingWindowLevelSetter` below.

---

## Body

```swift
var body: some View {
    Group {
        if state.webServerRunning {
            GuideWebView(port: state.config.Web_server_port) { type, deviceId, guideNumber, title in
                guard let url = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber })?.URL else { return }
                if type == "app" {
                    state.watchInApp(url: url, title: title, deviceId: deviceId, guideNumber: guideNumber)
                } else {
                    state.watchInVLC(url: url, deviceId: deviceId)
                }
            }
        } else {
            ProgressView("Starting guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    .onAppear { state.ensureWebServerRunning() }
    .onDisappear { state.releaseInternalWebServer() }
    .onExitCommand { dismiss() }
    .background(FloatingWindowLevelSetter())
    .frame(minWidth: 1100, minHeight: 720)
}
```

---

## `GuideWebView`

`private struct GuideWebView: NSViewRepresentable`. Loads `http://localhost:{port}/` in a `WKWebView`.

**`onWatch` closure** — called when JS posts to `window.webkit.messageHandlers.watch` with `{type, deviceId, guideNumber, title}`. The view resolves the stream URL from `state.lineups` and calls either `state.watchInApp` or `state.watchInVLC`.

**`WKScriptMessageHandler`** — the coordinator registers as the `"watch"` message handler in `makeNSView`. `dismantleNSView` removes it to prevent a retain cycle when the view is torn down.

**Navigation policy** — `WKNavigationDelegate` blocks all non-`localhost` navigation. Dark/light theme is injected via `evaluateJavaScript` in `webView(_:didFinish:)`:
```javascript
if(typeof setTheme==='function')setTheme('dark'); // or 'light'
```
`setTheme()` handles both `localStorage` persistence and live CSS class application (`applyLM`). The system appearance (`NSApp.effectiveAppearance`) is sampled in Swift and the appropriate string passed.

```swift
static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
    nsView.configuration.userContentController.removeScriptMessageHandler(forName: "watch")
}
```

---

## Web Server Lifecycle

`ensureWebServerRunning()` increments `AppState.internalWebServerUseCount` and starts the server if not already running. `releaseInternalWebServer()` decrements the count; the server stops only when the count reaches 0 **and** the user has not permanently enabled the web server (`Web_server_enabled == false`).

This ref-count approach means opening two `FloatingGuideView` windows simultaneously is safe — the server stays running until the last window closes.

---

## `FloatingWindowLevelSetter`

An `NSViewRepresentable` that raises the host `NSWindow` to `.floating` level on first appear. Keeps the guide above normal app windows while browsing without making it modal.

```swift
private struct FloatingWindowLevelSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            v.window?.level = .floating
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
```

`DispatchQueue.main.async` is required because `v.window` is nil during `makeNSView` — the view must be inserted into the window hierarchy first.

---

## Watch in App / Watch in VLC

Buttons appear in the web guide summary panel **only when:**
1. The page is loaded inside a `WKWebView` (JS checks `window.webkit?.messageHandlers?.watch`)
2. The selected show is currently on air (`_wLive` flag in JS)

Clicking either button posts to the `"watch"` message handler:
```javascript
function doWatchInApp() {
    window.webkit.messageHandlers.watch.postMessage({type:'app', deviceId:_d, guideNumber:_n, title:_title});
}
function doWatchInVLC() {
    window.webkit.messageHandlers.watch.postMessage({type:'vlc', deviceId:_d, guideNumber:_n, title:_title});
}
```

The Swift coordinator receives the message, looks up the stream URL from `state.lineups`, then calls the appropriate `AppState` watch method. When `Watch_in_VLC` is disabled or VLC is absent, `watchInVLC` is a no-op server-side (the button still appears because the web page can't query app settings).
