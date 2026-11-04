# Changelog

## 1.2.0

- When the internet stops, on any network, the menu says which step broke: the Wi-Fi, the router, a login page, the network's name server, the router's internet, or your VPN. Wi-Fi Refill looks at all of them at once, over the Wi-Fi itself, and says Offline when what it sees doesn't settle it.
- A VPN that stops getting through while the Wi-Fi works now shows in the menu too.
- The cup's steam shows your Wi-Fi: one to three waves for the signal, rising faster while the network is busy, a drip while Wi-Fi Refill logs you back in, and an exclamation mark when something is broken. It reads your Mac's own Wi-Fi and sends nothing, stands still with Reduce Motion, and Animate the Cup in the menu turns it off.

## 1.1.1

- A login page's web view now refuses the camera and microphone and doesn't offer them to the page. In 1.1.0 the refusal was not wired up; macOS still refused, since Wi-Fi Refill has no camera or microphone permission.

## 1.1.0

- Logs you back in to Awing Free Wi-Fi pages on Extreme Networks Wi-Fi, as at Highlands Coffee.
- Teach it any other login page that only needs button presses: log in once in its window, and it presses the same buttons each time the network logs you out, waiting for adverts and countdowns the way you did.
- Share This Login Page… sends what it learned, the buttons by name and caption with addresses and identifiers replaced, never anything you typed, so the next version can know the page for everyone.
- Learns how long a session lasts from the network's logouts when the login page doesn't say, and checks right when the next one is due to end.
- Works with a VPN that carries all traffic, such as Tailscale with an exit node: login pages are reached over the Wi-Fi itself.

## 1.0.1

- Fixes a case where the internet coming back right after a login interrupted Wi-Fi Refill before it noted the login. You were logged in, but the menu did not count it, and the end of the next session could be caught up to five minutes late.

## 1.0.0

- Logs you back in to Ruijie Cloud login pages with a One-click Login button when the cafe's Wi-Fi ends your session.
- Learns how long a session lasts from the login page and checks when it is due to end, with a check every five minutes in case the router ends it early.
- Asks once per network before it logs in. Networks in the menu turns it off for one network; Pause turns it off everywhere.
- Report This Login Page… shows a summary of an unsupported login page that you can send as a GitHub issue.
- English and Vietnamese.
