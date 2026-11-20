import Foundation

enum StatusShowKey: String, CaseIterable {
    case cpu = "showCPU"
    case gpu = "showGPU"
    case mem = "showMem"
    case chip = "showChip"
    case fan = "showFan"
    case power = "showPower"
    case disk = "showDisk"
    case net = "showNet"

    var title: String {
        switch self {
        case .cpu: return "CPU 占用"
        case .gpu: return "GPU 占用"
        case .mem: return "内存占用"
        case .chip: return "温度"
        case .fan: return "风扇转速"
        case .power: return "整机功耗"
        case .disk: return "磁盘占用"
        case .net: return "网速"
        }
    }

    var defaultOn: Bool {
        switch self {
        case .cpu, .mem, .chip, .net: return true
        default: return false
        }
    }
}

enum MenubarStyle: String, CaseIterable, Equatable {
    case compact = "compact"
    case standard = "standard"

    var title: String {
        switch self {
        case .compact: return "紧凑双行"
        case .standard: return "标准单行"
        }
    }
}

/// Fixed-capacity circular buffer for live panel sparklines (~300 bytes per series, zero heap churn).
struct HistoryRing: Equatable {
    let capacity: Int
    private var storage: [Double]
    private var head: Int = 0
    private(set) var count: Int = 0

    init(capacity: Int = 36) {
        self.capacity = max(2, capacity)
        self.storage = Array(repeating: 0, count: max(2, capacity))
    }

    mutating func push(_ value: Double) {
        let v = value.isFinite ? max(0, value) : 0
        storage[head] = v
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    mutating func reset() {
        head = 0
        count = 0
    }

    /// Ordered oldest → newest.
    var values: [Double] {
        guard count > 0 else { return [] }
        var out = [Double]()
        out.reserveCapacity(count)
        let start = (head - count + capacity) % capacity
        for i in 0..<count {
            out.append(storage[(start + i) % capacity])
        }
        return out
    }
}

enum TelemetrySource: Equatable {
    case native
    case macmon
    case unavailable

    var label: String {
        switch self {
        case .native: return "原生直采 (SMC + IOReport)"
        case .macmon: return "macmon 回退"
        case .unavailable: return "仅基础系统指标"
        }
    }
}

enum MemPressure: Equatable {
    case normal, warn, critical

    static func from(kernelLevel: Int32, fallbackPercent: Double) -> MemPressure {
        switch kernelLevel {
        case 1: return .normal
        case 2: return .warn
        case 4: return .critical
        default:
            if fallbackPercent < 70 { return .normal }
            if fallbackPercent < 85 { return .warn }
            return .critical
        }
    }

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warn: return "偏高"
        case .critical: return "紧张"
        }
    }
}

struct MemInfo {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var usedPercent: Double = 0
    var pressure: MemPressure = .normal
}

struct DiskInfo {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var usedPercent: Double = 0
}

struct ThermalInfo {
    var chipC: Double?
    var cpuC: Double?
    var gpuC: Double?
    var fanRpm: Int?
    var fanMaxRpm: Int?
    var pressureLabel: String = ""
    var sampleWall: TimeInterval?
}

struct PowerInfo {
    var sysW: Double?
    var cpuW: Double?
    var gpuW: Double?
    var aneW: Double?
}

struct CPUTiers {
    var e: Double = 0
    var p: Double = 0
    var s: Double = 0
    var hasSuper: Bool = false
    var valid: Bool = false
}

struct AggProc {
    var name: String
    var mainPid: Int32
    var appKey: String
    var execPath: String = ""
    var processCount: Int = 1
    var footprint: UInt64
    var cpuPercent: Double
}

struct MetricsSnapshot {
    var cpu: Double = 0
    var cpuUser: Double = 0
    var cpuSys: Double = 0
    var loadAvg1m: Double = 0
    var mem = MemInfo()
    var memShownPct: Int = 0
    var disk = DiskInfo()
    var thermal = ThermalInfo()
    var power = PowerInfo()
    var gpuPct: Double?
    var gpuSampleWall: TimeInterval?
    var tiers = CPUTiers()
    var netDown: Double = 0
    var netUp: Double = 0
    var procs: [AggProc] = []
}

enum Formatters {
    private static let byteUnits = ["B", "KB", "MB", "GB", "TB"]

