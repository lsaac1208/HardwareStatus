# Changelog

All notable changes to HardwareStatus are documented in this file.

## [2.0.0] - 2026-11-20

### Architecture & Performance
- **Zero-dependency native telemetry (`Sources/Native/`)**: replaced periodic `macmon` subprocess spawning with in-process C modules:
  - `hw_smc.c`: unified AppleSMC IOKit client with one-time `#KEY` discovery + stride-compacted sensor cache (~1.9 ms/read for CPU/GPU die temperatures, fan RPM/max, and total system power `PSTR`/`PDTR`).
  - `hw_ioreport.c`: persistent zero-sleep `libIOReport.dylib` subscription (`CPU Stats`, `GPU Stats`, `Energy Model`) with automatic 30s staleness re-seeding; skipped entirely when the popover is closed and GPU is hidden from the menubar.
  - `hw_proc.c`: single-syscall `proc_pid_rusage(RUSAGE_INFO_V4)` sampler, 64-bit physical NIC counters via `sysctl(IFMIB_IFDATA)`, and real kernel memory pressure via `kern.memorystatus_vm_pressure_level`.
  - Keeps `macmon` only as an automatic fallback if native SMC/IOReport are unavailable.
- **Modular codebase**: split the monolithic `HardwareStatus.swift` into `Sources/Native/` (C) and `Sources/App/` (`MetricsModels`, `DesignSystem`, `StatusTitle`, `PanelComponents`, `MonitorPanelController`, `FanBoost`, `SystemSampler`, `AppDelegate`).
- **Lower idle CPU & memory footprint**:
  - Pre-resolved Dark/Light menubar palettes + KVO on `effectiveAppearance` and cached `static let` fonts eliminate dynamic color closures during CoreText/replicant draws.
  - Downsampled `20×20 pt` (`40×40 px`) app icons in `iconCache` cut peak physical footprint from `129.7 MB` to `18.8 MB`.
  - Global click-outside event monitor is only active while the popover is open; idle timer uses 20% coalescing tolerance.
  - Process enumeration runs off the main thread on a dedicated serial `.utility` queue.

### Correctness & Apple Silicon Fixes
- **Fixed 41.67× Apple Silicon process CPU% bug**: converts `ri_user_time + ri_system_time` Mach ticks using `mach_timebase_info` (`125/3 ns/tick` on Apple Silicon) and guards against PID reuse via `ri_proc_start_abstime`.
- **Fixed VPN/TUN 2× network double-counting & 32-bit wrap**: reads true 64-bit `struct ifmibdata` counters filtered to physical `en*` / `pdp_ip*` interfaces, excluding `utun*`, `lo*`, `awdl*`, `llw*`, `bridge*`, `anpi*`, `ap*`.
- **Apple M6 3-tier CPU support**: auto-detects 3-tier `ECPU`/`MCPU`/`PCPU` (E / P / S Super cores) vs 2-tier M1–M5 (`ECPU`/`PCPU`) and displays `S 核 · P 核 · E 核` in the expanded CPU row.
- **Real kernel memory pressure & swap**: reads `kern.memorystatus_vm_pressure_level` instead of hardcoded percentage thresholds, and surfaces active swap usage in both collapsed and expanded memory views.
- **Smarter process ranking & safe termination**: keeps low-RAM high-CPU CLI processes (`cpu >= 0.5%`), prefers `NSRunningApplication` main PID over helper/renderer processes, supports normal + force quit, and surfaces `EPERM` errors cleanly.
- **Timestamp-gated `DisplaySmoothing`**: `applyTelemetry()` updates GPU/thermal/power EMAs only when a genuinely newer sample arrives, without double-pushing CPU or network EMAs; adds `SteadyInt` hysteresis to memory percentage.

### Features & Tooling
- **Optional thermal fan boost (`FanBoost.swift`)**: integrated from PR #4 and verified on macOS, with hysteresis/sustain debounce, M4 (`Ftst`) & M5 (`F%dmd`) support, non-root read-only degradation, and a `SIGSEGV`/fatal-signal crash guard that restores automatic fan control.
- **Optional power telemetry**: shows live system wattage in the panel subtitle and GPU wattage in the GPU row, plus an opt-in menubar `整机功耗` item.
- **Upgraded build, tests & CI**: `./build.sh [--test] [--install [DIR]]` targeting `macOS 14.0+`, native + Swift unit test suite (`Tests/run_tests.sh` + `Tests/fanboost/run.sh`), `KeepAlive: { Crashed: true }` LaunchAgent template, and GitHub Actions CI.

## [1.9.1] - 2026-10-30
- Card-based Control Center UI refactor (`DesignSystem`, `PanelComponents`, `MonitorPanelController`, `StatusTitle`).
- Sampling vs rendering split (`Snapshot`), pause on lock/sleep, skip process scan when panel closed, and menubar high-contrast typography.
