import Cocoa

struct SettingsState {
    var menubarStyle: MenubarStyle
    var order: [StatusShowKey]
    var visibility: [StatusShowKey: Bool]
    var fanBoostEnabled: Bool
    var fanBoostWritable: Bool
    var fanBoostDetail: String
    var fanThresholdC: Double
    var fanTargetPercent: Double
    var telemetryLabel: String
}

/// Native in-panel settings view: switches menubar style, toggles/reorders menubar metrics in place,
/// and configures thermal fan boost without bouncing through nested top-bar menus.
final class SettingsView: NSView {
    var onBack: (() -> Void)?
    var onStyleChange: ((MenubarStyle) -> Void)?
    var onToggleKey: ((StatusShowKey, Bool) -> Void)?
    var onMoveKey: ((StatusShowKey, Int) -> Void)?
    var onFanBoostToggle: ((Bool) -> Void)?
    var onFanThresholdChange: ((Double) -> Void)?
    var onFanTargetChange: ((Double) -> Void)?

    let stack = NSStackView()
    private let backBtn = FooterButton(title: "返回", image: symbol("chevron.left", size: 11, weight: .semibold))
    private let titleLabel = makeLabel("偏好设置", font: HIG.title)
    private let styleSegment = NSSegmentedControl(labels: ["紧凑双行", "标准单行"], trackingMode: .selectOne, target: nil, action: nil)
    private let itemsStack = NSStackView()
    private let fanSwitch = NSSwitch()
    private let fanStatusLabel = makeLabel("", font: HIG.caption, color: HIG.mutedInk)
    private let thresholdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let telemetryLabel = makeLabel("", font: HIG.caption, color: HIG.mutedInk)

