# HardwareStatus v1.9.1: visual round (UI/UX refactor)

Baseline: commit `c2e8978` plus the uncommitted Round-1 performance work (see `OPTIMIZATION_REPORT.md`). This round changes only the **view layer** and the menubar title. Sampling, throttling and prefs logic are unchanged except for a small amount of render glue.

> **Not built on macOS.** This work was done on a Linux sandbox that cannot link Cocoa. A syntax check passed; there was no type check and no screenshot of the new UI. See [§7 Platform limits](#7-platform-limits).

---

## 1. Critique: current UI vs HIG / Control Center / Activity Monitor / iStat

The line numbers below refer to the **pre-refactor** working tree (Round-1 `HardwareStatus.swift`).

### 1.1 Menubar (`docs/menubar.png`)
What the screenshot shows: a gauge SF Symbol, then `CPU   3% · 内存 50% · 温度 26 °C · ↓ 9.2 KB/s ↑ 32.4 KB/s`, all white and all one weight.

- **No hierarchy.** The title was a plain `String` (`buildTitle`, old L998–1012, assigned to `button.title`), set in one font (`HIG.status`, 11 pt mono medium). The labels "CPU / 内存 / 温度" carry as much visual weight as the numbers, so you have to *read* the item rather than glance at it. iStat Menus and the system clock both treat the value as the primary element.
- **Big gaps that look like bugs.** `"CPU %3d%%"` pads with ASCII spaces. In a monospaced-*digit* font an ASCII space is narrower than a digit, so the padding does not even give a stable width, and the 3-wide pad produces the visible `CPU   3%` hole.
- **The separators are as loud as the data.** ` · ` is drawn in the value colour with full-width spaces around it.
- **No load signal.** 95 % CPU or 98 °C looks exactly like 3 % / 26 °C. Control Center and iStat both use colour sparingly to flag a state.
- It is wide. That is partly inherent to a 4-metric default, which must not change.

### 1.2 Panel (`docs/panel.png`)
- **Clipped content (a real bug).** The third process row ("UURemote") is cut off behind the footer. `HIG.panelH = 560` was fixed (old L12), and the content lived in a scroll view above a 40-pt footer. With 3 metric rows, the thermo grid, IO and the table, the content exceeds 520 pt, so the default panel always scrolls and clips. HIG popovers should size to their content.
- **A single flat layer.** All groups sit directly on the popover material and are separated only by `Hairline`s (old L57–74, separator at α 0.35). Control Center groups related controls into rounded *modules*, and grouping gives hierarchy for free. Here CPU/内存/GPU, temperatures, IO and the process table all read at the same level.
- **Icons are tiny and monochrome.** `MetricRow.setSymbol` used a 12 pt glyph in `secondaryLabelColor`, in a 16-pt box (old L231–235). IORow used 11 pt in 14 pt (old L302–306). In System Settings, Control Center and iStat, the icon is the fastest way to find a row. Here it is a faint glyph next to a label.
- **Every bar is the same accent blue.** `ProgressTrack` (old L76–114) is a 4-pt bar (`HIG.barH = 4`, old L18) with a `separatorColor α 0.12` track. In the screenshot the track looks like a grey rule and the fills look like a highlight line. Thin bars with no colour coding make CPU, 内存, GPU and 存储 indistinguishable at a glance. Warn and critical states existed but nothing else did.
- **Weak type scale.** The title is 17 semibold. Values are 17 semibold monospaced SF Pro (`HIG.valuePrimary`), so the title and the numbers compete. Everything else is 11–13 regular. There is no "big number + small unit" treatment like the one Control Center, Battery or iStat use.
- **The thermo grid has no affordance** (`CompactValue`, old L238–264). "CPU 温度 / 31 °C" floats between two hairlines with no icon or container, and nothing indicates whether 31 °C is fine.
- **IO row values are a single grey string**: `28% · 128 GB / 460 GB` and `↓53.1 KB/s ↑697.3 KB/s`. The important part (the % used, the direction) is not emphasised.
- **Thermal badge.** It is a 6-pt dot plus caption. The dot's colour was a raw `CGColor` captured once (old L498, plus per-tick assignment at L1104), so it did not re-resolve when the appearance changed.

### 1.3 Expanded (`docs/panel-expanded.png`)
- **Memory segment bar.** Blue/purple/orange read as blue/purple/pink. There was no legend and nothing tied the caption text "应用 / 联动 / 压缩" to the colours. `SegmentBar.draw` (old L134–144) filled butting rectangles with no gaps, and only the outer corners were rounded.
- **The GPU row is visibly emptier** than CPU/内存. It had `alwaysShowDetail = false` (old L524), so it had no caption, and the row heights became uneven: 内存 grows while GPU stays short. The data for a caption already existed in the snapshot (`thermal.gpuC`).
- **The expand affordance is tiny.** The only target was a 9-pt chevron in an 18-pt button. It is easy to miss and it never changes direction.
- **Process table.** `AppProcRow` (old L309–374) is 28 pt tall with 18-pt icons. It has no hover state, and the `ellipsis.circle` buttons are always fully drawn on every row, which reads as visual noise in the screenshot. The sorted column is only distinguishable in the header (old `SortHeader` L376–435), not in the rows. Activity Monitor emphasises the sorted column.
- **Footer.** The footer has two bare text buttons with no icon and no hover feedback.

### 1.4 What was already right
- System popover chrome. There is no custom window, corners or shadow, and it follows Dark/Light correctly.
- SF Symbols, dynamic colours (`labelColor`/`secondaryLabelColor`) and tabular digits.
- Stable column alignment between `SortHeader` and `AppProcRow` via shared `HIG.proc*` constants.
- The process-table placement, the `活动监视器` hand-off, and right-click for preferences.

**Verdict:** the panel is functional and native but sits well below what AppKit can deliver. The problems are in *design-system* territory: tokens, hierarchy, grouping, colour semantics and sizing. None of them is a platform limit, so a view-layer refactor is justified.

---

## 2. Visual ceiling for this stack

| Surface | What is achievable here | Hard limits |
|---|---|---|
| **Menubar (`NSStatusItem`)** | `button.attributedTitle` with mixed fonts, sizes and colours, plus an SF Symbol image. Dynamic colours (`labelColor`, `secondaryLabelColor`, …) resolve against the menu bar's appearance. A custom `NSView` inside the button can draw sparklines and stacked two-line text (iStat style). | It is one line of ~22 pt height. Custom subviews must re-implement highlight, vibrancy and the "inactive display" dimming that the button does for free. Colour text bypasses the template treatment, so coloured values stay coloured on any wallpaper. There is no Liquid Glass control for menubar content. |
| **Panel (`NSPopover` + AppKit)** | Anything layer-backed: cards, capsule meters, gradient fills, CA animations, tracking-area hover, SF Symbol hierarchy, SF Pro Rounded, content-fitted height, accessibility labels. The popover provides system material, the arrow and the transient behaviour. | It is a popover, not a Control Center module. It cannot join the Control Center/Liquid Glass hierarchy, and true inner glass materials are not exposed for popover content in AppKit. It is single-process (no widget extension) and has no SwiftUI previews. |
| **SwiftUI (optional)** | `NSHostingView` inside the popover would give declarative animation, `.contentTransition(.numericText())` and `Gauge`. It would only need `build.sh` changes (`-framework SwiftUI`). | It adds per-tick diffing on every sample. That conflicts with the Round-1 "skip-if-unchanged" main-thread budget unless the model is carefully `Equatable`-gated, and it is a second UI paradigm in a one-person codebase. **Not used this round.** AppKit reaches ~90 % of the visual result. |

The ceiling for this repo is therefore roughly *iStat Menus' dropdowns or a Control Center-like module look inside a system popover*, with an attributed (not custom-drawn) menubar. This round targets exactly that.

---

## 3. Decision: refactor? **Yes**, scoped to the view layer

- The view code moved out of `HardwareStatus.swift` into four files. The one-file app is now five Swift files plus `hw_proc.c`.
- `AppDelegate` sampling, throttling, macmon, process, network, CPU, prefs and lifecycle code is **unchanged**.
- These glue functions changed: `buildTitle`, `longestTitleSample`, `applyStatusItemLength`, `renderStatusTitle`, `renderPanel`, `togglePopover` (2 lines), `popoverWillShow`, `buildPanel` (1 callback), and the entry point.
- No SwiftUI. No new runtime dependencies (QuartzCore was already imported).

---

## 4. What changed

### 4.1 Files
| File | Contents |
|---|---|
| `DesignSystem.swift` (new) | `HIG` tokens, `LoadLevel`, `cg(_:in:)` colour resolver, `symbol()`, `Motion` (reduce-motion-aware CA transactions), `makeLabel`, `RichLabel` (keyed attributed label), `Caption` (legend builder), `CardView`, `Hairline`, `IconTile`, `StatusPill`, `FlippedView` |
| `PanelComponents.swift` (new) | `ProgressTrack`, `SegmentBar`, `MetricRow`, `StatTile` (replaces `CompactValue`), `IORow`, `AppProcRow`, `SortHeader`, `FooterButton` |
| `MonitorPanelController.swift` (new) | Panel composition, content-fitted height (`fitToContentIfNeeded`), `resetForOpen`, `showProcRows`, `setThermal` |
| `StatusTitle.swift` (new) | `StatusSegment` + `StatusTitle.attributed/key/width`: the menubar typography |
| `HardwareStatus.swift` | View code removed. Render glue updated. Top-level code replaced by `@main enum HardwareStatusMain` with `withExtendedLifetime(delegate)` (`NSApplication.delegate` is weak) |
| `build.sh` | Compiles **all** Swift sources, listed explicitly in `SOURCES=(…)`. It fails fast if a new `*.swift` file is not listed. Adds `-parse-as-library` (required for `@main` in a multi-file module), `-module-name HardwareStatus`, and `-framework QuartzCore`. `hw_proc.c` is still compiled and linked as before. |

### 4.2 Design tokens (`HIG`, `DesignSystem.swift`)
- **Rhythm (4-pt grid):** outer inset 12, card padding 12, card gap 10, row gap 14, bar→caption 6, tile→title 10.
- **Shape:** card radius 12 (continuous curve), tile radius 6, capsule bars, hover radius 7.
- **Bars:** primary 6 pt (was 4), IO 4 pt. Track `labelColor α 0.09` (was `separatorColor α 0.12`).
- **Type scale:**

  | Use | Font |
  |---|---|
  | Title | 15 semibold |
  | Row title | 13 medium |
  | Values | **SF Pro Rounded 20 semibold, tabular** |
  | Unit | Rounded 12 secondary |
  | Tile values | Rounded 18 |
  | Captions | 11; numbers in captions are mono |
  | Column header | 11 medium |

- **Colour semantics:**

  | Metric | Colour |
  |---|---|
  | CPU | blue |
  | 内存 | green |
  | GPU | purple |
  | 存储 | indigo |
  | 网络 | teal |
  | 温度 | orange |
  | 风扇 | cyan |

  Memory segments are 应用 green, 联动 blue, 压缩 pink. Net arrows are ↓ blue and ↑ orange. Warn is orange and critical is red, with the same thresholds everywhere via `LoadLevel`.
- **Surfaces:** card fill `labelColor α 0.05` with a 0.5-pt stroke at α 0.06. The hairline is `separatorColor α 0.6` at 0.5 pt.

All colours are dynamic and are re-resolved in `updateLayer()` (`wantsUpdateLayer = true`), so Light/Dark and accent changes apply live. That fixes the old raw-`CGColor` thermal dot.

### 4.3 Components
- **Header:** 系统状态 at 15 semibold. The thermal state is now a **capsule pill** (`StatusPill`: tinted fill, dot and label; green/yellow/orange/red by `thermalState`). The subtitle uses tabular digits so the uptime doesn't shimmer.
- **Resources card:** CPU, 内存 and GPU `MetricRow`s.
  - Each row has a 24-pt **tinted icon tile** (System Settings style), a 13-medium title, and a big rounded value with a small `%`.
  - The 6-pt capsule bar has a gradient fill in the metric tint. Below it is a caption.
  - **The whole row toggles details** (`mouseUp`), not just the chevron. The chevron flips ⌄/⌃ and exposes an accessibility value.
  - Values tint orange/red past thresholds.
- **Memory expanded:** `SegmentBar` is now layer-based, with 1.5-pt gaps between segments and animated widths. The caption is a **legend whose dots match the segment colours**: `● 应用 13.0 GB ● 联动 2.7 GB ● 压缩 135 MB 交换 0 B`.
- **GPU parity:** the GPU row always has a caption. It shows `GPU 温度 41 °C` from the existing `thermal.gpuC`, `GPU 温度 读取中…` while waiting, or `需要 macmon 提供 GPU 数据` when there is no GPU data. When unsupported, the value shows a muted `未支持` placeholder instead of a 17-pt string. All three rows now have the same height and rhythm.
- **Thermo tiles:** CPU 温度 and 风扇转速 are two side-by-side mini cards. Each has a 20-pt icon tile (thermometer/fan) and a rounded value with a unit. Temperature turns orange at ≥85 °C and red at ≥95 °C.
- **IO card:**
  - 存储 shows an emphasised `28%` plus a muted `128 GB / 460 GB`, with a 4-pt indigo bar.
  - 网络 shows **tinted ↓/↑ arrows** with tabular rates.
- **Process card:**
  - The column header (`占用最高`, then `CPU ⌄`/`内存`) has the active column in medium label colour and an SF Symbol chevron. A hairline separates it from the rows.
  - The table shows **5 rows** (was 3) at 28 pt with 20-pt icons. Real app icons keep their own squircle (no extra masking). Daemons and CLIs get a centred `gearshape.2.fill`/`app.dashed` glyph instead of a stretched template.
  - The **sorted column is emphasised in every row.**
  - **Hover** shows a soft rounded highlight that bleeds 6 pt into the card padding, and the `⋯` button goes from 55 % to 100 % opacity. This uses one tracking area per row.
- **Footer:** `活动监视器` uses the real Activity Monitor app icon at 16 pt, and `更多` has a trailing `ellipsis.circle`. Labels brighten on hover.
- **Content-fitted popover:**
  - `fitToContentIfNeeded()` measures the stack and resizes the popover via `preferredContentSize` and `popover.contentSize`. The height is clamped between 360 pt and `min(780, screen − 48)`.
  - It only runs after something changed height (expand/collapse, visible row count, first open), **not every tick**.
  - It is pre-sized before `show` so the popover doesn't jump.
  - The scroll view remains only as a fallback for very short screens.
  - **This fixes the clipped third process row.**
- **Motion:**
  - Bar widths and segment widths animate with a 0.35 s ease-out. Colour crossfades on level change. The hover highlight fades.
  - Animation is disabled on first layout and on resize.
  - Animation is **fully disabled when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`** is on. The value is cached and invalidated on `accessibilityDisplayOptionsDidChangeNotification`.

### 4.4 Menubar (`StatusTitle.swift`)
- `button.attributedTitle` replaces `button.title`:
  - Metric names are **11 pt regular in `secondaryLabelColor`**.
  - Values are **12 pt medium, tabular, in `labelColor`**.
  - Separators are `·` in `tertiaryLabelColor` with thin spaces, which is tighter than before.
- **Padding:** values pad to 2 digits (`%2d`, was `%3d`). The padding uses **U+2007 figure spaces**, which are exactly one digit wide, so readings like 3 % → 45 % don't shift the item. This removes the old `CPU   3%` gap.
- **Load colour hints:**

  | Metric | Orange from | Red from |
  |---|---|---|
  | CPU / GPU | 75 % | 90 % |
  | 内存 | 85 % | 95 % |
  | 温度 | 85 °C | 95 °C |
  | 磁盘 | 80 % | 92 % |

  Normal values stay in the system label colour.
- **Width:** the item width is computed from the attributed rendering of the widest sample (`StatusTitle.width`), so it stays fixed while values change.
- **Default set unchanged:** `CPU · 内存 · 温度 · 网络`.
- **Wording:** the optional fan/disk labels now read `风扇` and `磁盘` instead of the single-character `扇`/`盘`. They mean the same thing and match the prefs menu wording.
- **Skip-if-unchanged is kept:** a plain `StatusTitle.key` (which includes the level) is compared before any attributed string is built or assigned.

### 4.5 Intentional behaviour nuances (UI only)
- The memory bar and menubar thresholds are now 85/95 instead of the generic 75/90. macOS routinely runs at 70–80 % "used", so the old thresholds painted memory orange most of the time.
- The CPU expanded caption says `P 核` / `E 核` instead of `P` / `E` (same meaning, clearer).
- There are 5 top-process rows instead of 3. The process scan already covered all processes, so this only affects rendering.

---

## 5. Round-1 preservation checklist

| Round-1 behaviour | Status | Where |
|---|---|---|
| Snapshot: sampling separate from rendering; sort/expand re-render without resampling | ✅ `onSortChanged → renderPanel()`. Row toggles go through `onToggleDetail → onSortChanged` | `HardwareStatus.swift` `buildPanel`, `MonitorPanelController.swift:98` |
| Process scan only while panel is open; ~0.6 s catch-up sample | ✅ untouched (`if panelVisible { sampleProcessTable() }`, `asyncAfter(.now() + 0.6)`) | `updateMetrics`, `sampleProcessTable` |
| macmon: skip when temp/GPU/fan not needed; ~5 s idle; timeout; drain stdout; multi-path lookup | ✅ untouched. The GPU caption reads `snapshot.thermal.gpuC` and triggers no new sampling | `refreshTempsAsync`, `resolveMacmonPath` |
| Process identity cache; CPU/net wrap safety; kill re-check | ✅ untouched (`procIdentityCache`, `counterDelta`, `friendlyNameAndKey(for:).1 == appKey`) | — |
| Main-thread skip-if-unchanged | ✅ Kept and extended: `setText`; `RichLabel.set(key:)` builds attributed strings only on change; `ProgressTrack.set` early-returns; `SegmentBar.set` ignores sub-half-point changes; status title compares `StatusTitle.key`; `setIcon` keyed; `fitToContentIfNeeded` gated by a dirty flag | `DesignSystem.swift`, `PanelComponents.swift` |
| Disk cache ~15 s; timer tolerance + deduped restart | ✅ untouched | `diskMaxAge`, `restartTimer` |
| Default menubar `CPU · 内存 · 温度 · 网络` | ✅ prefs and migrations untouched | `seedDefaultsIfNeeded` |
| Chinese UI semantics | ✅ all strings kept. Wording refinements are listed in §4.4/§4.5 | — |
| No daemon; pause on lock/sleep | ✅ untouched | `installLifecycleObservers`, `desiredInterval` |
| No git commit/push | ✅ the working tree is modified only | — |

New per-tick costs, all small:
- One `[StatusSegment]` array and one key string per tick, which replace the old title string.
- `stack.fittingSize` only when the dirty flag is set.
- No new timers, observers (beyond one reduce-motion notification) or subprocesses.

---

## 6. How to verify on a Mac mini

```bash
cd HardwareStatus
./build.sh                      # expect "BUILT …/HardwareStatus.app"
open HardwareStatus.app
```

If `build.sh` fails, the likely type-level suspects are listed in §7.

### Visual checklist
**Menubar**
1. Names (CPU/内存/温度) are lighter and smaller than the numbers, and the dots are faint.
2. There is no wide gap in `CPU 3%`.
3. The item width doesn't change as values tick.
4. Run `yes > /dev/null &` ×(cores) and confirm CPU turns orange, then red. `killall yes` afterwards.
5. Switch the menu bar between Light and Dark (wallpaper or appearance) and confirm the text stays legible.

**Panel, collapsed**
1. The panel shows cards, coloured icon tiles, 6-pt capsule bars and rounded numerals.
2. **All 5 process rows are visible with no clipping behind the footer.**
3. The thermal pill is green.

**Expanded**
1. Click anywhere on the 内存 row. The panel grows smoothly, the bar becomes 3 segments with gaps, and the legend dots match the segments.
2. Click again and the panel shrinks back.
3. CPU expanded shows the load and P/E cores.
4. GPU always has a caption.

**Process table**
1. Hovering a row shows a soft highlight and a brighter `⋯`.
2. Click 内存 in the header: the chevron moves, the memory column becomes primary in every row, and the numbers do **not** jump (no resample).

**Motion**
1. Bars glide when values change.
2. Turn on System Settings › Accessibility › Display › **Reduce motion** and confirm the bars snap instead.

**Appearance**
1. Toggle Light/Dark while the panel is open. Cards, tracks, tiles and the pill should re-tint.
2. Change the accent colour and confirm nothing breaks; metric tints are fixed by design.

**Footer**
1. The Activity Monitor icon is shown, and clicking it opens Activity Monitor.
2. 更多 opens the menu. Right-click on the menubar item still opens the prefs menu.

### Performance regression check (Round-1 parity)
- **Panel closed:** Activity Monitor › HardwareStatus should stay at ≈0 % CPU. The process scan should not run when closed, which you can confirm with `sudo fs_usage -f exec | grep macmon`: ~5 s cadence only if 温度 is in the menubar.
- **Panel open:** about 1 Hz updates. CPU should be comparable to Round 1, because bar animations run in the render server.

---

## 7. Platform limits

- This sandbox is Linux. There is no macOS SDK, `xcrun`, AppKit, QuartzCore or libproc, so **`./build.sh` was not run, no app was produced, and the new UI has not been seen rendered.** The critique is based on the provided screenshots. The "after" state is described from the code, not from screenshots.
- **What was checked:** Swift 6.0.3 Linux toolchain (`/tmp/swiftdl/tc`, run with `LD_LIBRARY_PATH=/tmp/swiftlibs` for a `libncurses.so.6` shim). `swiftc -parse` passes for each of the 5 files individually and for `swiftc -parse -parse-as-library *.swift` together. A deliberately broken file is rejected, so the pass is meaningful. **This is a syntax check, not a type check against Cocoa.**
- **Type-level items to watch on the first macOS build:**
  - `NSFontDescriptor.withDesign(.rounded)`, which is optional-returning and handled.
  - `CALayer.cornerCurve` (macOS 10.15+).
  - `NSButton.imageHugsTitle`.
  - Overriding `isHidden` with `didSet` in `AppProcRow`.
  - `RichLabel(labelWithString:)`, an inherited convenience init.
  - `@main` together with `-parse-as-library` in a multi-file module.

  All are standard for the `macosx26.0` target.
- **Menubar caveat:** attributed titles with explicit dynamic colours render correctly in Light/Dark menu bars. However, the orange/red warn colours are not template-tinted, which is the intended signal. Check legibility over very bright or very saturated wallpapers.
- Not done (future): a custom-view menubar (two-line or sparkline), SwiftUI `.numericText()` digit transitions, and a menubar pref to disable colour hints.
