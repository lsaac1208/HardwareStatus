import Cocoa
import Darwin
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panel: MonitorPanelController!
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

    private var visibleKeysCache: [StatusShowKey]?
    private var lastStatusTitleKey = ""
    private var showMenuItems: [StatusShowKey: NSMenuItem] = [:]
    private var orderMenu: NSMenu!
    private var iconCache: [String: NSImage] = [:]
    private var isScreenLocked = false
    private var isSleeping = false
    private var isPanelOpen = false
    private var isMenubarDark = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedDefaultsIfNeeded()
        startFanBoost()
        buildPanel()
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
        applyStatusItemLength(forPreview: longestTitleSample())
    }

    private func buildPanel() {
        panel = MonitorPanelController()
        _ = panel.view
        panel.onSortChanged = { [weak self] in self?.renderPanel() }
        panel.onOpenActivity = { [weak self] in self?.openActivityMonitor() }
        panel.onMoreMenu = { [weak self] btn in self?.showMoreMenu(from: btn) }

        popover = NSPopover()
        popover.contentSize = NSSize(width: HIG.panelW, height: HIG.panelH)
        panel.onPreferredSizeChange = { [weak self] size in self?.popover.contentSize = size }
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = panel
        popover.delegate = self
    }

    private func buildPrefsMenu() {
        prefsMenu = NSMenu()
        prefsMenu.autoenablesItems = false
        prefsMenu.delegate = self
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

        diagMenuItem = NSMenuItem(title: "v2.0.0 · 原生直采 · 无守护进程", action: nil, keyEquivalent: "")
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
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            panel.resetForOpen()
            panel.fitToContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // popoverWillShow already sets isPanelOpen + throttle
            updateMetrics(forceSensors: true)
        }
    }

    private func startClickOutsideMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.popover.isShown else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !self.popover.isShown && self.isPanelOpen {
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

    @objc private func moveOrderUp(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        var order = statusOrder()
        guard let i = order.firstIndex(of: key), i > 0 else { return }
        order.swapAt(i, i - 1); saveOrder(order); rebuildOrderMenu(); statusPrefsChanged()
    }

    @objc private func moveOrderDown(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        var order = statusOrder()
        guard let i = order.firstIndex(of: key), i < order.count - 1 else { return }
        order.swapAt(i, i + 1); saveOrder(order); rebuildOrderMenu(); statusPrefsChanged()
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
        if !on && key == .disk { snapshot.disk = sampler.sampleDisk(maxAge: 0) }
        statusPrefsChanged()
        if !on && [StatusShowKey.chip, .gpu, .fan, .power].contains(key) {
            sampler.refreshSensorsAsync(
                panelVisible: isPanelVisible, visibleKeys: visibleStatusKeys(),
                fanBoostWantsTemp: fanBoost.wantsTemperature, force: true
            )
        }
    }

    private func statusPrefsChanged() {
        visibleKeysCache = nil
        applyStatusItemLength(forPreview: longestTitleSample())
        renderStatusTitle()
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
            let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
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

    @objc private func toggleFanBoost(_ sender: NSMenuItem) {
        fanBoost.setEnabled(!fanBoost.enabled)
        if fanBoost.wantsTemperature {
            sampler.refreshSensorsAsync(
                panelVisible: isPanelVisible, visibleKeys: visibleStatusKeys(),
                fanBoostWantsTemp: true, force: true
            )
        }
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

    private func longestTitleSample() -> [StatusSegment] {
        visibleStatusKeys().map { key -> StatusSegment in
            switch key {
            case .cpu: return .metric(label: "CPU", value: "100%", level: .normal)
            case .gpu: return .metric(label: "GPU", value: "100%", level: .normal)
            case .mem: return .metric(label: "内存", value: "100%", level: .normal)
            case .chip: return .metric(label: "温度", value: "105\u{2009}°C", level: .normal)
            case .fan: return .metric(label: "风扇", value: "9999 RPM", level: .normal)
            case .power: return .metric(label: "功耗", value: "100 W", level: .normal)
            case .disk: return .metric(label: "磁盘", value: "100%", level: .normal)
            case .net: return .rates(down: Formatters.formatRateShort(999.9 * 1024 * 1024), up: Formatters.formatRateShort(999.9 * 1024 * 1024))
            }
        }
    }

    private func applyStatusItemLength(forPreview sample: [StatusSegment]) {
        let iconW: CGFloat = 16
        statusItem.length = ceil(StatusTitle.width(sample) + iconW + 8)
    }

    private func buildTitleSegments() -> [StatusSegment] {
        let s = snapshot
        func pct(_ v: Int) -> String { String(format: "%2d%%", min(100, max(0, v))) }
        let downStr = Formatters.formatRateShort(s.netDown)
        let upStr = Formatters.formatRateShort(s.netUp)
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
                return .metric(label: "温度", value: String(format: "%2d\u{2009}°C", v), level: .of(Double(v), warn: 85, critical: 95))
            case .fan:
                return .metric(
                    label: "风扇",
                    value: s.thermal.fanRpm.map { String(format: "%4d RPM", min(9999, $0)) } ?? "--",
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
        renderStatusTitle()
        if isPanelVisible { renderPanel() }
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

    private func renderStatusTitle() {
        if let button = statusItem.button {
            isMenubarDark = Ink.isDark(button.effectiveAppearance)
        }
        let segments = buildTitleSegments()
        let key = StatusTitle.key(segments, dark: isMenubarDark)
        if key != lastStatusTitleKey {
            lastStatusTitleKey = key
            statusItem.button?.attributedTitle = StatusTitle.attributed(segments, dark: isMenubarDark)
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
        if panel.cpuRow.detailExpanded {
            if s.tiers.valid && s.tiers.hasSuper {
                panel.cpuRow.setDetail(String(
                    format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f · S 核 %.0f%% · P 核 %.0f%% · E 核 %.0f%%",
                    s.cpuUser, s.cpuSys, s.loadAvg1m, s.tiers.s * 100, s.tiers.p * 100, s.tiers.e * 100
                ))
            } else if s.tiers.valid {
                panel.cpuRow.setDetail(String(
                    format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f · P 核 %.0f%% · E 核 %.0f%%",
                    s.cpuUser, s.cpuSys, s.loadAvg1m, s.tiers.p * 100, s.tiers.e * 100
                ))
            } else {
                panel.cpuRow.setDetail(String(
                    format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f",
                    s.cpuUser, s.cpuSys, s.loadAvg1m
                ))
            }
        } else {
            panel.cpuRow.setDetail(String(format: "用户 %.0f%% · 系统 %.0f%%", s.cpuUser, s.cpuSys))
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
            let app = Formatters.formatBytes(mem.app)
            let wired = Formatters.formatBytes(mem.wired)
            let comp = Formatters.formatBytes(mem.compressed)
            let swap = Formatters.formatBytes(mem.swapUsed)
            panel.memRow.detailLabel.set(key: "\(app)|\(wired)|\(comp)|\(swap)") {
                Caption().dot(HIG.memApp).text("应用\u{00A0}").value(app).gap()
                    .dot(HIG.memWired).text("联动\u{00A0}").value(wired).gap()
                    .dot(HIG.memCompressed).text("压缩\u{00A0}").value(comp).gap()
                    .text("交换\u{00A0}").value(swap).string
            }
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
        if let gc = thermal.gpuC, let gw = s.power.gpuW {
            panel.gpuRow.setDetail(String(format: "GPU 温度 %.0f °C · %@", gc, Formatters.formatWatts(gw)))
        } else if let gc = thermal.gpuC {
            panel.gpuRow.setDetail(String(format: "GPU 温度 %.0f °C", gc))
        } else if let gw = s.power.gpuW {
            panel.gpuRow.setDetail("GPU 功耗 \(Formatters.formatWatts(gw))")
        } else {
            panel.gpuRow.setDetail("GPU 温度 读取中…")
        }

        // Temp & Fan tiles
        if let c = thermal.cpuC ?? thermal.chipC {
            panel.tempCell.setReading(String(format: "%.0f", c), unit: "°C", level: .of(c, warn: 85, critical: 95))
        } else {
            panel.tempCell.setPlaceholder("读取中…")
        }

        let boosted = fanBoost.isBoosted
        panel.fanCell.titleLabel.setText("风扇转速 · \(fanBoost.shortStatus)")
        let fanTitleColor: NSColor = boosted ? HIG.warn : HIG.mutedInk
        if panel.fanCell.titleLabel.textColor != fanTitleColor { panel.fanCell.titleLabel.textColor = fanTitleColor }
        let fanTip = fanBoost.detailStatus
        if panel.fanCell.toolTip != fanTip { panel.fanCell.toolTip = fanTip }
        if let rpm = thermal.fanRpm {
            panel.fanCell.setReading("\(rpm)", unit: "RPM", level: boosted ? .warn : .normal)
        } else {
            panel.fanCell.setPlaceholder(fanBoost.capability == .fanless ? "无风扇" : "无读数")
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

        renderProcessRows()
    }

    private func renderProcessRows() {
        guard isPanelVisible, let panel = panel else { return }
        let n = panel.topRows.count
        let top: [AggProc] = panel.sortByCPU
            ? Array(snapshot.procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(n))
            : Array(snapshot.procs.sorted { $0.footprint > $1.footprint }.prefix(n))
        panel.showProcRows(top.count)
        for (i, p) in top.enumerated() {
            let row = panel.topRows[i]
            row.nameLabel.setText(p.name)
            row.cpuLabel.setText(String(format: "%.1f%%", p.cpuPercent))
            row.memLabel.setText(Formatters.formatBytes(p.footprint))
            row.setSortedByCPU(panel.sortByCPU)
            row.pid = p.mainPid
            row.setIcon(iconFor(appKey: p.appKey), key: p.appKey)
            let pid = p.mainPid, name = p.name, key = p.appKey
            row.onMenu = { [weak self] in self?.confirmKill(pid: pid, name: name, appKey: key) }
        }
        panel.fitToContentIfNeeded()
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

    private func confirmKill(pid: Int32, name: String, appKey: String) {
        let runningApp = NSRunningApplication(processIdentifier: pid)
        let alert = NSAlert()
        alert.messageText = runningApp != nil ? "结束应用？" : "结束进程？"
        alert.informativeText = "\(name) (PID \(pid))"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "结束")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制结束")

        let resp = alert.runModal()
        guard resp == .alertFirstButtonReturn || resp == .alertThirdButtonReturn else { return }
        guard sampler.verifyPidMatchesAppKey(pid: pid, appKey: appKey) else {
            NSSound.beep()
            return
        }
        let force = (resp == .alertThirdButtonReturn)
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
