# keda-rabbitmq-autoscaling

Event-driven autoscaling of Python workers on Kubernetes using RabbitMQ and KEDA.

> **Status: planned / under development.** This README describes the intended architecture and implementation roadmap. Application code, manifests, scripts, and CI still need to be created and validated. The structure below is a target, not a list of existing files.

## Why this project?

Message queues absorb bursts of work, but a fixed number of consumers can leave a growing backlog or waste resources during idle periods. This project demonstrates how to scale consumers based on queue demand rather than CPU utilization alone.

The goal is to publish a controlled workload, observe workers scaling out, drain the queue, and observe scaling back down. The implementation should be reproducible on Minikube and documented with actual measurements.

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
- Minikube as the first supported execution environment.
- A manual, repeatable load scenario with screenshots and measured results.

A single broker is a deliberate development simplification. Production availability, broker clustering, automatic retries with backoff, and a dead-letter queue are future improvements.

## Planned repository structure

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

Keep the generated credential manifest out of Git. Pin application dependencies, container images, and the KEDA chart version when implementation begins.

## Prerequisites

- Docker, Minikube, kubectl, and Helm.
- Python for local application development.
- Enough local resources for RabbitMQ, KEDA, and the maximum number of workers.

Record the tool versions and Minikube resources used alongside each experiment. No AWS account or Terraform is required for the initial version.

## Application configuration contract

These are proposed environment variables to implement consistently in the code and manifests:

| Variable | Component | Proposed default / purpose |
| --- | --- | --- |
| `RABBITMQ_HOST` | Both | RabbitMQ Service name |
| `RABBITMQ_PORT` | Both | `5672` |
| `RABBITMQ_USERNAME` | Both | Dedicated project user |
| `RABBITMQ_PASSWORD` | Both | Inject from a Kubernetes Secret |
| `RABBITMQ_QUEUE` | Both | `tasks` |
| `MESSAGE_COUNT` | Producer | `1000` |
| `PROCESSING_TIME_SECONDS` | Worker | `2` |
| `PREFETCH_COUNT` | Worker | `1` |

Use synthetic payloads with a message ID and publication timestamp. Never log credentials or connection URLs containing passwords.

The worker should acknowledge only after successful processing, handle shutdown gracefully, and close its connection. Interrupted processing can cause redelivery; the example must not claim exactly-once delivery. A real consumer should make repeated processing safe through idempotency.

## Proposed scaling configuration

| Setting | Starting value | Purpose |
| --- | --- | --- |
| `minReplicaCount` | `0` | Allow idle workers to scale to zero |
| `maxReplicaCount` | `5` | Bound resource consumption |
| `pollingInterval` | `5` seconds | KEDA trigger polling interval |
| `cooldownPeriod` | `60` seconds | Wait before returning to zero after inactivity |
| RabbitMQ mode | `QueueLength` | Scale from queue demand |
| Target value | `50` | Starting queue-length target per replica |

These are experiment settings, not production recommendations. Cooldown applies to returning to zero; scaling among active replicas follows HPA behavior. Do not expect instant or strictly proportional scaling: polling, HPA reconciliation, stabilization, broker metrics, and pod startup all affect the result.

Choose the RabbitMQ scaler protocol explicitly and document it. AMQP and HTTP can expose different queue measurements, especially around unacknowledged messages. Confirm the semantics for the pinned KEDA version before interpreting results.

## Implementation roadmap

### 1. Build a working message flow

- [ ] Implement a producer that declares the queue and publishes synthetic messages.
- [ ] Implement a worker with manual acknowledgements and configurable processing time.
- [ ] Use publisher confirms and detect publication failures.
- [ ] Validate producer and one worker against RabbitMQ before adding autoscaling.

### 2. Package and deploy

- [ ] Create Dockerfiles and pin dependencies.
- [ ] Create namespace `keda-rabbitmq-autoscaling`.
- [ ] Deploy RabbitMQ with readiness checks and persistent storage.
- [ ] Create dedicated credentials locally and inject them through a Secret.
- [ ] Deploy one worker and validate Service connectivity.
- [ ] Define resource requests and limits for broker and applications.

### 3. Enable autoscaling

- [ ] Install a pinned KEDA Helm chart version in a separate namespace.
- [ ] Create TriggerAuthentication and ScaledObject in the application namespace.
- [ ] Target the worker Deployment; do not create a second independent HPA for it.
- [ ] Verify trigger authentication, ScaledObject readiness, and the generated HPA.
- [ ] Verify that work activates workers from zero.

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

Once implemented, setup should start or use the selected Minikube profile, install KEDA, build/load application images, and deploy the project. Load generation should submit a producer Job with a configurable message count. Cleanup should remove application resources without deleting an unrelated cluster or shared KEDA installation.

**These scripts do not exist yet.** Publish executable quick-start instructions only after testing them from a clean setup.

For local images, load them into the chosen Minikube profile and configure an appropriate image pull policy. A locally built Docker image is not automatically available to Kubernetes.

## Observing the experiment

After the corresponding resources exist, use separate terminals:

```bash
kubectl config current-context
kubectl get pods -n keda-rabbitmq-autoscaling -w
kubectl get deployment worker -n keda-rabbitmq-autoscaling -w
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

No results have been measured yet. Fill the table after running the scenarios:

| Metric | Fixed worker | KEDA enabled |
| --- | --- | --- |
| Messages published | TBD | TBD |
| Processing time per message | TBD | TBD |
| Peak replicas | TBD | TBD |
| Queue drain time | TBD | TBD |
| Scale-from-zero delay | N/A | TBD |
| Return-to-zero delay | N/A | TBD |
| Redeliveries / failures | TBD | TBD |

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
