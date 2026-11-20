import Cocoa

/// One menubar item, already formatted by the sampler.
enum StatusSegment: Equatable {
    case metric(label: String, value: String, level: LoadLevel)
    case rates(down: String, up: String)
}

/// Menubar typography, value-primary: numbers 12 pt semibold tabular in full ink,
/// labels 10 pt medium at 0.9 opacity. Fonts and pre-resolved solid colors (no dynamic
/// color closures inside CoreText / NSStatusItem replicant draws) minimize redraw CPU.
enum StatusTitle {
    static let valueFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let labelFont: NSFont = .systemFont(ofSize: 10, weight: .medium)
    static let arrowFont: NSFont = .systemFont(ofSize: 11, weight: .semibold)

    private static let figureSpace = "\u{2007}"
    private static let thinSpace = "\u{2009}"
    private static let hairSpace = "\u{200A}"
    private static let labelBaseline: CGFloat = 0.5

    // Pre-resolved static attribute dictionaries for dark & light menubars:
    // avoids invoking NSCustomDynamicColor closures on every glyph run in CoreText / replicants.
    private struct Palette {
        let valueAttrs: [NSAttributedString.Key: Any]
        let labelAttrs: [NSAttributedString.Key: Any]
        let sepAttrs: [NSAttributedString.Key: Any]
        let arrowAttrs: [NSAttributedString.Key: Any]
        let warnAttrs: [NSAttributedString.Key: Any]
        let critAttrs: [NSAttributedString.Key: Any]

        init(dark: Bool) {
            let w: CGFloat = dark ? 1 : 0
            let valColor = NSColor(white: w, alpha: 1.0)
            let lblColor = NSColor(white: w, alpha: 0.9)
            let sepColor = NSColor(white: w, alpha: 0.52)
            valueAttrs = [.font: StatusTitle.valueFont, .foregroundColor: valColor]
            labelAttrs = [.font: StatusTitle.labelFont, .foregroundColor: lblColor, .baselineOffset: StatusTitle.labelBaseline]
            sepAttrs   = [.font: StatusTitle.labelFont, .foregroundColor: sepColor, .baselineOffset: StatusTitle.labelBaseline]
            arrowAttrs = [.font: StatusTitle.arrowFont, .foregroundColor: valColor]
            warnAttrs  = [.font: StatusTitle.valueFont, .foregroundColor: HIG.warn]
            critAttrs  = [.font: StatusTitle.valueFont, .foregroundColor: HIG.critical]
        }
    }

    private static let darkPalette = Palette(dark: true)
    private static let lightPalette = Palette(dark: false)

    static func attributed(_ segments: [StatusSegment], dark: Bool) -> NSAttributedString {
        let pal = dark ? darkPalette : lightPalette
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: " ", attributes: pal.labelAttrs))
        if segments.isEmpty {
            out.append(NSAttributedString(string: "—", attributes: pal.valueAttrs))
            return out
        }
        let sep = "\(thinSpace)\(hairSpace)·\(hairSpace)\(thinSpace)"
        for (i, seg) in segments.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: sep, attributes: pal.sepAttrs)) }
            switch seg {
            case let .metric(label, value, level):
                out.append(NSAttributedString(string: label + hairSpace, attributes: pal.labelAttrs))
                let attrs: [NSAttributedString.Key: Any]
                switch level {
                case .normal: attrs = pal.valueAttrs
                case .warn: attrs = pal.warnAttrs
                case .critical: attrs = pal.critAttrs
                }
                out.append(NSAttributedString(string: figurePadded(value), attributes: attrs))
            case let .rates(down, up):
                out.append(NSAttributedString(string: "↓", attributes: pal.arrowAttrs))
                out.append(NSAttributedString(string: figurePadded(down), attributes: pal.valueAttrs))
                out.append(NSAttributedString(string: " ↑", attributes: pal.arrowAttrs))
                out.append(NSAttributedString(string: figurePadded(up), attributes: pal.valueAttrs))
            }
        }
        return out
    }

    static func key(_ segments: [StatusSegment], dark: Bool) -> String {
        let body = segments.map {
            switch $0 {
            case let .metric(l, v, lv): return "\(l)\(v)\(lv)"
            case let .rates(d, u): return "↓\(d)↑\(u)"
            }
        }.joined(separator: "·")
        return (dark ? "D|" : "L|") + body
    }

    static func width(_ segments: [StatusSegment]) -> CGFloat {
        ceil(attributed(segments, dark: true).size().width)
    }

    static func figurePadded(_ s: String) -> String {
        let pad = s.prefix { $0 == " " }.count
        if pad == 0 { return s }
        return String(repeating: figureSpace, count: pad) + s.dropFirst(pad)
    }
}
