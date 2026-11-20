# Changelog

All notable changes to HardwareStatus are documented in this file.

## [2.1.0] - 2026-11-20

### UI/UX & Liquid Glass Overhaul
- **Compact stacked menubar (`StatusTitle.swift`)**:
  - Value-primary typography (`12pt` semibold tabular values at full ink vs `9.5pt` muted labels) with zero awkward leading-space gaps.
  - New `.compact` (default) mode renders network rates as a tightly-fitted `@2x` Retina stacked 2-line attachment (`↑` over `↓`, cached to skip redundant bitmap draws), cutting menubar width by **36%** vs v1.9.1; `.standard` gapless single-line mode remains selectable.
  - Hysteresis-based dynamic `statusItem.length` expands immediately to prevent clipping and shrinks only after 3 consecutive narrow readings to avoid jitter.
- **macOS 26/27 Liquid Glass cards & visual craft (`DesignSystem.swift`, `PanelComponents.swift`)**:
  - Progressive `NSGlassEffectView(style: .clear)` cards batched inside `NSGlassEffectContainerView` on macOS 26+, with clean translucent fallback on macOS 14–15.
  - GPU `CALayer` **live sparklines** (`HistoryRing`, 36-point zero-allocation circular buffer) on CPU, GPU, and Network (dual down/up traces), rendered strictly while the popover is visible.
  - **Structured expanded rows** across all three primary metrics (uniformly right-aligned chevrons): CPU shows M6 `S/P/E` (or M1–M5 `P/E`) mini-bars + 1m load; Memory and GPU render crisp 2×2 aligned grids with zero orphan wrapping.
  - **Enhanced Thermal & Fan tiles**: added GPU temp/system wattage and fan RPM %/max RPM subtitles plus 3pt semantic ratio bars; clicking the Fan tile opens Settings directly.
- **In-panel native Settings view (`SettingsView.swift`, `MonitorPanelController.swift`)**:
  - Slide-in Settings page accessible from the footer `设置` button (and `更多 → 设置…`) with `MenubarStyle` segmented control, 1-click `↑/↓` reorder buttons + `NSSwitch` toggles for every metric, FanBoost controls, and live telemetry info.
  - Smoothly animated popover height transitions (`0.18s`, respecting Reduce Motion) and persistent expand/sort UI preferences across launches.
- **Actionable process rows (`AppDelegate.swift`, `PanelComponents.swift`)**:
  - Hover-reveal `•••` button (`alpha = 0` at idle), inline relative share bars, rich multi-line tooltips (PID, aggregated process count, executable path), and click context menu (`在 Finder 中显示`, `复制 PID`, `复制路径`, `优雅退出…`, `强制结束…`).

### Performance & Verification
- **Lazy popover & panel construction**: defers creating `MonitorPanelController`, `SettingsView`, and Liquid Glass layers until first click, reducing live M6 idle physical footprint to **15.6 MB** (peak **16.4 MB**, down even further from v2.0.0's 17.7 MB) with `0.00%` child CPU.
- Expanded `Tests/CoreTests.swift` covering `HistoryRing`, compact/tight rate formatters, and `StatusTitle` compact vs standard layout and attachment rendering.

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
