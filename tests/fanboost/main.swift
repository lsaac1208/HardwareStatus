import Foundation

// Linux logic tests for FanBoost.swift + hw_smc.c against fake_smc.c. Run via ./run.sh.

var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if cond { print("  ok   \(msg)") } else { failures += 1; print("  FAIL \(msg) (line \(line))") }
}
func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func eq(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.5 }

// Crash path runs in a child process: arm the guard, then crash
if CommandLine.arguments.dropFirst().first == "crash" {
    fake_smc_reset(Int32(FAKE_M4))
    _ = hw_smc_open()
    hw_smc_install_crash_handlers()
    hw_smc_guard_configure("F0MdF1Md", 2, 1, 0)
    hw_smc_guard_arm(1)
    raise(SIGSEGV)
    exit(0)  // not reached
}

let prefix = "local.lsaac128.HardwareStatus.fanBoost."
for k in ["enabled", "thresholdC", "targetPercent", "hysteresisC", "sustainSec", "dirty"] {
    UserDefaults.standard.removeObject(forKey: prefix + k)
}

print("FanBoostPolicy")
do {
    var p = FanBoostPolicy()
    check(p.evaluate(tempC: 90, sampleWall: 0, now: 0, boosting: false) == .none, "first hot sample does not boost")
    check(p.evaluate(tempC: 90, sampleWall: 0, now: 4.9, boosting: false) == .none, "same sample repeated does not advance debounce")
    check(p.evaluate(tempC: 80, sampleWall: 5, now: 5, boosting: false) == .none, "dip below threshold")
    check(p.overSince == nil, "dip resets debounce")
    check(p.evaluate(tempC: 90, sampleWall: 10, now: 10, boosting: false) == .none, "spike after dip does not boost")
    check(p.evaluate(tempC: 91, sampleWall: 15, now: 15, boosting: false) == .boost, "sustained 5 s over threshold boosts")
    check(p.evaluate(tempC: 85, sampleWall: 20, now: 20, boosting: false) == .none, "exactly at threshold is not over")
    check(p.evaluate(tempC: 82, sampleWall: 20, now: 20, boosting: true) == .none, "inside hysteresis band keeps boost")
    check(p.evaluate(tempC: 80, sampleWall: 25, now: 25, boosting: true) == .release(.cooled), "threshold - hysteresis releases")
    check(p.evaluate(tempC: 95, sampleWall: 25, now: 56, boosting: true) == .release(.stale), "stale sample (>30 s) releases")
    check(p.evaluate(tempC: nil, sampleWall: nil, now: 60, boosting: true) == .release(.stale), "missing temperature releases")
    check(p.evaluate(tempC: nil, sampleWall: nil, now: 60, boosting: false) == .none, "missing temperature while auto is a no-op")
    check(p.evaluate(tempC: .nan, sampleWall: 60, now: 60, boosting: true) == .release(.stale), "NaN temperature releases")
    var q = FanBoostPolicy(); q.sustain = 3
    _ = q.evaluate(tempC: 99, sampleWall: 0, now: 0, boosting: false)
    check(q.evaluate(tempC: 99, sampleWall: 3, now: 3, boosting: false) == .boost, "custom sustain 3 s")
}

print("targetRPM clamp")
do {
    typealias P = FanBoostPolicy
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: 1500, percent: 80) == 4640, "80% of max")
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: 1500, percent: 250) == 5800, "percent capped at max")
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: nil, percent: 1) == 1200, "low percent clamped to min")
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: 5200, percent: 80) == 5200, "never below current RPM")
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: 9000, percent: 80) == 5800, "current above max still clamped")
    check(P.targetRPM(minRPM: 1200, maxRPM: nil, currentRPM: nil, percent: 80) == 4500, "max unread → 4500 fallback")
    check(P.targetRPM(minRPM: 5000, maxRPM: nil, currentRPM: nil, percent: 80) == 5000, "fallback clamped up to min")
    check(P.targetRPM(minRPM: nil, maxRPM: nil, currentRPM: nil, percent: 80) == 4500, "nothing readable → fallback")
    check(P.targetRPM(minRPM: 3000, maxRPM: 2000, currentRPM: nil, percent: 80) == nil, "max < min → don't touch fan")
    check(P.targetRPM(minRPM: nil, maxRPM: 400, currentRPM: nil, percent: 80) == nil, "tiny max → refuse (< 500 RPM)")
    check(P.targetRPM(minRPM: 0, maxRPM: 0, currentRPM: 0, percent: 80) == 4500, "zero probes treated as unread, never 0")
    check(P.targetRPM(minRPM: 1200, maxRPM: 5800, currentRPM: nil, percent: .nan) == 4640, "NaN percent → 80%")
}

