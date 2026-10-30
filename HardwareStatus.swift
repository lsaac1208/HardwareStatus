import Cocoa
import Foundation
import Darwin
import QuartzCore

@_silgen_name("hw_phys_footprint")
func hw_phys_footprint(_ pid: Int32) -> UInt64

// MARK: - Design tokens (compact single-layer panel)
enum HIG {
    static let panelW: CGFloat = 360
    static let panelH: CGFloat = 560
    static let insetX: CGFloat = 20
    static let insetTop: CGFloat = 18
    static let groupGap: CGFloat = 14
    static let rowGap: CGFloat = 10
    static let iconSize: CGFloat = 18
    static let barH: CGFloat = 4
    // Process table shared columns (header + rows)
    static let procMenuW: CGFloat = 20
    static let procMemW: CGFloat = 58
    static let procCpuW: CGFloat = 50
    static let procArrowW: CGFloat = 12
    static let procColGap: CGFloat = 6
    static var title2: NSFont { .systemFont(ofSize: 17, weight: .semibold) }
    static var valuePrimary: NSFont { .monospacedDigitSystemFont(ofSize: 17, weight: .semibold) }
    static var valueSecondary: NSFont { .monospacedDigitSystemFont(ofSize: 15, weight: .semibold) }
    static var valueUnit: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var name: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    static var callout: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    static var caption: NSFont { .systemFont(ofSize: 11, weight: .regular) }
    static var monoSm: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .regular) }
    static var status: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    static var section: NSFont { .systemFont(ofSize: 12, weight: .regular) }
}

private func label(_ s: String = "", font: NSFont, color: NSColor = .labelColor) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = font
    t.textColor = color
    t.drawsBackground = false
    t.isBordered = false
    t.lineBreakMode = .byTruncatingTail
    t.translatesAutoresizingMaskIntoConstraints = false
    return t
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class Hairline: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        applyColor()
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    private func applyColor() {
        // System divider color, slightly softened — avoid hard deep-gray cuts
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }
}

final class ProgressTrack: NSView {
    private let fill = CALayer()
    private var frac: CGFloat = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = HIG.barH / 2
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        fill.cornerRadius = HIG.barH / 2
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.addSublayer(fill)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ value: Double, warnAt: Double = 75, criticalAt: Double = 90) {
        frac = CGFloat(min(1, max(0, value / 100)))
        let c: NSColor
        if value >= criticalAt { c = .systemRed }
        else if value >= warnAt { c = .systemOrange }
        else { c = .controlAccentColor }
        fill.backgroundColor = c.cgColor
        needsLayout = true
    }
    override func layout() {
        super.layout()
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * frac, height: bounds.height)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
    }
}

final class SegmentBar: NSView {
    private var parts: [(CGFloat, NSColor)] = []
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = HIG.barH / 2
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(parts items: [(Double, NSColor)], total: Double) {
        let t = max(total, 1)
        var mapped = items.map { (CGFloat(min(1, max(0, $0.0 / t))), $0.1) }
        let sum = mapped.reduce(CGFloat(0)) { $0 + $1.0 }
        if sum > 1, sum > 0 { mapped = mapped.map { ($0.0 / sum, $0.1) } }
        parts = mapped
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: HIG.barH/2, yRadius: HIG.barH/2).fill()
        var x: CGFloat = 0
        for (f, c) in parts {
            let w = bounds.width * f
            c.setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: max(0, w), height: bounds.height)).fill()
            x += w
        }
    }
}

// MARK: - Primary metric row
final class MetricRow: NSView {
    let symbolView = NSImageView()
    let titleLabel = label("", font: HIG.name)
    let valueLabel = label("", font: HIG.valuePrimary, color: .labelColor)
    let detailLabel = label("", font: HIG.caption, color: .secondaryLabelColor)
    let expandBtn = NSButton()
    let track = ProgressTrack()
    let segments = SegmentBar()
    var usesSegments = false {
        didSet { track.isHidden = usesSegments; segments.isHidden = !usesSegments }
    }
    private(set) var detailExpanded = false
    var alwaysShowDetail = false
    var onToggleDetail: (() -> Void)?
    private var detailH: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        valueLabel.alignment = .right
        segments.isHidden = true
        expandBtn.isBordered = false
        expandBtn.imagePosition = .imageOnly
        expandBtn.translatesAutoresizingMaskIntoConstraints = false
        expandBtn.contentTintColor = .tertiaryLabelColor
        let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "详情")
        expandBtn.image = chevron?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        expandBtn.target = self
        expandBtn.action = #selector(toggle)
        expandBtn.isHidden = true
        [symbolView, titleLabel, valueLabel, expandBtn, detailLabel, track, segments].forEach(addSubview)
        detailH = detailLabel.heightAnchor.constraint(equalToConstant: 16)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            symbolView.widthAnchor.constraint(equalToConstant: 16),
            symbolView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: symbolView.centerYAnchor),
            expandBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            expandBtn.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            expandBtn.widthAnchor.constraint(equalToConstant: 18),
            expandBtn.heightAnchor.constraint(equalToConstant: 18),
            valueLabel.trailingAnchor.constraint(equalTo: expandBtn.leadingAnchor, constant: -2),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            track.heightAnchor.constraint(equalToConstant: HIG.barH),
            segments.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            segments.topAnchor.constraint(equalTo: track.topAnchor),
            segments.heightAnchor.constraint(equalTo: track.heightAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: track.bottomAnchor, constant: 6),
            detailH,
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func enableDetail(_ on: Bool) { expandBtn.isHidden = !on }
    func setExpanded(_ on: Bool) {
        detailExpanded = on
        expandBtn.state = on ? .on : .off
        detailLabel.maximumNumberOfLines = on ? 2 : 1
        detailLabel.lineBreakMode = on ? .byWordWrapping : .byTruncatingTail
        if alwaysShowDetail {
            detailLabel.isHidden = false
            detailH.constant = on ? 28 : 16
        } else {
            detailLabel.isHidden = !on
            detailH.constant = on ? 28 : 0
        }
    }
    @objc private func toggle() {
        setExpanded(!detailExpanded)
        onToggleDetail?()
    }
    func setSymbol(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbolView.image = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        symbolView.contentTintColor = .secondaryLabelColor
    }
}

final class CompactValue: NSView {
    let titleLabel = label("", font: HIG.caption, color: .secondaryLabelColor)
    let valueLabel = label("", font: HIG.valueSecondary, color: .labelColor)
    let unitLabel = label("", font: HIG.valueUnit, color: .secondaryLabelColor)
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, valueLabel, unitLabel].forEach(addSubview)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            unitLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 4),
            unitLabel.firstBaselineAnchor.constraint(equalTo: valueLabel.firstBaselineAnchor),
            unitLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setValue(_ value: String, unit: String) {
        valueLabel.stringValue = value
        unitLabel.stringValue = unit
        unitLabel.isHidden = unit.isEmpty
    }
}

