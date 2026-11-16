<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Smolder icon">
</p>

<h1 align="center">Smolder</h1>

<p align="center"><b>Catch your Mac smoldering while nobody is watching.</b></p>

<p align="center">
  <a href="https://github.com/penntiao/smolder/actions/workflows/ci.yml"><img src="https://github.com/penntiao/smolder/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-black" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
</p>

<p align="center"><a href="README.zh-CN.md">简体中文</a></p>

---

Smolder is a small menu bar app for Macs that run all the time with nobody looking at them — a Mac mini
on a shelf as a home server, a MacBook with its lid closed, a build box, an always-on AI agent machine. It
learns what *normal* looks like on your Mac and messages your phone when something is actually wrong.

It was born from a real incident: a background daemon got stuck in a retry loop and burned a full CPU core
for **eight hours** on a lid-closed MacBook Air. Nobody noticed. A temperature alarm would not have helped
either — on that day the battery never got hotter than 30.6 °C, while an ordinary half-hour of heavy work
the week before had reached 33.5 °C. **A fixed temperature threshold either misses the fault or cries wolf.**

So Smolder does not ask *"is it hot?"*. It asks *"is it hotter than what it is doing explains?"* and
*"is something doing work it never does?"*

<p align="center">
  <img src="docs/images/panel-light.png" width="340" alt="Smolder menu bar panel">
</p>

## What it watches

| Alert | Fires when | Why it is not a fixed threshold |
|---|---|---|
| **Runaway program** | A program uses far more CPU than *its own* usual peak (≥ 0.5 cores and ≥ 1.5× its 14-day peak) through most of 30 minutes, not just on average | A compiler or AI agent that is busy every day is not flagged; a daemon that normally idles and suddenly burns a core is |
| **Busy in the background** | With every screen off, the *quietest* moments of the last two hours draw ≥ 1.5 W more than usual | Real work raises the power *peaks*; something that never stops raises the *floor*. A lit screen raises it too, so this is not judged while the Mac is in use |
| **Hotter than the load explains** | The chip runs ≥ 3 °C (or 4 residual MADs) above what the current power draw (system and P-core cluster) predicts, for 20 minutes, after correcting for the room over the last few hours | A learned power → temperature model: heavy work that runs hot is expected, and so is a warm afternoon; a stopped fan or a blocked vent is not |
| **Hard limits** | macOS throttles for 10 minutes, critical thermal pressure, or (on a Mac with a battery) battery ≥ 35 °C | Never learned, never adapted — the backstop for anything the baselines could absorb |

Each alert is one notification when it starts and one when it resolves, never a stream. Every message says
what was measured, what was expected and who is likely behind it:

```
🟠 appstoreagent is running away
Using 0.98 cores on average for 30 min
Usually close to idle
PID 4127 · /System/Library/PrivateFrameworks/…/appstoreagent
```

How the models work, and the research behind them, is in [docs/how-it-works.md](docs/how-it-works.md).

## Any Apple Silicon Mac

Smolder reads what the hardware has and adapts to it; *Settings → Detection → This Mac* shows what it found.

| | MacBook Air | MacBook Pro | Mac mini · Mac Studio |
|---|---|---|---|
| Chip, SSD temperature, power | ✓ | ✓ | ✓ |
| Battery temperature and its limit | ✓ | ✓ | — |
| Room estimated from the battery for the drift check | ✓ | ✓ | — (a hotter room looks like worse cooling) |
| Lid open or closed (compared separately) | ✓ | ✓ | — |
| Fan speed | — (fanless) | ✓ | ✓ |

It is used every day on a MacBook Air (M4). Mac mini and Mac Studio support is new: if you run one, the output
of `--probe` (see below) helps.

## Notifications

- **macOS notifications** — for when someone is at the Mac.
- **Telegram** — alerts to your chat, and the bot answers `/status` with live temperatures, load and the
  busiest programs. *Settings → Notifications → Detect* finds your chat ID for you.
- **Webhook** — POSTs JSON for every event (and, optionally, heartbeats).
- **Custom command** — runs anything you like with the same JSON on stdin; relay to your own server over SSH,
  pipe to `ntfy`, write to a log.
