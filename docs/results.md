# Experiment results

[Back to README](../README.md) · [Experiment procedure](experiments.md) · [Architecture](architecture.md)

## Summary and evidence scope

Two manual 500-message runs were recorded on Kind. The fixed-worker run took approximately 1008 seconds; the KEDA run took approximately 242 seconds from script invocation to reported queue completion, with five ready workers observed at peak. KEDA also returned the Deployment to zero.

The observed elapsed-time reduction is `(1008 - 242) / 1008 × 100 ≈ 76.0%`, and the elapsed-time ratio is `1008 / 242 ≈ 4.17`. These are descriptive calculations for one pair of runs. They do not establish repeatability, a throughput benchmark, or resource-cost savings.

Evidence below consists of producer logs, deployment-watch timestamps, and operator reports; raw logs are not included in this document. Exact software/image versions and runtime configuration equality were not captured. The baseline completion report included Ready and Unacked both zero; the KEDA completion report did not provide these counts separately. No new cluster experiment was performed during this documentation revision.

## First single-worker baseline

Recorded from the project owner's terminal output and completion report. Local timestamps use America/Araguaina (UTC−03:00).

| Field | Evidence |
| --- | --- |
| Cluster context | `kind-freekubelab` |
| Namespace | `keda-rabbitmq-autoscaling` |
| Producer Job | `producer-load-bqxgd` |
| Requested messages | 500 |
| Confirmed publications | 500, from producer logs |
| Run start | 2026-10-08 23:55:42 −03:00, immediately before invoking the script |
| Publication confirmation | 2026-10-08 23:55:44.176 −03:00; producer log timestamp was 2026-10-09 02:55:44.176 UTC |
| Reported queue completion | 2026-10-09 00:12:30 −03:00 |
| Start to reported completion | Approximately 16 min 48 s (1008 s) |
| Publication confirmation to reported completion | Approximately 16 min 46 s |
| Worker count | One worker throughout the run, confirmed by the project owner; watch output shows `1/1` before publication |
| Processing delay | Application default: 2 s; runtime value not separately captured |
| Autoscaling pause | Pause annotation not captured; the project owner confirmed no scale-out during the run |
| Initial queue state | Empty; the earlier 1000-message workload had finished, confirmed by the project owner |
| Final queue state | Ready and Unacked both zero at 00:12:30, confirmed by the project owner |
| Errors and restarts | None observed, confirmed by the project owner |
| Redeliveries | Not separately measured |

The start-to-completion measurement includes script execution, Job startup, publication, and consumption. Completion was reported manually, so subsecond precision is not warranted. The project owner confirmed both Ready and Unacked were zero at completion.

The deployment watch began at 23:50:50 with `0/0` and showed `1/1` at 23:52:11, before this 500-message run. These timestamps do not measure activation latency for this run. The full-run replica count is based on the project owner's confirmation rather than a complete watch recording.

A separate invocation created `producer-load-gcqbr` requesting 1000 messages. The project owner confirmed that workload had finished before this run. Its timing is excluded from the 500-message baseline.

The processing delay still needs explicit runtime confirmation before interpreting per-message performance or comparing with a changed worker configuration. Use the same configuration for the KEDA run.

## KEDA comparison

The second timed run used KEDA and requested the same 500-message workload. Evidence comes from producer logs, a timestamped deployment watch, and the completion time supplied by the project owner.

| Field | Evidence |
| --- | --- |
| Cluster context | `kind-freekubelab` |
| Producer Job | `producer-load-c27ms` |
| Requested / confirmed publications | 500 / 500 |
| Initial deployment state | `0/0` at 2026-10-09 00:22:04 −03:00 |
| Run start | 2026-10-09 00:22:26 −03:00 |
| Publication confirmation | 2026-10-09 00:22:27.945 −03:00; producer log timestamp was 03:22:27.945 UTC |
| First desired replica | `0/1` at 00:22:27, approximately 1 s after run start |
| First ready worker | `1/1` at 00:22:28, approximately 2 s after run start |
| Four ready workers | `4/4` at 00:22:33, approximately 7 s after run start |
| Peak ready workers | `5/5` at 00:22:48, approximately 22 s after run start |
| Reported queue completion | 2026-10-09 00:26:28 −03:00 |
| Start to reported completion | Approximately 4 min 2 s (242 s) |
| Publication confirmation to reported completion | Approximately 4 min |
| Return to zero | `0/0` at 00:26:52, also observed at 00:26:53 |
| Reported completion to zero | Approximately 24 s |
| Start to zero | Approximately 4 min 26 s (266 s) |
| Errors / restarts / redeliveries | Not separately reported or measured |

The first-ready delay is measured from script invocation, not from the first message reaching RabbitMQ. The completion timestamp is interpreted as the queue-empty observation requested in the test procedure; separate Ready and Unacked counts were not supplied for this run. The deployment watch establishes replica changes, not message acknowledgements.

The observed 24-second interval from reported completion to zero is not a measurement of the configured 60-second cooldown. The AMQP trigger measures ready messages; its last active observation can precede the completion of unacknowledged work. Polling and manual observation also affect these timestamps. The exact last-active time was not captured.

## First-round comparison

| Metric | Single worker | KEDA |
| --- | --- | --- |
| Confirmed publications | 500 | 500 |
| Peak ready workers | 1, confirmed by project owner | 5, captured in deployment watch |
| Start to reported queue completion | 1008 s (16 min 48 s) | 242 s (4 min 2 s) |
| Start to first ready worker | Already ready before publication | Approximately 2 s |
| Reported completion to zero | Not applicable | Approximately 24 s |

For these two runs, the observed elapsed-time ratio is `1008 / 242 ≈ 4.17`: the KEDA run took approximately 76.0% less time, saving 12 min 46 s. This is an initial manual comparison, not an average or a general performance guarantee. Confirm that the runtime processing delay, images, and resource configuration were identical; repeat both scenarios before drawing broader conclusions. The configured processing default is 2 seconds, but the effective runtime value was not separately captured.
