# How Smolder decides something is wrong

Smolder samples sensors every 10 seconds and per-program CPU time every 30 seconds, aggregates them into
one row per minute, and evaluates its detectors once a minute.

## What kind of Mac

At launch Smolder reads what the hardware has, without root: a lid (`AppleClamshellState` on `IOPMrootDomain`,
which Apple's power-management header documents as absent on hardware without one), an internal battery
(`IOPSCopyPowerSourcesInfo`), the number of fans (SMC `FNum`, absent on a fanless MacBook Air) and the model name
(the device tree's `product-name`). The lid decides whether the drift check compares lid states separately;
the battery gives the room estimate and its own hard limit; fans are shown (SMC `F<n>Ac`) and recorded, and a
heat alert on a Mac with fans says to check them. Fan speed is deliberately not an input to the thermal model:
a fan that stopped would then explain its own heat.

### Screens and who lit them

Each minute records three things about screens, the same way on every Mac:

- `builtin_screen`: whether the Mac's own panel was lit (MacBook, iMac). A MacBook's panel can only be lit with
  the lid open. On a Mac without one (Mac mini, Mac Studio) the column is empty, not "off".
- `other_screens`: the most other screens lit at once. This counts anything macOS drives as a display — a
  monitor, an HDMI dummy plug, or a virtual display that a remote-desktop app creates when no screen is lit
  (UU Remote does this on a closed MacBook and on a headless Mac mini). Smolder cannot tell these apart.
- `screen_holders` (its own table): for each program that held a display-sleep assertion, how many seconds of
  the minute it held it — a video, a presentation, a remote session (UU Remote's is `UURemoteServer`).

Read together:

| Mac | Someone at the Mac | A remote session |
|---|---|---|
| MacBook, lid open | `builtin_screen` = 1 | the remote app in `screen_holders` |
| MacBook, lid closed | — (cannot be) | `other_screens` ≥ 1 and the remote app in `screen_holders` |
| Mac mini, no monitor | — (nothing to look at) | `other_screens` ≥ 1 (virtual display) and the remote app in `screen_holders` |
| Mac mini with a monitor or dummy plug | `other_screens` ≥ 1 and no remote app in `screen_holders` | the remote app in `screen_holders` |

On a Mac mini with a monitor, a lit screen alone does not say who is using it; only `screen_holders` does.
`screen_on` (any screen lit) stays as before and is what the idle-power check uses.

## Why not a temperature threshold

The chip temperature of an Apple Silicon Mac is mostly a function of power draw. On a fanless MacBook Air
macOS clamps sustained power (a 13" M4 settles around 8 W under load) and temperature follows; on a Mac with
fans (MacBook Pro, Mac mini, Mac Studio) the fans spin up with the heat, which bends the curve but keeps it a
function of power. A threshold on temperature therefore measures *how much work the Mac is doing*, which is
exactly the thing that changes from month to month. Tuned low, it fires on every compile; tuned high, it misses a stuck daemon burning
a single core, which barely moves the temperature.

Baselines that learn the temperature itself (rolling means, seasonal models, clustering) have a second
problem: they learn a slow fault as the new normal. Datadog, Elastic and Netdata all document this in their
own anomaly detection.

Smolder splits the question into three that stay stable when the workload changes.

## 1. Is the chip hotter than its power draw explains?

```
expected die temperature = base + R × P̃ + Rslow × P̃slow + k × C̃ + q × Q̃
```

`P̃` is the system power passed through a first-order low-pass filter with time constant `τ`, mimicking the
chip's thermal inertia. `P̃slow` is the same power through a 60-minute filter: a fanless Mac keeps warming
for an hour of sustained work as heat soaks into the chassis, long after the chip itself has settled. `C̃` is
CPU usage in cores through the fast filter. System power includes the display and the rest of the board, so
at the same total watts a CPU-heavy load puts more of them into the die than a lit screen or video does; the
CPU term accounts for that.

`Q̃` is the P-core cluster's own power (SMC key `PP0b`, readable without root), through the fast filter.
Busy cores say nothing about the clock: a build that pins the P-cores at their top frequency draws several
times the watts of light work on the same number of cores. On an M4 `PP0b` tracks `powermetrics` CPU power
within about 5 %, including under a full load where the chip caps its own frequency — something DVFS state
residency (also readable without root) cannot see, since it reports the requested state. The energy
counters in IOReport's *Energy Model* group are only refreshed when a privileged client asks (roughly every
15 minutes, when `powerlogd` does), so they cannot drive a per-minute model.

The `q` term is used only when it earns its place: once at least 12 hours of minutes carry P-core power (a third of what the first fit needs),
the model is fitted on those minutes both with and without it, and the version with it is kept only if it
cuts the 95th percentile of the absolute error by at least 10 % without widening the median error.
Otherwise — or on a Mac without that sensor — the term is left out. The median alone would not do: the
minutes this term is for (builds at the top clock) are a few percent of a day.

`base`, `R`, `Rslow`, `k` and `τ` are fitted once a day from the last 14 days by least squares, after
dropping points more than 3 robust standard deviations out (one refit). Coefficients are kept non-negative
(more load never cools the chip); an input whose coefficient comes out negative had no usable range in the
data and is left out. `τ` is chosen from 1, 2, 3, 5, 8 and 13 minutes by smallest residual spread.

On the Mac this was built on, adding the slow and CPU terms cut the residual spread from 1.15 °C to 0.76 °C
and explained a day of mixed use — idle, video, hours of work — within ±2 °C. The power-only model's error
swung with CPU share: about 2.4 °C too warm on light-CPU loads and 2.6 °C too cool on CPU-heavy ones at the
same watts.

This is the standard first-order thermal model used for mobile SoCs, server rooms and battery packs, with
residual-based fault detection on top. Because it models physics rather than workload, a new kind of
work does not need relearning.

### The room

The model has no ambient term, and the room moves more than the alert band: on the Mac this was built on,
the idle residual swung from −2.8 °C at dawn to +2.7 °C on a warm afternoon. Judged against the bare model,
every warm afternoon plus a little use read as a cooling problem.

So the residual is judged relative to a **room offset**: the median residual over the last 6 hours, ending
20 minutes ago (one sustain period, so the minutes being judged are not part of it). It needs at least a
quarter of that window, otherwise the offset is 0. Three things keep it from swallowing a real fault:

- minutes inside an open or past incident never enter it, so once an anomaly is flagged the offset stays
  where it was before;
- it is capped at ±4 °C, so a fault that was already there when Smolder started still shows;
- the fixed limits (thermal pressure, battery 35 °C) do not use it.

A slow fault that builds up over many hours without ever crossing the band can be absorbed; that is the
trade-off for not alarming every afternoon.

### When it alerts

An alert needs:

- a residual minus the room offset above `max(3 °C, 4 × MAD)`, where MAD is the residual spread on the fit data,
- in at least 80 % of the last 20 minutes,
- at a power level the model has actually seen (≤ 1.25 × the 95th percentile of the fit data). Beyond
  that the linear model is extrapolating, so Smolder does not judge.

Heavy load running hot is predicted, so it is never flagged.

## 2. Is a program doing work it never does?

Every 10 minutes Smolder stores each program's average CPU use (by executable path). A program's
*usual peak* is the 99th percentile of those buckets over 14 days, excluding buckets recorded while that
program was part of an incident.

A program is flagged when its 30-minute average exceeds `max(0.5 cores, 1.5 × usual peak)`, it was
present for at least 80 % of that window, and it was over that line in at least 80 % of the window's
minutes. A daemon that normally idles has a usual peak near zero, so a stuck loop at one core is flagged
within 30 minutes. A program that is busy every day is judged against its own busy days.

The per-minute check is there because an average hides its shape: ten minutes at 1.4 cores averages 0.5
over half an hour. That is what iCloud's `fileproviderd` did after a 5 GB copy into a synced Documents
folder, and it stopped on its own. A program that burns in pulses rather than steadily — two minutes busy,
three idle — is still flagged once twice the window (60 minutes) averages above the line.

Independently, the **idle power floor** — the 10th percentile of the last 120 minutes of power — is compared
with its 14-day median. Real work raises the peaks; something that never stops raises the quiet moments
too. This catches long-running burners that no single program threshold would, and it is suppressed while a
runaway program is already being reported.

A lit screen raises the quiet moments as well: on the MacBook Air Smolder was built on, the 10th percentile
is 0.35 W with every screen off and 2.2 W with the screen on. So both the window and the baseline use only
minutes when every screen was off. While someone is using the Mac — fewer than 90 % screen-off minutes in the
window — the floor is not judged at all, and an open floor incident neither recovers nor escalates
meanwhile: a minute that could not be judged is not a normal minute.

## 3. Hard limits

These never adapt:

- macOS thermal pressure *Heavy* (the level where throttling starts) for 10 minutes, or *Trapping* at
  all. Smolder reads the fine-grained `com.apple.system.thermalpressurelevel` notify key; the public
  `ProcessInfo.thermalState` merges Moderate and Heavy.
- Battery above 35 °C for 5 minutes. Apple's guidance is an ambient range of 10–35 °C; sustained heat
  above that shortens battery life.

## Guarding against learning a fault

- Time ranges of past and open incidents are excluded from every fit and baseline, including the room offset.
- A program's buckets are marked anomalous while it is under an incident.
- A window of the thermal model is frozen as a reference, and every daily refit is checked against it; if
  cooling has drifted, Smolder tells you once a week instead of silently accepting it. What is compared has
  to be alike, or changes in how the Mac was used read as changes in cooling. On the author's Mac each of
  these produced false alarms before it was handled:
  - **The room.** A fit on the die alone puts a changing room into `R` whenever the warm days happen to be
    the busy ones (a week of use at about 24 °C, then a week idle as the room cooled to about 19 °C, read as
    20 % worse cooling). Where the Mac has a battery, the drift check fits the die's rise *over the room*
    (model 2). The room is the battery temperature at the last quiet minute — both filtered powers at most
    1 W, so the chassis has cooled — held through busy stretches and dropped after 24 hours without a quiet
    minute. A fanless Mac's battery sits within about a degree of the room when idle; a constant offset ends
    up in `base`, the idle rise over the room. Without a battery the check uses the ordinary fit and says it
    cannot tell a hotter room from worse cooling.
  - **The lid.** A closed lid covers the keyboard deck, so the same watts run the die hotter than with the
    lid open. The reference was frozen during a week of mostly desk work with the lid open, later work was
    mostly remote with it closed, and the check read that as worse cooling (+26 % to +53 %). Each minute records whether
    the lid was closed (`AppleClamshellState`, no root), and drift fits keep to one lid state: whichever
    most minutes were in when the reference was frozen. A minute counts once its lid state has held for an
    hour (the chassis' slow time constant) without a gap of more than five minutes.
  - **The load.** Comparing fitted coefficients (`R + Rslow`) fails whenever two windows worked
    differently: in a mostly idle window the watts term is set by the idle minutes, which warm a little
    more per watt than busy ones, and busy cores and watts trade heat between their two terms (two weeks
    with 95 % of minutes under 1.7 W read as 65 % worse cooling). So the check measures the window's *busy* minutes — smoothed
    power at least 2 W above the window's median, up to the load the reference has seen — with the
    reference as the yardstick: the median warming those minutes show over the reference's idle level,
    against the median the reference predicts for the very same inputs. A window with fewer than 180 busy
    minutes cannot become the reference, and a week with fewer is not judged under load. On the same
    lid-mixed history the coefficients moved +26 % to +81 %; this measure 1.01–1.22.
  - The idle level is judged on every window: the idle rise over the room up more than 3 °C (8 °C on the
    ordinary fit) is drift.

  The reference fit is only the yardstick; what counts as *usual* is learned, week by week
  (`CoolingBaseline`). Each finished week gives one number — that week's busy-minute warming over what the
  yardstick predicts — kept for good, so the history is not bound by the 90 days of minute data. The first
  usual level is the yardstick measured against its own window the same way. From the weeks Smolder learns
  the usual level and how much a usual week strays from it:
  - **Better is learned on its own.** Two judged weeks in a row clearly below the usual level (a stand under
    the Mac, a cooler spot) become the new usual level, and Smolder says so.
  - **Worse is never learned on its own.** A week clearly above it is reported, every week it lasts, until you
    accept it: `/accept` to the Telegram bot, or *Settings → Detection → Accept as the new normal*. Accepting
    also covers a flagged idle rise.
  - **More weeks refine the level, but only downward** from the level last set by the first week, an
    improvement or an acceptance. A fault that creeps up a little each week cannot carry the level with it.
  - **"Clearly" is learned too.** The stray of one week is estimated from how much each usual week differs
    from the usual week before it (half the squared difference), pooled with a prior worth four weeks at
    8 %. A steady creep moves each week only a little, so it does not widen the line it is about to cross;
    the spread of the deviations themselves would, and in testing let a fault rising 2.5 % a week through for
    twelve weeks. The alert line is 2.5 times the stray, starting at +20 % and narrowing as the weeks agree,
    down to +8 %; an improvement must exceed twice the stray, at least 5 %.

  On the author's Mac before lid filtering, four weeks read 1.17, 1.09, 1.09 and 1.16 against a usual level
  of 1.01 measured on the reference window: all within the line, which had narrowed to +17 %. That steady
  +10 % or so is about what working with the lid closed rather than open costs; with both sides kept to the
  closed lid it should go away. If a steady offset like that remains, the line will reach it as it narrows,
  report it once, and an acceptance settles it.

  A reference saved before 0.1.9 mixed both lid states; on a Mac with a lid it is dropped and a new one
  frozen once a window has a week of minutes in one lid state and enough busy minutes, which on a mostly
  idle Mac can take a while. Until then the check does not run. Where there is no lid the old reference is
  kept, and its weeks start being learned from the day 0.3.0 starts. The live judgement keeps the ordinary fit and the room offset above: its band comes from the fit's
  spread, and fitted against the room that spread shrinks enough to make ordinary use read as too hot.
- *Accept as normal* on an incident is an explicit choice: it closes the incident and lets its data be
  learned from.
- Hard limits are the backstop for anything the adaptive parts miss.

## Learning period

For the first 72 hours (configurable) only conservative fixed rules run: a program near a full core
(≥ 0.9) for an hour, plus the hard limits. The thermal model needs at least 36 hours of data before its
first fit.

## Incidents

Findings become incidents with one notification when they start, one if they escalate in severity, and one
when they have been normal for 15 consecutive minutes. A single normal minute does not resolve an incident.

## References

- Bhat, Gumussoy, Ogras — first-order power–temperature dynamics identified on a mobile SoC:
  https://arxiv.org/abs/2003.11081
- Pittino et al. — thermal model identification on production HPC clusters: https://arxiv.org/abs/1810.01865
- Dey, Perez, Moura — residual-based thermal fault diagnosis for battery packs:
  https://ecal.studentorg.berkeley.edu/pubs/Batt_Thermal_Fault_Diag.pdf
- Datadog anomaly monitors (limits of adaptive baselines): https://docs.datadoghq.com/monitors/types/anomaly/
- Elastic — how its machine learning adapts to change:
  https://www.elastic.co/blog/designing-for-change-in-elastic-machine-learning
- Netdata anomaly detection: https://learn.netdata.cloud/docs/netdata-ai/anomaly-detection
- NIST — robust outlier detection with MAD: https://www.itl.nist.gov/div898/handbook/eda/section3/eda35h.htm
- Apple — responding to thermal state changes:
  https://developer.apple.com/library/mac/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html
- Apple — maximizing battery performance: https://www.apple.com/batteries/maximizing-performance/
