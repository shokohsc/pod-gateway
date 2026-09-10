package routing

import v1 "k8s.io/api/core/v1"

// RoutingInitContainer returns an initContainer spec that runs redirect.sh
// to route egress traffic through the VPN gateway. It mirrors the reference
// gateway-admission-controller's container: explicit root + NET_ADMIN/NET_RAW
// capabilities so nftables works regardless of the pod's security context.
func RoutingInitContainer(gatewayIP, clusterCIDR, gatewayCIDR, vpnServerIP, image, imagePullPolicy string) v1.Container {
	runAsUser := int64(0)
	runAsNonRoot := false
	return v1.Container{
		Name:            "vpn-egress-redirect",
		Image:           image,
		ImagePullPolicy: v1.PullPolicy(imagePullPolicy),
		Command:         []string{"/usr/local/bin/redirect.sh"},
		SecurityContext: &v1.SecurityContext{
			Capabilities: &v1.Capabilities{
				Add:  []v1.Capability{"NET_ADMIN", "NET_RAW"},
				Drop: []v1.Capability{},
			},
			RunAsUser:    &runAsUser,
			RunAsNonRoot: &runAsNonRoot,
		},
		Env: []v1.EnvVar{
			{Name: "GATEWAY_IP", Value: gatewayIP},
			{Name: "CLUSTER_CIDR", Value: clusterCIDR},
			{Name: "GATEWAY_CIDR", Value: gatewayCIDR},
			{Name: "VPN_SERVER_IP", Value: vpnServerIP},
		},
	}
}
