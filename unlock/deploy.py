#!/usr/bin/env python3
"""Deploy smolder-unlock. Run it on the Mac you want to be able to unlock.

    deploy.py init                      write a config.json to fill in
    deploy.py plan      [config.json]   what is configured, what each step will do; changes nothing
    deploy.py apply     [config.json]   run every step; each one checks itself and the run stops at the first failure
    deploy.py apply --step NAME         one step: preflight, server, link, mac, cloudflare, start, verify
    deploy.py verify    [config.json]   only look: is everything in place and answering
    deploy.py uninstall [config.json]   take it all down again

Every step can be run again safely. Lines start with OK, FAIL, TODO (something only a person can do) or INFO, so
an agent can follow along. Secrets come from the environment and are never written to this machine:

    CLOUDFLARE_API_TOKEN   required for the cloudflare step (permissions listed in README.md)
    TELEGRAM_BOT_TOKEN     if notify.telegram is configured
    SMTP_PASSWORD          if notify.email is configured

Standard library only; Python 3.9+.
"""
import json
import os
import shlex
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STEPS = ["preflight", "server", "link", "mac", "cloudflare", "start", "verify"]
MARK = "smolder-unlock-status"          # the comment on our line in the Mac's authorized_keys
TUNNEL, APP = "smolder-unlock", "Smolder Unlock"
failed = []


def say(kind, msg):
    print(f"{kind:<5}{msg}", flush=True)
    if kind == "FAIL":
        failed.append(msg)


def sh(cmd, inp=None, timeout=120):
    r = subprocess.run(cmd, shell=isinstance(cmd, str), input=inp, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


class Remote:
    def __init__(self, target):
        self.base = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "ControlMaster=auto",
                     "-o", "ControlPersist=60", "-o", "ControlPath=/tmp/smolder-unlock-%C", target]

    def run(self, script, inp=None, timeout=180):
        """Run a shell script on the server (as root, or through sudo when the login is not root)."""
        wrapped = "if [ \"$(id -u)\" = 0 ]; then IN=$f sh -s; else sudo -n env IN=$f sh -s; fi"
        if inp is None:
            return sh(self.base + ["f=; " + wrapped], script, timeout)
        # the payload travels on stdin into a temp file; the script itself is a here-document
        return sh(self.base + [f"f=$(mktemp); cat > $f; ( {wrapped} ) <<'SMOLDER_EOF'\n{script}\nSMOLDER_EOF\nrc=$?; rm -f $f; exit $rc"], inp, timeout)


