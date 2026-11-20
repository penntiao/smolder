#!/usr/bin/env python3
"""smolder-unlock: bring a FileVault Mac back after a reboot, from anywhere.

Runs on an always-on Linux host that can reach the Mac's SSH port (directly, or through a reverse tunnel
that a device in the Mac's home network keeps open). It does three things:

  * serves one page behind Cloudflare Access: where the Mac is on its way back, and, when the Mac waits at
    the FileVault password screen, one password field. The password is used for a single SSH login, which
    is how macOS 26+ unlocks the disk remotely (see `man apple_ssh_and_filevault`);
  * watches the Mac every two minutes and sends a message when it needs you (Telegram, optionally e-mail);
  * learns how long a real unlock takes, so the page can pace its progress bar by it.

The password lives only in this process's memory and in the environment of the one ssh child it starts.
It is never written to disk or to the journal. Standard library only; Python 3.9+.
"""
import base64
import calendar
import hashlib
import json
import os
import re
import smtplib
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = os.path.dirname(os.path.abspath(__file__))
CONF = json.load(open(os.environ.get("SMOLDER_UNLOCK_CONFIG", os.path.join(BASE, "config.json"))))
STATE_DIR = os.path.join(BASE, "state")
KEY, KNOWN = os.path.join(BASE, "keys", "status"), os.path.join(BASE, "known_hosts")
ASKPASS = os.path.join(BASE, "askpass.sh")

MAC = CONF["mac"]                      # {"user", "host", "port"} as seen from this host
ROUTER = CONF.get("link_check")        # optional {"host", "port"}: an SSH port that proves the tunnel is up
ACCESS = CONF["access"]                # {"team_domain", "aud", "emails": [...]}
SITE = CONF["site"]                    # {"hostname", "listen_port"}
NOTIFY = CONF.get("notify", {})
LANG = CONF.get("lang", "en")

SSH_BASE = ["ssh", "-F", "/dev/null", "-T", "-p", str(MAC["port"]),
            "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" + KNOWN, "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "HostKeyAlias=the-mac", "-o", "ConnectTimeout=12"]
FETCH = SSH_BASE + ["-i", KEY, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey",
                    f"{MAC['user']}@{MAC['host']}"]
LOGIN = ["ssh", "-v"] + SSH_BASE[1:] + ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password,keyboard-interactive",
                                        "-o", "NumberOfPasswordPrompts=1", f"{MAC['user']}@{MAC['host']}", "true"]

STALE = 5 * 60
PROBE_EVERY, PROBE_AFTER_LOGIN, FAST_FOR = 20, 6, 90
TRIES = 4                      # a sleeping Mac wakes for about 10 s per packet: try again rather than ask again
WRONG_LIMIT, WRONG_WINDOW = 3, 15 * 60
CONFIRM_AT = (1.0, 3.0, 6.0, 10.0)   # seconds after the password was handed over
MARK_ASKED = ("Next authentication method: password", "Next authentication method: keyboard-interactive")
EXPECT_DEFAULT = 4.5
WATCH_EVERY, WARN, WARN_LOCKED, ESCALATE = 120, 10 * 60, 3 * 60, 60 * 60
RANK = {"link": 0, "silent": 1, "locked": 2, "error": 2, "up": 3}

