# Architecture and design decisions

[Back to README](../README.md) · [Operations](operations.md) · [Results](results.md)

![Architecture overview](architecture.png)

The cluster boundary in the image groups the lab components. The application resources live in `keda-rabbitmq-autoscaling`; the KEDA installation lives in the separate `keda` namespace. The generated HPA belongs to the application namespace. The credential arrow represents the scaler's Secret reference; the producer, worker, and broker also use the Secret, although their credential paths are omitted for readability.

## Component responsibilities

| Component | Implementation | Responsibility |
| --- | --- | --- |
| Producer | Python application in a Kubernetes Job | Declare `tasks`, publish JSON payloads, and confirm publication |
| Broker | RabbitMQ StatefulSet, one replica | Store and deliver messages; expose AMQP and management ports |
| Service | Headless Service `rabbitmq` | Provide in-cluster broker discovery |
| Storage | PVC `data-rabbitmq-0`, requested size 1 Gi | Persist broker data across pod replacement |
| Worker | Python application in `worker-deployment` | Consume, simulate processing, and acknowledge completed work |
| ScaledObject | `rabbitmq-scaledobject` | Associate queue demand with the worker Deployment |
| TriggerAuthentication | `keda-trigger-auth-rabbitmq` | Reference connection and credential keys in `rabbitmq-credentials` |
| KEDA / HPA | Operator and generated HPA | Activate from zero, scale active workers, and return to zero |

## Message lifecycle

1. The producer declares a durable queue and enables publisher confirms.
2. It publishes persistent JSON messages through the default exchange with `tasks` as the routing key and mandatory routing enabled. Each payload contains a UUID and UTC publication timestamp.
3. RabbitMQ delivers messages to workers. Prefetch defaults to one and automatic acknowledgements are disabled.
4. A worker validates the payload and simulates processing for the configured delay while servicing connection events.
5. Successful processing ends with a manual ACK. Interrupted work remains unacknowledged and can be redelivered after the consumer connection closes.

Publisher confirmation means the broker accepted publication; it does not mean a worker finished processing. The combination of confirms, durable queues, persistent messages, and storage provides persistence mechanisms, but broker restart behavior has not been experimentally established here.

Malformed payloads are negatively acknowledged with `requeue=False`. With no dead-letter configuration, they are discarded. Workers exit on handled connection failures; they do not implement an application-level reconnect/backoff loop. Kubernetes may restart the container, which is a separate recovery mechanism.

Duplicate delivery and processing remain possible. A production consumer needs idempotent business operations and an explicit retry/dead-letter policy; this lab does not guarantee exactly-once processing.

## Scaling lifecycle

The scaler uses AMQP `QueueLength` with a target of 100 ready messages per replica. The configured bounds are zero to five workers, the polling interval is five seconds, and the return-to-zero cooldown is 60 seconds.

KEDA handles activation from zero and return to zero. While replicas are active, KEDA exposes metrics used by the generated HPA. The HPA applies scaling decisions to the Deployment. Do not attach a separate independent HPA to the same target.

Queue length is a demand signal, not a processing-completion signal. Under AMQP, ready messages can reach zero while messages are still unacknowledged. Record both counts when measuring drain time. Scaling also depends on reconciliation, stabilization, scheduling, and pod startup; the target is not a guarantee of an immediate replica count.

The worker manifest starts with one replica; KEDA subsequently manages its desired replica count. A pod without a readiness probe can be Ready before its consumer connection is established. Compare Kubernetes replicas with RabbitMQ consumer counts.

## Decisions and tradeoffs

| Decision | Benefit | Tradeoff or remaining validation |
| --- | --- | --- |
| Kind and locally loaded images | Low-cost local Kubernetes experiment | Images must be loaded into cluster nodes; fresh setup remains unverified |
| One broker with PVC | Simple persistence setup | Single point of failure; no broker HA or recovery benchmark |
| Queue-length scaling | Direct response to queued demand | Ready count excludes in-flight work and does not capture processing complexity |
| Prefetch of one | Bounded in-flight work per consumer | Throughput tradeoff depends on processing and network characteristics |
| Maximum of five workers | Bounded lab resource demand | Backlog can continue growing at the replica ceiling |
| Kubernetes Secret injection | Credentials absent from source manifests | Secret values are not inherently encrypted by base64; access control is still required |
| Local mutable image tags | Convenient rebuilds for a lab | Record image IDs/digests to establish experiment configuration equality |
| No automatic producer Job retries | Avoid replaying a partially published batch automatically | Failed publication requires inspecting confirmed counts before rerunning |

## Operational boundaries

Setup does not create the cluster or install its storage provisioner. It installs the requested KEDA chart only when absent and refuses an incompatible existing release. Repeated setup rebuilds local images and requests a worker rollout, so run it between experiments after draining the queue.

Cleanup retains the namespace, cluster, KEDA installation, PVC, and credentials by default. Deleting broker data requires `--delete-data`. The lab does not configure TLS, NetworkPolicies, dedicated workload RBAC, or a production secrets-management system.
