package routing

import v1 "k8s.io/api/core/v1"

// RoutingInitContainer returns an initContainer spec that runs redirect.sh
// to route egress traffic through the VPN gateway.
func RoutingInitContainer(gatewayIP, clusterCIDR, gatewayCIDR, vpnServerIP, image string) v1.Container {
	return v1.Container{
		Name:    "vpn-egress-redirect",
		Image:   image,
		Command: []string{"/usr/local/bin/redirect.sh"},
		Env: []v1.EnvVar{
			{Name: "GATEWAY_IP", Value: gatewayIP},
			{Name: "CLUSTER_CIDR", Value: clusterCIDR},
			{Name: "GATEWAY_CIDR", Value: gatewayCIDR},
			{Name: "VPN_SERVER_IP", Value: vpnServerIP},
		},
	}
}
