import Cocoa
import QuartzCore

// MARK: - Design tokens
/// Single source of truth for the panel. Spacing sits on a strict 4-pt grid (4/8/12/16);
/// type maps onto the macOS text styles Control Center uses (title3 15, body 13, callout 12,
/// caption 11). Fonts are cached once as static constants.
enum HIG {
    // Panel geometry
    static let panelW: CGFloat = 368
    static let panelH: CGFloat = 620
    static let panelMinH: CGFloat = 360
    static let panelMaxH: CGFloat = 860
    static let outerX: CGFloat = 12
    static let outerTop: CGFloat = 16
    static let outerBottom: CGFloat = 12
    static let headerInset: CGFloat = 4
    static let cardGap: CGFloat = 8
    static let cardPad: CGFloat = 12
    static let cardRadius: CGFloat = 14
    static let footerH: CGFloat = 44
    static let headerGap: CGFloat = 12
    static let contentW: CGFloat = panelW - outerX * 2
    static let cardInnerW: CGFloat = contentW - cardPad * 2

    // Rows
    static let rowGap: CGFloat = 12
    static let tileSize: CGFloat = 24
    static let tileSizeSmall: CGFloat = 20
    static let tileRadius: CGFloat = 6
    static let tileGlyph: CGFloat = 12
    static let titleGap: CGFloat = 10
    static let rowSeparatorInset: CGFloat = tileSize + titleGap
    static let barH: CGFloat = 4
    static let barHSmall: CGFloat = 3
    static let barTop: CGFloat = 8
    static let detailTop: CGFloat = 4
    static let detailLineH: CGFloat = 16

    // Process table (header + rows share these columns)
    static let procRows = 5
    static let procRowH: CGFloat = 28
    static let procHoverInset: CGFloat = 6
    static let appIcon: CGFloat = 20
    static let procMenuW: CGFloat = 20
    static let procMemW: CGFloat = 60
    static let procCpuW: CGFloat = 52
    static let procArrowW: CGFloat = 10
    static let procColGap: CGFloat = 6
    static let procMenuIdleAlpha: CGFloat = 0.0

    // Cached type scale (resolved once instead of every render)
    static let title: NSFont = .systemFont(ofSize: 15, weight: .semibold)
    static let subtitle: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let rowTitle: NSFont = .systemFont(ofSize: 13, weight: .medium)
    static let valueXL: NSFont = rounded(24, .semibold)
    static let valueL: NSFont = rounded(22, .semibold)
    static let valueUnit: NSFont = rounded(11, .medium)
    static let placeholder: NSFont = .systemFont(ofSize: 12, weight: .regular)
    static let body: NSFont = .systemFont(ofSize: 13, weight: .regular)
    static let callout: NSFont = .systemFont(ofSize: 12, weight: .regular)
    static let caption: NSFont = .systemFont(ofSize: 11, weight: .regular)
    static let captionMono: NSFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let captionStrong: NSFont = .systemFont(ofSize: 11, weight: .medium)
    static let monoSm: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let monoSmStrong: NSFont = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let dotFont: NSFont = .systemFont(ofSize: 8)

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
    static let memSwap: NSColor = .systemOrange
    static let cpuSuper: NSColor = .systemIndigo
    static let cpuPerf: NSColor = .systemBlue
    static let cpuEff: NSColor = .systemTeal
    static let netDown: NSColor = .systemBlue
    static let netUp: NSColor = .systemOrange
    static let warn: NSColor = .systemOrange
    static let critical: NSColor = .systemRed

