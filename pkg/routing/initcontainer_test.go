package routing

import (
	"testing"

	v1 "k8s.io/api/core/v1"
)

func TestRoutingInitContainer(t *testing.T) {
	c := RoutingInitContainer("10.0.0.1", "10.32.0.0/12", "10.96.0.0/24", "203.0.113.1", "routing-init:latest", "IfNotPresent")

	if c.Name != "vpn-egress-redirect" {
		t.Errorf("Name = %q, want vpn-egress-redirect", c.Name)
	}
	if c.Image != "routing-init:latest" {
		t.Errorf("Image = %q, want routing-init:latest", c.Image)
	}
	if c.ImagePullPolicy != v1.PullIfNotPresent {
		t.Errorf("ImagePullPolicy = %q, want IfNotPresent", c.ImagePullPolicy)
	}
	if c.SecurityContext == nil {
		t.Fatal("SecurityContext should not be nil (needs NET_ADMIN/NET_RAW + root)")
	}
	sc := c.SecurityContext
	if sc.RunAsUser == nil || *sc.RunAsUser != 0 {
		t.Errorf("RunAsUser = %v, want 0", sc.RunAsUser)
	}
	if sc.RunAsNonRoot == nil || *sc.RunAsNonRoot {
		t.Errorf("RunAsNonRoot = %v, want false", sc.RunAsNonRoot)
	}
	for _, cap := range []v1.Capability{"NET_ADMIN", "NET_RAW"} {
		if !hasCapability(sc.Capabilities, cap) {
			t.Errorf("Capabilities.Add missing %s", cap)
		}
	}
	if len(c.Command) != 1 || c.Command[0] != "/usr/local/bin/redirect.sh" {
		t.Errorf("Command = %v, want [/usr/local/bin/redirect.sh]", c.Command)
	}
	if len(c.Env) != 4 {
		t.Fatalf("Env len = %d, want 4", len(c.Env))
	}
	wantEnv := []struct{ name, value string }{
		{"GATEWAY_IP", "10.0.0.1"},
		{"CLUSTER_CIDR", "10.32.0.0/12"},
		{"GATEWAY_CIDR", "10.96.0.0/24"},
		{"VPN_SERVER_IP", "203.0.113.1"},
	}
	for i, w := range wantEnv {
		if c.Env[i].Name != w.name || c.Env[i].Value != w.value {
			t.Errorf("Env[%d] = {%q, %q}, want {%q, %q}", i, c.Env[i].Name, c.Env[i].Value, w.name, w.value)
		}
	}
}

func TestRoutingInitContainerNeverNilEnv(t *testing.T) {
	c := RoutingInitContainer("", "", "", "", "", "")
	if c.Env == nil {
		t.Error("Env should never be nil (redirect.sh requires all four vars)")
	}
	for _, e := range c.Env {
		if e.Value != "" {
			t.Errorf("Env[%s] = %q, want empty string for empty arg", e.Name, e.Value)
		}
	}
}

func hasCapability(caps *v1.Capabilities, want v1.Capability) bool {
	if caps == nil {
		return false
	}
	for _, c := range caps.Add {
		if c == want {
			return true
		}
	}
	return false
}
