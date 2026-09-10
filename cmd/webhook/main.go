package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	admissionv1 "k8s.io/api/admission/v1"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/apimachinery/pkg/types"
)

var (
	scheme       = runtime.NewScheme()
	codecs       = serializer.NewCodecFactory(scheme)
	deserializer = codecs.UniversalDeserializer()
)

func init() {
	if err := admissionv1.AddToScheme(scheme); err != nil {
		panic(err)
	}
}

func main() {
	certFile := os.Getenv("TLS_CERT_FILE")
	keyFile := os.Getenv("TLS_KEY_FILE")
	if certFile == "" || keyFile == "" {
		log.Fatal("TLS_CERT_FILE and TLS_KEY_FILE must be set")
	}

	gatewayIP := os.Getenv("GATEWAY_IP")
	clusterCIDR := os.Getenv("CLUSTER_CIDR")
	gatewayCIDR := os.Getenv("GATEWAY_CIDR")
	vpnServerIP := os.Getenv("VPN_SERVER_IP")
	if gatewayIP == "" || clusterCIDR == "" || gatewayCIDR == "" || vpnServerIP == "" {
		log.Fatal("GATEWAY_IP, CLUSTER_CIDR, GATEWAY_CIDR, VPN_SERVER_IP must all be set")
	}

	clusterServicesCIDR := os.Getenv("CLUSTER_SERVICES_CIDR")
	if clusterServicesCIDR == "" {
		clusterServicesCIDR = "10.96.0.0/12"
	}

	vxlanID := os.Getenv("VXLAN_ID")
	if vxlanID == "" {
		vxlanID = "1000"
	}
	vxlanPort := os.Getenv("VXLAN_PORT")
	if vxlanPort == "" {
		vxlanPort = "4790"
	}
	vxlanNet := os.Getenv("VXLAN_NET")
	if vxlanNet == "" {
		vxlanNet = "10.255.0.0/16"
	}

	routingInitImage := os.Getenv("ROUTING_INIT_IMAGE")
	if routingInitImage == "" {
		routingInitImage = "routing-init:latest"
	}

	imagePullPolicy := os.Getenv("IMAGE_PULL_POLICY")
	if imagePullPolicy == "" {
		imagePullPolicy = "IfNotPresent"
	}

	annotationKey := os.Getenv("ANNOTATION_KEY")
	if annotationKey == "" {
		annotationKey = "vpn.example.com/egress"
	}

	healthAddr := os.Getenv("HEALTH_ADDR")
	if healthAddr == "" {
		healthAddr = ":8080"
	}

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8443"
	}

	opts := Options{
		AnnotationKey:       annotationKey,
		GatewayIP:           gatewayIP,
		ClusterCIDR:         clusterCIDR,
		GatewayCIDR:         gatewayCIDR,
		ClusterServicesCIDR: clusterServicesCIDR,
		VPNServerIP:         vpnServerIP,
		VXLANID:             vxlanID,
		VXLANPort:           vxlanPort,
		VXLANNet:            vxlanNet,
		RoutingInitImage:    routingInitImage,
		ImagePullPolicy:     imagePullPolicy,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutateHandler(opts))

	healthMux := http.NewServeMux()
	healthMux.HandleFunc("/healthz", healthHandler)
	healthMux.HandleFunc("/readyz", readyHandler(gatewayIP))

	go func() {
		log.Printf("health listening on %s", healthAddr)
		if err := http.ListenAndServe(healthAddr, healthMux); err != nil {
			log.Fatal(err)
		}
	}()

	log.Printf("listening on %s", listenAddr)
	if err := http.ListenAndServeTLS(listenAddr, certFile, keyFile, mux); err != nil {
		log.Fatal(err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

func readyHandler(gatewayIP string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if _, err := net.DefaultResolver.LookupHost(ctx, gatewayIP); err != nil {
			http.Error(w, fmt.Sprintf("gateway %q unresolvable: %v", gatewayIP, err), http.StatusServiceUnavailable)
			return
		}
		healthHandler(w, r)
	}
}

func mutateHandler(opts Options) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, fmt.Sprintf("reading body: %v", err), http.StatusBadRequest)
			return
		}

		var review admissionv1.AdmissionReview
		if _, _, err := deserializer.Decode(body, nil, &review); err != nil {
			sendAdmissionResponse(w, types.UID(""), false, fmt.Sprintf("decode error: %v", err))
			return
		}

		if review.Request == nil {
			http.Error(w, "no admission request", http.StatusBadRequest)
			return
		}

		var pod v1.Pod
		if err := json.Unmarshal(review.Request.Object.Raw, &pod); err != nil {
			sendAdmissionResponse(w, review.Request.UID, false, fmt.Sprintf("unmarshal pod: %v", err))
			return
		}

		if !hasGatewayAnnotation(&pod, opts.AnnotationKey) {
			sendAdmissionResponse(w, review.Request.UID, true, "")
			return
		}

		patchBytes, err := injectRoutingInitContainer(&pod, opts)
		if err != nil {
			sendAdmissionResponse(w, review.Request.UID, false, err.Error())
			return
		}

		if patchBytes == nil {
			sendAdmissionResponse(w, review.Request.UID, true, "")
			return
		}

		patchType := admissionv1.PatchTypeJSONPatch
		sendAdmissionResponseWithPatch(w, review.Request.UID, true, patchBytes, &patchType)
	}
}

func sendAdmissionResponse(w http.ResponseWriter, uid types.UID, allowed bool, message string) {
	review := admissionv1.AdmissionReview{
		Response: &admissionv1.AdmissionResponse{
			UID:     uid,
			Allowed: allowed,
		},
	}
	if message != "" {
		review.Response.Result = &metav1.Status{Message: message}
	}
	review.SetGroupVersionKind(admissionv1.SchemeGroupVersion.WithKind("AdmissionReview"))
	writeAdmissionReview(w, &review)
}

func sendAdmissionResponseWithPatch(w http.ResponseWriter, uid types.UID, allowed bool, patch []byte, patchType *admissionv1.PatchType) {
	review := admissionv1.AdmissionReview{
		Response: &admissionv1.AdmissionResponse{
			UID:       uid,
			Allowed:   allowed,
			PatchType: patchType,
			Patch:     patch,
		},
	}
	review.SetGroupVersionKind(admissionv1.SchemeGroupVersion.WithKind("AdmissionReview"))
	writeAdmissionReview(w, &review)
}

func writeAdmissionReview(w http.ResponseWriter, review *admissionv1.AdmissionReview) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(review)
}
