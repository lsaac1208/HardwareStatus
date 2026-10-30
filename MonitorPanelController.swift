import Cocoa

// MARK: - Root panel
/// Layout (top → bottom), Control Center-style modules on the system popover material:
///   header   系统状态 + thermal pill, chip · RAM · uptime
///   card     CPU / 内存 / GPU metric rows
///   tiles    CPU 温度 | 风扇转速
///   card     存储 / 网络
///   card     占用最高 process table
///   footer   活动监视器 | 更多
/// The popover height follows the content (clamped to the screen), so nothing is clipped
/// behind the footer; the scroll view only matters on very short displays.
final class MonitorPanelController: NSViewController {
    let scroll = NSScrollView()
    let doc = FlippedView()
    let stack = NSStackView()

    let titleLabel = makeLabel("系统状态", font: HIG.title)
    let subtitleLabel = makeLabel("", font: HIG.subtitle, color: .secondaryLabelColor)
    let thermalPill = StatusPill()

    let cpuRow = MetricRow(symbol: "cpu", title: "CPU", tint: HIG.tintCPU)
    let memRow = MetricRow(symbol: "memorychip", title: "内存", tint: HIG.tintMem)
    let gpuRow = MetricRow(symbol: "cube.transparent", title: "GPU", tint: HIG.tintGPU)
    let tempCell = StatTile(symbol: "thermometer.medium", title: "CPU 温度", tint: HIG.tintTemp)
    let fanCell = StatTile(symbol: "fan", title: "风扇转速", tint: HIG.tintFan)
    let diskRow = IORow(symbol: "internaldrive", title: "存储", tint: HIG.tintDisk)
    let netRow = IORow(symbol: "network", title: "网络", tint: HIG.tintNet)
    let sortHeader = SortHeader()
    var topRows: [AppProcRow] = []

    let footer = NSView()
    let activityBtn = FooterButton(title: "活动监视器", image: MonitorPanelController.activityIcon())
    let moreButton = FooterButton(title: "更多", image: symbol("ellipsis.circle", size: 12))

    var sortByCPU = true
    var onSortChanged: (() -> Void)?
    var onOpenActivity: (() -> Void)?
    var onMoreMenu: ((NSButton) -> Void)?
    /// Popover should adopt this size (fires only when the fitted height actually changes).
    var onPreferredSizeChange: ((NSSize) -> Void)?

    private var needsFit = true
    private var visibleProcRows = -1

