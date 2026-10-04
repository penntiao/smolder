# Changelog

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
