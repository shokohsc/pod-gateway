package routing

import (
	"testing"
)

func TestRoutingInitContainer(t *testing.T) {
	c := RoutingInitContainer("10.0.0.1", "10.32.0.0/12", "10.96.0.0/24", "203.0.113.1")

	if c.Name != "vpn-egress-redirect" {
		t.Errorf("Name = %q, want vpn-egress-redirect", c.Name)
	}
	if c.Image != "routing-init:latest" {
		t.Errorf("Image = %q, want routing-init:latest", c.Image)
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
	c := RoutingInitContainer("", "", "", "")
	if c.Env == nil {
		t.Error("Env should never be nil (redirect.sh requires all four vars)")
	}
	for _, e := range c.Env {
		if e.Value != "" {
			t.Errorf("Env[%s] = %q, want empty string for empty arg", e.Name, e.Value)
		}
	}
}
