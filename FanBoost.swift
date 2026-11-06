import Foundation

// 超温风扇加速: when the CPU temperature (macmon, same reading as the panel) stays above a
// threshold, force the fans to manual mode at a clamped target RPM; hand control back to
// the system once it has cooled by `hysteresis`. Everything runs in-process (hw_smc.c),
// no daemon / helper. The system's own thermal protection always stays in charge.

/// Pure decision logic (no SMC, no Cocoa), kept separate so it can be tested on its own.
struct FanBoostPolicy {
    var thresholdC: Double = 85
    var hysteresisC: Double = 5
    /// Over-temperature must persist this long, measured between macmon samples, so a
    /// single spike never forces the fans.
    var sustain: TimeInterval = 4
    /// No fresh temperature for this long while boosting → give control back.
    var staleAfter: TimeInterval = 30
    private(set) var overSince: TimeInterval?

    enum ReleaseReason: Equatable { case cooled, stale }
    enum Decision: Equatable { case none, boost, release(ReleaseReason) }

    mutating func reset() { overSince = nil }

    /// `sampleWall` is when the reading was taken (uptime); repeated ticks with the same
    /// sample don't advance the debounce.
    mutating func evaluate(tempC: Double?, sampleWall: TimeInterval?, now: TimeInterval, boosting: Bool) -> Decision {
        guard let t = tempC, t.isFinite, let w = sampleWall, now - w <= staleAfter else {
            overSince = nil
            return boosting ? .release(.stale) : .none
        }
        if boosting {
            if t <= thresholdC - hysteresisC { overSince = nil; return .release(.cooled) }
            return .none
        }
        guard t > thresholdC else { overSince = nil; return .none }
        let since = overSince ?? w
        overSince = since
        return w - since >= sustain ? .boost : .none
    }

    /// Lowest RPM ever written as a target; the C layer refuses anything below too.
    static let minimumSafeRPM = 500.0

    /// `percent` of the fan's max, clamped to the probed [min, max]. Falls back to
    /// `fallbackRPM` when max is unreadable. Never below what the fan already spins at
    /// (boost must not reduce cooling) and never 0. nil = don't touch this fan.
    static func targetRPM(minRPM: Double?, maxRPM: Double?, currentRPM: Double?,
                          percent: Double, fallbackRPM: Double = 4500) -> Double? {
        let lo = minRPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let hi = maxRPM.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let lo = lo, let hi = hi, hi < lo { return nil }  // nonsense probe
        let pct = min(100, max(10, percent.isFinite ? percent : 80))
        var t = hi.map { $0 * pct / 100 } ?? fallbackRPM
        if let c = currentRPM, c.isFinite, c > t { t = c }
        if let hi = hi { t = min(t, hi) }
        if let lo = lo { t = max(t, lo) }
        t = t.rounded()
        return t >= minimumSafeRPM ? t : nil
    }
}

/// Main-thread API; every SMC call runs on one serial queue (`q_` members are confined to it).
final class FanBoostController {
    enum Capability: Equatable { case probing, noSMC, fanless, readOnly(String), writable }
    enum State: Equatable { case auto, engaging, boosted, failed(String) }

    struct Fan { let index: Int; let minRPM: Double?; let maxRPM: Double?; let modeKey: String? }
    struct Hardware { var fans: [Fan] = []; var hasFtst = false; var legacyFS = false }

    // MARK: Settings (UserDefaults, edited from 更多 › 超温风扇加速)
    static let thresholdChoices: [Double] = [75, 80, 85, 90, 95]
    static let targetPercentChoices: [Double] = [60, 70, 80, 90, 100]
    static let hysteresisChoices: [Double] = [3, 5, 8, 10]
    static let sustainChoices: [Double] = [3, 4, 5]

    private let prefs = UserDefaults.standard
    private let prefix = "local.lsaac128.HardwareStatus.fanBoost."
    private var dirtyKey: String { prefix + "dirty" }
    var enabled: Bool { prefs.bool(forKey: prefix + "enabled") }
    var thresholdC: Double { prefs.double(forKey: prefix + "thresholdC") }
    var targetPercent: Double { prefs.double(forKey: prefix + "targetPercent") }
    var hysteresisC: Double { prefs.double(forKey: prefix + "hysteresisC") }
    var sustainSec: Double { prefs.double(forKey: prefix + "sustainSec") }

