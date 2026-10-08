#!/usr/bin/env python3
# github-watchdog (linux) :: guard.py
# Every run: proxy-test the GitHub links. If an IP-mapped service fails, walk its
# candidate pool, restart+verify, keep first working; if all fail, rollback.
import sys, os, json, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ghcommon import (BASE, load_cfg_ips, write_cfg, restart, proxy_ok,
                      load_pools, now, acquire_lock, release_lock)

LOG = BASE + "/guard.log"

# links checked via proxy (name -> url). IP-mapped ones are auto-healable.
LINKS = [
    ("github",   "https://github.com/robots.txt"),
    ("api",      "https://api.github.com/rate_limit"),
    ("codeload", "https://codeload.github.com/cli/cli/tar.gz/refs/heads/trunk"),
    ("raw",      "https://raw.githubusercontent.com/cli/cli/trunk/README.md"),
    ("assets",   "https://github.githubassets.com/favicons/favicon.svg"),
    ("pages",    "https://jquery.github.io/"),
]
HEALABLE = ("github", "api", "codeload")


def log(msg):
    line = f"{now()}  {msg}"
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            os.remove(LOG)
        open(LOG, "a").write(line + "\n")
    except OSError:
        pass
    print(line)


def main():
    if not acquire_lock():
        log("another heal is in progress -> skip")
        return 0
    try:
        return _run()
    finally:
        release_lock()


def _run():
    url_of = dict(LINKS)
    bad = [n for n, u in LINKS if not proxy_ok(u)]
    ok = [n for n, _ in LINKS if n not in bad]
    log(f"ok={ok} bad={bad}")
    if not bad:
        return 0

    target = [n for n in bad if n in HEALABLE]
    if not target:
        log("no auto-healable link failed (raw/assets/pages require manual attention)")
        return 0

    cur = load_cfg_ips()
    if not cur:
        log("config.yaml unparseable -> abort heal")
        return 3
    pools = load_pools()
    orig = dict(cur)
    healed_any = False

    for name in target:
        pool = [ip for ip in pools.get(name, []) if ip != cur.get(name)]
        if not pool:
            log(f"{name}: no alternate candidate")
            continue
        for ip in pool:
            cand = dict(cur)
            cand[name] = ip
            write_cfg(cand["github"], cand["api"], cand["codeload"])
            restart()
            if proxy_ok(url_of[name]):
                cur = cand
                healed_any = True
                log(f"{name}: healed -> {ip}")
                break
            log(f"{name}: {ip} failed verify")
        else:
            log(f"{name}: all candidates failed; restoring original")
            cur[name] = orig[name]
            write_cfg(cur["github"], cur["api"], cur["codeload"])
            restart()

    # guard also keeps the mirror fresh opportunistically (best effort)
    return 0 if not healed_any else 0


if __name__ == "__main__":
    sys.exit(main())
