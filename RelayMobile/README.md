# Relay for iPhone

A remote for Relay on the Mac. Cards, Claude sessions and connectors all stay on the Mac; the phone mirrors
the cards, streams replies, answers permission prompts, sends messages and starts new cards.

- **Mac side:** `Relay/Sources/Relay/Remote.swift`, a WebSocket server on port 7788 advertised over Bonjour as
  `_relay._tcp`. The phone must present the token in `~/Library/Application Support/Relay/remote-token`.
- **Pairing:** on the Mac choose **Relay › Pair iPhone…** and scan the QR code with the iPhone Camera.
  It opens `relay://pair?host=…&port=7788&token=…`, and the phone keeps that in its Keychain.
- **Away from home (5G):** install Tailscale on the Mac and the iPhone and sign both in to the same account, then pair
  (again). The pairing code then carries the Mac's Tailscale name as a second address; the phone tries home Wi-Fi
  first and Tailscale after 5 seconds. The Mac has to be awake with Relay open.

## Build

```bash
brew install xcodegen
xcodegen generate
open RelayMobile.xcodeproj
```

`RELAY_DEMO=1` in the scheme's environment starts with sample cards; so does **Try it with sample cards** on the
first screen.

## TestFlight

1. Join the Apple Developer Program (paid) with the Apple ID that owns your team.
2. In App Store Connect, create an app: platform iOS, name Relay (or any free name), bundle ID `org.openrelay.relay.mobile`.
3. Run `./testflight.sh`. It archives, signs automatically and uploads.
4. In App Store Connect › TestFlight, add yourself as an internal tester. Internal builds need no review.
