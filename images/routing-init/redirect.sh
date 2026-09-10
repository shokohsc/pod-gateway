#!/bin/sh
set -e
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR required}"
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR required}"
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP required}"
VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP required}"
VXLAN_ID="${VXLAN_ID:?VXLAN_ID required}"
VXLAN_PORT="${VXLAN_PORT:?VXLAN_PORT required}"
VXLAN_NET="${VXLAN_NET:?VXLAN_NET required}"

# The vxlan remote needs a literal IPv4: resolve the gateway Service FQDN to its
# ClusterIP rather than configuring an address manually.
if ! echo "$GATEWAY_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    GATEWAY_IP="$(getent hosts "$GATEWAY_IP" | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1; exit}')"
fi
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP could not be resolved from name}"

# Derived addresses inside the vxlan subnet (network's last octet must be 0).
prefix="${VXLAN_NET#*/}"
net="${VXLAN_NET%/*}"
gw_ip="${net%.*}.1"
client_ip="${net%.*}.2"

# Pin cluster-internal traffic to the real interface before the default route
# moves to vxlan0.
gw="$(ip route show default | awk '{print $3; exit}')"
gw_dev="$(ip route show default | awk '{print $5; exit}')"
ip route replace "$CLUSTER_CIDR" via "$gw" dev "$gw_dev"
ip route replace "$GATEWAY_CIDR" via "$gw" dev "$gw_dev"
ip route replace "$VPN_SERVER_IP" via "$gw" dev "$gw_dev"

ip link add vxlan0 type vxlan id "$VXLAN_ID" dev "$gw_dev" remote "$GATEWAY_IP" dstport "$VXLAN_PORT"
ip link set vxlan0 up
ip addr add "$client_ip/$prefix" dev vxlan0
bridge fdb append 00:00:00:00:00:00 dst "$GATEWAY_IP" dev vxlan0
ip route replace default via "$gw_ip" dev vxlan0