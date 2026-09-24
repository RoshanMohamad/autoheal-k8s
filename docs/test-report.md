# Chaos Test Report — Week 4

Environment: local `kind` cluster (control-plane + 2 workers, Kubernetes v1.37.0),
`autoheal-api:dev`, 2 replicas, `minAvailable: 1`, `maxUnavailable: 0 / maxSurge: 1`.

Reproduce with `make chaos-all`, or individually (`make chaos-pod`, `make chaos-crash`, …).
Every script asserts its own pass condition and exits non-zero on failure.

Figures below are from a single clean `make chaos-all` run in which all six
scenarios passed. Two bugs found across earlier repeated runs are recorded below.

## Results

| # | Scenario | Expected | Observed | Result |
|---|---|---|---|---|
| T1 | Pod crash (`kubectl delete pod`) | Replacement Ready < 30s | Ready in **10s** | PASS |
| T2 | Process crash (`/crash` → `exit(1)`) | Container restarts, count increments | Restart at **3s**, Ready at **5s**, pod name unchanged | PASS |
| T3 | Hung app (`/hang` blocks event loop) | Liveness fails 3× then restarts | Killed at **51s**, Ready again in **2s** | PASS |
| T4 | Not ready (`/ready` → 503) | Removed from endpoints, no restart | Removed in **10s**, **0 restarts**, rejoined after **34s** | PASS |
| T7 | Bad rollout (readiness never passes) | Rollout stalls, old pods serve, undo restores | Rollout stalled (new pod 0/1), **2/2 endpoints kept serving**, undo restored | PASS |
| T8 | Node drain | Available replicas never below PDB minimum | Lowest observed **1**, equal to `minAvailable: 1` | PASS |

## Objectives evidenced

- **O1** (crash recovery < 30s) — T1: 10s.
- **O2** (liveness restarts hung container within 3 checks) — T3: exactly 3 failures, then restart.
- **O3** (readiness keeps traffic away) — T4: endpoint removed while the container kept running.
- **O6** (zero-downtime deploys) — T7: a deliberately broken rollout never reduced serving capacity,
  because `maxUnavailable: 0` blocks removing an old pod until a new one is Ready.
- **O7** (survive voluntary disruption) — T8: drain honoured the PodDisruptionBudget.

## Replica spreading

Not one of the numbered scenarios, but part of the same phase and worth recording
because the first implementation did not work.

| Mechanism | Observed |
|---|---|
| `podAntiAffinity` (preferred) | Both replicas scheduled onto **the same node** |
| `topologySpreadConstraints` (`maxSkew: 1`, `ScheduleAnyway`) | Replacement pod scheduled onto the **empty node**, 1 per node |

Preferred anti-affinity is only a scheduler hint and was routinely outweighed by
node-resource scoring, leaving both replicas on one node — meaning a single node
failure would have taken out the whole service. Switched to
`topologySpreadConstraints`.

One caveat that applies to both mechanisms: spreading is evaluated at *scheduling*
time only. During a rolling update the scheduler counts the old pods that are
about to terminate, so new pods can pile onto the "emptier" node and stay there
once the old ones go. Kubernetes does not rebalance running pods; correcting that
continuously needs the descheduler. Fresh scheduling — replacements, scale-ups —
spreads correctly.

## Bugs found by re-running the suite

Both scenarios passed individually on the first attempt and only failed when the
suite was run repeatedly — a reminder that a single green run proves little.

1. **T3 was racing its own clamp.** The app clamps `/hang` to `MAX_HANG_MS`, which
   was set to 30000ms. The liveness budget is `periodSeconds 10 × failureThreshold 3`
   = exactly 30s, so whether the third probe failure landed before the hang ended
   was a coin flip. Raised `MAX_HANG_MS` to 60000, and T3 now asserts up front that
   the clamp exceeds the liveness budget rather than flaking when it does not.
2. **Scenarios were contaminating each other.** T4 asserts the restart count does
   *not* change, so a container still restarting from T3 failed it. A fixed
   `sleep 10` between scenarios was not enough; `run-all.sh` now waits for genuine
   quiescence (expected replicas Ready *and* restart count stable across
   consecutive samples) via `settle()` in `lib.sh`.

## Notes and caveats

- **T2 vs T1 distinction.** T2's value is that the pod *name is unchanged*: the kubelet restarted the
  container in place, rather than the ReplicaSet creating a replacement as in T1. Two different
  recovery mechanisms, and the report distinguishes them deliberately.
