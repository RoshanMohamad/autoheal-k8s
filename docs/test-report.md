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
- **T5/T6 (autoscaling)** are Week 5; see the section below.
- **Availability during chaos was not measured as an SLI here.** These runs assert control-plane
  behaviour (replica counts, endpoints, restarts), not request-level success rate. The 99.5%
  availability figure needs k6 driving background traffic (Week 5) plus the Prometheus SLI query
  already written in [../observability/grafana-dashboard.json](../observability/grafana-dashboard.json).

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
| T5 | Traffic spike (k6 10 → 500 VUs over 5 min on `/work`, 3 min hold) | 2 → 4 → 8 within 180s of CPU > 60%; availability ≥ 99.5%; p95 recovers | _not yet run_ | — |
| T6 | Load ends | Back to 2 within 600s, no flapping | _not yet run_ | — |

## Objectives to be evidenced

- **O4** (scale out under load): T5 scale-up time, measured from the first HPA
  sample with CPU above target to `currentReplicas == 8`.
- **O5** (scale in without flapping): T6 time from k6 exit to 2 replicas; any
  rise in the replica count after it has started falling counts as a flap.
- **Availability SLI**: k6's `http_req_failed` rate over the whole spike, which
  is request-level evidence that the chaos runs above did not collect.
