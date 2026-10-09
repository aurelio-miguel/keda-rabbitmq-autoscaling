#!/usr/bin/env bash
set -euo pipefail
set +x

usage() {
  cat <<'EOF'
Usage: setup.sh [--cluster NAME] [--keda-version VERSION]

Prepare an existing Kind cluster. Defaults: freekubelab, KEDA chart 2.21.0.
The script does not create a cluster or start a producer Job.

If rabbitmq-credentials does not exist, export RABBITMQ_USERNAME and
RABBITMQ_PASSWORD before running. Existing credentials are preserved.
EOF
}

cluster_name=freekubelab
keda_version=2.21.0
while (( $# )); do
  case "$1" in
    --cluster|--keda-version)
      if (( $# < 2 )) || [[ "$2" == --* || -z "$2" ]]; then
        printf 'Error: %s requires a value.\n' "$1" >&2
        exit 1
      fi
      if [[ "$1" == --cluster ]]; then cluster_name="$2"; else keda_version="$2"; fi
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ ! "$cluster_name" =~ ^[a-z0-9][a-z0-9-]*$ || ! "$keda_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Error: provide a valid Kind cluster name and a chart version such as 2.21.0.\n' >&2
  exit 1
fi
for dependency in kubectl kind docker helm python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Error: %s is required.\n' "$dependency" >&2
    exit 1
  fi
done

repository_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
context="kind-$cluster_name"
namespace=keda-rabbitmq-autoscaling
kube=(kubectl --context "$context")
stage='checking cluster prerequisites'
trap 'printf "Error during %s. Review the preceding command output.\n" "$stage" >&2' ERR

cluster_list="$(kind get clusters)"
found=false
while IFS= read -r existing_cluster; do
  if [[ "$existing_cluster" == "$cluster_name" ]]; then found=true; fi
done <<< "$cluster_list"
if [[ "$found" != true ]]; then
  printf 'Error: Kind cluster %s does not exist. Create it before running setup.\n' "$cluster_name" >&2
  exit 1
fi
docker info >/dev/null
"${kube[@]}" cluster-info >/dev/null
for manifest in namespace rabbitmq worker-deployment trigger-authentication scaled-object; do
  if [[ ! -f "$repository_root/k8s/$manifest.yaml" ]]; then
    printf 'Error: missing manifest: k8s/%s.yaml\n' "$manifest" >&2
    exit 1
  fi
done
for application in producer worker; do
  for file in Dockerfile .dockerignore requirements.txt "$application.py"; do
    if [[ ! -f "$repository_root/apps/$application/$file" ]]; then
      printf 'Error: missing file: apps/%s/%s\n' "$application" "$file" >&2
      exit 1
    fi
  done
done
printf 'Preparing context %s, namespace %s, KEDA chart %s\n' "$context" "$namespace" "$keda_version"

stage='checking the KEDA release'
release_state="$(helm list --kube-context "$context" --namespace keda --all -o json |
  python3 -c '
import json, sys
version = sys.argv[1]
matches = [release for release in json.load(sys.stdin) if release["name"] == "keda"]
if not matches:
    print("absent")
else:
    release = matches[0]
    if release["chart"] != "keda-" + version or release["status"] != "deployed":
        raise SystemExit("Error: existing KEDA release differs from the requested version or is not deployed. Inspect helm list -n keda; setup will not upgrade it automatically.")
    print("present")
' "$keda_version")"

stage='preparing the namespace and credentials'
"${kube[@]}" apply -f "$repository_root/k8s/namespace.yaml"
secret_json="$("${kube[@]}" get secret rabbitmq-credentials -n "$namespace" --ignore-not-found -o json)"
if [[ -z "$secret_json" ]]; then
  if [[ -z "${RABBITMQ_USERNAME:-}" || -z "${RABBITMQ_PASSWORD:-}" ]]; then
    printf 'Error: export RABBITMQ_USERNAME and RABBITMQ_PASSWORD, or create rabbitmq-credentials in %s first.\n' "$namespace" >&2
    exit 1
  fi
  python3 -c '
import json, os
credentials = {name: os.environ["RABBITMQ_" + name.upper()] for name in ("username", "password")}
if any(not value.strip() for value in credentials.values()):
    raise SystemExit("Error: RabbitMQ credentials must not be blank")
credentials["rabbitmq"] = "amqp://rabbitmq.keda-rabbitmq-autoscaling.svc.cluster.local:5672/"
print(json.dumps({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": "rabbitmq-credentials", "namespace": "keda-rabbitmq-autoscaling"}, "type": "Opaque", "stringData": credentials}))
' | "${kube[@]}" create -f -
else
  host_state="$(printf '%s\n' "$secret_json" | python3 -c '
import base64, json, sys
data = json.load(sys.stdin).get("data", {})
for key in ("username", "password"):
    if not data.get(key) or not base64.b64decode(data[key]).strip():
        raise SystemExit("Error: existing rabbitmq-credentials requires nonempty username and password keys")
print("present" if data.get("rabbitmq") else "absent")
')"
  if [[ "$host_state" == absent ]]; then
    "${kube[@]}" patch secret rabbitmq-credentials -n "$namespace" --type merge \
      -p '{"stringData":{"rabbitmq":"amqp://rabbitmq.keda-rabbitmq-autoscaling.svc.cluster.local:5672/"}}'
  fi
  printf 'Using existing RabbitMQ credentials.\n'
fi
unset secret_json

stage='preparing KEDA'
if [[ "$release_state" == absent ]]; then
  helm repo add kedacore https://kedacore.github.io/charts
  helm repo update kedacore
  helm install keda kedacore/keda --kube-context "$context" \
    --namespace keda --create-namespace --version "$keda_version" --wait --timeout 5m
fi
"${kube[@]}" wait --for=condition=Established --timeout=120s \
  crd/triggerauthentications.keda.sh crd/scaledobjects.keda.sh
for deployment in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
  "${kube[@]}" rollout status "deployment/$deployment" -n keda --timeout=300s
done

stage='building and loading application images'
for application in producer worker; do
  docker build -t "rabbitmq-$application:local" "$repository_root/apps/$application"
  kind load docker-image "rabbitmq-$application:local" --name "$cluster_name"
done

stage='deploying RabbitMQ'
"${kube[@]}" apply -f "$repository_root/k8s/rabbitmq.yaml"
"${kube[@]}" rollout status statefulset/rabbitmq -n "$namespace" --timeout=300s

stage='deploying the worker'
"${kube[@]}" apply -f "$repository_root/k8s/worker-deployment.yaml"

"${kube[@]}" rollout restart deployment/worker-deployment -n "$namespace"
existing_scaler="$("${kube[@]}" get scaledobject rabbitmq-scaledobject -n "$namespace" --ignore-not-found -o name)"
if [[ -z "$existing_scaler" ]]; then
  "${kube[@]}" rollout status deployment/worker-deployment -n "$namespace" --timeout=180s
fi

stage='configuring autoscaling'
"${kube[@]}" apply -f "$repository_root/k8s/trigger-authentication.yaml"
"${kube[@]}" apply -f "$repository_root/k8s/scaled-object.yaml"
"${kube[@]}" wait --for=condition=Ready scaledobject/rabbitmq-scaledobject -n "$namespace" --timeout=120s
printf 'Setup complete. No load was published.\n'
printf 'Inspect scaling: kubectl --context %q get scaledobject,hpa -n %q\n' "$context" "$namespace"
printf 'To generate load, select context %s and run ./scripts/generate-load.sh 500\n' "$context"