- **T7 restore time reads as ~1s.** This is not a measurement error — availability never dropped, so
  the "recovered" condition was essentially already true when rollback began. That is the point of
  the scenario.
- **T8 sampling is coarse.** Availability was polled every 2s and the drain completed quickly, so only
  3 samples were captured. The minimum observed equalled the PDB floor rather than proving a
  sub-2-second dip never occurred. A longer drain (more replicas, or a slower `terminationGracePeriod`)
  would give stronger evidence.
- **T5/T6 (autoscaling)** are Week 5; see the Week 5 report below.
- **The runs above did not measure request-level availability.** That was added later; see
  the next section.

## Availability under background traffic

Rerun of the full suite with the HPA enabled (Week 5 chart) and k6 sending a steady
10 req/s through the ingress for each scenario (`make chaos-all`; `LOAD=0` turns it off).
Each scenario gets its own k6 run, from 10s before injection to the end of its checks.

| # | Result | Key timing | Requests | Failed | Availability |
|---|---|---|---|---|---|
| T1 | PASS | Capacity restored in **14s** | 222 | 0 | **100.00%** |
| T2 | PASS | Restart at 3s, Ready at **7s** | 323 | 0 | **100.00%** |
| T3 | PASS | Liveness killed it at **54s** | 650 | **56** | **91.38%** |
| T4 | PASS | Out of endpoints in **7s**, 0 restarts, back after 34s | 630 | 0 | **100.00%** |
| T7 | PASS | Rollout stalled, 4/4 endpoints kept serving | 681 | 0 | **100.00%** |
| T8 | PASS | Lowest ready during drain: 3 (PDB min 1) | 174 | 0 | **100.00%** |
| | | **Total** | **2680** | **56** | **97.91%** |

Across the suite, 99.5% availability holds in every scenario except T3, and T3 alone takes
the total below target. Pod crashes, process crashes, readiness failures, a bad rollout and a
node drain cost **zero** user requests. Only a *hung* pod does.

**Why T3 loses requests, and what would fix it.** A hung pod is still a Service endpoint until
its readiness probe fails 3 times (`periodSeconds 5 × failureThreshold 3` ≈ 15s, plus
`timeoutSeconds 3` per attempt). Until then, roughly half of all requests go to a pod whose event
loop is blocked, and they hit k6's 10s timeout. Options, not yet applied:
- Tighten readiness to `periodSeconds: 2, failureThreshold: 2, timeoutSeconds: 1`, cutting
  detection to about 4s. The cost is more probe traffic and more sensitivity to GC pauses.
- Set ingress-nginx `proxy-next-upstream-timeout` / `proxy-read-timeout` to a few seconds, so
  the ingress retries a slow upstream on another pod instead of waiting.

## Bugs found by adding the HPA and traffic

1. **"Recovered" checks assumed a fixed replica count.** T1, T2, T3 and T7 waited for ready
   pods to *equal* the starting count. With the HPA in play, a scale-out during a scenario meant
   that count was never matched again, and T1 failed even though capacity recovered in seconds. They
   now wait for *at least* the starting count (`ready_at_least` in `lib.sh`).
2. **Background traffic can trigger the HPA.** At 20 req/s, deleting one pod pushed the survivor
   above 60% of its 100m CPU request, and the HPA scaled 2 → 4 mid-scenario. That is correct HPA
   behaviour, but it confounds the chaos results. Background rate lowered to 10 req/s, which one pod
   can carry alone.
3. **A hung pod looks like a busy pod.** `/hang` spins the CPU, so T3 drove the HPA to 6
   replicas. A real deadlock would idle instead, so this is specific to how the hang is simulated.
   The next scenarios then started scaled out (T4 at 6 pods, T7 and T8 at 4). The settle step
   between scenarios now waits up to 480s, which covers the HPA's 300s scale-down window.
4. **The T8 drain also evicts metrics-server.** It runs as a single replica, so the HPA
   has no CPU data until it reschedules. That is harmless in this run. In production, metrics-server
   would want 2 replicas and its own PDB.

## Grafana evidence: deferred

The proposal asks for a Grafana screenshot of each scenario. `observability/snapshot.sh`
turns the per-scenario windows written by `run-all.sh` into PNGs. However, the dev laptop (8 GB RAM,
Docker VM capped at 3.9 GB) could not run kube-prometheus-stack alongside the tests: the VM thrashed
(load average 66, ~50% of CPU time in the kernel), and the API server, controller-manager and
scheduler crash-looped. Idle pods also reported phantom CPU that kept the HPA scaled out. The numbers
above were therefore measured with the monitoring stack **uninstalled**. Screenshots are deferred to
the Week 6 cloud cluster or a 16 GB machine.

