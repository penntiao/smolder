# Changelog

## 0.1.1

- Fix: macOS notifications without permission are skipped instead of holding events in the outbox.
- Fix: on a lid-closed Mac, App Nap throttled Smolder's timers by many minutes, so samples went
  missing and heartbeats stopped — which a dead man's switch reports as the Mac being offline.
  Smolder now holds a user-initiated activity (system sleep still allowed) and sets
  `NSAppSleepDisabled`.
- Opening Smolder by hand (or Homebrew reopening it after an upgrade) while the LaunchAgent is installed hands over to the supervised copy, so it stays crash-restarted.
- `Smolder --test-notify` sends a test message to every configured destination and prints each result.

## 0.1.0

First release.

- Menu bar app for Apple Silicon Macs: chip, SSD and battery temperature, whole-system power, CPU load and thermal pressure, read without root.
- Three kinds of alerts, each explained in one line:
  - **Runaway program** — a program far above its own usual CPU peak for 30 minutes, plus a whole-machine "idle power floor" check.
  - **Running hotter than the load explains** — a learned power → temperature model; heavy work that runs hot is expected and never flagged.
  - **Hard limits** — macOS throttling for 10 minutes, or a battery above 35 °C. These never adapt.
- 72-hour learning period with conservative fixed rules; incidents are never learned as normal.
- Notifications: macOS, Telegram (with `/status`), webhook, custom command, heartbeat ping for a dead man's switch.
- English and Simplified Chinese.
