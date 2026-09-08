# VPN Egress Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Kubernetes pod gateway running an OpenVPN client with an nftables kill switch, plus a mutating webhook that routes annotated client pods' external egress through it, on a Cilium/Talos cluster.

**Architecture:** Four components: (1) a gateway Deployment+Service running `openvpn` (tun0) with a kill-switch nftables supervisor in its netns; (2) an initContainer that downloads the `.ovpn` from a remote URL; (3) a mutating admission webhook that injects (4) a routing initContainer into annotated pods, which redirects their external egress to the gateway's ClusterIP. Cluster-internal traffic is excluded from the redirect and never affected by the kill switch.

**Tech Stack:** Go (admission webhook, `sigs.k8s.io/controller-runtime` or stdlib `admission/v1` + `apimachinery`), shell/nftables, Docker, Helm or raw manifests, cert-manager.

**Spec:** `docs/superpowers/specs/2026-09-08-vpn-egress-gateway-design.md`

## Global Constraints

- Zero real VPN credentials or endpoints in the repo. The `.ovpn` is fetched at runtime from a remote URL supplied via config/env.
- Works on a Cilium CNI on Talos nodes. Cilium's kube-proxy replacement handles the ClusterIP Service.
- No forward on host required: forwarding happens in the gateway pod netns.
- Cluster-internal ranges, the VPN server IP, and localhost are always excluded from the redirect.
- Kill switch is all-or-nothing: external egress allowed only out `tun0`; when `tun0` is down, external egress is dropped; cluster traffic still works.
- The webhook's CA bundle must be trusted by the API server (cert-manager + cluster trusted CA).
- Annotation that opts a pod in: `vpn.example.com/egress: "true"`.

---

### Task 1: Repo scaffolding + gateway container images

**Files:**
- Create: `Dockerfile` (multi-stage: webhook build + runtime)
- Create: `images/gateway/Dockerfile`
- Create: `images/gateway/killswitch.sh`
- Create: `images/routing-init/Dockerfile`
- Create: `images/routing-init/redirect.sh`
- Create: `go.mod`, `go.sum`
- Create: `Makefile`

**Interfaces:**
- Produces: container images and helper scripts that later tasks (`webhook` Go code, Helm chart) reference.

- [ ] **Step 1: Init Go module and Makefile**

Create `go.mod`:
```
module github.com/example/vpn-egress-gateway

go 1.22
```
Create `Makefile` with targets `build`, `test`, `docker-build`, `docker-push` that set image tags via `IMAGE_TAG` and `REGISTRY`.

- [ ] **Step 2: Write the gateway Dockerfile**

Create `images/gateway/Dockerfile`:
- Base `openvpn/openvpn:3` (or equivalent `alpine` + `openvpn` + `nftables` + `iproute2`).
- Install `nftables`, `ca-certificates`, `curl`.
- Copy `killswitch.sh` to `/usr/local/bin/killswitch.sh`.
- ENTRYPOINT: run `killswitch.sh` which then execs `openvpn`.

- [ ] **Step 3: Write the kill-switch supervisor script**

Create `images/gateway/killswitch.sh`:

```bash
#!/bin/sh
set -e

VPN_SERVER_IP="${VPN_SERVER_IP:?VPN_SERVER_IP is required}"
TUN_IF="${TUN_IF:-tun0}"

# Base ruleset loaded at startup: default DROP external egress.
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

# OpenVPN prints "Initialization Sequence Completed" when up.
exec openvpn --config /etc/openvpn/client.ovpn \
  --script-security 2 \
  --route-up /usr/local/bin/killswitch-open.sh \
  --route-pre-down /usr/local/bin/killswitch-close.sh
```

Create `images/gateway/killswitch-open.sh` and `images/gateway/killswitch-close.sh`:
- `open`: install `inet killswitch` forward policy to `accept` for external egress out `$TUN_IF`.
- `close`: reset forward policy to `drop` (the kill switch). Both read `TUN_IF`.

- [ ] **Step 4: Write the routing-init redirect script**

Create `images/routing-init/redirect.sh`:

```bash
#!/bin/sh
set -e
GATEWAY_CIDR="${GATEWAY_CIDR:?GATEWAY_CIDR required}"   # e.g. 10.96.0.0/16
CLUSTER_CIDR="${CLUSTER_CIDR:?CLUSTER_CIDR required}"    # e.g. 10.0.0.0/8
GATEWAY_IP="${GATEWAY_IP:?GATEWAY_IP required}"

nft -f - <<EOF
table inet vpnroute {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    ip daddr { $CLUSTER_CIDR, $GATEWAY_CIDR } return
    ip daddr != { $VPN_SERVER_IP } dnat to $GATEWAY_IP
  }
}
EOF
```
(Order: exclude cluster/gateway ranges first, then DNAT the rest to the gateway ClusterIP.)

Create `images/routing-init/Dockerfile` (base `alpine` + `nftables`, copy `redirect.sh`, ENTRYPOINT runs it).