- **Dead man's switch** — Smolder cannot report its own death. Send heartbeats to healthchecks.io,
  Uptime Kuma or your own server and let *that* alert when they stop.

Check every destination from the terminal with `/Applications/Smolder.app/Contents/MacOS/Smolder --test-notify`.
Payloads and recipes: [docs/integrations.md](docs/integrations.md).

## Install

Requires an Apple Silicon Mac on macOS 14 Sonoma or later.

**Homebrew**

```bash
brew install --cask penntiao/tap/smolder
```

**Download** the zip from [Releases](https://github.com/penntiao/smolder/releases), unzip, move
`Smolder.app` to Applications, then right-click → Open the first time.

**From source** (Command Line Tools are enough, no Xcode needed)

```bash
git clone https://github.com/penntiao/smolder.git
cd smolder
scripts/build-app.sh --install
```

> [!NOTE]
> Smolder is ad-hoc signed, not notarized — that needs a paid Apple Developer account. The Homebrew cask
> clears the quarantine flag after installing so macOS lets it start. If you would rather not trust a
> binary, build it from source: it is about 3,300 lines of Swift.

## Set up in five minutes

1. Open Smolder (a flame appears in the menu bar), then *Settings → General* → turn on
   **Start at login and restart after a crash**.
2. **Telegram**: in Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot` and copy the token
   it gives you. Paste it in *Settings → Notifications → Telegram*, send your new bot any message, then press
   **Detect**. Smolder now messages you, and the bot answers `/status`.
3. **Keep the Mac awake.** A Mac that sleeps is not being watched.
   - Mac mini, Mac Studio: *System Settings → Energy* → turn on
     **Prevent automatic sleeping when the display is off**.
   - MacBook with the lid closed: macOS sleeps a closed MacBook unless an external display is attached.
     Keep it on power and run `sudo pmset -a disablesleep 1` (undo with `0`), or use an app such as
     Amphetamine.
4. Optional: a dead man's switch (*Settings → Notifications → Dead man's switch*), so you also hear about it
   when the Mac itself goes silent.

For the first 72 hours Smolder learns what is normal on this Mac; only conservative fixed rules apply until then.

## Privacy and how it reads sensors

- Everything stays on your Mac unless you configure a destination. No telemetry, no analytics, no updates
  phoning home.
- No root, no helper tool, no kernel extension. Chip temperatures come from the `IOHIDEventSystem`
  sensors, power from the SMC, per-program CPU from `/bin/ps`. These are private interfaces, so a future
  macOS could change them; `Smolder.app/Contents/MacOS/Smolder --probe` prints what your Mac exposes.
- Data lives in `~/Library/Application Support/Smolder/`: a SQLite history (90 days), the learned model,
  and `secrets.json` (mode 0600) for tokens. Tokens are not in the Keychain because an ad-hoc signed app
  would trigger a Keychain prompt after every update — and nobody is there to click it on an unattended Mac.

## Limitations

- Apple Silicon only. Intel Macs expose different sensors.
- No ambient temperature sensor. Smolder estimates the room from the last few hours (capped at ±4 °C) so a
  warm afternoon is not reported as a cooling problem, but a slow fault building over many hours can be
  absorbed the same way, and a hot room beyond the cap still looks like worse cooling. The weekly drift
  check measures against the room as estimated from the battery while the Mac idles; a Mac without a battery
  (Mac mini, Mac Studio) has no such estimate there.
- The drift check can only judge cooling under load, on minutes of one lid state. A Mac that is almost always
  idle may go weeks without enough busy minutes to be judged.
- Fan speed is shown and recorded but not judged on its own; a fan that stops shows up as the chip running
  hotter than its load explains.
- The first 72 hours are a learning period; until then only conservative fixed rules apply.

## Contributing

Issues and pull requests are welcome. Please include the output of `--probe` and your Mac model when
reporting sensor problems. `swift test` runs the detection scenarios (it needs Xcode; the app itself builds
with the Command Line Tools alone).

## License

[MIT](LICENSE)
