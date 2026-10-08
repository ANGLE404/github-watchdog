#!/bin/bash
# github-watchdog (linux) :: start
set -u
systemctl start github-hosts.service
systemctl start github-hosts-update.timer github-hosts-health.timer github-hosts-guard.timer github-hosts-mirror.timer 2>/dev/null
echo "github-hosts started."
systemctl --no-pager --quiet is-active github-hosts.service
