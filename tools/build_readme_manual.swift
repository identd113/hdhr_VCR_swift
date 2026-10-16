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

addBody("Thanks for trying hdhrVCRplus. It lives quietly in your Mac's menu bar and records shows from your HDHomeRun tuner in the background \u{2014} no subscription, no media server, and no account to create. This Read Me tours everything: the menu bar, the program guide, watching TV and your recordings, the web guide for your phone and other computers, the terminal guide, notifications, and the settings that matter.")

addH2("What You Need")
addBody("A Mac running macOS 15 (Sequoia) or later with an Apple Silicon chip, and an HDHomeRun network tuner (CONNECT, PRIME, EXTEND, FLEX and so on) on the same network. VLC (in your Applications folder) is optional and is only needed for the built-in player, Watch Now.")

addH2("Getting Started")
addBody("Drag hdhrVCRplus to your Applications folder and open it. A short launch screen shows the app finding your tuner, loading its channel lineup and loading the guide. The first time, a setup wizard follows it in the same window: it finds your tuner, asks where recordings should be saved, and lets you choose how early you want to be told before a show records. Finish it once; you can run it again any time from Settings \u{2192} Maintenance \u{2192} Reset First-Run Setup.")
addBody("When the launch screen ends, it glides up to the hdhrVCRplus icon in your menu bar \u{2014} that's where the app lives. macOS asks once for permission to find devices on your local network; say yes, or the app can't see your tuner. (The app may show a Dock icon until that permission is confirmed; after that it's menu bar only, and Settings \u{2192} Advanced lets you choose either way.)")

addH2("The Menu Bar")
addBody("Click the menu bar icon to see what's recording right now, what's coming up next, and everything you've scheduled \u{2014} Recording, Up Next, Scheduled and Paused sections, with a header showing how many tuners are in use and by what. Click a show for quick actions: Edit, Pause, Skip, Delete, Show Recording in Finder, and Watch Now! on anything that's recording. The icon's little light tells you at a glance what the app is doing; Settings \u{2192} About lets you click through every pattern.")
addImage("menu.png", displayWidth: 320)
addCaption("The menu bar dropdown \u{2014} your control center.")
addImage("recording.png", displayWidth: 380)
addCaption("A show currently recording, with its progress and remaining time.")

addH2("The Program Guide")
addBody("Add Show opens a full cable-style guide \u{2014} channels down the side, time across the top, tiles color-coded by genre. A search box finds a show by name in a couple of keystrokes, favorite channels get their own row at the top, green NEW badges flag original episodes, and a live red line shows where \"now\" is. Little signal bars beside each channel come from real tuner readings, so you can see which channels are solid before you schedule one.")
addImage("guide.png", displayWidth: 460)
addCaption("The program guide, with the live \"now\" indicator and per-channel signal bars.")

addH2("Scheduling a Recording")
addBody("Click any program to see its details, then choose how to record it: once; every week at that time (pick the days); every new episode on that channel; or every new episode on any channel that tuner receives. Series are matched by the guide's own series ID, so reruns and retitled episodes are still caught. Useful options: New Only skips reruns, Skip Already Recorded (Settings \u{2192} Recording, with Series subfolders on) won't grab an episode it already has on disk, and Bonus Time adds extra minutes after the scheduled end (sports get this automatically, since live events run long).")
addImage("addshow_details.png", displayWidth: 400)
addCaption("Scheduling a new recording, with the four recurrence choices.")
addImage("edit_show.png", displayWidth: 400)
addCaption("Editing an existing scheduled recording.")
addBody("The app keeps going without you: it reattaches to a recording if the app or Mac restarts, pauses a show that keeps failing, pauses a show whose tuner has gone missing and resumes it when the tuner returns, and keeps the Mac awake while a recording is running.")

addH2("Watching TV and Your Recordings")
addBody("Watch Now opens a built-in player (VLC-powered) with a channel picker, volume and audio-output controls, and full-screen with arrow-key seeking. If a show is already recording, Watch Now! plays it straight from disk instead of opening a second tuner \u{2014} and a scrub bar lets you jump anywhere already recorded. Right-click the video to add picture-in-picture windows (live channels or a recording), drag a corner to resize, and click one to swap it into the main window. The player can also cast to a Chromecast on your network (Beta).")
addBody("Recording FEED (Beta): turn on Settings \u{2192} Sharing \u{2192} Rebroadcast In-Progress Recordings and another Mac running hdhrVCRplus on your network can watch your in-progress recording live \u{2014} even scrub back through it \u{2014} without using a second tuner.")

