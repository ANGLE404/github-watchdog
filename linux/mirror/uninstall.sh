#!/bin/bash
# github-watchdog (linux) :: mirror :: uninstall
set -u
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
bash "$HERE/gh-apply.sh" --off
systemctl disable --now github-hosts-mirror.timer 2>/dev/null || true
rm -f /etc/systemd/system/github-hosts-mirror.service /etc/systemd/system/github-hosts-mirror.timer
systemctl daemon-reload
rm -f /etc/profile.d/github-mirror.sh /usr/local/bin/git
echo "Uninstalled. git goes direct."
