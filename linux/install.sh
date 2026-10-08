#!/bin/bash
# =============================================================================
#  github-watchdog (linux) :: top-level installer
#  Installs the domain-fronting mitmproxy accelerator + IP self-healing guard
#  + git mirror module on a Debian/Ubuntu host. Run as root.
#
#  Usage:  sudo bash install.sh
#          (override base with GH_BASE=/opt/github-hosts)
# =============================================================================
set -eu
BASE="${GH_BASE:-/opt/github-hosts}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

[ "$(id -u)" = "0" ] || { echo "run as root (sudo bash install.sh)"; exit 1; }

echo "== 1) layout =="
mkdir -p "$BASE/src" "$BASE/mirror/bin" "$BASE/venv"

echo "== 2) core plugin + config =="
install -m 644 "$HERE/core/github-hosts.py" "$BASE/src/github-hosts.py"
[ -f "$BASE/src/config.yaml" ] || install -m 644 "$HERE/core/config.yaml" "$BASE/src/config.yaml"

echo "== 3) python venv + mitmproxy =="
if [ ! -x "$BASE/venv/bin/mitmdump" ]; then
  python3 -m venv "$BASE/venv"
  "$BASE/venv/bin/pip" install -U pip >/dev/null
  "$BASE/venv/bin/pip" install "mitmproxy==10.4.2"
fi

echo "== 4) self-healing scripts =="
install -m 755 "$HERE/ghcommon.py"  "$BASE/ghcommon.py"
install -m 755 "$HERE/update_ips.py" "$BASE/update_ips.py"
install -m 755 "$HERE/guard.py"     "$BASE/guard.py"
install -m 755 "$HERE/selfcheck.sh" "$BASE/selfcheck.sh"
install -m 755 "$HERE/start.sh"     "$BASE/start.sh"
install -m 755 "$HERE/stop.sh"      "$BASE/stop.sh"
install -m 755 "$HERE/status.sh"    "$BASE/status.sh"

echo "== 5) systemd units =="
cp "$HERE"/systemd/*.service "$HERE"/systemd/*.timer /etc/systemd/system/
systemctl daemon-reload

echo "== 6) start service once to mint the CA =="
systemctl enable github-hosts.service
systemctl restart github-hosts.service
sleep 5

CA=/root/.mitmproxy/mitmproxy-ca-cert.pem
if [ -f "$CA" ]; then
  install -m 644 "$CA" /usr/local/share/ca-certificates/mitmproxy-ca-cert.crt
  update-ca-certificates >/dev/null 2>&1 || true
  echo "   CA trusted"
fi

echo "== 7) timers =="
systemctl enable --now github-hosts-update.timer github-hosts-health.timer github-hosts-guard.timer

echo "== 8) system proxy profile.d =="
install -m 644 "$HERE/profile.d/github-proxy.sh" /etc/profile.d/github-proxy.sh

echo "== 9) git mirror module =="
install -m 755 "$HERE/mirror/gh-fastest.sh" "$HERE/mirror/gh-apply.sh" "$HERE/mirror/ghdl" "$HERE/mirror/install.sh" "$HERE/mirror/uninstall.sh" "$BASE/mirror/"
install -m 755 "$HERE/mirror/bin/git" "$BASE/mirror/bin/git"
install -m 644 "$HERE/mirror/mirrors.txt" "$BASE/mirror/mirrors.txt"
bash "$BASE/mirror/install.sh"

echo "== 10) CLI helpers =="
ln -sf "$BASE/start.sh"  /usr/local/bin/gh-start
ln -sf "$BASE/stop.sh"   /usr/local/bin/gh-stop
ln -sf "$BASE/status.sh" /usr/local/bin/gh-status

echo ""
echo "Done. Run: gh-status   (or bash $BASE/selfcheck.sh)"
