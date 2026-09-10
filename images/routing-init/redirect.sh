#!/bin/sh
set -e
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR required}"
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR required}"
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP required}"
VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP required}"

# nft needs an address literal; resolve a Service FQDN to its IPv4 ClusterIP first.
if ! echo "$GATEWAY_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    GATEWAY_IP="$(getent hosts "$GATEWAY_IP" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1; exit}')"
fi
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP could not be resolved from name}"

nft -f - <<EOF
table inet vpnroute {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } return
    ip daddr $VPN_SERVER_IP return
    ip daddr { 127.0.0.0/8, 169.254.0.0/16 } return
    dnat ip to $GATEWAY_IP
  }
}
EOF
