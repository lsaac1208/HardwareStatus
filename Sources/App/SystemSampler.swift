import Cocoa
import Darwin
import Foundation

/// Owns all OS and hardware telemetry sampling, isolated from AppKit view logic.
/// - Synchronous cheap calls (CPU ticks, VM stats, 64-bit physical NIC counters, disk cache) run on main.
/// - SMC / IOReport / macmon fallback run on a dedicated serial `.utility` queue.
/// - Process enumeration runs on a separate serial `.utility` queue so opening the panel never stalls UI.
final class SystemSampler {
    let chipName: String
    let modelId: String
    let memTotalBytes: UInt64
    let memTotalGB: String
    let memPageSize: UInt64

    private let hostPort: mach_port_t = mach_host_self()

    // CPU delta state (main thread)
    private var lastCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    private var lastCPUWall: TimeInterval = 0
    private var lastCPUValue: Double = 0
    private var lastCPUUserSys: (user: Double, system: Double) = (0, 0)

    // 64-bit physical network state (main thread)
    private var lastIfBytes: [String: (inB: UInt64, outB: UInt64)] = [:]
    private var lastNetWall: TimeInterval?
    private(set) var netDownBps: Double = 0
    private(set) var netUpBps: Double = 0

    // Disk cache (main thread)
    private var diskCache: (info: DiskInfo, wall: TimeInterval)?
    let diskMaxAge: TimeInterval = 15

    // Native SMC + IOReport + optional macmon fallback (guarded by sensorLock / sensorQueue)
    private let sensorQueue = DispatchQueue(label: "local.lsaac128.HardwareStatus.sensors", qos: .utility)
    private let sensorLock = NSLock()
    private var sensorInFlight = false
    private var lastSensorLaunchWall: TimeInterval = -.infinity
    private var iorWarmupScheduled = false
    let sensorIdleMinInterval: TimeInterval = 5.0

    private var cachedCpuC: Double?
    private var cachedGpuC: Double?
    private var cachedFanRpm: Int?
    private var cachedFanMaxRpm: Int?
    private var cachedTempWall: TimeInterval?
    private var cachedGpuPct: Double?
    private var cachedGpuWall: TimeInterval?
    private var cachedTiers = CPUTiers()
    private var cachedPower = PowerInfo()
    private var cachedSource: TelemetrySource = .unavailable

    // macmon fallback (only used if native SMC + IOReport both yield nothing)
    private var macmonPath: String?
    private var macmonProbeWall: TimeInterval = -.infinity
    private let macmonTimeout: TimeInterval = 5.0

    // Background process scanner (state confined to procQueue)
    private let procQueue = DispatchQueue(label: "local.lsaac128.HardwareStatus.procs", qos: .utility)
    private var procInFlight = false
    private var lastProcSampleWall: TimeInterval = 0
    private var lastProcCPU: [Int32: (cpuNs: UInt64, startNs: UInt64, wall: TimeInterval)] = [:]
    private var procCPUSmooth: [String: Double] = [:]
    private var procSmoothReset = true
    private var procWarmupPending = false
    private var procPathBuf = [CChar](repeating: 0, count: 4 * 1024)
    private var procIdentityCache: [String: (name: String, key: String, isHelper: Bool)] = [:]
    private var displayNameCache: [String: String] = [:]

    var onSensorsUpdated: (() -> Void)?

    init() {
        var name = "Apple Silicon"
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { name = s }
        }
        chipName = name

