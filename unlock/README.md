# Smolder Unlock

**Bring a FileVault Mac back after a restart, from your phone.**

An always-on Mac has one weak spot: after a restart or a power cut it stops at the FileVault password screen.
Nothing on the Mac runs yet — no remote desktop, no VPN, no agent — so it waits until someone walks up to it.

Smolder Unlock is the part that lives *outside* the Mac. One page, behind your own login, shows where the Mac
is on its way back and takes the password in a single field when it is needed. A watcher tells you (Telegram,
optionally e-mail) when the Mac is waiting.

<p align="center"><a href="README.zh-CN.md">简体中文</a> · <a href="AGENTS.md">Runbook for AI agents</a></p>

## How it works

macOS 26 and later can unlock FileVault over SSH: with Remote Login on, a password login at the password
screen unlocks the disk (`man apple_ssh_and_filevault`). Everything here is plumbing around that one fact.

```text
your phone ── https://mac.example.com ── Cloudflare Access (e-mail code, only you)
                                              │ Cloudflare Tunnel (outbound from your server)
                                   your server: unlockd.py  (page + watcher)
                                              │ one SSH login with the password you typed
                                   the Mac's SSH port, reached either
                                     · through a reverse tunnel that a device at home keeps open, or
                                     · directly (a port forward, or a VPN you already have)
```

After the unlock the Mac sits at its login window; log in over the remote desktop you already use.

## What you need

| | |
|---|---|
| The Mac | Apple Silicon, macOS 26+, FileVault on, Remote Login on. |
| A laptop with the lid closed | An external display or an HDMI dummy plug. Without one it goes to sleep seconds after starting up, at the password screen, and nothing can reach it. A Mac mini or Studio needs nothing. |
| A server | Any always-on Linux host with systemd, Python 3.9+ and curl. It makes outbound connections only. |
| A way from the server to the Mac | The Mac cannot dial out while it is locked. Either **a device at home that is always on** (router, Raspberry Pi, NAS) keeps a reverse SSH tunnel to the server, or your home has **a public address with a port forwarded** to the Mac's port 22. If you have neither, this cannot work. |
| Cloudflare | A free account with your domain on it, and Zero Trust enabled once (free plan). |

## Where your password goes

Read this before you decide to use it.

- You type the Mac's login password into the page. It travels over HTTPS to Cloudflare (which terminates TLS
  and could read it), through the tunnel to your server, into the memory of `unlockd.py`, and from there over
  SSH to the Mac. **Cloudflare and your server both see it.** If you do not accept that, do not use this.
- On the server it exists only in the memory of that process and in the environment of one `ssh` child for the
  seconds the login takes. It is never written to disk or to the journal.
- The page is reachable only after a Cloudflare Access login limited to the e-mail addresses you list. The
  server checks the signature of Cloudflare's token on every request as well, so a request that did not come
  through your Access application is refused even from the server's own loopback.
- The server holds one SSH key for the Mac. On the Mac that key is restricted to a forced command that prints
  the clock and Smolder's heartbeat file. It cannot open a shell, forward ports or read anything else.
- Three wrong passwords stop the page for 15 minutes.

## Set up

```bash
brew install penntiao/tap/smolder-unlock       # or clone this repository and use unlock/deploy.py
smolder-unlock init                             # writes config.json in the current directory
# edit config.json
export CLOUDFLARE_API_TOKEN=…                  # permissions below
export TELEGRAM_BOT_TOKEN=…                    # only if you configured notify.telegram
smolder-unlock plan
smolder-unlock apply
```

`apply` runs seven steps — `preflight`, `server`, `link`, `mac`, `cloudflare`, `start`, `verify` — and each one
checks itself. Lines start with `OK`, `FAIL`, `TODO` (something only you can do) or `INFO`. It stops at the first
failure; fix it and rerun the step with `smolder-unlock apply --step NAME`. Every step is safe to run again.

Then do the one test that matters, while you are at home: restart the Mac, wait for the alert, unlock it from
the page.

### config.json

