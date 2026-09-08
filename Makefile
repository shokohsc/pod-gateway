IMAGE_TAG ?= latest
REGISTRY ?= ghcr.io/example

.PHONY: build test docker-build docker-push

build:
	CGO_ENABLED=0 go build -o bin/webhook ./cmd/webhook

test:
	go vet ./...

docker-build:
	docker build -t $(REGISTRY)/vpn-egress-gateway:$(IMAGE_TAG) .
	docker build -t $(REGISTRY)/gateway:$(IMAGE_TAG) images/gateway
	docker build -t $(REGISTRY)/routing-init:$(IMAGE_TAG) images/routing-init

docker-push:
	docker push $(REGISTRY)/vpn-egress-gateway:$(IMAGE_TAG)
	docker push $(REGISTRY)/gateway:$(IMAGE_TAG)
	docker push $(REGISTRY)/routing-init:$(IMAGE_TAG)
