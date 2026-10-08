#!/usr/bin/env python3
# github-watchdog (linux) :: update_ips.py
# Discover GitHub IPv4 candidate pools (Meta API -> third-party seeds -> doh.pub),
# TCP:443 test them, write dynamic-ips.json, then apply the best per service with
# end-to-end proxy verification and rollback.
import sys, os, json, time, subprocess, ipaddress
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ghcommon import (BASE, CONFIG, POOLS, META_CACHE, PROXY, CA,
                      SERVICES, STATIC, write_cfg, load_cfg_ips, restart,
                      proxy_ok, tcp_ms, now, acquire_lock, release_lock)

THIRDPARTY = [
    "https://raw.hellogithub.com/hosts",
    "https://raw.githubusercontent.com/521xueweihan/GitHub520/main/hosts",
]
LOG = BASE + "/update-ips.log"


def log(msg):
    line = f"{now()}  {msg}"
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            os.remove(LOG)
        open(LOG, "a").write(line + "\n")
    except OSError:
        pass
    print(line)


def curl(url, proxy=False, timeout=25):
    args = ["curl", "-s", "--max-time", str(timeout), "-H", "User-Agent: github-hosts",
            "-H", "Accept: application/vnd.github+json"]
    if proxy:
        args += ["-x", PROXY, "--cacert", CA]
    else:
        args += ["--noproxy", "*"]
    args.append(url)
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout + 5)
        return r.stdout
    except Exception:
        return ""


def get_meta():
    for url, via in [("https://api.github.com/meta", True),
                     ("https://api.github.com/meta", False),
                     ("https://gh-proxy.com/https://api.github.com/meta", False),
                     ("https://ghproxy.net/https://api.github.com/meta", False)]:
        j = curl(url, proxy=via)
        try:
            d = json.loads(j)
            if d.get("web") or d.get("api") or d.get("pages"):
                log(f"meta OK ({'proxy' if via else 'direct'}): {url}")
                try:
                    open(META_CACHE, "w").write(j)
                except OSError:
                    pass
                return d
        except Exception:
            pass
    if os.path.exists(META_CACHE):
        log("meta fallback: local cache")
        return json.load(open(META_CACHE))
    log("meta unavailable")
    return None


def ranges24(cidrs, drop_pages=True):
    out = []
    for c in cidrs or []:
        if ":" in c:
            continue
        if drop_pages and c.startswith("185.199."):
            continue
        try:
            net = ipaddress.ip_network(c, strict=False)
        except ValueError:
            continue
        if net.prefixlen == 32:
            out.append(str(net.network_address))
        elif net.prefixlen <= 24:
            pref = max(net.prefixlen, 16)
            try:
                n = ipaddress.ip_network(f"{net.network_address}/{pref}", strict=False)
            except ValueError:
                continue
            for i, sub in enumerate(n.subnets(new_prefix=24)):
                if i >= 32:
                    break
                out.append(str(sub.network_address))
    return out


def candidates(base24, last_octets, cap=32):
    out = []
    for b in base24:
        if "." not in b or b.count(".") != 3:
            # single host
            out.append(b)
            continue
        for lo in last_octets:
            ip = b.rsplit(".", 1)[0] + "." + lo
            if ip not in out:
                out.append(ip)
        if len(out) >= cap:
            break
    return out[:cap]


def thirdparty_seeds():
    seeds = {}
    for url in THIRDPARTY:
        txt = curl(url, proxy=True) or curl(url, proxy=False)
        if not txt:
            continue
        n = 0
        for line in txt.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[0].count(".") == 3 and parts[0][0].isdigit():
                seeds.setdefault(parts[1].lower(), []).append(parts[0])
                n += 1
        log(f"thirdparty {url}: {n} lines")
    return seeds


def doh_resolve(name):
    j = curl(f"https://doh.pub/dns-query?name={name}&type=A")
    try:
        d = json.loads(j)
        return [a["data"] for a in d.get("Answer", []) if a.get("type") == 1]
    except Exception:
        return []


def main():
    if not acquire_lock():
        log("another heal is in progress -> skip")
        return 0
    try:
        return _run()
    finally:
        release_lock()


def _run():
    meta = get_meta()
    if not meta:
        log("no meta and no cache -> abort")
        return 2

    seeds = thirdparty_seeds()
    web = (meta.get("web") or []) + (meta.get("git") or [])
    spec = {
        "github":   (ranges24(web), ["3"], ["github.com"]),
        "api":      (ranges24((meta.get("api") or []) + (meta.get("web") or [])), ["6"], ["api.github.com"]),
        "codeload": (ranges24((meta.get("git") or []) + (meta.get("web") or [])), ["9"], ["codeload.github.com"]),
    }

    pools = {}
    for name, (base24, last, domains) in spec.items():
        cand = []
        for dom in domains:
            for ip in seeds.get(dom, []):
                if ip not in cand:
                    cand.append(ip)
        for ip in candidates(base24, last):
            if ip not in cand:
                cand.append(ip)
        # doh.pub fallback seeds
        for dom in domains:
            for ip in doh_resolve(dom):
                if ip not in cand:
                    cand.append(ip)
        cand = cand[:24]
        good = []
        for ip in cand:
            ms = tcp_ms(ip)
            if ms is not None:
                good.append((ms, ip))
        good.sort()
        pools[name] = [ip for _, ip in good]
        log(f"{name}: {len(cand)} candidates, {len(pools[name])} reachable -> {pools[name][:6]}")

    json.dump({"updated": now(), "source": "api.github.com/meta", "pools": pools},
              open(POOLS, "w"), indent=1)

    # ---- apply best per service with verify + rollback ----
    cur = load_cfg_ips()
    if not cur:
        log("config.yaml unparseable -> skip apply")
        return 3
    orig = dict(cur)
    changed = False
    for name, _url in SERVICES:
        if name in cur and pools.get(name) and cur[name] == pools[name][0]:
            continue
        pool = pools.get(name) or [cur[name]]
        for ip in pool:
            cur[name] = ip
            write_cfg(cur["github"], cur["api"], cur["codeload"])
            restart()
            if proxy_ok(dict(SERVICES)[name]):
                changed = True
                log(f"{name}: switched to {ip} OK")
                break
            else:
                log(f"{name}: {ip} failed verify")
        else:
            log(f"{name}: all candidates failed -> keep {orig[name]}")
            cur[name] = orig[name]
    write_cfg(cur["github"], cur["api"], cur["codeload"])
    restart()
    log("update_ips done; cfg=" + json.dumps(cur))
    return 0


if __name__ == "__main__":
    sys.exit(main())
