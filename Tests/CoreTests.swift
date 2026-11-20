import Cocoa
import Foundation

@main
enum CoreTestsMain {
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String, line: Int = #line) {
        if cond {
            print("  ok   \(msg)")
        } else {
            failures += 1
            print("  FAIL \(msg) (line \(line))")
        }
    }

    static func main() {
        print("Formatters & MemPressure")
        do {
            check(Formatters.formatBytes(0) == "0 B", "0 bytes")
            check(Formatters.formatBytes(1024) == "1 KB", "1 KB")
            check(Formatters.formatBytes(2 * 1024 * 1024) == "2 MB", "2 MB")
            check(Formatters.formatBytes(16 * 1024 * 1024 * 1024) == "16.0 GB", "16.0 GB")
            check(Formatters.formatBytes(128 * 1024 * 1024 * 1024) == "128 GB", "128 GB")
            check(Formatters.formatRate(500) == "500 B/s", "rate B/s")
            check(Formatters.formatRate(2048) == "2.0 KB/s", "rate KB/s")
            check(Formatters.formatRate(5 * 1024 * 1024) == "5.0 MB/s", "rate MB/s")
            check(Formatters.formatRateShort(0).contains("B/s"), "short rate B/s")
            check(Formatters.formatRateShort(15 * 1024).contains("KB/s"), "short rate KB/s")
            check(Formatters.formatRateShort(12 * 1024 * 1024).contains("MB/s"), "short rate MB/s")
            check(Formatters.formatRateTight(500) == "500 B/s", "tight rate B/s")
            check(Formatters.formatRateTight(28.8 * 1024) == "28.8 KB/s", "tight rate KB/s < 100")
            check(Formatters.formatRateTight(240 * 1024) == "240 KB/s", "tight rate KB/s >= 100")
            check(Formatters.formatRateTight(1.4 * 1024 * 1024) == "1.4 MB/s", "tight rate MB/s")
            check(Formatters.formatRateCompact(0) == "0B", "compact rate 0B")
            check(Formatters.formatRateCompact(28.8 * 1024) == "28.8K", "compact rate KB/s < 100")
            check(Formatters.formatRateCompact(240 * 1024) == "240K", "compact rate KB/s >= 100")
            check(Formatters.formatRateCompact(1.4 * 1024 * 1024) == "1.4M", "compact rate MB/s")
            check(Formatters.formatRateCompact(2.5 * 1024 * 1024 * 1024) == "2.5G", "compact rate GB/s")
            check(Formatters.formatWatts(7.34) == "7.3 W", "watts < 100")
            check(Formatters.formatWatts(125.4) == "125 W", "watts >= 100")
            check(Formatters.formatUptime(3660) == "1时1分", "uptime hours")
            check(Formatters.formatUptime(90000) == "1天1时", "uptime days")
            check(Formatters.clampPct(-5) == 0, "clamp negative")
            check(Formatters.clampPct(123.4) == 100, "clamp > 100")
            check(Formatters.clampPct(.nan) == 0, "clamp NaN")
            check(Formatters.clampPct(42.6) == 43, "clamp rounding")
            check(MemPressure.from(kernelLevel: 1, fallbackPercent: 95) == .normal, "kernel normal overrides percent")
            check(MemPressure.from(kernelLevel: 2, fallbackPercent: 30) == .warn, "kernel warn overrides percent")
            check(MemPressure.from(kernelLevel: 4, fallbackPercent: 30) == .critical, "kernel critical overrides percent")
            check(MemPressure.from(kernelLevel: 0, fallbackPercent: 90) == .critical, "fallback when kernel unavailable")
        }

        print("HistoryRing")
        do {
            var ring = HistoryRing(capacity: 4)
            check(ring.count == 0 && ring.values.isEmpty, "HistoryRing starts empty")
            ring.push(10)
            ring.push(20)
            ring.push(30)
            check(ring.count == 3 && ring.values == [10, 20, 30], "HistoryRing preserves insertion order")
            ring.push(40)
            ring.push(50)
            ring.push(60)
            check(ring.count == 4 && ring.values == [30, 40, 50, 60], "HistoryRing wraps oldest-to-newest")
            ring.push(.nan)
            ring.push(-5)
            check(ring.values == [50, 60, 0, 0], "HistoryRing clamps NaN/negative to 0")
            ring.reset()
            check(ring.count == 0 && ring.values.isEmpty, "HistoryRing reset clears count and values")
        }

        print("DisplaySmoothing")
        do {
            var ema = DisplaySmoothing.EMA(tau: 2.0)
            check(ema.push(10.0, at: 0) == 10.0, "EMA seeds on first sample")
            let mid = ema.push(20.0, at: 2.0)
            check(mid > 16.0 && mid < 16.6, "EMA converges ~63.2% at dt=tau (\(mid))")
            check(ema.push(100.0, at: 2.0) == mid, "EMA ignores zero dt")
            check(ema.push(.nan, at: 5.0) == mid, "EMA ignores NaN")

            var steady = DisplaySmoothing.SteadyInt()
            check(steady.update(14.4) == 14, "SteadyInt initial")
            check(steady.update(14.6) == 14, "SteadyInt suppresses 14.4 <-> 14.6 boundary jitter")
            check(steady.update(14.64) == 14, "SteadyInt holds within +-0.65 band")
            check(steady.update(14.7) == 15, "SteadyInt switches past +0.65")
            check(steady.update(14.4) == 15, "SteadyInt holds 15 at 14.4")
            check(steady.update(14.3) == 14, "SteadyInt switches back below -0.65")

            var sm = DisplaySmoothing()
            var snap = MetricsSnapshot()
            snap.mem = MemInfo(total: 32_000_000_000, used: 16_000_000_000, usedPercent: 50.0)
            snap.gpuPct = 20.0
            snap.gpuSampleWall = 10.0
            snap.thermal = ThermalInfo(chipC: 40, cpuC: 40, gpuC: 35, fanRpm: 1000, fanMaxRpm: 4900, pressureLabel: "温控正常", sampleWall: 10.0)
            snap.power = PowerInfo(sysW: 10.0, cpuW: 4.0, gpuW: 1.0, aneW: 0.0)
            sm.apply(to: &snap, rawCPU: 10, rawUser: 6, rawSys: 4, rawNetDown: 10_000, rawNetUp: 2_000, now: 10.0)
            check(snap.cpu == 10 && snap.memShownPct == 50 && snap.thermal.cpuC == 40, "initial apply populates snapshot")

            // Stale sensor timestamp must NOT advance thermal/GPU EMAs
            snap.gpuPct = 90.0
            snap.gpuSampleWall = 10.0
            snap.thermal.cpuC = 90.0
            snap.thermal.sampleWall = 10.0
            sm.applyTelemetry(to: &snap, now: 15.0)
            check(snap.gpuPct == 20.0, "stale gpuSampleWall does not push GPU EMA")
            check(snap.thermal.cpuC == 40.0, "stale thermal sampleWall does not push CPU temp EMA")
            check(snap.cpu == 10.0, "applyTelemetry leaves CPU untouched")

            // New timestamp advances thermal/GPU EMAs
            snap.gpuPct = 90.0
            snap.gpuSampleWall = 15.0
            snap.thermal.cpuC = 90.0
            snap.thermal.sampleWall = 15.0
            sm.applyTelemetry(to: &snap, now: 15.0)
            check((snap.gpuPct ?? 0) > 50.0, "fresh gpuSampleWall advances GPU EMA")
            check((snap.thermal.cpuC ?? 0) > 60.0, "fresh thermal sampleWall advances CPU temp EMA")
        }

        print("StatusTitle")
        do {
            let stdSegs: [StatusSegment] = [
                .metric(label: "CPU", value: "12%", level: .normal),
                .metric(label: "温度", value: "38\u{2009}°C", level: .warn),
                .rates(down: "1.2 MB/s", up: "340 KB/s")
            ]
            let cmpSegs: [StatusSegment] = [
                .metric(label: "CPU", value: "12%", level: .normal),
                .metric(label: "温度", value: "38\u{2009}°C", level: .warn),
                .rates(down: "1.2M", up: "340K")
            ]
            let darkKey = StatusTitle.key(cmpSegs, dark: true, style: .compact)
            let lightKey = StatusTitle.key(cmpSegs, dark: false, style: .compact)
            let stdKey = StatusTitle.key(cmpSegs, dark: true, style: .standard)
            check(darkKey != lightKey, "StatusTitle key distinguishes dark vs light menubar")
            check(darkKey != stdKey, "StatusTitle key distinguishes compact vs standard style")
            let attrCmp = StatusTitle.attributed(cmpSegs, dark: true, style: .compact)
            let attrStd = StatusTitle.attributed(stdSegs, dark: true, style: .standard)
            check(attrCmp.length > 0 && attrStd.length > 0, "StatusTitle attributed strings non-empty")
            var hasAttachment = false
            attrCmp.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attrCmp.length), options: []) { val, _, _ in
                if val is NSTextAttachment { hasAttachment = true }
            }
            check(hasAttachment, "compact menubar style uses stacked NSTextAttachment for network rates")
            let wCmp = StatusTitle.width(cmpSegs, style: .compact)
            let wStd = StatusTitle.width(stdSegs, style: .standard)
            check(wCmp > 40 && wStd > wCmp + 30,
                  String(format: "compact style (%.0f pt) is meaningfully narrower than standard (%.0f pt)", wCmp, wStd))
        }

        print("Native C · hw_proc_sample (Mach timebase accuracy)")
        do {
            let pid = getpid()
            var before = hw_proc_sample_t()
            var after = hw_proc_sample_t()
            check(hw_proc_sample(pid, &before) == 0, "hw_proc_sample initial call succeeds")
            check(before.phys_footprint > 0, "phys_footprint positive (\(before.phys_footprint) B)")
            check(before.start_ns > 0, "start_ns positive")

            let wallStart = ProcessInfo.processInfo.systemUptime
            var acc: UInt64 = 1
            while ProcessInfo.processInfo.systemUptime - wallStart < 0.12 {
                for i in 1...10_000 { acc = acc &* UInt64(i) &+ 7 }
            }
            _ = acc

            check(hw_proc_sample(pid, &after) == 0, "hw_proc_sample second call succeeds")
            check(after.start_ns == before.start_ns, "start_ns stable for same PID")
            let cpuDeltaSec = Double((after.user_ns &+ after.system_ns) &- (before.user_ns &+ before.system_ns)) / 1e9
            check(cpuDeltaSec >= 0.05 && cpuDeltaSec <= 0.50,
                  String(format: "CPU delta matches wall burn (%.3fs vs ~0.12s; no 41.67x error)", cpuDeltaSec))
        }

        print("Native C · hw_net_sample (64-bit physical NIC filter)")
        do {
            var net = hw_net_sample_t()
            check(hw_net_sample(&net) == 0, "hw_net_sample succeeds")
            let count = Int(net.count)
            check(count >= 0 && count <= Int(HW_NET_MAX_IFACES), "interface count valid (\(count))")
            var allPhysical = true
            withUnsafePointer(to: &net.ifaces) { ptr in
                ptr.withMemoryRebound(to: hw_net_iface_t.self, capacity: Int(HW_NET_MAX_IFACES)) { arr in
                    for i in 0..<count {
                        var iface = arr[i]
                        let name = withUnsafePointer(to: &iface.name) {
                            $0.withMemoryRebound(to: CChar.self, capacity: 32) { String(cString: $0) }
                        }
                        if !(name.hasPrefix("en") || name.hasPrefix("pdp_ip")) {
                            allPhysical = false
                            print("    unexpected non-physical iface: \(name)")
                        }
                    }
                }
            }
            check(allPhysical, "only physical en*/pdp_ip* interfaces included (utun/lo/awdl excluded)")
        }

        print("Native C · hw_memory_pressure_level")
        do {
            let lvl = hw_memory_pressure_level()
            check(lvl == 1 || lvl == 2 || lvl == 4 || lvl == 0, "kernel memory pressure valid (\(lvl))")
        }

        print("Native C · hw_smc_read_sensors & hw_ioreport_sample")
        do {
            var smc = hw_smc_sensors_t()
            if hw_smc_read_sensors(&smc) == 0 {
                if smc.has_cpu_temp != 0 {
                    check(smc.cpu_temp_c > 10 && smc.cpu_temp_c < 120,
                          String(format: "SMC CPU temp realistic (%.2f °C)", smc.cpu_temp_c))
                }
                if smc.has_gpu_temp != 0 {
                    check(smc.gpu_temp_c > 10 && smc.gpu_temp_c < 120,
                          String(format: "SMC GPU temp realistic (%.2f °C)", smc.gpu_temp_c))
                }
                if smc.has_sys_power != 0 {
                    check(smc.sys_power_w > 0 && smc.sys_power_w < 500,
                          String(format: "SMC system power realistic (%.2f W)", smc.sys_power_w))
                }
                print("  info SMC: cpu=\(smc.has_cpu_temp != 0 ? String(format: "%.1f°C", smc.cpu_temp_c) : "n/a") gpu=\(smc.has_gpu_temp != 0 ? String(format: "%.1f°C", smc.gpu_temp_c) : "n/a") fan=\(smc.fan_rpm)/\(smc.fan_max_rpm) pwr=\(smc.has_sys_power != 0 ? String(format: "%.2fW", smc.sys_power_w) : "n/a")")
            } else {
                print("  skip SMC unavailable in this environment (e.g. VM/CI)")
            }
            hw_smc_close()

            if hw_ioreport_available() != 0 {
                var s1 = hw_ioreport_sample_t()
                var s2 = hw_ioreport_sample_t()
                check(hw_ioreport_sample(&s1) == 0 && s1.valid == 0, "IOReport first call seeds baseline")
                Thread.sleep(forTimeInterval: 0.15)
                check(hw_ioreport_sample(&s2) == 0 && s2.valid != 0, "IOReport second call returns valid delta")
                if s2.has_gpu != 0 {
                    check(s2.gpu_active >= 0.0 && s2.gpu_active <= 1.0,
                          String(format: "IOReport GPU active in [0,1] (%.1f%%)", s2.gpu_active * 100))
                }
                if s2.has_cpu_tiers != 0 {
                    check(s2.cpu_e >= 0.0 && s2.cpu_e <= 1.0 && s2.cpu_p >= 0.0 && s2.cpu_p <= 1.0 && s2.cpu_s >= 0.0 && s2.cpu_s <= 1.0,
                          String(format: "IOReport CPU tiers in [0,1] (super=%d S=%.1f%% P=%.1f%% E=%.1f%%)",
                                 s2.has_super, s2.cpu_s * 100, s2.cpu_p * 100, s2.cpu_e * 100))
                }
                hw_ioreport_close()
            } else {
                print("  skip IOReport unavailable in this environment")
            }
        }

        print(failures == 0 ? "CORE TESTS PASSED" : "\(failures) CORE TESTS FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