    static let track = Ink.dynamic(dark: 0.13, light: 0.09)
    static let cardFill = Ink.dynamic(dark: 0.075, light: 0.042)
    static let cardStroke = Ink.dynamic(dark: 0.14, light: 0.095)
    static let hover: NSColor = NSColor.labelColor.withAlphaComponent(0.06)
    static let hairline = Ink.dynamic(dark: 0.14, light: 0.09)
    static let mutedInk = Ink.dynamic(dark: 0.76, light: 0.58)
    static let faintInk = Ink.dynamic(dark: 0.55, light: 0.38)
    static let tileFillAlpha: CGFloat = 0.14
    static let barFillStartAlpha: CGFloat = 0.85
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

/// Solid white/black ink at a fixed opacity per appearance.
enum Ink {
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static func dynamic(dark: CGFloat, light: CGFloat) -> NSColor {
        NSColor(name: nil) { isDark($0) ? NSColor(white: 1, alpha: dark) : NSColor(white: 0, alpha: light) }
    }
}

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
    static func layers(animated: Bool, duration: CFTimeInterval = Motion.duration, _ body: () -> Void) {
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

// MARK: - Typography helpers
func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor, alignment: NSTextAlignment = .left) -> NSTextField {
    let tf = NSTextField(labelWithString: text)
    tf.font = font
    tf.textColor = color
    tf.alignment = alignment
    tf.lineBreakMode = .byTruncatingTail
    tf.maximumNumberOfLines = 1
    tf.translatesAutoresizingMaskIntoConstraints = false
    return tf
}

extension NSTextField {
    func setText(_ s: String) { if stringValue != s { stringValue = s } }
}

final class RichLabel: NSTextField {
    private var lastKey: String?
    static func make(alignment: NSTextAlignment = .left) -> RichLabel {
        let tf = RichLabel(labelWithString: "")
        tf.alignment = alignment
        tf.lineBreakMode = .byTruncatingTail
        tf.maximumNumberOfLines = 1
        tf.translatesAutoresizingMaskIntoConstraints = false
        return tf
    }
    func set(key: String, build: () -> NSAttributedString) {
        if lastKey == key { return }
        lastKey = key
        attributedStringValue = build()
    }
    func setNumber(_ number: String, unit: String, color: NSColor = .labelColor,
                   numberFont: NSFont = HIG.valueXL, placeholder: Bool = false) {
        let key = "\(number)|\(unit)|\(color.description)|\(numberFont.pointSize)|\(placeholder)"
        set(key: key) {
            if placeholder {
                return NSAttributedString(string: number, attributes: [.font: HIG.placeholder, .foregroundColor: HIG.mutedInk])
            }
            let out = NSMutableAttributedString(string: number, attributes: [.font: numberFont, .foregroundColor: color])
            if !unit.isEmpty {
                out.append(NSAttributedString(string: "\u{2009}" + unit, attributes: [.font: HIG.valueUnit, .foregroundColor: HIG.mutedInk]))
            }
            return out
        }
    }
}

final class Caption {
    private let s = NSMutableAttributedString()
    func dot(_ color: NSColor) -> Caption {
        s.append(NSAttributedString(string: "●\u{2009}", attributes: [.font: HIG.dotFont, .foregroundColor: color, .baselineOffset: 1]))
        return self
    }
    func text(_ t: String, _ color: NSColor = HIG.mutedInk, font: NSFont = HIG.caption) -> Caption {
        s.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: color]))
        return self
    }
    func value(_ t: String) -> Caption { text(t.replacingOccurrences(of: " ", with: "\u{00A0}"), .labelColor, font: HIG.captionMono) }
    func gap() -> Caption { text("   ") }
    var string: NSAttributedString { s }
}

// MARK: - Surfaces
final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class CardView: NSView {
    let stack = NSStackView()
    private var glassOverlay: NSView?

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

        if #available(macOS 26.0, *) {
            layer?.borderWidth = 0
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = HIG.cardRadius
            glass.translatesAutoresizingMaskIntoConstraints = false
            let inner = NSView()
            inner.translatesAutoresizingMaskIntoConstraints = false
            inner.addSubview(stack)
            glass.contentView = inner
            addSubview(glass)
            glassOverlay = glass
            NSLayoutConstraint.activate([
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
                stack.topAnchor.constraint(equalTo: inner.topAnchor, constant: padding),
                stack.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: padding),
                stack.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -padding),
                stack.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -padding)
            ])
        } else {
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if #available(macOS 26.0, *), let glass = glassOverlay as? NSGlassEffectView {
            let dark = Ink.isDark(effectiveAppearance)
            glass.tintColor = dark
                ? NSColor(white: 1.0, alpha: 0.045)
                : NSColor(white: 1.0, alpha: 0.34)
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = nil
        } else {
            layer?.backgroundColor = cg(HIG.cardFill, in: self)
            layer?.borderColor = cg(HIG.cardStroke, in: self)
        }
    }
}

