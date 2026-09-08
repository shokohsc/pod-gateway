package main

import (
	"encoding/json"
	"testing"

	admissionv1 "k8s.io/api/admission/v1"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
)

func TestHasGatewayAnnotation(t *testing.T) {
	tests := []struct {
		name string
		pod  *v1.Pod
		want bool
	}{
		{
			name: "annotation present with value true",
			pod: &v1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{"vpn.example.com/egress": "true"},
				},
			},
			want: true,
		},
		{
			name: "annotation absent",
			pod: &v1.Pod{
				ObjectMeta: metav1.ObjectMeta{},
			},
			want: false,
		},
		{
			name: "annotation present but not true",
			pod: &v1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{"vpn.example.com/egress": "yes"},
				},
			},
			want: false,
		},
		{
			name: "annotation present with empty string",
			pod: &v1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{"vpn.example.com/egress": ""},
				},
			},
			want: false,
		},
		{
			name: "annotation present with True (capital T)",
			pod: &v1.Pod{
				ObjectMeta: metav1.ObjectMeta{
					Annotations: map[string]string{"vpn.example.com/egress": "True"},
				},
			},
			want: false,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := hasGatewayAnnotation(tt.pod); got != tt.want {
				t.Errorf("hasGatewayAnnotation() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestInjectRoutingInitContainer_ProducesPatch(t *testing.T) {
	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-pod",
			Namespace: "default",
		},
	}

	opts := Options{
		GatewayIP:        "10.0.0.1",
		ClusterCIDR:      "10.32.0.0/12",
		GatewayCIDR:      "10.96.0.0/24",
		VPNServerIP:      "203.0.113.1",
		RoutingInitImage: "routing-init:latest",
	}

	patch, err := injectRoutingInitContainer(pod, opts)
	if err != nil {
		t.Fatalf("injectRoutingInitContainer() error = %v", err)
	}

	var ops []map[string]interface{}
	if err := json.Unmarshal(patch, &ops); err != nil {
		t.Fatalf("invalid JSON patch: %v\npatch: %s", err, patch)
	}
	if len(ops) != 1 {
		t.Fatalf("patch has %d ops, want 1", len(ops))
	}
	if ops[0]["op"] != "add" {
		t.Errorf("op = %v, want add", ops[0]["op"])
	}
	if ops[0]["path"] != "/spec/initContainers" {
		t.Errorf("path = %v, want /spec/initContainers", ops[0]["path"])
	}

	val, _ := json.Marshal(ops[0]["value"])
	var containers []v1.Container
	if err := json.Unmarshal(val, &containers); err != nil {
		t.Fatalf("value is not a container array: %v", err)
	}
	if len(containers) != 1 {
		t.Fatalf("value has %d containers, want 1", len(containers))
	}
	if containers[0].Name != "vpn-egress-redirect" {
		t.Errorf("container name = %q, want vpn-egress-redirect", containers[0].Name)
	}
	if containers[0].Image != "routing-init:latest" {
		t.Errorf("container image = %q, want routing-init:latest", containers[0].Image)
	}
}

func TestInjectRoutingInitContainer_ExistingInitContainers(t *testing.T) {
	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "test-pod"},
		Spec: v1.PodSpec{
			InitContainers: []v1.Container{
				{Name: "setup", Image: "busybox"},
			},
		},
	}
	opts := Options{
		GatewayIP:        "10.0.0.1",
		ClusterCIDR:      "10.32.0.0/12",
		GatewayCIDR:      "10.96.0.0/24",
		VPNServerIP:      "203.0.113.1",
		RoutingInitImage: "routing-init:latest",
	}
	patch, err := injectRoutingInitContainer(pod, opts)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var ops []map[string]interface{}
	if err := json.Unmarshal(patch, &ops); err != nil {
		t.Fatalf("invalid JSON patch: %v", err)
	}
	val, _ := json.Marshal(ops[0]["value"])
	var containers []v1.Container
	if err := json.Unmarshal(val, &containers); err != nil {
		t.Fatalf("value not container array: %v", err)
	}
	if len(containers) != 2 {
		t.Fatalf("want 2 containers, got %d", len(containers))
	}
	if containers[0].Name != "setup" {
		t.Errorf("first container = %q, want setup", containers[0].Name)
	}
	if containers[1].Name != "vpn-egress-redirect" {
		t.Errorf("second container = %q, want vpn-egress-redirect", containers[1].Name)
	}
}

func TestInjectRoutingInitContainer_DoubleInjectionGuard(t *testing.T) {
	pod := &v1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "test-pod"},
		Spec: v1.PodSpec{
			InitContainers: []v1.Container{
				{Name: "vpn-egress-redirect", Image: "routing-init:latest"},
			},
		},
	}
	opts := Options{
		GatewayIP:        "10.0.0.1",
		ClusterCIDR:      "10.32.0.0/12",
		GatewayCIDR:      "10.96.0.0/24",
		VPNServerIP:      "203.0.113.1",
		RoutingInitImage: "routing-init:latest",
	}
	patch, err := injectRoutingInitContainer(pod, opts)
	if err != nil {
		t.Fatalf("unexpected error for double injection: %v", err)
	}
	if patch != nil {
		t.Errorf("expected nil patch for double injection, got %s", patch)
	}
}

func TestAdmissionReviewDecodeRoundTrip(t *testing.T) {
	pod := v1.Pod{
		TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"},
		ObjectMeta: metav1.ObjectMeta{
			Name:        "test-pod",
			Namespace:   "default",
			Annotations: map[string]string{"vpn.example.com/egress": "true"},
		},
	}
	podRaw, err := json.Marshal(pod)
	if err != nil {
		t.Fatalf("marshal pod: %v", err)
	}

	review := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{APIVersion: "admission.k8s.io/v1", Kind: "AdmissionReview"},
		Request: &admissionv1.AdmissionRequest{
			UID:    types.UID("test-uid"),
			Object: runtime.RawExtension{Raw: podRaw},
		},
	}
	body, err := json.Marshal(review)
	if err != nil {
		t.Fatalf("marshal review: %v", err)
	}

	var out admissionv1.AdmissionReview
	if _, _, err := deserializer.Decode(body, nil, &out); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if out.Request == nil {
		t.Fatal("decoded request is nil")
	}
	var decoded v1.Pod
	if err := json.Unmarshal(out.Request.Object.Raw, &decoded); err != nil {
		t.Fatalf("unmarshal pod from decoded request: %v", err)
	}
	if decoded.Annotations["vpn.example.com/egress"] != "true" {
		t.Errorf("annotation = %q, want %q", decoded.Annotations["vpn.example.com/egress"], "true")
	}
}
