# Changelog

## 0.3.1

- Each minute now records which programs kept a screen awake, and for how many seconds (new `screen_holders`
  table; `--probe` prints them too). On a closed Mac a lit screen is usually a remote-desktop session, so this
  says whose lit minutes they were — a video, a presentation, a remote session. Recorded only; no detector
  uses it.

## 0.3.0

- The long-term cooling check now learns, week by week, instead of comparing against a reference frozen once.
  Each finished week gives one number — its busy-minute warming over what the reference predicts — kept for
  good. From them Smolder learns the usual level and how much a usual week strays. Two weeks in a row clearly
  better (a stand, a cooler spot) become the new usual level, with a message saying so; nothing has to be
  reset. A week clearly worse is reported every week until you accept it with `/accept` (Telegram) or
  *Settings → Detection → Accept as the new normal*; worse is never learned on its own, and more weeks refine
  the level only downward, so a slow fault cannot creep in. The alert line is learned from how much each usual
  week differs from the one before: it starts at +20 % and narrows to as little as +8 %.
- `/status` and *Settings → Detection* show where the cooling check stands.
- The first usual level is the reference measured against its own window the same way, not an assumed 1.

## 0.2.0

- Any Apple Silicon Mac, not only a MacBook with its lid closed. At launch Smolder reads what the hardware
  has — a lid, a battery, fans, the model name — and shows it in *Settings → Detection → This Mac* and in
  `--probe`. Where there is no battery (Mac mini, Mac Studio) the battery tile, its hard limit and the
  learning-period note about it are gone; where there are fans the panel and `/status` show the fastest one's
  speed, each minute records it (new `fan_rpm` column, `fanRPM` in heartbeats), and a heat alert says to check
  that the fan spins. Fan speed is not a thermal-model input: a stopped fan would then explain its own heat.
- `/status` leaves out readings the Mac does not have instead of showing them as "–".
- New tagline and README: Mac minis on a shelf and closed MacBooks alike, a table of what each kind of Mac
  gets, and a five-minute setup (Telegram bot, keeping the Mac awake). Mac mini and Mac Studio support has
  not yet been tried on real hardware; please send `--probe` output.

## 0.1.9

- Fix: "Cooling has drifted from its reference" kept firing every week though cooling had not changed. Two
  causes, both changes in how the Mac was used. The reference's busy minutes were mostly lid-open desk work,
  later ones lid-closed remote work, which runs the die hotter at the same watts; and the check compared
  fitted coefficients, so a mostly idle fortnight, whose watts term is set by its idle minutes, read as 65 %
  worse cooling. Each minute now records whether the lid was closed (`AppleClamshellState`, no root; new
  `lid_closed` column, also in `--probe`). Drift fits keep to minutes settled for an hour in one lid state,
  and the check measures the window's busy minutes (≥ 2 W above its median power) against what the reference
  predicts for those very inputs: more than 20 % above is drift; fewer than 180 busy minutes are not judged.
  The idle-level check is unchanged. On the same history the old measure moved +26 % to +81 %, the new one
  1.01–1.22 with the lid states still mixed.
- A reference saved by an earlier version mixed both lid states: on a Mac with a lid it is dropped, and a new
  one is frozen once a window has a week of minutes in one lid state and at least 180 busy minutes. Until then
  the drift check does not run. On a Mac without a lid the old reference is kept.

## 0.1.8

- Fix: when a room-referenced fit could not be made (too few quiet minutes in the window), the drift check fell
  back to the ordinary fit and, the kinds differing, dropped the room-referenced reference. It now skips that
  check and keeps the reference.

## 0.1.7

- Fix: "Cooling has drifted from its reference" fired because the room had cooled. A week of use at about
  24 °C followed by a week idle at about 19 °C made the fit on the die alone read 20 % more °C per watt
  (1.31 → 1.58): the warm days were the busy ones. On a Mac with a battery, the drift check now compares fits
  of the die's rise over the room, with the room taken from the battery at the last quiet minute (both
  filtered powers ≤ 1 W) and held through busy stretches. On the same history they moved 13 %. A reference
  saved by an earlier version is refitted this way on its own window; the idle limit for these fits is
  3 °C over the room. The live "hotter than the load explains" judgement is unchanged.

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