    private(set) var capability: Capability = .probing
    private(set) var state: State = .auto
    private(set) var targets: [Int: Double] = [:]
    var onChange: (() -> Void)?

    private var hw = Hardware()
    private var policy = FanBoostPolicy()
    private var suspended = false
    private var generation = 0
    private var cancel = CancelFlag()
    private var lastVerifyWall: TimeInterval = 0
    private var verifyFailures = 0
    private var retryAfterWall: TimeInterval = 0
    private let verifyInterval: TimeInterval = 8
    private let failureBackoff: TimeInterval = 60
    private let queue = DispatchQueue(label: "local.lsaac128.HardwareStatus.smc", qos: .userInitiated)
    private var signalSources: [DispatchSourceSignal] = []

    // Queue-confined ownership: what *we* forced, so restore never touches other tools' state
    private var q_forcedFans: [Fan] = []
    private var q_forcedLegacy = false
    private var q_wroteFtst = false
    /// A forcing write of ours succeeded (or the last run died mid-boost): restore must write.
    private var q_owned = false
    /// Set once by SIGTERM/INT/HUP; checked by the unlock loop (never reassigned, so thread-safe).
    private let terminating = CancelFlag()

    final class CancelFlag {
        private let lock = NSLock(); private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    init() {
        prefs.register(defaults: [
            prefix + "enabled": true, prefix + "thresholdC": 85.0, prefix + "targetPercent": 80.0,
            prefix + "hysteresisC": 5.0, prefix + "sustainSec": 4.0
        ])
        applyPolicySettings()
    }

    /// Probe hardware, recover from a previous run that died while boosting, arm crash handlers.
    func start(onTerminateSignal: @escaping () -> Void) {
        hw_smc_install_crash_handlers()
        installTerminationSignals(onTerminateSignal)
        let wasDirty = prefs.bool(forKey: dirtyKey)
        queue.async { [weak self] in
            guard let self = self else { return }
            let (cap, hw) = self.q_probe()
            if wasDirty, !hw.fans.isEmpty {
                // Last run was killed (SIGKILL / power loss) mid-boost: hand fans back first
                self.q_forcedFans = hw.fans.filter { $0.modeKey != nil }
                self.q_forcedLegacy = hw.legacyFS
                self.q_wroteFtst = hw.hasFtst
                self.q_owned = true
                self.q_restore(hw)
            }
            DispatchQueue.main.async {
                self.hw = hw; self.capability = cap
                self.onChange?()
            }
        }
    }

    // MARK: Main-thread API

    /// macmon must keep sampling while boost could act, even if no temperature is shown.
    var wantsTemperature: Bool { enabled && capability == .writable && !suspended }
    var isBoosted: Bool { state == .boosted || state == .engaging }

    /// Call on every tick with the CPU temperature the panel shows.
    func evaluate(tempC: Double?, sampleWall: TimeInterval?, now: TimeInterval) {
        guard capability == .writable, enabled, !suspended else { return }
        if case .failed = state {
            if now < retryAfterWall { return }
            state = .auto; policy.reset(); onChange?()
        }
        switch policy.evaluate(tempC: tempC, sampleWall: sampleWall, now: now, boosting: isBoosted) {
        case .boost: engage(now: now)
        case .release: release()
        case .none:
            if state == .boosted, now - lastVerifyWall >= verifyInterval { verify(now: now) }
        }
    }

    func setEnabled(_ on: Bool) {
        prefs.set(on, forKey: prefix + "enabled")
        if !on { restoreNow() }
        onChange?()
    }
    func setSetting(_ name: String, _ value: Double) {
        prefs.set(value, forKey: prefix + name)
        applyPolicySettings()
        onChange?()
    }

    /// Lock screen / sleep: give control back synchronously and stop acting until resumed.
    func setSuspended(_ on: Bool) {
        if on == suspended { return }
        suspended = on
        if on { restoreNow() } else { policy.reset() }
    }

