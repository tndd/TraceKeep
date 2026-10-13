# TraceKeep compact monitor design QA

Date: 2026-10-14

Source visual truth: `docs/design/mini-reference.png` (selected third gauge concept, revised to remove all colored ticks).
Implementation: `docs/design/mini-implemented.png`; additional states `docs/design/mini-hot.png`, `docs/design/mini-stale.png`.
Viewport: 300 × 228 CSS pixels; minimum width checked at 280 × 228. Browser screenshot is 300 × 228 pixels, DPR 1. Generated source is 1499 × 1049 pixels (approximately 300 × 210 logical design pixels). Compared both images in the same review input, accounting for the source presentation border and native-window content area. No claim of pixel-perfect or native-window screenshot verification.

## Findings

No actionable P0/P1/P2 visual findings remain.

- Typography: Segoe UI / Yu Gothic UI keeps prominent tabular temperature numerals, compact uppercase sensor labels, and quiet recorder text. Windows system fonts intentionally replace the generated mock's unspecified face. Japanese labels use the existing product language.
- Spacing: two equal gauges, central divider, five compact lamps, one detail action and one footer. No clipping or scroll overflow at 300 or 280 pixels. Initial numeric-only layout was superseded by the selected gauge layout before handoff.
- Colors: uniform active arc color is computed only from temperature. No green/yellow/red ticks or colored zones remain. Green, yellow and red were verified with synthetic samples; stale CPU shows a gray track and dash while GPU remains live. Lamps describe recorder state separately.
- Assets: actual selected Image Gen TraceKeep logo is used as a PNG and multi-resolution Windows ICO. Chevron uses Heroicons with its license. Gauges are data-driven canvas charts, not raster replacements for measurements.
- Copy/content: CPU, GPU, five recorder groups, details and recording status match the selected information hierarchy. Labels/footer are localized. The synthetic browser preview carries a visible mock-data label, absent from the real Tauri app.

## Accepted implementation differences

- Arc sweep follows a defined 0–100 °C scale rather than the image generator's illustrative positions. Values above the display scale retain their numeric value and cap the arc.
- Temperature color anchors are presentation conventions with explanatory hover text; they are not claims about hardware health or protection limits.
- Native window framing replaces the mock's decorative perimeter. Content area is 300 × 228 to preserve readable live status text.
- Whole degrees are displayed in the small window; hover and accessible meter text retain one decimal.

## Interaction and state verification

- Details button navigates to the full monitor in browser preview. Native window opening is covered separately by Windows CI lifecycle tests.
- Keyboard Tab reaches the CPU gauge, with accessible temperature label; each lamp has a state label and keyboard focus.
- Five lamps remain visible if worker records disappear; stale log state overrides an old green worker state.
- Browser console checked: no errors in compact view.
- Source and implementation are entirely visible at their displayed sizes; no separate crop was necessary for this single small component. Focused hot/stale screenshots verify gauge and lamp behavior.
- Automated tests cover colors, invalid/absent readings, opt-out, stale state and scale clamping.

## Comparison history

First gauge comparison passed after correcting the planned content height before capture. An additional full-console brand check found the PNG at its intrinsic 128 px size (P2); explicit 30 × 30 px bounds and compact single-line wordmark fixed it. A browser reload confirmed 30 × 30 px rendering and the complete TraceKeep wordmark.

## Follow-up polish

P3: small-text rasterization and tray readability vary with Windows display scaling; test additional physical displays if requested. Actual user's native tray pixels are not available through the current computer-use interface.

## Implementation checklist

- [x] Selected brand and gauge structure
- [x] No threshold tick marks
- [x] Synthetic normal/hot/stale visual checks
- [x] Minimum width, keyboard and details navigation
- [x] Temperature and recording-state unit checks
- [x] Local-only assets

final result: passed

## Compact mini follow-up (2026-10-14)

The later compact layout supersedes the original 300 × 228 size and footer described above. Source revision: 5831b77. The details action uses the bundled Heroicons expand symbol. The redundant recording footer is removed; the five independently labelled collector lamps remain. Error notices remain available.

