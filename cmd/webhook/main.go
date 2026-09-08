package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

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

	listenAddr := os.Getenv("LISTEN_ADDR")
	if listenAddr == "" {
		listenAddr = ":8443"
	}

	opts := Options{
		GatewayIP:   gatewayIP,
		ClusterCIDR: clusterCIDR,
		GatewayCIDR: gatewayCIDR,
		VPNServerIP: vpnServerIP,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", mutateHandler(opts))

	log.Printf("listening on %s", listenAddr)
	if err := http.ListenAndServeTLS(listenAddr, certFile, keyFile, mux); err != nil {
		log.Fatal(err)
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

		if !hasGatewayAnnotation(&pod) {
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
