# VPN Egress Gateway

Routes selected Kubernetes pods through an OpenVPN tunnel with a hard kill
switch: if the tunnel drops, all external egress is blocked immediately.

Only pods annotated with `vpn.example.com/egress: "true"` are affected.
Everything else in the cluster is untouched.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Cluster                                                 │
│                                                         │
│  ┌──────────────┐     ┌──────────────────────────────┐  │
│  │ Annotated Pod │     │ Gateway Deployment            │  │
│  │              │     │                              │  │
│  │ routing-init │     │  fetchconfig (initContainer)  │  │
│  │   ┌────────┐ │     │  ↓ /etc/openvpn/client.ovpn  │  │
│  │   │ vxlan0 │─┼────→│  gateway Service ClusterIP    │  │
│  │   └────────┘ │     │  ↓ vxlan0                     │  │
│  │ app traffic  │     │  kill-switch (nftables)       │  │
│  └──────────────┘     │  ↓ MASQ                       │  │
│                       │  openvpn → tun0               │  │
│                       └──────────────┬───────────────┘  │
│                                      │                  │
└──────────────────────────────────────┼──────────────────┘
                                       │
                                       ▼
                              VPN Server / Internet
```

A mutating webhook injects a `routing-init` initContainer into annotated pods.
That container creates a `vxlan0` tunnel pointing at the gateway Service
ClusterIP and swaps the pod's default route to it, so external egress reaches
the gateway with the original destination intact. The gateway forwards it into
`tun0` with masquerade. The gateway pod runs OpenVPN behind an nftables
kill-switch: external egress is allowed only out `tun0`; when the tunnel is
down, all external egress is dropped. Cluster-internal traffic and
established/related connections are always allowed (the client pins
`CLUSTER_CIDR`/`GATEWAY_CIDR`/`VPN_SERVER_IP` routes to its real interface).

## Prerequisites

- **Cilium** CNI (kube-proxy replacement mode)
- **Talos** Linux nodes
- **cert-manager** installed and a `ClusterIssuer` available for webhook TLS

## Install

```bash
helm install vpn-egress-gateway deploy/helm \
  --set configURL=https://your-vpn-server/client.ovpn \
  --set vpnServerIP=203.0.113.10 \
  --set clusterCIDR=10.244.0.0/16 \
  --set gatewayCIDR=10.8.0.2/32 \
  --set webhook.issuer.name=<your-cluster-issuer>
```

`gatewayIP` defaults to the gateway Service FQDN
(`vpn-egress-gateway.<namespace>.svc.cluster.local`); the injected
`routing-init` container resolves it to the Service ClusterIP at pod start (the
vxlan remote needs a literal address, so it is never set manually), and no
manual bootstrap step is needed. To pin a specific address instead, pass
`--set gatewayIP=<cluster-ip>`.

### Helm Values

| Value | Description | Default |
|-------|-------------|---------|
| `registry` | Container image registry | `ghcr.io/example` |
| `tag` | Image tag | `latest` |
| `imagePullPolicy` | Pull policy | `IfNotPresent` |
| `configURL` | URL to download `.ovpn` client config | `""` (required) |
| `clusterCIDR` | Cluster pod/service CIDR | `10.244.0.0/16` |
| `gatewayCIDR` | Gateway tun interface CIDR | `10.8.0.2/32` |
| `vpnServerIP` | Remote VPN server IP | `""` (required) |
| `gatewayIP` | Gateway Service address (FQDN or literal ClusterIP) | `vpn-egress-gateway.<ns>.svc.cluster.local` |
| `vxlanID` | VXLAN network identifier | `1000` |
| `vxlanPort` | VXLAN UDP port (also the gateway Service port) | `4790` |
| `vxlanNet` | VXLAN subnet (gateway `.1`, clients `.2`; last octet must be `0`) | `10.255.0.0/16` |
| `tolerations` | Pod tolerations | `[]` |
| `vpnLogLevel` | OpenVPN log verbosity (0-11) | `1` |
| `dataCiphers` | OpenVPN `--data-ciphers` list | `AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC` |
| `gateway.image` | Gateway image name | `gateway` |
| `routingInit.image` | Routing-init image name | `routing-init` |
| `webhook.image` | Webhook image name | `vpn-egress-gateway` |
| `webhook.replicaCount` | Webhook replicas | `1` |
| `webhook.listenAddr` | Webhook listen address | `:8443` |
| `webhook.healthAddr` | Plaintext health/readiness listener | `:8080` |
| `webhook.annotationKey` | Opt-in annotation key | `vpn.example.com/egress` |
| `webhook.certName` | cert-manager Certificate name | `vpn-egress-webhook-cert` |
| `webhook.tlsSecretName` | TLS secret name | `vpn-egress-webhook-cert` |
| `webhook.issuer.name` | cert-manager ClusterIssuer | `vpn-egress-private-ca` |

## Opt-In Annotation

Pods opt in via the annotation key `webhook.annotationKey` (default
`vpn.example.com/egress`):

```yaml
metadata:
  annotations:
    vpn.example.com/egress: "true"
