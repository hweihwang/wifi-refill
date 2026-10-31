# Wi-Fi Refill

Menu bar app that logs a Mac back in to cafe Wi-Fi login pages. SwiftPM, no Xcode project.

- `Sources/RefillCore`: everything testable. `PortalClient` (HTTP that never follows redirects by itself), `Drivers` and `RuijieCloud` (one login page kind each), `Schedule` (when to check, pure), `PortalReport` (allowlisted summary of unknown pages).
- `Sources/WiFiRefill`: AppKit glue. `Watcher` (network events, timers, consent), `AppDelegate` (menu), `WelcomeWindow`.
- `swift test` replays a recorded real network through `FakeNetwork`. `scripts/install-dev.sh` builds, signs and opens the app. `scripts/release.sh VERSION [--publish]` notarizes, packages and publishes (needs APPLE_API_* env, the Sparkle key, and clones of homebrew-wifi-refill and hweihwang.com next to this repo).

Rules
- Add or change a driver only with a recording from a real network, and keep its tests' hostile cases.
- Every network request must appear in the README's privacy table.
- User-facing strings go through `L(...)` and need a Vietnamese line in `Resources/vi.lproj/Localizable.strings`.
- The app's log and reports never contain query values, page bodies, or addresses that identify a person.