final class IORow: NSView {
    let symbolView = NSImageView()
    let titleLabel = label("", font: HIG.name)
    let valueLabel = label("", font: HIG.monoSm, color: .labelColor)
    let track = ProgressTrack()
    var showsTrack = true {
        didSet { track.isHidden = !showsTrack; trackH.constant = showsTrack ? HIG.barH : 0 }
    }
    private var trackH: NSLayoutConstraint!
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        valueLabel.alignment = .right
        [symbolView, titleLabel, valueLabel, track].forEach(addSubview)
        trackH = track.heightAnchor.constraint(equalToConstant: HIG.barH)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            symbolView.widthAnchor.constraint(equalToConstant: 14),
            symbolView.heightAnchor.constraint(equalToConstant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: symbolView.centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            valueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            track.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            trackH,
            track.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setSymbol(_ name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbolView.image = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        symbolView.contentTintColor = .secondaryLabelColor
    }
}

final class AppProcRow: NSView {
    let iconView = NSImageView()
    let nameLabel = label("", font: HIG.body)
    let cpuLabel = label("", font: HIG.monoSm, color: .secondaryLabelColor)
    let memLabel = label("", font: HIG.monoSm, color: .secondaryLabelColor)
    let menuBtn = NSButton()
    var onMenu: (() -> Void)?
    var pid: Int32 = 0
    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 4
        iconView.layer?.masksToBounds = true
        menuBtn.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "操作")
        menuBtn.isBordered = false
        menuBtn.imagePosition = .imageOnly
        menuBtn.target = self
        menuBtn.action = #selector(tap)
        menuBtn.translatesAutoresizingMaskIntoConstraints = false
        menuBtn.contentTintColor = .tertiaryLabelColor
        cpuLabel.alignment = .right
        memLabel.alignment = .right
        [iconView, nameLabel, cpuLabel, memLabel, menuBtn].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: HIG.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: HIG.iconSize),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuBtn.trailingAnchor.constraint(equalTo: trailingAnchor),
            menuBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            menuBtn.widthAnchor.constraint(equalToConstant: HIG.procMenuW),
            menuBtn.heightAnchor.constraint(equalToConstant: HIG.procMenuW),
            // mem / cpu share exact columns with SortHeader (arrow reserved between them)
            memLabel.trailingAnchor.constraint(equalTo: menuBtn.leadingAnchor, constant: -2),
            memLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memLabel.widthAnchor.constraint(equalToConstant: HIG.procMemW),
            cpuLabel.trailingAnchor.constraint(equalTo: memLabel.leadingAnchor, constant: -(HIG.procColGap + HIG.procArrowW)),
            cpuLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            cpuLabel.widthAnchor.constraint(equalToConstant: HIG.procCpuW),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: cpuLabel.leadingAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func tap() { onMenu?() }
    func setIcon(_ image: NSImage?) {
        if let image {
            let copy = image.copy() as! NSImage
            copy.size = NSSize(width: HIG.iconSize, height: HIG.iconSize)
            iconView.image = copy
            iconView.contentTintColor = nil
        } else {
            iconView.image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)
            iconView.contentTintColor = .tertiaryLabelColor
        }
    }
}

final class SortHeader: NSView {
    let titleLabel = label("占用最高", font: HIG.section, color: .secondaryLabelColor)
    let cpuBtn = NSButton()
    let memBtn = NSButton()
    let arrowLabel = label("↓", font: HIG.caption, color: .labelColor)
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
            b.font = HIG.caption
            b.translatesAutoresizingMaskIntoConstraints = false
            b.contentTintColor = .secondaryLabelColor
            b.alignment = .right
        }
        cpuBtn.target = self; cpuBtn.action = #selector(tapCPU)
        memBtn.target = self; memBtn.action = #selector(tapMem)
        arrowLabel.alignment = .center
        [titleLabel, cpuBtn, arrowLabel, memBtn].forEach(addSubview)
        // Align with AppProcRow: menuW + memW + gap+arrow + cpuW from trailing
        let menuPad = HIG.procMenuW + 2
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            memBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -menuPad),
            memBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            memBtn.widthAnchor.constraint(equalToConstant: HIG.procMemW),
            cpuBtn.trailingAnchor.constraint(equalTo: memBtn.leadingAnchor, constant: -(HIG.procColGap + HIG.procArrowW)),
            cpuBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
            cpuBtn.widthAnchor.constraint(equalToConstant: HIG.procCpuW),
            arrowLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            arrowLabel.widthAnchor.constraint(equalToConstant: HIG.procArrowW)
        ])
        // Arrow lives in reserved slot between CPU and 内存 columns
        arrowToCpu = arrowLabel.leadingAnchor.constraint(equalTo: cpuBtn.trailingAnchor)
        arrowToMem = arrowLabel.trailingAnchor.constraint(equalTo: memBtn.leadingAnchor)
        arrowToCpu.isActive = true
        refreshTitles()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func refreshTitles() {
        cpuBtn.title = "CPU"
        memBtn.title = "内存"
        cpuBtn.contentTintColor = sortByCPU ? .labelColor : .secondaryLabelColor
        memBtn.contentTintColor = sortByCPU ? .secondaryLabelColor : .labelColor
        arrowLabel.textColor = .labelColor
        arrowToCpu.isActive = false
        arrowToMem.isActive = false
        if sortByCPU { arrowToCpu.isActive = true }
        else { arrowToMem.isActive = true }
    }
    @objc private func tapCPU() { onSortCPU?() }
    @objc private func tapMem() { onSortMem?() }
}

// MARK: - Root panel (single-layer)
final class MonitorPanelController: NSViewController {
    let scroll = NSScrollView()
    let doc = FlippedView()
    let stack = NSStackView()

    let titleLabel = label("系统状态", font: HIG.title2)
    let subtitleLabel = label("", font: HIG.caption, color: .secondaryLabelColor)
    let thermalDot = NSView()
    let thermalBadge = label("", font: HIG.caption, color: .labelColor)

    let cpuRow = MetricRow()
    let memRow = MetricRow()
    let gpuRow = MetricRow()
    let tempCell = CompactValue()
    let fanCell = CompactValue()
    let diskRow = IORow()
    let netRow = IORow()
    let sortHeader = SortHeader()
    var topRows: [AppProcRow] = []

    let footer = NSView()
    let activityBtn = NSButton()
    let moreButton = NSButton()

    var sortByCPU = true
    var onSortChanged: (() -> Void)?
    var onOpenActivity: (() -> Void)?
    var onMoreMenu: ((NSButton) -> Void)?

