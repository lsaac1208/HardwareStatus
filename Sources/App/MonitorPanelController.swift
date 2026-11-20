import Cocoa

// MARK: - Root panel
/// Control Center-style hardware status popover with progressive Liquid Glass cards (macOS 26+),
/// structured expandable detail rows, live sparklines, hover-reveal process actions, and an
/// in-panel slide-over Settings view.
final class MonitorPanelController: NSViewController {
    let scroll = NSScrollView()
    let doc = FlippedView()
    let stack = NSStackView()
    let settingsView = SettingsView()

    let titleLabel = makeLabel("系统状态", font: HIG.title)
    let subtitleLabel = makeLabel("", font: HIG.subtitle, color: HIG.mutedInk)
    let thermalPill = StatusPill()

    let cpuRow = MetricRow(symbol: "cpu", title: "CPU", tint: HIG.tintCPU, showsSparkline: true)
    let cpuDetail = CPUTiersDetailView()
    let memRow = MetricRow(symbol: "memorychip", title: "内存", tint: HIG.tintMem)
    let memDetail = MemGridDetailView()
    let gpuRow = MetricRow(symbol: "cube.transparent", title: "GPU", tint: HIG.tintGPU, showsSparkline: true)
    let gpuDetail = GPUDetailView()

    let tempCell = StatTile(symbol: "thermometer.medium", title: "CPU 温度", tint: HIG.tintTemp)
    let fanCell = StatTile(symbol: "fan", title: "风扇转速", tint: HIG.tintFan)
    let diskRow = IORow(symbol: "internaldrive", title: "存储", tint: HIG.tintDisk)
    let netRow = IORow(symbol: "network", title: "网络", tint: HIG.tintNet, showsNetSparkline: true)
    let sortHeader = SortHeader()
    var topRows: [AppProcRow] = []

    let footer = NSView()
    let activityBtn = FooterButton(title: "活动监视器", image: MonitorPanelController.activityIcon())
    let settingsBtn = FooterButton(title: "设置", image: symbol("slider.horizontal.3", size: 12))
    let moreButton = FooterButton(title: "更多", image: symbol("ellipsis.circle", size: 12))

    private var monitorHost: GlassStackHost!
    private var monitorBottom: NSLayoutConstraint!
    private var settingsBottom: NSLayoutConstraint!

    var sortByCPU = true
    private(set) var isShowingSettings = false