    /// Synchronous restore (quit, sleep, lock, disable). Safe to call repeatedly.
    func restoreNow() {
        cancel.cancel()
        generation += 1
        let hadState = state != .auto
        state = .auto; targets = [:]; policy.reset()
        let hw = self.hw
        queue.sync { _ = self.q_restore(hw) }
        if hadState { onChange?() }
    }

    // MARK: Status text (Chinese UI)

    /// Short tag for the fan tile title.
    var shortStatus: String {
        switch capability {
        case .probing: return "检测中"
        case .noSMC: return "只读"
        case .fanless: return "无风扇"
        case .readOnly: return "只读"
        case .writable: break
        }
        if !enabled { return "自动" }
        switch state {
        case .auto: return "自动"
        case .engaging: return "切换中"
        case .boosted: return "强制加速"
        case .failed: return "自动"
        }
    }
    /// One-line explanation for the 更多 menu / tooltip.
    var detailStatus: String {
        switch capability {
        case .probing: return "风扇：检测中…"
        case .noSMC: return "风扇：无法访问 SMC，仅显示转速"
        case .fanless: return "无风扇机型：无需加速（被动散热）"
        case .readOnly(let why): return "风扇：自动 · 只读（\(why)）"
        case .writable: break
        }
        if !enabled { return "风扇：自动（超温加速已关闭）" }
        switch state {
        case .auto: return "风扇：自动（系统控制）"
        case .engaging: return "风扇：正在切换到强制加速…"
        case .boosted:
            let rpm = targets.values.max().map { String(format: "%.0f", $0) } ?? "--"
            return "风扇：强制加速 · 目标 \(rpm) RPM"
        case .failed(let why): return "风扇：自动（\(why)，稍后重试）"
        }
    }

    // MARK: Transitions

    private func applyPolicySettings() {
        policy.thresholdC = thresholdC
        policy.hysteresisC = hysteresisC
        policy.sustain = sustainSec
    }

    private func engage(now: TimeInterval) {
        guard state == .auto else { return }
        state = .engaging
        generation += 1
        let gen = generation, hw = self.hw, pct = targetPercent
        let flag = CancelFlag(); cancel = flag
        prefs.set(true, forKey: dirtyKey)  // before the first write: survives SIGKILL
        onChange?()
        queue.async { [weak self] in
            guard let self = self else { return }
            let result = self.q_engage(hw, percent: pct, cancel: flag)
            DispatchQueue.main.async {
                guard gen == self.generation else { return }  // superseded by a restore
                switch result {
                case .boosted(let t):
                    self.state = .boosted; self.targets = t
                    self.lastVerifyWall = ProcessInfo.processInfo.systemUptime; self.verifyFailures = 0
                case .denied:
                    self.state = .auto; self.capability = .readOnly("无 SMC 写入权限")
                case .failed(let why):
                    self.fail(why)
                case .cancelled:
                    self.state = .auto
                }
                self.onChange?()
            }
        }
    }

    private func release() {
        guard state != .auto else { return }
        cancel.cancel()
        generation += 1
        state = .auto; targets = [:]; policy.reset()
        let hw = self.hw
        queue.async { [weak self] in self?.q_restore(hw) }
        onChange?()
    }

    private func verify(now: TimeInterval) {
        lastVerifyWall = now
        let gen = generation, hw = self.hw, t = targets
        queue.async { [weak self] in
            guard let self = self else { return }
            let r = self.q_verify(hw, targets: t)
            DispatchQueue.main.async {
                guard gen == self.generation, self.state == .boosted else { return }
                switch r {
                case .ok: self.verifyFailures = 0
                case .denied:
                    self.restoreNow(); self.capability = .readOnly("无 SMC 写入权限"); self.onChange?()
                case .lost:
                    self.verifyFailures += 1
                    if self.verifyFailures >= 3 { self.restoreNow(); self.fail("系统收回了风扇控制") }
                }
            }
        }
    }

    private func fail(_ why: String) {
        state = .failed(why); targets = [:]
        retryAfterWall = ProcessInfo.processInfo.systemUptime + failureBackoff
        onChange?()
    }

