#!/bin/sh
set -eu
out="/etc/openvpn/client.ovpn"
CONFIG_URL="${CONFIG_URL:?CONFIG_URL required}"
curl -fSL --retry 3 --retry-delay 2 -o "$out" "$CONFIG_URL"
test -s "$out"