TEXT = {
    "en": {"link": ("The way home is down", "Power, network or the tunnel device at home. Nothing can be seen or unlocked until it is back."),
           "silent": ("The Mac does not answer", "Off, asleep, or off the network."),
           "locked": ("The Mac is waiting for its password", "It restarted and sits at the FileVault screen. Open https://{host} and enter the password."),
           "error": ("Cannot read the Mac's status", "{detail}"),
           "up": ("The Mac is unlocked but not logged in", "It sits at the login window (or Smolder is not running). Log in over remote desktop."),
           "ok": ("The Mac is back to normal", ""), "boot": ("The Mac restarted", "It was back before an alert was due."),
           "for": "for {m} min", "still": ", over an hour now"},
    "zh": {"link": ("回家的通道断了", "家里断电、断网，或负责通道的设备没连上。恢复前看不到 Mac，也没法远程解锁。"),
           "silent": ("Mac 没有应答", "关机、睡着，或掉网。"),
           "locked": ("Mac 在等开机密码", "它重启过，停在开机密码界面。打开 https://{host} 输入密码。"),
           "error": ("读不到 Mac 的状态", "{detail}"),
           "up": ("Mac 已解锁，还没登录", "停在登录窗口（或 Smolder 没在运行）。用远程桌面登录。"),
           "ok": ("Mac 恢复正常", ""), "boot": ("Mac 重启过", "中断很短，没到报警的时间。"),
           "for": "已持续 {m} 分钟", "still": "，已超过 1 小时"},
}[LANG if LANG in ("en", "zh") else "en"]

lock = threading.Lock()
state = {"probe": None, "probedAt": 0, "probing": False, "job": None, "fastUntil": 0, "wrong": []}


def log(msg):
    print(msg, flush=True)


