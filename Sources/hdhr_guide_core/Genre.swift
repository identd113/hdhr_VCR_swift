import Foundation

// Same palette as Resources/guide.js's _gcDk (the web guide's dark-mode genre background tints)
// and the alias table right below it — kept as (h, s, l) rather than hand-transcribed RGB so
// there's one obviously-correct source, not a second place these can silently drift apart from
// guide.js if that palette ever changes. All are dark, muted tones (30–38% lightness) chosen to
// host light text, which is why cell text below just uses a plain bright foreground rather than
// a per-genre-tuned one.
private let genreHSL: [String: (h: Double, s: Double, l: Double)] = [
    "drama": (216, 48, 35), "comedy": (47, 48, 35), "news": (342, 43, 35), "sports": (119, 48, 31),
    "reality": (25, 48, 35), "movie": (270, 58, 38), "talk": (173, 43, 34), "children": (315, 43, 35),
    "crime": (0, 55, 33), "romance": (333, 50, 37), "thriller": (238, 48, 38), "action": (12, 52, 35),
    "mystery": (255, 52, 38), "doc": (202, 48, 35), "science": (188, 52, 33), "nature": (82, 50, 33),
    "history": (28, 50, 34), "music": (287, 52, 37), "food": (52, 52, 34), "travel": (182, 48, 33),
    "gameshow": (58, 55, 34), "home": (35, 46, 33), "health": (148, 50, 32), "faith": (65, 48, 32)
]

private let genreAlias: [String: String] = [
    "sitcom": "comedy", "movies": "movie", "kids": "children", "sport": "sports",
    "documentary": "doc", "game show": "gameshow", "animation": "children", "animated": "children"
]

private func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (UInt8, UInt8, UInt8) {
    let s = s / 100, l = l / 100
    let c = (1 - abs(2 * l - 1)) * s
    let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = l - c / 2
    let (r1, g1, b1): (Double, Double, Double)
    switch h {
    case 0..<60:   (r1, g1, b1) = (c, x, 0)
    case 60..<120: (r1, g1, b1) = (x, c, 0)
    case 120..<180: (r1, g1, b1) = (0, c, x)
    case 180..<240: (r1, g1, b1) = (0, x, c)
    case 240..<300: (r1, g1, b1) = (x, 0, c)
    default:        (r1, g1, b1) = (c, 0, x)
    }
    return (UInt8(((r1 + m) * 255).rounded()), UInt8(((g1 + m) * 255).rounded()), UInt8(((b1 + m) * 255).rounded()))
}

// 24-bit ANSI background escape for a genre name, or "" when unrecognized/nil — an empty guide
// slot or an unmapped genre just gets the terminal's own default background, same as the web
// guide's ungenred rows.
public func genreBackground(_ genre: String?) -> String {
    guard let genre, !genre.isEmpty else { return "" }
    let key = genreAlias[genre.lowercased()] ?? genre.lowercased()
    guard let hsl = genreHSL[key] else { return "" }
    let (r, g, b) = hslToRGB(hsl.h, hsl.s, hsl.l)
    return "\u{1B}[48;2;\(r);\(g);\(b)m"
}
