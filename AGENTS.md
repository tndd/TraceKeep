# Development rules

- Preserve ongoing recording. Never stop or replace installed collectors as a side effect of GUI work.
- Keep collection independent of window lifetime. The window X returns to the tray without stopping. Explicit tray Exit must stop the recorder successfully before removing the icon; cancellation/failure retains the tray. A GUI crash must not stop recording.
- Never commit real logs, exports, crash dumps, tokens, user paths or third-party binaries.
- Do not infer component failure from generic motherboard labels or a single sampled value.
- Avoid hardware writes, stress tests, or driver installation in automated tests.
- Test log truncation, partial writes, missing data and stale data using synthetic fixtures.
- Run `cargo test` and a Windows release build for Rust changes. Verify UI states against real or clearly labelled synthetic data.
- Keep the frontend local, dependency-light and usable without external network requests.
