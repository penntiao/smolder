# How Smolder decides something is wrong

Smolder samples sensors every 10 seconds and per-program CPU time every 30 seconds, aggregates them into
one row per minute, and evaluates its detectors once a minute.

## Why not a temperature threshold

The chip temperature of a fanless Apple Silicon Mac is mostly a function of power draw: macOS clamps
sustained power (a 13" M4 MacBook Air settles around 8 W under load) and temperature follows. A threshold
on temperature therefore measures *how much work the Mac is doing*, which is exactly the thing that changes
from month to month. Tuned low, it fires on every compile; tuned high, it misses a stuck daemon burning
a single core, which barely moves the temperature.

Baselines that learn the temperature itself (rolling means, seasonal models, clustering) have a second
problem: they learn a slow fault as the new normal. Datadog, Elastic and Netdata all document this in their
own anomaly detection.

Smolder splits the question into three that stay stable when the workload changes.

## 1. Is the chip hotter than its power draw explains?

```
expected die temperature = base + R × P̃ + Rslow × P̃slow + k × C̃
```

`P̃` is the system power passed through a first-order low-pass filter with time constant `τ`, mimicking the
chip's thermal inertia. `P̃slow` is the same power through a 60-minute filter: a fanless Mac keeps warming
for an hour of sustained work as heat soaks into the chassis, long after the chip itself has settled. `C̃` is
CPU usage in cores through the fast filter. System power includes the display and the rest of the board, so
at the same total watts a CPU-heavy load puts more of them into the die than a lit screen or video does; the
CPU term accounts for that.

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

A program is flagged when its 30-minute average exceeds `max(0.5 cores, 1.5 × usual peak)` and it was
present for at least 80 % of that window. A daemon that normally idles has a usual peak near zero, so a
stuck loop at one core is flagged after 30 minutes. A program that is busy every day is judged against its
own busy days.

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
- The first full-window thermal fit is frozen as a reference. If later fits drift more than 20 % in
  steady-state resistance (`R + Rslow`) or 8 °C in `base`, Smolder tells you once a week instead of silently accepting it. (It cannot tell a
  hotter room from worse cooling — there is no ambient sensor — and says so.)
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
