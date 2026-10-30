import Cocoa
import Foundation
import Darwin
import QuartzCore

@_silgen_name("hw_phys_footprint")
func hw_phys_footprint(_ pid: Int32) -> UInt64

// View layer lives in DesignSystem.swift, PanelComponents.swift,
// MonitorPanelController.swift and StatusTitle.swift.

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
    // MARK: Sampling state (main thread only unless noted)
    private let hostPort: mach_port_t = mach_host_self()  // one send right for app lifetime
    private var memTotalBytes: UInt64 = 0
    private var memPageSize: UInt64 = 16384
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCPUWall: TimeInterval = 0
    private var lastCPUValue: Double = 0
    private var lastCPUUserSys: (user: Double, system: Double) = (0, 0)
    private var lastProcCPU: [Int32: (cpu: Double, wall: TimeInterval)] = [:]
    private var lastProcSampleWall: TimeInterval = 0
    private var procWarmupPending = false
    private var procPathBuf = [CChar](repeating: 0, count: 4 * 1024)  // reused by proc_pidpath
    private var procIdentityCache: [String: (name: String, key: String)] = [:]  // exe path -> (name, appKey)
    private var displayNameCache: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]
    private var diskCache: (info: DiskInfo, wall: TimeInterval)?
    private let diskMaxAge: TimeInterval = 15
    private let idleInterval: TimeInterval = 2.5
    private let menuOpenInterval: TimeInterval = 1.0
    private let prefs = UserDefaults.standard
    private let prefsPrefix = "local.lsaac128.HardwareStatus."
    private let orderKey = "local.lsaac128.HardwareStatus.statusOrder"
    // macmon: resolved lazily (Homebrew arm64/x86, PATH); nil = not found, re-probed at most once a minute
    private var macmonPath: String?
    private var macmonProbeWall: TimeInterval = -.infinity
    private var lastMacmonLaunchWall: TimeInterval = -.infinity
    private let macmonIdleMinInterval: TimeInterval = 5   // panel closed: temps change slowly
    private let macmonTimeout: TimeInterval = 5
    // Guarded by tempLock (written on a utility queue, read on main)
    private let tempLock = NSLock()
    private var cachedCpuC: Double?
    private var cachedGpuC: Double?
    private var cachedFanRpm: Int?
    private var cachedGpuPct: Double?
    private var cachedPE: (p: Double, e: Double, s: Double) = (0, 0, 0)
    private var tempRefreshInFlight = false
    // Per-interface 32-bit if_data counters (see counterDelta)
    private var lastIfBytes: [String: (inB: UInt32, outB: UInt32)] = [:]
    private var lastNetWall: TimeInterval?
    private var netDownBps: Double = 0
    private var netUpBps: Double = 0
    // Latest sampled values; UI-only actions (sort / expand / prefs) re-render from here
    private var snapshot = Snapshot()
    private var visibleKeysCache: [StatusShowKey]?
    private var lastStatusTitle = ""
    private var showMenuItems: [StatusShowKey: NSMenuItem] = [:]
    private var orderMenu: NSMenu!
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
        // CPU/network need a baseline; process baseline is taken lazily when the panel opens
        _ = sampleCPU(); sampleNetwork()
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
        memTotalBytes = mem
        memTotalGB = String(format: "%.0f GB", Double(mem) / 1_073_741_824.0)
        var pageSize: vm_size_t = 0
        if host_page_size(hostPort, &pageSize) == KERN_SUCCESS, pageSize > 0 { memPageSize = UInt64(pageSize) }
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
        }
        applyStatusItemLength(forPreview: longestTitleSample())
    }

    private func buildPanel() {
        panel = MonitorPanelController()
        _ = panel.view
        // Sort / expand only re-render cached samples; resampling here would compute CPU
        // deltas over a few ms and make the numbers jump.
        panel.onSortChanged = { [weak self] in self?.renderPanel() }
        panel.onOpenActivity = { [weak self] in self?.openActivityMonitor() }
        panel.onMoreMenu = { [weak self] btn in self?.showMoreMenu(from: btn) }
        popover = NSPopover()
        popover.contentSize = NSSize(width: HIG.panelW, height: HIG.panelH)
        // Panel fits its height to the content (expand / row count); follow it
        panel.onPreferredSizeChange = { [weak self] size in self?.popover.contentSize = size }
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
            // Size to content before showing so the popover doesn't jump on open (UI only)
            panel.resetForOpen()
            panel.fitToContentIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // popoverWillShow already set isPanelOpen + throttle
            updateMetrics()
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
        statusPrefsChanged()
    }
    @objc private func moveOrderDown(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = StatusShowKey(rawValue: raw) else { return }
        var order = statusOrder(); guard let i = order.firstIndex(of: key), i < order.count-1 else { return }
        order.swapAt(i, i+1); saveOrder(order); rebuildOrderMenu()
        statusPrefsChanged()
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
        if !on && key == .disk { snapshot.disk = diskInfo(maxAge: 0) }  // disk isn't sampled while hidden
        statusPrefsChanged()
        if !on && [StatusShowKey.chip, .gpu, .fan].contains(key) { refreshTempsAsync(force: true) }
    }
    private func statusPrefsChanged() {
        visibleKeysCache = nil
        applyStatusItemLength(forPreview: longestTitleSample())
        renderStatusTitle()
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
        isSleeping = false; lastNetWall = nil; lastIfBytes.removeAll(); lastCPUTicks = nil
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
        // Idempotent: open/willShow/unlock may all ask for the same interval
        if let t = timer, t.isValid, t.timeInterval == interval { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.updateMetrics() }
        t.tolerance = interval * 0.1  // let the system coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
    /// Menubar keys in user order; cached because UserDefaults is read on every tick otherwise.
    private func visibleStatusKeys() -> [StatusShowKey] {
        if let k = visibleKeysCache { return k }
        let k = statusOrder().filter { isShow($0) }
        visibleKeysCache = k
        return k
    }
    private var isPanelVisible: Bool { isPanelOpen || popover?.isShown == true }
    /// Widest plausible title for the current key set, so the item never resizes per tick.
    private func longestTitleSample() -> [StatusSegment] {
        visibleStatusKeys().map { key -> StatusSegment in
            switch key {
            case .cpu: return .metric(label: "CPU", value: "100%", level: .normal)
            case .gpu: return .metric(label: "GPU", value: "100%", level: .normal)
            case .mem: return .metric(label: "内存", value: "100%", level: .normal)
            case .chip: return .metric(label: "温度", value: "105\u{2009}°C", level: .normal)  // reserve 3-digit temp
            case .fan: return .metric(label: "风扇", value: "9999 RPM", level: .normal)
            case .disk: return .metric(label: "磁盘", value: "100%", level: .normal)
            case .net: return .rates(down: formatRateShort(999.9 * 1024 * 1024), up: formatRateShort(999.9 * 1024 * 1024))
            }
        }
    }
    private func applyStatusItemLength(forPreview sample: [StatusSegment]) {
        let iconW: CGFloat = 16
        statusItem.length = ceil(StatusTitle.width(sample) + iconW + 8)
    }
    /// Values are padded to 2 digits (figure spaces, see StatusTitle) so typical readings don't
    /// shift the row; warn/critical levels mirror the panel's bar thresholds.
    private func buildTitle(cpu: Double, gpu: Double?, mem: Double, chipC: Double?, fanRpm: Int?, disk: Double, down: String, up: String) -> [StatusSegment] {
        func pct(_ v: Double) -> String { String(format: "%2d%%", Self.clampPct(v)) }
        return visibleStatusKeys().map { key -> StatusSegment in
            switch key {
            case .cpu:
                return .metric(label: "CPU", value: pct(cpu), level: .of(cpu, warn: 75, critical: 90))
            case .gpu:
                guard let g = gpu else { return .metric(label: "GPU", value: "--", level: .normal) }
                return .metric(label: "GPU", value: pct(g), level: .of(g, warn: 75, critical: 90))
            case .mem:
                return .metric(label: "内存", value: pct(mem), level: .of(mem, warn: 85, critical: 95))
            case .chip:
                guard let c = chipC else { return .metric(label: "温度", value: "--\u{2009}°C", level: .normal) }
                let v = min(999, max(0, Int(c.rounded())))
                return .metric(label: "温度", value: String(format: "%2d\u{2009}°C", v), level: .of(Double(v), warn: 85, critical: 95))
            case .fan:
                return .metric(label: "风扇", value: fanRpm.map { String(format: "%4d RPM", min(9999, $0)) } ?? "--", level: .normal)
            case .disk:
                return .metric(label: "磁盘", value: pct(disk), level: .of(disk, warn: 80, critical: 92))
            case .net:
                return .rates(down: down, up: up)
            }
        }
    }

    // MARK: - Sample → render pipeline
    private struct Snapshot {
        var cpu: Double = 0
        var mem = MemInfo(total: 0, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, usedPercent: 0)
        var disk = DiskInfo(total: 0, used: 0, usedPercent: 0)
        var thermal = ThermalInfo(chipC: nil, cpuC: nil, gpuC: nil, fanRpm: nil, pressureLabel: "")
        var gpuPct: Double?
        var pe: (p: Double, e: Double, s: Double) = (0, 0, 0)
        var procs: [AggProc] = []   // only refreshed while the panel is visible
    }
    private static func clampPct(_ v: Double) -> Int { min(100, max(0, Int(v.rounded()))) }

    /// Timer tick: sample what the menubar needs; panel-only work (process table,
    /// disk when hidden from menubar) runs only while the popover is visible.
    private func updateMetrics() {
        if isSleeping || isScreenLocked { return }
        let panelVisible = isPanelVisible
        let keys = visibleStatusKeys()
        snapshot.cpu = sampleCPU()
        snapshot.mem = sampleMemory()
        if panelVisible || keys.contains(.disk) { snapshot.disk = diskInfo(maxAge: diskMaxAge) }
        snapshot.thermal = sampleThermal()
        sampleNetwork()
        tempLock.lock()
        snapshot.gpuPct = cachedGpuPct
        snapshot.pe = cachedPE
        tempLock.unlock()
        if panelVisible { sampleProcessTable() }
        renderStatusTitle()
        refreshTempsAsync(force: false)
        if panelVisible { renderPanel() }
    }

    private func sampleProcessTable() {
        let wall = ProcessInfo.processInfo.systemUptime
        let dt = wall - lastProcSampleWall
        if dt < 0.5 { return }  // e.g. open right after a tick — delta would be noise
        snapshot.procs = aggregateByApp(sampleProcessesRaw())
        // Baseline is stale (panel was closed / first open): values are averaged over the
        // gap, so take a quick follow-up sample instead of waiting a full tick.
        if dt > 3 && !procWarmupPending {
            procWarmupPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                self.procWarmupPending = false
                if self.isPanelVisible { self.updateMetrics() }
            }
        }
    }

    private func renderStatusTitle() {
        let s = snapshot
        let segments = buildTitle(
            cpu: s.cpu, gpu: s.gpuPct, mem: s.mem.usedPercent, chipC: s.thermal.chipC,
            fanRpm: s.thermal.fanRpm, disk: s.disk.usedPercent,
            down: formatRateShort(netDownBps), up: formatRateShort(netUpBps)
        )
        // Re-assigning an identical title still relayouts/redraws the status item
        let key = StatusTitle.key(segments)
        if key != lastStatusTitle {
            lastStatusTitle = key
            statusItem.button?.attributedTitle = StatusTitle.attributed(segments)
        }
    }

    /// Pure render from `snapshot`; safe to call for UI-only changes (sort, expand).
    private func renderPanel() {
        guard isPanelVisible, let panel = panel else { return }
        let s = snapshot
        let thermal = s.thermal
        let cpuI = Self.clampPct(s.cpu)
        let memI = Self.clampPct(s.mem.usedPercent)
        let diskI = Self.clampPct(s.disk.usedPercent)
        let gpuI = s.gpuPct.map(Self.clampPct)

        let uptime = formatUptime(ProcessInfo.processInfo.systemUptime)
        panel.subtitleLabel.setText("\(chipName) · \(memTotalGB) · 已运行 \(uptime)")
        let pillColor: NSColor
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pillColor = .systemGreen
        case .fair: pillColor = .systemYellow
        case .serious: pillColor = .systemOrange
        case .critical: pillColor = .systemRed
        @unknown default: pillColor = .tertiaryLabelColor
        }
        panel.setThermal(thermal.pressureLabel, color: pillColor)

        panel.cpuRow.setReading("\(cpuI)", level: .of(Double(cpuI), warn: 75, critical: 90))
        panel.cpuRow.track.set(Double(cpuI))
        // Only format the variant that is actually shown
        if panel.cpuRow.detailExpanded {
            var loads = [Double](repeating: 0, count: 3)
            _ = loads.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
            panel.cpuRow.setDetail(String(
                format: "用户 %.0f%% · 系统 %.0f%% · 负载 %.2f · P 核 %.0f%% · E 核 %.0f%%",
                lastCPUUserSys.user, lastCPUUserSys.system, loads[0], s.pe.p * 100, s.pe.e * 100
            ))
        } else {
            panel.cpuRow.setDetail(String(format: "用户 %.0f%% · 系统 %.0f%%", lastCPUUserSys.user, lastCPUUserSys.system))
        }

        let mem = s.mem
        // Main value: percent only; capacity + pressure (or the colored legend) below
        panel.memRow.setReading("\(memI)", level: .of(Double(memI), warn: 85, critical: 95))
        panel.memRow.usesSegments = panel.memRow.detailExpanded
        if panel.memRow.detailExpanded {
            panel.memRow.segments.set(parts: [
                (Double(mem.app), HIG.memApp),
                (Double(mem.wired), HIG.memWired),
                (Double(mem.compressed), HIG.memCompressed)
            ], total: Double(mem.total))
            let app = formatBytes(mem.app), wired = formatBytes(mem.wired)
            let comp = formatBytes(mem.compressed), swap = formatBytes(sampleSwap())
            // Legend dots match the segment colors
            panel.memRow.detailLabel.set(key: "\(app)|\(wired)|\(comp)|\(swap)") {
                Caption().dot(HIG.memApp).text("应用 ").value(app).gap()
                    .dot(HIG.memWired).text("联动 ").value(wired).gap()
                    .dot(HIG.memCompressed).text("压缩 ").value(comp).gap()
                    .text("交换 ").value(swap).string
            }
        } else {
            panel.memRow.track.set(Double(memI), warnAt: 85, criticalAt: 95)
            let pressure: String
            if memI < 70 { pressure = "正常" }
            else if memI < 85 { pressure = "偏高" }
            else { pressure = "紧张" }
            let usedGB = Double(mem.used) / 1_073_741_824.0
            panel.memRow.setDetail(String(format: "%.1f / %@ · 内存压力%@", usedGB, memTotalGB, pressure))
        }

        // GPU gets a caption too (temperature from macmon), so it has the same rhythm as CPU / 内存
        if let g = gpuI {
            panel.gpuRow.setReading("\(g)", level: .of(Double(g), warn: 75, critical: 90))
            panel.gpuRow.track.set(Double(g))
        } else {
            panel.gpuRow.setPlaceholder("未支持")
            panel.gpuRow.track.set(0)
        }
        if let gc = thermal.gpuC {
            panel.gpuRow.setDetail(String(format: "GPU 温度 %.0f °C", gc))
        } else {
            panel.gpuRow.setDetail(gpuI == nil ? "需要 macmon 提供 GPU 数据" : "GPU 温度 读取中…")
        }

        // Prefer CPU sensor for "CPU 温度"; fall back to chip
        if let c = thermal.cpuC ?? thermal.chipC {
            panel.tempCell.setReading(String(format: "%.0f", c), unit: "°C", level: .of(c, warn: 85, critical: 95))
        } else {
            panel.tempCell.setPlaceholder("读取中…")
        }
        if let rpm = thermal.fanRpm {
            panel.fanCell.setReading("\(rpm)", unit: "RPM")
        } else {
            panel.fanCell.setPlaceholder("无读数")
        }

        if s.disk.total == 0 {
            panel.diskRow.setMessage("读取失败")
            panel.diskRow.track.set(0)
        } else {
            panel.diskRow.setUsage(percent: diskI, detail: "\(formatBytes(s.disk.used)) / \(formatBytes(s.disk.total))")
            panel.diskRow.track.set(Double(diskI), warnAt: 80, criticalAt: 92)
        }
        panel.netRow.setRates(down: formatRate(netDownBps), up: formatRate(netUpBps))

        let n = panel.topRows.count
        let top: [AggProc] = panel.sortByCPU
            ? Array(s.procs.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(n))
            : Array(s.procs.sorted { $0.footprint > $1.footprint }.prefix(n))
        panel.showProcRows(top.count)
        for (i, p) in top.enumerated() {
            let row = panel.topRows[i]
            row.nameLabel.setText(p.name)
            row.cpuLabel.setText(String(format: "%.1f%%", p.cpuPercent))
            row.memLabel.setText(formatBytes(p.footprint))
            row.setSortedByCPU(panel.sortByCPU)
            row.pid = p.mainPid
            row.setIcon(iconFor(appKey: p.appKey), key: p.appKey)
            let pid = p.mainPid, name = p.name, key = p.appKey
            row.onMenu = { [weak self] in self?.confirmKill(pid: pid, name: name, appKey: key) }
        }
        panel.fitToContentIfNeeded()
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
    private func confirmKill(pid: Int32, name: String, appKey: String) {
        let alert = NSAlert()
        alert.messageText = "结束进程？"
        alert.informativeText = "\(name) (pid \(pid))"; alert.alertStyle = .warning
        alert.addButton(withTitle: "结束"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The alert can stay up indefinitely: make sure the pid wasn't recycled meanwhile
        guard friendlyNameAndKey(for: pid).1 == appKey else { NSSound.beep(); return }
        kill(pid, SIGTERM)
    }

    private struct ThermalInfo {
        var chipC: Double?
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
        // Hotter of CPU / GPU sensors
        let chip: Double? = [cpu, gpu].compactMap { $0 }.max()
        return ThermalInfo(chipC: chip, cpuC: cpu, gpuC: gpu, fanRpm: fan, pressureLabel: pressure)
    }

    /// Resolve macmon once: README promises "macmon in PATH", but LaunchAgents get a minimal
    /// PATH, so probe the usual install locations explicitly too.
    private func resolveMacmonPath() -> String? {
        if let p = macmonPath { return p }
        let now = ProcessInfo.processInfo.systemUptime
        if now - macmonProbeWall < 60 { return nil }
        macmonProbeWall = now
        var candidates = ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon",
                          NSHomeDirectory() + "/.cargo/bin/macmon", "/opt/local/bin/macmon"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/macmon" }
        }
        macmonPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return macmonPath
    }

    /// macmon is a subprocess spawn + ~200 ms sample, by far the most expensive source.
    /// Skip it when nothing visible needs it, and space it out while the panel is closed.
    private func refreshTempsAsync(force: Bool) {
        let panelVisible = isPanelVisible
        let now = ProcessInfo.processInfo.systemUptime
        if !force {
            if !panelVisible && !visibleStatusKeys().contains(where: { [StatusShowKey.chip, .gpu, .fan].contains($0) }) { return }
            // 0.5 s slack so timer tolerance doesn't push a 2.5 s tick cadence to every 3rd tick
            if !panelVisible && now - lastMacmonLaunchWall < macmonIdleMinInterval - 0.5 { return }
        }
        guard let path = resolveMacmonPath() else { return }
        tempLock.lock()
        // `force` bypasses the time throttle only — never run two macmon instances at once
        if tempRefreshInFlight { tempLock.unlock(); return }
        tempRefreshInFlight = true; tempLock.unlock()
        lastMacmonLaunchWall = now
        let timeout = macmonTimeout
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.tempLock.lock(); self?.tempRefreshInFlight = false; self?.tempLock.unlock() }
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = ["pipe", "-s", "1", "-i", "200"]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice  // was an unread Pipe
            do { try proc.run() } catch { return }
            // A hung macmon used to leave tempRefreshInFlight set forever (temps frozen)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if proc.isRunning { proc.terminate() }
            }
            // Drain stdout before waiting so a large write can't block on a full pipe
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
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
            var fanRpm: Int? = nil
            if let fans = obj["fans"] as? [[String: Any]] {
                var best = 0
                for f in fans {
                    let rpm: Int
                    if let r = f["rpm"] as? Int { rpm = r }
                    else if let r = f["rpm"] as? Double, r.isFinite { rpm = Int(r.rounded()) }
                    else { continue }
                    if rpm > best { best = rpm }
                }
                if best > 0 { fanRpm = best }
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
            self.cachedGpuPct = gpuPct
            self.cachedPE = (pRatio, eRatio, sRatio)
            self.tempLock.unlock()
        }
    }

    /// Delta of a 32-bit counter: wrap if it was near the top, otherwise treat a decrease
    /// as a reset (interface re-created, e.g. VPN utun) rather than a ~4 GiB burst.
    private static func counterDelta(_ cur: UInt32, _ prev: UInt32) -> UInt64 {
        if cur >= prev { return UInt64(cur - prev) }
        return prev >= 0xC000_0000 ? UInt64(cur &- prev) : 0
    }
    private func sampleNetwork() {
        let wall = ProcessInfo.processInfo.systemUptime
        let dt = lastNetWall.map { wall - $0 } ?? 0
        if lastNetWall != nil && dt <= 0.2 { return }  // too short for a meaningful rate
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return }
        defer { freeifaddrs(ifaddr) }
        var dIn: UInt64 = 0; var dOut: UInt64 = 0
        var next: [String: (inB: UInt32, outB: UInt32)] = [:]
        next.reserveCapacity(lastIfBytes.count)
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let flags = Int32(p.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoop = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoop, let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = p.pointee.ifa_data {
                // if_data counters are 32-bit and wrap every 4 GiB: track per interface
                // (summing first made any single wrap read as 0 B/s).
                let ifd = data.assumingMemoryBound(to: if_data.self).pointee
                let name = String(cString: p.pointee.ifa_name)
                let cur = (inB: ifd.ifi_ibytes, outB: ifd.ifi_obytes)
                if let prev = lastIfBytes[name] {
                    dIn += Self.counterDelta(cur.inB, prev.inB); dOut += Self.counterDelta(cur.outB, prev.outB)
                }
                next[name] = cur
            }
            ptr = p.pointee.ifa_next
        }
        if lastNetWall != nil, dt > 0 {
            netDownBps = Double(dIn) / dt; netUpBps = Double(dOut) / dt
        }
        lastIfBytes = next
        lastNetWall = wall
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
        let wall = ProcessInfo.processInfo.systemUptime
        // Called again within a few ms (panel open right after a tick): delta would be noise
        if lastCPUTicks != nil && wall - lastCPUWall < 0.5 { return lastCPUValue }
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return lastCPUValue }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }
        // Ticks are 32-bit signed per core; UInt64(Int32) traps once a counter goes negative
        // (long uptimes), so reinterpret as unsigned.
        @inline(__always) func tick(_ i: Int) -> UInt64 { UInt64(UInt32(bitPattern: cpuInfo[i])) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for i in 0..<Int(numCPUs) {
            let offset = Int(CPU_STATE_MAX) * i
            user += tick(offset + Int(CPU_STATE_USER))
            system += tick(offset + Int(CPU_STATE_SYSTEM))
            idle += tick(offset + Int(CPU_STATE_IDLE))
            nice += tick(offset + Int(CPU_STATE_NICE))
        }
        defer { lastCPUTicks = (user, system, idle, nice); lastCPUWall = wall }
        guard let last = lastCPUTicks else { return lastCPUValue }
        // A per-core counter wrapped: re-baseline instead of trapping on unsigned underflow
        guard user >= last.user, system >= last.system, idle >= last.idle, nice >= last.nice else { return lastCPUValue }
        let total = (user - last.user) + (system - last.system) + (idle - last.idle) + (nice - last.nice)
        guard total > 0 else { return lastCPUValue }
        let u = Double((user - last.user) + (nice - last.nice)) / Double(total) * 100.0
        let s = Double(system - last.system) / Double(total) * 100.0
        lastCPUUserSys = (u, s)
        lastCPUValue = u + s
        return lastCPUValue
    }
    private struct MemInfo { var total, used, app, wired, compressed, cached: UInt64; var usedPercent: Double }
    private func sampleMemory() -> MemInfo {
        // hw.memsize / page size are constant: read once in seedIdentity()
        let totalSize = memTotalBytes
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = hostPort
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let page = memPageSize
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
    /// Volume capacity barely moves, and "important usage" capacity can be slow to query.
    private func diskInfo(maxAge: TimeInterval) -> DiskInfo {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = diskCache, now - c.wall < maxAge { return c.info }
        let info = sampleDisk()
        diskCache = (info, now)
        return info
    }
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
        lastProcSampleWall = wall
        let pids = listAllPIDs()
        var rows: [ProcRow] = []; rows.reserveCapacity(256)
        var nextCPU: [Int32: (cpu: Double, wall: TimeInterval)] = [:]
        nextCPU.reserveCapacity(pids.count)
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
        // Hot path (every process, every panel tick): reuse one path buffer and memoize
        // the path -> (name, appKey) parse instead of re-deriving it each time.
        let pathLen = procPathBuf.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if pathLen > 0 {
            let path = String(cString: procPathBuf)
            if let hit = procIdentityCache[path] { return (hit.name, hit.key) }
            let ident: (name: String, key: String)
            if let range = path.range(of: ".app/") {
                let appRoot = String(path[..<range.upperBound].dropLast())
                let name = displayName(fromAppPath: path) ?? URL(fileURLWithPath: appRoot).deletingPathExtension().lastPathComponent
                ident = (name, appRoot)
            } else if path.hasSuffix(".app") {
                let name = displayName(fromAppPath: path) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                ident = (name, path)
            } else {
                ident = (URL(fileURLWithPath: path).lastPathComponent, path)
            }
            if procIdentityCache.count > 1000 { procIdentityCache.removeAll(keepingCapacity: true) }
            procIdentityCache[path] = ident
            return (ident.name, ident.key)
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
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB"]
    private func formatBytes(_ bytes: UInt64) -> String {
        let units = Self.byteUnits
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
        panel.resetForOpen()
        applyThrottle()
    }
}

// Multi-file module: an explicit entry point replaces top-level code (built with -parse-as-library)
@main
enum HardwareStatusMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate  // NSApplication.delegate is weak
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
