#!/usr/bin/env python3
# =============================================================================
# gh-release-upload.py :: upload a GitHub Release asset WITHOUT the
# `uploads.github.com` DNS/SNI path.
#
# Why this exists
# ---------------
# `gh release upload` POSTs the asset to https://uploads.github.com/... .
# That host is NOT served by the *.github.com wildcard IP: when the local
# mitmproxy maps *.github.com to 140.82.116.3, the upload POST is routed to a
# backend that answers 404.  The real front-end lives on the Azure range
# (20.205.243.16x) and *resets the TLS connection when a SNI is sent*, so a
# normal HTTPS client cannot reach it.
#
# The fix is a raw TLS connection with NO SNI to 20.205.243.161, then a plain
# HTTP POST of the asset bytes.  This is a documented fallback for when even
# the config.yaml `uploads.github.com` mapping cannot be used (e.g. the proxy
# is not running, or upstream SNI handling changed).
#
# Usage:
#   python3 gh-release-upload.py OWNER/REPO TAG FILE [FILE ...]
#     [--ip 20.205.243.161] [--label name]
#
# Auth token is read from $GH_TOKEN, else `gh auth token`.
# =============================================================================
import argparse, os, socket, ssl, subprocess, sys

FRONTENDS = ["20.205.243.161", "20.205.243.162", "20.205.243.165", "20.205.243.167"]


def token():
    t = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if t:
        return t.strip()
    return subprocess.check_output(["gh", "auth", "token"], text=True).strip()


def release_id(repo, tag, tok):
    env = dict(os.environ, GH_TOKEN=tok)
    out = subprocess.check_output(
        ["gh", "api", f"/repos/{repo}/releases/tags/{tag}", "--jq", ".id"],
        text=True, env=env)
    return out.strip()


def upload(ip, repo, rid, path, tok):
    name = os.path.basename(path)
    body = open(path, "rb").read()
    req = (
        f"POST /repos/{repo}/releases/{rid}/assets?name={name} HTTP/1.1\r\n"
        f"Host: uploads.github.com\r\n"
        f"Authorization: Bearer {tok}\r\n"
        f"Accept: application/vnd.github+json\r\n"
        f"Content-Type: application/octet-stream\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n\r\n"
    ).encode() + body
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((ip, 443), timeout=30)
    ss = ctx.wrap_socket(raw, server_hostname=None)  # <- no SNI
    ss.sendall(req)
    buf = b""
    while len(buf) < 8192:
        d = ss.recv(8192)
        if not d:
            break
        buf += d
    ss.close()
    return buf.decode("latin1", "ignore").splitlines()[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("tag")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--ip", default=None)
    a = ap.parse_args()
    tok = token()
    try:
        rid = release_id(a.repo, a.tag, tok)
    except subprocess.CalledProcessError as e:
        print("cannot resolve release id:", e, file=sys.stderr)
        return 1
    print(f"release {a.repo}@{a.tag} -> id {rid}")
    ips = [a.ip] if a.ip else FRONTENDS
    rc = 0
    for f in a.files:
        ok = False
        for ip in ips:
            try:
                line = upload(ip, a.repo, rid, f, tok)
            except Exception as e:
                print(f"  {os.path.basename(f):40} {ip:16} ERR {type(e).__name__}: {e}")
                continue
            print(f"  {os.path.basename(f):40} {ip:16} {line}")
            if " 201 " in line or " 200 " in line:
                ok = True
                break
        if not ok:
            rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
