# Changelog

## 1.4.0

- Cup on the Desktop, in the menu, puts a bigger cup on your desktop. Its steam is your Wi-Fi, its coffee is what's left of the cafe session, and a little kettle refills it when Wi-Fi Refill logs you back in. When something breaks it turns cold and says what. Drag it anywhere, point at it for the menu's status line, and right-click to hide it. It reads your Mac's own Wi-Fi and sends nothing.
- Right after joining a network, while the router is still handing out an address, the menu no longer says the router isn't answering.

## 1.3.0

- Teach pages that ask you to type, such as a phone number, a room number or a voucher: tick Remember what I type on this page while you teach it, and Wi-Fi Refill types it again for you, with the buttons, each time the network logs you out. What you typed stays in your Keychain on this Mac, never in a shared page, a report or the log. Pressing Return in a field counts as pressing the form's button.
- When the internet is gone, the menu offers Use Your iPhone's Hotspot…, which opens Wi-Fi settings where macOS lists your iPhone. macOS joins it by itself only when no Wi-Fi is around at all.

## 1.2.1

- When a cafe session ends, the menu says Wi-Fi Refill is waiting for the login page, instead of blaming the router's internet for the few seconds before the page appears.
- Wi-Fi Refill remembers when a cafe session ends across updates and restarts, so it still logs you back in right on time.
- After a failed login it tries again after 3 seconds, then 8, then 20, instead of waiting 20 seconds; routers often refuse for a moment right as a session ends.
- It notices when the internet stops long after its last check, on any network: when your Mac keeps sending and nothing comes back, it checks, and the menu says what broke. It reads this from your Mac's own counters and sends nothing until then.
- Only a tunnel counts as a VPN, so another network service on the Mac is no longer taken for one.

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
