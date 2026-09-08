#!/bin/sh
set -e
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR required}"
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR required}"
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP required}"
VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP required}"

nft -f - <<EOF
table inet vpnroute {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } return
    ip daddr != { $VPN_SERVER_IP } dnat to $GATEWAY_IP
  }
}
EOF
