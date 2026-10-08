#!/bin/bash
# github-watchdog (linux) :: selfcheck  (extended: ~19 checks + self-heal)
CA=/root/.mitmproxy/mitmproxy-ca-cert.pem
PROXY="http://127.0.0.1:8180"
BASE=/opt/github-hosts
PASS=0; FAIL=0; FAILED=""
ok()  { PASS=$((PASS+1)); printf "  [ OK ] %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED $2"; printf "  [FAIL] %s\n" "$1"; }
http() { curl -x "$PROXY" --cacert "$CA" -s -o /dev/null --max-time 25 -w '%{http_code}' "$1"; }
chk_http() { local c; c=$(http "$2"); [ "$c" = "200" ] && ok "$1 ($c)" || bad "$1 (code=$c)" "$3"; }

echo "==== github-hosts selfcheck  $(date '+%F %T') ===="
echo "-- connectivity (via proxy) --"
chk_http "github.com"          "https://github.com/robots.txt"                                     github
chk_http "api.github.com"      "https://api.github.com/rate_limit"                                api
chk_http "codeload.github.com" "https://codeload.github.com/cli/cli/tar.gz/refs/heads/trunk"      codeload
chk_http "raw.githubusercontent" "https://raw.githubusercontent.com/cli/cli/trunk/README.md"      raw
chk_http "githubassets"        "https://github.githubassets.com/favicons/favicon.svg"             assets
chk_http "github pages"        "https://jquery.github.io/"                                        pages

echo "-- service / proxy --"
systemctl --quiet is-active github-hosts.service && ok "github-hosts.service active" || bad "github-hosts.service inactive" svc
ss -ltn 2>/dev/null | grep -q ':8180' && ok "mitmproxy port 8180 listening" || bad "port 8180 down" port
[ -f "$CA" ] && ok "mitmproxy CA present" || bad "mitmproxy CA missing" ca

echo "-- systemd timers --"
for t in update health guard mirror; do
  systemctl --quiet is-enabled github-hosts-$t.timer 2>/dev/null && ok "timer $t enabled" || bad "timer $t disabled" "timer_$t"
done

echo "-- git / mirror --"
which git 2>/dev/null | grep -q "/opt/github-hosts/mirror/bin/git" && ok "git shim active" || bad "git shim NOT in PATH" shim
git config --global --list 2>/dev/null | grep -q 'url.https://.*github.com/.insteadof' && ok "git global mirror applied" || bad "git global mirror missing" gmirror
if git config --system --list 2>/dev/null | grep -q 'url\.'; then bad "legacy system url keys remain" legacy; else ok "legacy system url keys cleared"; fi
n=$(/usr/bin/python3 -c 'import json;print(len(json.load(open("/opt/github-hosts/mirror/mirrors-ranked.json"))["ranked"]))' 2>/dev/null || echo 0)
[ "${n:-0}" -ge 1 ] && ok "mirror ranked sources = $n" || bad "no ranked mirrors" ranked
[ -f /etc/profile.d/github-proxy.sh ] && ok "system proxy profile.d present" || bad "profile.d proxy missing" profiled

echo "-- ssh --"
ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | grep -q "successfully authenticated" \
  && ok "SSH auth to github.com" || bad "SSH auth failed" ssh

echo "---- summary: PASS=$PASS FAIL=$FAIL ----"
if [ "$FAIL" -gt 0 ]; then
  echo "$(date '+%F %T') 健康检查失败:$FAILED -> 重刷IP并重启"
  /usr/bin/python3 $BASE/update_ips.py
  systemctl restart github-hosts.service
  exit 1
fi
echo "$(date '+%F %T') ALL OK"
exit 0