The default content size is 300 × 202, with a 280 × 202 minimum. Browser verification at both widths found no horizontal or vertical overflow. The expand action opened the full dashboard. JavaScript syntax checks and all eight mini state tests passed. The private screenshot uses explicitly labelled synthetic temperatures and is kept outside the repository. The temporary viewport override was reset. Native verification is tracked by Windows CI; native pixels are not accessible through the current computer-use interface.

Windows CI run 38465206526, attempt 2, completed successfully: frontend/PowerShell checks, 19 Rust tests, release build and tray lifecycle. The verified artifact was installed by replacing only the per-user viewer; coordinator and all five worker PIDs remained unchanged, with all workers recording and zero reported errors. Progress reporting did not expose steps until completion, so missing live steps alone must not be treated as proof that a runner is idle.

final result: passed

## Full device workspace — production integration (2026-10-14)

Tested executable source: `04c569530e65536c55b33b41dd7969089446fa69`.
Windows CI run: 38459086631, completed successfully (frontend, recorder/evidence migration, Rust, release build and tray lifecycle tests).

Reference: accepted device workspace at local port 8771, captured during this turn after the requested CPU panel revision. Implementation: production frontend at local port 8772, using output from the compiled `pcdiag history` command. Private reference and implementation screenshots remain outside this repository in local outputs; no real logs or screenshots are published.

Visual review compared both screenshots together. The temporary browser viewport was requested at 1320 by 900; per-tab browser scaling produced different effective capture sizes, so the comparison assessed layout proportions and content rather than exact pixels. Full-page capture showed a browser capture crop/sticky-position artifact; viewport screenshots and DOM bounds were used to verify the actual visible layout. The override was reset afterwards.

- Preserved the navy/cyan palette, left navigation, summary metric strip, six representative device panels and event/coverage section.
- CPU summary now pairs measured load and temperature in a scatterplot with marginal empirical distributions. Labels, units, paired sample count and missing-data behavior are present.
- GPU state chords, interval disk-latency box plots, board-voltage frequencies, process-family packing and power-limit heat cells retain distinct visual forms.
- Events use five-minute cells, severity colors and counts when space permits. Cell selection, multiple-event selection, linked sensor time and raw-record drawer were verified with real saved records.
- All device pages and empty-source states were checked. Missing values remain unavailable; invalid/reset counters are excluded. No new browser console errors remain after fixing the initial missing context import.
- The period toolbar and actual recorder controls intentionally replace the mock banner and simulated controls. History is manually loaded in two-hour windows; recorder state is polled separately.
- Native installed viewer reported a fresh successful workspace render. Native pixels are not available to current computer-use tools; browser verification uses the same compiled frontend assets.
- Replacing only the per-user viewer preserved the recorder PID and all five worker PIDs. All workers continued recording with zero reported errors.

Read-only verification of a two-hour saved-log window returned all expected CPU/board/activity samples and events without truncation, invalid records or unresolved references. Process and GPU-detail payloads intentionally retain only their last two samples in a window, as documented in the UI.

No actionable P0/P1/P2 visual findings remain within the reviewed desktop layouts. P3: verify additional physical display scaling if requested; extremely narrow chart cells omit their visible counts but retain accessible labels.

final result: passed

## Summary visual refinements (2026-10-14)

Source revision: d637f1d. CPU summary now compares the first and second hours of the selected interval in blue and yellow, including marginal distributions and explicit time legends. Event cells retain severity hue and use five fixed count bands for intensity; the same count has the same intensity across providers and filters. Removed permanent cell outlines and overlaid count labels; hover/accessibility and selection retain exact counts.

Board voltage now shows time-by-value occupancy, normalized by the available samples in each five-minute column, plus an all-period marginal distribution. Discrete observed values remain discrete; more than 12 unique levels are explicitly binned without smoothing. Empty columns are distinguished from zero occupancy. Hover/keyboard selection exposes the numerator and denominator.

Validation: seven frontend tests passed, covering fixed event thresholds, empty/discrete voltage data and conservation under binning. Real-record browser review verified both CPU colors, differing intensity for two vs four events, keyboard event drilldown and voltage-cell details. Wide desktop and narrow layouts were inspected; no new console errors. Screenshot saved privately outside the repository. The browser viewport override was reset. Collectors are unchanged.

final result: passed
