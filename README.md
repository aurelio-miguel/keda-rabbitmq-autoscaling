# keda-rabbitmq-autoscaling

Event-driven autoscaling of Python workers on Kubernetes using RabbitMQ and KEDA.

> **Status: end-to-end autoscaling manually validated on Kind.** RabbitMQ, the producer Job, and the worker Deployment are deployed. KEDA activated workers from zero, scaled up to five replicas, and returned to zero after consumption. Automation scripts, quantitative measurements, and CI remain planned.

## Why this project?

Message queues absorb bursts of work, but a fixed number of consumers can leave a growing backlog or waste resources during idle periods. This project demonstrates how to scale consumers based on queue demand rather than CPU utilization alone.

The goal is to publish a controlled workload, observe workers scaling out, drain the queue, and observe scaling back down. This cycle has been manually validated on Kind. Reproducing it from a clean setup and recording timings are the next steps; Minikube support remains planned.

## Architecture

| Component | Responsibility |
| --- | --- |
| Producer | Publish a configurable number of synthetic messages |
| RabbitMQ | Store messages until consumers process them |
| Worker Deployment | Consume messages and simulate processing time |
| KEDA ScaledObject | Define the queue trigger and scaling boundaries |
| KEDA TriggerAuthentication | Reference RabbitMQ credentials stored in a Kubernetes Secret |
| Kubernetes | Schedule and run the components |

The producer publishes to RabbitMQ; workers consume from the same queue. KEDA observes queue demand, handles activation from zero, and supplies metrics to a Kubernetes HPA for scaling while workers are active. KEDA does not consume application messages or create cluster nodes.

## Initial scope

- Python producer and worker, packaged as separate Docker images.
- Single RabbitMQ instance with its management interface for observation.
- A durable queue named `tasks` and persistent messages.
- Manual acknowledgements after successful processing.
- Bounded worker prefetch, initially `1`.
- A KEDA RabbitMQ trigger using queue length.
- Kind as the first validated execution environment; Minikube support is planned.
- A manual, repeatable load scenario with screenshots and measured results.

A single broker is a deliberate development simplification. Production availability, broker clustering, automatic retries with backoff, and a dead-letter queue are future improvements.

## Planned repository structure

The application files and Kubernetes manifests below exist. Scripts, results documentation, the architecture image, and CI are still planned.