def cf(method, path, body=None):
    req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={**cf_auth(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=40) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        try:
            return json.load(e)
        except ValueError:
            return {"success": False, "errors": [{"message": f"HTTP {e.code}"}]}


def cf_auth():
    """A scoped API token is the right thing; a global key with its e-mail also works for accounts that only have that."""
    if os.environ.get("CLOUDFLARE_API_TOKEN"):
        return {"Authorization": "Bearer " + os.environ["CLOUDFLARE_API_TOKEN"]}
    return {"X-Auth-Email": os.environ["CLOUDFLARE_EMAIL"], "X-Auth-Key": os.environ["CLOUDFLARE_API_KEY"]}


def have_cf():
    return bool(os.environ.get("CLOUDFLARE_API_TOKEN") or (os.environ.get("CLOUDFLARE_EMAIL") and os.environ.get("CLOUDFLARE_API_KEY")))


def cf_ok(r, what):
    if not r.get("success"):
        raise RuntimeError(f"Cloudflare: {what}: " + "; ".join(str(e.get("message")) for e in r.get("errors", [])))
    return r["result"]


def load_config(path):
    c = json.load(open(path))
    c.setdefault("lang", "en")
    c["server"].setdefault("install_dir", "/opt/smolder-unlock")
    c["server"].setdefault("listen_port", 3112)
    link = c["link"]
    if link["mode"] == "reverse":
        link.setdefault("mac_port_on_server", 39930)
        link.setdefault("device_port_on_server", 39931)
        c["_mac_seen"] = {"host": "127.0.0.1", "port": link["mac_port_on_server"]}
        c["_check"] = {"host": "127.0.0.1", "port": link["device_port_on_server"]}
    elif link["mode"] == "direct":
        # optional link.check {"host","port"}: an SSH port that answers whenever the path home is up (a router, a jump host),
        # so the page can tell "home is offline" from "the Mac does not answer"
        c["_mac_seen"], c["_check"] = {"host": link["host"], "port": link.get("port", 22)}, link.get("check")
    else:
        raise SystemExit("link.mode must be \"reverse\" or \"direct\"")
    return c


# ------------------------------------------------------------------ steps

def preflight(c, r):
    code, out, _ = sh("sw_vers -productVersion")
    major = int(out.split(".")[0]) if code == 0 and out else 0
    say("OK" if major >= 26 else "FAIL", f"macOS {out or '?'} (unlocking over SSH needs macOS 26 or later)")
    _, out, _ = sh("fdesetup status")
    say("OK" if "FileVault is On" in out else "INFO", out.splitlines()[0] if out else "FileVault status unknown")
    code, _, _ = sh("nc -z -G 3 127.0.0.1 22")
    say("OK", "Remote Login is on") if code == 0 else say("TODO", "turn on System Settings → General → Sharing → Remote Login (the installer must not change this for you)")
    if code != 0:
        failed.append("Remote Login is off")
    _, out, _ = sh("ioreg -r -k AppleClamshellState -d 1")
    if "AppleClamshellState" in out:
        _, disp, _ = sh("system_profiler SPDisplaysDataType")
        ext = [l for l in disp.splitlines() if "Resolution" in l]
        say("INFO", "this is a laptop: with the lid closed it sleeps at the password screen unless a display (or an "
                    f"HDMI dummy plug) is attached. Displays seen now: {len(ext)}")
    hb = os.path.expanduser("~/.local/state/smolder/heartbeat.json")
    say("OK" if os.path.exists(hb) else "INFO",
        "Smolder writes its heartbeat file" if os.path.exists(hb) else "no Smolder heartbeat file: the page will still work; "
        "\"logged in or still at the login window\" cannot be told apart (see README, \"Tell logged-in from unlocked\")")
    code, out, err = r.run("command -v python3 systemctl curl >/dev/null && python3 -c 'import sys; print(sys.version_info >= (3, 9))' && uname -m")
    good = code == 0 and out.startswith("True")
    say("OK" if good else "FAIL", f"server reachable with python3 ≥ 3.9, systemd, curl ({out.splitlines()[-1] if good else err or out})")
    if not have_cf():
        say("TODO", "export CLOUDFLARE_API_TOKEN (see README for the permissions it needs)")
    if c.get("notify", {}).get("telegram") and "TELEGRAM_BOT_TOKEN" not in os.environ:
        say("TODO", "export TELEGRAM_BOT_TOKEN (or remove notify.telegram)")


def server(c, r):
    d = shlex.quote(c["server"]["install_dir"])
    files = {n: open(os.path.join(HERE, "server", n)).read() for n in ("unlockd.py", "page.html", "askpass.sh")}
    script = f"""set -e
id smolder-unlock >/dev/null 2>&1 || useradd --system --home-dir {d} --shell /usr/sbin/nologin smolder-unlock
install -d -m 755 {d} && install -d -m 700 -o smolder-unlock -g smolder-unlock {d}/state {d}/keys
python3 - "$IN" {d} <<'PY'
import json, os, sys
for name, text in json.load(open(sys.argv[1])).items():
    p = os.path.join(sys.argv[2], name)
    open(p, "w").write(text); os.chmod(p, 0o755 if name != "page.html" else 0o644)
PY
[ -f {d}/keys/status ] || ssh-keygen -q -t ed25519 -N '' -C {MARK} -f {d}/keys/status
chown smolder-unlock:smolder-unlock {d}/keys/status {d}/keys/status.pub && chmod 600 {d}/keys/status
cat {d}/keys/status.pub"""
    code, out, err = r.run(script, json.dumps(files))
    ok = code == 0 and out.startswith("ssh-ed25519 ")
    say("OK" if ok else "FAIL", "program files and the status key are on the server" if ok else f"server step: {err or out}")
    return out if ok else None


def link(c, r):
    l = c["link"]
    if l["mode"] == "direct":
        say("INFO", f"link: the server reaches the Mac's SSH at {l['host']}:{l.get('port', 22)} (your port forward or VPN); nothing to install")
        return
    conf = f"""# smolder-unlock: a device at home keeps a reverse tunnel open; it may listen on these two loopback ports and nothing else
Match User smolder-link
\tAuthorizedKeysFile /etc/ssh/smolder-link_authorized_keys
\tAllowTcpForwarding remote
\tPermitListen 127.0.0.1:{l['mac_port_on_server']} 127.0.0.1:{l['device_port_on_server']}
\tGatewayPorts no
\tAllowAgentForwarding no
\tX11Forwarding no
\tPermitTTY no
\tForceCommand /usr/sbin/nologin
\tClientAliveInterval 20
\tClientAliveCountMax 3
"""
    script = """set -e
id smolder-link >/dev/null 2>&1 || useradd --system --create-home --shell /bin/sh smolder-link
passwd -l smolder-link >/dev/null 2>&1 || true
touch /etc/ssh/smolder-link_authorized_keys && chmod 644 /etc/ssh/smolder-link_authorized_keys
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || { echo "sshd_config does not include sshd_config.d"; exit 3; }
cp "$IN" /etc/ssh/sshd_config.d/70-smolder-link.conf.new
mv /etc/ssh/sshd_config.d/70-smolder-link.conf.new /etc/ssh/sshd_config.d/70-smolder-link.conf
if sshd -t; then systemctl reload ssh 2>/dev/null || systemctl reload sshd; else rm -f /etc/ssh/sshd_config.d/70-smolder-link.conf; echo "sshd refused the new config; removed it"; exit 4; fi
wc -l < /etc/ssh/smolder-link_authorized_keys"""
    code, out, err = r.run(script, conf)
    if code != 0:
        return say("FAIL", f"link step on the server: {out or err}")
    say("OK", "server accepts the reverse tunnel for user smolder-link (two loopback ports, no shell)")
    host = l.get("server_host") or c["server"]["ssh"].split("@")[-1]   # what the home device dials; set link.server_host if server.ssh is an alias
    out_dir = os.path.join(os.getcwd(), "home-device")
    os.makedirs(out_dir, exist_ok=True)
    cmd = (f"ssh -N -T -o ExitOnForwardFailure=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new "
           f"-o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=15 -p {l.get('server_port', 22)} "
           f"-i /etc/smolder-link/key -R 127.0.0.1:{l['mac_port_on_server']}:{c['mac']['lan_ip']}:22 "
           f"-R 127.0.0.1:{l['device_port_on_server']}:127.0.0.1:22 smolder-link@{host}")
    open(os.path.join(out_dir, "smolder-link.service"), "w").write(
        f"[Unit]\nDescription=smolder-unlock: reverse tunnel from home to the unlock server\nAfter=network-online.target\nWants=network-online.target\n\n"
        f"[Service]\nExecStart=/usr/bin/{cmd}\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=multi-user.target\n")
    open(os.path.join(out_dir, "smolder-link.openwrt"), "w").write(
        "#!/bin/sh /etc/rc.common\n# OpenWrt: copy to /etc/init.d/smolder-link, chmod +x, then: /etc/init.d/smolder-link enable && /etc/init.d/smolder-link start\n"
        "# needs the openssh-client package (dropbear's client is not used here)\nUSE_PROCD=1\nSTART=95\nstart_service() {\n\tprocd_open_instance\n"
        f"\tprocd_set_param command /usr/bin/{cmd}\n\tprocd_set_param respawn 3600 10 0\n\tprocd_set_param stderr 1\n\tprocd_close_instance\n}}\n")
    open(os.path.join(out_dir, "README.txt"), "w").write(
        "On the always-on device at home (router, Raspberry Pi, NAS; anything but the Mac itself):\n\n"
        "  1. mkdir -p /etc/smolder-link && ssh-keygen -q -t ed25519 -N '' -f /etc/smolder-link/key\n"
        f"  2. append /etc/smolder-link/key.pub as one line to /etc/ssh/smolder-link_authorized_keys on {host}\n"
        "  3. systemd device: copy smolder-link.service to /etc/systemd/system/, then: systemctl enable --now smolder-link\n"
        "     OpenWrt: see the first lines of smolder-link.openwrt\n"
        f"  4. the device's own SSH must listen on 127.0.0.1:22 (it is how the server tells \"tunnel down\" from \"Mac down\")\n\n"
        "Then run: deploy.py apply --step mac\n")
    if int(out or 0) == 0:
        say("TODO", f"set up the tunnel on your home device: follow {out_dir}/README.txt, then continue with --step mac")
    else:
        say("OK", "a home device key is registered")


def mac(c, r, pub=None):
    d = shlex.quote(c["server"]["install_dir"])
    if not pub:
        _, pub, _ = r.run(f"cat {d}/keys/status.pub")
    if not pub.startswith("ssh-ed25519 "):
        return say("FAIL", "the server has no status key yet: run --step server first")
    path = os.path.expanduser("~/.ssh/authorized_keys")
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    lines = [l for l in (open(path).read().splitlines() if os.path.exists(path) else []) if MARK not in l]
    hb = os.path.expanduser("~/.local/state/smolder/heartbeat.json")
    lines.append(f'restrict,command="date +%s; cat {hb} 2>/dev/null" {pub}')
    with open(path + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path + ".tmp", 0o600)
    os.replace(path + ".tmp", path)
    say("OK", "the Mac accepts the server's status key (it can only print the clock and Smolder's heartbeat file)")
    _, hostkey, _ = sh("cat /etc/ssh/ssh_host_ed25519_key.pub")
    if not hostkey.startswith("ssh-ed25519 "):
        return say("FAIL", "cannot read this Mac's SSH host key")
    known = "the-mac " + " ".join(hostkey.split()[:2]) + "\n"
    code, out, err = r.run(f"cp \"$IN\" {d}/known_hosts && chmod 644 {d}/known_hosts", known)
    say("OK" if code == 0 else "FAIL", "the server pins this Mac's host key" if code == 0 else err)
    mac_seen = c["_mac_seen"]
    cfg = json.dumps({"mac": {"user": c["mac"]["user"], **mac_seen}, "link_check": c["_check"], "access": {"team_domain": "x", "aud": "x", "emails": []},
                      "site": {"hostname": "x", "listen_port": c["server"]["listen_port"]}})
    code, out, err = r.run(f"cp \"$IN\" {d}/probe.json && chmod 644 {d}/probe.json && cd {d} && "
                           f"runuser -u smolder-unlock -- env SMOLDER_UNLOCK_CONFIG={d}/probe.json python3 unlockd.py --probe; rm -f {d}/probe.json", cfg)
    rung = (json.loads(out.splitlines()[-1]).get("rung") if code == 0 and out else None)
    if rung in ("ok", "up"):
        say("OK", f"the server can see this Mac through the link (state: {rung})")
    else:
        say("FAIL", f"the server cannot read this Mac through the link (state: {rung or err or out}); "
                    + ("is the home device tunnel running?" if c["link"]["mode"] == "reverse" else "check the forwarded address and port"))


def cloudflare(c, r):
    if not have_cf():
        return say("TODO", "export CLOUDFLARE_API_TOKEN, then run --step cloudflare")
    cfc, d = c["cloudflare"], shlex.quote(c["server"]["install_dir"])
    host = cfc["hostname"]
    try:
        zone = cf_ok(cf("GET", f"/zones?name={cfc['zone']}"), "find the zone")
        if not zone:
            return say("FAIL", f"the token cannot see the zone {cfc['zone']}")
        zid, acct = zone[0]["id"], zone[0]["account"]["id"]
        org = cf("GET", f"/accounts/{acct}/access/organizations")
        if not org.get("success"):
            return say("TODO", "enable Zero Trust once in the Cloudflare dashboard (free plan is enough): Zero Trust → pick a team name")
        team = org["result"]["auth_domain"]
        idps = cf_ok(cf("GET", f"/accounts/{acct}/access/identity_providers"), "list login methods")
        otp = next((i["id"] for i in idps if i["type"] == "onetimepin"), None) or cf_ok(
            cf("POST", f"/accounts/{acct}/access/identity_providers", {"name": "One-time PIN", "type": "onetimepin", "config": {}}), "add one-time PIN login")["id"]
        apps = cf_ok(cf("GET", f"/accounts/{acct}/access/apps"), "list Access applications")
        app = next((a for a in apps if a.get("domain") == host), None) or cf_ok(cf("POST", f"/accounts/{acct}/access/apps", {
            "type": "self_hosted", "name": APP, "domain": host, "session_duration": "24h", "app_launcher_visible": False,
            "allowed_idps": [otp], "auto_redirect_to_identity": True, "http_only_cookie_attribute": True}), "create the Access application")
        include = [{"email": {"email": e}} for e in cfc["emails"]]
        pols = cf_ok(cf("GET", f"/accounts/{acct}/access/apps/{app['id']}/policies"), "list policies")
        body = {"name": "owner only", "decision": "allow", "precedence": 1, "include": include}
        if pols:
            cf_ok(cf("PUT", f"/accounts/{acct}/access/apps/{app['id']}/policies/{pols[0]['id']}", body), "update the policy")
        else:
            cf_ok(cf("POST", f"/accounts/{acct}/access/apps/{app['id']}/policies", body), "create the policy")
        pols = cf_ok(cf("GET", f"/accounts/{acct}/access/apps/{app['id']}/policies"), "re-read policies")
        if len(pols) != 1 or pols[0]["decision"] != "allow" or len(pols[0]["include"]) != len(include):
            return say("FAIL", "the Access application does not have exactly the one owner-only policy; not publishing the hostname")
        say("OK", f"Access application protects {host}: e-mail code, only {', '.join(cfc['emails'])}")
        # only now, with the lock on the door, publish the hostname
        tun = cf_ok(cf("GET", f"/accounts/{acct}/cfd_tunnel?name={TUNNEL}&is_deleted=false"), "find the tunnel")
        tid = tun[0]["id"] if tun else cf_ok(cf("POST", f"/accounts/{acct}/cfd_tunnel", {"name": TUNNEL, "config_src": "cloudflare"}), "create the tunnel")["id"]
        cf_ok(cf("PUT", f"/accounts/{acct}/cfd_tunnel/{tid}/configurations", {"config": {"ingress": [
            {"hostname": host, "service": f"http://127.0.0.1:{c['server']['listen_port']}"}, {"service": "http_status:404"}]}}), "set the tunnel route")
        rec = cf_ok(cf("GET", f"/zones/{zid}/dns_records?name={host}"), "look up DNS")
        want = {"type": "CNAME", "name": host, "content": f"{tid}.cfargotunnel.com", "proxied": True, "comment": "smolder-unlock"}
        if not rec:
            cf_ok(cf("POST", f"/zones/{zid}/dns_records", want), "create the DNS record")
        elif rec[0]["content"] != want["content"]:
            return say("FAIL", f"{host} already points somewhere else ({rec[0]['content']}); pick another hostname or remove that record")
        token = cf_ok(cf("GET", f"/accounts/{acct}/cfd_tunnel/{tid}/token"), "fetch the tunnel token")
    except RuntimeError as e:
        return say("FAIL", str(e))
    say("OK", f"tunnel {TUNNEL} routes {host} to the server; DNS record in place")
    notify = json.loads(json.dumps(c.get("notify") or {}))
    if notify.get("telegram"):
        notify["telegram"]["bot_token"] = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    if notify.get("email"):
        notify["email"]["password"] = os.environ.get("SMTP_PASSWORD", "")
    conf = {"lang": c["lang"], "mac": {"user": c["mac"]["user"], **c["_mac_seen"]}, "link_check": c["_check"],
            "access": {"team_domain": team, "aud": app["aud"], "emails": cfc["emails"]},
            "site": {"hostname": host, "listen_port": c["server"]["listen_port"]}, "notify": notify}
    script = f"""set -e
python3 - "$IN" {d} <<'PY'
import json, os, sys
b = json.load(open(sys.argv[1])); d = sys.argv[2]
for name, text in (("config.json", json.dumps(b["conf"], indent=1)), ("state/tunnel-token", b["token"])):
    p = os.path.join(d, name); open(p, "w").write(text); os.chmod(p, 0o600)
PY
chown smolder-unlock:smolder-unlock {d}/config.json {d}/state/tunnel-token
if [ ! -x {d}/cloudflared ]; then
  case "$(uname -m)" in x86_64) a=amd64;; aarch64|arm64) a=arm64;; armv7l) a=arm;; *) echo "unsupported CPU $(uname -m)"; exit 5;; esac
  curl -fsSL -o {d}/cloudflared.new "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$a"
  chmod 755 {d}/cloudflared.new && mv {d}/cloudflared.new {d}/cloudflared
fi
{d}/cloudflared --version | head -1"""
    code, out, err = r.run(script, json.dumps({"conf": conf, "token": token}), timeout=300)
    say("OK" if code == 0 else "FAIL", f"server has its config, the tunnel token and {out.splitlines()[-1] if code == 0 and out else 'cloudflared'}" if code == 0 else err or out)


def start(c, r):
    d = c["server"]["install_dir"]
    units = {"smolder-unlock.service": f"""[Unit]
Description=smolder-unlock: page and watcher that bring a FileVault Mac back after a reboot
After=network-online.target
Wants=network-online.target

[Service]
User=smolder-unlock
WorkingDirectory={d}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 {d}/unlockd.py
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
""", "smolder-unlock-tunnel.service": f"""[Unit]
Description=smolder-unlock: Cloudflare Tunnel (outbound only)
After=network-online.target
Wants=network-online.target

[Service]
User=smolder-unlock
ExecStart={d}/cloudflared tunnel --no-autoupdate run --token-file {d}/state/tunnel-token
Restart=always
RestartSec=10
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
"""}
    script = f"""set -e
[ -f {shlex.quote(d)}/config.json ] || {{ echo "no config.json yet: run --step cloudflare first"; exit 6; }}
python3 - "$IN" <<'PY'
import json, sys
for name, text in json.load(open(sys.argv[1])).items():
    open("/etc/systemd/system/" + name, "w").write(text)
PY
systemctl daemon-reload
systemctl enable -q smolder-unlock.service smolder-unlock-tunnel.service
systemctl restart smolder-unlock.service smolder-unlock-tunnel.service
sleep 4
systemctl is-active smolder-unlock.service smolder-unlock-tunnel.service | tr '\\n' ' '"""
    code, out, err = r.run(script, json.dumps(units))
    ok = code == 0 and out.split() == ["active", "active"]
    say("OK" if ok else "FAIL", "both services are running" if ok else f"services: {out or err}")


def verify(c, r):
    d, port, host = shlex.quote(c["server"]["install_dir"]), c["server"]["listen_port"], c["cloudflare"]["hostname"]
    code, out, _ = r.run(f"""echo "units=$(systemctl is-active smolder-unlock.service smolder-unlock-tunnel.service | tr '\n' ' ')"
echo "health=$(curl -s -m 5 127.0.0.1:{port}/health)"
echo "nologin=$(curl -s -m 5 -o /dev/null -w '%{{http_code}}' 127.0.0.1:{port}/)"
cd {d} && echo "probe=$(runuser -u smolder-unlock -- python3 unlockd.py --probe)" """)
    got = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
    say("OK" if got.get("units", "").split() == ["active", "active"] else "FAIL", f"services: {got.get('units', '?').strip()}")
    say("OK" if '"ok": true' in got.get("health", "") else "FAIL", "the page program answers on the server")
    say("OK" if got.get("nologin") == "403" else "FAIL", f"a request without a Cloudflare login is refused on the server itself ({got.get('nologin')})")
    try:
        rung = json.loads(got.get("probe", "")).get("rung")
    except ValueError:
        rung = got.get("probe") or "no answer"
    say("OK" if rung in ("ok", "up") else "FAIL", f"the server sees the Mac: {rung}")
    code, out, _ = sh(["curl", "-sS", "-m", "20", "-o", "/dev/null", "-w", "%{http_code} %{redirect_url}", f"https://{host}/"])
    status, _, where = out.partition(" ")
    if status == "200":
        say("FAIL", f"https://{host}/ answered without asking for a login. Take it down (deploy.py uninstall) and check the Access application")
    else:
        say("OK" if status == "302" and "cloudflareaccess.com" in where else "FAIL",
            f"https://{host}/ sends visitors to the Cloudflare login" if status == "302" else f"https://{host}/ is not answering as expected yet ({out or 'no answer'}); DNS can take a minute, run verify again")
    say("TODO", f"open https://{host} on your phone, log in with the e-mail code: it should say all is well. "
                "Then restart the Mac once while you are at home and unlock it from the page")


def uninstall(c, r):
    d = shlex.quote(c["server"]["install_dir"])
    if have_cf():
        try:
            host = c["cloudflare"]["hostname"]
            zone = cf_ok(cf("GET", f"/zones?name={c['cloudflare']['zone']}"), "find the zone")[0]
            zid, acct = zone["id"], zone["account"]["id"]
            for t in cf_ok(cf("GET", f"/accounts/{acct}/cfd_tunnel?name={TUNNEL}&is_deleted=false"), "find the tunnel"):
                cf("PUT", f"/accounts/{acct}/cfd_tunnel/{t['id']}/configurations", {"config": {"ingress": [{"service": "http_status:404"}]}})
            for rec in cf_ok(cf("GET", f"/zones/{zid}/dns_records?name={host}"), "look up DNS"):
                if rec.get("content", "").endswith(".cfargotunnel.com"):
                    cf("DELETE", f"/zones/{zid}/dns_records/{rec['id']}")
            for a in cf_ok(cf("GET", f"/accounts/{acct}/access/apps"), "list applications"):
                if a.get("domain") == host:
                    cf("DELETE", f"/accounts/{acct}/access/apps/{a['id']}")
            r.run("systemctl disable -q --now smolder-unlock-tunnel.service 2>/dev/null; true")
            for t in cf_ok(cf("GET", f"/accounts/{acct}/cfd_tunnel?name={TUNNEL}&is_deleted=false"), "find the tunnel"):
                cf("DELETE", f"/accounts/{acct}/cfd_tunnel/{t['id']}")
            say("OK", "Cloudflare: route, DNS record, Access application and tunnel removed (hostname first, lock last)")
        except (RuntimeError, IndexError) as e:
            say("FAIL", str(e))
    else:
        say("TODO", "CLOUDFLARE_API_TOKEN not set: remove the tunnel, DNS record and Access application in the dashboard")
    code, out, err = r.run(f"""systemctl disable -q --now smolder-unlock.service smolder-unlock-tunnel.service 2>/dev/null
rm -f /etc/systemd/system/smolder-unlock.service /etc/systemd/system/smolder-unlock-tunnel.service; systemctl daemon-reload
rm -f /etc/ssh/sshd_config.d/70-smolder-link.conf /etc/ssh/smolder-link_authorized_keys; sshd -t && (systemctl reload ssh 2>/dev/null || systemctl reload sshd)
pkill -u smolder-link 2>/dev/null; pkill -u smolder-unlock 2>/dev/null; sleep 1
userdel -r smolder-link 2>/dev/null; rm -rf {d}; userdel smolder-unlock 2>/dev/null
id smolder-link >/dev/null 2>&1 && echo "user smolder-link is still there" || echo done""")
    say("OK" if "done" in out else "FAIL", "server: services, files and both users removed" if "done" in out else err)
    path = os.path.expanduser("~/.ssh/authorized_keys")
    if os.path.exists(path):
        keep = [l for l in open(path).read().splitlines() if MARK not in l]
        open(path, "w").write("\n".join(keep) + ("\n" if keep else ""))
    say("OK", "this Mac: the status key line is gone from authorized_keys")
    if c["link"]["mode"] == "reverse":
        say("TODO", "on the home device: stop and remove the smolder-link service and /etc/smolder-link")


def plan(c):
    l = c["link"]
    say("INFO", f"Mac user {c['mac']['user']}; server {c['server']['ssh']} ({c['server']['install_dir']}, 127.0.0.1:{c['server']['listen_port']})")
    say("INFO", "link: " + (f"reverse tunnel from a home device; the server sees the Mac at 127.0.0.1:{l['mac_port_on_server']}" if l["mode"] == "reverse"
                           else f"direct to {l['host']}:{l.get('port', 22)}"))
    say("INFO", f"page: https://{c['cloudflare']['hostname']} behind Cloudflare Access, only {', '.join(c['cloudflare']['emails'])}")
    say("INFO", "alerts: " + (", ".join(k for k in ("telegram", "email") if (c.get("notify") or {}).get(k)) or "none"))
    say("INFO", "steps, in order: " + ", ".join(STEPS))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only = sys.argv[sys.argv.index("--step") + 1] if "--step" in sys.argv else None
    if only:
        args = [a for a in args if a != only]
    if args and args[0] == "init":
        if os.path.exists("config.json"):
            raise SystemExit("config.json already exists here")
        open("config.json", "w").write(open(os.path.join(HERE, "config.example.json")).read())
        return say("OK", "wrote config.json; edit it (README.md explains every key), then run: plan")
    if not args or args[0] not in ("plan", "apply", "verify", "uninstall"):
        raise SystemExit(__doc__)
    c = load_config(args[1] if len(args) > 1 else "config.json")
    r = Remote(c["server"]["ssh"])
    if args[0] == "plan":
        plan(c)
    elif args[0] == "verify":
        verify(c, r)
    elif args[0] == "uninstall":
        uninstall(c, r)
    else:
        pub = None
        for name in ([only] if only else STEPS):
            print(f"--- {name}", flush=True)
            before = len(failed)
            out = {"preflight": preflight, "server": server, "link": link, "cloudflare": cloudflare, "start": start, "verify": verify}.get(name)
            pub = mac(c, r, pub) if name == "mac" else (out(c, r) if out else say("FAIL", f"unknown step {name}"))
            pub = pub if name == "server" else None
            if len(failed) > before:
                print(f"stopped at step {name}; fix the FAIL line above and run: deploy.py apply --step {name}", flush=True)
                break
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
