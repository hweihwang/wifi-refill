# Wi-Fi Refill

Menu bar app that logs a Mac back in to cafe Wi-Fi login pages. SwiftPM, no Xcode project.

- `Sources/RefillCore`: everything testable. `PortalClient` (HTTP that never follows redirects by itself, sent straight over the Wi-Fi by `DirectTransport` so a VPN can't hide the login page), `Drivers`, `RuijieCloud`, `AwingExtreme`, `MikroTikHotspot` and `UniFiGuestPortal` (one login page kind each), `Gateway` (the Wi-Fi under any VPN), `Recipe` and `Replay` (pages people taught: which buttons, and when to press them, pure), `BuiltInRecipes` (shared pages that ship, after drivers), `PageScript` (the web view's script), `SessionLength` (session length learned from logouts, pure), `WiFiRelay` (SOCKS5 relay that sends a taught page's web view out on the Wi-Fi, only to the internet and the cafe's subnet), `Schedule` (when to check, pure), `PortalReport` (allowlisted summary of unknown pages).
- `Sources/WiFiRefill`: AppKit glue. `Watcher` (network events, timers, consent), `LoginBrowser` (the web view that learns and replays a taught page), `AppDelegate` (menu), `WelcomeWindow`, `Hotspot` (turns on and joins the person's iPhone hotspot through Sharing, a private framework).
- `swift test` replays a recorded real network through `FakeNetwork`. `scripts/install-dev.sh` builds, signs and opens the app. `scripts/release.sh VERSION [--publish]` notarizes, packages and publishes (needs APPLE_API_* env, the Sparkle key, and clones of homebrew-wifi-refill and hweihwang.com next to this repo).

Rules
- Add or change a driver only with a recording from a real network, or from the vendor's own firmware in a virtual machine (say which), and keep its tests' hostile cases.
- Every network request must appear in the README's privacy table.
- User-facing strings go through `L(...)` and need a Vietnamese line in `Resources/vi.lproj/Localizable.strings`.
- The app's log and reports never contain query values, page bodies, or addresses that identify a person.
