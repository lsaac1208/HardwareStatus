import Cocoa
import QuartzCore

// MARK: - Bars
final class ProgressTrack: NSView {
    private let fill = CAGradientLayer()
    private let baseTint: NSColor
    private var activeTint: NSColor
    private var fraction: CGFloat = 0
    private var laidOutWidth: CGFloat = -1

    init(tint: NSColor, height: CGFloat = HIG.barH) {
        self.baseTint = tint
        self.activeTint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true
        fill.startPoint = CGPoint(x: 0, y: 0.5)
        fill.endPoint = CGPoint(x: 1, y: 0.5)
        fill.cornerRadius = height / 2
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ percent: Double, warnAt: Double = 75, criticalAt: Double = 90) {
        let p = max(0, min(100, percent.isFinite ? percent : 0))
        let f = CGFloat(p / 100.0)
        let tint = LoadLevel.of(p, warn: warnAt, critical: criticalAt).color(tint: baseTint)
        if abs(f - fraction) < 0.002 && tint == activeTint { return }
        let colorChanged = tint != activeTint
        fraction = f
        activeTint = tint
        if colorChanged { applyFillColors() }
        needsLayout = true
    }

    private func applyFillColors() {
        let end = cg(activeTint, in: self)
        let start = cg(activeTint.withAlphaComponent(HIG.barFillStartAlpha), in: self)
        Motion.layers(animated: false) { fill.colors = [start, end] }
    }

    override func layout() {
        super.layout()
        let animated = laidOutWidth == bounds.width
        laidOutWidth = bounds.width
        let w = fraction > 0 ? max(bounds.height, bounds.width * fraction) : 0
        Motion.layers(animated: animated) {
            fill.frame = CGRect(x: 0, y: 0, width: min(bounds.width, w), height: bounds.height)
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = cg(HIG.track, in: self)
        applyFillColors()
    }
}

final class SegmentBar: NSView {
    private var segLayers: [CALayer] = []
    private var parts: [(CGFloat, NSColor)] = []
    private var laidOutWidth: CGFloat = -1

