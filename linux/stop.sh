#!/bin/bash
# github-watchdog (linux) :: stop
set -u
systemctl stop github-hosts.service
systemctl stop github-hosts-update.timer github-hosts-health.timer github-hosts-guard.timer github-hosts-mirror.timer 2>/dev/null
echo "github-hosts stopped."
