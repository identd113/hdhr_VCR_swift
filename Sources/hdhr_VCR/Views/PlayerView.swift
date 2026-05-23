import AVKit
import AppKit

private extension String {
    func appendLine(to path: String) throws {
        let data = Data(self.utf8)
        if FileManager.default.fileExists(atPath: path),
           let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
        } else {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// Manages a single reusable pop-out player window. Calling play() a second time
// replaces the current stream in the same window rather than opening a new one.
@MainActor
final class PlayerWindowManager {
    static let shared = PlayerWindowManager()

    private var window: NSWindow?
    private var player: AVPlayer?
    private var statusObserver: NSKeyValueObservation?

    private init() {}

    func play(url: URL, title: String) {
        let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/hdhr_player.log")
        let logLine = "[\(Date())] play url=\(url)\n"
        try? logLine.appendLine(to: logPath)
        let avPlayer = AVPlayer(url: url)
        self.player = avPlayer

        let playerView = AVPlayerView()
        playerView.player = avPlayer
        playerView.controlsStyle = .inline

        statusObserver?.invalidate()
        let lp = logPath
        statusObserver = avPlayer.currentItem?.observe(\.status) { item, _ in
            let line = "[\(Date())] item status=\(item.status.rawValue) error=\(item.error?.localizedDescription ?? "none") underlyingError=\(String(describing: (item.error as NSError?)?.userInfo))\n"
            try? line.appendLine(to: lp)
        }

        if let win = window {
            win.contentView = playerView
            win.title = title
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = title
            win.contentView = playerView
            win.isReleasedWhenClosed = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.window = win
        }

        avPlayer.play()
    }
}
