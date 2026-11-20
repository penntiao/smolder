# Runbook for AI agents: deploying Smolder Unlock

You are helping the owner of a Mac set up remote FileVault unlock. Work on **the Mac that is to be unlocked**.
Read `README.md` first, in particular "What you need" and "Where your password goes". The owner must have read
the second one; ask them to confirm before you start.

## Ground rules

- Never ask for, type, store or log the Mac's login password. The owner types it into the web page, once, at
  the end. Nothing in this runbook needs it.
- Secrets reach the installer through environment variables only. Do not write them into `config.json`, shell
  history, notes or commit messages. Ask the owner to `export` them in the terminal you are using, or to paste
  them when you ask; do not echo them back.
- Do not turn on Remote Login, change energy settings, or restart the Mac yourself. Those are the owner's.
  The restart test at the end must happen while the owner is physically near the Mac.
- `apply` changes the server (two system users, two systemd services, optionally an sshd config snippet) and
  the Cloudflare account (one tunnel, one Access application, one DNS record). Show the owner `plan` before
  the first `apply`.
- Every step is idempotent. When a step fails, read its `FAIL` line, fix the cause, rerun that step. Do not edit
  files on the server by hand to get past a check.

## Output contract

Each line of `plan`, `apply`, `verify`, `uninstall` starts with one of:

| Prefix | Meaning | What you do |
|---|---|---|
| `OK` | checked and true | continue |
| `FAIL` | checked and false; the run stops after this step | fix, then `apply --step <name>` |
| `TODO` | needs a person | relay it to the owner in their words, wait, then rerun the step |
| `INFO` | context | relay if relevant |

Exit code 0 means no `FAIL`. Steps are announced as `--- <name>`.

## Procedure

1. **Collect** from the owner: macOS short user name; server SSH target; which link they have (a home device
   that is always on → `reverse`; a public address with a forwarded port → `direct`; neither → stop, this cannot
   work); domain on Cloudflare and the hostname to use; e-mail address(es) allowed to log in; Telegram chat id
   if they want alerts. Find the Mac's LAN address with `ipconfig getifaddr en0` (or `en1`) and recommend a
   fixed address on the router.
2. **Write** `config.json` from `config.example.json` (`smolder-unlock init` copies it). No secrets in it.
3. **Secrets**: the owner creates the Cloudflare token (README, "Cloudflare API token") and exports
   `CLOUDFLARE_API_TOKEN`; and `TELEGRAM_BOT_TOKEN` if alerts are configured.
4. `smolder-unlock plan` → show the owner. Then `smolder-unlock apply`.
5. Expected stops:
   - `preflight` `TODO turn on … Remote Login` → the owner does it in System Settings; rerun `--step preflight`.
   - `preflight` `INFO this is a laptop …` with `Displays seen now: 0` → tell the owner a lid-closed laptop needs
     a display or dummy plug, or the whole thing will not work after a real restart.
   - `link` `TODO set up the tunnel on your home device` (reverse mode, first run) → follow
     `home-device/README.txt` on that device (you may do it over SSH if the owner gives you access), then
     `apply --step mac` and continue with `--step cloudflare`, `--step start`, `--step verify`.
   - `cloudflare` `TODO enable Zero Trust once` → the owner does it in the dashboard; rerun the step.
6. `smolder-unlock verify` must print only `OK` lines and the final `TODO`.
7. **Hand over** to the owner: open the page on the phone, log in with the e-mail code, expect "All good".
   Then, at home, restart the Mac, wait for the alert, unlock from the page, log in over remote desktop.
   Offer `ssh <server> 'journalctl -u smolder-unlock -n 20'` afterwards: the `login:` line shows how long the
   unlock took.

## Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `mac` step: `cannot read this Mac through the link (state: silent)` | reverse tunnel not up, or wrong `mac.lan_ip` | on the server `ss -ltn \| grep 3993`; on the home device, the service log |
| `… (state: link)` | the home device's own SSH is not on `127.0.0.1:22` | start an SSH server there, or it will always read as "home is offline" |
| `… (state: locked)` right after `mac` | `authorized_keys` on the Mac not readable by sshd | `ls -le ~/.ssh`; must be `700` / `600`, owned by the user |
| `… (state: error) Host key verification failed` | the Mac's host key changed, or the port reaches another machine | rerun `--step mac`; if it persists, the forward points at the wrong host |
| `verify`: `https://… is not answering as expected yet` | DNS not propagated, tunnel still connecting | wait a minute, `verify` again; `journalctl -u smolder-unlock-tunnel` on the server |
| page shows "Could not reach it" after a password | the Mac was asleep and did not wake in four tries | try again; a lid-closed laptop without a display will not wake |
| page logs in but says 403 | the visitor's e-mail is not in `cloudflare.emails` | fix the config, `apply --step cloudflare`, `--step start` |

## Undo

`smolder-unlock uninstall` with the same `config.json` and `CLOUDFLARE_API_TOKEN`. It prints what it removed
and one `TODO` for the home device.