```

The webhook matches `Pod` create/update events and injects the routing
initContainer. Pods without the annotation are never touched.

The webhook serves `/healthz` (liveness) and `/readyz` (readiness) on the
plaintext `webhook.healthAddr` port. Readiness fails if the gateway address in
`GATEWAY_IP` does not resolve, so a broken redirect target takes the webhook
out of service instead of injecting a dead route.

## Kill Switch

The gateway pod runs an nftables ruleset that enforces an all-or-nothing
kill switch on external egress:

1. `established,related` connections are always accepted.
2. Cluster-internal traffic (`CLUSTER_CIDR`, `GATEWAY_CIDR`) is always accepted.
3. Traffic to the VPN server IP is always accepted.
4. When `tun0` is up: external egress is allowed only out `tun0`.
5. When `tun0` is down: all external egress is dropped.

If the tunnel goes down, cluster-internal traffic continues to work.
External egress from the pod is entirely blocked until the tunnel recovers.

## Cilium Masquerading Note

The gateway Service is a plain ClusterIP over the VXLAN UDP port
(`vxlanPort`); Cilium's kube-proxy replacement resolves it via eBPF, so client
`vxlan0` tunnels can target the Service name. Keep NAT single-ended:

- Masquerade is applied **only** on the tunnel leg (`postrouting` out `tun0`,
  `oifname tun0 masquerade`).
- The client→gateway VXLAN leg is not masqueraded; reply traversal relies on
  the gateway's conntrack reversing the tunnel SNAT.

The gateway pod needs `privileged: true` and `nftables`/`netfilter`
capability so nftables operates inside its own network namespace, plus
`iproute2` to create the `vxlan0` device. No host `ip_forward` is required.

## Troubleshooting

**Gateway pod is CrashLoopBackOff:**
Check the `fetchconfig` initContainer logs — the `.ovpn` download from
`CONFIG_URL` likely failed. Fix the URL or ensure the config file is served,
then restart.

**Annotated pod has no VPN routing:**
Ensure the annotation `vpn.example.com/egress: "true"` is present and the
webhook is running (`kubectl get deploy vpn-egress-webhook`). Inside the pod,
confirm `vxlan0` exists and is the default route (`ip route show`), and that
CLUSTER_CIDR/GATEWAY_CIDR/VPN_SERVER_IP routes still point at `eth0`.

Check the gateway Service ClusterIP resolves from the pod:
`getent hosts vpn-egress-gateway.<ns>.svc.cluster.local`.

**Egress works when it shouldn't (kill switch not enforced):**
Check that the gateway pod has the kill-switch nftables rules installed
(`nft list ruleset` in the gateway pod). Verify `tun0` is up.

**Webhook TLS errors:**
Check cert-manager Certificate status: `kubectl describe certificate vpn-egress-webhook-cert`. Ensure the ClusterIssuer exists and is ready.
