#!/bin/bash
# github-watchdog (linux) :: status
set -u
BASE=/opt/github-hosts
echo "================ github-hosts status ================"
echo "[service]"; systemctl --no-pager --quiet is-active github-hosts.service 2>/dev/null || echo inactive
echo "[timers]"
for t in github-hosts-update github-hosts-health github-hosts-guard github-hosts-mirror; do
  printf "  %-26s %s / %s\n" "$t" "$(systemctl is-enabled $t.timer 2>/dev/null || echo -)" "$(systemctl is-active $t.timer 2>/dev/null || echo -)"
done
echo "[proxy]"; (ss -ltnp 2>/dev/null | grep -q ':8180' && echo "  8180 listening") || echo "  8180 DOWN"
echo "[config ips]"; /usr/bin/python3 - "$BASE/src/config.yaml" <<'PY'
import re,sys
try: t=open(sys.argv[1]).read()
except OSError: print("  (no config)"); raise SystemExit
for host in ["github.com","api.github.com","codeload.github.com"]:
    m=re.search(r"hosts:\s*\[%s\]\s*\n\s*sni:[^\n]*\n\s*address:\s*([^\n]+)"%re.escape(host),t)
    print(f"  {host:24s} -> {m.group(1).strip() if m else '??'}")
PY
echo "[mirror]"; bash $BASE/mirror/gh-apply.sh --status 2>/dev/null | sed 's/^/  /'
echo "[pools]"; /usr/bin/python3 - <<'PY'
import json
try: d=json.load(open("/opt/github-hosts/dynamic-ips.json"))
except Exception: print("  (none)"); raise SystemExit
print("  updated:",d.get("updated"))
for k,v in d.get("pools",{}).items(): print(f"  {k:10s} {len(v)} candidates  {v[:4]}")
PY
echo "[last guard/update]"
tail -n 3 $BASE/guard.log 2>/dev/null | sed 's/^/  guard: /'
tail -n 3 $BASE/update-ips.log 2>/dev/null | sed 's/^/  update: /'
echo "====================================================="
