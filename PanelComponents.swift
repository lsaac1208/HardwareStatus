import Cocoa
import QuartzCore

// MARK: - Bars
/// Capsule meter: soft track, gradient fill in the metric tint, orange/red past thresholds.
/// Width and color changes animate (ease-out) unless Reduce Motion is on.
final class ProgressTrack: NSView {
    private let fill = CAGradientLayer()
    private var frac: CGFloat = -1
    private var level: LoadLevel = .normal
    private var laidOutWidth: CGFloat = 0
    var tint: NSColor { didSet { applyFillColor(animated: false) } }

    init(tint: NSColor = .controlAccentColor, height: CGFloat = HIG.barH) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true
        fill.cornerRadius = height / 2
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: Double, warnAt: Double = 75, criticalAt: Double = 90) {
        let newFrac = CGFloat(min(1, max(0, value / 100)))
        let newLevel = LoadLevel.of(value, warn: warnAt, critical: criticalAt)
        if newFrac == frac && newLevel == level { return }
        let first = frac < 0
        if newLevel != level || first { level = newLevel; applyFillColor(animated: !first) }
        frac = newFrac
        needsLayout = true
    }
    private func applyFillColor(animated: Bool) {
        let c = level.color(tint: tint)
        Motion.layers(animated: animated) {
            fill.colors = [cg(c.withAlphaComponent(0.72), in: self), cg(c, in: self)]
        }
    }
    override func layout() {
        super.layout()
        // First layout / popover resize: jump; value change: glide
        let animated = laidOutWidth == bounds.width && frac >= 0
        laidOutWidth = bounds.width
        Motion.layers(animated: animated) {
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * max(0, frac), height: bounds.height)
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(HIG.track, in: self)
        applyFillColor(animated: false)  // set() skips unchanged values, so re-resolve dynamic color here
    }
}

