<p align="center"><img src="docs/icon.png" width="128" height="128" alt="Wi-Fi Refill icon: a white cup with Wi-Fi waves rising like steam, on caramel"></p>

<h1 align="center">Wi-Fi Refill</h1>

<p align="center"><b>Free refills for cafe Wi-Fi.</b><br>
A small Mac menu bar app that logs you back in when the cafe's Wi-Fi logs you out.</p>

<p align="center">
  <a href="https://github.com/hweihwang/wifi-refill/releases/latest/download/Wi-Fi-Refill.dmg"><b>Download for macOS</b></a> ·
  <a href="https://hweihwang.com/wifi-refill/">Website</a> ·
  <a href="#install-with-homebrew">Homebrew</a> ·
  <a href="LICENSE">MIT</a>
</p>

<p align="center"><img src="docs/menu.png" width="720" alt="A Mac at a cafe with a document open. The Wi-Fi Refill menu hangs below the cup in the menu bar and says VLAN233: logged in."></p>

Many cafes put their Wi-Fi behind a login page with a single "connect" button, and end the session after an hour.
Your Mac stays on the Wi-Fi, but nothing loads until you open a page like neverssl.com and press the button again.

Wi-Fi Refill presses it for you. It learns how long a session lasts, from the login page or from the network's own
logouts, checks when it is due to end, and logs you back in. On a network without a login page it looks every five minutes for the first three hours,
then stays quiet until your Mac joins another network.

- **No setup.** No accounts and no passwords. It asks once per network before it logs in.
- **Quiet.** It checks when your Mac joins a network or wakes up, when a session is due to end, and every five minutes
  on a cafe network in case the router ends it early. Other networks get the same five-minute check for three hours
  after joining, then only when your Mac keeps sending and nothing comes back, which it sees in its own counters.
- **Careful.** It only presses buttons on login pages it was tested against or that you taught it, and it only types
  what you taught it to, when you ticked **Remember what I type on this page**.

## On any Wi-Fi

When a check finds no internet, or the check takes more than three seconds, Wi-Fi Refill looks at every step between
your Mac and the internet at once, over the Wi-Fi itself, and the menu says which one broke: the Wi-Fi, the router, a
login page, the network's name server, the router's internet, or your VPN. It takes a few seconds. When what it sees
doesn't settle it, the menu says Offline rather than guess. When the internet is gone, **Use Your iPhone's Hotspot…**
opens Wi-Fi settings, where macOS lists your iPhone; macOS joins it by itself only when no Wi-Fi is around at all.

The steam on the cup shows your Wi-Fi: one to three waves for the signal, rising faster while the network is busy. The
cup is filled while Wi-Fi Refill keeps you logged in at a cafe, drips while it logs you back in, and shows an
exclamation mark when something is broken. The steam comes from your Mac's own Wi-Fi readings and sends nothing. It
stands still with Reduce Motion, and **Animate the Cup** in the menu turns it off.

## Which login pages work

Wi-Fi Refill knows two kinds of login page, and learns any other page that only needs button presses.

- **Ruijie Cloud** pages with a **One-click Login** button. You will recognise them by the address
  `portal-…ruijienetworks.com` in your browser and the button at the bottom of the page. Tested on a live cafe network
  that logs you out every 60 minutes.
- **Awing** Free Wi-Fi pages on Extreme Networks Wi-Fi, as at Highlands Coffee. The address starts with
  `v1.awingconnect.vn/login`, and the page shows an advert with a connect button. These pages don't say how long a
  session lasts, so Wi-Fi Refill learns it: it notes when the network logs you out, and after a session or two it
  checks right when the next one is due to end.

### Teach it any other page

When a login page Wi-Fi Refill doesn't know appears, choose **Teach Wi-Fi Refill This Login Page…** in the menu. The
page opens in Wi-Fi Refill's window; log in as you usually do. Wi-Fi Refill remembers which buttons you pressed, and
each time the network logs you out it opens the page in a window you don't see and presses them again, waiting for any
countdown the way you did. Teaching a page allows Wi-Fi Refill to log in on that network; another network with the
same login page, such as another store of the same chain, asks once.

If the page asks you to type, such as a phone number, a room number or a voucher, tick **Remember what I type on this
page** in the window before you log in. Wi-Fi Refill then remembers what you typed into each field and types it again
for you, with the buttons, each time the network logs you out. What you typed stays in your Keychain on this Mac, never
in the settings, the log, a report or a shared page. Without the tick, it doesn't learn the page and leaves it to you.
A code that changes each time, such as one sent by text message, can't be replayed: Wi-Fi Refill asks you to teach
the page again. Pages that open another window or show a CAPTCHA stay with you. When the page changes, for example a
new advert, Wi-Fi Refill starts over on a fresh page, up to three times, and if that still does not log in it asks you
to teach the page again.

To help everyone else at that cafe, choose **Share This Login Page…**. It sends what Wi-Fi Refill learned, the buttons
by their names and captions, with addresses and anything that looks like an identifier replaced and never anything you
typed, as a GitHub issue you can read and edit first. Shared pages
that check out on a real network ship with the next version, so Wi-Fi Refill knows them without teaching.

If you meet a page Wi-Fi Refill can't learn, choose **Report This Login Page…** in the menu. It describes how the page
is built: addresses with unfamiliar names replaced, parameter and form field names, and no values. You can read and
edit it first, and GitHub opens with it filled in.

## Install

