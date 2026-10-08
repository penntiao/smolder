# Changelog

## 0.1.6

- Fix: a short burst was reported as a runaway program. The rule judged only the 30-minute average, so ten
  minutes at 1.4 cores read as "0.54 cores on average for 30 min" — iCloud's `fileproviderd` syncing a 5 GB
  copy into Documents, which stopped by itself. A program must now also be over the line in 80 % of the
  window's minutes. One that burns in pulses rather than steadily is flagged once 60 minutes average above
  the line. Nothing the new rule flags would have gone unflagged before.

## 0.1.5

- Each minute records the P-core cluster's power (SMC `PP0b`, no root; new `cpu_power` column), and
  `--probe` prints it.
- The thermal model can use it: once 12 hours of minutes carry it, a fit with the P-core power term is
  compared with one without on the same minutes and kept only if it cuts the tail error (95th percentile)
  by 10 % without widening the median. Busy cores cannot tell a build at the top clock from light work at a
  low one; this is what made long builds read as a cooling problem.

## 0.1.4

- Fix: "Running hotter than the load explains" fired on warm afternoons. The model has no ambient term and the
  room swings more than the 3 °C band (idle residual −2.8 to +2.7 °C over a day on the author's Mac), so a
  warm room plus half an hour of use read as a cooling problem. The residual is now judged against a room
  offset — the median residual over the last 6 hours, ending one sustain period ago — capped at ±4 °C and
  never fed by minutes inside an incident. Settings: `thermalAmbientEnabled`, `thermalAmbientHours`,
  `thermalAmbientMaxOffset`.
- The alert says how much of the expected temperature is room correction.

## 0.1.3

- "Running hotter than the load explains" is less easily fooled by ordinary heavy use. The thermal model now
  adds a 60-minute power term (heat soaking into a fanless chassis) and a CPU term (at the same system watts,
  CPU work heats the die more than a lit screen or video). On real data this cut the residual spread by a
  third and removed a bias of ±2.5 °C that tracked CPU share.
- Fits saved by 0.1.x still load and are replaced by the new model at the next start; a drift reference
  from the old model is reset rather than compared.

## 0.1.2

- Fix: "Busy in the background" fired whenever someone used the Mac for two hours — a lit screen alone keeps
  every quiet moment several watts above a lid-closed baseline. The idle power floor now counts only minutes
  with every screen off, for both the window and the baseline, and is not judged while the Mac is in use.
  A floor incident that cannot be judged stays open instead of being reported as resolved.
- Each minute in `history.sqlite` records whether a screen was lit (`screen_on`); `--probe` prints it.

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
