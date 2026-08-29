// Builds tools/dmg_assets/generated/Read Me.rtfd — the DMG's user manual — fresh from
// docs/screenshots/ every time it's run (never a tracked, staleness-prone binary), the same
// "regenerate from source at release time" philosophy deploy_release.sh already applies to
// AppIcon.icns/favicon.ico. Run via `swift tools/build_readme_manual.swift <repo_root>`.
//
// Uses Cocoa's own NSAttributedString RTFD writer, not hand-rolled RTF markup — three earlier
// approaches (textutil's HTML→RTFD image conversion, and two different hand-written \pict RTF
// control-word attempts) all silently dropped or corrupted the embedded images; NSAttachment(data:
// ofType:) + .fileWrapper(from:documentAttributes:) is the one path that reliably round-trips real
// image data through Cocoa's own reader, since that's the exact format its own reader expects.
import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("Usage: swift build_readme_manual.swift <repo_root>\n".data(using: .utf8)!)
    exit(1)
}
let repoRoot = CommandLine.arguments[1]
let screens = repoRoot + "/docs/screenshots"
let outDir = repoRoot + "/tools/dmg_assets/generated"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let out = outDir + "/Read Me.rtfd"

let bodyFont = NSFont(name: "Geneva", size: 13) ?? NSFont.systemFont(ofSize: 13)
let h1Font = NSFont(name: "Geneva-Bold", size: 22) ?? NSFont.boldSystemFont(ofSize: 22)
let h2Font = NSFont(name: "Geneva-Bold", size: 15) ?? NSFont.boldSystemFont(ofSize: 15)
let captionFont = NSFontManager.shared.convert(NSFont(name: "Geneva", size: 11) ?? NSFont.systemFont(ofSize: 11), toHaveTrait: .italicFontMask)

let centerPara = NSMutableParagraphStyle()
centerPara.alignment = .center
centerPara.paragraphSpacing = 10

let leftPara = NSMutableParagraphStyle()
leftPara.alignment = .left
leftPara.paragraphSpacing = 12
leftPara.lineSpacing = 2

let doc = NSMutableAttributedString()

func addH1(_ s: String) {
    doc.append(NSAttributedString(string: s + "\n", attributes: [.font: h1Font, .paragraphStyle: centerPara]))
}
func addTagline(_ s: String) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.paragraphSpacing = 16
    let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    doc.append(NSAttributedString(string: s + "\n", attributes: [.font: italic, .paragraphStyle: para]))
}
func addH2(_ s: String) {
    let para = NSMutableParagraphStyle()
    para.alignment = .left
    para.paragraphSpacingBefore = 14
    para.paragraphSpacing = 4
    doc.append(NSAttributedString(string: s + "\n", attributes: [.font: h2Font, .paragraphStyle: para]))
}
func addBody(_ s: String) {
    doc.append(NSAttributedString(string: s + "\n", attributes: [.font: bodyFont, .paragraphStyle: leftPara]))
}
func addImage(_ filename: String, displayWidth: CGFloat) {
    let path = screens + "/" + filename
    guard let image = NSImage(contentsOfFile: path), let pngData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write("MISSING IMAGE: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    let size = image.size
    let scale = displayWidth / size.width
    let displaySize = NSSize(width: displayWidth, height: size.height * scale)

    // NSTextAttachment(data:ofType:) is what actually gives the attachment a real fileWrapper —
    // the RTFD exporter serializes each attachment's own fileWrapper into the package, not
    // whatever NSImage happens to be wired up for on-screen display alone.
    let attachment = NSTextAttachment(data: pngData, ofType: "public.png")
    attachment.bounds = NSRect(origin: .zero, size: displaySize)

    let imgPara = NSMutableParagraphStyle()
    imgPara.alignment = .center
    imgPara.paragraphSpacingBefore = 8
    imgPara.paragraphSpacing = 2

    let attachmentString = NSMutableAttributedString(attachment: attachment)
    attachmentString.addAttribute(.paragraphStyle, value: imgPara, range: NSRange(location: 0, length: attachmentString.length))
    doc.append(attachmentString)
    doc.append(NSAttributedString(string: "\n"))
}
func addCaption(_ s: String) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.paragraphSpacing = 16
    doc.append(NSAttributedString(string: s + "\n", attributes: [.font: captionFont, .paragraphStyle: para]))
}
func addRule() {
    let para = NSMutableParagraphStyle()
    para.paragraphSpacingBefore = 6
    para.paragraphSpacing = 10
    doc.append(NSAttributedString(string: String(repeating: "\u{2014}", count: 40) + "\n", attributes: [.font: bodyFont, .paragraphStyle: para, .foregroundColor: NSColor.darkGray]))
}

