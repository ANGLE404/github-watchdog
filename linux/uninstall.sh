#!/bin/bash
# =============================================================================
#  github-watchdog (linux) :: top-level uninstaller. Run as root.
# =============================================================================
set -u
BASE="${GH_BASE:-/opt/github-hosts}"

[ "$(id -u)" = "0" ] || { echo "run as root"; exit 1; }

echo "== stop timers + service =="
systemctl disable --now github-hosts-update.timer github-hosts-health.timer github-hosts-guard.timer github-hosts-mirror.timer 2>/dev/null
systemctl disable --now github-hosts.service 2>/dev/null
rm -f /etc/systemd/system/github-hosts*.service /etc/systemd/system/github-hosts*.timer
systemctl daemon-reload

echo "== git mirror off =="
[ -x "$BASE/mirror/gh-apply.sh" ] && bash "$BASE/mirror/gh-apply.sh" --off 2>/dev/null

echo "== remove files =="
rm -f /usr/local/bin/git /usr/local/bin/gh-start /usr/local/bin/gh-stop /usr/local/bin/gh-status
rm -f /etc/profile.d/github-mirror.sh /etc/profile.d/github-proxy.sh
rm -f /usr/local/share/ca-certificates/mitmproxy-ca-cert.crt
update-ca-certificates >/dev/null 2>&1 || true
rm -rf "$BASE"

echo "Uninstalled. git goes direct."
