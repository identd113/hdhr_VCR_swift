// Sets a file/folder's custom Finder icon via NSWorkspace — the same API Finder itself uses to
// draw icons, so this is a real, verifiable apply (confirmed in practice: plain `cp -R` on a
// bundle/folder does NOT reliably preserve this attribute, so any script that copies a
// custom-iconed item afterward must re-apply it at the final destination, not just once upstream).
// Usage: swift apply_finder_icon.swift <icon.icns> <target file or folder>
import AppKit

guard CommandLine.arguments.count > 2 else {
    FileHandle.standardError.write("Usage: swift apply_finder_icon.swift <icon.icns> <target>\n".data(using: .utf8)!)
    exit(1)
}
let iconPath = CommandLine.arguments[1]
let targetPath = CommandLine.arguments[2]

guard let icon = NSImage(contentsOfFile: iconPath) else {
    FileHandle.standardError.write("ERROR: couldn't load icon at \(iconPath)\n".data(using: .utf8)!)
    exit(1)
}
guard NSWorkspace.shared.setIcon(icon, forFile: targetPath, options: []) else {
    FileHandle.standardError.write("ERROR: setIcon failed for \(targetPath)\n".data(using: .utf8)!)
    exit(1)
}
print("applied \(iconPath) -> \(targetPath)")
