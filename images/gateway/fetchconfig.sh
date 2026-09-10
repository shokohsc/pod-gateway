#!/bin/sh
set -eu
out="${OUT:-/etc/openvpn/client.ovpn}"
CONFIG_URL="${CONFIG_URL:?CONFIG_URL required}"
if command -v wget >/dev/null 2>&1; then
    wget -q --tries=3 -O "$out" "$CONFIG_URL"
else
    curl -fSL --retry 3 --retry-delay 2 -o "$out" "$CONFIG_URL"
fi
test -s "$out"

# Harden the client config: fail on auth errors, fast server/connect timeouts,
# replay protection, and quiet replay warnings.
cat >> "$out" <<'EOF'
auth-retry none
server-poll-timeout 5
connect-timeout 5
replay-window 64 15
mute-replay-warnings
EOF
