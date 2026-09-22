# autoheal-k8s

Self-healing, autoscaling Kubernetes demo. Full proposal in [claude.md](claude.md).

## Local setup (Week 1-2)

```bash
# 1. App: install deps, run tests
cd app
npm install
npm test

# 2. Build the image
docker build -t autoheal-api:dev .

# 3. Create the local cluster (control-plane + 2 workers, ports 8080/8443 mapped for ingress)
cd ..
kind create cluster --config kind/kind-config.yaml

# 4. Load the image into the cluster (kind nodes can't pull local-only images)
kind load docker-image autoheal-api:dev --name autoheal

# 5. Install an ingress controller (ingress-nginx, kind-flavored manifest)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

# The controller binds hostPort 80/443, but only the control-plane node carries
# the extraPortMappings from kind-config.yaml. Pin it there, or localhost:8080
# will return empty replies.
kubectl patch deployment -n ingress-nginx ingress-nginx-controller --type=strategic \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/os":"linux","ingress-ready":"true"}}}}}'

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# 6. Deploy the app
helm install autoheal helm/autoheal-api

# 7. Hit it (maps to ingress.host in values.yaml)
curl -H "Host: autoheal.local" http://localhost:8080/healthz
```

## Observability (Week 3)

Run these once the cluster from the previous section is up. The values file trims
retention and resources so the stack fits alongside kind on a laptop.

```bash
# 1. Install the monitoring stack (release name must be "monitoring": the chart
#    only discovers ServiceMonitors/PrometheusRules labelled release=monitoring)
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f observability/values-kube-prometheus-stack.yaml

# 2. Point Prometheus at the app
helm upgrade autoheal helm/autoheal-api --set serviceMonitor.enabled=true

# 3. Load the dashboard (the Grafana sidecar watches for this label)
kubectl create configmap autoheal-dashboard \
  -n monitoring --from-file=observability/grafana-dashboard.json
kubectl label configmap autoheal-dashboard -n monitoring grafana_dashboard=1

# 4. Load the alert rules
kubectl apply -f observability/alert-rules.yaml

# 5. Open Grafana (admin / admin) and Prometheus
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
```

Verify the app is actually being scraped at Prometheus → Status → Targets, or:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up{job="autoheal-api"}'
```

| File | Purpose |
|---|---|
| [observability/values-kube-prometheus-stack.yaml](observability/values-kube-prometheus-stack.yaml) | Slimmed stack config for kind |
| [observability/grafana-dashboard.json](observability/grafana-dashboard.json) | Dashboard: RED metrics, replicas, HPA, restarts, readiness, nodes |
| [observability/alert-rules.yaml](observability/alert-rules.yaml) | Crash-loop, HPA-at-max, error-rate and PDB alerts |

## Chaos scenarios (Week 4)

Each script asserts a pass condition and exits non-zero on failure. Measured
results are in [docs/test-report.md](docs/test-report.md).

```bash
make chaos-pod      # T1: delete a pod, expect recovery under 30s
make chaos-crash    # T2: /crash, expect in-place container restart
make chaos-hang     # T3: /hang, expect liveness to restart it
make chaos-unready  # T4: /ready 503, expect endpoint removal without restart
make chaos-rollout  # T7: readiness never passes, expect stalled rollout + undo
make chaos-drain    # T8: drain a node, expect the PDB to hold
make chaos-all      # everything, with a results table
```

Resilience settings live in [helm/autoheal-api/values.yaml](helm/autoheal-api/values.yaml):
`maxUnavailable: 0` (a new pod must be Ready before an old one goes), a
PodDisruptionBudget with `minAvailable: 1`, and `topologySpreadConstraints` to
spread replicas across nodes.

Spreading uses `topologySpreadConstraints` rather than preferred
`podAntiAffinity`: the latter is only a scheduler hint, and in testing it placed
both replicas on the same node — the exact failure it was meant to prevent.
`whenUnsatisfiable: ScheduleAnyway` is deliberate, so the HPA can still scale to
8 replicas on a 2-worker cluster instead of leaving pods Pending.

## Endpoints

| Path | Purpose |
|---|---|
| `GET /healthz` | Liveness probe target |
| `GET /ready` | Readiness probe target |
| `GET /startupz` | Startup probe target |
| `GET /work?durationMs=` | CPU-heavy endpoint for load testing |
| `GET /hang?durationMs=` | Blocks the event loop (simulates a hung app) |
| `POST /crash` | Exits the process (simulates a crash) |
| `POST /chaos/unready` | Forces `/ready` to 503 for N seconds |
| `GET /metrics` | Prometheus metrics |