    var onUIStateChanged: (() -> Void)?
    var onOpenActivity: (() -> Void)?
    var onMoreMenu: ((NSButton) -> Void)?
    var onSettingsVisibilityChanged: ((Bool) -> Void)?
    var onPreferredSizeChange: ((NSSize, Bool) -> Void)?

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

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, subtitleLabel, thermalPill].forEach(header.addSubview)
        subtitleLabel.font = HIG.subtitle
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

        // Resources card (all three rows expandable & right-aligned)
        cpuRow.setExpandedView(cpuDetail)
        memRow.setExpandedView(memDetail)
        gpuRow.setExpandedView(gpuDetail)

        for m in [cpuRow, memRow, gpuRow] {
            m.enableDetail(true)
            m.alwaysShowDetail = true
            m.setExpanded(false)
            m.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
            m.onToggleDetail = { [weak self] in
                guard let self = self else { return }
                self.needsFit = true
                self.onUIStateChanged?()
                self.fitToContentIfNeeded(animated: true)
            }
            m.onHeightChange = { [weak self] in self?.needsFit = true }
        }
        let resSeps = (0..<2).map { _ in Hairline(inset: HIG.rowSeparatorInset) }
        resSeps.forEach { $0.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true }
        let resources = CardView([cpuRow, resSeps[0], memRow, resSeps[1], gpuRow], spacing: HIG.rowGap)

        // Thermal & Fan dual tiles
        let thermo = NSStackView(views: [tempCell, fanCell])
        thermo.orientation = .horizontal
        thermo.distribution = .fillEqually
        thermo.spacing = HIG.cardGap
        thermo.translatesAutoresizingMaskIntoConstraints = false
        fanCell.onTap = { [weak self] in self?.setShowingSettings(true, animated: true) }

        // IO card
        netRow.showsTrack = false
        for r in [diskRow, netRow] { r.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true }
        let ioSep = Hairline(inset: HIG.rowSeparatorInset)
        ioSep.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        let io = CardView([diskRow, ioSep, netRow], spacing: HIG.rowGap)

        // Process card
        sortHeader.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        sortHeader.onSortCPU = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = true; self.sortHeader.sortByCPU = true; self.onUIStateChanged?()
        }
        sortHeader.onSortMem = { [weak self] in
            guard let self = self else { return }
            self.sortByCPU = false; self.sortHeader.sortByCPU = false; self.onUIStateChanged?()
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
        procs.stack.setCustomSpacing(4, after: sortHeader)
        procs.stack.setCustomSpacing(4, after: headLine)

        for v in [resources, thermo, io, procs] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: HIG.contentW).isActive = true
        }
        [header, resources, thermo, io, procs].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(HIG.headerGap, after: header)

        monitorHost = GlassStackHost(content: stack)
        settingsView.isHidden = true
        settingsView.onBack = { [weak self] in self?.setShowingSettings(false, animated: true) }

        doc.addSubview(monitorHost)
        doc.addSubview(settingsView)
        scroll.documentView = doc

        let clip = scroll.contentView
        monitorBottom = monitorHost.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -HIG.outerBottom)
        settingsBottom = settingsView.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -HIG.outerBottom)
        monitorBottom.isActive = true
        settingsBottom.isActive = false

        NSLayoutConstraint.activate([
            monitorHost.topAnchor.constraint(equalTo: doc.topAnchor, constant: HIG.outerTop),
            monitorHost.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: HIG.outerX),
            monitorHost.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -HIG.outerX),
            monitorHost.widthAnchor.constraint(equalToConstant: HIG.contentW),
            settingsView.topAnchor.constraint(equalTo: doc.topAnchor, constant: HIG.outerTop),
            settingsView.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: HIG.outerX),
            settingsView.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -HIG.outerX),
            settingsView.widthAnchor.constraint(equalToConstant: HIG.contentW),
            doc.topAnchor.constraint(equalTo: clip.topAnchor),
            doc.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            doc.widthAnchor.constraint(equalToConstant: HIG.panelW)
        ])

        // Footer
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)
        activityBtn.target = self; activityBtn.action = #selector(openActivity)
        settingsBtn.target = self; settingsBtn.action = #selector(toggleSettings)
        moreButton.target = self; moreButton.action = #selector(openMore)
        moreButton.imagePosition = .imageTrailing
        let footLine = Hairline()
        [footLine, activityBtn, settingsBtn, moreButton].forEach(footer.addSubview)
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
            settingsBtn.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -14),
            settingsBtn.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor)
        ])
    }

    /// Restore saved user expand & sort preferences without jarring resets on every open.
    func applySavedUIState(cpuExpanded: Bool, memExpanded: Bool, gpuExpanded: Bool, sortByCPU: Bool) {
        cpuRow.setExpanded(cpuExpanded)
        memRow.setExpanded(memExpanded)
        memRow.usesSegments = memExpanded
        gpuRow.setExpanded(gpuExpanded)
        self.sortByCPU = sortByCPU
        sortHeader.sortByCPU = sortByCPU
        needsFit = true
    }

    func prepareForOpen() {
        if isShowingSettings { setShowingSettings(false, animated: false) }
        topRows.forEach { $0.resetHover() }
        needsFit = true
    }

    func setShowingSettings(_ show: Bool, animated: Bool) {
        if isShowingSettings == show { return }
        isShowingSettings = show
        monitorHost.isHidden = show
        settingsView.isHidden = !show
        monitorBottom.isActive = !show
        settingsBottom.isActive = show
        settingsBtn.contentTintColor = show ? .controlAccentColor : HIG.mutedInk
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        onSettingsVisibilityChanged?(show)
        needsFit = true
        fitToContentIfNeeded(animated: animated)
    }

    func setThermal(_ text: String, color: NSColor, step: Int) { thermalPill.set(text, color: color, step: step) }

    func showProcRows(_ n: Int) {
        if n == visibleProcRows { return }
        visibleProcRows = n
        for (i, row) in topRows.enumerated() {
            row.isHidden = i >= n
            if i >= n { row.pid = 0; row.onMenu = nil; row.toolTip = nil }
        }
        needsFit = true
    }

    func setNeedsFit() { needsFit = true }

    func fitToContentIfNeeded(animated: Bool = false) {
        guard needsFit else { return }
        needsFit = false
        doc.layoutSubtreeIfNeeded()
        let activeStack = isShowingSettings ? settingsView.stack : stack
        let contentH = activeStack.fittingSize.height + HIG.outerTop + HIG.outerBottom + HIG.footerH
        let screenH = view.window?.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        let h = min(max(contentH, HIG.panelMinH), min(HIG.panelMaxH, screenH - 48)).rounded(.up)
        if abs(preferredContentSize.height - h) < 1 { return }
        let size = NSSize(width: HIG.panelW, height: h)
        preferredContentSize = size
        onPreferredSizeChange?(size, animated)
    }

    @objc private func openActivity() { onOpenActivity?() }
    @objc private func toggleSettings() { setShowingSettings(!isShowingSettings, animated: true) }
    @objc private func openMore() { onMoreMenu?(moreButton) }
}