---

# Autoscaling Test Report — Week 5

Environment: as above, plus metrics-server (`--kubelet-insecure-tls`) and the
`autoscaling/v2` HPA: min 2, max 8, target 60% CPU of the 100m request,
scale-up +100%/60s, scale-down 300s window then −50%/60s.

Reproduce with `make metrics-server && make deploy && make load-spike`. The script
writes a per-5s timeline (replicas, desired, CPU%, ready) and the k6 log to
`load/results/`.

## Results

| # | Scenario | Expected | Observed | Result |
|---|---|---|---|---|
| T5 | Traffic spike (k6 10 → 500 VUs over 5 min on `/work`, 3 min hold) | 2 → 4 → 8 within 180s of CPU > 60%; availability ≥ 99.5%; p95 recovers | 2 → 4 → 8 in **74s**; **56,899 requests, 0 failed (100%)**; p95 **68.5 ms** once scaled out | PASS |
| T6 | Load ends | Back to 2 within 600s, no flapping | Back to 2 in **389s**, 8 → 4 → 2, **no flaps** | PASS |

## Timeline

T5, measured from k6 start:

| t | Event |
|---|---|
| 0s | 2 replicas, CPU 8% |
| 51s | CPU 107% crosses the 60% target; HPA wants 4 |
| 68s | 4 replicas Ready (CPU 184%) |
| 114s | HPA wants 8. It was held for one 60s policy period after the first step (+100%/60s) |
| 125s | **8 replicas Ready**, 74s after the threshold crossing |
| 300–480s | Held at 8 at ~240% CPU. The HPA is pinned at max for the whole hold |

T6, measured from k6 exit:

| t | Event |
|---|---|
| 0–313s | Held at 8 while the 300s stabilisation window expires |
| 313s | Desired 4 (−50% policy) |
| 330s | 4 replicas |
| 378s | Desired 2 |
| 389s | **2 replicas** |

## Objectives evidenced

- **O4** (scale out 2 → 8 within 3 min): 74s. The scale-up policy is visible:
  exactly one doubling per 60s period, with no jump straight to 8.
- **O5** (back to 2 within 10 min, no flapping): 389s, strictly decreasing. The stabilisation window
  accounts for 300s of it: that time is deliberately bought insurance against a returning spike.
- **Availability**: 0 failed requests out of 56,899 across a 50× load ramp.

## Notes and caveats

- **8 replicas was not enough capacity by the HPA's own measure.** CPU sat at ~240% of request
  on all 8 pods during the hold. Pods could burst to their 300m limit, so latency stayed healthy
  (p95 68.5 ms), but the HPA wanted more than `maxReplicas`. In production this is the
  `AutohealHPAAtMaxReplicas` alert's job. The hold (3 min) is shorter than that alert's 10 min
  `for:`, so it would not have fired here. A deliberate test of the alert needs a longer hold.
- **The 60% target is measured against a 100m request.** Small absolute changes move it a lot:
  10 req/s of `/work?durationMs=2` is ~35% on a single pod. This is why the chaos suite's background
  traffic had to be lowered, as recorded above.
- **Scale-up p95 is not broken out.** The overall p95 (117.5 ms) includes the first minute on
  2 overloaded pods. Only the "once scaled out" p95 is tagged separately (`phase:recovered` in
  `load/spike.js`).
- Raw per-5s timeline and k6 log: `load/results/t5-t6-20260923-221013-*` (git-ignored).

---

# Cloud Test Report — Week 6

Environment: GKE zonal cluster, node pool of 2–4 × e2-standard-2 with the Cluster
Autoscaler (`OPTIMIZE_UTILIZATION` profile), kube-prometheus-stack installed.
Created with `make gke-up`, torn down with `make gke-down`.

| # | Scenario | Expected | Observed | Result |
|---|---|---|---|---|
| T9 | Node capacity exhausted (8 replicas × 500m CPU) | Pending pods trigger a node add; all replicas Ready | _not yet run_ | — |

The kind-side checks run so far only cover T9's safety and plumbing, not the Cluster Autoscaler itself:
- It refuses to run on kind (detects `kind://` provider IDs).
- It counts only *unschedulable* pods (`PodScheduled=False`), not pods that are merely starting.
- Its restore step returns the HPA and container resources to their original values.