    private let contentW: CGFloat = HIG.panelW - HIG.insetX * 2

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: HIG.panelW, height: HIG.panelH))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        view = root
        preferredContentSize = NSSize(width: HIG.panelW, height: HIG.panelH)

        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.drawsBackground = false
        root.addSubview(scroll)

        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HIG.groupGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        thermalDot.translatesAutoresizingMaskIntoConstraints = false
        thermalDot.wantsLayer = true
        thermalDot.layer?.cornerRadius = 3
        thermalDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        thermalBadge.alignment = .left
        [titleLabel, subtitleLabel, thermalDot, thermalBadge].forEach(header.addSubview)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            thermalBadge.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            thermalBadge.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            thermalDot.trailingAnchor.constraint(equalTo: thermalBadge.leadingAnchor, constant: -5),
            thermalDot.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            thermalDot.widthAnchor.constraint(equalToConstant: 6),
            thermalDot.heightAnchor.constraint(equalToConstant: 6),
            thermalDot.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: contentW)
        ])

        cpuRow.setSymbol("cpu"); cpuRow.titleLabel.stringValue = "CPU"
        cpuRow.enableDetail(true); cpuRow.alwaysShowDetail = true; cpuRow.setExpanded(false)
        memRow.setSymbol("memorychip"); memRow.titleLabel.stringValue = "内存"
        memRow.usesSegments = false; memRow.enableDetail(true)
        memRow.alwaysShowDetail = true; memRow.setExpanded(false)
        gpuRow.setSymbol("cube"); gpuRow.titleLabel.stringValue = "GPU"
        gpuRow.enableDetail(false); gpuRow.alwaysShowDetail = false; gpuRow.setExpanded(false)
        for m in [cpuRow, memRow, gpuRow] {
            m.widthAnchor.constraint(equalToConstant: contentW).isActive = true
            m.onToggleDetail = { [weak self] in self?.onSortChanged?() }
        }
        let primary = NSStackView(views: [cpuRow, memRow, gpuRow])
        primary.orientation = .vertical
        primary.spacing = HIG.rowGap
        primary.alignment = .leading
        primary.translatesAutoresizingMaskIntoConstraints = false
        primary.widthAnchor.constraint(equalToConstant: contentW).isActive = true

        tempCell.titleLabel.stringValue = "CPU 温度"
        fanCell.titleLabel.stringValue = "风扇转速"
        let thermo = NSStackView(views: [tempCell, fanCell])
        thermo.orientation = .horizontal
        thermo.distribution = .fillEqually
        thermo.spacing = 16
        thermo.translatesAutoresizingMaskIntoConstraints = false
        thermo.widthAnchor.constraint(equalToConstant: contentW).isActive = true

        diskRow.setSymbol("internaldrive"); diskRow.titleLabel.stringValue = "存储"
        netRow.setSymbol("network"); netRow.titleLabel.stringValue = "网络"; netRow.showsTrack = false
        for r in [diskRow, netRow] { r.widthAnchor.constraint(equalToConstant: contentW).isActive = true }
        let io = NSStackView(views: [diskRow, netRow])
        io.orientation = .vertical; io.spacing = 8; io.alignment = .leading
        io.translatesAutoresizingMaskIntoConstraints = false
        io.widthAnchor.constraint(equalToConstant: contentW).isActive = true

        sortHeader.widthAnchor.constraint(equalToConstant: contentW).isActive = true
        sortHeader.onSortCPU = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = true; self.sortHeader.sortByCPU = true; self.onSortChanged?()
        }
        sortHeader.onSortMem = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = false; self.sortHeader.sortByCPU = false; self.onSortChanged?()
        }
        let procStack = NSStackView()
        procStack.orientation = .vertical; procStack.spacing = 4; procStack.alignment = .leading
        procStack.translatesAutoresizingMaskIntoConstraints = false
        procStack.addArrangedSubview(sortHeader)
        for _ in 0..<3 {
            let row = AppProcRow()
            row.widthAnchor.constraint(equalToConstant: contentW).isActive = true
            topRows.append(row)
            procStack.addArrangedSubview(row)
        }
        procStack.widthAnchor.constraint(equalToConstant: contentW).isActive = true

        let h2 = Hairline(); let h3 = Hairline(); let h4 = Hairline()
        for h in [h2,h3,h4] { h.widthAnchor.constraint(equalToConstant: contentW).isActive = true }

        // No divider under title — whitespace connects header to resources
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(primary)
        stack.addArrangedSubview(h2)
        stack.addArrangedSubview(thermo)
        stack.addArrangedSubview(h3)
        stack.addArrangedSubview(io)
        stack.addArrangedSubview(h4)
        stack.addArrangedSubview(procStack)

        stack.setCustomSpacing(18, after: header)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: HIG.insetTop),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: HIG.insetX),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -HIG.insetX),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -12),
            stack.widthAnchor.constraint(equalToConstant: contentW),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalToConstant: HIG.panelW)
        ])

        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        activityBtn.title = "活动监视器"
        activityBtn.bezelStyle = .inline; activityBtn.isBordered = false
        activityBtn.font = HIG.callout; activityBtn.contentTintColor = .secondaryLabelColor
        activityBtn.translatesAutoresizingMaskIntoConstraints = false
        activityBtn.target = self; activityBtn.action = #selector(openActivity)
        moreButton.title = "更多"
        moreButton.bezelStyle = .inline; moreButton.isBordered = false
        moreButton.font = HIG.callout; moreButton.contentTintColor = .secondaryLabelColor
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.target = self; moreButton.action = #selector(openMore)
        footer.addSubview(activityBtn); footer.addSubview(moreButton)
        let footLine = Hairline(); footer.addSubview(footLine)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 40),
            footLine.topAnchor.constraint(equalTo: footer.topAnchor),
            footLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HIG.insetX),
            footLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -HIG.insetX),
            activityBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HIG.insetX),
            activityBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -HIG.insetX),
            moreButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])
    }
    @objc private func openActivity() { onOpenActivity?() }
    @objc private func openMore() { onMoreMenu?(moreButton) }
}