- [ ] **Step 5: Write the webhook buildstage Dockerfile**

Create root `Dockerfile`:
```
FROM golang:1.22 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /webhook ./cmd/webhook

FROM scratch
COPY --from=build /webhook /webhook
ENTRYPOINT ["/webhook"]
```

- [ ] **Step 6: Add a root test + verify build tools**

Run: `make test` (no tests yet — `go vet ./...` as placeholder gate).
Expected: passes with no tests.

- [ ] **Step 7: Commit**

```bash
git add Dockerfile images go.mod go.sum Makefile
git commit -m "chore: scaffold repo and gateway/routing-init images"
```

---

### Task 2: Load `.ovpn` from remote URL (initContainer)

**Files:**
- Create: `images/gateway/fetchconfig.sh`
- Modify: `images/gateway/Dockerfile`

**Interfaces:**
- Consumes: `CONFIG_URL` env.
- Produces: `/etc/openvpn/client.ovpn` in a shared `emptyDir` consumed by Task 1's gateway ENTRYPOINT.

- [ ] **Step 1: Write the failing test for URL-safe config fetch logic**

Write `scripts/test_fetchconfig.sh` (bash) that runs `fetchconfig.sh` against a `file://`-served config and asserts the file lands at the output path.

- [ ] **Step 2: Run test to verify it fails (no script yet)**

Run: `scripts/test_fetchconfig.sh`
Expected: FAIL (script not found).

- [ ] **Step 3: Write fetchconfig.sh**

```bash
#!/bin/sh
set -eu
out="/etc/openvpn/client.ovpn"
CONFIG_URL="${CONFIG_URL:?CONFIG_URL required}"
curl -fSL --retry 3 --retry-delay 2 -o "$out" "$CONFIG_URL"
test -s "$out"
```

Add `images/gateway/init-fetchconfig` Dockerfile entry/binary layout: add `fetchconfig.sh` to the gateway image and an `initContainer` command reference (used in the Helm chart, Task 5).

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test_fetchconfig.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add images/gateway/fetchconfig.sh scripts/test_fetchconfig.sh images/gateway/Dockerfile
git commit -m "feat: fetch openvpn config from remote URL in initContainer"
```

---

### Task 3: Kill-switch ruleset unit test

**Files:**
- Create: `scripts/test_killswitch.sh`
- Create: `images/gateway/killswitch-open.sh`
- Modify: `images/gateway/killswitch.sh` (reference subnet/route logic)

**Interfaces:**
- Consumes: `VPN_SERVER_IP`, `TUN_IF` env.
- Produces: a runnable test that verifies forward policy flips to `drop` when the tunnel is down and `accept` out `tun0` when up.

- [ ] **Step 1: Write the failing test**

Create `scripts/test_killswitch.sh` that:
- Starts a scratch netns with a dummy `tun0`.
- Sources/execs `killswitch-close.sh`, asserts forward chain policy is `drop`.
- Execs `killswitch-open.sh`, asserts forward policy is `accept` for tunnel egress.
- Asserts cluster-internal ranges are accepted in both states.

- [ ] **Step 2: Run test to verify it fails (open/close not yet written)**

Run: `bash scripts/test_killswitch.sh`
Expected: FAIL.

- [ ] **Step 3: Write killswitch-open.sh / killswitch-close.sh**

`killswitch-open.sh`:
```bash
#!/bin/sh
nft add rule inet killswitch forward oifname "$TUN_IF" accept
```
`killswitch-close.sh`:
```bash
#!/bin/sh
nft flush chain inet killswitch forward
```
(Comment: flush removes the tun-egress accept, leaving the boot-time `policy drop` in force.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/test_killswitch.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/test_killswitch.sh images/gateway/killswitch-open.sh images/gateway/killswitch-close.sh
git commit -m "feat: kill-switch ruleset open/close scripts with test"
```

---

### Task 4: Mutating webhook (Go)

**Files:**
- Create: `cmd/webhook/main.go`
- Create: `cmd/webhook/mutate.go`
- Create: `cmd/webhook/mutate_test.go`
- Create: `pkg/routing/initcontainer.go`
- Create: `pkg/routing/initcontainer_test.go`

**Interfaces:**
- Consumes: annotation `vpn.example.com/egress: "true"`; `GATEWAY_IP`, `CLUSTER_CIDR`, `GATEWAY_CIDR` config.
- Produces: a `MutatingWebhookConfiguration`-ready HTTPS server; patch that injects a routing initContainer into matching pods.

- [ ] **Step 1: Write the failing test for the patch builder**