        var model = "Mac"
        size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &buf, &size, nil, 0)
            let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { model = s }
        }
        modelId = model

        var mem: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &mem, &len, nil, 0)
        memTotalBytes = mem
        memTotalGB = String(format: "%.0f GB", Double(mem) / 1_073_741_824.0)

        var ps: vm_size_t = 0
        memPageSize = (host_page_size(hostPort, &ps) == KERN_SUCCESS && ps > 0) ? UInt64(ps) : 16384
    }

    func resetAfterWake() {
        lastNetWall = nil
        lastIfBytes.removeAll()
        lastCPUTicks = nil
        sensorQueue.async { hw_ioreport_reset() }
        resetProcessSmoothing()
    }

    func resetProcessSmoothing() {
        procQueue.async { [weak self] in
            self?.procCPUSmooth.removeAll()
            self?.procSmoothReset = true
        }
    }

    func shutdown() {
        sensorQueue.sync {
            hw_ioreport_close()
        }
    }

    var telemetrySource: TelemetrySource {
        sensorLock.lock()
        defer { sensorLock.unlock() }
        return cachedSource
    }

    // MARK: - CPU / Memory / Load / Disk / Network (fast, main thread)

    func sampleCPU() -> (total: Double, user: Double, system: Double) {
        let wall = ProcessInfo.processInfo.systemUptime
        if lastCPUTicks != nil && wall - lastCPUWall < 0.5 {
            return (lastCPUValue, lastCPUUserSys.user, lastCPUUserSys.system)
        }
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCpuInfo: mach_msg_type_number_t = 0
        let result = host_processor_info(hostPort, PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else {
            return (lastCPUValue, lastCPUUserSys.user, lastCPUUserSys.system)
        }
        defer {
            let size = vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

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

        guard let last = lastCPUTicks,
              user >= last.user, system >= last.system, idle >= last.idle, nice >= last.nice else {
            return (lastCPUValue, lastCPUUserSys.user, lastCPUUserSys.system)
        }
        let total = (user - last.user) + (system - last.system) + (idle - last.idle) + (nice - last.nice)
        guard total > 0 else { return (lastCPUValue, lastCPUUserSys.user, lastCPUUserSys.system) }

        let u = Double((user - last.user) + (nice - last.nice)) / Double(total) * 100.0
        let s = Double(system - last.system) / Double(total) * 100.0
        lastCPUUserSys = (u, s)
        lastCPUValue = u + s
        return (lastCPUValue, u, s)
    }

    func sampleLoadAvg1m() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        let n = loads.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        return n >= 1 ? loads[0] : 0
    }

    func sampleMemory(includeSwap: Bool) -> MemInfo {
        let totalSize = memTotalBytes
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return MemInfo(total: totalSize)
        }
        let page = memPageSize
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (internalPages > purgeable ? internalPages - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let cached = UInt64(stats.external_page_count) * page
        let used = app + wired + compressed
        let pct = totalSize > 0 ? Double(used) / Double(totalSize) * 100.0 : 0
        let swapUsed: UInt64 = includeSwap ? sampleSwap() : 0
        let pressure = MemPressure.from(kernelLevel: hw_memory_pressure_level(), fallbackPercent: pct)
        return MemInfo(
            total: totalSize, used: used, app: app, wired: wired, compressed: compressed,
            cached: cached, swapUsed: swapUsed, usedPercent: pct, pressure: pressure
        )
    }

    private func sampleSwap() -> UInt64 {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        return sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 ? UInt64(xsw.xsu_used) : 0
    }

    func sampleDisk(maxAge: TimeInterval) -> DiskInfo {
        let now = ProcessInfo.processInfo.systemUptime
        if let c = diskCache, now - c.wall < maxAge { return c.info }
        let info = queryDisk()
        diskCache = (info, now)
        return info
    }

    private func queryDisk() -> DiskInfo {
        do {
            let vals = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ])
            let total = UInt64(vals.volumeTotalCapacity ?? 0)
            let avail: UInt64
            if let important = vals.volumeAvailableCapacityForImportantUsage { avail = UInt64(important) }
            else { avail = UInt64(vals.volumeAvailableCapacity ?? 0) }
            let used = total > avail ? total - avail : 0
            let pct = total > 0 ? Double(used) / Double(total) * 100.0 : 0
            return DiskInfo(total: total, used: used, usedPercent: pct)
        } catch {
            return DiskInfo()
        }
    }

    /// True 64-bit physical-only network throughput (en* / pdp_ip*, zero VPN/TUN double-counting).
    func sampleNetwork() -> (down: Double, up: Double) {
        let wall = ProcessInfo.processInfo.systemUptime
        let dt = lastNetWall.map { wall - $0 } ?? 0
        if lastNetWall != nil && dt <= 0.2 { return (netDownBps, netUpBps) }

        var raw = hw_net_sample_t()
        guard hw_net_sample(&raw) == 0 else { return (netDownBps, netUpBps) }

        var dIn: UInt64 = 0
        var dOut: UInt64 = 0
        var next: [String: (inB: UInt64, outB: UInt64)] = [:]
        next.reserveCapacity(Int(raw.count))

        let count = Int(raw.count)
        withUnsafePointer(to: &raw.ifaces) { ptr in
            ptr.withMemoryRebound(to: hw_net_iface_t.self, capacity: Int(HW_NET_MAX_IFACES)) { arr in
                for i in 0..<count {
                    var iface = arr[i]
                    let name = withUnsafePointer(to: &iface.name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                    }
                    let cur = (inB: iface.in_bytes, outB: iface.out_bytes)
                    if let prev = lastIfBytes[name] {
                        if cur.inB >= prev.inB { dIn &+= cur.inB - prev.inB }
                        if cur.outB >= prev.outB { dOut &+= cur.outB - prev.outB }
                    }
                    next[name] = cur
                }
            }
        }

        if lastNetWall != nil, dt > 0 {
            netDownBps = Double(dIn) / dt
            netUpBps = Double(dOut) / dt
        }
        lastIfBytes = next
        lastNetWall = wall
        return (netDownBps, netUpBps)
    }

    // MARK: - Thermal / GPU / Power / Tiers (cached snapshot + background native refresh)

    func currentTelemetry() -> (thermal: ThermalInfo, power: PowerInfo, gpuPct: Double?, gpuWall: TimeInterval?, tiers: CPUTiers) {
        let pressure: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "温控正常"
            case .fair: return "温控一般"
            case .serious: return "温控偏高"
            case .critical: return "温控危急"
            @unknown default: return "温控未知"
            }
        }()
        sensorLock.lock()
        let cpu = cachedCpuC
        let gpu = cachedGpuC
        let fan = cachedFanRpm
        let fanMax = cachedFanMaxRpm
        let wall = cachedTempWall
        let gpuPct = cachedGpuPct
        let gpuWall = cachedGpuWall
        let tiers = cachedTiers
        let power = cachedPower
        sensorLock.unlock()

        let chip = [cpu, gpu].compactMap { $0 }.max()
        let thermal = ThermalInfo(
            chipC: chip, cpuC: cpu, gpuC: gpu,
            fanRpm: fan, fanMaxRpm: fanMax,
            pressureLabel: pressure, sampleWall: wall
        )
        return (thermal, power, gpuPct, gpuWall, tiers)
    }

    func refreshSensorsAsync(
        panelVisible: Bool,
        visibleKeys: [StatusShowKey],
        fanBoostWantsTemp: Bool,
        force: Bool
    ) {
        let needSMC = force || panelVisible || fanBoostWantsTemp ||
            visibleKeys.contains(where: { $0 == .chip || $0 == .fan || $0 == .power })
        let needIOR = panelVisible || visibleKeys.contains(.gpu)
        if !needSMC && !needIOR { return }

        let now = ProcessInfo.processInfo.systemUptime
        if !force && !panelVisible && now - lastSensorLaunchWall < sensorIdleMinInterval - 0.5 {
            return
        }

        sensorLock.lock()
        if sensorInFlight { sensorLock.unlock(); return }
        sensorInFlight = true
        sensorLock.unlock()
        lastSensorLaunchWall = now

        sensorQueue.async { [weak self] in
            guard let self = self else { return }
            var needsIorWarmup = false
            let sampleWall = ProcessInfo.processInfo.systemUptime

            var smc = hw_smc_sensors_t()
            var smcOk = false
            if needSMC, hw_smc_read_sensors(&smc) == 0 {
                smcOk = (smc.has_cpu_temp != 0 || smc.has_gpu_temp != 0 || smc.has_fan_rpm != 0 || smc.has_sys_power != 0)
            }

            var ior = hw_ioreport_sample_t()
            var iorOk = false
            if needIOR, hw_ioreport_available() != 0 {
                if hw_ioreport_sample(&ior) == 0 {
                    if ior.valid != 0 {
                        iorOk = true
                    } else {
                        needsIorWarmup = true
                    }
                }
            }

            if smcOk || iorOk {
                self.sensorLock.lock()
                self.cachedSource = .native
                if smcOk {
                    if smc.has_cpu_temp != 0 { self.cachedCpuC = smc.cpu_temp_c }
                    if smc.has_gpu_temp != 0 { self.cachedGpuC = smc.gpu_temp_c }
                    if smc.has_fan_rpm != 0 {
                        self.cachedFanRpm = Int(smc.fan_rpm)
                        self.cachedFanMaxRpm = smc.fan_max_rpm > 0 ? Int(smc.fan_max_rpm) : nil
                    }
                    if smc.has_sys_power != 0 { self.cachedPower.sysW = smc.sys_power_w }
                    self.cachedTempWall = sampleWall
                }
                if iorOk {
                    if ior.has_gpu != 0 {
                        self.cachedGpuPct = min(100.0, max(0.0, ior.gpu_active * 100.0))
                        self.cachedGpuWall = sampleWall
                    }
                    if ior.has_cpu_tiers != 0 {
                        self.cachedTiers = CPUTiers(
                            e: ior.cpu_e, p: ior.cpu_p, s: ior.cpu_s,
                            hasSuper: ior.has_super != 0, valid: true
                        )
                    }
                    if ior.has_cpu_power != 0 { self.cachedPower.cpuW = ior.cpu_power_w }
                    if ior.has_gpu_power != 0 { self.cachedPower.gpuW = ior.gpu_power_w }
                    if ior.has_ane_power != 0 { self.cachedPower.aneW = ior.ane_power_w }
                }
                self.sensorInFlight = false
                self.sensorLock.unlock()

                DispatchQueue.main.async { [weak self] in self?.onSensorsUpdated?() }

                if needsIorWarmup {
                    self.scheduleIorWarmup()
                }
                return
            }

            if needsIorWarmup {
                self.sensorLock.lock()
                self.sensorInFlight = false
                self.sensorLock.unlock()
                self.scheduleIorWarmup()
                return
            }

            // Fallback: only if neither SMC nor IOReport is available (e.g. non-Apple-Silicon / unusual env)
            let fallbackOk = self.sampleViaMacmonFallback()
            self.sensorLock.lock()
            if !fallbackOk && self.cachedSource == .unavailable {
                self.cachedSource = .unavailable
            }
            self.sensorInFlight = false
            self.sensorLock.unlock()

            if fallbackOk {
                DispatchQueue.main.async { [weak self] in self?.onSensorsUpdated?() }
            }
        }
    }

    private func scheduleIorWarmup() {
        sensorLock.lock()
        if iorWarmupScheduled { sensorLock.unlock(); return }
        iorWarmupScheduled = true
        sensorLock.unlock()

        sensorQueue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            self.sensorLock.lock()
            self.iorWarmupScheduled = false
            self.sensorLock.unlock()
            var ior = hw_ioreport_sample_t()
            guard hw_ioreport_sample(&ior) == 0, ior.valid != 0 else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.sensorLock.lock()
            self.cachedSource = .native
            if ior.has_gpu != 0 {
                self.cachedGpuPct = min(100.0, max(0.0, ior.gpu_active * 100.0))
                self.cachedGpuWall = now
            }
            if ior.has_cpu_tiers != 0 {
                self.cachedTiers = CPUTiers(
                    e: ior.cpu_e, p: ior.cpu_p, s: ior.cpu_s,
                    hasSuper: ior.has_super != 0, valid: true
                )
            }
            if ior.has_cpu_power != 0 { self.cachedPower.cpuW = ior.cpu_power_w }
            if ior.has_gpu_power != 0 { self.cachedPower.gpuW = ior.gpu_power_w }
            if ior.has_ane_power != 0 { self.cachedPower.aneW = ior.ane_power_w }
            self.sensorLock.unlock()
            DispatchQueue.main.async { [weak self] in self?.onSensorsUpdated?() }
        }
    }

    private func resolveMacmonPath() -> String? {
        if let p = macmonPath { return p }
        let now = ProcessInfo.processInfo.systemUptime
        if now - macmonProbeWall < 60 { return nil }
        macmonProbeWall = now
        var candidates = [
            "/opt/homebrew/bin/macmon", "/usr/local/bin/macmon",
            NSHomeDirectory() + "/.cargo/bin/macmon", "/opt/local/bin/macmon"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/macmon" }
        }
        macmonPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        return macmonPath
    }

    private func sampleViaMacmonFallback() -> Bool {
        guard let path = resolveMacmonPath() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["pipe", "-s", "1", "-i", "200"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }

        // Cancellable watchdog so a normal 250 ms exit doesn't cause an extra timer wakeup 5 s later
        let watchdog = DispatchWorkItem { [weak proc] in
            if proc?.isRunning == true { proc?.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + macmonTimeout, execute: watchdog)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first,
              let jsonData = String(line).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return false }

        var cpu: Double?
        var gpu: Double?
        if let temp = obj["temp"] as? [String: Any] {
            if let v = temp["cpu_temp_avg"] as? Double, v.isFinite, v > 0, v < 150 { cpu = v }
            if let v = temp["gpu_temp_avg"] as? Double, v.isFinite, v > 0, v < 150 { gpu = v }
        }
        var fanRpm: Int?
        var fanMax: Int?
        if let fans = obj["fans"] as? [[String: Any]] {
            var best = -1
            for f in fans {
                let rpm = (f["rpm"] as? Int) ?? (f["rpm"] as? Double).map { Int($0.rounded()) } ?? -1
                if rpm > best { best = rpm }
                if let mx = (f["max_rpm"] as? Int) ?? (f["max_rpm"] as? Double).map({ Int($0.rounded()) }), mx > (fanMax ?? 0) {
                    fanMax = mx
                }
            }
            if best >= 0 { fanRpm = best }
        }
        var gpuPct: Double?
        if let r = obj["gpu_active_ratio"] as? Double, r.isFinite {
            gpuPct = min(100, max(0, r * 100.0))
        } else if let arr = obj["gpu_usage"] as? [Any], arr.count >= 2, let u = arr[1] as? Double, u.isFinite {
            gpuPct = min(100, max(0, u * 100.0))
        }
        var tiers = CPUTiers()
        if let arr = obj["cpu_tiers"] as? [[String: Any]] {
            for t in arr {
                let label = (t["label"] as? String) ?? ""
                let ratio = (t["active_ratio"] as? Double) ?? 0
                switch label {
                case "E": tiers.e = ratio; tiers.valid = true
                case "P": tiers.p = ratio; tiers.valid = true
                case "S": tiers.s = ratio; tiers.hasSuper = true; tiers.valid = true
                default: break
                }
            }
        }
        let wall = ProcessInfo.processInfo.systemUptime
        sensorLock.lock()
        cachedSource = .macmon
        cachedCpuC = cpu; cachedGpuC = gpu
        cachedFanRpm = fanRpm; cachedFanMaxRpm = fanMax
        cachedTempWall = wall
        cachedGpuPct = gpuPct; cachedGpuWall = wall
        cachedTiers = tiers
        if let sw = obj["sys_power"] as? Double, sw.isFinite, sw >= 0 { cachedPower.sysW = sw }
        if let cw = obj["cpu_power"] as? Double, cw.isFinite, cw >= 0 { cachedPower.cpuW = cw }
        if let gw = obj["gpu_power"] as? Double, gw.isFinite, gw >= 0 { cachedPower.gpuW = gw }
        if let aw = obj["ane_power"] as? Double, aw.isFinite, aw >= 0 { cachedPower.aneW = aw }
        sensorLock.unlock()
        return true
    }

    // MARK: - Off-Main-Thread Process Scanner

    func scanProcessesAsync(
        runningAppPIDs: Set<Int32>,
        onResult: @escaping (_ procs: [AggProc], _ needsWarmup: Bool) -> Void
    ) {
        procQueue.async { [weak self] in
            guard let self = self, !self.procInFlight else { return }
            let wall = ProcessInfo.processInfo.systemUptime
            let dt = wall - self.lastProcSampleWall
            if dt < 0.5 { return }

            self.procInFlight = true
            defer { self.procInFlight = false }

            var procs = self.aggregateByApp(self.sampleProcessesRaw(wall: wall), runningAppPIDs: runningAppPIDs)
            let a = self.procSmoothReset ? 1.0 : (1.0 - exp(-dt / 2.0))
            self.procSmoothReset = dt > 3.0
            var next: [String: Double] = [:]
            next.reserveCapacity(procs.count)
            for i in procs.indices {
                let raw = procs[i].cpuPercent
                let v = self.procCPUSmooth[procs[i].appKey].map { $0 + a * (raw - $0) } ?? raw
                procs[i].cpuPercent = v
                next[procs[i].appKey] = v
            }
            self.procCPUSmooth = next

            let shouldWarmup = dt > 3.0 && !self.procWarmupPending
            if shouldWarmup { self.procWarmupPending = true }
            DispatchQueue.main.async {
                onResult(procs, shouldWarmup)
            }
        }
    }

    func clearProcWarmupFlag() {
        procQueue.async { [weak self] in self?.procWarmupPending = false }
    }

    func verifyPidMatchesAppKey(pid: Int32, appKey: String) -> Bool {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        let len = buf.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if len > 0 {
            let path = String(cString: buf)
            if let range = path.range(of: ".app/") {
                return String(path[..<range.upperBound].dropLast()) == appKey
            }
            return path == appKey
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            return "name:\(String(cString: nameBuf))" == appKey
        }
        return "pid:\(pid)" == appKey
    }

    private struct ProcRow {
        var pid: Int32
        var name: String
        var appKey: String
        var isHelper: Bool
        var footprint: UInt64
        var cpuPercent: Double
    }

    private func sampleProcessesRaw(wall: TimeInterval) -> [ProcRow] {
        lastProcSampleWall = wall
        let pids = listAllPIDs()
        var rows: [ProcRow] = []
        rows.reserveCapacity(256)
        var nextCPU: [Int32: (cpuNs: UInt64, startNs: UInt64, wall: TimeInterval)] = [:]
        nextCPU.reserveCapacity(pids.count)
        let selfPid = getpid()

        for pid in pids {
            if pid <= 0 || pid == selfPid { continue }
            var sample = hw_proc_sample_t()
            guard hw_proc_sample(pid, &sample) == 0 else { continue }

            let totalNs = sample.user_ns &+ sample.system_ns
            var cpuPct: Double = 0
            if let prev = lastProcCPU[pid], prev.startNs == sample.start_ns, totalNs >= prev.cpuNs {
                let dWall = wall - prev.wall
                if dWall > 0 {
                    cpuPct = (Double(totalNs - prev.cpuNs) / 1e9) / dWall * 100.0
                }
            }
            nextCPU[pid] = (totalNs, sample.start_ns, wall)

            // Keep lightweight high-CPU CLI processes in addition to >= 2 MB processes
            if sample.phys_footprint < 2 * 1024 * 1024 && cpuPct < 0.5 { continue }

            let (name, appKey, isHelper) = friendlyIdentity(for: pid)
            rows.append(ProcRow(
                pid: pid, name: name, appKey: appKey, isHelper: isHelper,
                footprint: sample.phys_footprint, cpuPercent: cpuPct
            ))
        }
        lastProcCPU = nextCPU
        return rows
    }

    private func aggregateByApp(_ rows: [ProcRow], runningAppPIDs: Set<Int32>) -> [AggProc] {
        struct Acc {
            var name: String
            var mainPid: Int32
            var mainRank: Int  // 2 = NSRunningApplication main process, 1 = non-helper, 0 = helper
            var mainFoot: UInt64
            var footprint: UInt64
            var cpuPercent: Double
            var appKey: String
        }
        var map: [String: Acc] = [:]
        map.reserveCapacity(rows.count / 2 + 1)

        for r in rows {
            let rank = runningAppPIDs.contains(r.pid) ? 2 : (r.isHelper ? 0 : 1)
            if var a = map[r.appKey] {
                a.footprint &+= r.footprint
                a.cpuPercent += r.cpuPercent
                if rank > a.mainRank || (rank == a.mainRank && r.footprint > a.mainFoot) {
                    a.mainRank = rank
                    a.mainFoot = r.footprint
                    a.mainPid = r.pid
                    a.name = r.name
                }
                map[r.appKey] = a
            } else {
                map[r.appKey] = Acc(
                    name: r.name, mainPid: r.pid, mainRank: rank, mainFoot: r.footprint,
                    footprint: r.footprint, cpuPercent: r.cpuPercent, appKey: r.appKey
                )
            }
        }
        return map.values.map {
            AggProc(name: $0.name, mainPid: $0.mainPid, appKey: $0.appKey, footprint: $0.footprint, cpuPercent: $0.cpuPercent)
        }
    }

    private func listAllPIDs() -> [Int32] {
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bufSize) / MemoryLayout<Int32>.stride + 16)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.stride))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled) / MemoryLayout<Int32>.stride))
    }

    private func friendlyIdentity(for pid: Int32) -> (String, String, Bool) {
        let pathLen = procPathBuf.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if pathLen > 0 {
            let path = String(cString: procPathBuf)
            if let hit = procIdentityCache[path] { return (hit.name, hit.key, hit.isHelper) }
            let ident: (name: String, key: String, isHelper: Bool)
            if let range = path.range(of: ".app/") {
                let appRoot = String(path[..<range.upperBound].dropLast())
                let tail = String(path[range.upperBound...])
                let isHelper = tail.contains(".app/") || tail.contains("Helper") || tail.contains("Renderer") || tail.contains("XPCServices")
                let name = displayName(fromAppRoot: appRoot) ?? URL(fileURLWithPath: appRoot).deletingPathExtension().lastPathComponent
                ident = (name, appRoot, isHelper)
            } else if path.hasSuffix(".app") {
                let name = displayName(fromAppRoot: path) ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                ident = (name, path, false)
            } else {
                ident = (URL(fileURLWithPath: path).lastPathComponent, path, false)
            }
            if procIdentityCache.count > 1000 { procIdentityCache.removeAll(keepingCapacity: true) }
            procIdentityCache[path] = ident
            return (ident.name, ident.key, ident.isHelper)
        }
        var nameBuf = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0 {
            let n = String(cString: nameBuf)
            return (n, "name:\(n)", false)
        }
        return ("pid \(pid)", "pid:\(pid)", false)
    }

    private func displayName(fromAppRoot appRoot: String) -> String? {
        if let cached = displayNameCache[appRoot] { return cached }
        let infoURL = URL(fileURLWithPath: appRoot).appendingPathComponent("Contents/Info.plist")
        var name: String?
        if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any] {
            if let display = dict["CFBundleDisplayName"] as? String, !display.isEmpty { name = display }
            else if let bundleName = dict["CFBundleName"] as? String, !bundleName.isEmpty { name = bundleName }
        }
        let resolved = name ?? URL(fileURLWithPath: appRoot).deletingPathExtension().lastPathComponent
        if displayNameCache.count > 400 { displayNameCache.removeAll(keepingCapacity: true) }
        displayNameCache[appRoot] = resolved
        return resolved
    }
}
