import Foundation

// Diagnostic-only log for hdhr_guide — separate from hdhr_VCR's own glog()/RotatingLogFile
// (a different module; not worth importing hdhr_VCR, an executable not a library, just for this).
// Exists specifically to see what raw bytes actually arrive for a keypress that isn't behaving as
// expected — printing to stdout isn't an option here, it would corrupt the alternate-screen
// display, so this writes to its own file instead, tailable from a second terminal while the app
// runs. Truncated at launch past 2MB — this is meant for a short debugging session, not
// unbounded-runtime logging, so it doesn't need RotatingLogFile's full generation-rotation scheme.
enum DebugLog {
    static let path = NSHomeDirectory() + "/Library/Logs/hdhrVCRplus-guide-debug.log"

    private static let handle: FileHandle? = {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(atPath: path)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        let h = FileHandle(forWritingAtPath: path)
        h?.seekToEndOfFile()
        return h
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        guard let handle else { return }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
    }
}