    private static func activityIcon() -> NSImage? {
        let img = NSWorkspace.shared.icon(forFile: "/System/Applications/Utilities/Activity Monitor.app")
        let copy = img.copy() as! NSImage
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: HIG.panelW, height: HIG.panelH))
        view = root
        preferredContentSize = NSSize(width: HIG.panelW, height: HIG.panelH)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.drawsBackground = false
        root.addSubview(scroll)

        doc.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HIG.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, thermalPill].forEach(header.addSubview)
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)  // uptime ticks
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: HIG.headerInset),
            titleLabel.topAnchor.constraint(equalTo: header.topAnchor),
            thermalPill.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -HIG.headerInset + 2),
            thermalPill.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            thermalPill.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -HIG.headerInset),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            header.widthAnchor.constraint(equalToConstant: HIG.contentW)
        ])

        // Resources card
        cpuRow.enableDetail(true); cpuRow.alwaysShowDetail = true; cpuRow.setExpanded(false)
        memRow.enableDetail(true); memRow.alwaysShowDetail = true; memRow.setExpanded(false)
        gpuRow.enableDetail(false); gpuRow.alwaysShowDetail = true; gpuRow.setExpanded(false)
        for m in [cpuRow, memRow, gpuRow] {
            m.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
            m.onToggleDetail = { [weak self] in self?.onSortChanged?() }
            m.onHeightChange = { [weak self] in self?.needsFit = true }
        }
        let resources = CardView([cpuRow, memRow, gpuRow], spacing: HIG.rowGap)

        // Thermal tiles
        let thermo = NSStackView(views: [tempCell, fanCell])
        thermo.orientation = .horizontal
        thermo.distribution = .fillEqually
        thermo.spacing = HIG.cardGap
        thermo.translatesAutoresizingMaskIntoConstraints = false

        // IO card
        netRow.showsTrack = false
        for r in [diskRow, netRow] { r.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true }
        let io = CardView([diskRow, netRow], spacing: 12)

        // Process card
        sortHeader.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        sortHeader.onSortCPU = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = true; self.sortHeader.sortByCPU = true; self.onSortChanged?()
        }
        sortHeader.onSortMem = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = false; self.sortHeader.sortByCPU = false; self.onSortChanged?()
        }
        let headLine = Hairline()
        headLine.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        var procViews: [NSView] = [sortHeader, headLine]
        for _ in 0..<HIG.procRows {
            let row = AppProcRow()
            row.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
            topRows.append(row)
            procViews.append(row)
        }
        let procs = CardView(procViews, spacing: 0, padding: HIG.cardPad)
        procs.stack.setCustomSpacing(6, after: sortHeader)
        procs.stack.setCustomSpacing(4, after: headLine)

        for v in [resources, thermo, io, procs] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: HIG.contentW).isActive = true
        }
        [header, resources, thermo, io, procs].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(14, after: header)

        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: HIG.outerTop),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: HIG.outerX),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -HIG.outerX),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -HIG.outerBottom),
            stack.widthAnchor.constraint(equalToConstant: HIG.contentW),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalToConstant: HIG.panelW)
        ])

        // Footer
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        activityBtn.target = self; activityBtn.action = #selector(openActivity)
        moreButton.target = self; moreButton.action = #selector(openMore)
        moreButton.imagePosition = .imageTrailing
        footer.addSubview(activityBtn); footer.addSubview(moreButton)
        let footLine = Hairline(); footer.addSubview(footLine)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: HIG.footerH),
            footLine.topAnchor.constraint(equalTo: footer.topAnchor),
            footLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HIG.outerX),
            footLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -HIG.outerX),
            activityBtn.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HIG.outerX + HIG.headerInset),
            activityBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -(HIG.outerX + HIG.headerInset)),
            moreButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])
    }

    /// Popover is about to show: collapsed details, single-color memory bar, fresh fit.
    func resetForOpen() {
        cpuRow.setExpanded(false)
        memRow.setExpanded(false)
        memRow.usesSegments = false
        topRows.forEach { $0.resetHover() }
        needsFit = true
    }

    func setThermal(_ text: String, color: NSColor) { thermalPill.set(text, color: color) }

    /// Show the first `n` process rows; hidden rows collapse in the stack.
    func showProcRows(_ n: Int) {
        if n == visibleProcRows { return }
        visibleProcRows = n
        for (i, row) in topRows.enumerated() {
            row.isHidden = i >= n
            if i >= n { row.pid = 0; row.onMenu = nil }
        }
        needsFit = true
    }

    func setNeedsFit() { needsFit = true }

    /// Resize the popover to the content height. Only does work after something changed
    /// height (expand, GPU caption, row count), not on every tick.
    func fitToContentIfNeeded() {
        guard needsFit else { return }
        needsFit = false
        let contentH = stack.fittingSize.height + HIG.outerTop + HIG.outerBottom + HIG.footerH
        let screenH = view.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        let h = min(max(contentH, HIG.panelMinH), min(HIG.panelMaxH, screenH - 48)).rounded(.up)
        if abs(preferredContentSize.height - h) < 1 { return }
        let size = NSSize(width: HIG.panelW, height: h)
        preferredContentSize = size
        onPreferredSizeChange?(size)
    }

    @objc private func openActivity() { onOpenActivity?() }
    @objc private func openMore() { onMoreMenu?(moreButton) }
}
