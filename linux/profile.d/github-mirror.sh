# github-watchdog mirror: prepend git shim
if [ -d /opt/github-hosts/mirror/bin ] && ! echo ":$PATH:" | grep -q ":/opt/github-hosts/mirror/bin:"; then
  PATH="/opt/github-hosts/mirror/bin:$PATH"
  export PATH
fi
