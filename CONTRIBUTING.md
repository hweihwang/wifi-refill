# Contributing

Thanks for helping. The most useful contribution is support for another kind of login page, so most of this file is
about that.

## Adding a login page

Most login pages need no code: people teach them from the menu. A driver is for a page worth logging in to without
running its scripts, which is faster and leaks nothing to its advertisers. Wi-Fi Refill only uses drivers someone has
tested on a real network. A driver needs three things:

1. **A recording.** Connect to the network, wait until the login page appears, and record what the router and the
   login page send back, for example with `curl -v http://captive.apple.com/hotspot-detect.html` and the redirects that
   follow. **Report This Login Page…** in the menu gives a safe summary to start an issue with. Before you commit a
   recording, replace every value that identifies a person, a device or a network: hardware addresses, public IP
   addresses, router serial numbers, tokens, signatures and session ids. Keep the shape of each value.
2. **A driver** in `Sources/RefillCore`, conforming to `PortalDriver`:
   - `entry(in:)` recognises the login page from the probe's answer, by host name, never by page text alone.
   - `prepare(from:on:client:)` walks the login page up to its button without pressing it. Follow only addresses
     on the login page's own hosts, and stop with `LoginError.unsupported` at anything you have not tested, such as
     another mode of the same vendor.
   - `login(_:client:)` does what the button does. Send tokens only to the device the page named, and only if it is on
     the Mac's own network: the current router itself when the page names a router.
3. **Tests** in `Tests/RefillCoreTests` that replay the recording through `FakeNetwork`: the happy path, and what
   happens when the page points somewhere it should not.

Then add the driver to `Drivers.all`, describe the login page in the README, and open a pull request that says where
and when you tested it.

Out of scope: login pages that need a voucher, a room number, a phone number, a password, a payment or a CAPTCHA.

## Sharing a taught page

A page people teach needs no code at all. Someone teaches it, chooses **Share This Login Page…**, and the issue carries
the recipe in the report's shape: the page's address with unfamiliar names replaced, and each pressed button by tag,
type and role, and by id, name, label and text where they read like a caption. Identifiers are replaced, so the issue
says what to look for, not everything needed to press it. To ship it for everyone:

1. Check it on a real network: teach the page yourself, or replay the shared recipe there.
2. Add it to `Recipe.builtIn` in `Sources/RefillCore/BuiltInRecipes.swift`, with where and when it was checked.
3. Add a test that replays it against the page's elements as recorded, as `SharedRecipeTests` does for Awing.

Shipped recipes come after drivers, and Wi-Fi Refill asks once per network before it uses one.

## Everything else

- `swift test` runs the tests. `scripts/install-dev.sh` builds the app, signs it with your Developer ID and opens it.
- Keep the app quiet: no new background checks on networks without a login page, and no network requests that the
  privacy table in the README does not list.
- User-facing text lives in English in the code and in Vietnamese in `Resources/vi.lproj/Localizable.strings`. Add
  both.