print("hw_smc.c encoding")
do {
    fake_smc_reset(Int32(FAKE_M4))
    check(hw_smc_open() == 0, "open")
    var v = 0.0
    check(hw_smc_read_number("F0Mx", &v) == 0 && eq(v, 5800), "read flt little-endian")
    check(hw_smc_read_number("FNum", &v) == 0 && eq(v, 2), "read ui8")
    check(hw_smc_read_number("ZZZZ", &v) == HW_SMC_ERR_SMC | 0x84, "missing key → SMC 0x84")
    check(hw_smc_read_number("F0M", &v) == HW_SMC_ERR_ARG, "bad key length rejected")
    check(hw_smc_write_number("F0Tg", 0) == HW_SMC_ERR_ARG, "target RPM 0 refused by C layer")
    check(hw_smc_write_number("F0Tg", 300) == HW_SMC_ERR_ARG, "target RPM < 500 refused by C layer")
    check(hw_smc_write_number("F0Tg", .nan) == HW_SMC_ERR_ARG, "NaN refused")
    check(hw_smc_write_number("F0Md", 1) == HW_SMC_ERR_SMC | 0x82, "M4: mode write blocked before Ftst")
    fake_smc_set_denied(1)
    check(hw_smc_write_number("F0Tg", 3000) == Int32(bitPattern: 0xe00002c1), "privilege error surfaced")
}

func makeController(_ model: Int32) -> FanBoostController {
    fake_smc_reset(model)
    let c = FanBoostController()
    c.start(onTerminateSignal: {})
    pump(0.3)
    return c
}
/// Two hot samples 5 s apart, as macmon delivers them with the panel closed
func heatUp(_ c: FanBoostController, from t0: TimeInterval) {
    c.evaluate(tempC: 92, sampleWall: t0, now: t0)
    c.evaluate(tempC: 93, sampleWall: t0 + 5, now: t0 + 5)
}
func waitBoost(_ c: FanBoostController, timeout: TimeInterval = 12) {
    let end = Date().addingTimeInterval(timeout)
    while c.state != .boosted && Date() < end { pump(0.1) }
}
let dirtyKey = prefix + "dirty"

