#!/usr/bin/env python3
"""Checks the Cloudflare Access token verification in unlockd.py against tokens signed with a throwaway key.
Needs the `openssl` command. Run: python3 unlock/tests/test_access_token.py"""
import base64, json, os, subprocess, sys, tempfile, time

tmp = tempfile.mkdtemp()
conf = {"mac": {"user": "u", "host": "127.0.0.1", "port": 1}, "access": {"team_domain": "t.example", "aud": "AUD1", "emails": ["me@example.com"]},
        "site": {"hostname": "h.example", "listen_port": 1}}
json.dump(conf, open(os.path.join(tmp, "c.json"), "w"))
os.environ["SMOLDER_UNLOCK_CONFIG"] = os.path.join(tmp, "c.json")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "server"))
import unlockd  # noqa: E402

b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
key = os.path.join(tmp, "k.pem")
subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
mod = subprocess.run(["openssl", "rsa", "-in", key, "-noout", "-modulus"], check=True, capture_output=True, text=True).stdout.strip().split("=")[1]
unlockd._keys.update(at=time.time(), by_kid={"kid1": (int(mod, 16), 65537)})


def token(claims, kid="kid1", alg="RS256", keyfile=key):
    signing = b64(json.dumps({"alg": alg, "kid": kid}).encode()) + "." + b64(json.dumps(claims).encode())
    sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", keyfile], input=signing.encode(), check=True, capture_output=True).stdout
    return signing + "." + b64(sig)


good = {"email": "Me@Example.com", "aud": ["AUD1"], "exp": time.time() + 60}
other = os.path.join(tmp, "o.pem")
subprocess.run(["openssl", "genrsa", "-out", other, "2048"], check=True, capture_output=True)
cases = [("valid token", token(good), "me@example.com"),
         ("expired", token({**good, "exp": time.time() - 5}), ""),
         ("meant for another application", token({**good, "aud": ["OTHER"]}), ""),
         ("signed by someone else", token(good, keyfile=other), ""),
         ("unknown key id", token(good, kid="nope"), ""),
         ("payload swapped after signing", ".".join([token(good).split(".")[0], b64(json.dumps({**good, "email": "evil@x"}).encode()), token(good).split(".")[2]]), ""),
         ("no token", "", ""), ("garbage", "a.b.c", "")]
bad = 0
for name, tok, want in cases:
    got = unlockd.caller_email({"Cf-Access-Jwt-Assertion": tok})
    print(("ok  " if got == want else "FAIL"), name, "->", repr(got))
    bad += got != want
sys.exit(1 if bad else 0)
