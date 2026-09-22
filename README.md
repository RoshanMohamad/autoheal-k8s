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
