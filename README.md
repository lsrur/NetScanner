# NetScanner

Native macOS app (SwiftUI, macOS 15+) for discovering hosts on the local network, pinging them with aggregate statistics and scanning TCP ports. It needs no root and runs in the App Sandbox.

## Build

```sh
xcodegen generate
open NetScanner.xcodeproj        # or:
xcodebuild -scheme NetScanner -destination 'platform=macOS' test
```

`scripts/update-oui.sh` and `scripts/update-services.sh` regenerate the vendor and service tables in `NetScanner/Resources/`.

Debug builds accept `NETSCANNER_AUTOSCAN=1` (scan all interfaces on launch) and `NETSCANNER_SELECT=<ip>` (select that host when the scan ends), which is handy for screenshots.

## Platform notes

- **Unprivileged ping:** uses a `SOCK_DGRAM` + `IPPROTO_ICMP` socket. Replies include the IP header, and the receive buffer is raised to 1 MB because the default ~8 KB drops replies during a scan.
- **MAC addresses:** inside the sandbox (with Local Network access) the routing sysctl returns real neighbor MACs, while a spawned `arp`/`ndp` only sees redacted ones (`02:00:00:00:00:00`). Outside the sandbox it is the other way around, so both are tried.
- **Host names:** Bonjour (multicast reverse lookup), NetBIOS node status and the router's DNS are queried in parallel.
- **Local Network:** macOS asks for permission the first time. If it is denied, scans find nothing and the app shows a banner linking to System Settings.
- **Inspector:** a classic `HSplitView` instead of `.inspector`, because on macOS 26 the inspector floats over the content and wide tables scroll underneath it.