def load(name, default):
    try:
        with open(os.path.join(STATE_DIR, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(name, value):
    path = os.path.join(STATE_DIR, name)
    with open(path + ".tmp", "w") as f:
        json.dump(value, f)
    os.replace(path + ".tmp", path)


# ---------------------------------------------------------------- looking at the Mac

def ssh_answers(host, port):
    try:
        with socket.create_connection((host, port), timeout=8) as s:
            s.settimeout(8)
            return s.recv(32).startswith(b"SSH-")
    except OSError:
        return False


def fetch_status():
    """Log in with the status-only key. Its forced command on the Mac prints the Mac's clock and, if Smolder
    writes one, the heartbeat file. Returns ("ok", {...}), ("locked", why) or ("error", why)."""
    try:
        r = subprocess.run(FETCH, capture_output=True, text=True, timeout=40, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "error", "timed out"
    why = (r.stderr.strip().splitlines() or [""])[-1]
    if r.returncode == 255 and "Permission denied" in why:
        return "locked", why          # the key list is on the encrypted disk: refused means not unlocked yet
    if r.returncode != 0:
        return "error", why or f"exit {r.returncode}"
    clock, _, body = r.stdout.partition("\n")
    out = {}
    try:
        p = json.loads(body)["payload"]
        sent = calendar.timegm(time.strptime(p["sentAt"][:19], "%Y-%m-%dT%H:%M:%S"))
        out = {"age": float(clock) - sent, "bootTime": p.get("bootTime")}
    except (ValueError, KeyError, TypeError):
        pass                          # no heartbeat file: we still know the disk is unlocked
    return "ok", out


def probe():
    if ROUTER and not ssh_answers(ROUTER["host"], ROUTER["port"]):
        return {"rung": "link"}
    if not ssh_answers(MAC["host"], MAC["port"]):
        return {"rung": "silent"}
    kind, value = fetch_status()
    if kind != "ok":
        return {"rung": kind, "detail": str(value)[:120]}
    fresh = "age" in value and value["age"] < STALE
    return {"rung": "ok" if fresh else "up", **{k: v for k, v in value.items() if v is not None}}


def do_probe():
    try:
        p = probe()
    except Exception as e:  # noqa: BLE001
        p = {"rung": "error", "detail": type(e).__name__}
    with lock:
        if state["probe"] is None or state["probe"]["rung"] != p["rung"]:
            log(f"probe: {p['rung']}")
        state.update(probe=p, probedAt=time.time(), probing=False)
    return p


def maybe_probe():
    now = time.time()
    with lock:
        every = PROBE_AFTER_LOGIN if now < state["fastUntil"] else PROBE_EVERY
        busy = state["job"] and state["job"]["phase"] == "trying"
        if state["probing"] or busy or now - state["probedAt"] < every:
            return
        state["probing"] = True
    threading.Thread(target=do_probe, daemon=True).start()


# ---------------------------------------------------------------- unlocking

def confirm_unlocked():
    """At the password screen the Mac refuses the status key. Once the disk is unlocked that small sshd is gone
    (the system restarts SSH), so anything but "refused" from a Mac we were just talking to means: unlocked."""
    if not ssh_answers(MAC["host"], MAC["port"]):
        return not ROUTER or ssh_answers(ROUTER["host"], ROUTER["port"])
    return fetch_status()[0] != "locked"


def login_once(password, was_locked):
    """One password login: "accepted", "wrong" or "unreachable". macOS at the FileVault screen takes the
    password, unlocks, and then stops talking on that connection without closing it, so we do not wait for ssh
    to finish: a refusal is read from its output, an unlock is confirmed by looking at the Mac from the side."""
    env = {"PATH": "/usr/bin:/bin", "SSH_ASKPASS": ASKPASS, "SSH_ASKPASS_REQUIRE": "force",
           "SMOLDER_UNLOCK_PW": password, "DISPLAY": "none"}
    t0 = time.time()
    proc = subprocess.Popen(LOGIN, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            stdin=subprocess.DEVNULL, start_new_session=True)
    seen = {"asked": None, "result": None, "tail": []}

    def reader():
        for line in proc.stdout:
            line = line.rstrip()
            if not line.startswith("debug1:"):
                seen["tail"].append(line[:160])     # what the server or ssh says; never contains the password
            if seen["asked"] is None and any(m in line for m in MARK_ASKED):
                seen["asked"] = time.time()
            if "Permission denied" in line or "Too many authentication failures" in line:
                seen["result"] = seen["result"] or "wrong"
            elif "Authenticated to " in line or "Authentication succeeded" in line or "unlocked" in line.lower():
                seen["result"] = seen["result"] or "accepted"

    threading.Thread(target=reader, daemon=True).start()
    checks, result = (list(CONFIRM_AT) if was_locked else []), None
    while time.time() - t0 < 40:
        if seen["result"]:
            result = seen["result"]
            break
        if proc.poll() is not None:
            time.sleep(0.2)
            result = seen["result"] or ("accepted" if proc.returncode == 0 else "unreachable")
            break
        if seen["asked"] and checks and time.time() - seen["asked"] >= checks[0]:
            checks.pop(0)
            if confirm_unlocked():
                result = "accepted"
                break
        time.sleep(0.1)
    if proc.poll() is None:
        proc.kill()
    log(f"login: {result or 'unreachable'} in {time.time() - t0:.1f}s (asked at {((seen['asked'] or t0) - t0):.1f}s) "
        + " | ".join(seen["tail"][-4:]))
    return result or "unreachable"


def run_job(password):
    with lock:
        was_locked = bool(state["probe"]) and state["probe"]["rung"] == "locked"
    result, started = "unreachable", time.time()
    for n in range(1, TRIES + 1):
        with lock:
            state["job"].update(attempt=n)
        result = login_once(password, was_locked)
        if result != "unreachable":
            break
        time.sleep(2)
    del password
    now = time.time()
    with lock:
        state["job"].update(phase=result, at=now)
        if result == "wrong":
            state["wrong"].append(now)
        if result == "accepted":
            if was_locked and state["job"]["attempt"] == 1:
                save("timing.json", (load("timing.json", []) + [round(now - started, 2)])[-20:])
            state["fastUntil"], state["probedAt"] = now + FAST_FOR, now


def expected_seconds():
    took = sorted(load("timing.json", [])[-5:])
    return round(took[len(took) // 2], 2) if took else EXPECT_DEFAULT


def snapshot():
    now = time.time()
    with lock:
        state["wrong"] = [t for t in state["wrong"] if now - t < WRONG_WINDOW]
        job = dict(state["job"]) if state["job"] else None
        if job and job["phase"] != "trying" and now - job["at"] > 600:
            job = state["job"] = None
        p = state["probe"]
        return {"now": int(now), "probe": {"rung": p["rung"]} if p else None, "job": job,
                "wrongLeft": WRONG_LIMIT - len(state["wrong"]), "expect": expected_seconds()}


# ---------------------------------------------------------------- who is asking (Cloudflare Access)

_keys = {"at": 0, "by_kid": {}}


def b64d(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def access_keys():
    if time.time() - _keys["at"] > 3600 or not _keys["by_kid"]:
        with urllib.request.urlopen(f"https://{ACCESS['team_domain']}/cdn-cgi/access/certs", timeout=15) as r:
            _keys["by_kid"] = {k["kid"]: (int.from_bytes(b64d(k["n"]), "big"), int.from_bytes(b64d(k["e"]), "big"))
                               for k in json.load(r)["keys"]}
        _keys["at"] = time.time()
    return _keys["by_kid"]


SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


def caller_email(headers):
    """The e-mail in the Access token, or "" unless the token is signed by this team's Access keys (RS256),
    meant for this application, and not expired."""
    try:
        h, p, s = headers.get("Cf-Access-Jwt-Assertion", "").split(".")
        head, body = json.loads(b64d(h)), json.loads(b64d(p))
        if head.get("alg") != "RS256":
            return ""
        n, e = access_keys()[head["kid"]]
        size = (n.bit_length() + 7) // 8
        want = b"\x00\x01" + b"\xff" * (size - 3 - len(SHA256_PREFIX) - 32) + b"\x00" + SHA256_PREFIX + hashlib.sha256(f"{h}.{p}".encode()).digest()
        if pow(int.from_bytes(b64d(s), "big"), e, n).to_bytes(size, "big") != want:
            return ""
        aud = body.get("aud", [])
        if ACCESS["aud"] not in (aud if isinstance(aud, list) else [aud]) or body.get("exp", 0) < time.time():
            return ""
        return str(body.get("email", "")).lower()
    except Exception:  # noqa: BLE001 - any doubt is a no
        return ""


class Handler(BaseHTTPRequestHandler):
    server_version = "smolder-unlock"

    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        for k, v in (("Content-Type", ctype), ("Content-Length", str(len(data))), ("Cache-Control", "no-store"),
                     ("X-Frame-Options", "DENY"), ("Referrer-Policy", "no-referrer"),
                     ("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; frame-ancestors 'none'")):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def allowed(self):
        if self.path == "/health" and "Cf-Connecting-Ip" not in self.headers:
            return True
        email = caller_email(self.headers)
        return bool(email) and email in [e.lower() for e in ACCESS["emails"]]

    def do_GET(self):
        if not self.allowed():
            return self.reply(403, {"error": "forbidden"})
        if self.path == "/health":
            return self.reply(200, {"ok": True})
        if self.path == "/api/status":
            maybe_probe()
            return self.reply(200, snapshot())
        if self.path in ("/", "/index.html"):
            with open(os.path.join(BASE, "page.html"), "rb") as f:
                return self.reply(200, f.read(), "text/html; charset=utf-8")
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        if not self.allowed() or self.path != "/api/unlock":
            return self.reply(403, {"error": "forbidden"})
        if self.headers.get("Origin") != f"https://{SITE['hostname']}" or "application/json" not in self.headers.get("Content-Type", ""):
            return self.reply(403, {"error": "bad origin"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            password = json.loads(self.rfile.read(n) if 0 < n <= 2048 else b"{}").get("password", "")
        except ValueError:
            password = ""
        if not isinstance(password, str) or not password or "\n" in password:
            return self.reply(400, {"error": "empty"})
        now = time.time()
        with lock:
            state["wrong"] = [t for t in state["wrong"] if now - t < WRONG_WINDOW]
            if state["job"] and state["job"]["phase"] == "trying":
                return self.reply(409, {"error": "busy"})
            if len(state["wrong"]) >= WRONG_LIMIT:
                return self.reply(429, {"error": "too many wrong passwords"})
            state["job"] = {"phase": "trying", "attempt": 0, "tries": TRIES, "at": now}
        threading.Thread(target=run_job, args=(password,), daemon=True).start()
        self.reply(202, snapshot())


# ---------------------------------------------------------------- telling the owner

def notify(title, note=""):
    """Returns True only if every configured channel took the message; the watcher retries otherwise."""
    ok, text = True, title + (f"\n{note}" if note else "")
    tg = NOTIFY.get("telegram")
    if tg:
        try:
            data = urllib.parse.urlencode({"chat_id": tg["chat_id"], "text": text}).encode()
            with urllib.request.urlopen(f"https://api.telegram.org/bot{tg['bot_token']}/sendMessage", data=data, timeout=30) as r:
                ok = ok and json.load(r).get("ok", False)
        except Exception as e:  # noqa: BLE001
            log(f"telegram failed: {type(e).__name__}")
            ok = False
    mail = NOTIFY.get("email")
    if mail:
        try:
            m = EmailMessage()
            m["Subject"], m["From"], m["To"] = title, mail["from"], mail["to"]
            m.set_content(text)
            with smtplib.SMTP(mail["host"], mail.get("port", 587), timeout=30) as s:
                s.starttls()
                s.login(mail["user"], mail["password"])
                s.send_message(m)
        except Exception as e:  # noqa: BLE001 - mail is the second leg; do not hold the alert for it
            log(f"email failed: {type(e).__name__}")
    return ok


def card(rung, since=None, detail="", suffix=""):
    title, note = TEXT[rung]
    lasted = f" ({TEXT['for'].format(m=int((time.time() - since) / 60))})" if since else ""
    return title + suffix + lasted, note.format(host=SITE["hostname"], detail=detail)


def watch_once(mem):
    """One look. `mem` is {"since", "level", "rung", "boot"}; it only moves forward after a delivered message."""
    p, now = do_probe(), time.time()
    rung = p["rung"]
    if rung != "ok":
        mem["since"] = mem.get("since") or now
        lasted, level, told = now - mem["since"], mem.get("level", 0), mem.get("rung")
        if level == 0 and lasted >= (WARN_LOCKED if rung == "locked" else WARN):
            if notify(*card(rung, mem["since"], p.get("detail", ""))):
                mem.update(level=1, rung=rung)
        elif level >= 1 and told in RANK and RANK[rung] > RANK[told]:
            if notify(*card(rung, mem["since"], p.get("detail", ""))):
                mem["rung"] = rung
        elif level == 1 and lasted >= ESCALATE:
            if notify(*card(rung, mem["since"], p.get("detail", ""), TEXT["still"])):
                mem["level"] = 2
        return
    boot = p.get("bootTime")
    if mem.get("level", 0) >= 1:
        if not notify(*card("ok", mem["since"])):
            return
    elif boot and mem.get("boot") and boot != mem["boot"]:
        if not notify(*card("boot")):
            return
    mem.update(since=None, level=0, rung=None, boot=boot or mem.get("boot"))


def watcher():
    mem = load("watch.json", {})
    while True:
        try:
            watch_once(mem)
            save("watch.json", mem)
        except Exception as e:  # noqa: BLE001
            log(f"watch failed: {type(e).__name__}: {e}")
        time.sleep(WATCH_EVERY)


if __name__ == "__main__":
    os.makedirs(STATE_DIR, exist_ok=True)
    if "--probe" in sys.argv:           # for the installer and for humans: one look, as JSON
        print(json.dumps(probe()))
        sys.exit(0)
    if "--test-notify" in sys.argv:
        sys.exit(0 if notify(*card("locked")) else 1)
    if NOTIFY:
        threading.Thread(target=watcher, daemon=True).start()
    log(f"smolder-unlock on 127.0.0.1:{SITE['listen_port']} for https://{SITE['hostname']}")
    ThreadingHTTPServer(("127.0.0.1", SITE["listen_port"]), Handler).serve_forever()