    static func clampPct(_ v: Double) -> Int {
        guard v.isFinite else { return 0 }
        return min(100, max(0, Int(v.rounded())))
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        var value = Double(bytes)
        var idx = 0
        while value >= 1024 && idx < byteUnits.count - 1 {
            value /= 1024
            idx += 1
        }
        if idx == 0 { return String(format: "%.0f %@", value, byteUnits[idx]) }
        if idx >= 3 {
            if value >= 100 { return String(format: "%.0f %@", value, byteUnits[idx]) }
            return String(format: "%.1f %@", value, byteUnits[idx])
        }
        return String(format: "%.0f %@", value.rounded(), byteUnits[idx])
    }

    static func formatRate(_ bps: Double) -> String {
        let v = max(0, bps.isFinite ? bps : 0)
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1024 * 1024 { return String(format: "%.1f KB/s", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", v / (1024 * 1024)) }
        return String(format: "%.2f GB/s", v / (1024 * 1024 * 1024))
    }

    static func formatRateShort(_ bps: Double) -> String {
        let v = max(0, bps.isFinite ? bps : 0)
        if v < 1024 { return String(format: "%5.0f B/s", v) }
        if v < 1024 * 1024 { return String(format: "%5.1f KB/s", v / 1024) }
        if v < 1024 * 1024 * 1024 { return String(format: "%5.1f MB/s", v / (1024 * 1024)) }
        return String(format: "%5.2f GB/s", v / (1024 * 1024 * 1024))
    }

    /// Gapless single-line rate for standard menubar mode (e.g. "28.8 KB/s", "1.4 MB/s").
    static func formatRateTight(_ bps: Double) -> String {
        let v = max(0, bps.isFinite ? bps : 0)
        if v < 1024 { return String(format: "%.0f B/s", v) }
        if v < 1024 * 1024 {
            let k = v / 1024
            return k >= 100 ? String(format: "%.0f KB/s", k) : String(format: "%.1f KB/s", k)
        }
        if v < 1024 * 1024 * 1024 {
            let m = v / (1024 * 1024)
            return m >= 100 ? String(format: "%.0f MB/s", m) : String(format: "%.1f MB/s", m)
        }
        return String(format: "%.2f GB/s", v / (1024 * 1024 * 1024))
    }

    /// Ultra-compact rate for stacked 2-line menubar mode (e.g. "0B", "28.8K", "124K", "1.4M").
    static func formatRateCompact(_ bps: Double) -> String {
        let v = max(0, bps.isFinite ? bps : 0)
        if v < 1024 { return String(format: "%.0fB", v) }
        if v < 1024 * 1024 {
            let k = v / 1024
            return k >= 100 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        }
        if v < 1024 * 1024 * 1024 {
            let m = v / (1024 * 1024)
            return m >= 100 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        }
        return String(format: "%.1fG", v / (1024 * 1024 * 1024))
    }

    static func formatWatts(_ watts: Double) -> String {
        let v = max(0, watts.isFinite ? watts : 0)
        if v >= 100 { return String(format: "%.0f W", v) }
        return String(format: "%.1f W", v)
    }

    static func formatUptime(_ sec: TimeInterval) -> String {
        let s = max(0, Int(sec))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return "\(d)天\(h)时" }
        if h > 0 { return "\(h)时\(m)分" }
        return "\(m)分"
    }
}

/// Display-side smoothing with continuous time-constant EMA + integer dead band.
/// Only advances sensor EMAs when a genuinely newer sample timestamp arrives.
struct DisplaySmoothing {
    struct EMA {
        let tauUp: Double
        let tauDown: Double
        private(set) var value: Double?
        private var wall: TimeInterval = 0

        init(tau: Double) { tauUp = tau; tauDown = tau }
        init(tauUp: Double, tauDown: Double) { self.tauUp = tauUp; self.tauDown = tauDown }

        mutating func push(_ x: Double, at now: TimeInterval) -> Double {
            guard x.isFinite else { return value ?? 0 }
            guard let v = value else { value = x; wall = now; return x }
            let dt = now - wall
            if dt <= 0 { return v }
            let a = 1 - exp(-dt / (x > v ? tauUp : tauDown))
            let out = v + a * (x - v)
            value = out
            wall = now
            return out
        }

        mutating func reset() { value = nil; wall = 0 }
    }

    /// Integer readout with ±0.65 dead band to suppress boundary flicker (e.g. 14 ↔ 15).
    struct SteadyInt {
        private(set) var shown: Int?

