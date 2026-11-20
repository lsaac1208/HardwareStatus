import Cocoa

/// One menubar item, already formatted by the sampler.
enum StatusSegment: Equatable {
    case metric(label: String, value: String, level: LoadLevel)
    case rates(down: String, up: String)
}

/// Menubar typography, value-primary:
/// - Values: 12 pt semibold tabular digits in full ink (1.0 opacity)
/// - Labels: 9.5 pt regular in muted ink (0.68 opacity) for effortless glanceability
/// - `.compact` mode renders network rates as a crisp Retina 2-line stacked attachment (↑ over ↓),
///   reclaiming ~35–45% of menubar width with zero awkward leading-space gaps.
/// - Pre-resolved solid dark/light palettes avoid NSCustomDynamicColor closures during CoreText redraws.
enum StatusTitle {
    static let valueFont: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let labelFont: NSFont = .systemFont(ofSize: 9.5, weight: .regular)
    static let arrowFont: NSFont = .systemFont(ofSize: 10.5, weight: .semibold)
    static let stackRateFont: NSFont = .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    static let stackArrowFont: NSFont = .systemFont(ofSize: 8.0, weight: .bold)

    private static let thinSpace = "\u{2009}"
    private static let hairSpace = "\u{200A}"
    private static let labelBaseline: CGFloat = 0.5
    private static let stackedArrowW: CGFloat = 8.5
    private static let stackedMinTextW: CGFloat = 25
    private static let stackedHeight: CGFloat = 17
    private static var cachedStackedKey: String = ""
    private static var cachedStackedImage: NSImage?
    private static var cachedStackedWidth: CGFloat = 36

    private struct Palette {
        let valueAttrs: [NSAttributedString.Key: Any]
        let labelAttrs: [NSAttributedString.Key: Any]
        let sepAttrs: [NSAttributedString.Key: Any]
        let arrowAttrs: [NSAttributedString.Key: Any]
        let arrowSubAttrs: [NSAttributedString.Key: Any]
        let stackDownAttrs: [NSAttributedString.Key: Any]
        let stackUpAttrs: [NSAttributedString.Key: Any]
        let stackDownArrowAttrs: [NSAttributedString.Key: Any]
        let stackUpArrowAttrs: [NSAttributedString.Key: Any]
        let warnAttrs: [NSAttributedString.Key: Any]
        let critAttrs: [NSAttributedString.Key: Any]

        init(dark: Bool) {
            let w: CGFloat = dark ? 1 : 0
            let valColor = NSColor(white: w, alpha: 1.0)
            let lblColor = NSColor(white: w, alpha: 0.68)
            let sepColor = NSColor(white: w, alpha: 0.36)
            let upColor = NSColor(white: w, alpha: 0.76)
            let downArrowColor = NSColor(white: w, alpha: 0.92)
            let upArrowColor = NSColor(white: w, alpha: 0.68)
            let rightPara = NSMutableParagraphStyle()
            rightPara.alignment = .right
            rightPara.lineBreakMode = .byClipping

            valueAttrs = [.font: StatusTitle.valueFont, .foregroundColor: valColor]
            labelAttrs = [.font: StatusTitle.labelFont, .foregroundColor: lblColor, .baselineOffset: StatusTitle.labelBaseline]
            sepAttrs   = [.font: StatusTitle.labelFont, .foregroundColor: sepColor, .baselineOffset: StatusTitle.labelBaseline]
            arrowAttrs = [.font: StatusTitle.arrowFont, .foregroundColor: downArrowColor]
            arrowSubAttrs = [.font: StatusTitle.arrowFont, .foregroundColor: upArrowColor]
            stackDownAttrs = [.font: StatusTitle.stackRateFont, .foregroundColor: valColor, .paragraphStyle: rightPara]
            stackUpAttrs   = [.font: StatusTitle.stackRateFont, .foregroundColor: upColor, .paragraphStyle: rightPara]
            stackDownArrowAttrs = [.font: StatusTitle.stackArrowFont, .foregroundColor: downArrowColor]
            stackUpArrowAttrs   = [.font: StatusTitle.stackArrowFont, .foregroundColor: upArrowColor]
            warnAttrs  = [.font: StatusTitle.valueFont, .foregroundColor: HIG.warn]
            critAttrs  = [.font: StatusTitle.valueFont, .foregroundColor: HIG.critical]
        }
    }

    private static let darkPalette = Palette(dark: true)
    private static let lightPalette = Palette(dark: false)