/// Stacked capsule (memory breakdown) with 1.5-pt gaps between non-empty segments.
final class SegmentBar: NSView {
    private var parts: [(CGFloat, NSColor)] = []
    private var segLayers: [CALayer] = []
    private var laidOutWidth: CGFloat = 0
    init(height: CGFloat = HIG.barH) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(parts items: [(Double, NSColor)], total: Double) {
        let t = max(total, 1)
        var mapped = items.map { (CGFloat(min(1, max(0, $0.0 / t))), $0.1) }
        let sum = mapped.reduce(CGFloat(0)) { $0 + $1.0 }
        if sum > 1 { mapped = mapped.map { ($0.0 / sum, $0.1) } }
        // Skip relayout when fractions moved less than half a point on a ~300 pt bar
        if mapped.count == parts.count,
           zip(mapped, parts).allSatisfy({ abs($0.0 - $1.0) < 0.0015 && $0.1 == $1.1 }) { return }
        let colorsChanged = mapped.count != parts.count || zip(mapped, parts).contains { $0.1 != $1.1 }
        parts = mapped
        while segLayers.count < parts.count { let l = CALayer(); layer?.addSublayer(l); segLayers.append(l) }
        if colorsChanged { applyColors() }
        needsLayout = true
    }
    private func applyColors() {
        Motion.layers(animated: false) {
            for (i, l) in segLayers.enumerated() {
                l.isHidden = i >= parts.count
                if i < parts.count { l.backgroundColor = cg(parts[i].1, in: self) }
            }
        }
    }
    override func layout() {
        super.layout()
        let animated = laidOutWidth == bounds.width
        laidOutWidth = bounds.width
        let gap: CGFloat = 1.5
        let visible = parts.indices.filter { parts[$0].0 * bounds.width >= 0.5 }
        Motion.layers(animated: animated) {
            var x: CGFloat = 0
            for (i, part) in parts.enumerated() {
                let w = bounds.width * part.0
                // The gap is carved out of the segment, so the total still maps to `total`
                let trailingGap: CGFloat = (visible.contains(i) && i != visible.last) ? gap : 0
                segLayers[i].frame = CGRect(x: x, y: 0, width: max(0, w - trailingGap), height: bounds.height)
                x += w
            }
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(HIG.track, in: self)
        applyColors()
    }
}

// MARK: - Primary metric row (CPU / 内存 / GPU)
/// [tile] Title ……………… 14 %  ⌄
///        [=========bar==========]
///        caption / legend
/// The whole row toggles detail when expandable, not just the chevron.
final class MetricRow: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.rowTitle)
    let valueLabel = RichLabel.make(alignment: .right)
    let detailLabel = RichLabel.make()
    let expandBtn = NSButton()
    let track: ProgressTrack
    let segments = SegmentBar()
    var usesSegments = false {
        didSet { if usesSegments != oldValue { track.isHidden = usesSegments; segments.isHidden = !usesSegments } }
    }
    private(set) var detailExpanded = false
    private(set) var detailEnabled = false
    /// Caption visible when collapsed (CPU / 内存 summary, GPU temperature).
    var alwaysShowDetail = false { didSet { if alwaysShowDetail != oldValue { setExpanded(detailExpanded) } } }
    var onToggleDetail: (() -> Void)?
    /// Called when the row's height changes so the panel can refit.
    var onHeightChange: (() -> Void)?
    private var detailH: NSLayoutConstraint!

    init(symbol: String, title: String, tint: NSColor) {
        tile = IconTile(symbol: symbol, tint: tint)
        track = ProgressTrack(tint: tint)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        segments.isHidden = true
        expandBtn.isBordered = false
        expandBtn.imagePosition = .imageOnly
        expandBtn.translatesAutoresizingMaskIntoConstraints = false
        expandBtn.contentTintColor = .tertiaryLabelColor
        expandBtn.target = self
        expandBtn.action = #selector(toggle)
        expandBtn.isHidden = true
        expandBtn.setAccessibilityLabel("详情")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = HIG.caption
        updateChevron()
        [tile, titleLabel, valueLabel, expandBtn, detailLabel, track, segments].forEach(addSubview)
        detailH = detailLabel.heightAnchor.constraint(equalToConstant: HIG.detailLineH)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HIG.titleGap),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            expandBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            expandBtn.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            expandBtn.widthAnchor.constraint(equalToConstant: 16),
            expandBtn.heightAnchor.constraint(equalToConstant: 16),
            valueLabel.trailingAnchor.constraint(equalTo: expandBtn.leadingAnchor, constant: -4),
            valueLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: HIG.barTop),
            track.heightAnchor.constraint(equalToConstant: HIG.barH),
            segments.heightAnchor.constraint(equalTo: track.heightAnchor),
            segments.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            segments.topAnchor.constraint(equalTo: track.topAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: HIG.detailTop),
            detailH,
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func enableDetail(_ on: Bool) { detailEnabled = on; expandBtn.isHidden = !on }
    func setExpanded(_ on: Bool) {
        detailExpanded = on
        updateChevron()
        detailLabel.maximumNumberOfLines = on ? 2 : 1
        detailLabel.lineBreakMode = on ? .byWordWrapping : .byTruncatingTail
        let h: CGFloat
        if alwaysShowDetail || on { h = on ? HIG.detailLineH * 2 : HIG.detailLineH } else { h = 0 }
        detailLabel.isHidden = h == 0
        if detailH.constant != h { detailH.constant = h; onHeightChange?() }
    }
    /// Value in the big rounded face; `level` tints it on warn/critical.
    func setReading(_ number: String, unit: String = "%", level: LoadLevel = .normal) {
        valueLabel.setNumber(number, unit: unit, color: level == .normal ? .labelColor : level.color(tint: tile.tint))
    }
    func setPlaceholder(_ text: String) { valueLabel.setNumber(text, unit: "", placeholder: true) }
    func setDetail(_ text: String) {
        detailLabel.set(key: text) {
            NSAttributedString(string: text, attributes: [.font: HIG.caption, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
    private func updateChevron() {
        expandBtn.image = symbol(detailExpanded ? "chevron.up" : "chevron.down", size: 9, weight: .semibold)
        expandBtn.setAccessibilityValue(detailExpanded ? "已展开" : "已收起")
    }
    @objc private func toggle() {
        setExpanded(!detailExpanded)
        onToggleDetail?()
    }
    // Clicking anywhere on the row expands it (labels forward mouse events to us; the
    // chevron button handles its own click).
    override func mouseDown(with event: NSEvent) { if !detailEnabled { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        guard detailEnabled else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }
}

// MARK: - Stat tile (温度 / 风扇)
final class StatTile: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.caption, color: .secondaryLabelColor)
    let valueLabel = RichLabel.make()
    private let card: CardView
    init(symbol: String, title: String, tint: NSColor) {
        tile = IconTile(symbol: symbol, tint: tint, size: HIG.tileSizeSmall, glyphSize: 10)
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        card = CardView([body], padding: HIG.cardPad)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        [tile, titleLabel, valueLabel].forEach(body.addSubview)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -HIG.cardPad * 2),
            tile.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tile.topAnchor.constraint(equalTo: body.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 8),
            valueLabel.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setReading(_ value: String, unit: String, level: LoadLevel = .normal) {
        valueLabel.setNumber(value, unit: unit, color: level == .normal ? .labelColor : level.color(tint: tile.tint),
                            numberFont: HIG.valueL)
    }
    func setPlaceholder(_ text: String) { valueLabel.setNumber(text, unit: "", placeholder: true) }
}

// MARK: - IO row (存储 / 网络)
final class IORow: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.rowTitle)
    let valueLabel = RichLabel.make(alignment: .right)
    let track: ProgressTrack
    var showsTrack = true {
        didSet { track.isHidden = !showsTrack; trackTop.constant = showsTrack ? HIG.barTop : 0; trackH.constant = showsTrack ? HIG.barHSmall : 0 }
    }
    private var trackTop: NSLayoutConstraint!
    private var trackH: NSLayoutConstraint!
    init(symbol: String, title: String, tint: NSColor) {
        tile = IconTile(symbol: symbol, tint: tint)
        track = ProgressTrack(tint: tint, height: HIG.barHSmall)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        [tile, titleLabel, valueLabel, track].forEach(addSubview)
        trackH = track.heightAnchor.constraint(equalToConstant: HIG.barHSmall)
        trackTop = track.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: HIG.barTop)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HIG.titleGap),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackTop, trackH,
            track.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    /// "28%  128 GB / 460 GB": emphasised percent, muted capacity.
    func setUsage(percent: Int, detail: String) {
        valueLabel.set(key: "\(percent)|\(detail)") {
            Caption().text("\(percent)%", .labelColor, font: HIG.monoSmStrong)
                .text("  " + detail, .secondaryLabelColor, font: HIG.monoSm).string
        }
    }
    /// "↓ 53.1 KB/s   ↑ 697.3 KB/s" with tinted arrows.
    func setRates(down: String, up: String) {
        valueLabel.set(key: "\(down)|\(up)") {
            Caption().text("↓ ", HIG.netDown, font: HIG.monoSmStrong).text(down, .labelColor, font: HIG.monoSm)
                .text("    ↑ ", HIG.netUp, font: HIG.monoSmStrong).text(up, .labelColor, font: HIG.monoSm).string
        }
    }
    func setMessage(_ text: String) {
        valueLabel.set(key: "msg|" + text) {
            NSAttributedString(string: text, attributes: [.font: HIG.callout, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

// MARK: - Process table
final class AppProcRow: NSView {
    let iconView = NSImageView()
    let nameLabel = makeLabel("", font: HIG.body)
    let cpuLabel = makeLabel("", font: HIG.monoSm, color: .secondaryLabelColor)
    let memLabel = makeLabel("", font: HIG.monoSm, color: .secondaryLabelColor)
    let menuBtn = NSButton()
    var onMenu: (() -> Void)?
    var pid: Int32 = 0
    private var iconKey: String?
    private let hoverLayer = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { applyHover() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hoverLayer.cornerRadius = 7
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        menuBtn.image = symbol("ellipsis.circle", size: 13, weight: .regular)
        menuBtn.setAccessibilityLabel("操作")
        menuBtn.isBordered = false
        menuBtn.imagePosition = .imageOnly
        menuBtn.target = self
        menuBtn.action = #selector(tap)
        menuBtn.translatesAutoresizingMaskIntoConstraints = false
        menuBtn.contentTintColor = .tertiaryLabelColor
        menuBtn.alphaValue = 0.55
        cpuLabel.alignment = .right
        memLabel.alignment = .right
        [iconView, nameLabel, cpuLabel, memLabel, menuBtn].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HIG.procRowH),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: HIG.appIcon),
            iconView.heightAnchor.constraint(equalToConstant: HIG.appIcon),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: HIG.titleGap),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: HIG.procMenuW),
            menuBtn.heightAnchor.constraint(equalToConstant: HIG.procMenuW),
            // mem / cpu share exact columns with SortHeader (arrow slot reserved between them)
            memLabel.trailingAnchor.constraint(equalTo: menuBtn.leadingAnchor, constant: -2),
            memLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memLabel.widthAnchor.constraint(equalToConstant: HIG.procMemW),
            cpuLabel.trailingAnchor.constraint(equalTo: memLabel.leadingAnchor, constant: -(HIG.procColGap + HIG.procArrowW)),
            cpuLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            cpuLabel.widthAnchor.constraint(equalToConstant: HIG.procCpuW),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cpuLabel.leadingAnchor, constant: -6)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tap() { onMenu?() }

    /// Emphasise whichever column the table is sorted by.
    func setSortedByCPU(_ byCPU: Bool) {
        let on = NSColor.labelColor, off = NSColor.secondaryLabelColor
        if cpuLabel.textColor != (byCPU ? on : off) { cpuLabel.textColor = byCPU ? on : off }
        if memLabel.textColor != (byCPU ? off : on) { memLabel.textColor = byCPU ? off : on }
    }

    /// `key` identifies the icon source; the copy/resize is skipped when it is unchanged.
    func setIcon(_ image: NSImage?, key: String) {
        if key == iconKey { return }
        iconKey = key
        if let image, !image.isTemplate {
            // App icons already carry the macOS squircle; just size them
            let copy = image.copy() as! NSImage
            copy.size = NSSize(width: HIG.appIcon, height: HIG.appIcon)
            iconView.image = copy
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = nil
        } else {
            // Symbol fallback (daemons / CLI tools): a glyph at icon-tile size, not a stretched template
            let isSystem = key.hasPrefix("/System") || key.hasPrefix("/usr") || key.hasPrefix("/bin") || key.hasPrefix("/sbin")
            iconView.image = symbol(isSystem ? "gearshape.2.fill" : "app.dashed", size: 14, weight: .regular)
            iconView.imageScaling = .scaleNone
            iconView.contentTintColor = .tertiaryLabelColor
        }
    }

    // Hover: soft highlight + reveal the actions button (cheap: one tracking area per row)
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// A transient popover can close under the pointer without a mouseExited.
    func resetHover() { hovering = false }
    override var isHidden: Bool { didSet { if isHidden { hovering = false } } }
    override func layout() {
        super.layout()
        Motion.layers(animated: false) {
            hoverLayer.frame = bounds.insetBy(dx: -HIG.procHoverInset, dy: 0)
        }
    }
    private func applyHover() {
        Motion.layers(animated: true) { hoverLayer.opacity = hovering ? 1 : 0 }
        menuBtn.alphaValue = hovering ? 1 : 0.55
        menuBtn.contentTintColor = hovering ? .secondaryLabelColor : .tertiaryLabelColor
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { hoverLayer.backgroundColor = cg(HIG.hover, in: self) }
}

final class SortHeader: NSView {
    let titleLabel = makeLabel("占用最高", font: HIG.captionStrong, color: .secondaryLabelColor)
    let cpuBtn = NSButton()
    let memBtn = NSButton()
    let arrowView = NSImageView()
    var sortByCPU = true { didSet { refreshTitles() } }
    var onSortCPU: (() -> Void)?
    var onSortMem: (() -> Void)?
    private var arrowToCpu: NSLayoutConstraint!
    private var arrowToMem: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        for b in [cpuBtn, memBtn] {
            b.isBordered = false
            b.translatesAutoresizingMaskIntoConstraints = false
            b.alignment = .right
        }
        cpuBtn.target = self; cpuBtn.action = #selector(tapCPU)
        memBtn.target = self; memBtn.action = #selector(tapMem)
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = symbol("chevron.down", size: 8, weight: .bold)
        arrowView.contentTintColor = .labelColor
        [titleLabel, cpuBtn, arrowView, memBtn].forEach(addSubview)
        // Align with AppProcRow: menuW + memW + gap+arrow + cpuW from trailing
        let menuPad = HIG.procMenuW + 2
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -menuPad),
            memBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            memBtn.widthAnchor.constraint(equalToConstant: HIG.procMemW),
            cpuBtn.trailingAnchor.constraint(equalTo: memBtn.leadingAnchor, constant: -(HIG.procColGap + HIG.procArrowW)),
            cpuBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            cpuBtn.widthAnchor.constraint(equalToConstant: HIG.procCpuW),
            arrowView.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowView.widthAnchor.constraint(equalToConstant: HIG.procArrowW)
        ])
        // Arrow lives in the reserved slot right of the active column
        arrowToCpu = arrowView.leadingAnchor.constraint(equalTo: cpuBtn.trailingAnchor, constant: 2)
        arrowToMem = arrowView.leadingAnchor.constraint(equalTo: memBtn.trailingAnchor, constant: 2)
        refreshTitles()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshTitles() {
        func title(_ s: String, active: Bool) -> NSAttributedString {
            let p = NSMutableParagraphStyle(); p.alignment = .right
            return NSAttributedString(string: s, attributes: [
                .font: active ? HIG.captionStrong : HIG.caption,
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: p
            ])
        }
        cpuBtn.attributedTitle = title("CPU", active: sortByCPU)
        memBtn.attributedTitle = title("内存", active: !sortByCPU)
        cpuBtn.setAccessibilityValue(sortByCPU ? "已排序" : nil)
        memBtn.setAccessibilityValue(sortByCPU ? nil : "已排序")
        arrowToCpu.isActive = false
        arrowToMem.isActive = false
        (sortByCPU ? arrowToCpu : arrowToMem).isActive = true
    }
    @objc private func tapCPU() { onSortCPU?() }
    @objc private func tapMem() { onSortMem?() }
}

/// Plain footer action: SF Symbol / app icon + label, label brightens on hover.
final class FooterButton: NSButton {
    convenience init(title: String, image: NSImage?) {
        self.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = image == nil ? .noImage : .imageLeading
        imageHugsTitle = true
        isBordered = false
        bezelStyle = .inline
        font = HIG.callout
        contentTintColor = .secondaryLabelColor
        translatesAutoresizingMaskIntoConstraints = false
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = .labelColor }
    override func mouseExited(with event: NSEvent) { contentTintColor = .secondaryLabelColor }
}