addH2("The Web Guide \u{2014} Any Browser on Your Network")
addBody("Turn on Settings \u{2192} Sharing \u{2192} Enable Web LAN and the same guide is available in any browser on your home network at http://<your-mac's-address>:1980 \u{2014} perfect for scheduling from a laptop, tablet or phone while the Mac sits in a closet. You see each tuner's Recording, Up Next and Scheduled lists, and you can schedule, edit, pause and delete just as in the app. On a phone, open http://<your-mac's-address>:1980/vertical for a calendar-style guide that fits a portrait screen. The web guide is for your local network only; it is not meant to be exposed to the internet.")

addH2("The Terminal Guide")
addBody("Prefer the keyboard? hdhrVCRplus includes a full-screen guide for Terminal. With Web LAN on, turn on Settings \u{2192} Sharing \u{2192} Terminal Guide and click Open in Terminal \u{2014} or run it yourself, from your Mac or over SSH from another computer, with: /Applications/hdhrVCRplus.app/Contents/Helpers/hdhr_guide")
addImage("tui_guide_grid.png", displayWidth: 460)
addCaption("The terminal guide: genre-tinted channel grid, selection, summary panel and signal dots.")
addBody("Move between channels with the up and down arrows and between programs with left and right. Press / to search by show name (or jump to a channel, for example #5.1), Tab to switch tuners, f to favorite a channel, and ? for the full list of keys. Press Enter on a program to schedule it: the summary screen offers the same four choices as the app.")
addImage("tui_guide_schedule.png", displayWidth: 460)
addCaption("Scheduling from the terminal: once, weekly, or a series on this channel or any channel.")
addBody("Press d on something already scheduled to remove it, and q to quit.")

addH2("Notifications and Discord")
addBody("macOS notifications tell you what's Up Next and when a Recording is Soon. If you use Discord, paste a webhook URL into Settings \u{2192} Notifications and hdhrVCRplus posts neat cards when a recording starts, finishes (with its file size), fails, pauses, or hits a conflict \u{2014} each type can be switched on or off, and a Test button checks the webhook right away.")
addImage("settings_notifications.png", displayWidth: 460)
addCaption("Settings \u{2192} Notifications.")

addH2("Settings")
addBody("Where recordings are saved and how much free disk space to keep in reserve, transcoding (none, heavy, mobile, internet720), keeping recordings out of Time Machine backups, guide options, the launch screen, Launch at Login, sharing, and Export/Import Config (move your whole setup, shows included, to another Mac in one file) all live in one Settings window, organized by tab.")
addImage("settings_general.png", displayWidth: 460)
addCaption("Settings \u{2192} General.")
addImage("settings_recording.png", displayWidth: 460)
addCaption("Settings \u{2192} Recording.")

addH2("Staying Up to Date")
addBody("hdhrVCRplus checks GitHub once a day for a newer release and tells you in the menu when there is one. Settings \u{2192} About shows your version and links to the project.")

addH2("If Something Goes Wrong")
addBody("Check that your Mac and the tuner are on the same network and that hdhrVCRplus is allowed under System Settings \u{2192} Privacy & Security \u{2192} Local Network. The app writes a log to ~/Library/Logs/hdhrVCRplus.log (secrets such as webhook tokens are masked), which is the first thing to attach to a bug report. Settings \u{2192} Advanced has verbose recording logs for chasing a stubborn recording problem.")

addH2("Free, With a Tip Jar")
addBody("hdhrVCRplus is free and open-source (GPL v3), and the program guide is free courtesy of SiliconDust. If you find it useful, an occasional card in the app invites you to leave a tip via PayPal; if you've tipped, enter your code to stop seeing it. The source code, documentation and issue tracker live on GitHub.")

addRule()
addCaption("hdhrVCRplus \u{2014} free, open-source, and yours to keep.")

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
