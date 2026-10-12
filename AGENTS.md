# Development rules

- Preserve ongoing recording. Never stop or replace installed collectors as a side effect of GUI work.
- Keep hardware collection independent of GUI lifetime. Closing the viewer must not stop Windows tasks.
- Never commit real logs, exports, crash dumps, tokens, user paths or third-party binaries.
- Do not infer component failure from generic motherboard labels or a single sampled value.
- Avoid hardware writes, stress tests, or driver installation in automated tests.
- Test log truncation, partial writes, missing data and stale data using synthetic fixtures.
- Run `cargo test` and a Windows release build for Rust changes. Verify UI states against real or clearly labelled synthetic data.
- Keep the frontend local, dependency-light and usable without external network requests.
