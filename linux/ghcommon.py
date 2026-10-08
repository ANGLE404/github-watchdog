#!/usr/bin/env python3
# github-watchdog (linux) :: shared helpers for IP discovery / guard
import os, re, sys, time, socket, subprocess, json, datetime

BASE = "/opt/github-hosts"
CONFIG = BASE + "/src/config.yaml"
POOLS = BASE + "/dynamic-ips.json"
META_CACHE = BASE + "/meta-cache.json"
CA = "/root/.mitmproxy/mitmproxy-ca-cert.pem"
PROXY = "http://127.0.0.1:8180"
ASSETS_IP = "185.199.111.154"
UPLOADS_IP = "20.205.243.161"
LOCK = BASE + "/.healing"

# self-heal coordination: during a heal window the service is restarted several
# times; the 5-min health check must not mistake that churn for a real outage
# (that caused an oscillation storm). Guard/update hold this lock while healing.
STALE_LOCK = 300


def acquire_lock():
    try:
        if os.path.exists(LOCK):
            import time as _t
            if _t.time() - os.path.getmtime(LOCK) > STALE_LOCK:
                os.remove(LOCK)
            else:
                return False
        with open(LOCK, "w") as f:
            f.write(str(int(__import__("time").time())))
        return True
    except OSError:
        return True


def release_lock():
    try:
        os.remove(LOCK)
    except OSError:
        pass


def healing_active():
    if not os.path.exists(LOCK):
        return False
    import time as _t
    if _t.time() - os.path.getmtime(LOCK) > STALE_LOCK:
        return False
    return True

# service: name -> (proxy test url)
SERVICES = [
    ("github",   "https://github.com/robots.txt"),
    ("api",      "https://api.github.com/rate_limit"),
    ("codeload", "https://codeload.github.com/cli/cli/tar.gz/refs/heads/trunk"),
]

# static fallback pools (known-good GitHub IPv4)
STATIC = {
    "github":   ["20.205.243.166", "140.82.112.3", "140.82.113.3", "140.82.114.3", "140.82.116.3"],
    "api":      ["20.205.243.168", "140.82.112.6", "140.82.113.6", "140.82.116.6"],
    "codeload": ["20.205.243.165", "140.82.112.9", "140.82.113.9", "140.82.116.9"],
}


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def load_cfg_ips():
    """Return {github,api,codeload} current addresses, or None."""
    try:
        txt = open(CONFIG).read()
    except OSError:
        return None
    out = {}
    for name, host in [("github", "github.com"), ("api", "api.github.com"), ("codeload", "codeload.github.com")]:
        m = re.search(r"hosts:\s*\[%s\]\s*\n\s*sni:[^\n]*\n\s*address:\s*([0-9.]+):443" % re.escape(host), txt)
        if not m:
            return None
        out[name] = m.group(1)
    return out


def write_cfg(gh, api, codeload):
    txt = f"""---
# 自动生成 - github-hosts Linux 移植版 ({now()})
mappings:
- hosts: [github.com]
  sni: "_github.com"
  address: {gh}:443
- hosts: [api.github.com]
  sni: "_api.github.com"
  address: {api}:443
- hosts: [codeload.github.com]
  sni: "_codeload.github.com"
  address: {codeload}:443
- hosts: [uploads.github.com]
  sni: "_github.com"
  address: {UPLOADS_IP}:443
- hosts: [github.githubassets.com]
  sni: "_github.githubassets.com"
  address: {ASSETS_IP}:443
- hosts: ["*.githubusercontent.com"]
  sni: www.yelp.com
  address: www.yelp.com:443
"""
    tmp = CONFIG + ".new"
    open(tmp, "w").write(txt)
    os.replace(tmp, CONFIG)


def restart():
    subprocess.run(["systemctl", "restart", "github-hosts.service"], check=False)
    time.sleep(3.5)


def proxy_ok(url, timeout=20, retries=2):
    for i in range(retries):
        try:
            r = subprocess.run(
                ["curl", "-x", PROXY, "--cacert", CA, "-s", "-o", "/dev/null",
                 "--max-time", str(timeout), "-w", "%{http_code}", url],
                capture_output=True, text=True, timeout=timeout + 5)
            if r.stdout.strip() in ("200", "301", "302"):
                return True
        except Exception:
            pass
        if i < retries - 1:
            time.sleep(2)
    return False


def tcp_ms(ip, port=443, timeout=1.2):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.connect((ip, port))
        return int((time.time() - t0) * 1000)
    except Exception:
        return None
    finally:
        s.close()


def load_pools():
    pools = {k: list(v) for k, v in STATIC.items()}
    try:
        d = json.load(open(POOLS))
        for k, v in (d.get("pools") or {}).items():
            if k in pools:
                # dynamic first, then static (dedup)
                merged = list(v) + [x for x in pools[k] if x not in v]
                pools[k] = merged
    except Exception:
        pass
    return pools