print("Controller · M4 (Ftst unlock)")
do {
    let c = makeController(Int32(FAKE_M4))
    check(c.capability == .writable, "probe: writable (root faked)")
    check(c.shortStatus == "自动", "starts automatic")
    c.evaluate(tempC: 92, sampleWall: 0, now: 0)
    check(c.state == .auto, "one hot sample: still automatic")
    check(fake_smc_write_count() == 0, "no SMC writes while just watching")
    c.evaluate(tempC: 93, sampleWall: 5, now: 5)
    check(c.state == .engaging, "sustained: engaging")
    check(UserDefaults.standard.bool(forKey: dirtyKey), "dirty marker set before writes")
    let start = Date()
    waitBoost(c)
    check(c.state == .boosted, "boosted after unlock (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
    check(eq(fake_smc_get("Ftst"), 1), "Ftst=1 written")
    check(eq(fake_smc_get("F0Md"), 1) && eq(fake_smc_get("F1Md"), 1), "both fans manual")
    check(eq(fake_smc_get("F0Tg"), 4640) && eq(fake_smc_get("F1Tg"), 4640), "targets = 80% of 5800")
    check(c.shortStatus == "强制加速" && c.detailStatus.contains("4640"), "status text: 强制加速 · 4640")
    let writes = fake_smc_write_count()
    for i in 0..<5 { c.evaluate(tempC: 93, sampleWall: 10 + Double(i), now: 10 + Double(i)) }
    pump(0.2)
    check(fake_smc_write_count() == writes, "no writes on ticks between verifies")
    // System reclaims a fan behind our back → verify re-asserts
    fake_smc_set("F0Md", 3)
    let now = ProcessInfo.processInfo.systemUptime + 9
    c.evaluate(tempC: 93, sampleWall: now, now: now)
    pump(0.3)
    check(eq(fake_smc_get("F0Md"), 1), "verify re-asserted manual mode")
    let w2 = fake_smc_write_count()
    c.evaluate(tempC: 93, sampleWall: now + 9, now: now + 9)
    pump(0.3)
    check(fake_smc_write_count() == w2, "verify with nothing drifted writes nothing")
    c.evaluate(tempC: 79.5, sampleWall: now + 10, now: now + 10)
    pump(0.3)
    check(c.state == .auto, "cooled below threshold - hysteresis → automatic")
    check(eq(fake_smc_get("F0Md"), 3) && eq(fake_smc_get("Ftst"), 0), "modes back to system, Ftst=0")
    check(!UserDefaults.standard.bool(forKey: dirtyKey), "dirty marker cleared")
    check(fake_smc_min_target_written() >= 500, "never wrote a target below 500 RPM")
}

print("Controller · safety paths")
do {
    let c = makeController(Int32(FAKE_M4))
    heatUp(c, from: 100); waitBoost(c)
    c.setSuspended(true)  // screen lock / sleep: synchronous
    check(c.state == .auto && eq(fake_smc_get("Ftst"), 0) && eq(fake_smc_get("F1Md"), 3), "lock/sleep restores synchronously")
    let w = fake_smc_write_count()
    heatUp(c, from: 200); pump(0.2)
    check(c.state == .auto && fake_smc_write_count() == w, "suspended: no action while locked")
    c.setSuspended(false)

    heatUp(c, from: 300); waitBoost(c)
    c.setEnabled(false)
    check(c.state == .auto && eq(fake_smc_get("Ftst"), 0), "disabling feature restores synchronously")
    heatUp(c, from: 400); pump(0.2)
    check(c.state == .auto, "disabled: ignores heat")
    c.setEnabled(true)

    heatUp(c, from: 500)
    pump(0.5)  // mid-unlock (Ftst countdown running)
    check(c.state == .engaging, "engaging mid-unlock")
    c.restoreNow()  // quit path while engaging
    check(c.state == .auto && eq(fake_smc_get("F0Md"), 3) && eq(fake_smc_get("Ftst"), 0), "quit during unlock: restored, nothing left forced")
    pump(4)
    check(eq(fake_smc_get("F0Md"), 3), "cancelled unlock never re-forces afterwards")

    heatUp(c, from: 600); waitBoost(c)
    let up = ProcessInfo.processInfo.systemUptime
    c.evaluate(tempC: 93, sampleWall: up - 40, now: up)
    pump(0.3)
    check(c.state == .auto && eq(fake_smc_get("Ftst"), 0), "stale temperature (macmon gone) → automatic")

    heatUp(c, from: 700); waitBoost(c)
    fake_smc_set_denied(1)
    fake_smc_set("F0Md", 3)  // force a drift so verify must write
    let n2 = ProcessInfo.processInfo.systemUptime + 20
    c.evaluate(tempC: 93, sampleWall: n2, now: n2)
    pump(0.3)
    check(c.state == .auto, "permission lost during verify → automatic")
    if case .readOnly = c.capability { check(true, "capability degraded to read-only") } else { check(false, "capability degraded to read-only") }
    fake_smc_set_denied(0)
    c.restoreNow()
}

print("Controller · denied from the start")
do {
    let c = makeController(Int32(FAKE_M4))
    fake_smc_set_denied(1)
    heatUp(c, from: 0)
    pump(0.5)
    check(c.state == .auto, "denied → stays automatic")
    if case .readOnly(let why) = c.capability { check(why.contains("权限"), "read-only: \(why)") } else { check(false, "read-only") }
    check(!UserDefaults.standard.bool(forKey: dirtyKey), "nothing owned → dirty marker cleared")
    c.restoreNow()
    check(fake_smc_write_count() == 0, "no successful writes at all")
}

print("Controller · M5 (lowercase md, no Ftst)")
do {
    let c = makeController(Int32(FAKE_M5))
    check(c.capability == .writable, "probe finds F0md")
    heatUp(c, from: 0); waitBoost(c, timeout: 2)
    check(c.state == .boosted && eq(fake_smc_get("F0md"), 1), "direct mode write, no unlock wait")
    check(fake_smc_get("Ftst").isNaN, "Ftst never created/written")
    c.restoreNow()
    check(eq(fake_smc_get("F0md"), 0) && eq(fake_smc_get("F1md"), 0), "restored to auto (0)")
}

print("Controller · fanless")
do {
    let c = makeController(Int32(FAKE_FANLESS))
    check(c.capability == .fanless, "FNum=0 → fanless")
    check(c.detailStatus.contains("无风扇"), "UI explains: \(c.detailStatus)")
    check(!c.wantsTemperature, "doesn't keep macmon busy")
    heatUp(c, from: 0); pump(0.2)
    check(fake_smc_write_count() == 0, "no writes")
}

print("Controller · recovery after a killed run")
do {
    UserDefaults.standard.set(true, forKey: dirtyKey)
    fake_smc_reset(Int32(FAKE_M4))
    fake_smc_set("Ftst", 1); fake_smc_set("F0Md", 1); fake_smc_set("F1Md", 1)
    let c = FanBoostController()
    c.start(onTerminateSignal: {})
    pump(0.3)
    check(eq(fake_smc_get("Ftst"), 0) && eq(fake_smc_get("F0Md"), 3), "launch with dirty marker restores automatic")
    check(!UserDefaults.standard.bool(forKey: dirtyKey), "marker cleared")
    _ = c
}

for k in ["enabled", "thresholdC", "targetPercent", "hysteresisC", "sustainSec", "dirty"] {
    UserDefaults.standard.removeObject(forKey: prefix + k)
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
