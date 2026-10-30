import Cocoa
import QuartzCore

// MARK: - Design tokens
/// Single source of truth for the panel. Spacing sits on a 4-pt grid; type maps onto the
/// macOS text styles Control Center uses (title3 15, body 13, callout 12, caption 11).
enum HIG {
    // Panel geometry
    static let panelW: CGFloat = 360
    static let panelH: CGFloat = 600        // initial size; the controller fits to content after
    static let panelMinH: CGFloat = 360
    static let panelMaxH: CGFloat = 780
    static let outerX: CGFloat = 12         // popover edge → card edge
    static let outerTop: CGFloat = 16
    static let outerBottom: CGFloat = 12
    static let headerInset: CGFloat = 4     // header text sits slightly inside the card column
    static let cardGap: CGFloat = 10
    static let cardPad: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let footerH: CGFloat = 44
    static var contentW: CGFloat { panelW - outerX * 2 }        // card width
    static var cardInnerW: CGFloat { contentW - cardPad * 2 }   // content column inside a card

    // Rows
    static let rowGap: CGFloat = 14         // between metric rows inside a card
    static let tileSize: CGFloat = 24       // tinted icon tile (System Settings style)
    static let tileSizeSmall: CGFloat = 20
    static let tileRadius: CGFloat = 6
    static let tileGlyph: CGFloat = 12
    static let titleGap: CGFloat = 10       // tile → title
    static let barH: CGFloat = 6
    static let barHSmall: CGFloat = 4
    static let barTop: CGFloat = 8          // header line → bar
    static let detailTop: CGFloat = 6       // bar → caption
    static let detailLineH: CGFloat = 15

    // Process table (header + rows share these columns)
    static let procRows = 5
    static let procRowH: CGFloat = 28
    static let procHoverInset: CGFloat = 6  // hover highlight bleeds into the card padding
    static let appIcon: CGFloat = 20
    static let procMenuW: CGFloat = 20
    static let procMemW: CGFloat = 60
    static let procCpuW: CGFloat = 52
    static let procArrowW: CGFloat = 10
    static let procColGap: CGFloat = 6

    // Type scale
    static var title: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    static var subtitle: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var rowTitle: NSFont { .systemFont(ofSize: 13, weight: .medium) }
    static var valueXL: NSFont { rounded(20, .semibold) }
    static var valueL: NSFont { rounded(18, .semibold) }
    static var valueUnit: NSFont { rounded(12, .medium) }
    static var placeholder: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var callout: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var caption: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var captionMono: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    static var captionStrong: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    static var monoSm: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    static var monoSmStrong: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .semibold) }

    /// SF Pro Rounded with tabular digits: numbers don't jitter and read as "gauge" values.
    static func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    // Semantic colors (all dynamic; resolve via `cg(_:in:)` before handing to CALayer)
    static let tintCPU: NSColor = .systemBlue
    static let tintMem: NSColor = .systemGreen
    static let tintGPU: NSColor = .systemPurple
    static let tintDisk: NSColor = .systemIndigo
    static let tintNet: NSColor = .systemTeal
    static let tintTemp: NSColor = .systemOrange
    static let tintFan: NSColor = .systemCyan
    static let memApp: NSColor = .systemGreen
    static let memWired: NSColor = .systemBlue
    static let memCompressed: NSColor = .systemPink
    static let netDown: NSColor = .systemBlue
    static let netUp: NSColor = .systemOrange
    static let warn: NSColor = .systemOrange
    static let critical: NSColor = .systemRed
    static var track: NSColor { NSColor.labelColor.withAlphaComponent(0.09) }
    static var cardFill: NSColor { NSColor.labelColor.withAlphaComponent(0.05) }
    static var cardStroke: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
    static var hover: NSColor { NSColor.labelColor.withAlphaComponent(0.07) }
    static var hairline: NSColor { NSColor.separatorColor.withAlphaComponent(0.6) }
}

/// Warn/critical thresholds shared by bars, tiles and the menubar.
enum LoadLevel: Equatable {
    case normal, warn, critical
    static func of(_ v: Double, warn: Double, critical: Double) -> LoadLevel {
        v >= critical ? .critical : (v >= warn ? .warn : .normal)
    }
    func color(tint: NSColor) -> NSColor {
        switch self { case .normal: return tint; case .warn: return HIG.warn; case .critical: return HIG.critical }
    }
}

/// Resolve a dynamic NSColor against a view's appearance (CALayer only takes CGColor).
func cg(_ color: NSColor, in view: NSView) -> CGColor {
    var out = color.cgColor
    view.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
    return out
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .medium) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
}

// MARK: - Motion
/// Bar/segment transitions. Honors System Settings › Accessibility › Display › Reduce motion.
enum Motion {
    static let duration: CFTimeInterval = 0.35
    private static var observer: NSObjectProtocol?
    private static var cachedReduce: Bool?
    static var reduce: Bool {
        if let r = cachedReduce { return r }
        let r = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        cachedReduce = r
        if observer == nil {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
            ) { _ in cachedReduce = nil }
        }
        return r
    }
    /// Run layer mutations with an ease-out animation, or none at all.
    static func layers(animated: Bool, _ body: () -> Void) {
        CATransaction.begin()
        if animated && !reduce {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        body()
        CATransaction.commit()
    }
}

