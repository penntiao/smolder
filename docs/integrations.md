# Integrations

Webhook and custom-command destinations receive the same JSON envelope.

## Event

Sent once when an incident opens, again if it escalates, and once when it resolves (`kind: "recovered"`,
same `incidentID`).

```json
{
  "type": "event",
  "payload": {
    "id": "5D0C2A8E-…",
    "incidentID": "9F1B…",
    "kind": "runawayProcess",
    "severity": "warning",
    "title": "appstoreagent is running away",
    "lines": [
      "Using 0.98 cores on average for 30 min",
      "Usually close to idle",
      "PID 4127 · /System/Library/PrivateFrameworks/AppStoreDaemon.framework/Support/appstoreagent"
    ],
    "host": "MacBook Air",
    "startedAt": "2026-10-01T01:56:00Z",
    "createdAt": "2026-10-01T02:26:00Z"
  }
}
```

`kind` is one of `runawayProcess`, `thermalAnomaly`, `thermalPressure`, `hardLimit`, `recovered`, `test`.
`severity` is `info`, `warning` or `critical`. `title` and `lines` are localized and ready to display.
`id` is unique per message; use it to de-duplicate, since Smolder retries until delivery succeeds.

## Heartbeat

Sent every 60 seconds by default when *Send heartbeats* is on. Turn *Send alerts* off on a destination
that should only receive heartbeats.

```json
{
  "type": "heartbeat",
  "payload": {
    "host": "MacBook Air",
    "sentAt": "2026-10-04T03:12:00Z",
    "bootTime": "2026-09-30T19:05:11Z",
    "appVersion": "0.1.0",
    "status": {
      "dieMax": 44.8, "expectedDie": 41.2, "ssd": 33, "battery": 25.4,
      "power": 1.2, "cpuCores": 0.6, "thermalState": 0, "learning": false,
      "openIncidents": [],
      "topProcesses": [{ "pid": 24755, "name": "claude", "path": "/…/claude", "cores": 0.31 }],
      "pendingDeliveries": 0,
      "deliveryErrors": {}
    }
  }
}
```

A changed `bootTime` means the Mac restarted. A non-zero `pendingDeliveries` with `deliveryErrors` that
persist means alerts are not getting out (for example Telegram is unreachable) — worth alerting on from
the receiving side.

## Delivery guarantees

Events go through a persistent outbox (`outbox.json`). Each destination is tracked separately and retried
with exponential backoff (15 s up to 1 h) across restarts, for up to 7 days. A webhook must answer 2xx; a
command must exit 0. Heartbeats are fire-and-forget: a missed heartbeat is what a dead man's switch is for.

## Recipes

### Dead man's switch with healthchecks.io

Create a check with a period of 5 minutes, paste its ping URL into *Dead man's switch → Ping a URL on every
heartbeat*. If the Mac dies, sleeps or loses its network, healthchecks.io alerts you.

### Relay to your own server over SSH

Useful when you already run alerting on a server. On the server, create a user whose key can only run one
command:

```bash
sudo useradd --system --create-home --shell /bin/sh smolder
sudo -u smolder mkdir -m 700 /home/smolder/.ssh
# one line in /home/smolder/.ssh/authorized_keys:
#   restrict,command="/usr/local/bin/smolder-ingest" ssh-ed25519 AAAA… smolder@mac
```

`/usr/local/bin/smolder-ingest` receives the envelope on stdin, for example:

```bash
#!/bin/sh
# Keep the latest heartbeat; hand events to whatever sends your alerts.
set -e
payload="$(cat)"
case "$payload" in
  *'"type":"heartbeat"'*) printf '%s' "$payload" > /var/lib/smolder/last-heartbeat.json ;;
  *) printf '%s' "$payload" | /usr/local/bin/your-alert-sender ;;
esac
```

A timer on the server can then alert when `last-heartbeat.json` is older than a few minutes.

On the Mac, generate a key just for this and configure *Custom command*:

```
Executable:  /usr/bin/ssh
Arguments:   -i
             /Users/you/.ssh/smolder_relay
             -o
             BatchMode=yes
             -o
             ConnectTimeout=15
             smolder@your-server
```

### ntfy

```
Executable:  /usr/bin/curl
Arguments:   -fsS
             -H
             Title: Smolder
             --data-binary
             @-
             https://ntfy.sh/your-topic
```

This posts the raw JSON; put a small script in between if you want only the title and lines.