| Key | Meaning |
|---|---|
| `lang` | `"en"` or `"zh"`: language of the alerts. The page follows the browser. |
| `mac.user` | Your macOS short user name. |
| `mac.lan_ip` | The Mac's address in your home network (reverse mode). Give it a fixed address on the router. |
| `server.ssh` | How to reach the server from this Mac: `root@host`, or a user that can `sudo` without a password, or a `Host` from `~/.ssh/config`. |
| `server.install_dir`, `server.listen_port` | Defaults `/opt/smolder-unlock` and `3112` (loopback only). |
| `link.mode` | `"reverse"`: a home device keeps the tunnel; set `mac_port_on_server` / `device_port_on_server` if the defaults `39930` / `39931` are taken. If the device must dial something other than the host in `server.ssh` on port 22 (an alias there, another SSH port, a local proxy), set `server_host` / `server_port`. `"direct"`: set `host` and `port` where the server reaches the Mac's SSH; optionally `check: {"host", "port"}`, an SSH port that answers whenever the path home is up, so the page can tell "home is offline" from "the Mac does not answer". |
| `cloudflare.zone`, `.hostname`, `.emails` | Your domain, the page's hostname under it, and who may log in. |
| `notify.telegram.chat_id` | Where alerts go. The bot token comes from `TELEGRAM_BOT_TOKEN`. |
| `notify.email` | Optional second channel: `{"host", "port", "user", "from", "to"}`, password from `SMTP_PASSWORD`. |

### Cloudflare API token

Create a custom token (My Profile → API Tokens) with:

- Account · Cloudflare Tunnel · Edit
- Account · Access: Apps and Policies · Edit
- Account · Access: Organizations, Identity Providers, and Groups · Edit
- Zone · Zone · Read and Zone · DNS · Edit, limited to your zone

Those five are enough; install and uninstall were run with exactly this token.

The installer creates the Access application first, confirms it has exactly one owner-only policy, and only
then publishes the hostname. Uninstall goes the other way round. The token is used from your Mac and is not
stored anywhere.

### The home device (reverse mode)

`apply` prepares the server and writes a `home-device/` folder with a ready `systemd` unit, an OpenWrt init
script and four lines of instructions. Install it on the always-on device, then continue with
`smolder-unlock apply --step mac`. The device's key can only open two loopback ports on your server.

### Tell "logged in" from "unlocked"

Without Smolder the page knows *locked* and *unlocked*. With [Smolder](../README.md) writing its heartbeat to
a file it also knows whether someone has logged in, and the watcher reports a Mac left at the login window.
In Smolder → Settings → Notifications → Custom command, turn on *Send heartbeats* and use:

```bash
/bin/sh -c 'umask 077; f="$HOME/.local/state/smolder/heartbeat.json"; mkdir -p "${f%/*}"; cat > "$f.tmp" && mv "$f.tmp" "$f"'
```

## What you will see

| The page says | Meaning |
|---|---|
| All good | Logged in and Smolder is reporting. |
| Waiting for the password | At the FileVault screen. Type it. |
| Unlocked · Ready for remote login | Disk unlocked, at the login window. |
| The Mac does not answer | Off, asleep, or off the network. |
| Home is offline | The tunnel from home is down (reverse mode). |

The watcher sends one message when trouble has lasted 10 minutes (3 for "waiting for the password", which never
clears by itself), one when things move forward, one after an hour, one on recovery, and a note when the Mac
restarted and came back before an alert was due.

## Tested, and not

Tested on a MacBook Air M4 (macOS 27.2, Wi-Fi only, lid closed with a dummy plug), a Debian 13 arm64 server,
through a reverse tunnel kept by an OpenWrt 25.12 router: restarts unlocked from a phone after 4 and after 26 minutes at
the password screen; the installer and uninstaller end to end in both link modes, with a scoped API token; the
OpenWrt init script on that router, including reconnecting after the tunnel was killed.

- At the password screen the Mac's display sleeps after 5 minutes and the Mac itself after 20 idle minutes.
  It still wakes for each incoming connection, which is why the page retries up to four times.
- macOS stops talking on the SSH connection once it has unlocked, without closing it. The server therefore
  confirms an unlock by looking at the Mac from the side; expect "Unlocked" a few seconds after you submit.
- The real restarts above were done with the author's earlier private version of the same logic; this packaged
  code has run the installer, the page and the checks, but not yet a real unlock.
- Not tested: the systemd unit for a home device, Intel Macs, a wired-only Mac mini, an overnight wait at the
  password screen, and recovery after a real power cut.

## Remove

```bash
smolder-unlock uninstall
```

Removes the Cloudflare route, DNS record, Access application and tunnel; the services, files and users on the
server; and the key line on the Mac. It tells you what is left to remove on the home device.
