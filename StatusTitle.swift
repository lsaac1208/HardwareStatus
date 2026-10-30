import Cocoa

/// One menubar item, already formatted by the sampler.
enum StatusSegment: Equatable {
    case metric(label: String, value: String, level: LoadLevel)
    case rates(down: String, up: String)
}

/// Menubar typography. Hierarchy from size/weight. Ink is forced solid white/black —
/// `labelColor` / `secondaryLabelColor` wash out on the translucent menu bar and stay
/// visibly fainter than system menu titles ("文件", the clock). Warn/critical still tint.
enum StatusTitle {
    static var valueFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }
    static var labelFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    private static let figureSpace = "\u{2007}"
    private static let thinSpace = "\u{2009}"

    /// Opaque ink matched to the menubar appearance (not the washed dynamic label colors).
    private static var ink: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)
        }
    }

    private static var sepInk: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.45)
        }
    }

    static func attributed(_ segments: [StatusSegment]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ink = Self.ink
        let sep = Self.sepInk
        func add(_ s: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        add(" ", labelFont, ink)
        if segments.isEmpty { add("—", valueFont, ink) }
        for (i, seg) in segments.enumerated() {
            if i > 0 { add("\(thinSpace)·\(thinSpace)", valueFont, sep) }
            switch seg {
            case let .metric(label, value, level):
                add(label + thinSpace, labelFont, ink)
                // Warn/critical keep their signal colors (already vivid).
                add(figurePadded(value), valueFont, level == .normal ? ink : level.color(tint: ink))
            case let .rates(down, up):
                add("↓", labelFont, ink)
                add(figurePadded(down), valueFont, ink)
                add(" ↑", labelFont, ink)
                add(figurePadded(up), valueFont, ink)
            }
        }
        return out
    }

    static func key(_ segments: [StatusSegment]) -> String {
        segments.map {
            switch $0 {
            case let .metric(l, v, lv): return "\(l)\(v)\(lv)"
            case let .rates(d, u): return "↓\(d)↑\(u)"
            }
        }.joined(separator: "·")
    }

    static func width(_ segments: [StatusSegment]) -> CGFloat {
        ceil(attributed(segments).size().width)
    }

    private static func figurePadded(_ s: String) -> String {
        let pad = s.prefix { $0 == " " }.count
        if pad == 0 { return s }
        return String(repeating: figureSpace, count: pad) + s.dropFirst(pad)
    }
}