Download [Wi-Fi-Refill.dmg](https://github.com/hweihwang/wifi-refill/releases/latest/download/Wi-Fi-Refill.dmg), open
it and drag Wi-Fi Refill to Applications. It is signed and notarized by Apple. It needs macOS 14 Sonoma or later and
runs on Apple silicon and Intel Macs.

<img src="docs/welcome.png" width="460" align="right" alt="Wi-Fi Refill's welcome window: it is in your menu bar, logs you back in when cafe Wi-Fi logs you out, asks once per network, knows Ruijie Cloud and Awing login pages, and can be taught any other page that only needs button presses.">

Look for the cup in your menu bar. The first time a supported login page appears, Wi-Fi Refill asks whether it may log
in on that network, and macOS asks whether it may reach devices on your local network. Allow both: the last step of
the login is a request to the cafe's router or Wi-Fi controller.

### Install with Homebrew

```sh
brew tap hweihwang/wifi-refill
brew trust --tap hweihwang/wifi-refill
brew install --cask wifi-refill
```

Homebrew asks you to trust taps outside its own repositories; the second line does that for this one.

Wi-Fi Refill updates itself, so you never need to download it again.

## Privacy

Wi-Fi Refill has no analytics and no account. It makes these requests and no others:

| To | When | Why |
|---|---|---|
| `captive.apple.com` | When your Mac joins a network or wakes; on a cafe network when the session is due to end and every five minutes; on other networks every five minutes for three hours after joining; when your Mac keeps sending and nothing comes back, at most once a minute; on a cafe network that just stopped, every two seconds for up to twenty seconds while its login page appears; once more when a check finds no internet or takes over three seconds | The same check macOS uses to notice a login page |
| The login page's own servers | When a supported login page appears | To read the page before asking you, and to log in once you agree |
| The cafe's router or Wi-Fi controller | After you agree, on that network | The last step of the login |
| Your router: a ping, or the start of a connection that sends nothing | When a check finds no internet, or takes over three seconds | To tell whether the router answers |
| Your network's own name server: one question for `captive.apple.com` | When a check finds no internet, or takes over three seconds | To tell a broken name server from a broken line |
| `captive.apple.com` by its address: the start of a connection that sends nothing | When a check finds no internet, or takes over three seconds | To tell whether the router's line reaches the internet |
| `captive.apple.com` through your VPN, never following a redirect | With each check, when a VPN carries all traffic | To tell whether the VPN is the problem |
| Whatever a taught login page loads | When that page appears on a network you allowed, and while you teach it | Running the page so Wi-Fi Refill can press its buttons |
| `hweihwang.com` | Once a day | To look for updates |
| `github.com` | When an update downloads | The update itself |
| `github.com` | Only when you choose Open GitHub in a report | The report travels in the page address; it is published only if you submit the issue |

The first eight rows, except the check through your VPN, go over the Wi-Fi or Ethernet itself, even when a VPN is on: while a login page holds the network, a
VPN can't reach anything, and the login page only exists on the cafe's network. macOS checks for login pages the same
way.

A login page Wi-Fi Refill knows runs without its scripts, and Wi-Fi Refill never follows it to other websites. A
taught page runs in a private web view, as in a browser: its scripts and adverts run, and it may contact its
advertisers. The web view keeps no cookies or history once it closes, can reach only the internet and the cafe's own
network, has WebRTC turned off, and closes as soon as the network opens. What you taught (which buttons and fields, on which page) stays on your Mac with the settings
and a short log at `~/Library/Logs/WiFiRefill.log`; what you typed, if you ticked Remember what I type, stays in your
Keychain and goes only into the page you typed it into.

## Questions

**Why does the cafe log me out?** The cafe's router gives each login a fixed time, often an hour. When it runs out,
the router sends every web request to the login page again, while your Mac still shows a working Wi-Fi connection.

**How fast is it?** Wi-Fi Refill learns the session length from the login page, or from the network's logouts when the
page doesn't say, and checks when the session is due to end, then every two seconds until the router ends it. A taught page takes as long as the page does, adverts and
countdowns included, usually under half a minute. If the router ends a session early, the next check comes
within five minutes, or sooner if macOS notices the change.

**What does the cup in the menu bar mean?** Steam: your Wi-Fi signal, one to three waves, faster while the network is
busy. Filled: you are on a cafe network and logged in. A drip: Wi-Fi Refill is logging you back in. An exclamation mark
instead of steam: something is broken, and the menu says what. With **Animate the Cup** off, the cup stands still: filled
when you are logged in at a cafe, an outline when there is nothing to do, and a warning sign when the last login failed.

**Can I turn it off for one network?** Yes. Open **Networks** in the menu and turn off **Log In Automatically**, or
choose **Pause** to stop everywhere.

## Build from source

You need Xcode 16 or later.

```sh
swift test                 # the login flow is replayed from a recording of a real network
scripts/install-dev.sh     # builds, signs and opens ~/Applications/Wi-Fi Refill.app
swift run refill-doctor    # looks at every step to the internet on this network and names the broken one
```

[CONTRIBUTING.md](CONTRIBUTING.md) explains how to add support for another login page.

## License

MIT, see [LICENSE](LICENSE). Wi-Fi Refill uses [Sparkle](https://sparkle-project.org) for updates, also under the MIT
license. It is not affiliated with Ruijie Networks, Awing, Extreme Networks or Highlands Coffee.

Made by [Hoang](https://hweihwang.com/). Found a bug? [Open an issue](https://github.com/hweihwang/wifi-refill/issues).
Security problems go to [SECURITY.md](SECURITY.md).
