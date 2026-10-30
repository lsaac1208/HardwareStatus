# HardwareStatus v1.9.1: optimization round 1

Scope: `HardwareStatus.swift` only. It is still one file, so `build.sh`, `hw_proc.c/h`, `Info.plist`, the LaunchAgent example and the MIT `LICENSE` are untouched. Menubar defaults (`CPU · 内存 · 温度 · 网络`), panel layout, Chinese UI strings, "no daemon" and "pause on lock/sleep" all stay the same.

> **Not built on macOS.** This work was done on a Linux sandbox. See [Platform limits](#platform-limits-on-this-linux-box).

---

## 1. Research findings (before = commit `c2e8978`)

### Architecture
- The whole app is one 1455-line file: design tokens and custom views (`HIG`, `MetricRow`, `IORow`, `AppProcRow`, `SortHeader`, L9–418), `MonitorPanelController` (L421–618), and a ~800-line `AppDelegate` (L634–1437). The delegate holds every sampler, all prefs/menu code and all rendering.
- One main-thread `Timer` drives everything (`restartTimer`, L910). The interval is 2.5 s when the panel is closed and 1.0 s when it is open (L647–648, `desiredInterval` L902). The timer stops entirely while asleep or locked (L893–899, L906–909).
- `macmon` is the only off-main work. Each tick does a `Process` spawn on `DispatchQueue.global(.utility)` (`refreshTempsAsync`, L1145). Its results go into lock-guarded caches (`tempLock`, L653–661) that the next tick reads.

### Bottlenecks and bugs
| # | Evidence (before) | Problem |
|---|---|---|
| A | `updateMetrics` L963–967 runs before the panel guard at L983 | **The full process scan, aggregation and sort ran on every tick even with the panel closed.** That is `proc_listpids`, then `hw_phys_footprint`, `proc_pidinfo` and `proc_pidpath` for every pid, on the main thread, every 2.5 s, forever. The menubar never shows process data. |
| B | `friendlyNameAndKey` L1384 | A 4 KiB `[CChar]` was allocated per process per tick, and the `.app` path was re-parsed (`range(of:)`, `URL(...)`) every time. |
| C | `refreshTempsAsync(force: false)` L982, called every tick | **A `macmon` subprocess was spawned every 1–2.5 s**, even when no temperature, GPU or fan value was visible anywhere. |
| D | L1154–1159 | `waitUntilExit()` ran *before* draining stdout, so a large write could deadlock on a full pipe. stderr was piped but never read. There was no timeout, so a hung macmon left `tempRefreshInFlight = true` forever and temperatures froze. `force: true` also allowed two macmon instances to run at once. |
| E | `macmonPath` L652 hard-coded `/opt/homebrew/bin/macmon` | The README says "macmon in `PATH`", but Intel Homebrew (`/usr/local`), cargo and MacPorts installs never worked. The app also re-tried the failing launch every tick. |
| F | `onSortChanged → updateMetrics` L728; `onToggleDetail` L510 | **Clicking the CPU/内存 sort header or the expand chevron resampled everything.** CPU and process deltas were then computed over a few milliseconds, so the numbers jumped (bug). `togglePopover` (L796) did the same right after a tick. |
| G | `sampleCPU` L1266–1273 | `UInt64(Int32)` traps if a per-core tick counter goes negative, and `user - last.user` traps on unsigned underflow if a counter wraps. Both are **crashes** on long uptimes. |
| H | `sampleNetwork` L1221–1233 | `if_data` byte counters are 32-bit. Summing them across interfaces *before* taking the delta meant any single wrap (every 4 GiB) or interface reset showed 0 B/s. `netLifetime` and `netSessionStart` were dead state. |
| I | `sampleCPU` L1257, `sampleMemory` L1285 | `mach_host_self()` was called twice per tick. Each call takes a new send-right reference that is never released. `hw.memsize` and `host_page_size` were re-queried every tick even though they never change. |
| J | `sampleDisk` L955, called every tick | A volume `resourceValues` query (including `…ForImportantUsage`, which can be slow) ran every tick, even though disk is hidden in the menubar by default and the panel was closed. |
| K | L937, L917 | `statusOrder()` + `isShow()` did 1 array read plus 7 bool reads from `UserDefaults` and a dedupe on every tick. |
| L | L977, L999–1086 | The status-item title and every label were reassigned each tick even when unchanged, which relayouts and redraws them. Redundant `textColor = .labelColor` writes. `cpuLong`/`memLong` were formatted even when collapsed. `getloadavg` and swap were read even when not shown. `setIcon` copied and resized an `NSImage` for 3 rows every tick. `ProgressTrack.set` always called `needsLayout`. |
| M | `togglePopover` L796 + `popoverWillShow` L1441 | Duplicate throttle path: the timer was invalidated and recreated twice on every open, and the timer had no tolerance (no wakeup coalescing). |
| N | `confirmKill` L1112–1117 | The pid was captured when the menu was built. The modal alert can stay open indefinitely, and the pid may be recycled before you confirm. |

Checked and found OK: `Timer` and row/panel closures already use `[weak self]`, so there are no retain cycles. `cached*` is consistently read and written under `tempLock`. UI updates always happen on the main thread (the macmon worker only writes the caches). The global event monitor lives for the app's lifetime, so never removing it is fine.

---

## 2. What changed (all in `HardwareStatus.swift`; line numbers are *after*)

1. **Split sampling from rendering, with a `Snapshot`** (fixes A, F)
   - `updateMetrics()` (L1028) only samples what the menubar needs. The process table is sampled only while the popover is visible (`sampleProcessTable`, L1047).
   - `renderStatusTitle()` (L1064) and `renderPanel()` (L1085) render only from `snapshot`. Sort and expand now call `renderPanel()` (L771) and no longer resample. Prefs changes call `statusPrefsChanged()` (L930).
   - Because the process baseline is stale on open, a single follow-up sample runs 0.6 s later, so true per-process CPU% shows almost immediately instead of an average over the time the panel was closed.
   - `sampleCPU` (L1403) and `sampleProcessTable` ignore calls less than 0.5 s after the previous sample and reuse the last value instead of computing a delta over a few milliseconds.
2. **Throttle and harden macmon** (fixes C, D, E)
   - `refreshTempsAsync` (L1272) skips the spawn when the panel is closed and none of 温度/GPU/风扇 is in the menubar.
   - While closed, it spawns at most every ~5 s (`macmonIdleMinInterval`). With the panel open the cadence is unchanged (every tick).
   - `force` now bypasses only the time throttle and never starts a second concurrent instance.
   - stdout is drained before `waitUntilExit()`, stderr goes to `FileHandle.nullDevice` (L1295), and a 5 s watchdog terminates a hung macmon.
   - `resolveMacmonPath()` (L1256) probes `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `/opt/local/bin`, then `$PATH`, and caches the result. If nothing is found it re-probes once a minute instead of failing every tick.
   - Dead `cachedFanMax`/`cachedFanCount` were removed.
3. **Cheaper process scan** (fixes B)
   - `friendlyNameAndKey` (L1551) reuses one path buffer and memoizes path → (display name, appKey) in `procIdentityCache` (bounded to 1000 entries).
   - `nextCPU.reserveCapacity`.
4. **Crash and correctness fixes in the samplers** (fixes G, H, I, N)
   - CPU ticks are read via `UInt32(bitPattern:)`, and a counter that goes backwards re-baselines instead of trapping (L1403).
   - Network keeps per-interface 32-bit counters. `counterDelta` (L1351) handles a wrap near `UInt32.max` and treats any other decrease as a reset, so a VPN `utun` re-creation doesn't show as a 4 GiB spike.
   - Dead network state was removed.
   - `hostPort` is taken once (L660). `hw.memsize` and page size are read once in `seedIdentity`.
   - `confirmKill` (L1223) re-checks that the pid still maps to the same app before sending `SIGTERM`. If it doesn't, it beeps and does nothing.
5. **Less main-thread UI churn** (fixes J, K, L)
   - `NSTextField.setText` (L52) assigns only when the text changed.
   - The status-item title is assigned only when it differs.
   - `ProgressTrack.set` (L91) returns early when the value and color are unchanged, and re-resolves the color when the appearance changes.
   - `AppProcRow.setIcon(_:key:)` (L361) skips the copy and resize for the same app.
   - Only the visible detail variant is formatted, and loadavg/swap are read only when expanded.
   - Redundant `textColor` writes were removed, and `formatBytes` uses a static units array.
   - Visible menubar keys are cached and invalidated on prefs changes (`visibleStatusKeys`, L971).
   - Disk capacity is cached for 15 s (`diskInfo`, L1471) and sampled only when the panel is open or 磁盘 is shown in the menubar. Enabling 磁盘 forces a fresh read.
6. **Timer hygiene** (fixes M): `restartTimer` (L961) is a no-op when the interval is unchanged and sets `tolerance = 10 %`. `togglePopover` no longer duplicates `popoverWillShow`'s throttle call.
7. **Maintainability:** added `MARK` sections, a `Snapshot` type that documents what the UI consumes, and comments on threading (`tempLock` scope). The file was deliberately **not** split this round, to keep `build.sh` unchanged and the diff reviewable.

### Before → after per tick, panel closed, default menubar (CPU · 内存 · 温度 · 网络)
| Work | Before (every 2.5 s) | After |
|---|---|---|
| Process scan (≈3 syscalls/pid + 4 KiB alloc/pid + sort) | every tick | **none** |
| macmon `Process` spawn | every tick | every ~5 s (none if 温度/GPU/风扇 are hidden) |
| Disk volume query | every tick | none (unless 磁盘 is shown; then ≤ every 15 s) |
| `mach_host_self` / `hw.memsize` / page size | 2 / 1 / 1 | 0 / 0 / 0 |
| UserDefaults reads | ~8 | 0 |
| Status-item title set | always | only on change |

---

## 3. How to verify on macOS
1. `./build.sh`. It should print `BUILT …/HardwareStatus.app/Contents/MacOS/HardwareStatus` and an arm64 Mach-O. Then run `open HardwareStatus.app`.
2. **Idle cost:** with the panel closed, run `sudo fs_usage -w -f exec | grep macmon` (or watch `ps -ax | grep macmon` in Activity Monitor). Spawns should arrive about every 5 s, not every 2.5 s. Then turn off 温度 in 右键 → 状态栏显示 (keep CPU on). Spawns should stop. In Instruments → Time Profiler, `sampleProcessesRaw` should not appear while the panel is closed.
3. **Panel open:** values refresh every ~1 s. Top-process CPU% should become non-zero and plausible within about 1 s of opening.
4. **Sort/expand bug:** click CPU/内存 in the header and the chevrons repeatedly. The CPU % and process CPU % must no longer jump. Only the ordering and detail text should change.
5. **macmon path:** with macmon installed only at `/usr/local/bin` (or `~/.cargo/bin`), temperature should appear. Without macmon, the panel should show 读取中… / 无读数 and nothing should crash.
6. **Hung macmon:** temporarily point a wrapper script that does `sleep 60` at the probed path. Temperatures should recover once a real macmon is back, because the watchdog kills the hung process after 5 s.
7. **Menubar prefs:** toggle and reorder items. The title should update immediately and the width should match the previous behavior. Enabling 磁盘 should show a real % immediately.
8. **Kill guard:** open the ⋯ on a process, quit that app yourself, then press 结束. You should hear a beep and nothing should be killed.
9. **Network:** run a large download (> 4 GiB) and connect/disconnect a VPN. There should be no 0 B/s dropouts at wrap and no multi-GB/s spikes on reconnect.
10. **Appearance:** switch Light/Dark while the panel is open. The bar fill colors should follow.

---

## Platform limits on this Linux box
- There is no macOS SDK, `xcrun`, `clang` for Darwin, Cocoa, or `libproc`, so I did **not** run `./build.sh` and **did not produce or launch an app**. I make no claim that it builds on macOS.
- **Done here:** I downloaded the official Swift 6.0.3 Linux toolchain and ran `swiftc -parse HardwareStatus.swift`, which passes. I checked that the parser rejects a deliberately broken file, so the pass is meaningful. This is a syntax check only, not a type check against AppKit.
- I compiled and ran copies of the pure helpers (`counterDelta`, the CPU tick `bitPattern` conversion) as a Linux test, and their assertions pass.
- Type-level concerns to watch on the first macOS build are `performAsCurrentDrawingAppearance` (macOS 11+, fine for the `macosx26.0` target) and the implicit pointer conversion in `proc_pidpath(pid, $0.baseAddress, …)`. Both are standard usage.

## Follow-ups (not in this round)
- Split into `Views.swift` / `Panel.swift` / `Sampling.swift` / `App.swift` and list them in `build.sh`. This is a mechanical move now that sampling and rendering are separated.
- Move the process scan off the main thread, keeping CPU-delta state confined to that queue.
- When macmon data arrives, post a coalesced title refresh to main to remove the up-to-one-tick temperature lag.
- Use 64-bit network counters via `sysctl(NET_RT_IFLIST2)` / `if_data64`.

---

## Conclusion (excerpt)
> In v1.9.1 the app did its most expensive work (a full process scan and a `macmon` spawn every tick) whether or not anyone could see the result, and rendering was tangled with sampling, so a UI click caused bogus CPU readings. This round separates sampling from rendering, scans processes only while the panel is open, spaces out macmon and makes it robust (no deadlock, no hang, finds non-Homebrew installs), and fixes two long-uptime crashes and a network-counter wrap bug. It also removes most per-tick main-thread churn. User-visible behavior, defaults and the single-file `./build.sh` flow are unchanged. It has not been built on macOS yet; see §3 for the checks to run there.
