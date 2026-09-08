#!/bin/sh
set -e

VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP is required}"
TUN_IF="${TUN_IF:-tun0}"

nft -f - <<EOF
table inet killswitch {
  chain gewall {
    type filter hook forward priority filter; policy drop;
  }
  chain outwall {
    type filter hook output priority filter; policy accept;
  }
}
EOF

exec openvpn --config /etc/openvpn/client.ovpn \
  --script-security 2 \
  --route-up /usr/local/bin/killswitch-open.sh \
  --route-pre-down /usr/local/bin/killswitch-close.sh
