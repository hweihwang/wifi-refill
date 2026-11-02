# Security

Wi-Fi Refill talks to networks you do not control, so security reports are welcome.

Please report a problem privately through [GitHub's security advisories](https://github.com/hweihwang/wifi-refill/security/advisories/new)
instead of a public issue. Say what a hostile network or login page could make the app do, and how to reproduce it. I
will answer within a week and credit you in the release notes unless you prefer otherwise.

Things that are in scope include the app requesting addresses outside the login page's own hosts and the cafe's
router or Wi-Fi controller, sending a login token anywhere but the device the page named on the Mac's own network,
leaking data through the login page report, a taught page's web view reaching anything but the internet and the
cafe's own network or recording something typed, and updates that could be replaced in transit.
