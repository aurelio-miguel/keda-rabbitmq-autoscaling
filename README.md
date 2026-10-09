# keda-rabbitmq-autoscaling

Event-driven autoscaling of Python workers on Kubernetes using RabbitMQ and KEDA.

> **Status: end-to-end autoscaling manually validated on Kind.** RabbitMQ, the producer Job, and the worker Deployment are deployed. KEDA activated workers from zero, scaled up to five replicas, and returned to zero after consumption. Setup, load generation, and cleanup have been validated on the running cluster. CI is implemented; its first GitHub Actions run, clean-setup validation, and repeated measurements remain pending.

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

The application files, Kubernetes manifests, all three scripts, `docs/results.md`, application unit tests, and the CI workflow below exist. The architecture image is still planned.

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
|-- tests/
|   `-- test_applications.py
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
- [x] Add RabbitMQ readiness checks.
- [x] Create dedicated credentials locally and inject them through a Secret.
- [x] Deploy one worker and validate Service connectivity.
- [x] Define resource requests and limits for broker and applications.

### 3. Enable autoscaling

- [x] Install KEDA via Helm in a separate namespace.
- [ ] Record and pin the installed KEDA chart version for the reproducible setup.
- [x] Create TriggerAuthentication and ScaledObject in the application namespace.
- [x] Target the worker Deployment; do not create a second independent HPA for it.
- [x] Verify trigger authentication, ScaledObject readiness, and the generated HPA.
- [x] Verify that work activates workers from zero.
- [x] Verify scaling up to five workers and returning to zero after consumption.

### 4. Make the experiment reproducible

- [x] Implement `setup.sh` with context validation and clear errors.
- [x] Validate `setup.sh` against the running cluster.
- [ ] Validate `setup.sh` from a clean setup.
- [x] Implement `generate-load.sh` to create a fresh producer Job for each run.
- [x] Validate the load-generation script against the running cluster.
- [x] Implement `cleanup.sh` scoped to this project's resources.
- [x] Validate `cleanup.sh` against the running cluster.
- [ ] Replace this roadmap-only setup section with tested execution commands.
- [ ] Record the exact software versions and experiment results.

### 5. Add CI and presentation

- [x] Add CI for Python checks and Docker builds without requiring a live cluster.
- [ ] Verify the first GitHub Actions run.
- [ ] Optionally publish versioned images to GHCR.
- [ ] Add an architecture image and a short demonstration.
- [ ] Document limitations and publish an article explaining the observations.

## Planned execution workflow

Once implemented, setup should validate the selected cluster context, install KEDA, build/load application images, and deploy the project. Kind is the currently validated environment; Minikube support still needs testing. Load generation should submit a producer Job with a configurable message count. Cleanup should remove application resources without deleting an unrelated cluster or shared KEDA installation.

**All three scripts are implemented and validated on the running cluster.** The project owner confirmed cleanup followed by setup and another test worked successfully. A complete quick-start still needs testing from an empty cluster with fresh storage.

For the validated Kind cluster, application images must be loaded into `freekubelab` with `kind load docker-image IMAGE:TAG --name freekubelab`. The application manifests use `imagePullPolicy: IfNotPresent`. A locally built Docker image is not automatically available to Kubernetes. For a future Minikube run, load images into the selected Minikube profile instead.

## Prepare the Kind environment

`scripts/setup.sh` prepares an existing Kind cluster using Docker, Kind, kubectl, Helm, and Python 3. From the repository root:

```bash
./scripts/setup.sh --help
./scripts/setup.sh --cluster freekubelab --keda-version 2.21.0
```

It explicitly targets `kind-freekubelab` without changing the current kubectl context. It checks access, applies the namespace, preserves existing RabbitMQ credentials, installs KEDA if absent, builds and loads both application images, deploys RabbitMQ and the worker, and applies the KEDA resources. It waits for the broker rollout and ScaledObject readiness. It does not publish messages or create a cluster.

The chart version defaults to `2.21.0`. If an existing Helm release named `keda` uses another version, setup stops rather than upgrading it. Inspect the installed release with `helm --kube-context kind-freekubelab list -n keda` and pass that chart version explicitly to reuse it. Existing autoscaling pause annotations are preserved; inspect them before a load test.

If `rabbitmq-credentials` already exists, its username and password are reused. A missing `rabbitmq` connection key is added for the in-cluster AMQP Service. If the Secret does not exist, supply credentials through exported environment variables:

```bash
read -rp 'RabbitMQ username: ' RABBITMQ_USERNAME
read -rsp 'RabbitMQ password: ' RABBITMQ_PASSWORD
export RABBITMQ_USERNAME RABBITMQ_PASSWORD
./scripts/setup.sh --cluster freekubelab --keda-version 2.21.0
unset RABBITMQ_PASSWORD
```

The script does not load `.env` files. If reusing broker storage, use the credentials already configured in that broker; creating a Secret is not a password-rotation operation. Application build contexts exclude local `.env` files through `.dockerignore`. Repeated setup rebuilds images and requests a worker rollout to use the rebuilt local tag, so run it between experiments after the queue has drained.

The setup script has been checked locally with simulated commands covering new and existing Secrets, missing connection keys, KEDA version checks, image loading, and failure paths. The project owner also confirmed successful execution against the running cluster. Execution from a clean setup remains to be validated.

## Generate a new load

With the application deployed and its image available to cluster nodes, run from the repository root:

```bash
kubectl config current-context
./scripts/generate-load.sh 1000 --dry-run
./scripts/generate-load.sh 1000
```

The script requires Bash, Python 3, and kubectl. It uses `k8s/producer-job.yaml` as its template, preserving the image, command, resources, and Secret references. Each invocation creates a new Job named `producer-load-` followed by a Kubernetes-generated suffix, leaving existing Jobs intact. `MESSAGE_COUNT` is overridden for that Job; the source manifest is not changed.

The optional count defaults to the shell's `MESSAGE_COUNT`, or `1000` when unset, and must be a positive integer. The script prints the selected context, namespace, and message count. `--dry-run` prints the generated JSON without creating a Job, though kubectl may still contact the API server for discovery. Both preview and submission use the context selected at script startup.

After creation, the script prints commands to follow logs and inspect completion. Job creation alone does not mean publication succeeded; check the logs and Job status. Automatic retries are disabled with `backoffLimit: 0` and `restartPolicy: Never` to avoid repeating a partially published workload. Completed Jobs are retained for inspection.

Local checks covered manifest generation and simulated kubectl submission. The project owner also validated the script against the running Kind cluster; `producer-load-bqxgd` confirmed publication of 500 messages. See the [experiment record](docs/results.md) for timing evidence and remaining checks.

## Clean up application resources

Run from the repository root. Preview the plan first:

```bash
./scripts/cleanup.sh --cluster freekubelab --dry-run
./scripts/cleanup.sh --cluster freekubelab
```

The script explicitly targets `kind-freekubelab` and namespace `keda-rabbitmq-autoscaling`. It removes the fixed producer Job and generated Jobs matching both the `producer-load-` prefix and the load-generator label, then removes the ScaledObject, TriggerAuthentication, worker Deployment, RabbitMQ StatefulSet, and RabbitMQ Service. The HPA owned by the ScaledObject is removed through Kubernetes garbage collection. Jobs without the script's matching name and label are retained.

The cluster, KEDA installation, namespace, PVC `data-rabbitmq-0`, and Secret `rabbitmq-credentials` remain. A later setup can reuse the broker data and credentials. Cleanup stops running workloads; collect results and logs before running it.

To also delete the broker PVC and credentials, explicitly opt in:

```bash
./scripts/cleanup.sh --cluster freekubelab --delete-data --dry-run
./scripts/cleanup.sh --cluster freekubelab --delete-data
```

Deleting the PVC can permanently remove persisted messages and broker configuration, depending on the volume reclaim policy. With a `Retain` policy, the underlying volume is retained and requires separate administration. The script does not delete PersistentVolumes directly or delete the namespace.

Cleanup requires Bash, kubectl, and Python 3 and works from any directory. Missing named resources are ignored; an absent application namespace is a successful no-op. It stops on other API errors. Local checks covered scope, deletion order, previews, retained data, absent resources, and failure handling using simulated kubectl commands. The project owner also validated cleanup and successful recreation with setup on the running cluster.

## Continuous integration

`.github/workflows/build.yml` runs on pushes, pull requests, and manual dispatch. It checks Python syntax, runs eight broker-free unit tests on Python 3.9 (matching the current Docker base) and 3.12, and checks Bash syntax for all scripts. After these checks pass, separate jobs build the producer and worker images and check Python syntax inside each image. Images are built for validation without being published or deployed.

The unit tests cover persistent confirmed publication, unroutable and rejected messages, invalid configuration, credential-safe error logging, acknowledgement after processing, heartbeat servicing, SIGTERM interruption, and malformed payload rejection. Broker connections are simulated. Actual broker persistence, redelivery, and Kubernetes autoscaling still require integration experiments.

Run the same application tests locally with an activated Python environment:

```bash
python -m pip install -r apps/producer/requirements.txt -r apps/worker/requirements.txt
python -m unittest discover -s tests -v
bash -n scripts/setup.sh scripts/generate-load.sh scripts/cleanup.sh
```

The first GitHub Actions execution remains to be verified after these files are committed and pushed. No cluster credentials or RabbitMQ secrets are needed by this workflow.

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

Two timed runs each confirmed 500 publications on Kind. The single-worker baseline finished approximately 16 min 48 s after script invocation; the KEDA run finished in approximately 4 min 2 s, reached five ready workers, and returned to zero. The observed elapsed-time ratio was approximately 4.17, with a 76.0% reduction in elapsed time. These are first-round manual observations; runtime configuration equality and repeated measurements are still needed. See [docs/results.md](docs/results.md) for timestamps, evidence, and measurement limits.

| Metric | Fixed worker | KEDA enabled |
| --- | --- | --- |
| Messages published | 500 confirmed | 500 confirmed |
| Processing time per message | Default 2 s; runtime value unconfirmed | Default 2 s; runtime value unconfirmed |
| Peak replicas | 1, confirmed by project owner | 5, recorded in deployment watch |
| Start to reported queue completion | Approx. 16 min 48 s | Approx. 4 min 2 s |
| Start to first ready worker | Already ready | Approx. 2 s |
| Reported completion to zero workers | N/A | Approx. 24 s |
| Errors / restarts | None observed, reported by project owner | TBD |
| Redeliveries | Not measured | TBD |

The script defaults to 1000 messages when no count is supplied; both timed runs explicitly requested 500. The application default processing delay is 2 seconds per message, rather than a measured processing duration. The interval from reported completion to zero is an observation, not a measurement of the configured 60-second cooldown: AMQP ready-message activity can stop before unacknowledged processing finishes.

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
