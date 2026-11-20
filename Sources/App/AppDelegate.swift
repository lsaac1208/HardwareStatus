import Cocoa
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var panel: MonitorPanelController?
    private var prefsMenu: NSMenu!
    private var moreMenu: NSMenu!
    private var diagMenuItem: NSMenuItem!
    private var fanStatusMenuItem: NSMenuItem!
    private var fanBoostRoot: NSMenuItem!
    private var eventMonitor: Any?
    private var appearanceObs: NSKeyValueObservation?
    private var timer: Timer?

    private let sampler = SystemSampler()
    private let fanBoost = FanBoostController()
    private var snapshot = MetricsSnapshot()
    private var smooth = DisplaySmoothing()

    private let idleInterval: TimeInterval = 2.5
    private let menuOpenInterval: TimeInterval = 1.0
    private let prefs = UserDefaults.standard
    private let prefsPrefix = "local.lsaac128.HardwareStatus."
    private let orderKey = "local.lsaac128.HardwareStatus.statusOrder"
    private let menubarStyleKey = "local.lsaac128.HardwareStatus.menubarStyle"
    private let uiCpuExpandedKey = "local.lsaac128.HardwareStatus.ui.cpuExpanded"
    private let uiMemExpandedKey = "local.lsaac128.HardwareStatus.ui.memExpanded"
    private let uiGpuExpandedKey = "local.lsaac128.HardwareStatus.ui.gpuExpanded"
    private let uiSortByCPUKey = "local.lsaac128.HardwareStatus.ui.sortByCPU"

    private var cpuHistory = HistoryRing(capacity: 36)
    private var gpuHistory = HistoryRing(capacity: 36)
    private var netDownHistory = HistoryRing(capacity: 36)
    private var netUpHistory = HistoryRing(capacity: 36)
    private var lastGpuHistoryWall: TimeInterval?

    private var visibleKeysCache: [StatusShowKey]?
    private var cachedMenubarStyle: MenubarStyle?
    private var lastStatusTitleKey = ""
    private var currentStatusLength: CGFloat = 0
    private var shrinkStreak = 0
    private var showMenuItems: [StatusShowKey: NSMenuItem] = [:]
    private var styleMenuItems: [MenubarStyle: NSMenuItem] = [:]
    private var orderMenu: NSMenu!
    private var iconCache: [String: NSImage] = [:]
    private var activeMenuProc: AggProc?
    private var isScreenLocked = false
    private var isSleeping = false
    private var isPanelOpen = false
    private var isMenubarDark = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedDefaultsIfNeeded()
        startFanBoost()
        buildPrefsMenu()
        buildMoreMenu()
        buildStatusItem()
        installLifecycleObservers()

        sampler.onSensorsUpdated = { [weak self] in
            self?.handleSensorsUpdated()
        }

        // Seed baselines for CPU / network / native sensors
        _ = sampler.sampleCPU()
        _ = sampler.sampleNetwork()
        sampler.refreshSensorsAsync(
            panelVisible: false, visibleKeys: visibleStatusKeys(),
            fanBoostWantsTemp: fanBoost.wantsTemperature, force: true
        )
        updateMetrics()
        restartTimer(interval: idleInterval)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        appearanceObs?.invalidate()
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
        fanBoost.restoreNow()
        sampler.shutdown()
        hw_smc_close()
    }

    private func startFanBoost() {
        fanBoost.onChange = { [weak self] in
            guard let self = self else { return }
            self.renderStatusTitle()
            self.renderPanel()
            if self.panel?.isShowingSettings == true { self.renderSettings() }
        }
        fanBoost.start(onTerminateSignal: { NSApp.terminate(nil) })
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
            button.font = StatusTitle.valueFont
            button.toolTip = "系统状态"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            isMenubarDark = Ink.isDark(button.effectiveAppearance)
            appearanceObs = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] btn, _ in
                guard let self = self else { return }
                let dark = Ink.isDark(btn.effectiveAppearance)
                if dark != self.isMenubarDark {
                    self.isMenubarDark = dark
                    self.renderStatusTitle()
                }
            }
        }
        let initialAttr = StatusTitle.attributed(buildTitleSegments(), dark: isMenubarDark, style: menubarStyle)
        updateStatusItemLength(contentWidth: ceil(initialAttr.size().width), force: true)
    }

    private func ensurePanelBuilt() {
        guard panel == nil else { return }
        let panel = MonitorPanelController()
        _ = panel.view
        self.panel = panel

        let savedSortByCPU = prefs.object(forKey: uiSortByCPUKey) == nil ? true : prefs.bool(forKey: uiSortByCPUKey)
        panel.applySavedUIState(
            cpuExpanded: prefs.bool(forKey: uiCpuExpandedKey),
            memExpanded: prefs.bool(forKey: uiMemExpandedKey),
            gpuExpanded: prefs.bool(forKey: uiGpuExpandedKey),
            sortByCPU: savedSortByCPU
        )

        panel.onUIStateChanged = { [weak self] in
            guard let self = self else { return }
            self.saveUIState()
            self.renderPanel()
        }
        panel.onOpenActivity = { [weak self] in self?.openActivityMonitor() }
        panel.onMoreMenu = { [weak self] btn in self?.showMoreMenu(from: btn) }
        panel.onSettingsVisibilityChanged = { [weak self] showing in
            if showing { self?.renderSettings() }
        }

        panel.settingsView.onStyleChange = { [weak self] style in self?.setMenubarStyle(style) }
        panel.settingsView.onToggleKey = { [weak self] key, on in self?.setShow(key, on: on) }
        panel.settingsView.onMoveKey = { [weak self] key, delta in self?.moveOrder(key, delta: delta) }
        panel.settingsView.onFanBoostToggle = { [weak self] on in self?.setFanBoostEnabled(on) }
        panel.settingsView.onFanThresholdChange = { [weak self] val in
            self?.fanBoost.setSetting("thresholdC", val)
            self?.renderSettings()
        }
        panel.settingsView.onFanTargetChange = { [weak self] val in
            self?.fanBoost.setSetting("targetPercent", val)
            self?.renderSettings()
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: HIG.panelW, height: HIG.panelH)
        panel.onPreferredSizeChange = { [weak self] size, animated in
            self?.resizePopover(to: size, animated: animated)
        }
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = panel
        pop.delegate = self
        self.popover = pop
    }

    private func resizePopover(to size: NSSize, animated: Bool) {
        guard let popover = popover else { return }
        if animated && !Motion.reduce && popover.isShown {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                popover.contentSize = size
            }
        } else {
            popover.contentSize = size
        }
    }

    private func buildPrefsMenu() {
        prefsMenu = NSMenu()
        prefsMenu.autoenablesItems = false
        prefsMenu.delegate = self

        let styleRoot = NSMenuItem(title: "状态栏样式", action: nil, keyEquivalent: "")
        let styleSub = NSMenu()
        for style in MenubarStyle.allCases {
            let mi = NSMenuItem(title: style.title, action: #selector(selectMenubarStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = style.rawValue
            mi.state = menubarStyle == style ? .on : .off
            mi.isEnabled = true
            styleSub.addItem(mi)
            styleMenuItems[style] = mi
        }
        styleRoot.submenu = styleSub
        prefsMenu.addItem(styleRoot)

        let showRoot = NSMenuItem(title: "状态栏显示", action: nil, keyEquivalent: "")
        let showSub = NSMenu()
        for key in StatusShowKey.allCases {
            let mi = NSMenuItem(title: key.title, action: #selector(toggleShow(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = key.rawValue
            mi.state = isShow(key) ? .on : .off
            mi.isEnabled = true
            showSub.addItem(mi)
            showMenuItems[key] = mi
        }
        showRoot.submenu = showSub
        prefsMenu.addItem(showRoot)

        let orderRoot = NSMenuItem(title: "状态栏顺序", action: nil, keyEquivalent: "")
        orderMenu = NSMenu()
        rebuildOrderMenu()
        orderRoot.submenu = orderMenu
        prefsMenu.addItem(orderRoot)

        prefsMenu.addItem(.separator())
        let sample = NSMenuItem(title: "锁屏时暂停采样", action: nil, keyEquivalent: "")
        sample.state = .on
        sample.isEnabled = false
        prefsMenu.addItem(sample)
    }

    private func buildMoreMenu() {
        moreMenu = NSMenu()
        moreMenu.autoenablesItems = false
        moreMenu.delegate = self

        fanStatusMenuItem = NSMenuItem(title: "风扇：检测中…", action: nil, keyEquivalent: "")
        fanStatusMenuItem.isEnabled = false
        moreMenu.addItem(fanStatusMenuItem)

        fanBoostRoot = NSMenuItem(title: "超温风扇加速", action: nil, keyEquivalent: "")
        fanBoostRoot.submenu = NSMenu()
        fanBoostRoot.submenu?.autoenablesItems = false
        fanBoostRoot.isEnabled = true
        moreMenu.addItem(fanBoostRoot)

        moreMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(showPrefsFromMore(_:)), keyEquivalent: "")
        settings.target = self
        settings.isEnabled = true
        moreMenu.addItem(settings)

        diagMenuItem = NSMenuItem(title: "v2.1.0 · 原生直采 · 无守护进程", action: nil, keyEquivalent: "")
        diagMenuItem.isEnabled = false
        moreMenu.addItem(diagMenuItem)

        moreMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = true
        moreMenu.addItem(quitItem)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        if event.type == .rightMouseUp { showPrefsMenu(relativeTo: sender.bounds, of: sender) }
        else { togglePopover() }
    }

    @objc private func showPrefsFromMore(_ sender: NSMenuItem) {
        ensurePanelBuilt()
        renderSettings()
        panel?.setShowingSettings(true, animated: true)
    }

    private func showMoreMenu(from btn: NSButton) {
        moreMenu.popUp(positioning: nil, at: NSPoint(x: btn.bounds.minX, y: btn.bounds.minY), in: btn)
    }

    private func showPrefsMenu(relativeTo rect: NSRect, of view: NSView) {
        rebuildOrderMenu()
        for (key, mi) in showMenuItems { mi.state = isShow(key) ? .on : .off }
        for (style, mi) in styleMenuItems { mi.state = menubarStyle == style ? .on : .off }
        prefsMenu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.minY), in: view)
    }

    private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        ensurePanelBuilt()
        guard let popover = popover, let panel = panel else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.prepareForOpen()
            panel.fitToContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // popoverWillShow already sets isPanelOpen + throttle
            updateMetrics(forceSensors: true)
        }
    }

    private func startClickOutsideMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover?.isShown == true else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.popover?.isShown != true && self.isPanelOpen {
                    self.isPanelOpen = false
                    self.applyThrottle()
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private func seedDefaultsIfNeeded() {
        let migrateKey = prefsPrefix + "v18Defaults"
        if prefs.object(forKey: migrateKey) == nil {
            for k in StatusShowKey.allCases {
                prefs.set(k.defaultOn, forKey: prefsPrefix + k.rawValue)
            }
            prefs.set(true, forKey: migrateKey)
        }
        let v191Key = prefsPrefix + "v191MenubarDefaults"
        if prefs.object(forKey: v191Key) == nil {
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.chip.rawValue)
            prefs.set(true, forKey: prefsPrefix + StatusShowKey.net.rawValue)
            prefs.set(true, forKey: v191Key)
        }
        for key in StatusShowKey.allCases {
            if prefs.object(forKey: prefsPrefix + key.rawValue) == nil {
                prefs.set(key.defaultOn, forKey: prefsPrefix + key.rawValue)
            }
        }
        if prefs.array(forKey: orderKey) == nil {
            prefs.set(StatusShowKey.allCases.map(\.rawValue), forKey: orderKey)
        }
        if prefs.string(forKey: menubarStyleKey) == nil {
            prefs.set(MenubarStyle.compact.rawValue, forKey: menubarStyleKey)
        }
    }

    private var menubarStyle: MenubarStyle {
        if let cached = cachedMenubarStyle { return cached }
        let parsed = prefs.string(forKey: menubarStyleKey).flatMap(MenubarStyle.init(rawValue:)) ?? .compact
        cachedMenubarStyle = parsed
        return parsed
    }

    private func setMenubarStyle(_ style: MenubarStyle) {
        guard style != menubarStyle else { return }
        prefs.set(style.rawValue, forKey: menubarStyleKey)
        cachedMenubarStyle = style
        for (s, mi) in styleMenuItems { mi.state = s == style ? .on : .off }
        statusPrefsChanged()
        if panel?.isShowingSettings == true { renderSettings() }
    }

    @objc private func selectMenubarStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = MenubarStyle(rawValue: raw) else { return }
        setMenubarStyle(style)
    }

    private func saveUIState() {
        guard let panel = panel else { return }
        prefs.set(panel.cpuRow.detailExpanded, forKey: uiCpuExpandedKey)
        prefs.set(panel.memRow.detailExpanded, forKey: uiMemExpandedKey)
        prefs.set(panel.gpuRow.detailExpanded, forKey: uiGpuExpandedKey)
        prefs.set(panel.sortByCPU, forKey: uiSortByCPUKey)
    }

    private func makeSettingsState() -> SettingsState {
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.0"
        return SettingsState(
            menubarStyle: menubarStyle,
            order: statusOrder(),
            visibility: Dictionary(uniqueKeysWithValues: StatusShowKey.allCases.map { ($0, isShow($0)) }),
            fanBoostEnabled: fanBoost.enabled,
            fanBoostWritable: fanBoost.capability == .writable,
            fanBoostDetail: fanBoost.detailStatus,
            fanThresholdC: fanBoost.thresholdC,
            fanTargetPercent: fanBoost.targetPercent,
            telemetryLabel: "HardwareStatus v\(ver) · \(sampler.telemetrySource.label) · 无守护进程"
        )
    }

    private func renderSettings() {
        panel?.settingsView.render(makeSettingsState())
    }

    private func isShow(_ key: StatusShowKey) -> Bool { prefs.bool(forKey: prefsPrefix + key.rawValue) }

    private func statusOrder() -> [StatusShowKey] {
        let raw = (prefs.array(forKey: orderKey) as? [String]) ?? StatusShowKey.allCases.map(\.rawValue)
        var seen = Set<StatusShowKey>()
        var out: [StatusShowKey] = []
        for s in raw {
            if let k = StatusShowKey(rawValue: s), !seen.contains(k) {
                out.append(k)
                seen.insert(k)
            }
        }
        for k in StatusShowKey.allCases where !seen.contains(k) { out.append(k) }
        return out
    }

    private func saveOrder(_ keys: [StatusShowKey]) { prefs.set(keys.map(\.rawValue), forKey: orderKey) }

    private func rebuildOrderMenu() {
        orderMenu.removeAllItems()
        let order = statusOrder()
        for (i, key) in order.enumerated() {
            let mi = NSMenuItem(title: key.title, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            orderMenu.addItem(mi)
            let up = NSMenuItem(title: "↑ 上移", action: #selector(moveOrderUp(_:)), keyEquivalent: "")
            up.target = self; up.representedObject = key.rawValue; up.isEnabled = i > 0
            orderMenu.addItem(up)
            let down = NSMenuItem(title: "↓ 下移", action: #selector(moveOrderDown(_:)), keyEquivalent: "")
            down.target = self; down.representedObject = key.rawValue; down.isEnabled = i < order.count - 1
            orderMenu.addItem(down)
            orderMenu.addItem(.separator())
        }
    }

    private func moveOrder(_ key: StatusShowKey, delta: Int) {
        var order = statusOrder()
        guard let idx = order.firstIndex(of: key) else { return }
        let target = idx + delta
        guard target >= 0 && target < order.count else { return }
        order.swapAt(idx, target)
        saveOrder(order)
        rebuildOrderMenu()
        statusPrefsChanged()
        if panel?.isShowingSettings == true { renderSettings() }
    }

    @objc private func moveOrderUp(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        moveOrder(key, delta: -1)
    }

    @objc private func moveOrderDown(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        moveOrder(key, delta: 1)
    }

    private func setShow(_ key: StatusShowKey, on: Bool) {
        if !on {
            let othersOn = StatusShowKey.allCases.filter { $0 != key && isShow($0) }
            if othersOn.isEmpty {
                if panel?.isShowingSettings == true { renderSettings() }
                return
            }
        }
        prefs.set(on, forKey: prefsPrefix + key.rawValue)
        showMenuItems[key]?.state = on ? .on : .off
        if on && key == .disk { snapshot.disk = sampler.sampleDisk(maxAge: 0) }
        statusPrefsChanged()
        if on && [StatusShowKey.chip, .gpu, .fan, .power].contains(key) {
            sampler.refreshSensorsAsync(
                panelVisible: isPanelVisible, visibleKeys: visibleStatusKeys(),
                fanBoostWantsTemp: fanBoost.wantsTemperature, force: true
            )
        }
        if panel?.isShowingSettings == true { renderSettings() }
    }

    @objc private func toggleShow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        setShow(key, on: !isShow(key))
    }

    private func statusPrefsChanged() {
        visibleKeysCache = nil
        lastStatusTitleKey = ""
        renderStatusTitle(forceLength: true)
    }

    @objc private func quit() { popover?.performClose(nil); NSApp.terminate(nil) }

    // MARK: - Lifecycle & FanBoost Menu

    private func installLifecycleObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(onWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(onDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(onScreenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreenUnlocked), name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func onWillSleep() { isSleeping = true; syncFanBoostSuspension(); applyThrottle() }

    @objc private func onDidWake() {
        isSleeping = false
        sampler.resetAfterWake()
        smooth.reset()
        cpuHistory.reset()
        gpuHistory.reset()
        netDownHistory.reset()
        netUpHistory.reset()
        lastGpuHistoryWall = nil
        syncFanBoostSuspension()
        applyThrottle()
        updateMetrics(forceSensors: true)
    }

    @objc private func onScreenLocked() { isScreenLocked = true; syncFanBoostSuspension(); applyThrottle() }

    @objc private func onScreenUnlocked() {
        isScreenLocked = false
        syncFanBoostSuspension()
        applyThrottle()
        updateMetrics(forceSensors: true)
    }

    private func syncFanBoostSuspension() { fanBoost.setSuspended(isSleeping || isScreenLocked) }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === moreMenu {
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.0"
            diagMenuItem.title = "v\(ver) · \(sampler.telemetrySource.label) · 无守护进程"
            rebuildFanBoostMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {}

    private func rebuildFanBoostMenu() {
        guard let menu = fanBoostRoot.submenu else { return }
        fanStatusMenuItem.title = fanBoost.detailStatus
        menu.removeAllItems()
        let status = NSMenuItem(title: fanBoost.detailStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "启用超温加速", action: #selector(toggleFanBoost(_:)), keyEquivalent: "")
        toggle.target = self; toggle.state = fanBoost.enabled ? .on : .off; toggle.isEnabled = true
        menu.addItem(toggle)

        func choices(_ title: String, _ values: [Double], current: Double, setting: String, _ label: (Double) -> String) {
            let root = NSMenuItem(title: "\(title)：\(label(current))", action: nil, keyEquivalent: "")
            let sub = NSMenu(); sub.autoenablesItems = false
            for v in values {
                let mi = NSMenuItem(title: label(v), action: #selector(setFanBoostSetting(_:)), keyEquivalent: "")
                mi.target = self; mi.representedObject = [setting: v]; mi.isEnabled = true
                mi.state = abs(v - current) < 0.01 ? .on : .off
                sub.addItem(mi)
            }
            root.submenu = sub; root.isEnabled = fanBoost.enabled
            menu.addItem(root)
        }
        choices("触发温度", FanBoostController.thresholdChoices, current: fanBoost.thresholdC, setting: "thresholdC") { "\(Int($0)) °C" }
        choices("目标转速", FanBoostController.targetPercentChoices, current: fanBoost.targetPercent, setting: "targetPercent") { "最大转速 \(Int($0))%" }
        choices("回差", FanBoostController.hysteresisChoices, current: fanBoost.hysteresisC, setting: "hysteresisC") { "\(Int($0)) °C" }
        choices("持续超温", FanBoostController.sustainChoices, current: fanBoost.sustainSec, setting: "sustainSec") { "\(Int($0)) 秒" }

        menu.addItem(.separator())
        for note in [
            "CPU 温度持续高于阈值才加速，降到阈值 − 回差后恢复自动",
            "退出 / 休眠 / 锁屏 / 关闭时恢复系统自动控制",
            "写入 SMC 需以 root 运行；芯片自身温控保护始终优先"
        ] {
            let mi = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
    }

    private func setFanBoostEnabled(_ on: Bool) {
        fanBoost.setEnabled(on)
        if fanBoost.wantsTemperature {
            sampler.refreshSensorsAsync(
                panelVisible: isPanelVisible, visibleKeys: visibleStatusKeys(),
                fanBoostWantsTemp: true, force: true
            )
        }
        if panel?.isShowingSettings == true { renderSettings() }
    }

    @objc private func toggleFanBoost(_ sender: NSMenuItem) {
        setFanBoostEnabled(!fanBoost.enabled)
    }

    @objc private func setFanBoostSetting(_ sender: NSMenuItem) {
        guard let kv = sender.representedObject as? [String: Double], let first = kv.first else { return }
        fanBoost.setSetting(first.key, first.value)
    }

    // MARK: - Scheduling

    private func desiredInterval() -> TimeInterval? {
        if isSleeping || isScreenLocked { return nil }
        return isPanelOpen ? menuOpenInterval : idleInterval
    }

    private func applyThrottle() {
        if let iv = desiredInterval() { restartTimer(interval: iv) }
        else { timer?.invalidate(); timer = nil }
    }

    private func restartTimer(interval: TimeInterval) {
        if let t = timer, t.isValid, t.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.updateMetrics() }
        t.tolerance = interval >= 2.0 ? interval * 0.2 : interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func visibleStatusKeys() -> [StatusShowKey] {
        if let k = visibleKeysCache { return k }
        let k = statusOrder().filter { isShow($0) }
        visibleKeysCache = k
        return k
    }

    private var isPanelVisible: Bool { isPanelOpen || popover?.isShown == true }

    // MARK: - Menubar Title Sizing & Building

    /// Hysteresis-based dynamic menubar sizing: expands immediately to prevent clipping,
    /// shrinks only after 3 consecutive narrow readings to avoid jitter.
    private func updateStatusItemLength(contentWidth: CGFloat, force: Bool) {
        let iconW: CGFloat = 16
        let needed = ceil(contentWidth + iconW + 8)
        if force || currentStatusLength <= 0 {
            currentStatusLength = needed + 6
            statusItem.length = currentStatusLength
            shrinkStreak = 0
            return
        }
        if needed > currentStatusLength {
            currentStatusLength = needed + 6
            statusItem.length = currentStatusLength
            shrinkStreak = 0
        } else if needed < currentStatusLength - 18 {
            shrinkStreak += 1
            if shrinkStreak >= 3 {
                currentStatusLength = needed + 6
                statusItem.length = currentStatusLength
                shrinkStreak = 0
            }
        } else {
            shrinkStreak = 0
        }
    }

    private func buildTitleSegments() -> [StatusSegment] {
        let s = snapshot
        let style = menubarStyle
        func pct(_ v: Int) -> String { "\(min(100, max(0, v)))%" }
        let downStr = style == .compact ? Formatters.formatRateCompact(s.netDown) : Formatters.formatRateTight(s.netDown)
        let upStr = style == .compact ? Formatters.formatRateCompact(s.netUp) : Formatters.formatRateTight(s.netUp)
        return visibleStatusKeys().map { key -> StatusSegment in
            switch key {
            case .cpu:
                let v = Formatters.clampPct(s.cpu)
                return .metric(label: "CPU", value: pct(v), level: .of(Double(v), warn: 75, critical: 90))
            case .gpu:
                guard let g = s.gpuPct else { return .metric(label: "GPU", value: "--", level: .normal) }
                let v = Formatters.clampPct(g)
                return .metric(label: "GPU", value: pct(v), level: .of(Double(v), warn: 75, critical: 90))
            case .mem:
                let v = s.memShownPct
                return .metric(label: "内存", value: pct(v), level: .of(Double(v), warn: 85, critical: 95))
            case .chip:
                guard let c = s.thermal.chipC else { return .metric(label: "温度", value: "--\u{2009}°C", level: .normal) }
                let v = min(999, max(0, Int(c.rounded())))
                return .metric(label: "温度", value: "\(v)\u{2009}°C", level: .of(Double(v), warn: 85, critical: 95))
            case .fan:
                return .metric(
                    label: "风扇",
                    value: s.thermal.fanRpm.map { "\(min(9999, $0)) RPM" } ?? "--",
                    level: fanBoost.isBoosted ? .warn : .normal
                )
            case .power:
                guard let w = s.power.sysW else { return .metric(label: "功耗", value: "-- W", level: .normal) }
                return .metric(label: "功耗", value: Formatters.formatWatts(w), level: .normal)
            case .disk:
                let v = Formatters.clampPct(s.disk.usedPercent)
                return .metric(label: "磁盘", value: pct(v), level: .of(Double(v), warn: 80, critical: 92))
            case .net:
                return .rates(down: downStr, up: upStr)
            }
        }
    }

    // MARK: - Sample → Render Pipeline

    private func updateMetrics(forceSensors: Bool = false) {
        if isSleeping || isScreenLocked { return }
        let panelVisible = isPanelVisible
        let keys = visibleStatusKeys()
        let now = ProcessInfo.processInfo.systemUptime

        let cpuSample = sampler.sampleCPU()
        snapshot.mem = sampler.sampleMemory(includeSwap: panelVisible)
        if panelVisible { snapshot.loadAvg1m = sampler.sampleLoadAvg1m() }
        if panelVisible || keys.contains(.disk) { snapshot.disk = sampler.sampleDisk(maxAge: sampler.diskMaxAge) }
        let net = sampler.sampleNetwork()
        pullTelemetryIntoSnapshot(now: now)

        smooth.apply(
            to: &snapshot,
            rawCPU: cpuSample.total, rawUser: cpuSample.user, rawSys: cpuSample.system,
            rawNetDown: net.down, rawNetUp: net.up,
            now: now
        )
        cpuHistory.push(snapshot.cpu)
        netDownHistory.push(snapshot.netDown)
        netUpHistory.push(snapshot.netUp)
        recordGpuHistoryIfFresh()
        renderStatusTitle()
        if panelVisible {
            renderPanel()
            triggerProcessScan()
        }

        sampler.refreshSensorsAsync(
            panelVisible: panelVisible, visibleKeys: keys,
            fanBoostWantsTemp: fanBoost.wantsTemperature, force: forceSensors
        )
    }

    private func handleSensorsUpdated() {
        if isSleeping || isScreenLocked { return }
        let now = ProcessInfo.processInfo.systemUptime
        pullTelemetryIntoSnapshot(now: now)
        smooth.applyTelemetry(to: &snapshot, now: now)
        recordGpuHistoryIfFresh()
        renderStatusTitle()
        if isPanelVisible { renderPanel() }
    }

    private func recordGpuHistoryIfFresh() {
        guard let pct = snapshot.gpuPct, let wall = snapshot.gpuSampleWall else { return }
        if lastGpuHistoryWall != wall {
            lastGpuHistoryWall = wall
            gpuHistory.push(pct)
        }
    }

    private func pullTelemetryIntoSnapshot(now: TimeInterval) {
        let t = sampler.currentTelemetry()
        snapshot.thermal = t.thermal
        snapshot.power = t.power
        snapshot.gpuPct = t.gpuPct
        snapshot.gpuSampleWall = t.gpuWall
        snapshot.tiers = t.tiers
        fanBoost.evaluate(
            tempC: t.thermal.cpuC ?? t.thermal.chipC,
            sampleWall: t.thermal.sampleWall,
            now: now
        )
    }

    private func triggerProcessScan() {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        sampler.scanProcessesAsync(runningAppPIDs: runningPIDs) { [weak self] procs, needsWarmup in
            guard let self = self, self.isPanelVisible else { return }
            self.snapshot.procs = procs
            self.renderProcessRows()
            if needsWarmup {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self = self else { return }
                    self.sampler.clearProcWarmupFlag()
                    if self.isPanelVisible { self.triggerProcessScan() }
                }
            }
        }
    }

    private func renderStatusTitle(forceLength: Bool = false) {
        if let button = statusItem.button {
            isMenubarDark = Ink.isDark(button.effectiveAppearance)
        }
        let style = menubarStyle
        let segments = buildTitleSegments()
        let key = StatusTitle.key(segments, dark: isMenubarDark, style: style)
        if key != lastStatusTitleKey {
            lastStatusTitleKey = key
            let attr = StatusTitle.attributed(segments, dark: isMenubarDark, style: style)
            updateStatusItemLength(contentWidth: ceil(attr.size().width), force: forceLength)
            statusItem.button?.attributedTitle = attr
        }
    }

    /// Pure render from `snapshot`; safe for UI-only updates (sort / expand / fan boost change).
    private func renderPanel() {
        guard isPanelVisible, let panel = panel else { return }
        let s = snapshot
        let thermal = s.thermal
        let cpuI = Formatters.clampPct(s.cpu)
        let memI = s.memShownPct
        let diskI = Formatters.clampPct(s.disk.usedPercent)
        let gpuI = s.gpuPct.map(Formatters.clampPct)

        let uptime = Formatters.formatUptime(ProcessInfo.processInfo.systemUptime)
        if let sw = s.power.sysW {
            panel.subtitleLabel.setText("\(sampler.chipName) · \(sampler.memTotalGB) · \(Formatters.formatWatts(sw)) · 已运行 \(uptime)")
        } else {
            panel.subtitleLabel.setText("\(sampler.chipName) · \(sampler.memTotalGB) · 已运行 \(uptime)")
        }

        let pillColor: NSColor
        let pillStep: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pillColor = .systemGreen; pillStep = 1
        case .fair: pillColor = .systemYellow; pillStep = 2
        case .serious: pillColor = .systemOrange; pillStep = 3
        case .critical: pillColor = .systemRed; pillStep = 4
        @unknown default: pillColor = HIG.faintInk; pillStep = 1
        }
        panel.setThermal(thermal.pressureLabel, color: pillColor, step: pillStep)

        // CPU
        panel.cpuRow.setReading("\(cpuI)", level: .of(Double(cpuI), warn: 75, critical: 90))
        panel.cpuRow.track.set(Double(cpuI))
        panel.cpuRow.sparkline?.update(primary: cpuHistory.values)
        if panel.cpuRow.detailExpanded {
            panel.cpuDetail.update(user: s.cpuUser, sys: s.cpuSys, load1m: s.loadAvg1m, tiers: s.tiers)
        } else {
            panel.cpuRow.setDetail(String(format: "用户 %.0f%% · 系统 %.0f%% · 1m 负载 %.2f", s.cpuUser, s.cpuSys, s.loadAvg1m))
        }

        // Memory (real kernel pressure + swap)
        let mem = s.mem
        panel.memRow.setReading("\(memI)", level: .of(Double(memI), warn: 85, critical: 95))
        panel.memRow.usesSegments = panel.memRow.detailExpanded
        if panel.memRow.detailExpanded {
            panel.memRow.segments.set(parts: [
                (Double(mem.app), HIG.memApp),
                (Double(mem.wired), HIG.memWired),
                (Double(mem.compressed), HIG.memCompressed)
            ], total: Double(mem.total))
            panel.memDetail.update(mem: mem)
        } else {
            panel.memRow.track.set(Double(memI), warnAt: 85, criticalAt: 95)
            let usedGB = Double(mem.used) / 1_073_741_824.0
            if mem.swapUsed >= 128 * 1024 * 1024 {
                panel.memRow.setDetail(String(
                    format: "%.1f / %@ · 压力%@ · 交换 %@",
                    usedGB, sampler.memTotalGB, mem.pressure.label, Formatters.formatBytes(mem.swapUsed)
                ))
            } else {
                panel.memRow.setDetail(String(
                    format: "%.1f / %@ · 内存压力%@",
                    usedGB, sampler.memTotalGB, mem.pressure.label
                ))
            }
        }

        // GPU
        if let g = gpuI {
            panel.gpuRow.setReading("\(g)", level: .of(Double(g), warn: 75, critical: 90))
            panel.gpuRow.track.set(Double(g))
        } else {
            panel.gpuRow.setPlaceholder("读取中…")
            panel.gpuRow.track.set(0)
        }
        panel.gpuRow.sparkline?.update(primary: gpuHistory.values)
        if panel.gpuRow.detailExpanded {
            panel.gpuDetail.update(gpuC: thermal.gpuC, power: s.power)
        } else {
            if let gc = thermal.gpuC, let gw = s.power.gpuW {
                panel.gpuRow.setDetail(String(format: "GPU 温度 %.0f °C · %@", gc, Formatters.formatWatts(gw)))
            } else if let gc = thermal.gpuC {
                panel.gpuRow.setDetail(String(format: "GPU 温度 %.0f °C", gc))
            } else if let gw = s.power.gpuW {
                panel.gpuRow.setDetail("GPU 功耗 \(Formatters.formatWatts(gw))")
            } else {
                panel.gpuRow.setDetail("GPU 温度 读取中…")
            }
        }

        // Temp & Fan tiles
        if let c = thermal.cpuC ?? thermal.chipC {
            panel.tempCell.setReading(String(format: "%.0f", c), unit: "°C", level: .of(c, warn: 85, critical: 95))
            let tempRatio = max(0.0, min(100.0, (c - 20.0) / 80.0 * 100.0))
            panel.tempCell.track.set(tempRatio, warnAt: 81.25, criticalAt: 93.75)
        } else {
            panel.tempCell.setPlaceholder("读取中…")
            panel.tempCell.track.set(0)
        }
        if let gc = thermal.gpuC, let sw = s.power.sysW {
            panel.tempCell.setSubtitle(String(format: "GPU %.0f°C · %@", gc, Formatters.formatWatts(sw)))
        } else if let gc = thermal.gpuC {
            panel.tempCell.setSubtitle(String(format: "GPU %.0f°C", gc))
        } else if let sw = s.power.sysW {
            panel.tempCell.setSubtitle("整机功耗 \(Formatters.formatWatts(sw))")
        } else {
            panel.tempCell.setSubtitle("传感读取中")
        }

        let boosted = fanBoost.isBoosted
        panel.fanCell.titleLabel.setText("风扇转速 · \(fanBoost.shortStatus)")
        let fanTitleColor: NSColor = boosted ? HIG.warn : HIG.mutedInk
        if panel.fanCell.titleLabel.textColor != fanTitleColor { panel.fanCell.titleLabel.textColor = fanTitleColor }
        let fanTip = "\(fanBoost.detailStatus)（点击打开设置）"
        if panel.fanCell.toolTip != fanTip { panel.fanCell.toolTip = fanTip }
        if let rpm = thermal.fanRpm {
            panel.fanCell.setReading("\(rpm)", unit: "RPM", level: boosted ? .warn : .normal)
            if let maxRpm = thermal.fanMaxRpm, maxRpm > 0 {
                let ratio = max(0.0, min(100.0, Double(rpm) / Double(maxRpm) * 100.0))
                panel.fanCell.setSubtitle("\(Int(ratio.rounded()))% · 上限 \(maxRpm)", color: boosted ? HIG.warn : HIG.faintInk)
                panel.fanCell.track.set(ratio, warnAt: 75, criticalAt: 92)
            } else {
                let fallbackRatio = max(0.0, min(100.0, Double(rpm) / 6000.0 * 100.0))
                panel.fanCell.setSubtitle(rpm == 0 ? "静音停转 · 点击设置" : "自动调速 · 点击设置", color: boosted ? HIG.warn : HIG.faintInk)
                panel.fanCell.track.set(fallbackRatio, warnAt: 75, criticalAt: 92)
            }
        } else {
            panel.fanCell.setPlaceholder(fanBoost.capability == .fanless ? "无风扇" : "无读数")
            panel.fanCell.setSubtitle(fanBoost.capability == .fanless ? "被动散热机型" : "点击打开设置")
            panel.fanCell.track.set(0)
        }

        // Disk & Network
        if s.disk.total == 0 {
            panel.diskRow.setMessage("读取失败")
            panel.diskRow.track.set(0)
        } else {
            panel.diskRow.setUsage(percent: diskI, detail: "\(Formatters.formatBytes(s.disk.used)) / \(Formatters.formatBytes(s.disk.total))")
            panel.diskRow.track.set(Double(diskI), warnAt: 80, criticalAt: 92)
        }
        panel.netRow.setRates(down: Formatters.formatRate(s.netDown), up: Formatters.formatRate(s.netUp))
        panel.netRow.sparkline?.update(primary: netDownHistory.values, secondary: netUpHistory.values)

        renderProcessRows()
    }

    private func renderProcessRows() {
        guard isPanelVisible, let panel = panel else { return }
        let n = panel.topRows.count
        let top: [AggProc] = panel.sortByCPU
            ? Array(snapshot.procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(n))
            : Array(snapshot.procs.sorted { $0.footprint > $1.footprint }.prefix(n))
        panel.showProcRows(top.count)

        let cpuScale = max(40.0, top.first?.cpuPercent ?? 40.0)
        let memScale = max(Double(2 * 1024 * 1024 * 1024), Double(top.first?.footprint ?? 1) * 1.15)
        for (i, p) in top.enumerated() {
            let row = panel.topRows[i]
            row.nameLabel.setText(p.name)
            row.cpuLabel.setText(String(format: "%.1f%%", p.cpuPercent))
            row.memLabel.setText(Formatters.formatBytes(p.footprint))
            row.setSortedByCPU(panel.sortByCPU)
            row.pid = p.mainPid
            row.setIcon(iconFor(appKey: p.appKey), key: p.appKey)

            let frac = panel.sortByCPU ? (p.cpuPercent / cpuScale) : (Double(p.footprint) / memScale)
            row.setShare(fraction: frac, tint: panel.sortByCPU ? HIG.tintCPU : HIG.tintMem)

            var tipLines = ["\(p.name)  (PID \(p.mainPid))"]
            if p.processCount > 1 { tipLines.append("聚合 \(p.processCount) 个关联进程") }
            if !p.execPath.isEmpty { tipLines.append(p.execPath) }
            let tip = tipLines.joined(separator: "\n")
            if row.toolTip != tip { row.toolTip = tip }

            let proc = p
            row.onMenu = { [weak self] anchor in self?.showProcessMenu(for: proc, anchor: anchor) }
        }
        panel.fitToContentIfNeeded()
    }

    private func resolvedRevealPath(for proc: AggProc) -> String? {
        let raw = !proc.execPath.isEmpty ? proc.execPath : proc.appKey
        if let range = raw.range(of: ".app") {
            let bundle = String(raw[..<range.upperBound])
            if FileManager.default.fileExists(atPath: bundle) { return bundle }
        }
        if !raw.isEmpty, FileManager.default.fileExists(atPath: raw) { return raw }
        return nil
    }

    private func showProcessMenu(for proc: AggProc, anchor: NSView) {
        activeMenuProc = proc
        let menu = NSMenu()
        menu.autoenablesItems = false

        let headerText = proc.processCount > 1
            ? "\(proc.name) · PID \(proc.mainPid) · \(proc.processCount) 个进程"
            : "\(proc.name) · PID \(proc.mainPid)"
        let header = NSMenuItem(title: headerText, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "在 Finder 中显示", action: #selector(procRevealInFinder), keyEquivalent: "")
        reveal.target = self
        reveal.isEnabled = resolvedRevealPath(for: proc) != nil
        menu.addItem(reveal)

        let copyPid = NSMenuItem(title: "复制 PID", action: #selector(procCopyPid), keyEquivalent: "")
        copyPid.target = self
        copyPid.isEnabled = true
        menu.addItem(copyPid)

        let copyPath = NSMenuItem(title: "复制路径", action: #selector(procCopyPath), keyEquivalent: "")
        copyPath.target = self
        copyPath.isEnabled = !proc.execPath.isEmpty || resolvedRevealPath(for: proc) != nil
        menu.addItem(copyPath)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "优雅退出…", action: #selector(procQuitGraceful), keyEquivalent: "")
        quitItem.target = self
        quitItem.isEnabled = true
        menu.addItem(quitItem)

        let forceItem = NSMenuItem(title: "强制结束…", action: #selector(procQuitForce), keyEquivalent: "")
        forceItem.target = self
        forceItem.isEnabled = true
        menu.addItem(forceItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY), in: anchor)
    }

    @objc private func procRevealInFinder() {
        guard let proc = activeMenuProc, let path = resolvedRevealPath(for: proc) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func procCopyPid() {
        guard let proc = activeMenuProc else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(proc.mainPid)", forType: .string)
    }

    @objc private func procCopyPath() {
        guard let proc = activeMenuProc else { return }
        let path = !proc.execPath.isEmpty ? proc.execPath : (resolvedRevealPath(for: proc) ?? "")
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc private func procQuitGraceful() {
        guard let proc = activeMenuProc else { return }
        confirmKill(pid: proc.mainPid, name: proc.name, appKey: proc.appKey, defaultForce: false)
    }

    @objc private func procQuitForce() {
        guard let proc = activeMenuProc else { return }
        confirmKill(pid: proc.mainPid, name: proc.name, appKey: proc.appKey, defaultForce: true)
    }

    /// Downsamples NSWorkspace multi-res icons to a single 20x20 pt (@2x = 40x40 px) bitmap
    /// so iconCache uses ~6 KB per app instead of retaining 256+ KB multi-rep icons.
    private func iconFor(appKey: String) -> NSImage? {
        if let cached = iconCache[appKey] { return cached }
        var path = appKey
        if let range = path.range(of: ".app") { path = String(path[..<range.upperBound]) }
        let img: NSImage
        if path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) {
            let full = NSWorkspace.shared.icon(forFile: path)
            img = Self.downsampleIcon(full, ptSize: HIG.appIcon)
        } else if appKey.hasPrefix("/System") || appKey.hasPrefix("/usr") || appKey.hasPrefix("/bin") || appKey.hasPrefix("/sbin") {
            img = NSImage(systemSymbolName: "gearshape.2", accessibilityDescription: nil) ?? NSImage()
        } else {
            img = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()
        }
        if iconCache.count >= 64 { iconCache.removeAll(keepingCapacity: true) }
        iconCache[appKey] = img
        return img
    }

    private static func downsampleIcon(_ source: NSImage, ptSize: CGFloat) -> NSImage {
        let px = Int(ptSize * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            source.size = NSSize(width: ptSize, height: ptSize)
            return source
        }
        rep.size = NSSize(width: ptSize, height: ptSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: ptSize, height: ptSize),
            from: .zero, operation: .copy, fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: ptSize, height: ptSize))
        out.addRepresentation(rep)
        return out
    }

    private func confirmKill(pid: Int32, name: String, appKey: String, defaultForce: Bool = false) {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let alert = NSAlert()
        if defaultForce {
            alert.messageText = runningApp != nil ? "强制结束应用？" : "强制结束进程？"
            alert.informativeText = "\(name) (PID \(pid))\n将立即发送强制终止信号，未保存的数据可能会丢失。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "强制结束")
            alert.addButton(withTitle: "取消")
        } else {
            alert.messageText = runningApp != nil ? "优雅退出应用？" : "结束进程？"
            alert.informativeText = "\(name) (PID \(pid))"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "退出")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "强制结束")
        }

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn || resp == .alertThirdButtonReturn else { return }
        guard sampler.verifyPidMatchesAppKey(pid: pid, appKey: appKey) else {
            NSSound.beep()
            return
        }
        let force = defaultForce ? (resp == .alertFirstButtonReturn) : (resp == .alertThirdButtonReturn)
        if let app = runningApp, !app.isTerminated {
            let ok = force ? app.forceTerminate() : app.terminate()
            if ok { return }
        }
        let sig = force ? SIGKILL : SIGTERM
        if kill(pid, sig) != 0 {
            let err = errno
            if err != ESRCH {
                let errAlert = NSAlert()
                errAlert.messageText = "无法结束 \(name)"
                errAlert.informativeText = err == EPERM
                    ? "权限不足（系统或受保护进程，PID \(pid)）。"
                    : "系统返回错误：\(String(cString: strerror(err)))。"
                errAlert.alertStyle = .informational
                errAlert.runModal()
            }
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        isPanelOpen = false
        stopClickOutsideMonitor()
        applyThrottle()
        sampler.resetProcessSmoothing()
        if iconCache.count > 24 { iconCache.removeAll(keepingCapacity: false) }
    }

    func popoverWillShow(_ notification: Notification) {
        isPanelOpen = true
        startClickOutsideMonitor()
        applyThrottle()
    }
}

@main
enum HardwareStatusMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
