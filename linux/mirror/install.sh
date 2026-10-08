#!/bin/bash
# =============================================================================
#  github-watchdog (linux) :: mirror :: install
#  - pick fastest mirror now + write global git config (root)
#  - install git shim (/usr/local/bin/git) + PATH hook (/etc/profile.d)
#  - register systemd timer github-hosts-mirror.timer (daily --refresh)
#  Run as root.
# =============================================================================
set -eu
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
chmod +x "$HERE/gh-fastest.sh" "$HERE/gh-apply.sh" "$HERE/ghdl" "$HERE/bin/git" 2>/dev/null || true

# 1) PATH hook so `git` hits the shim in every login shell
cat > /etc/profile.d/github-mirror.sh <<'EOF'
# github-watchdog mirror: prepend git shim
if [ -d /opt/github-hosts/mirror/bin ] && ! echo ":$PATH:" | grep -q ":/opt/github-hosts/mirror/bin:"; then
  PATH="/opt/github-hosts/mirror/bin:$PATH"
  export PATH
fi
EOF

# 2) install shim as /usr/local/bin/git (symlink)
ln -sf "$HERE/bin/git" /usr/local/bin/git

# 3) pick fastest + apply
bash "$HERE/gh-apply.sh" --apply

# 4) systemd daily refresh
cat > /etc/systemd/system/github-hosts-mirror.service <<EOF
[Unit]
Description=github-watchdog mirror: refresh fastest git mirror
After=network-online.target github-hosts.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $HERE/gh-apply.sh --refresh
EOF

cat > /etc/systemd/system/github-hosts-mirror.timer <<'EOF'
[Unit]
Description=Daily refresh of fastest GitHub mirror

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now github-hosts-mirror.timer

echo ""
echo "Done. New login shells get the git shim; current shell: export PATH=/opt/github-hosts/mirror/bin:\$PATH"
echo "Manage: gh-apply.sh --status | --auto | --off    gh-fastest.sh --top 8    ghdl <url>"