`pkg/routing/initcontainer.go` exposes:
```go
func RoutingInitContainer(gatewayIP, clusterCIDR, gatewayCIDR string) v1.Container
```
Write `pkg/routing/initcontainer_test.go` asserting the returned `v1.Container` has image `routing-init`, the right `args`/`env`, and the redirect script env vars.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./pkg/routing/...`
Expected: FAIL (func not defined).

- [ ] **Step 3: Write RoutingInitContainer**

```go
func RoutingInitContainer(gatewayIP, clusterCIDR, gatewayCIDR string) v1.Container {
	return v1.Container{
		Name:    "vpn-egress-redirect",
		Image:   "routing-init:latest",
		Command: []string{"/usr/local/bin/redirect.sh"},
		Env: []v1.EnvVar{
			{Name: "GATEWAY_IP", Value: gatewayIP},
			{Name: "CLUSTER_CIDR", Value: clusterCIDR},
			{Name: "GATEWAY_CIDR", Value: gatewayCIDR},
			{Name: "VPN_SERVER_IP", Value: os.Getenv("VPN_SERVER_IP")},
		},
	}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./pkg/routing/...`
Expected: PASS.

- [ ] **Step 5: Write the failing test for the mutating webhook**

`mutate.go`:
```go
func hasGatewayAnnotation(p *v1.Pod) bool
func injectRoutingInitContainer(p *v1.Pod, opts ...) ([]byte, error) // returns JSONPatch
```
Write `mutate_test.go` covering: annotation present -> patch produced embedding routing init; annotation absent -> no patch; pod not annotated -> skip.

- [ ] **Step 6: Run test to verify it fails**

Run: `go test ./cmd/webhook/...`
Expected: FAIL.

- [ ] **Step 7: Write mutate.go and main.go**

`mutate.go` implements the patch using `k8s.io/apimachinery/pkg/util/jsonpatch` or a hand-built patch array to add `initContainers += routing-egress`. `main.go` serves `/mutate` over HTTPS with certs from `TLS_CERT_FILE`/`TLS_KEY_FILE` env, decodes `admission/v1` `AdmissionReview`, dispatches to `injectRoutingInitContainer`.

- [ ] **Step 8: Run tests to verify they pass**

Run: `go test ./...`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add cmd/webhook pkg/routing go.mod go.sum
git commit -m "feat: mutating webhook injects routing initContainer into annotated pods"
```

---

### Task 5: Helm chart / manifests + webhook TLS

**Files:**
- Create: `deploy/helm/values.yaml`
- Create: `deploy/helm/templates/gateway.yaml`
- Create: `deploy/helm/templates/webhook.yaml`
- Create: `deploy/helm/templates/cert.yaml`
- Create: `deploy/helm/Chart.yaml`

**Interfaces:**
- Consumes: `GATEWAY_IP`/Service ClusterIP, `CLUSTER_CIDR`, `GATEWAY_CIDR`, `VPN_SERVER_IP`, `CONFIG_URL`.
- Produces: deployable gateway Deployment + Service, webhook Deployment + Service + `MutatingWebhookConfiguration`, cert-manager `Certificate`.

- [ ] **Step 1: Write the gateway deployment + service template**

`gateway.yaml`: Deployment with `initContainer` running `fetchconfig.sh` (`CONFIG_URL`), main container running `killswitch.sh` / `openvpn`, mounting the shared `emptyDir`. Tolerations for Talos nodes, `hostNetwork: false`, privileged `securityContext` (needs `NET_ADMIN` for nftables + tun). A `ClusterIP` `Service` (name `vpn-egress-gateway`).

- [ ] **Step 2: Write the webhook deployment + service template**

`webhook.yaml`: Deployment running the webhook image, `Service`, and a `MutatingWebhookConfiguration` with `reinvocationPolicy: IfNeeded`, `sideEffects: None`, `admissionReviewVersions: ["v1"]`, `rules` matching `pods` with the `vpn.example.com/egress` annotation, `clientConfig` referencing the webhook Service `path: /mutate`.

- [ ] **Step 3: Write the cert template**

`cert.yaml`: cert-manager `Certificate` for the webhook Service DNS name + a `ClusterIssuer` reference; wire the cert CA bundle into the `MutatingWebhookConfiguration.clientConfig`.

- [ ] **Step 4: Write values.yaml and validate with helm lint**

Run: `helm lint deploy/helm`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add deploy/helm
git commit -m "feat: helm chart for gateway, webhook, and webhook TLS"
```

---

### Task 6: End-to-end design verification + docs

**Files:**
- Create: `README.md`
- Create: `docs/OPERATIONS.md`

**Interfaces:** None — documents the deployment and operations.

- [ ] **Step 1: Write README.md**

Document: architecture diagram, prerequisites (Cilium, Talos, cert-manager), install (`helm install vpn-egress-gateway deploy/helm` with required values), annotation opt-in, kill-switch behavior, and a troubleshooting note for the Cilium masquerading requirement.

- [ ] **Step 2: Write docs/OPERATIONS.md**

Document: how to update the VPN endpoint/config (set `CONFIG_URL`), how to validate the kill switch (stop the tunnel and confirm egress is blocked), and how the webhook cert rotates.

- [ ] **Step 3: Run the full test suite**

Run: `make test`
Expected: `go test ./...` passes, scripts pass.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/OPERATIONS.md
git commit -m "docs: add README and operations guide"
```