    private func installTerminationSignals(_ onTerminate: @escaping () -> Void) {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak self] in
                // Restore first, off the main thread, in case the main thread is stuck
                self?.terminating.cancel()
                hw_smc_guard_restore()
                DispatchQueue.main.async { onTerminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { exit(0) }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    // MARK: SMC queue

    private enum EngageResult { case boosted([Int: Double]), denied, failed(String), cancelled }
    private enum VerifyResult { case ok, denied, lost }

    private static let kIOReturnNotPrivileged = Int32(bitPattern: 0xe00002c1)
    private static let kIOReturnBadArgument = Int32(bitPattern: 0xe00002c2)
    private static let kIOReturnNotPermitted = Int32(bitPattern: 0xe00002e2)
    private static let smcKeySizeMismatch = Int32(HW_SMC_ERR_SMC | 0x87)
    private static func isDenied(_ r: Int32) -> Bool {
        r == kIOReturnNotPrivileged || r == kIOReturnBadArgument || r == kIOReturnNotPermitted
    }

    private func q_read(_ key: String) -> Double? {
        var v = 0.0
        return hw_smc_read_number(key, &v) == 0 && v.isFinite ? v : nil
    }
    private func q_exists(_ key: String) -> Bool {
        var size: UInt32 = 0, type: UInt32 = 0
        return hw_smc_key_info(key, &size, &type) == 0 && size > 0
    }
    /// Non-zero writes are the forcing ones (mode 1, Ftst 1, target RPM, FS! mask).
    private func q_write(_ key: String, _ value: Double) -> Int32 {
        let r = Int32(hw_smc_write_number(key, value))
        if r == 0 && value != 0 { q_owned = true }
        return r
    }

    private func q_probe() -> (Capability, Hardware) {
        guard hw_smc_open() == 0 else { return (.noSMC, Hardware()) }
        var hw = Hardware()
        let n = Int(q_read("FNum") ?? 0)
        if n <= 0 { return (.fanless, hw) }
        for i in 0..<min(n, 8) {
            // Apple Silicon generations differ in the mode key's case (F0Md vs F0md on M5)
            let mode = ["F\(i)Md", "F\(i)md"].first { q_exists($0) }
            hw.fans.append(Fan(index: i, minRPM: q_read("F\(i)Mn"), maxRPM: q_read("F\(i)Mx"), modeKey: mode))
        }
        hw.hasFtst = q_exists("Ftst")
        hw.legacyFS = hw.fans.allSatisfy { $0.modeKey == nil } && q_exists("FS! ")  // older Intel
        if !hw.legacyFS && hw.fans.allSatisfy({ $0.modeKey == nil }) {
            return (.readOnly("此机型未找到风扇模式键"), hw)
        }
        // AppleSMC rejects unprivileged writes to fan keys; without a helper that means root
        if geteuid() != 0 { return (.readOnly("需以 root 运行才能写入 SMC"), hw) }
        return (.writable, hw)
    }

    private func q_engage(_ hw: Hardware, percent: Double, cancel: CancelFlag) -> EngageResult {
        let stop = { cancel.isCancelled || self.terminating.isCancelled }
        if stop() { return .cancelled }
        var plan: [(Fan, Double)] = []
        for fan in hw.fans where fan.modeKey != nil || hw.legacyFS {
            let t = FanBoostPolicy.targetRPM(minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                             currentRPM: q_read("F\(fan.index)Ac"), percent: percent)
            if let t = t { plan.append((fan, t)) }
        }
        if plan.isEmpty { return .failed("无法确定安全转速") }
        let fans = plan.map { $0.0 }
        // Arm the crash guard and record ownership before anything is written
        let keys = fans.compactMap { $0.modeKey }.joined()
        hw_smc_guard_configure(keys, Int32(fans.count), hw.hasFtst ? 1 : 0, hw.legacyFS ? 1 : 0)
        hw_smc_guard_arm(1)
        q_forcedFans = fans; q_forcedLegacy = hw.legacyFS

        func abort(_ r: EngageResult) -> EngageResult { q_restore(hw); return r }
        if hw.legacyFS {
            let mask = fans.reduce(0) { $0 | (1 << $1.index) }
            let r = q_write("FS! ", Double(mask))
            if r != 0 { return abort(Self.isDenied(r) ? .denied : .failed("写入风扇模式失败")) }
        } else {
            var pending = fans
            var lastErr: Int32 = 0
            func tryModes() {
                pending = pending.filter { fan in
                    let r = q_write(fan.modeKey!, 1)
                    if r != 0 { lastErr = r }
                    return r != 0
                }
            }
            tryModes()
            if !pending.isEmpty && Self.isDenied(lastErr) { return abort(.denied) }
            if !pending.isEmpty && hw.hasFtst {
                // M4-class: thermalmonitord holds mode 3 until the Ftst diagnostic unlock;
                // the mode write starts succeeding a few seconds later.
                let r = q_write("Ftst", 1)
                if Self.isDenied(r) { return abort(.denied) }
                if r == 0 { q_wroteFtst = true }
                let deadline = Date().addingTimeInterval(10)
                while !pending.isEmpty && Date() < deadline {
                    if stop() { return abort(.cancelled) }
                    Thread.sleep(forTimeInterval: 0.1)
                    tryModes()
                }
            }
            if !pending.isEmpty { return abort(.failed("系统拒绝切换手动模式")) }
        }
        if stop() { return abort(.cancelled) }
        var applied: [Int: Double] = [:]
        for (fan, t) in plan {
            let key = "F\(fan.index)Tg"
            let r = q_write(key, t)
            if Self.isDenied(r) { return abort(.denied) }
            // 0x87 (size mismatch) is reported on some targets even though the value applied
            if r != 0, !(r == Self.smcKeySizeMismatch && abs((q_read(key) ?? 0) - t) < 100) {
                return abort(.failed("写入目标转速失败"))
            }
            applied[fan.index] = t
        }
        return .boosted(applied)
    }

    /// Periodic check (every `verifyInterval`): re-assert manual mode / target if the
    /// system took them back. Writes only when something actually drifted.
    private func q_verify(_ hw: Hardware, targets: [Int: Double]) -> VerifyResult {
        var drifted = false
        for fan in q_forcedFans {
            guard let t = targets[fan.index] else { continue }
            if let key = fan.modeKey, q_read(key) != 1 {
                drifted = true
                if hw.hasFtst, q_read("Ftst") != 1 {
                    let r = q_write("Ftst", 1)
                    if Self.isDenied(r) { return .denied }
                    if r == 0 { q_wroteFtst = true }
                }
                let r = q_write(key, 1)
                if Self.isDenied(r) { return .denied }
                if r != 0 { continue }
            }
            let tgKey = "F\(fan.index)Tg"
            if let tg = q_read(tgKey), abs(tg - t) <= 100 { continue }
            drifted = true
            let r = q_write(tgKey, t)
            if Self.isDenied(r) { return .denied }
        }
        if !drifted { return .ok }
        // Re-read once: did re-asserting stick?
        for fan in q_forcedFans {
            if let key = fan.modeKey, q_read(key) != 1 { return .lost }
        }
        return .ok
    }

    /// Hand every fan we forced back to automatic. No-op if we forced nothing.
    @discardableResult
    private func q_restore(_ hw: Hardware) -> Bool {
        guard q_owned else {
            // Nothing of ours was ever accepted (e.g. first write denied): just drop the claim
            q_clearOwnership(); return true
        }
        var ok = true
        if q_forcedLegacy {
            if q_write("FS! ", 0) != 0 && q_write("FS! ", 0) != 0 { ok = false }
        } else {
            for fan in q_forcedFans {
                guard let key = fan.modeKey else { continue }
                if q_write(key, 0) == 0 || q_write(key, 0) == 0 { continue }
                // Rejected because the system already reclaimed it (0 auto / 3 system) is fine
                if let m = q_read(key), m == 0 || m == 3 { continue }
                ok = false
            }
        }
        if hw.hasFtst && (q_wroteFtst || q_read("Ftst") == 1) {
            if q_write("Ftst", 0) != 0 && q_write("Ftst", 0) != 0 { ok = false }
        }
        if ok { q_clearOwnership() }
        // On failure the guard and dirty marker stay armed: the crash handler, the next
        // restore and the next launch all try again; thermalmonitord also reclaims on exit.
        return ok
    }

    private func q_clearOwnership() {
        q_forcedFans = []; q_forcedLegacy = false; q_wroteFtst = false; q_owned = false
        hw_smc_guard_arm(0)
        prefs.set(false, forKey: dirtyKey)
    }
}