    static func attributed(_ segments: [StatusSegment], dark: Bool, style: MenubarStyle = .compact) -> NSAttributedString {
        let pal = dark ? darkPalette : lightPalette
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: thinSpace, attributes: pal.labelAttrs))
        if segments.isEmpty {
            out.append(NSAttributedString(string: "—", attributes: pal.valueAttrs))
            return out
        }
        let sep = "\(thinSpace)\(hairSpace)·\(hairSpace)\(thinSpace)"
        for (i, seg) in segments.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: sep, attributes: pal.sepAttrs)) }
            switch seg {
            case let .metric(label, value, level):
                out.append(NSAttributedString(string: label + thinSpace, attributes: pal.labelAttrs))
                let attrs: [NSAttributedString.Key: Any]
                switch level {
                case .normal: attrs = pal.valueAttrs
                case .warn: attrs = pal.warnAttrs
                case .critical: attrs = pal.critAttrs
                }
                out.append(NSAttributedString(string: value, attributes: attrs))
            case let .rates(down, up):
                if style == .compact {
                    let (img, w) = stackedRatesImage(down: down, up: up, dark: dark, palette: pal)
                    let att = NSTextAttachment()
                    att.image = img
                    att.bounds = NSRect(x: 0, y: -4.0, width: w, height: stackedHeight)
                    out.append(NSAttributedString(attachment: att))
                } else {
                    out.append(NSAttributedString(string: "↓\(hairSpace)", attributes: pal.arrowAttrs))
                    out.append(NSAttributedString(string: down, attributes: pal.valueAttrs))
                    out.append(NSAttributedString(string: "\(thinSpace)\(thinSpace)↑\(hairSpace)", attributes: pal.arrowSubAttrs))
                    out.append(NSAttributedString(string: up, attributes: pal.valueAttrs))
                }
            }
        }
        return out
    }

    static func key(_ segments: [StatusSegment], dark: Bool, style: MenubarStyle = .compact) -> String {
        let body = segments.map {
            switch $0 {
            case let .metric(l, v, lv): return "\(l)\(v)\(lv)"
            case let .rates(d, u): return "↓\(d)↑\(u)"
            }
        }.joined(separator: "·")
        return (dark ? "D|" : "L|") + style.rawValue + "|" + body
    }

    static func width(_ segments: [StatusSegment], style: MenubarStyle = .compact) -> CGFloat {
        ceil(attributed(segments, dark: true, style: style).size().width)
    }

    /// Renders crisp @2x Retina stacked network rates (↑ on top, ↓ on bottom) sized tightly to the
    /// widest active rate string so arrows hug the digits with zero wasted menubar width.
    private static func stackedRatesImage(down: String, up: String, dark: Bool, palette: Palette) -> (NSImage, CGFloat) {
        let cacheKey = "\(dark ? "D" : "L")|\(up)|\(down)"
        if cacheKey == cachedStackedKey, let img = cachedStackedImage {
            return (img, cachedStackedWidth)
        }
        let upAttr = NSAttributedString(string: up, attributes: palette.stackUpAttrs)
        let dnAttr = NSAttributedString(string: down, attributes: palette.stackDownAttrs)
        let textW = ceil(max(stackedMinTextW, max(upAttr.size().width, dnAttr.size().width)))
        let w = ceil(stackedArrowW + textW + 1)
        let h = stackedHeight
        let pxW = Int(w * 2), pxH = Int(h * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return (NSImage(size: NSSize(width: w, height: h)), w)
        }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.shouldAntialias = true
            // Cocoa flipped=false: y=0 is bottom (↓), y=8 is top (↑)
            let valRectUp = NSRect(x: stackedArrowW, y: 8.0, width: textW, height: 9.0)
            let valRectDn = NSRect(x: stackedArrowW, y: -0.5, width: textW, height: 9.0)
            NSAttributedString(string: "↑", attributes: palette.stackUpArrowAttrs)
                .draw(at: NSPoint(x: 0.5, y: 8.5))
            upAttr.draw(in: valRectUp)
            NSAttributedString(string: "↓", attributes: palette.stackDownArrowAttrs)
                .draw(at: NSPoint(x: 0.5, y: 0.0))
            dnAttr.draw(in: valRectDn)
        }
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: w, height: h))
        img.addRepresentation(rep)
        cachedStackedKey = cacheKey
        cachedStackedImage = img
        cachedStackedWidth = w
        return (img, w)
    }
}
