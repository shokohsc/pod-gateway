package main

import (
	"encoding/json"

	v1 "k8s.io/api/core/v1"

	"github.com/example/vpn-egress-gateway/pkg/routing"
)

type Options struct {
	AnnotationKey    string
	GatewayIP        string
	ClusterCIDR      string
	GatewayCIDR      string
	VPNServerIP      string
	RoutingInitImage string
}

func hasGatewayAnnotation(p *v1.Pod, key string) bool {
	if p.Annotations == nil {
		return false
	}
	return p.Annotations[key] == "true"
}

func injectRoutingInitContainer(p *v1.Pod, opts Options) ([]byte, error) {
	for _, c := range p.Spec.InitContainers {
		if c.Name == "vpn-egress-redirect" {
			return nil, nil
		}
	}

	container := routing.RoutingInitContainer(opts.GatewayIP, opts.ClusterCIDR, opts.GatewayCIDR, opts.VPNServerIP, opts.RoutingInitImage)
	existing := p.Spec.InitContainers
	existing = append(existing, container)

	return json.Marshal([]map[string]interface{}{
		{"op": "add", "path": "/spec/initContainers", "value": existing},
	})
}