/// Wraps a vertical stack of `CardView`s inside `NSGlassEffectContainerView` on macOS 26+
/// so sibling glass surfaces batch into a single GPU pass.
final class GlassStackHost: NSView {
    init(content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 0
            container.translatesAutoresizingMaskIntoConstraints = false
            container.contentView = content
            addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: topAnchor),
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class Hairline: NSView {
    private let line = CALayer()
    var inset: CGFloat = 0 { didSet { needsLayout = true } }
    convenience init(inset: CGFloat) { self.init(frame: .zero); self.inset = inset }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(line)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 0.5).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        Motion.layers(animated: false) {
            line.frame = CGRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: bounds.height)
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { line.backgroundColor = cg(HIG.hairline, in: self) }
}

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
    override func updateLayer() { layer?.backgroundColor = cg(tint.withAlphaComponent(HIG.tileFillAlpha), in: self) }
}

final class StatusPill: NSView {
    let textLabel = makeLabel("", font: HIG.captionStrong, color: .labelColor)
    private var pips: [CALayer] = []
    private var color: NSColor = .systemGreen
    private var step = 1
    private var configured = false
    private static let pipW: CGFloat = 2.5
    private static let pipGap: CGFloat = 1.5
    private static let pipHeights: [CGFloat] = [4, 6, 8, 10]
    private static let pipOff = Ink.dynamic(dark: 0.3, light: 0.18)
    private let ladder = NSView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        translatesAutoresizingMaskIntoConstraints = false
        ladder.wantsLayer = true
        ladder.translatesAutoresizingMaskIntoConstraints = false
        for h in Self.pipHeights {
            let l = CALayer()
            l.cornerRadius = Self.pipW / 2
            l.frame = CGRect(x: 0, y: 0, width: Self.pipW, height: h)
            ladder.layer?.addSublayer(l)
            pips.append(l)
        }
        addSubview(ladder); addSubview(textLabel)
        let ladderW = Self.pipW * 4 + Self.pipGap * 3
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            ladder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            ladder.centerYAnchor.constraint(equalTo: centerYAnchor),
            ladder.widthAnchor.constraint(equalToConstant: ladderW),
            ladder.heightAnchor.constraint(equalToConstant: 10),
            textLabel.leadingAnchor.constraint(equalTo: ladder.trailingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            textLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, color: NSColor, step: Int) {
        textLabel.setText(text)
        isHidden = text.isEmpty
        setAccessibilityLabel(text)
        let step = min(4, max(1, step))
        if color != self.color || step != self.step || !configured {
            let animated = configured
            configured = true
            self.color = color; self.step = step
            applyPips(animated: animated)
            needsDisplay = true
        }
    }
    override func layout() {
        super.layout()
        Motion.layers(animated: false) {
            for (i, l) in pips.enumerated() {
                l.frame.origin = CGPoint(x: CGFloat(i) * (Self.pipW + Self.pipGap), y: 0)
            }
        }
    }
    private func applyPips(animated: Bool) {
        let on = cg(color, in: self)
        let off = cg(Self.pipOff, in: self)
        Motion.layers(animated: animated) {
            for (i, l) in pips.enumerated() { l.backgroundColor = i < step ? on : off }
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(color.withAlphaComponent(0.12), in: self)
        layer?.borderColor = cg(color.withAlphaComponent(0.28), in: self)
        applyPips(animated: false)
    }
}
