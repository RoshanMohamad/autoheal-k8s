.PHONY: help build test image cluster cluster-down load deploy undeploy \
        chaos-pod chaos-crash chaos-hang chaos-unready chaos-rollout chaos-drain chaos-all \
        status logs

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

status:
	@kubectl get pods -l app.kubernetes.io/name=autoheal-api -o wide
	@echo
	@kubectl get endpoints $(RELEASE)-autoheal-api
	@echo
	@kubectl get pdb

logs:
	@kubectl logs -l app.kubernetes.io/name=autoheal-api --tail=50 -f
