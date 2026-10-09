# Operations guide

[Back to README](../README.md) · [Architecture](architecture.md) · [Experiment results](results.md)

Commands below target the local Kind lab. Setup and cleanup explicitly select a Kind context; load generation uses the current kubectl context. The scripts were reported as validated on the existing cluster. A fresh-cluster installation remains unverified.

## Prerequisites

- Docker for building application images and running the local cluster.
- Python for local application development outside containers.
- Kind, kubectl, and Helm for the validated Kubernetes and KEDA setup.
- Enough local resources for RabbitMQ, KEDA, and up to five workers.

Record tool versions and cluster resources alongside each experiment. The validated context is `kind-freekubelab`; a Minikube profile is not the cluster used in this run. No AWS account or Terraform is required for the initial version.

## Storage prerequisite

The RabbitMQ StatefulSet requests a 1 Gi PVC without specifying a StorageClass. The cluster must provide a working default StorageClass and provisioner. Check before setup:

```bash
kubectl --context kind-freekubelab get storageclass
```

If no default class exists, configure local storage first. Setup does not install a storage provisioner. A Pending PVC prevents the broker rollout from completing.

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
kubectl config use-context kind-freekubelab
kubectl config current-context
./scripts/generate-load.sh 1000 --dry-run
./scripts/generate-load.sh 1000
```

The script requires Bash, Python 3, and kubectl. It uses `k8s/producer-job.yaml` as its template, preserving the image, command, resources, and Secret references. Each invocation creates a new Job named `producer-load-` followed by a Kubernetes-generated suffix, leaving existing Jobs intact. `MESSAGE_COUNT` is overridden for that Job; the source manifest is not changed.

The optional count defaults to the shell's `MESSAGE_COUNT`, or `1000` when unset, and must be a positive integer. The script prints the selected context, namespace, and message count. `--dry-run` prints the generated JSON without creating a Job, though kubectl may still contact the API server for discovery. Both preview and submission use the context selected at script startup.

After creation, the script prints commands to follow logs and inspect completion. Job creation alone does not mean publication succeeded; check the logs and Job status. Automatic retries are disabled with `backoffLimit: 0` and `restartPolicy: Never` to avoid repeating a partially published workload. Completed Jobs are retained for inspection.

Local checks covered manifest generation and simulated kubectl submission. The project owner also validated the script against the running Kind cluster; `producer-load-bqxgd` confirmed publication of 500 messages. See the [experiment record](results.md) for timing evidence and remaining checks.

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

## Observe queue and replicas

```bash
kubectl --context kind-freekubelab get deployment worker-deployment -n keda-rabbitmq-autoscaling -w
kubectl --context kind-freekubelab get scaledobject,hpa -n keda-rabbitmq-autoscaling
kubectl --context kind-freekubelab exec -n keda-rabbitmq-autoscaling rabbitmq-0 -- rabbitmqctl list_queues name messages_ready messages_unacknowledged consumers
```

A successful producer Job confirms publication, not completed processing. Verify both ready and unacknowledged messages are zero before treating the workload as drained.

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