```text
.
|-- apps/
|   |-- producer/
|   |   |-- producer.py
|   |   |-- requirements.txt
|   |   `-- Dockerfile
|   `-- worker/
|       |-- worker.py
|       |-- requirements.txt
|       `-- Dockerfile
|-- k8s/
|   |-- namespace.yaml
|   |-- rabbitmq.yaml
|   |-- worker-deployment.yaml
|   |-- producer-job.yaml
|   |-- trigger-authentication.yaml
|   `-- scaled-object.yaml
|-- scripts/
|   |-- setup.sh
|   |-- generate-load.sh
|   `-- cleanup.sh
|-- docs/
|   |-- architecture.png
|   `-- results.md
|-- .github/workflows/build.yml
|-- .gitignore
`-- README.md
```

Keep the generated credential manifest out of Git. Application dependencies are pinned in each application's `requirements.txt`. Record and pin the KEDA chart version for the reproducible setup.

## Prerequisites

- Docker for building application images and running the local cluster.
- Python for local application development outside containers.
- Kind, kubectl, and Helm for the validated Kubernetes and KEDA setup.
- Enough local resources for RabbitMQ, KEDA, and up to five workers.

Record tool versions and cluster resources alongside each experiment. The validated context is `kind-freekubelab`; a Minikube profile is not the cluster used in this run. No AWS account or Terraform is required for the initial version.

## Application configuration contract

The applications use the following environment variables. The Kubernetes manifests supply the RabbitMQ Service name and reference credentials from a Secret:

| Variable | Component | Default / purpose |
| --- | --- | --- |
| `RABBITMQ_HOST` | Both | `localhost`; use a reachable broker address in Docker or a Service name in Kubernetes |
| `RABBITMQ_PORT` | Both | `5672` |
| `RABBITMQ_USERNAME` | Both | Required; RabbitMQ user |
| `RABBITMQ_PASSWORD` | Both | Required; supply at runtime, injected from a Kubernetes Secret in Kubernetes |
| `RABBITMQ_QUEUE` | Both | `tasks` |
| `MESSAGE_COUNT` | Producer | `1000` |
| `PROCESSING_TIME_SECONDS` | Worker | `2` |
| `PREFETCH_COUNT` | Worker | `1` |

Use synthetic payloads with a message ID and publication timestamp. Never log credentials or connection URLs containing passwords.

The worker acknowledges only after successful processing, handles shutdown gracefully, and closes its connection. Interrupted processing can cause redelivery; the example does not guarantee exactly-once delivery. A real consumer should make repeated processing safe through idempotency.

## Local validation

On 2026-10-04, the project owner manually validated the message flow with RabbitMQ, the producer, and the worker running in Docker. The producer published messages and the worker consumed them successfully before introducing autoscaling.

Runtime variables can be supplied with `docker run --env-file`. The applications read environment variables; they do not load `.env` files themselves. For the Linux setup discussed here, `--network host` allows an application container to reach a broker exposed on the host's `127.0.0.1`; `RABBITMQ_PORT` must match the published or forwarded host port. With Docker's default networking, `localhost` refers to the application container itself.

This validation covers successful publication and consumption. Broker restart persistence, interrupted-worker redelivery, and failure scenarios still need explicit integration validation. Message counts, timings, and the exact tool versions used in this run have not been recorded.

## Validated scaling configuration

| Setting | Configured value | Purpose |
| --- | --- | --- |
| `minReplicaCount` | `0` | Allow idle workers to scale to zero |
| `maxReplicaCount` | `5` | Bound resource consumption |
| `pollingInterval` | `5` seconds | KEDA trigger polling interval |
| `cooldownPeriod` | `60` seconds | Wait before returning to zero after inactivity |
| RabbitMQ mode | `QueueLength` | Scale from queue demand |
| RabbitMQ protocol | `amqp` | Query the broker over AMQP |
| Target value | `100` | Queue-length target per replica |

These are experiment settings, not production recommendations. Cooldown applies to returning to zero; scaling among active replicas follows HPA behavior. Do not expect instant or strictly proportional scaling: polling, HPA reconciliation, stabilization, broker metrics, and pod startup all affect the result.

The current scaler uses AMQP. AMQP queue length measures ready messages, so observe unacknowledged messages separately when verifying processing completion. Returning to zero alone does not prove that every message was acknowledged.

On 2026-10-08, the project owner manually validated this configuration on Kind:

- `rabbitmq-scaledobject` reported `Ready=True` and created `keda-hpa-rabbitmq-scaledobject` for `worker-deployment`.
- With the trigger inactive, KEDA reduced the initial worker replica count from one to zero.
- After publication, the observed ready/desired replica progression was `0/0 → 1/1 → 4/4 → 5/5`.
- After consumption, the worker pods returned to zero.

This validates activation, scale-out, and return to zero for the initial scenario. It does not yet provide measured activation or drain times, a fixed-worker comparison, or evidence for the failure scenarios.

## Implementation roadmap

### 1. Build a working message flow

- [x] Implement a producer that declares the queue and publishes synthetic messages.
- [x] Implement a worker with manual acknowledgements and configurable processing time.
- [x] Use publisher confirms and detect publication failures.
- [x] Validate producer and one worker against RabbitMQ before adding autoscaling.

### 2. Package and deploy

- [x] Create Dockerfiles and pin application dependencies.
- [x] Create namespace `keda-rabbitmq-autoscaling`.
- [x] Deploy RabbitMQ with persistent storage.
- [ ] Add RabbitMQ readiness checks.
- [x] Create dedicated credentials locally and inject them through a Secret.
- [x] Deploy one worker and validate Service connectivity.
- [ ] Define resource requests and limits for broker and applications.

### 3. Enable autoscaling

- [x] Install KEDA via Helm in a separate namespace.
- [ ] Record and pin the installed KEDA chart version for the reproducible setup.
- [x] Create TriggerAuthentication and ScaledObject in the application namespace.
- [x] Target the worker Deployment; do not create a second independent HPA for it.
- [x] Verify trigger authentication, ScaledObject readiness, and the generated HPA.
- [x] Verify that work activates workers from zero.
- [x] Verify scaling up to five workers and returning to zero after consumption.

### 4. Make the experiment reproducible

- [ ] Implement `setup.sh` with context validation and clear errors.
- [ ] Implement `generate-load.sh` to create a fresh producer Job for each run.
- [ ] Implement `cleanup.sh` scoped to this project's resources.
- [ ] Replace this roadmap-only setup section with tested execution commands.
- [ ] Record the exact software versions and experiment results.

### 5. Add CI and presentation

- [ ] Add CI for Python checks and Docker builds without requiring a live cluster.
- [ ] Optionally publish versioned images to GHCR.
- [ ] Add an architecture image and a short demonstration.
- [ ] Document limitations and publish an article explaining the observations.

## Planned execution workflow

Once implemented, setup should validate the selected cluster context, install KEDA, build/load application images, and deploy the project. Kind is the currently validated environment; Minikube support still needs testing. Load generation should submit a producer Job with a configurable message count. Cleanup should remove application resources without deleting an unrelated cluster or shared KEDA installation.

**These scripts do not exist yet.** Publish executable quick-start instructions only after testing them from a clean setup.

For the validated Kind cluster, application images must be loaded into `freekubelab` with `kind load docker-image IMAGE:TAG --name freekubelab`. The application manifests use `imagePullPolicy: IfNotPresent`. A locally built Docker image is not automatically available to Kubernetes. For a future Minikube run, load images into the selected Minikube profile instead.

## Observing the experiment

Use separate terminals to observe the deployed resources:

```bash
kubectl config current-context
kubectl get pods -n keda-rabbitmq-autoscaling -w
kubectl get deployment worker-deployment -n keda-rabbitmq-autoscaling -w
kubectl get hpa -n keda-rabbitmq-autoscaling -w
kubectl get scaledobject -n keda-rabbitmq-autoscaling
```

Watch RabbitMQ ready messages, unacknowledged messages, and consumer count alongside replica count. The HPA may show a minimum of one while KEDA manages the zero-replica state separately.

## Experiment scenarios

| Scenario | Configuration | What to measure |
| --- | --- | --- |
| Baseline | One fixed worker; autoscaling disabled | Processing time and queue backlog |
| Burst | Same workload with KEDA enabled | Activation delay, peak replicas, drain time |
| Slow consumer | Increase processing time | Backlog growth and scaling response |
| Replica limit | Load exceeds five workers' capacity | Remaining backlog at maximum replicas |
| Idle | Stop publishing and let processing finish | Scale-down behavior and return to zero |
| Interrupted worker | Terminate a worker during processing | Redelivery and acknowledgement behavior |

Keep the queue empty before each comparable run, use the same payload count and processing delay, and record ready/unacknowledged counts. Ensure the fixed-worker baseline is not still controlled by KEDA.

## Results

The local Docker flow and the initial Kind autoscaling cycle were manually validated. The observed KEDA peak was five ready replicas, followed by a return to zero after consumption. A fixed-worker baseline and quantitative timings have not been recorded.

| Metric | Fixed worker | KEDA enabled |
| --- | --- | --- |
| Messages published | TBD | TBD |
| Processing time per message | TBD | TBD |
| Peak replicas | TBD | 5 (observed) |
| Queue drain time | TBD | TBD |
| Scale-from-zero delay | N/A | TBD |
| Return-to-zero delay | N/A | TBD |
| Redeliveries / failures | TBD | TBD |

The current application defaults are 1000 messages and 2 seconds of processing per message. These are configuration defaults, not measured results or a verified message count for the recorded run.

Queue drain time should account for both ready and unacknowledged messages. Do not interpret an empty ready queue as proof that all processing has finished.

## Troubleshooting checklist

- **Workers do not start:** inspect ScaledObject conditions, KEDA operator logs, credentials, queue name, and broker connectivity.
- **Pods stay Pending:** check cluster capacity, requests, and scheduling events; KEDA does not provision nodes.
- **ImagePullBackOff:** check image names, tags, pull policy, and local image loading.
- **Workers stay active:** inspect queue metrics, unacknowledged work, cooldown, and HPA stabilization.
- **Messages disappear after restart:** check broker persistence, queue durability, and persistent publication.
- **Messages are processed twice:** inspect redelivery and acknowledgements; design consumers for at-least-once processing.

## Git rules

Commit application code, manifests without real credentials, dependency files, Dockerfiles, scripts, documentation, and workflows.

Do not commit `.env` files, generated Secret manifests, passwords, kubeconfig files, tokens, virtual environments, or local runtime data. Base64-encoded Kubernetes Secret values are not encrypted.

## Future improvements

- Prometheus and Grafana dashboards.
- Retry policy and dead-letter queue.
- Idempotent processing with a persistent result store.
- Sustained load generation with a configurable publication rate.
- Comparison of queue-based and CPU-based autoscaling.
- RabbitMQ high availability and recovery experiments.

## References

- [KEDA documentation](https://keda.sh/docs/)
- [RabbitMQ queue scaler](https://keda.sh/docs/latest/scalers/rabbitmq-queue/)
- [Kubernetes Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [RabbitMQ work queues tutorial](https://www.rabbitmq.com/tutorials/tutorial-two-python)
- [Minikube documentation](https://minikube.sigs.k8s.io/docs/)
- [Kind documentation](https://kind.sigs.k8s.io/docs/user/quick-start/)