    init(height: CGFloat = HIG.barH) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(parts raw: [(Double, NSColor)], total: Double) {
        let denom = max(total, 1)
        let mapped = raw.map { (CGFloat(max(0, min(1, $0.0 / denom))), $0.1) }
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
        let gap: CGFloat = 1
        let visible = parts.indices.filter { parts[$0].0 * bounds.width >= 0.5 }
        Motion.layers(animated: animated) {
            var x: CGFloat = 0
            for (i, part) in parts.enumerated() {
                let w = bounds.width * part.0
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

// MARK: - Lightweight CALayer Sparkline (only drawn while panel is open)
final class SparklineView: NSView {
    private let primaryFill = CAGradientLayer()
    private let primaryMask = CAShapeLayer()
    private let primaryStroke = CAShapeLayer()
    private let secondaryStroke = CAShapeLayer()

    private let primaryTint: NSColor
    private let secondaryTint: NSColor?
    private let fixedMax: Double?
    private let minAutoMax: Double

    private var primaryValues: [Double] = []
    private var secondaryValues: [Double] = []

    init(tint: NSColor, secondaryTint: NSColor? = nil, fixedMax: Double? = 100.0, minAutoMax: Double = 64 * 1024) {
        self.primaryTint = tint
        self.secondaryTint = secondaryTint
        self.fixedMax = fixedMax
        self.minAutoMax = minAutoMax
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        primaryFill.startPoint = CGPoint(x: 0.5, y: 1.0)
        primaryFill.endPoint = CGPoint(x: 0.5, y: 0.0)
        primaryFill.mask = primaryMask
        layer?.addSublayer(primaryFill)

        primaryStroke.fillColor = nil
        primaryStroke.lineWidth = 1.35
        primaryStroke.lineCap = .round
        primaryStroke.lineJoin = .round
        layer?.addSublayer(primaryStroke)

        if secondaryTint != nil {
            secondaryStroke.fillColor = nil
            secondaryStroke.lineWidth = 1.15
            secondaryStroke.lineCap = .round
            secondaryStroke.lineJoin = .round
            layer?.addSublayer(secondaryStroke)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(primary: [Double], secondary: [Double] = []) {
        primaryValues = primary
        secondaryValues = secondary
        rebuildPaths()
    }

    override func layout() {
        super.layout()
        Motion.layers(animated: false) {
            primaryFill.frame = bounds
            primaryMask.frame = bounds
            primaryStroke.frame = bounds
            secondaryStroke.frame = bounds
        }
        rebuildPaths()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let top = cg(primaryTint.withAlphaComponent(0.24), in: self)
        let bot = cg(primaryTint.withAlphaComponent(0.01), in: self)
        Motion.layers(animated: false) {
            primaryFill.colors = [top, bot]
            primaryStroke.strokeColor = cg(primaryTint.withAlphaComponent(0.88), in: self)
            if let st = secondaryTint {
                secondaryStroke.strokeColor = cg(st.withAlphaComponent(0.78), in: self)
            }
        }
    }

    private func rebuildPaths() {
        let w = bounds.width, h = bounds.height
        guard w > 4, h > 4 else { return }
        let padY: CGFloat = 1.5
        let usableH = max(1, h - padY * 2)

        let peak = max(primaryValues.max() ?? 0, secondaryValues.max() ?? 0)
        let maxVal = fixedMax ?? max(minAutoMax, peak * 1.15)

        func buildStroke(for vals: [Double]) -> (CGPath?, CGPath?) {
            guard vals.count >= 2 else { return (nil, nil) }
            let stroke = CGMutablePath()
            let fill = CGMutablePath()
            let stepX = w / CGFloat(vals.count - 1)
            var pts: [CGPoint] = []
            pts.reserveCapacity(vals.count)
            for (i, v) in vals.enumerated() {
                let x = CGFloat(i) * stepX
                let norm = CGFloat(max(0, min(1, v / maxVal)))
                let y = padY + norm * usableH
                pts.append(CGPoint(x: x, y: y))
            }
            stroke.move(to: pts[0])
            fill.move(to: CGPoint(x: pts[0].x, y: 0))
            fill.addLine(to: pts[0])
            for i in 1..<pts.count {
                let prev = pts[i - 1], cur = pts[i]
                let midX = (prev.x + cur.x) * 0.5
                let c1 = CGPoint(x: midX, y: prev.y)
                let c2 = CGPoint(x: midX, y: cur.y)
                stroke.addCurve(to: cur, control1: c1, control2: c2)
                fill.addCurve(to: cur, control1: c1, control2: c2)
            }
            fill.addLine(to: CGPoint(x: pts.last!.x, y: 0))
            fill.closeSubpath()
            return (stroke, fill)
        }

        let (pStroke, pFill) = buildStroke(for: primaryValues)
        Motion.layers(animated: false) {
            primaryStroke.path = pStroke
            primaryMask.path = pFill
            if secondaryTint != nil {
                let (sStroke, _) = buildStroke(for: secondaryValues)
                secondaryStroke.path = sStroke
            }
        }
    }
}

// MARK: - Structured Expanded Details (CPU Tiers / Memory 2x2 Grid / GPU Power)

private final class TierMiniBar: NSView {
    private let titleLabel: NSTextField
    private let valueLabel = makeLabel("0%", font: HIG.captionMono, color: .labelColor, alignment: .right)
    private let track: ProgressTrack

    init(title: String, tint: NSColor) {
        titleLabel = makeLabel(title, font: HIG.caption, color: HIG.mutedInk)
        track = ProgressTrack(tint: tint, height: 3)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, valueLabel, track].forEach(addSubview)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            track.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(percent: Double) {
        let v = Formatters.clampPct(percent)
        valueLabel.setText("\(v)%")
        track.set(Double(v))
    }
}

final class CPUTiersDetailView: NSView {
    private let userSysLabel = makeLabel("", font: HIG.caption, color: HIG.mutedInk)
    private let loadLabel = makeLabel("", font: HIG.captionMono, color: HIG.mutedInk, alignment: .right)
    private let tiersStack = NSStackView()
    private let superBar = TierMiniBar(title: "S 核", tint: HIG.cpuSuper)
    private let perfBar = TierMiniBar(title: "P 核", tint: HIG.cpuPerf)
    private let effBar = TierMiniBar(title: "E 核", tint: HIG.cpuEff)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let topRow = NSView()
        topRow.translatesAutoresizingMaskIntoConstraints = false
        [userSysLabel, loadLabel].forEach(topRow.addSubview)
        NSLayoutConstraint.activate([
            userSysLabel.leadingAnchor.constraint(equalTo: topRow.leadingAnchor),
            userSysLabel.topAnchor.constraint(equalTo: topRow.topAnchor),
            userSysLabel.bottomAnchor.constraint(equalTo: topRow.bottomAnchor),
            loadLabel.trailingAnchor.constraint(equalTo: topRow.trailingAnchor),
            loadLabel.centerYAnchor.constraint(equalTo: userSysLabel.centerYAnchor),
            loadLabel.leadingAnchor.constraint(greaterThanOrEqualTo: userSysLabel.trailingAnchor, constant: 8)
        ])

        tiersStack.orientation = .horizontal
        tiersStack.distribution = .fillEqually
        tiersStack.spacing = 10
        tiersStack.translatesAutoresizingMaskIntoConstraints = false
        [superBar, perfBar, effBar].forEach(tiersStack.addArrangedSubview)

        let outer = NSStackView(views: [topRow, tiersStack])
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 6
        outer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            tiersStack.widthAnchor.constraint(equalTo: outer.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(user: Double, sys: Double, load1m: Double, tiers: CPUTiers) {
        userSysLabel.setText(String(format: "用户 %.0f%% · 系统 %.0f%%", user, sys))
        loadLabel.setText(String(format: "1m 负载 %.2f", load1m))
        tiersStack.isHidden = !tiers.valid
        if tiers.valid {
            superBar.isHidden = !tiers.hasSuper
            if tiers.hasSuper { superBar.update(percent: tiers.s * 100) }
            perfBar.update(percent: tiers.p * 100)
            effBar.update(percent: tiers.e * 100)
        }
    }
}

private final class GridLegendCell: NSView {
    private let dot = CALayer()
    private let dotHost = NSView()
    private let titleLabel: NSTextField
    private let valueLabel = makeLabel("—", font: HIG.captionMono, color: .labelColor, alignment: .right)
    private var dotColor: NSColor?

    init(title: String, dotColor: NSColor?) {
        self.dotColor = dotColor
        titleLabel = makeLabel(title, font: HIG.caption, color: HIG.mutedInk)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        dotHost.translatesAutoresizingMaskIntoConstraints = false
        dotHost.wantsLayer = true
        dot.cornerRadius = 3
        dotHost.layer?.addSublayer(dot)

        [dotHost, titleLabel, valueLabel].forEach(addSubview)
        let hasDot = dotColor != nil
        dotHost.isHidden = !hasDot
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            dotHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotHost.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotHost.widthAnchor.constraint(equalToConstant: hasDot ? 6 : 0),
            dotHost.heightAnchor.constraint(equalToConstant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: dotHost.trailingAnchor, constant: hasDot ? 5 : 0),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setDotColor(_ color: NSColor) {
        if dotColor == color { return }
        dotColor = color
        needsDisplay = true
    }

    func setValue(_ text: String, color: NSColor = .labelColor) {
        valueLabel.setText(text)
        if valueLabel.textColor != color { valueLabel.textColor = color }
    }

    override func layout() {
        super.layout()
        Motion.layers(animated: false) { dot.frame = dotHost.bounds }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if let c = dotColor { dot.backgroundColor = cg(c, in: self) }
    }
}

final class MemGridDetailView: NSView {
    private let appCell = GridLegendCell(title: "应用", dotColor: HIG.memApp)
    private let wiredCell = GridLegendCell(title: "联动", dotColor: HIG.memWired)
    private let compCell = GridLegendCell(title: "压缩", dotColor: HIG.memCompressed)
    private let swapCell = GridLegendCell(title: "交换", dotColor: HIG.faintInk)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let row1 = NSStackView(views: [appCell, wiredCell])
        let row2 = NSStackView(views: [compCell, swapCell])
        for r in [row1, row2] {
            r.orientation = .horizontal
            r.distribution = .fillEqually
            r.spacing = 14
            r.translatesAutoresizingMaskIntoConstraints = false
        }
        let col = NSStackView(views: [row1, row2])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            row1.widthAnchor.constraint(equalTo: col.widthAnchor),
            row2.widthAnchor.constraint(equalTo: col.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(mem: MemInfo) {
        appCell.setValue(Formatters.formatBytes(mem.app))
        wiredCell.setValue(Formatters.formatBytes(mem.wired))
        compCell.setValue(Formatters.formatBytes(mem.compressed))
        let swapActive = mem.swapUsed >= 256 * 1024 * 1024
        swapCell.setDotColor(swapActive ? HIG.memSwap : HIG.faintInk)
        swapCell.setValue(Formatters.formatBytes(mem.swapUsed), color: swapActive ? HIG.warn : .labelColor)
    }
}

final class GPUDetailView: NSView {
    private let tempCell = GridLegendCell(title: "GPU 温度", dotColor: HIG.tintTemp)
    private let gpuWCell = GridLegendCell(title: "GPU 功耗", dotColor: HIG.tintGPU)
    private let sysWCell = GridLegendCell(title: "整机功耗", dotColor: HIG.tintCPU)
    private let aneWCell = GridLegendCell(title: "ANE 功耗", dotColor: HIG.tintNet)
    private let row2: NSStackView

    override init(frame: NSRect) {
        row2 = NSStackView(views: [sysWCell, aneWCell])
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        let row1 = NSStackView(views: [tempCell, gpuWCell])
        for r in [row1, row2] {
            r.orientation = .horizontal
            r.distribution = .fillEqually
            r.spacing = 14
            r.translatesAutoresizingMaskIntoConstraints = false
        }
        let col = NSStackView(views: [row1, row2])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
            row1.widthAnchor.constraint(equalTo: col.widthAnchor),
            row2.widthAnchor.constraint(equalTo: col.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(gpuC: Double?, power: PowerInfo) {
        tempCell.setValue(gpuC.map { String(format: "%.0f °C", $0) } ?? "—")
        gpuWCell.setValue(power.gpuW.map { Formatters.formatWatts($0) } ?? "—")
        let hasRow2 = (power.sysW != nil || power.aneW != nil)
        row2.isHidden = !hasRow2
        if hasRow2 {
            sysWCell.setValue(power.sysW.map { Formatters.formatWatts($0) } ?? "—")
            aneWCell.setValue(power.aneW.map { Formatters.formatWatts($0) } ?? "0.0 W")
        }
    }
}

// MARK: - Primary metric row (CPU / 内存 / GPU)
/// [tile] Title      [sparkline]     14 %  ⌄
///        [===========bar===========]
///        caption  OR  structured expandedView
final class MetricRow: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.rowTitle)
    let sparkline: SparklineView?
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
    var alwaysShowDetail = false
    var onToggleDetail: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let detailContainer = NSStackView()
    private var expandedView: NSView?
    private var valueTrailingToChevron: NSLayoutConstraint!
    private var valueTrailingToEdge: NSLayoutConstraint!

    init(symbol: String, title: String, tint: NSColor, showsSparkline: Bool = false) {
        tile = IconTile(symbol: symbol, tint: tint)
        track = ProgressTrack(tint: tint)
        sparkline = showsSparkline ? SparklineView(tint: tint, fixedMax: 100.0) : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        segments.isHidden = true

        expandBtn.isBordered = false
        expandBtn.imagePosition = .imageOnly
        expandBtn.translatesAutoresizingMaskIntoConstraints = false
        expandBtn.contentTintColor = HIG.faintInk
        expandBtn.target = self
        expandBtn.action = #selector(toggle)
        expandBtn.isHidden = true
        expandBtn.setAccessibilityLabel("详情")
        expandBtn.image = Self.chevronImage(expanded: false)

        detailLabel.textColor = HIG.mutedInk
        detailLabel.font = HIG.caption

        detailContainer.orientation = .vertical
        detailContainer.alignment = .leading
        detailContainer.spacing = 0
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addArrangedSubview(detailLabel)

        [tile, titleLabel, valueLabel, expandBtn, track, segments, detailContainer].forEach(addSubview)
        if let sp = sparkline { addSubview(sp) }

        valueTrailingToChevron = valueLabel.trailingAnchor.constraint(equalTo: expandBtn.leadingAnchor, constant: -4)
        valueTrailingToEdge = valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor)
        valueTrailingToEdge.isActive = true

        var constraints: [NSLayoutConstraint] = [
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HIG.titleGap),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            expandBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 2),
            expandBtn.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            expandBtn.widthAnchor.constraint(equalToConstant: 16),
            expandBtn.heightAnchor.constraint(equalToConstant: 16),
            valueLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: HIG.barTop),
            track.heightAnchor.constraint(equalToConstant: HIG.barH),
            segments.heightAnchor.constraint(equalTo: track.heightAnchor),
            segments.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            segments.topAnchor.constraint(equalTo: track.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailContainer.topAnchor.constraint(equalTo: track.bottomAnchor, constant: HIG.detailTop + 1),
            detailContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            detailLabel.widthAnchor.constraint(equalTo: detailContainer.widthAnchor)
        ]
        if let sp = sparkline {
            constraints.append(contentsOf: [
                sp.trailingAnchor.constraint(equalTo: valueLabel.leadingAnchor, constant: -10),
                sp.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                sp.widthAnchor.constraint(equalToConstant: 72),
                sp.heightAnchor.constraint(equalToConstant: 18),
                sp.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
            ])
        } else {
            constraints.append(valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setExpandedView(_ view: NSView) {
        if let old = expandedView {
            detailContainer.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
        expandedView = view
        view.isHidden = !detailExpanded
        detailContainer.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: detailContainer.widthAnchor).isActive = true
    }

    func enableDetail(_ on: Bool) {
        detailEnabled = on
        expandBtn.isHidden = !on
        valueTrailingToChevron.isActive = on
        valueTrailingToEdge.isActive = !on
    }

    func setExpanded(_ on: Bool) {
        let changed = (detailExpanded != on)
        detailExpanded = on
        expandBtn.image = Self.chevronImage(expanded: on)
        expandBtn.setAccessibilityValue(on ? "已展开" : "已收起")
        if let ev = expandedView {
            detailLabel.isHidden = on || !alwaysShowDetail
            ev.isHidden = !on
        } else {
            detailLabel.isHidden = !(alwaysShowDetail || on)
            detailLabel.maximumNumberOfLines = on ? 2 : 1
            detailLabel.lineBreakMode = on ? .byWordWrapping : .byTruncatingTail
        }
        if changed { onHeightChange?() }
    }

    func setReading(_ number: String, unit: String = "%", level: LoadLevel = .normal) {
        valueLabel.setNumber(number, unit: unit, color: level == .normal ? .labelColor : level.color(tint: tile.tint))
    }
    func setPlaceholder(_ text: String) { valueLabel.setNumber(text, unit: "", placeholder: true) }
    func setDetail(_ text: String) {
        detailLabel.set(key: text) {
            NSAttributedString(string: text, attributes: [.font: HIG.caption, .foregroundColor: HIG.mutedInk])
        }
    }
    private static func chevronImage(expanded: Bool) -> NSImage? {
        symbol(expanded ? "chevron.up" : "chevron.down", size: 9, weight: .semibold)
    }
    @objc private func toggle() {
        setExpanded(!detailExpanded)
        onToggleDetail?()
    }
    override func mouseDown(with event: NSEvent) { if !detailEnabled { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        guard detailEnabled else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }
}

// MARK: - Stat tile (温度 / 风扇, with ratio bar, subtitle & optional click action)
final class StatTile: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.caption, color: HIG.mutedInk)
    let valueLabel = RichLabel.make()
    let subLabel = makeLabel("", font: HIG.captionMono, color: HIG.faintInk)
    let track: ProgressTrack
    var onTap: (() -> Void)?

    private let card: CardView
    private let hoverLayer = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { applyHover() } } }

    init(symbol: String, title: String, tint: NSColor) {
        tile = IconTile(symbol: symbol, tint: tint, size: HIG.tileSizeSmall, glyphSize: 10)
        track = ProgressTrack(tint: tint, height: 3)
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        card = CardView([body], padding: HIG.cardPad)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        hoverLayer.cornerRadius = HIG.cardRadius
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)

        titleLabel.stringValue = title
        [tile, titleLabel, valueLabel, subLabel, track].forEach(body.addSubview)
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            body.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -HIG.cardPad * 2),
            tile.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            tile.topAnchor.constraint(equalTo: body.topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 7),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            valueLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 6),
            subLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            subLabel.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor),
            subLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 2),
            track.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            track.topAnchor.constraint(equalTo: subLabel.bottomAnchor, constant: 6),
            track.bottomAnchor.constraint(equalTo: body.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setReading(_ value: String, unit: String, level: LoadLevel = .normal) {
        valueLabel.setNumber(value, unit: unit, color: level == .normal ? .labelColor : level.color(tint: tile.tint),
                             numberFont: HIG.valueL)
    }
    func setPlaceholder(_ text: String) { valueLabel.setNumber(text, unit: "", placeholder: true) }
    func setSubtitle(_ text: String, color: NSColor = HIG.faintInk) {
        subLabel.setText(text)
        if subLabel.textColor != color { subLabel.textColor = color }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { if onTap != nil { hovering = true } }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if onTap == nil { super.mouseDown(with: event) } }
    override func mouseUp(with event: NSEvent) {
        guard let tap = onTap else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { tap() }
    }
    override func layout() {
        super.layout()
        Motion.layers(animated: false) { hoverLayer.frame = bounds }
    }
    private func applyHover() {
        Motion.layers(animated: true, duration: 0.16) { hoverLayer.opacity = hovering ? 1 : 0 }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { hoverLayer.backgroundColor = cg(HIG.hover, in: self) }
}

// MARK: - IO row (存储 / 网络, with optional live dual-rate sparkline)
final class IORow: NSView {
    let tile: IconTile
    let titleLabel = makeLabel("", font: HIG.rowTitle)
    let valueLabel = RichLabel.make(alignment: .right)
    let track: ProgressTrack
    let sparkline: SparklineView?

    var showsTrack = true {
        didSet {
            track.isHidden = !showsTrack
            trackTop.constant = showsTrack ? HIG.barTop : 0
            trackH.constant = showsTrack ? HIG.barHSmall : 0
        }
    }
    private var trackTop: NSLayoutConstraint!
    private var trackH: NSLayoutConstraint!

    init(symbol: String, title: String, tint: NSColor, showsNetSparkline: Bool = false) {
        tile = IconTile(symbol: symbol, tint: tint)
        track = ProgressTrack(tint: tint, height: HIG.barHSmall)
        sparkline = showsNetSparkline ? SparklineView(tint: HIG.netDown, secondaryTint: HIG.netUp, fixedMax: nil, minAutoMax: 64 * 1024) : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = title
        [tile, titleLabel, valueLabel, track].forEach(addSubview)
        if let sp = sparkline { addSubview(sp) }

        trackH = track.heightAnchor.constraint(equalToConstant: HIG.barHSmall)
        trackTop = track.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: HIG.barTop)

        var constraints: [NSLayoutConstraint] = [
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HIG.titleGap),
            titleLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackTop, trackH
        ]
        if let sp = sparkline {
            constraints.append(contentsOf: [
                sp.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                sp.trailingAnchor.constraint(equalTo: trailingAnchor),
                sp.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 6),
                sp.heightAnchor.constraint(equalToConstant: 18),
                sp.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            constraints.append(track.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setUsage(percent: Int, detail: String) {
        valueLabel.set(key: "\(percent)|\(detail)") {
            Caption().text("\(percent)%", .labelColor, font: HIG.monoSmStrong)
                .text("  " + detail, HIG.mutedInk, font: HIG.monoSm).string
        }
    }
    func setRates(down: String, up: String) {
        valueLabel.set(key: "\(down)|\(up)") {
            Caption().text("↓ ", HIG.netDown, font: HIG.monoSmStrong).text(down, .labelColor, font: HIG.monoSm)
                .text("   ↑ ", HIG.netUp, font: HIG.monoSmStrong).text(up, .labelColor, font: HIG.monoSm).string
        }
    }
    func setMessage(_ text: String) {
        valueLabel.set(key: "msg|" + text) {
            NSAttributedString(string: text, attributes: [.font: HIG.callout, .foregroundColor: HIG.mutedInk])
        }
    }
}

// MARK: - Process table (hover-reveal actions + inline usage bar + row click menu)
final class AppProcRow: NSView {
    let iconView = NSImageView()
    let nameLabel = makeLabel("", font: HIG.body)
    let cpuLabel = makeLabel("", font: HIG.monoSm, color: HIG.mutedInk)
    let memLabel = makeLabel("", font: HIG.monoSm, color: HIG.mutedInk)
    let menuBtn = NSButton()
    var onMenu: ((NSView) -> Void)?
    var pid: Int32 = 0
    private var iconKey: String?
    private let hoverLayer = CALayer()
    private let shareBar = CALayer()
    private var shareFraction: CGFloat = 0
    private var shareTint: NSColor = HIG.tintCPU
    private var hovering = false { didSet { if hovering != oldValue { applyHover() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        hoverLayer.cornerRadius = 7
        hoverLayer.cornerCurve = .continuous
        hoverLayer.opacity = 0
        layer?.addSublayer(hoverLayer)

        shareBar.cornerRadius = 1
        layer?.addSublayer(shareBar)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        menuBtn.image = symbol("ellipsis.circle.fill", size: 13, weight: .regular)
        menuBtn.setAccessibilityLabel("进程操作")
        menuBtn.isBordered = false
        menuBtn.imagePosition = .imageOnly
        menuBtn.target = self
        menuBtn.action = #selector(tapMenu)
        menuBtn.translatesAutoresizingMaskIntoConstraints = false
        menuBtn.contentTintColor = HIG.mutedInk
        menuBtn.alphaValue = HIG.procMenuIdleAlpha
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
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1.5),
            menuBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: HIG.procMenuW),
            menuBtn.heightAnchor.constraint(equalToConstant: HIG.procMenuW),
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

    @objc private func tapMenu() { onMenu?(menuBtn) }

    override func mouseDown(with event: NSEvent) {
        if onMenu == nil { super.mouseDown(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let action = onMenu else { super.mouseUp(with: event); return }
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(menuBtn) }
    }

    func setSortedByCPU(_ byCPU: Bool) {
        let on = NSColor.labelColor, off = HIG.mutedInk
        if cpuLabel.textColor != (byCPU ? on : off) { cpuLabel.textColor = byCPU ? on : off }
        if memLabel.textColor != (byCPU ? off : on) { memLabel.textColor = byCPU ? off : on }
    }

    func setShare(fraction: Double, tint: NSColor) {
        let f = CGFloat(max(0, min(1, fraction.isFinite ? fraction : 0)))
        if abs(f - shareFraction) < 0.01 && tint == shareTint { return }
        shareFraction = f
        shareTint = tint
        needsDisplay = true
        needsLayout = true
    }

    func setIcon(_ image: NSImage?, key: String) {
        if key == iconKey { return }
        iconKey = key
        if let image, !image.isTemplate {
            let copy = image.copy() as! NSImage
            copy.size = NSSize(width: HIG.appIcon, height: HIG.appIcon)
            iconView.image = copy
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = nil
        } else {
            let isSystem = key.hasPrefix("/System") || key.hasPrefix("/usr") || key.hasPrefix("/bin") || key.hasPrefix("/sbin")
            iconView.image = symbol(isSystem ? "gearshape.2.fill" : "app.dashed", size: 14, weight: .regular)
            iconView.imageScaling = .scaleNone
            iconView.contentTintColor = HIG.faintInk
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    func resetHover() { hovering = false }
    override var isHidden: Bool { didSet { if isHidden { hovering = false } } }

    override func layout() {
        super.layout()
        let barStart = HIG.appIcon + HIG.titleGap
        let maxBarW = max(0, bounds.width - barStart - HIG.procMenuW - 4)
        let barW = shareFraction > 0.015 ? max(4, maxBarW * shareFraction) : 0
        Motion.layers(animated: false) {
            hoverLayer.frame = bounds.insetBy(dx: -HIG.procHoverInset, dy: 0)
            shareBar.frame = CGRect(x: barStart, y: 1.0, width: barW, height: 1.8)
        }
    }
    private func applyHover() {
        Motion.layers(animated: true, duration: 0.16) { hoverLayer.opacity = hovering ? 1 : 0 }
        if Motion.reduce {
            menuBtn.alphaValue = hovering ? 1 : HIG.procMenuIdleAlpha
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                menuBtn.animator().alphaValue = hovering ? 1 : HIG.procMenuIdleAlpha
            }
        }
        menuBtn.contentTintColor = hovering ? .labelColor : HIG.mutedInk
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        hoverLayer.backgroundColor = cg(HIG.hover, in: self)
        shareBar.backgroundColor = cg(shareTint.withAlphaComponent(0.32), in: self)
    }
}

final class SortHeader: NSView {
    let titleLabel = makeLabel("占用最高", font: HIG.captionStrong, color: HIG.mutedInk)
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
                .foregroundColor: active ? NSColor.labelColor : HIG.mutedInk,
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
        contentTintColor = HIG.mutedInk
        translatesAutoresizingMaskIntoConstraints = false
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = .labelColor }
    override func mouseExited(with event: NSEvent) { contentTintColor = HIG.mutedInk }
}
