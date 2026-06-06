import SwiftUI
import WebKit

// Standalone cable guide browser — opened from the Add Show wizard or directly from the menu bar.
// Loads the web guide in a WKWebView; Watch in App / Watch in VLC via WKScriptMessage bridge.
// Window floats above normal windows via FloatingWindowLevelSetter.
struct FloatingGuideView: View {

    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if state.webServerRunning {
                GuideWebView(port: state.config.Web_server_port) { [state] type, deviceId, guideNumber, title in
                    guard let url = state.lineups[deviceId]?.first(where: { $0.GuideNumber == guideNumber })?.URL else { return }
                    if type == "app" {
                        state.watchInApp(url: url, title: title, deviceId: deviceId, guideNumber: guideNumber)
                    } else {
                        state.watchInVLC(url: url, deviceId: deviceId)
                    }
                }
            } else {
                ProgressView("Starting guide…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { state.ensureWebServerRunning() }
        .onDisappear { state.releaseInternalWebServer() }
        .onExitCommand { dismiss() }
        .background(FloatingWindowLevelSetter())
        .frame(minWidth: 1100, minHeight: 720)
    }
}

// WKWebView loading http://localhost:{port}/. Blocks off-localhost navigation; syncs
// dark/light theme after page load; routes Watch in App / Watch in VLC taps to Swift.
private struct GuideWebView: NSViewRepresentable {
    let port: Int
    let onWatch: (String, String, String, String) -> Void  // type, deviceId, guideNumber, title

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "watch")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: URL(string: "http://localhost:\(port)/")!))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "watch")
    }

    func makeCoordinator() -> Coordinator { Coordinator(onWatch: onWatch) }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onWatch: (String, String, String, String) -> Void

        init(onWatch: @escaping (String, String, String, String) -> Void) {
            self.onWatch = onWatch
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "watch", let body = message.body as? [String: Any] else { return }
            let type     = body["type"]        as? String ?? ""
            let deviceId = body["deviceId"]    as? String ?? ""
            let guideNum = body["guideNumber"] as? String ?? ""
            let title    = body["title"]       as? String ?? ""
            DispatchQueue.main.async { self.onWatch(type, deviceId, guideNum, title) }
        }

        func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.host == "localhost" ? .allow : .cancel)
        }

        func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            wv.evaluateJavaScript(
                "localStorage.setItem('theme','\(isDark ? "dark" : "light")');if(typeof applyTheme==='function')applyTheme();",
                completionHandler: nil
            )
        }
    }
}

// Raises the host NSWindow to the floating level so the guide stays above regular windows.
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
