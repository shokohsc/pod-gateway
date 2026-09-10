package routing

import v1 "k8s.io/api/core/v1"

// Params configures the injected routing initContainer.
type Params struct {
	GatewayIP       string
	ClusterCIDR     string
	GatewayCIDR     string
	VPNServerIP     string
	VXLANID         string
	VXLANPort       string
	VXLANNet        string
	Image           string
	ImagePullPolicy string
}

// RoutingInitContainer returns an initContainer spec that runs redirect.sh
// to route egress traffic through the VPN gateway. It mirrors the reference
// gateway-admission-controller's container: explicit root + NET_ADMIN/NET_RAW
// capabilities so it can program the network namespace.
func RoutingInitContainer(p Params) v1.Container {
	runAsUser := int64(0)
	runAsNonRoot := false
	return v1.Container{
		Name:            "vpn-egress-redirect",
		Image:           p.Image,
		ImagePullPolicy: v1.PullPolicy(p.ImagePullPolicy),
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
			{Name: "GATEWAY_IP", Value: p.GatewayIP},
			{Name: "CLUSTER_CIDR", Value: p.ClusterCIDR},
			{Name: "GATEWAY_CIDR", Value: p.GatewayCIDR},
			{Name: "VPN_SERVER_IP", Value: p.VPNServerIP},
			{Name: "VXLAN_ID", Value: p.VXLANID},
			{Name: "VXLAN_PORT", Value: p.VXLANPort},
			{Name: "VXLAN_NET", Value: p.VXLANNet},
		},
	}
}
