# Operations Guide

## Changing the VPN Endpoint or Config

The gateway's OpenVPN config is fetched at startup from the URL in
`CONFIG_URL`. To switch VPN providers or endpoints:

1. Set `CONFIG_URL` to the new `.ovpn` download URL:
   ```bash
   helm upgrade vpn-egress-gateway deploy/helm \
     --set configURL=https://new-vpn-server/client.ovpn \
     ...
   ```
2. Roll the gateway Deployment:
   ```bash
   kubectl rollout restart deploy/vpn-egress-gateway
   ```
3. Wait for the new pod to become ready:
   ```bash
   kubectl rollout status deploy/vpn-egress-gateway
   ```

The gateway container downloads the config to `/etc/openvpn/client.ovpn` at
the start of every container start, so a VPN-drop restart re-fetches it.
If the download fails, the pod will `CrashLoopBackOff` — fix the URL and
restart.

## Validating the Kill Switch

To verify the kill switch is functioning:

1. Identify the gateway pod:
   ```bash
   GATEWAY_POD=$(kubectl get pods -l app=vpn-egress-gateway -o jsonpath='{.items[0].metadata.name}')
   ```

2. Stop the OpenVPN tunnel (this triggers the kill-switch close hook):
   ```bash
   kubectl exec "$GATEWAY_POD" -- killall openvpn
   ```

3. From an annotated client pod, confirm external egress is blocked:
   ```bash
   kubectl run test-pod --image=busybox --rm -it --restart=Never \
     --annotations vpn.example.com/egress="true" -- wget -q -O /dev/null --timeout=5 https://example.com
   ```
   This should time out or fail — external egress is blocked.

4. Confirm cluster-internal traffic still works from the same pod:
   ```bash
   kubectl run test-pod --image=busybox --rm -it --restart=Never \
     --annotations vpn.example.com/egress="true" -- wget -q -O /dev/null --timeout=5 http://kubernetes.default.svc
   ```

5. To restore: restart the gateway pod so OpenVPN reconnects and the
   `route-up` hook re-opens tunnel egress:
   ```bash
   kubectl rollout restart deploy/vpn-egress-gateway
   ```

## Webhook Certificate Rotation

Certificate rotation is handled automatically by cert-manager:

1. The `Certificate` resource (`vpn-egress-webhook-cert`) is issued by the
   configured `ClusterIssuer`.
2. cert-manager renews the certificate before expiry and updates the TLS
   secret (`vpn-egress-webhook-cert`).
3. The `MutatingWebhookConfiguration` CA bundle is injected via the
   `cert-manager.io/inject-ca-from` annotation — cert-manager updates it
   automatically when the certificate is renewed.

To force an immediate renewal:

```bash
kubectl delete secret vpn-egress-webhook-cert
```

cert-manager will re-issue the certificate and update the secret. The
webhook pods pick up the new cert on next restart.

To check certificate status:

```bash
kubectl describe certificate vpn-egress-webhook-cert
```