    private var itemRows: [StatusShowKey: ItemRow] = [:]
    private var currentOrder: [StatusShowKey] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HIG.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        backBtn.target = self; backBtn.action = #selector(tapBack)
        [backBtn, titleLabel].forEach(header.addSubview)
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalToConstant: HIG.contentW),
            header.heightAnchor.constraint(equalToConstant: 24),
            backBtn.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: HIG.headerInset - 2),
            backBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])

        // Card 1: Menubar style
        let styleRow = NSView()
        styleRow.translatesAutoresizingMaskIntoConstraints = false
        let styleLbl = makeLabel("菜单栏样式", font: HIG.rowTitle)
        let styleSub = makeLabel("紧凑双行可将网速垂直堆叠，显著节省状态栏宽度", font: HIG.caption, color: HIG.mutedInk)
        styleSegment.controlSize = .small
        styleSegment.segmentStyle = .rounded
        styleSegment.target = self
        styleSegment.action = #selector(styleChanged)
        styleSegment.translatesAutoresizingMaskIntoConstraints = false
        [styleLbl, styleSegment, styleSub].forEach(styleRow.addSubview)
        NSLayoutConstraint.activate([
            styleRow.widthAnchor.constraint(equalToConstant: HIG.cardInnerW),
            styleLbl.leadingAnchor.constraint(equalTo: styleRow.leadingAnchor),
            styleLbl.topAnchor.constraint(equalTo: styleRow.topAnchor, constant: 2),
            styleSegment.trailingAnchor.constraint(equalTo: styleRow.trailingAnchor),
            styleSegment.centerYAnchor.constraint(equalTo: styleLbl.centerYAnchor),
            styleSub.leadingAnchor.constraint(equalTo: styleRow.leadingAnchor),
            styleSub.trailingAnchor.constraint(equalTo: styleRow.trailingAnchor),
            styleSub.topAnchor.constraint(equalTo: styleLbl.bottomAnchor, constant: 6),
            styleSub.bottomAnchor.constraint(equalTo: styleRow.bottomAnchor)
        ])
        let styleCard = CardView([styleRow], spacing: 0)

        // Card 2: Menubar items + reorder
        let itemsHeader = makeLabel("状态栏显示与排序", font: HIG.captionStrong, color: HIG.mutedInk)
        let itemsSep = Hairline()
        itemsSep.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        itemsStack.orientation = .vertical
        itemsStack.alignment = .leading
        itemsStack.spacing = 2
        itemsStack.translatesAutoresizingMaskIntoConstraints = false
        itemsStack.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
        let itemsCard = CardView([itemsHeader, itemsSep, itemsStack], spacing: 6)

        // Card 3: Thermal Fan Boost
        let fanTop = NSView()
        fanTop.translatesAutoresizingMaskIntoConstraints = false
        let fanTitle = makeLabel("超温风扇加速", font: HIG.rowTitle)
        fanSwitch.controlSize = .mini
        fanSwitch.target = self
        fanSwitch.action = #selector(fanToggled)
        fanSwitch.translatesAutoresizingMaskIntoConstraints = false
        fanStatusLabel.maximumNumberOfLines = 2
        fanStatusLabel.lineBreakMode = .byWordWrapping
        [fanTitle, fanSwitch, fanStatusLabel].forEach(fanTop.addSubview)
        NSLayoutConstraint.activate([
            fanTop.widthAnchor.constraint(equalToConstant: HIG.cardInnerW),
            fanTitle.leadingAnchor.constraint(equalTo: fanTop.leadingAnchor),
            fanTitle.topAnchor.constraint(equalTo: fanTop.topAnchor),
            fanSwitch.trailingAnchor.constraint(equalTo: fanTop.trailingAnchor),
            fanSwitch.centerYAnchor.constraint(equalTo: fanTitle.centerYAnchor),
            fanStatusLabel.leadingAnchor.constraint(equalTo: fanTop.leadingAnchor),
            fanStatusLabel.trailingAnchor.constraint(equalTo: fanTop.trailingAnchor),
            fanStatusLabel.topAnchor.constraint(equalTo: fanTitle.bottomAnchor, constant: 4),
            fanStatusLabel.bottomAnchor.constraint(equalTo: fanTop.bottomAnchor)
        ])

        let fanSep = Hairline()
        fanSep.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true

        for c in FanBoostController.thresholdChoices { thresholdPopup.addItem(withTitle: "\(Int(c)) °C") }
        for p in FanBoostController.targetPercentChoices { targetPopup.addItem(withTitle: "\(Int(p))%") }
        for pop in [thresholdPopup, targetPopup] {
            pop.controlSize = .small
            pop.font = HIG.captionMono
            pop.translatesAutoresizingMaskIntoConstraints = false
            pop.target = self
        }
        thresholdPopup.action = #selector(thresholdChanged)
        targetPopup.action = #selector(targetChanged)

        let fanControls = NSView()
        fanControls.translatesAutoresizingMaskIntoConstraints = false
        let tLbl = makeLabel("触发温度", font: HIG.caption, color: HIG.mutedInk)
        let pLbl = makeLabel("目标转速", font: HIG.caption, color: HIG.mutedInk)
        [tLbl, thresholdPopup, pLbl, targetPopup].forEach(fanControls.addSubview)
        NSLayoutConstraint.activate([
            fanControls.widthAnchor.constraint(equalToConstant: HIG.cardInnerW),
            fanControls.heightAnchor.constraint(equalToConstant: 24),
            tLbl.leadingAnchor.constraint(equalTo: fanControls.leadingAnchor),
            tLbl.centerYAnchor.constraint(equalTo: fanControls.centerYAnchor),
            thresholdPopup.leadingAnchor.constraint(equalTo: tLbl.trailingAnchor, constant: 6),
            thresholdPopup.centerYAnchor.constraint(equalTo: fanControls.centerYAnchor),
            targetPopup.trailingAnchor.constraint(equalTo: fanControls.trailingAnchor),
            targetPopup.centerYAnchor.constraint(equalTo: fanControls.centerYAnchor),
            pLbl.trailingAnchor.constraint(equalTo: targetPopup.leadingAnchor, constant: -6),
            pLbl.centerYAnchor.constraint(equalTo: fanControls.centerYAnchor)
        ])
        let fanCard = CardView([fanTop, fanSep, fanControls], spacing: 8)

        // Card 4: Telemetry & power policy info
        let infoRow = NSView()
        infoRow.translatesAutoresizingMaskIntoConstraints = false
        let policyLbl = makeLabel("锁屏 / 休眠自动暂停采样", font: HIG.caption, color: HIG.faintInk)
        [telemetryLabel, policyLbl].forEach(infoRow.addSubview)
        NSLayoutConstraint.activate([
            infoRow.widthAnchor.constraint(equalToConstant: HIG.cardInnerW),
            telemetryLabel.leadingAnchor.constraint(equalTo: infoRow.leadingAnchor),
            telemetryLabel.trailingAnchor.constraint(equalTo: infoRow.trailingAnchor),
            telemetryLabel.topAnchor.constraint(equalTo: infoRow.topAnchor),
            policyLbl.leadingAnchor.constraint(equalTo: infoRow.leadingAnchor),
            policyLbl.trailingAnchor.constraint(equalTo: infoRow.trailingAnchor),
            policyLbl.topAnchor.constraint(equalTo: telemetryLabel.bottomAnchor, constant: 3),
            policyLbl.bottomAnchor.constraint(equalTo: infoRow.bottomAnchor)
        ])
        let infoCard = CardView([infoRow], spacing: 0)

        for v in [styleCard, itemsCard, fanCard, infoCard] as [NSView] {
            v.widthAnchor.constraint(equalToConstant: HIG.contentW).isActive = true
        }
        [header, styleCard, itemsCard, fanCard, infoCard].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(HIG.headerGap, after: header)

        let host = GlassStackHost(content: stack)
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func render(_ state: SettingsState) {
        styleSegment.selectedSegment = state.menubarStyle == .compact ? 0 : 1

        if currentOrder != state.order {
            currentOrder = state.order
            itemsStack.arrangedSubviews.forEach {
                itemsStack.removeArrangedSubview($0)
                $0.removeFromSuperview()
            }
            itemRows.removeAll(keepingCapacity: true)
            for (idx, key) in state.order.enumerated() {
                let row = ItemRow(key: key)
                row.onToggle = { [weak self] on in self?.onToggleKey?(key, on) }
                row.onMove = { [weak self] delta in self?.onMoveKey?(key, delta) }
                row.setBoundsState(isFirst: idx == 0, isLast: idx == state.order.count - 1)
                row.setOn(state.visibility[key] ?? false)
                row.widthAnchor.constraint(equalToConstant: HIG.cardInnerW).isActive = true
                itemRows[key] = row
                itemsStack.addArrangedSubview(row)
            }
        } else {
            for (idx, key) in state.order.enumerated() {
                itemRows[key]?.setBoundsState(isFirst: idx == 0, isLast: idx == state.order.count - 1)
                itemRows[key]?.setOn(state.visibility[key] ?? false)
            }
        }

        fanSwitch.state = state.fanBoostEnabled ? .on : .off
        fanSwitch.isEnabled = state.fanBoostWritable
        thresholdPopup.isEnabled = state.fanBoostWritable
        targetPopup.isEnabled = state.fanBoostWritable
        fanStatusLabel.setText(state.fanBoostDetail)

        if let idx = FanBoostController.thresholdChoices.firstIndex(of: state.fanThresholdC) {
            thresholdPopup.selectItem(at: idx)
        }
        if let idx = FanBoostController.targetPercentChoices.firstIndex(of: state.fanTargetPercent) {
            targetPopup.selectItem(at: idx)
        }
        telemetryLabel.setText(state.telemetryLabel)
    }

    @objc private func tapBack() { onBack?() }
    @objc private func styleChanged() {
        onStyleChange?(styleSegment.selectedSegment == 0 ? .compact : .standard)
    }
    @objc private func fanToggled() {
        onFanBoostToggle?(fanSwitch.state == .on)
    }
    @objc private func thresholdChanged() {
        let idx = thresholdPopup.indexOfSelectedItem
        if idx >= 0 && idx < FanBoostController.thresholdChoices.count {
            onFanThresholdChange?(FanBoostController.thresholdChoices[idx])
        }
    }
    @objc private func targetChanged() {
        let idx = targetPopup.indexOfSelectedItem
        if idx >= 0 && idx < FanBoostController.targetPercentChoices.count {
            onFanTargetChange?(FanBoostController.targetPercentChoices[idx])
        }
    }

    private final class ItemRow: NSView {
        private let titleLabel: NSTextField
        private let upBtn = NSButton()
        private let downBtn = NSButton()
        private let toggle = NSSwitch()
        var onToggle: ((Bool) -> Void)?
        var onMove: ((Int) -> Void)?

        init(key: StatusShowKey) {
            titleLabel = makeLabel(key.title, font: HIG.body)
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = symbol(Self.symbolName(for: key), size: 12, weight: .medium)
            icon.contentTintColor = Self.tintColor(for: key)

            let moveButtons: [(NSButton, String, Selector)] = [
                (upBtn, "chevron.up", #selector(tapMoveUp)),
                (downBtn, "chevron.down", #selector(tapMoveDown))
            ]
            for (btn, name, act) in moveButtons {
                btn.image = symbol(name, size: 10, weight: .semibold)
                btn.isBordered = false
                btn.imagePosition = .imageOnly
                btn.contentTintColor = HIG.mutedInk
                btn.target = self
                btn.action = act
                btn.translatesAutoresizingMaskIntoConstraints = false
            }

            toggle.controlSize = .mini
            toggle.target = self
            toggle.action = #selector(toggled)
            toggle.translatesAutoresizingMaskIntoConstraints = false

            [icon, titleLabel, upBtn, downBtn, toggle].forEach(addSubview)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 26),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
                toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
                downBtn.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
                downBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
                downBtn.widthAnchor.constraint(equalToConstant: 20),
                downBtn.heightAnchor.constraint(equalToConstant: 20),
                upBtn.trailingAnchor.constraint(equalTo: downBtn.leadingAnchor, constant: -2),
                upBtn.centerYAnchor.constraint(equalTo: centerYAnchor),
                upBtn.widthAnchor.constraint(equalToConstant: 20),
                upBtn.heightAnchor.constraint(equalToConstant: 20)
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        func setOn(_ on: Bool) {
            let target: NSControl.StateValue = on ? .on : .off
            if toggle.state != target { toggle.state = target }
        }
        func setBoundsState(isFirst: Bool, isLast: Bool) {
            upBtn.isEnabled = !isFirst
            upBtn.alphaValue = isFirst ? 0.25 : 0.85
            downBtn.isEnabled = !isLast
            downBtn.alphaValue = isLast ? 0.25 : 0.85
        }

        @objc private func toggled() { onToggle?(toggle.state == .on) }
        @objc private func tapMoveUp() { onMove?(-1) }
        @objc private func tapMoveDown() { onMove?(1) }

        private static func symbolName(for key: StatusShowKey) -> String {
            switch key {
            case .cpu: return "cpu"
            case .gpu: return "cube.transparent"
            case .mem: return "memorychip"
            case .chip: return "thermometer.medium"
            case .fan: return "fan"
            case .power: return "bolt.fill"
            case .disk: return "internaldrive"
            case .net: return "network"
            }
        }
        private static func tintColor(for key: StatusShowKey) -> NSColor {
            switch key {
            case .cpu: return HIG.tintCPU
            case .gpu: return HIG.tintGPU
            case .mem: return HIG.tintMem
            case .chip: return HIG.tintTemp
            case .fan: return HIG.tintFan
            case .power: return HIG.warn
            case .disk: return HIG.tintDisk
            case .net: return HIG.tintNet
            }
        }
    }
}
