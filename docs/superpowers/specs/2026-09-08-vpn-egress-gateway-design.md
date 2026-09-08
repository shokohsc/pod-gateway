# VPN Egress Gateway — Design Spec

Date: 2026-09-08
Status: Draft

## Problem

Pods in a Cilium/Talos Kubernetes cluster need to reach the internet through
an OpenVPN client, with a hard guarantee that if the VPN tunnel drops, no
traffic leaks out over the plain network (a "kill switch").

Only pods explicitly annotated as using the gateway are routed through it.
The rest of the cluster is untouched.

## Goals

- Annotated pods get their external egress routed through an OpenVPN tunnel.
- If the tunnel goes down, external egress is entirely blocked (kill
  switch). All-or-nothing: no partial leak window.
- Cluster-internal traffic (services, API server, node ranges) is never
  affected by the redirect or the kill switch.
- Works on a Cilium CNI on Talos nodes.

## Non-Goals

- No real VPN credentials or endpoints in the repo. The `.ovpn` is fetched
  at runtime from a remote URL supplied via config.
- No support for multiple independent VPN providers in this first version
  (configurable via a single remote config URL).
- No per-pod VPN selection beyond a single gateway; one gateway deployment.

## Components

### 1. Gateway Deployment + Service

- A `Deployment` running one container, `openvpn`, plus an nftables
  supervisor.
- `initContainer` downloads the `.ovpn` client config from the remote config
  URL (set via env/config) into a shared `emptyDir`.
- Main container runs `openvpn --config` creating `tun0`.
- A stable `ClusterIP` `Service` fronts the deployment. Its ClusterIP is the
  redirect target that client initContainers use.

### 2. Kill-Switch nftables Ruleset (gateway pod netns)

The safety core. Installed in the gateway pod's network namespace by a
supervisor container that watches tunnel state and applies the ruleset.
Order matters:

1. Accept `established,related`.
2. Accept VPN tunnel traffic: UDP/TCP to the configured VPN server IP, on
   the tunnel.
3. Accept cluster-internal ranges and node/routable ranges. These are never
   "external egress" and must keep working whether or not the tunnel is up.
4. Default: allow external egress **only** out `tun0`.
5. When `tun0` is down: drop all external egress (the kill switch). Cluster
   traffic in rule 3 continues to work.

The supervisor only opens external egress while the tunnel is actually up,
so a dropped connection means dropped traffic, not a leak.

### 3. Mutating Webhook

- An admission controller (`admission/v1`) deployed as a small Deployment +
  `Service`.
- Matches `Pod` create/update events where the pod carries the gateway
  annotation, e.g. `vpn.example.com/egress: "true"`.
- Injects the routing initContainer (component 4) into the pod.
- Serves TLS on the webhook Service; registered via a
  `MutatingWebhookConfiguration`. Certificates provisioned with cert-manager
  (a `Certificate` resource + CA bundle), which is standard for and works
  with Talos/Cilium clusters.

### 4. Client Routing initContainer

- Injected only into annotated pods by the webhook.
- Runs once, in the pod's network namespace, before the app starts.
- Installs nftables rules that redirect non-cluster outbound traffic to the
  gateway Service ClusterIP.
- Excludes cluster-internal ranges, the VPN server IP, and localhost from the
  redirect so in-cluster traffic and the tunnel are unaffected.

## Data Flow

```
[annotated pod]
   app sends to external dest
   --> nftables (initContainer): redirect default external egress
   --> gateway Service ClusterIP
   --> gateway pod netns
       --> kill-switch nftables: allow only out tun0
       --> openvpn tun0
       --> VPN server / internet
```

Cluster-internal traffic bypasses the redirect entirely and stays in the
cluster. If tun0 drops, the gateway's kill-switch ruleset drops external
egress; cluster-internal traffic is unaffected.

## Cilium / Talos Notes

- Cilium's kube-proxy replacement handles the ClusterIP Service, so the
  redirect target is reachable and load-balanced across gateway backends.
- Because forwarding happens in the gateway pod's own network namespace
  (not on the host), no host `net.ipv4.ip_forward` is required.
- Masquerading: the redirect and the tunnel NAT must not double-mangle
  traffic; document the expected configuration so redirected client traffic
  is source-NAT'd only on the tunnel egress.
- The webhook's CA bundle must be trusted by the API server. In a
  Cilium/Talos setup cert-manager + the cluster's trusted CA path is used.

## Error Handling

- Config download failure: gateway initContainer fails loudly; gateway Pod
  is CrashLoopBackOff (visible), client pods still function (no redirect
  installed until annotation + successful webhook), external egress simply
  isn't tunneled.
- Tunnel drops: kill switch enforces all-or-nothing egress block.
- Webhook injection failure: pod admission fails; must not silently create a
  pod that thinks it's VPN-routed but isn't.

## Testing Strategy

- Unit tests for the kill-switch nftables rule ordering (drop-before-open
  logic) via a small test harness.
- Unit tests for the webhook's mutation logic (matches annotation,
  injects correct initContainer, excludes cluster ranges from redirect).
- An end-to-end smoke test in a cluster: run a pod with the annotation,
  verify external egress exits via the tunnel and is blocked when the tunnel
  is stopped.