enum StatusShowKey: String, CaseIterable {
    case cpu = "showCPU", gpu = "showGPU", mem = "showMem", chip = "showChip"
    case fan = "showFan", disk = "showDisk", net = "showNet"
    var title: String {
        switch self {
        case .cpu: return "CPU 占用"; case .gpu: return "GPU 占用"; case .mem: return "内存占用"
        case .chip: return "温度"; case .fan: return "风扇转速"; case .disk: return "磁盘占用"; case .net: return "网速"
        }
    }
    var defaultOn: Bool {
        switch self { case .cpu, .mem, .chip, .net: return true; default: return false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panel: MonitorPanelController!
    private var prefsMenu: NSMenu!
    private var moreMenu: NSMenu!
    private var eventMonitor: Any?
    private var timer: Timer?
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCPUUserSys: (user: Double, system: Double) = (0, 0)
    private var lastProcCPU: [Int32: (cpu: Double, wall: TimeInterval)] = [:]
    private var displayNameCache: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]
    private let idleInterval: TimeInterval = 2.5
    private let menuOpenInterval: TimeInterval = 1.0
    private let prefs = UserDefaults.standard
    private let prefsPrefix = "local.lsaac128.HardwareStatus."
    private let orderKey = "local.lsaac128.HardwareStatus.statusOrder"
    private let macmonPath = "/opt/homebrew/bin/macmon"
    private let tempLock = NSLock()
    private var cachedCpuC: Double?
    private var cachedGpuC: Double?
    private var cachedFanRpm: Int?
    private var cachedFanMax: Int?
    private var cachedFanCount: Int = 0
    private var cachedGpuPct: Double?
    private var cachedPE: (p: Double, e: Double, s: Double) = (0, 0, 0)
    private var tempRefreshInFlight = false
    private var lastNetBytes: (inB: UInt64, outB: UInt64, wall: TimeInterval)?
    private var netDownBps: Double = 0
    private var netUpBps: Double = 0
    private var netSessionStart: (inB: UInt64, outB: UInt64)?
    private var netLifetime: (inB: UInt64, outB: UInt64) = (0, 0)
    private var showMenuItems: [StatusShowKey: NSMenuItem] = [:]
    private var orderMenu: NSMenu!
    private let titleFont = HIG.status
    private var isScreenLocked = false
    private var isSleeping = false
    private var isPanelOpen = false
    private var chipName = "Apple Silicon"
    private var modelId = "Mac"
    private var memTotalGB = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedIdentity(); seedDefaultsIfNeeded(); buildPanel()
        buildPrefsMenu(); buildMoreMenu(); buildStatusItem()
        installLifecycleObservers(); installClickOutsideMonitor()
        _ = sampleCPU(); _ = sampleProcessesRaw(); _ = sampleNetwork()
        refreshTempsAsync(force: true); updateMetrics(); restartTimer(interval: idleInterval)
    }

