# Experiment procedure

[Back to README](../README.md) · [Operations](operations.md) · [Recorded results](results.md)

Use paired runs to compare one fixed worker with queue-based autoscaling. This is a procedure for future measurements; it does not imply these controls were captured in the initial results.

## Record the environment

Capture the commit, Kind/Kubernetes/Docker/Helm versions, installed KEDA chart, node resources, loaded image IDs, worker logs showing effective delay and prefetch, worker resource configuration, and ScaledObject configuration. Use a single timezone and record timestamps with an explicit offset.

```bash
git rev-parse HEAD
kind version
kubectl --context kind-freekubelab version
docker version
helm version
helm --kube-context kind-freekubelab list -n keda
kubectl --context kind-freekubelab get nodes -o wide
kubectl --context kind-freekubelab get deployment worker-deployment -n keda-rabbitmq-autoscaling -o yaml
kubectl --context kind-freekubelab get scaledobject rabbitmq-scaledobject -n keda-rabbitmq-autoscaling -o yaml
```

Do not include Secret values, passwords, or connection URLs containing credentials in shared evidence.

## Baseline: one fixed worker

Pause KEDA at one replica and confirm the actual state before publication:

```bash
kubectl --context kind-freekubelab annotate scaledobject rabbitmq-scaledobject \
  -n keda-rabbitmq-autoscaling autoscaling.keda.sh/paused-replicas='1' --overwrite
kubectl --context kind-freekubelab rollout status deployment/worker-deployment \
  -n keda-rabbitmq-autoscaling --timeout=180s
kubectl --context kind-freekubelab get deployment worker-deployment -n keda-rabbitmq-autoscaling
```

Wait for one ready worker and one RabbitMQ consumer. Confirm that ready and unacknowledged queue counts are both zero. Start recording queue counts and replicas, then publish 500 messages using the operations guide. Confirm 500 publications and successful Job completion. Keep recording until both queue counts reach zero; verify the worker stayed at one replica throughout.

## Autoscaling: zero to five workers

Remove the pause annotation:

```bash
kubectl --context kind-freekubelab annotate scaledobject rabbitmq-scaledobject \
  -n keda-rabbitmq-autoscaling autoscaling.keda.sh/paused-replicas-
kubectl --context kind-freekubelab get scaledobject,hpa -n keda-rabbitmq-autoscaling
```

Before publishing, verify that no other pause annotations remain, the scaler is Ready, the queue is empty, and the Deployment has reached zero replicas. Publish the same 500-message workload with the same worker image, delay, prefetch, and resource configuration.

Record first desired replica, first ready replica, RabbitMQ consumer count, peak ready replicas, ready/unacknowledged queue counts, and return to zero. Confirm completion from queue counts rather than from pod removal alone. After the test, leave KEDA unpaused unless intentionally preparing another baseline.

## Measurement definitions

| Measurement | Start | End |
| --- | --- | --- |
| End-to-end run time | Immediately before load script invocation | Observed ready = 0 and unacknowledged = 0 after confirmed publication |
| Publication-to-drain interval | Final publication confirmation | Observed ready = 0 and unacknowledged = 0 |
| Script-to-ready delay | Load script invocation | First observed ready worker |
| Idle-to-zero interval | Recorded queue-completion observation | First observed zero-replica state |

Record the observation interval; sampled timestamps limit precision. An idle-to-zero interval is not the configured cooldown measurement because the last active ready-message observation can precede completion of in-flight processing.

Repeat at least three paired runs and report every run, a median, and a range. Keep baseline and KEDA conditions identical, document exclusions, and prevent overlapping producers. Separate elapsed-time reduction from throughput, infrastructure cost, and message-delivery guarantees, which need their own measurements.

## Additional scenarios

| Scenario | Change | Evidence to collect |
| --- | --- | --- |
| Slow consumer | Increase processing delay consistently | Backlog, replicas, and drain time |
| Replica ceiling | Increase workload beyond five workers' capacity | Backlog while replicas remain capped |
| Interrupted worker | Terminate a worker during processing | Message ID redelivery and subsequent ACK |
| Broker restart | Restart the broker with queued persistent messages | Queue counts before/after and successful consumption |
| Invalid payload | Publish malformed synthetic input | NACK behavior and discarded/dead-lettered outcome |

Use synthetic data. Finish collecting evidence before cleanup; `--delete-data` can discard broker data.
