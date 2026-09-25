.PHONY: help build test image cluster cluster-down load deploy undeploy \
        chaos-pod chaos-crash chaos-hang chaos-unready chaos-rollout chaos-drain chaos-all \
        metrics-server load-spike load-steady gke-up gke-down oke-up oke-down chaos-ca status logs

CLUSTER ?= autoheal
RELEASE ?= autoheal
IMAGE   ?= autoheal-api:dev

help:
	@echo "Setup:"
	@echo "  make test          - run app unit tests"
	@echo "  make image         - build the container image"
	@echo "  make cluster       - create the kind cluster"
	@echo "  make load          - load the image into the cluster"
	@echo "  make deploy        - install/upgrade the Helm release"
	@echo ""
	@echo "Chaos scenarios:"
	@echo "  make chaos-pod     - T1: delete a pod, expect recovery under 30s"
	@echo "  make chaos-crash   - T2: /crash, expect in-place container restart"
	@echo "  make chaos-hang    - T3: /hang, expect liveness to restart it"
	@echo "  make chaos-unready - T4: /ready 503, expect removal from endpoints"
	@echo "  make chaos-rollout - T7: bad image, expect stalled rollout + undo"
	@echo "  make chaos-drain   - T8: drain a node, expect PDB to hold"
	@echo "  make chaos-all     - run every scenario in sequence"
	@echo ""
	@echo "Autoscaling:"
	@echo "  make metrics-server - install metrics-server (needed by the HPA)"
	@echo "  make load-spike    - T5+T6: k6 spike, expect 2 -> 8 -> 2 replicas"
	@echo "  make load-steady   - steady k6 background traffic (RATE, DURATION)"
	@echo ""
	@echo "Cloud (GKE, costs money):"
	@echo "  make gke-up        - terraform cluster + deploy everything (PROJECT_ID=...)"
	@echo "  make chaos-ca      - T9: exhaust capacity, expect Cluster Autoscaler to add a node"
	@echo "  make gke-down      - tear it all down (PROJECT_ID=...)"
	@echo ""
	@echo "Cloud (OKE, costs money):"
	@echo "  make oke-up        - terraform cluster + deploy everything (COMPARTMENT_OCID=...)"
	@echo "  make chaos-ca      - T9, same script as on GKE"
	@echo "  make oke-down      - tear it all down"
	@echo ""
	@echo "  make status        - show pods, endpoints, PDB"

test:
	cd app && npm test

image:
	cd app && docker build -t $(IMAGE) .

cluster:
	kind create cluster --config kind/kind-config.yaml

cluster-down:
	kind delete cluster --name $(CLUSTER)

load:
	kind load docker-image $(IMAGE) --name $(CLUSTER)

deploy:
	helm upgrade --install $(RELEASE) helm/autoheal-api

undeploy:
	helm uninstall $(RELEASE)

chaos-pod:
	@bash chaos/t1-pod-crash.sh

chaos-crash:
	@bash chaos/t2-process-crash.sh

chaos-hang:
	@bash chaos/t3-hang.sh

chaos-unready:
	@bash chaos/t4-unready.sh

chaos-rollout:
	@bash chaos/t7-bad-rollout.sh

chaos-drain:
	@bash chaos/t8-node-drain.sh

chaos-all:
	@bash chaos/run-all.sh

metrics-server:
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
	helm upgrade --install metrics-server metrics-server/metrics-server 	  -n kube-system -f kind/metrics-server-values.yaml --wait

load-spike:
	@bash chaos/t5-t6-autoscale.sh

load-steady:
	@bash load/k6.sh load/steady.js

gke-up:
	@bash infra/gke/up.sh

gke-down:
	@bash infra/gke/down.sh

oke-up:
	@bash infra/oke/up.sh

oke-down:
	@bash infra/oke/down.sh

chaos-ca:
	@bash chaos/t9-cluster-autoscaler.sh

status:
	@kubectl get pods -l app.kubernetes.io/name=autoheal-api -o wide
	@echo
	@kubectl get endpoints $(RELEASE)-autoheal-api
	@echo
	@kubectl get pdb
	@echo
	@kubectl get hpa

logs:
	@kubectl logs -l app.kubernetes.io/name=autoheal-api --tail=50 -f