        mutating func update(_ v: Double) -> Int {
            let r = Int(v.rounded())
            if let s = shown, abs(v - Double(s)) < 0.65 { return s }
            shown = r
            return r
        }

        mutating func reset() { shown = nil }
    }

    var cpu = EMA(tau: 3.5), cpuUser = EMA(tau: 3.5), cpuSys = EMA(tau: 3.5)
    var gpu = EMA(tau: 3.5)
    var cpuC = EMA(tau: 4.5), gpuC = EMA(tau: 4.5)
    var sysW = EMA(tau: 4.0)
    var down = EMA(tauUp: 2.0, tauDown: 4.5), up = EMA(tauUp: 2.0, tauDown: 4.5)

    var cpuI = SteadyInt(), memI = SteadyInt(), gpuI = SteadyInt()
    var cpuCI = SteadyInt(), gpuCI = SteadyInt()

    private var lastThermalWall: TimeInterval?
    private var lastGPUWall: TimeInterval?

    static let netHold: TimeInterval = 2.0
    var netShown: (down: Double, up: Double) = (0, 0)
    var netShownWall: TimeInterval = -.infinity

    static func rateMoved(_ new: Double, from shown: Double) -> Bool {
        abs(new - shown) > max(0.10 * shown, 1024)
    }

    mutating func reset() { self = DisplaySmoothing() }

    mutating func apply(
        to snapshot: inout MetricsSnapshot,
        rawCPU: Double, rawUser: Double, rawSys: Double,
        rawNetDown: Double, rawNetUp: Double,
        now: TimeInterval
    ) {
        snapshot.cpu = Double(cpuI.update(cpu.push(rawCPU, at: now)))
        snapshot.cpuUser = cpuUser.push(rawUser, at: now)
        snapshot.cpuSys = cpuSys.push(rawSys, at: now)
        snapshot.memShownPct = min(100, max(0, memI.update(snapshot.mem.usedPercent)))
        applyTelemetry(to: &snapshot, now: now)

        let d = down.push(rawNetDown, at: now)
        let u = up.push(rawNetUp, at: now)
        if now - netShownWall >= Self.netHold - 0.2,
           Self.rateMoved(d, from: netShown.down) || Self.rateMoved(u, from: netShown.up) {
            netShown = (d, u)
            netShownWall = now
        }
        snapshot.netDown = netShown.down
        snapshot.netUp = netShown.up
    }

    /// Smooths only asynchronous hardware telemetry (GPU / thermal / power) without re-pushing CPU or network EMAs.
    mutating func applyTelemetry(to snapshot: inout MetricsSnapshot, now: TimeInterval) {
        // GPU: only push into EMA when a new sample timestamp arrives
        if let g = snapshot.gpuPct {
            let gw = snapshot.gpuSampleWall ?? now
            if lastGPUWall != gw {
                lastGPUWall = gw
                snapshot.gpuPct = Double(gpuI.update(gpu.push(g, at: gw)))
            } else if let shown = gpuI.shown {
                snapshot.gpuPct = Double(shown)
            }
        } else {
            gpu.reset(); gpuI.reset(); lastGPUWall = nil
        }

        // Thermal & system power: only push into EMA on new SMC sample timestamp
        var t = snapshot.thermal
        let tw = t.sampleWall ?? now
        let isNewThermal = lastThermalWall != tw
        if isNewThermal { lastThermalWall = tw }

        if let c = t.cpuC {
            if isNewThermal {
                t.cpuC = Double(cpuCI.update(cpuC.push(c, at: tw)))
            } else if let shown = cpuCI.shown {
                t.cpuC = Double(shown)
            }
        } else {
            cpuC.reset(); cpuCI.reset()
        }

        if let g = t.gpuC {
            if isNewThermal {
                t.gpuC = Double(gpuCI.update(gpuC.push(g, at: tw)))
            } else if let shown = gpuCI.shown {
                t.gpuC = Double(shown)
            }
        } else {
            gpuC.reset(); gpuCI.reset()
        }

        t.chipC = [t.cpuC, t.gpuC].compactMap { $0 }.max()
        snapshot.thermal = t

        if let sw = snapshot.power.sysW {
            snapshot.power.sysW = isNewThermal ? sysW.push(sw, at: tw) : (sysW.value ?? sw)
        } else {
            sysW.reset()
        }
    }
}