addH1("hdhrVCRplus")
addTagline("a free menu-bar DVR for your HDHomeRun tuner")
addRule()

addBody("Thanks for trying hdhrVCRplus. It lives quietly in your Mac's menu bar and records shows from your HDHomeRun tuner in the background — no subscription, no media server, and no account to create. This Read Me covers everything you need to get your first recording scheduled.")

addH2("Getting Started")
addBody("The first time hdhrVCRplus opens, a short setup wizard walks you through finding your tuner, picking where recordings are saved, and choosing when you'd like to be notified before a show records. You can revisit any of these choices later from Settings \u{2192} Maintenance \u{2192} Reset First-Run Setup.")
addBody("Once set up, look for the hdhrVCRplus icon in your menu bar — that's the whole application. There is no Dock icon and no separate window to keep open.")

addH2("The Menu Bar")
addBody("Click the menu bar icon to see what's recording right now, what's coming up next, and everything you've scheduled — organized into Recording, Up Next, Scheduled, and Paused sections. Clicking a show reveals quick actions like Edit, Pause, or Delete.")
addImage("menu.png", displayWidth: 320)
addCaption("The menu bar dropdown — your control center.")
addImage("recording.png", displayWidth: 380)
addCaption("A show currently recording, with its progress and remaining time.")

addH2("The Program Guide")
addBody("Add Show opens a full cable-style guide — channels down the side, time across the top, color-coded by genre. A search box at the top finds a show by name in a couple of keystrokes, favorited channels get their own row, and a live red line shows you exactly where \"now\" is on the grid.")
addImage("guide.png", displayWidth: 460)
addCaption("The program guide, with the live \"now\" indicator and per-channel signal bars.")

addH2("Scheduling a Recording")
addBody("Click any program in the guide to see its details, then choose how you'd like it recorded: once, every week at that time, every new episode on that channel, or every new episode on any channel this tuner receives. Existing recordings can be revisited the same way from the Edit screen.")
addImage("addshow_details.png", displayWidth: 400)
addCaption("Scheduling a new recording, with the four recurrence choices.")
addImage("edit_show.png", displayWidth: 400)
addCaption("Editing an existing scheduled recording.")

addH2("Settings")
addBody("Everything else — where recordings are saved, how much free disk space to keep in reserve, transcoding, notification timing, Discord alerts, and sharing the guide with other devices on your network — lives in one Settings window, organized by tab.")
addImage("settings_general.png", displayWidth: 460)
addCaption("Settings \u{2192} General.")

addH2("Watching From Elsewhere")
addBody("With Sharing turned on in Settings, any browser on your home network can open the same program guide and schedule recordings — handy for a phone, tablet, or another computer. A companion terminal client, hdhr_guide, offers the same guide and scheduling from a Terminal window or over SSH, for anyone who'd rather not open a browser.")

addH2("Getting Help")
addBody("hdhrVCRplus is free and open-source. The project's source code, documentation, and issue tracker live on GitHub — see Settings \u{2192} About for the project link and your current version number.")

addRule()
addCaption("hdhrVCRplus — free, open-source, and yours to keep.")

let fullRange = NSRange(location: 0, length: doc.length)
do {
    let wrapper = try doc.fileWrapper(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    let outURL = URL(fileURLWithPath: out)
    try? FileManager.default.removeItem(at: outURL)
    try wrapper.write(to: outURL, options: [.atomic], originalContentsURL: nil)
    print("wrote \(out)")
} catch {
    FileHandle.standardError.write("ERROR: \(error)\n".data(using: .utf8)!)
    exit(1)
}