// MARK: - Labels
func makeLabel(_ s: String = "", font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = font
    t.textColor = color
    t.drawsBackground = false
    t.isBordered = false
    t.lineBreakMode = .byTruncatingTail
    t.translatesAutoresizingMaskIntoConstraints = false
    return t
}

extension NSTextField {
    /// Assign only when the text actually changes — avoids invalidating layout/redraw
    /// on every sampling tick when the value is stable.
    func setText(_ s: String) { if stringValue != s { stringValue = s } }
}

/// Label for mixed-style text (value + unit, legends). `key` is the plain content, so the
/// attributed string is only rebuilt and assigned when something visible changed.
final class RichLabel: NSTextField {
    private var key: String?
    static func make(alignment: NSTextAlignment = .natural) -> RichLabel {
        let t = RichLabel(labelWithString: "")
        t.drawsBackground = false
        t.isBordered = false
        t.alignment = alignment
        t.lineBreakMode = .byTruncatingTail
        t.translatesAutoresizingMaskIntoConstraints = false
        return t
    }
    func set(key: String, _ build: () -> NSAttributedString) {
        if key == self.key { return }
        self.key = key
        let a = NSMutableAttributedString(attributedString: build())
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        p.lineBreakMode = lineBreakMode
        a.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: a.length))
        attributedStringValue = a
    }
    /// Big rounded number + small secondary unit ("14 %", "1001 RPM"), or a muted placeholder.
    func setNumber(_ number: String, unit: String, color: NSColor = .labelColor,
                  numberFont: NSFont = HIG.valueXL, placeholder: Bool = false) {
        set(key: "\(number)|\(unit)|\(color)|\(placeholder)|\(numberFont.pointSize)") {
            if placeholder {
                return NSAttributedString(string: number, attributes: [.font: HIG.placeholder, .foregroundColor: NSColor.secondaryLabelColor])
            }
            let s = NSMutableAttributedString(string: number, attributes: [.font: numberFont, .foregroundColor: color])
            if !unit.isEmpty {
                s.append(NSAttributedString(string: "\u{2009}" + unit, attributes: [
                    .font: HIG.valueUnit, .foregroundColor: NSColor.secondaryLabelColor
                ]))
            }
            return s
        }
    }
}

/// Builds "● 应用 13.0 GB  ● 联动 2.7 GB" style legends for captions.
struct Caption {
    private let s = NSMutableAttributedString()
    init() {}
    func dot(_ color: NSColor) -> Caption {
        s.append(NSAttributedString(string: "●\u{2009}", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: color, .baselineOffset: 1]))
        return self
    }
    func text(_ t: String, _ color: NSColor = .secondaryLabelColor, font: NSFont = HIG.caption) -> Caption {
        s.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color]))
        return self
    }
    func value(_ t: String) -> Caption { text(t, .labelColor, font: HIG.captionMono) }
    func gap() -> Caption { text("   ") }
    var string: NSAttributedString { s }
}

// MARK: - Surfaces
final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Control Center-style module: soft fill, hairline stroke, continuous corners.
final class CardView: NSView {
    let stack = NSStackView()
    init(_ views: [NSView], spacing: CGFloat = HIG.rowGap, padding: CGFloat = HIG.cardPad) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HIG.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        views.forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(HIG.cardFill, in: self)
        layer?.borderColor = cg(HIG.cardStroke, in: self)
    }
}

final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = cg(HIG.hairline, in: self) }
}

/// Rounded-square glyph tile tinted per metric — the main hierarchy cue in each row.
final class IconTile: NSView {
    private let glyph = NSImageView()
    var tint: NSColor { didSet { needsDisplay = true; glyph.contentTintColor = tint } }
    init(symbol name: String, tint: NSColor, size: CGFloat = HIG.tileSize, glyphSize: CGFloat = HIG.tileGlyph) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HIG.tileRadius * size / HIG.tileSize
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = symbol(name, size: glyphSize, weight: .semibold)
        glyph.contentTintColor = tint
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = cg(tint.withAlphaComponent(0.18), in: self) }
}

/// Capsule status pill (header thermal state): tinted dot + label on a tinted fill.
final class StatusPill: NSView {
    let textLabel = makeLabel("", font: HIG.captionStrong, color: .secondaryLabelColor)
    private let dot = NSView()
    private var color: NSColor = .systemGreen
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot); addSubview(textLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            textLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, color: NSColor) {
        textLabel.setText(text)
        isHidden = text.isEmpty
        if color != self.color { self.color = color; needsDisplay = true }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(color.withAlphaComponent(0.16), in: self)
        dot.layer?.backgroundColor = cg(color, in: self)
    }
}