    private func seedIdentity() {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { chipName = s }
        }
        size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { modelId = s }
        }
        var mem: UInt64 = 0; var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &len, nil, 0)
        memTotalGB = String(format: "%.0f GB", Double(mem) / 1_073_741_824.0)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: 1)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "系统状态") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                img.isTemplate = true
                button.image = img.withSymbolConfiguration(cfg)
                button.imagePosition = .imageLeading
            }
            button.font = titleFont
            button.toolTip = "系统状态"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyStatusItemLength(forPreviewTitle: longestTitleSample())
    }

    private func buildPanel() {
        panel = MonitorPanelController()
        _ = panel.view
        panel.onSortChanged = { [weak self] in self?.updateMetrics() }
        panel.onOpenActivity = { [weak self] in self?.openActivityMonitor() }
        panel.onMoreMenu = { [weak self] btn in self?.showMoreMenu(from: btn) }
        popover = NSPopover()
        popover.contentSize = NSSize(width: HIG.panelW, height: HIG.panelH)
        popover.behavior = .transient
        popover.animates = true
        // System popover chrome only — no custom corner/border/shadow on content
        popover.contentViewController = panel
        popover.delegate = self
    }

    private func buildPrefsMenu() {
        prefsMenu = NSMenu(); prefsMenu.autoenablesItems = false; prefsMenu.delegate = self
        let showRoot = NSMenuItem(title: "状态栏显示", action: nil, keyEquivalent: "")
        let showSub = NSMenu()
        for key in StatusShowKey.allCases {
            let mi = NSMenuItem(title: key.title, action: #selector(toggleShow(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = key.rawValue
            mi.state = isShow(key) ? .on : .off; mi.isEnabled = true
            showSub.addItem(mi); showMenuItems[key] = mi
        }
        showRoot.submenu = showSub; prefsMenu.addItem(showRoot)
        let orderRoot = NSMenuItem(title: "状态栏顺序", action: nil, keyEquivalent: "")
        orderMenu = NSMenu(); rebuildOrderMenu(); orderRoot.submenu = orderMenu; prefsMenu.addItem(orderRoot)
        prefsMenu.addItem(.separator())
        let sample = NSMenuItem(title: "锁屏时暂停采样", action: nil, keyEquivalent: "")
        sample.state = .on; sample.isEnabled = false
        prefsMenu.addItem(sample)
    }

    private func buildMoreMenu() {
        moreMenu = NSMenu(); moreMenu.autoenablesItems = false
        let settings = NSMenuItem(title: "设置…", action: #selector(showPrefsFromMore(_:)), keyEquivalent: "")
        settings.target = self; settings.isEnabled = true; moreMenu.addItem(settings)
        let diag = NSMenuItem(title: "诊断：无守护进程 · 锁屏停采", action: nil, keyEquivalent: "")
        diag.isEnabled = false; moreMenu.addItem(diag)
        moreMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; quitItem.isEnabled = true; moreMenu.addItem(quitItem)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        if event.type == .rightMouseUp { showPrefsMenu(relativeTo: sender.bounds, of: sender) }
        else { togglePopover() }
    }
    @objc private func showPrefsFromMore(_ sender: NSMenuItem) {
        guard let button = statusItem.button else { return }
        showPrefsMenu(relativeTo: button.bounds, of: button)
    }
    private func showMoreMenu(from btn: NSButton) {
        moreMenu.popUp(positioning: nil, at: NSPoint(x: btn.bounds.minX, y: btn.bounds.minY), in: btn)
    }
    private func showPrefsMenu(relativeTo rect: NSRect, of view: NSView) {
        rebuildOrderMenu()
        for (key, mi) in showMenuItems { mi.state = isShow(key) ? .on : .off }
        prefsMenu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: view)
    }
    private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            isPanelOpen = true; applyThrottle(); updateMetrics()
        }
    }
    private func installClickOutsideMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.popover.isShown && self.isPanelOpen { self.isPanelOpen = false; self.applyThrottle() }
            }
        }
    }
    private func seedDefaultsIfNeeded() {
        let migrateKey = prefsPrefix + "v18Defaults"
        if prefs.object(forKey: migrateKey) == nil {
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.cpu.rawValue)
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.mem.rawValue)
            for k in [StatusShowKey.gpu, .chip, .fan, .disk, .net] {
                prefs.set(false, forKey: prefsPrefix + k.rawValue)
            }
            prefs.set(StatusShowKey.allCases.map(\.rawValue), forKey: orderKey)
            prefs.set(true, forKey: migrateKey)
        }
        // v1.9.1: menubar default = CPU · 内存 · 温度 · 网络
        let migrate191 = prefsPrefix + "v191MenubarDefaults"
        if prefs.object(forKey: migrate191) == nil {
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.cpu.rawValue)
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.mem.rawValue)
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.chip.rawValue)
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.net.rawValue)
            let order: [StatusShowKey] = [.cpu, .mem, .chip, .net, .gpu, .fan, .disk]
            prefs.set(order.map(\.rawValue), forKey: orderKey)
            prefs.set(true, forKey: migrate191)
        }
        for key in StatusShowKey.allCases {
            let k = prefsPrefix + key.rawValue
            if prefs.object(forKey: k) == nil { prefs.set(key.defaultOn, forKey: k) }
        }
        if prefs.object(forKey: orderKey) == nil {
            let order: [StatusShowKey] = [.cpu, .mem, .chip, .net, .gpu, .fan, .disk]
            prefs.set(order.map(\.rawValue), forKey: orderKey)
        }
    }
    private func isShow(_ key: StatusShowKey) -> Bool { prefs.bool(forKey: prefsPrefix + key.rawValue) }
    private func statusOrder() -> [StatusShowKey] {
        let raw = (prefs.array(forKey: orderKey) as? [String]) ?? StatusShowKey.allCases.map(\.rawValue)
        var seen = Set<StatusShowKey>(); var out: [StatusShowKey] = []
        for s in raw { if let k = StatusShowKey(rawValue: s), !seen.contains(k) { out.append(k); seen.insert(k) } }
        for k in StatusShowKey.allCases where !seen.contains(k) { out.append(k) }
        return out
    }
    private func saveOrder(_ keys: [StatusShowKey]) { prefs.set(keys.map(\.rawValue), forKey: orderKey) }
    private func rebuildOrderMenu() {
        orderMenu.removeAllItems()
        let order = statusOrder()
        for (i, key) in order.enumerated() {
            let mi = NSMenuItem(title: key.title, action: nil, keyEquivalent: "")
            mi.isEnabled = false; orderMenu.addItem(mi)
            let up = NSMenuItem(title: "↑ 上移", action: #selector(moveOrderUp(_:)), keyEquivalent: "")
            up.target = self; up.representedObject = key.rawValue; up.isEnabled = i > 0; orderMenu.addItem(up)
            let down = NSMenuItem(title: "↓ 下移", action: #selector(moveOrderDown(_:)), keyEquivalent: "")
            down.target = self; down.representedObject = key.rawValue; down.isEnabled = i < order.count - 1; orderMenu.addItem(down)
            orderMenu.addItem(.separator())
        }
    }
    @objc private func moveOrderUp(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        var order = statusOrder(); guard let i = order.firstIndex(of: key), i > 0 else { return }
        order.swapAt(i, i-1); saveOrder(order); rebuildOrderMenu()
        applyStatusItemLength(forPreviewTitle: longestTitleSample()); updateMetrics()
    }
    @objc private func moveOrderDown(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        var order = statusOrder(); guard let i = order.firstIndex(of: key), i < order.count-1 else { return }
        order.swapAt(i, i+1); saveOrder(order); rebuildOrderMenu()
        applyStatusItemLength(forPreviewTitle: longestTitleSample()); updateMetrics()
    }
    @objc private func toggleShow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        let on = isShow(key)
        if on {
            let othersOn = StatusShowKey.allCases.filter { $0 != key && isShow($0) }
            if othersOn.isEmpty { return }
        }
        prefs.set(!on, forKey: prefsPrefix + key.rawValue)
        sender.state = !on ? .on : .off
        applyStatusItemLength(forPreviewTitle: longestTitleSample()); updateMetrics()
    }
    @objc private func quit() { popover?.performClose(nil); NSApp.terminate(nil) }
    private func installLifecycleObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(onWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(onDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onScreenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    @objc private func onWillSleep() { isSleeping = true; applyThrottle() }
    @objc private func onDidWake() {
        isSleeping = false; lastNetBytes = nil; lastCPUTicks = nil
        applyThrottle(); refreshTempsAsync(force: true); updateMetrics()
    }
    @objc private func onScreenLocked() { isScreenLocked = true; applyThrottle() }
    @objc private func onScreenUnlocked() { isScreenLocked = false; applyThrottle(); updateMetrics() }
    func menuWillOpen(_ menu: NSMenu) {}
    func menuDidClose(_ menu: NSMenu) {}
    private func desiredInterval() -> TimeInterval? {
        if isSleeping || isScreenLocked { return nil }
        return isPanelOpen ? menuOpenInterval : idleInterval
    }
    private func applyThrottle() {
        if let iv = desiredInterval() { restartTimer(interval: iv) }
        else { timer?.invalidate(); timer = nil }
    }
    private func restartTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.updateMetrics() }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }
    private func longestTitleSample() -> String {
        var parts: [String] = []
        for key in statusOrder() where isShow(key) {
            switch key {
            case .cpu: parts.append("CPU 100%")
            case .gpu: parts.append("GPU 100%")
            case .mem: parts.append("内存 100%")
            case .chip: parts.append("温度 999 °C")  // reserve 3-digit temp
            case .fan: parts.append("扇 9999 RPM")
            case .disk: parts.append("盘 100%")
            case .net: parts.append("↓999.9 MB/s ↑999.9 MB/s")  // reserve peak rate width
            }
        }
        if parts.isEmpty { parts.append("—") }
        return " " + parts.joined(separator: " · ")
    }
    private func applyStatusItemLength(forPreviewTitle sample: String) {
        let textWidth = (sample as NSString).size(withAttributes: [.font: titleFont]).width
        statusItem.length = ceil(textWidth + 16 + 6)
    }
    private func buildTitle(cpuI: Int, gpuI: Int?, memI: Int, chipStr: String, fanRpm: Int?, diskI: Int, down: String, up: String) -> String {
        var parts: [String] = []
        for key in statusOrder() where isShow(key) {
            switch key {
            case .cpu: parts.append(String(format: "CPU %3d%%", cpuI))
            case .gpu: parts.append(gpuI.map { String(format: "GPU %3d%%", $0) } ?? "GPU  --")
            case .mem: parts.append(String(format: "内存 %3d%%", memI))
            case .chip: parts.append("温度 \(chipStr)")
            case .fan: parts.append(fanRpm.map { String(format: "扇 %4d RPM", min(9999,$0)) } ?? "扇  --")
            case .disk: parts.append(String(format: "盘 %3d%%", diskI))
            case .net: parts.append("↓\(down) ↑\(up)")
            }
        }
        return parts.isEmpty ? " —" : " " + parts.joined(separator: " · ")
    }

    private func updateMetrics() {
        if isSleeping || isScreenLocked { return }
        let cpu = sampleCPU()
        let mem = sampleMemory()
        let disk = sampleDisk()
        let thermal = sampleThermal()
        _ = sampleNetwork()
        let swap = sampleSwap()
        tempLock.lock()
        let gpuPct = cachedGpuPct
        let pe = cachedPE
        tempLock.unlock()
        let procs = aggregateByApp(sampleProcessesRaw())
        let sorted: [AggProc] = panel.sortByCPU
            ? procs.sorted { $0.cpuPercent > $1.cpuPercent }
            : procs.sorted { $0.footprint > $1.footprint }
        let top = Array(sorted.prefix(panel.topRows.count))
        let cpuI = min(100, max(0, Int(cpu.rounded())))
        let memI = min(100, max(0, Int(mem.usedPercent.rounded())))
        let diskI = min(100, max(0, Int(disk.usedPercent.rounded())))
        let gpuI = gpuPct.map { min(100, max(0, Int($0.rounded()))) }
        let chipStr: String
        if let c = thermal.chipC {
            // "31 °C" with space; pad to 3 digits width for stable menubar length
            chipStr = String(format: "%3d °C", min(999, max(0, Int(c.rounded()))))
        } else { chipStr = " -- °C" }
        statusItem.button?.title = buildTitle(
            cpuI: cpuI, gpuI: gpuI, memI: memI, chipStr: chipStr,
            fanRpm: thermal.fanRpm, diskI: diskI,
            down: formatRateShort(netDownBps), up: formatRateShort(netUpBps)
        )
        refreshTempsAsync(force: false)
        guard isPanelOpen || popover?.isShown == true else { return }

        let uptime = formatUptime(ProcessInfo.processInfo.systemUptime)
        panel.subtitleLabel.stringValue = "\(chipName) · \(memTotalGB) · 已运行 \(uptime)"
        panel.thermalBadge.stringValue = thermal.pressureLabel
        panel.thermalBadge.textColor = .labelColor
        let dotColor: NSColor
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: dotColor = .systemGreen
        case .fair: dotColor = .systemYellow
        case .serious, .critical: dotColor = .systemOrange
        @unknown default: dotColor = .tertiaryLabelColor
        }
        panel.thermalDot.layer?.backgroundColor = dotColor.cgColor
        panel.thermalDot.isHidden = thermal.pressureLabel.isEmpty

        panel.cpuRow.valueLabel.stringValue = String(format: "%d%%", cpuI)
        panel.cpuRow.valueLabel.textColor = .labelColor
        panel.cpuRow.track.set(Double(cpuI))
        var loads = [Double](repeating: 0, count: 3)
        _ = loads.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        let cpuShort = String(format: "用户 %.0f%% · 系统 %.0f%%", lastCPUUserSys.user, lastCPUUserSys.system)
        let cpuLong = String(
            format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f · P %.0f%% · E %.0f%%",
            lastCPUUserSys.user, lastCPUUserSys.system, loads[0], pe.p * 100, pe.e * 100
        )
        panel.cpuRow.detailLabel.stringValue = panel.cpuRow.detailExpanded ? cpuLong : cpuShort

        let usedGB = Double(mem.used) / 1_073_741_824.0
        let totalGBNum = Double(mem.total) / 1_073_741_824.0
        let totalGBStr = totalGBNum >= 100 ? String(format: "%.0f GB", totalGBNum) : String(format: "%.0f GB", totalGBNum)
        // Main value: percent only; capacity + pressure on the line below
        panel.memRow.valueLabel.stringValue = String(format: "%d%%", memI)
        panel.memRow.valueLabel.textColor = .labelColor
        panel.memRow.usesSegments = panel.memRow.detailExpanded
        if panel.memRow.detailExpanded {
            panel.memRow.segments.set(parts: [
                (Double(mem.app), NSColor.systemBlue),
                (Double(mem.wired), NSColor.systemPurple),
                (Double(mem.compressed), NSColor.systemOrange)
            ], total: Double(mem.total))
        } else {
            panel.memRow.track.set(Double(memI))
        }
        let pressure: String
        if memI < 70 { pressure = "正常" }
        else if memI < 85 { pressure = "偏高" }
        else { pressure = "紧张" }
        let memShort = String(format: "%.1f / %@ · 内存压力%@", usedGB, totalGBStr, pressure)
        let memLong = String(
            format: "应用 %@ · 联动 %@ · 压缩 %@ · 交换 %@",
            formatBytes(mem.app), formatBytes(mem.wired), formatBytes(mem.compressed), formatBytes(swap)
        )
        panel.memRow.detailLabel.stringValue = panel.memRow.detailExpanded ? memLong : memShort

        if let g = gpuI {
            panel.gpuRow.valueLabel.stringValue = String(format: "%d%%", g)
            panel.gpuRow.track.set(Double(g))
        } else {
            panel.gpuRow.valueLabel.stringValue = "未支持"
            panel.gpuRow.track.set(0)
        }
        panel.gpuRow.valueLabel.textColor = .labelColor

        // Prefer CPU sensor for "CPU 温度"; fall back to chip
        if let c = thermal.cpuC ?? thermal.chipC {
            panel.tempCell.setValue(String(format: "%.0f", c), unit: "°C")
        } else {
            panel.tempCell.setValue("读取中…", unit: "")
        }
        if let rpm = thermal.fanRpm {
            panel.fanCell.setValue("\(rpm)", unit: "RPM")
        } else {
            panel.fanCell.setValue("无读数", unit: "")
        }

        if disk.total == 0 {
            panel.diskRow.valueLabel.stringValue = "读取失败"
            panel.diskRow.track.set(0)
        } else {
            panel.diskRow.valueLabel.stringValue = String(
                format: "%d%% · %@ / %@",
                diskI, formatBytes(disk.used), formatBytes(disk.total)
            )
            panel.diskRow.track.set(Double(diskI), warnAt: 80, criticalAt: 92)
        }
        panel.netRow.valueLabel.stringValue = "↓\(formatRate(netDownBps))  ↑\(formatRate(netUpBps))"

        for (i, row) in panel.topRows.enumerated() {
            if i < top.count {
                let p = top[i]
                row.nameLabel.stringValue = p.name
                row.cpuLabel.stringValue = String(format: "%.1f%%", p.cpuPercent)
                row.memLabel.stringValue = formatBytes(p.footprint)
                row.pid = p.mainPid
                row.isHidden = false
                row.setIcon(iconFor(appKey: p.appKey))
                row.onMenu = { [weak self] in self?.confirmKill(pid: p.mainPid, name: p.name) }
            } else {
                row.isHidden = true
                row.pid = 0
                row.onMenu = nil
            }
        }
    }

    private func iconFor(appKey: String) -> NSImage? {
        if let cached = iconCache[appKey] { return cached }
        var path = appKey
        if let range = path.range(of: ".app") { path = String(path[..<range.upperBound]) }
        let img: NSImage
        if path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
            img = NSWorkspace.shared.icon(forFile: path)
        } else if appKey.hasPrefix("/System") || appKey.hasPrefix("/usr") || appKey.hasPrefix("/bin") || appKey.hasPrefix("/sbin") {
            img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        } else {
            img = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[appKey] = img
        if iconCache.count > 200 { iconCache.removeAll(keepingCapacity: true) }
        return img
    }

    private func formatUptime(_ sec: TimeInterval) -> String {
        let s = Int(sec); let d = s / 86400; let h = (s % 86400) / 3600; let m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)时" }
        if h > 0 { return "\(h)时\(m)分" }
        return "\(m)分"
    }
    private func confirmKill(pid: Int32, name: String) {
        let alert = NSAlert()
        alert.messageText = "结束进程？"
        alert.informativeText = "\(name) (pid \(pid))"; alert.alertStyle = .warning
        alert.addButton(withTitle: "结束"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { kill(pid, SIGTERM) }
    }

    private struct ThermalInfo {
        var chipC: Double?; var chipSensor: String?
        var cpuC: Double?; var gpuC: Double?; var fanRpm: Int?; var pressureLabel: String
    }
    private func sampleThermal() -> ThermalInfo {
        let pressure: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "温控正常"
            case .fair: return "温控一般"
            case .serious: return "温控偏高"
            case .critical: return "温控危急"
            @unknown default: return "温控未知"
            }
        }()
        tempLock.lock(); let cpu = cachedCpuC; let gpu = cachedGpuC; let fan = cachedFanRpm; tempLock.unlock()
        var chip: Double? = nil; var sensor: String? = nil
        switch (cpu, gpu) {
        case let (c?, g?): if g >= c { chip = g; sensor = "GPU" } else { chip = c; sensor = "CPU" }
        case let (c?, nil): chip = c; sensor = "CPU"
        case let (nil, g?): chip = g; sensor = "GPU"
        default: break
        }
        return ThermalInfo(chipC: chip, chipSensor: sensor, cpuC: cpu, gpuC: gpu, fanRpm: fan, pressureLabel: pressure)
    }

    private func refreshTempsAsync(force: Bool) {
        tempLock.lock(); let busy = tempRefreshInFlight
        if busy && !force { tempLock.unlock(); return }
        tempRefreshInFlight = true; tempLock.unlock()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.tempLock.lock(); self?.tempRefreshInFlight = false; self?.tempLock.unlock() }
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: self.macmonPath)
            proc.arguments = ["pipe", "-s", "1", "-i", "200"]
            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe; proc.standardError = errPipe
            do { try proc.run() } catch { return }
            proc.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard proc.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first,
                  let jsonData = String(line).data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else { return }
            var cpu: Double? = nil; var gpu: Double? = nil
            if let temp = obj["temp"] as? [String: Any] {
                if let v = temp["cpu_temp_avg"] as? Double, v.isFinite, v > 0, v < 150 { cpu = v }
                if let v = temp["gpu_temp_avg"] as? Double, v.isFinite, v > 0, v < 150 { gpu = v }
            }
            var fanRpm: Int? = nil; var fanMax: Int? = nil; var fanCount = 0
            if let fans = obj["fans"] as? [[String: Any]] {
                fanCount = fans.count; var best = 0; var bestMax = 0
                for f in fans {
                    let rpm: Int
                    if let r = f["rpm"] as? Int { rpm = r }
                    else if let r = f["rpm"] as? Double { rpm = Int(r.rounded()) }
                    else { continue }
                    if rpm > best { best = rpm }
                    if let m = f["max_rpm"] as? Int { bestMax = max(bestMax, m) }
                    else if let m = f["max_rpm"] as? Double { bestMax = max(bestMax, Int(m.rounded())) }
                }
                if best > 0 { fanRpm = best }
                if bestMax > 0 { fanMax = bestMax }
            }
            var gpuPct: Double? = nil
            if let r = obj["gpu_active_ratio"] as? Double, r.isFinite { gpuPct = min(100, max(0, r * 100.0)) }
            var pRatio = 0.0, eRatio = 0.0, sRatio = 0.0
            if let tiers = obj["cpu_tiers"] as? [[String: Any]] {
                for tier in tiers {
                    let label = (tier["label"] as? String) ?? ""
                    switch label {
                    case "E": eRatio = (tier["active_ratio"] as? Double) ?? 0
                    case "P": pRatio = (tier["active_ratio"] as? Double) ?? 0
                    case "S": sRatio = (tier["active_ratio"] as? Double) ?? 0
                    default: break
                    }
                }
            }
            self.tempLock.lock()
            self.cachedCpuC = cpu; self.cachedGpuC = gpu; self.cachedFanRpm = fanRpm
            self.cachedFanMax = fanMax; self.cachedFanCount = fanCount; self.cachedGpuPct = gpuPct
            self.cachedPE = (pRatio, eRatio, sRatio)
            self.tempLock.unlock()
        }
    }

    private func sampleNetwork() -> (down: Double, up: Double) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return (netDownBps, netUpBps) }
        defer { freeifaddrs(ifaddr) }
        var inB: UInt64 = 0; var outB: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoop = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoop, let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                if let data = p.pointee.ifa_data {
                    let ifd = data.assumingMemoryBound(to: if_data.self).pointee
                    inB += UInt64(ifd.ifi_ibytes); outB += UInt64(ifd.ifi_obytes)
                }
            }
            ptr = p.pointee.ifa_next
        }
        netLifetime = (inB, outB)
        if netSessionStart == nil { netSessionStart = (inB, outB) }
        let wall = ProcessInfo.processInfo.systemUptime
        if let last = lastNetBytes {
            let dt = wall - last.wall
            if dt > 0.2 {
                let dIn = inB >= last.inB ? inB - last.inB : 0
                let dOut = outB >= last.outB ? outB - last.outB : 0
                netDownBps = Double(dIn) / dt; netUpBps = Double(dOut) / dt
            }
        }
        lastNetBytes = (inB, outB, wall)
        return (netDownBps, netUpBps)
    }
    private func formatRate(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024*1024 { return String(format: "%.1f KB/s", bps/1024) }
        if bps < 1024*1024*1024 { return String(format: "%.1f MB/s", bps/(1024*1024)) }
        return String(format: "%.2f GB/s", bps/(1024*1024*1024))
    }
    private func formatRateShort(_ bps: Double) -> String {
        // Menubar: full units with space; fixed fractional digits to reduce jitter
        if bps < 1024 { return String(format: "%5.0f B/s", bps) }
        if bps < 1024*1024 { return String(format: "%5.1f KB/s", bps/1024) }
        if bps < 1024*1024*1024 { return String(format: "%5.1f MB/s", bps/(1024*1024)) }
        return String(format: "%5.2f GB/s", bps/(1024*1024*1024))
    }
    private func sampleCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            user += UInt64(cpuInfo[offset + Int(CPU_STATE_USER)])
            system += UInt64(cpuInfo[offset + Int(CPU_STATE_SYSTEM)])
            idle += UInt64(cpuInfo[offset + Int(CPU_STATE_IDLE)])
            nice += UInt64(cpuInfo[offset + Int(CPU_STATE_NICE)])
        }
        defer { lastCPUTicks = (user, system, idle, nice) }
        guard let last = lastCPUTicks else { return 0 }
        let total = (user - last.user) + (system - last.system) + (idle - last.idle) + (nice - last.nice)
        guard total > 0 else { return 0 }
        let u = Double((user - last.user) + (nice - last.nice)) / Double(total) * 100.0
        let s = Double(system - last.system) / Double(total) * 100.0
        lastCPUUserSys = (u, s)
        return (u + s)
    }
    private struct MemInfo { var total, used, app, wired, compressed, cached: UInt64; var usedPercent: Double }
    private func sampleMemory() -> MemInfo {
        var totalSize: UInt64 = 0; var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &totalSize, &len, nil, 0)
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize: vm_size_t = 0; host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        guard kr == KERN_SUCCESS else {
            return MemInfo(total: totalSize, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, usedPercent: 0)
        }
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = UInt64(stats.external_page_count) * page
        let used = app + wired + compressed
        let pct = totalSize > 0 ? Double(used) / Double(totalSize) * 100.0 : 0
        return MemInfo(total: totalSize, used: used, app: app, wired: wired, compressed: compressed, cached: cached, usedPercent: pct)
    }
    private func sampleSwap() -> UInt64 {
        var xsw = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        let r = sysctlbyname("vm.swapusage", &xsw, &size, nil, 0)
        return r == 0 ? UInt64(xsw.xsu_used) : 0
    }
    private struct DiskInfo { var total, used: UInt64; var usedPercent: Double }
    private func sampleDisk() -> DiskInfo {
        do {
            let vals = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ])
            let total = UInt64(vals.volumeTotalCapacity ?? 0)
            let avail: UInt64
            if let important = vals.volumeAvailableCapacityForImportantUsage { avail = UInt64(important) }
            else { avail = UInt64(vals.volumeAvailableCapacity ?? 0) }
            let used = total > avail ? total - avail : 0
            let pct = total > 0 ? Double(used)/Double(total)*100.0 : 0
            return DiskInfo(total: total, used: used, usedPercent: pct)
        } catch { return DiskInfo(total: 0, used: 0, usedPercent: 0) }
    }

    private struct ProcRow {
        var pid: Int32; var name: String; var appKey: String; var footprint: UInt64; var cpuPercent: Double
    }
    private struct AggProc {
        var name: String; var mainPid: Int32; var appKey: String; var footprint: UInt64; var cpuPercent: Double
    }
    private func sampleProcessesRaw() -> [ProcRow] {
        let wall = ProcessInfo.processInfo.systemUptime
        let pids = listAllPIDs()
        var rows: [ProcRow] = []; rows.reserveCapacity(256)
        var nextCPU: [Int32: (cpu: Double, wall: TimeInterval)] = [:]
        let selfPid = getpid()
        for pid in pids {
            if pid <= 0 || pid == selfPid { continue }
            let footprint = hw_phys_footprint(pid)
            if footprint < 2 * 1024 * 1024 { continue }
            var taskInfo = proc_taskinfo()
            let tiSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            var cpuSec: Double = 0
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, tiSize) == tiSize {
                cpuSec = Double(taskInfo.pti_total_user + taskInfo.pti_total_system) / Double(NSEC_PER_SEC)
            }
            var cpuPct: Double = 0
            if let prev = lastProcCPU[pid] {
                let dCPU = cpuSec - prev.cpu; let dWall = wall - prev.wall
                if dWall > 0, dCPU >= 0 { cpuPct = dCPU / dWall * 100.0 }
            }
            nextCPU[pid] = (cpuSec, wall)
            let (name, appKey) = friendlyNameAndKey(for: pid)
            rows.append(ProcRow(pid: pid, name: name, appKey: appKey, footprint: footprint, cpuPercent: cpuPct))
        }
        lastProcCPU = nextCPU
        return rows
    }
    private func aggregateByApp(_ rows: [ProcRow]) -> [AggProc] {
        struct Acc { var name: String; var mainPid: Int32; var mainFoot: UInt64; var footprint: UInt64; var cpuPercent: Double; var appKey: String }
        var map: [String: Acc] = [:]
        for r in rows {
            if var a = map[r.appKey] {
                a.footprint += r.footprint; a.cpuPercent += r.cpuPercent
                if r.footprint > a.mainFoot { a.mainFoot = r.footprint; a.mainPid = r.pid; a.name = r.name }
                map[r.appKey] = a
            } else {
                map[r.appKey] = Acc(name: r.name, mainPid: r.pid, mainFoot: r.footprint, footprint: r.footprint, cpuPercent: r.cpuPercent, appKey: r.appKey)
            }
        }
        return map.values.map { AggProc(name: $0.name, mainPid: $0.mainPid, appKey: $0.appKey, footprint: $0.footprint, cpuPercent: $0.cpuPercent) }
    }
    private func listAllPIDs() -> [Int32] {
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bufSize) / MemoryLayout<Int32>.stride)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufSize)
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<Int32>.stride))
    }
    private func friendlyNameAndKey(for pid: Int32) -> (String, String) {
        var pathBuf = [CChar](repeating: 0, count: 4 * 1024)
        if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 {
            let path = String(cString: pathBuf)
            if let range = path.range(of: ".app/") {
                let appRoot = String(path[..<range.upperBound].dropLast())
                let name = displayName(fromAppPath: path) ?? URL(fileURLWithPath: appRoot).deletingPathExtension().lastPathComponent
                return (name, appRoot)
            }
            if path.hasSuffix(".app") {
                let name = displayName(fromAppPath: path) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                return (name, path)
            }
            let base = URL(fileURLWithPath: path).lastPathComponent
            if let cached = displayNameCache[path] { return (cached, path) }
            displayNameCache[path] = base
            return (base, path)
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            let n = String(cString: nameBuf); return (n, "name:\(n)")
        }
        return ("pid \(pid)", "pid:\(pid)")
    }
    private func displayName(fromAppPath path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            if path.hasSuffix(".app") { return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
            return nil
        }
        let appRoot = String(path[..<range.upperBound].dropLast())
        if let cached = displayNameCache[appRoot] { return cached }
        let infoURL = URL(fileURLWithPath: appRoot).appendingPathComponent("Contents/Info.plist")
        var name: String? = nil
        if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
            if let display = dict["CFBundleDisplayName"] as? String, !display.isEmpty { name = display }
            else if let bundleName = dict["CFBundleName"] as? String, !bundleName.isEmpty { name = bundleName }
        }
        name = name ?? URL(fileURLWithPath: appRoot).deletingPathExtension().lastPathComponent
        displayNameCache[appRoot] = name!
        if displayNameCache.count > 800 { displayNameCache.removeAll(keepingCapacity: true) }
        return name
    }
    private func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes); var idx = 0
        while value >= 1024 && idx < units.count - 1 { value /= 1024; idx += 1 }
        if idx == 0 { return String(format: "%.0f %@", value, units[idx]) }
        // GB/TB: one decimal when under 100; MB/KB: whole numbers (avoid 28.0 MB)
        if idx >= 3 {
            if value >= 100 { return String(format: "%.0f %@", value, units[idx]) }
            return String(format: "%.1f %@", value, units[idx])
        }
        return String(format: "%.0f %@", value.rounded(), units[idx])
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) { isPanelOpen = false; applyThrottle() }
    func popoverWillShow(_ notification: Notification) {
        isPanelOpen = true
        // Default collapsed: percent + short captions; color mem breakdown only when expanded
        panel.cpuRow.setExpanded(false)
        panel.memRow.setExpanded(false)
        panel.memRow.usesSegments = false
        applyThrottle()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
