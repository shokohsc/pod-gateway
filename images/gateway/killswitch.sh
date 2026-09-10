#!/bin/sh
set -e

VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP is required}"
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR is required}"
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR is required}"
CLUSTER_SERVICES_CIDR="${CLUSTER_SERVICES_CIDR:?CLUSTER_SERVICES_CIDR is required}"
VXLAN_ID="${VXLAN_ID:?VXLAN_ID is required}"
VXLAN_PORT="${VXLAN_PORT:?VXLAN_PORT is required}"
VXLAN_NET="${VXLAN_NET:?VXLAN_NET is required}"
TUN_IF="$(printf '%s' "${TUN_IF:-tun0}" | tr -d '"')"
VPN_LOG_LEVEL="${VPN_LOG_LEVEL:-1}"
DATA_CIPHERS="${DATA_CIPHERS:-AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC}"

# Fetch a fresh client config every container start, so a VPN-drop restart
# re-downloads it instead of reusing the previous one.
CONFIG_URL="${CONFIG_URL:-}"
if [ -n "$CONFIG_URL" ]; then
  /usr/local/bin/fetchconfig.sh
fi

# vxlan0 receives client egress (original dst intact) and forwards it into the tunnel.
# A container restart reuses the pod netns, so clean up any vxlan0 from a previous run.
gw_if="$(ip route show default | awk '{print $5; exit}')"
gw_ip="$(ip route show default | awk '{print $3; exit}')"
ip link del vxlan0 2>/dev/null || true
ip link add vxlan0 type vxlan id "$VXLAN_ID" dev "$gw_if" dstport "$VXLAN_PORT"
ip link set vxlan0 up
net="${VXLAN_NET%/*}"
prefix="${VXLAN_NET#*/}"
ip addr replace "${net%.*}.1/$prefix" dev vxlan0
sysctl -w net.ipv4.ip_forward=1

# Cluster-internal service traffic (DNS ClusterIPs, etc.) must not ride the tunnel:
# the tunnel's pushed default-route would swallow it. Route it via a table that uses
# the real interface, for both locally-generated and vxlan-forwarded traffic.
ip route replace default via "$gw_ip" dev "$gw_if" table 100
ip rule add priority 100 to "$CLUSTER_SERVICES_CIDR" lookup 100 2>/dev/null || true

nft -f - <<EOF
table inet killswitch {
  chain gewall {
    type filter hook forward priority filter; policy drop;
    ct state established,related accept
    ip saddr { $CLUSTER_CIDR, $GATEWAY_CIDR } accept
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR, $CLUSTER_SERVICES_CIDR } accept
    ip daddr $VPN_SERVER_IP accept
  }
  chain outwall {
    type filter hook output priority filter; policy accept;
  }
  chain natwall {
    type nat hook postrouting priority srcnat; policy accept;
    oifname $TUN_IF masquerade
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
  --data-ciphers "$DATA_CIPHERS" \
  --verb "$VPN_LOG_LEVEL"
