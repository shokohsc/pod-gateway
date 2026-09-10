package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthHandler(t *testing.T) {
	rec := httptest.NewRecorder()
	healthHandler(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Errorf("healthHandler status = %d, want %d", rec.Code, http.StatusOK)
	}
}

func TestReadyHandler(t *testing.T) {
	tests := []struct {
		name       string
		gatewayIP  string
		wantStatus int
	}{
		{"literal ip", "203.0.113.1", http.StatusOK},
		{"unresolvable name", "vpn-egress-gateway.invalid", http.StatusServiceUnavailable},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			readyHandler(tt.gatewayIP)(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
			if rec.Code != tt.wantStatus {
				t.Errorf("readyHandler(%q) status = %d, want %d", tt.gatewayIP, rec.Code, tt.wantStatus)
			}
		})
	}
}
