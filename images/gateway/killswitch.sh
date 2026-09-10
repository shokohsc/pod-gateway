#!/bin/sh
set -e

VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP is required}"
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR is required}"
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR is required}"
TUN_IF="${TUN_IF:-tun0}"
VPN_LOG_LEVEL="${VPN_LOG_LEVEL:-1}"

nft -f - <<EOF
table inet killswitch {
  chain gewall {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ip saddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr $VPN_SERVER_IP accept
  }
  chain outwall {
    type filter hook output priority filter; policy accept;
  }
}
EOF

exec openvpn --config /etc/openvpn/client.ovpn \
  --cd /etc/openvpn \
  --auth-nocache \
  --pull-filter ignore ifconfig-ipv6 \
  --pull-filter ignore route-ipv6 \
  --script-security 2 \
  --up-restart \
  --route-up /usr/local/bin/killswitch-open.sh \
  --route-pre-down /usr/local/bin/killswitch-close.sh \
  --verb "$VPN_LOG_LEVEL"
