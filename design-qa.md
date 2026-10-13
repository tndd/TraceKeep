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

First gauge comparison passed after correcting the planned content height before capture. No post-capture P0/P1/P2 iteration was required.

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
