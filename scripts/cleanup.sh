#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cleanup.sh [--cluster NAME] [--dry-run] [--delete-data]

Remove this project's workloads from an existing Kind cluster.
Default cluster: freekubelab. Namespace: keda-rabbitmq-autoscaling.

--dry-run       Show the removal plan without deleting anything.
--delete-data   Also delete PVC data-rabbitmq-0 and Secret rabbitmq-credentials.
                This discards the broker's persisted data with typical dynamic
                storage using the Delete reclaim policy.

The namespace, cluster, KEDA installation, and unrelated resources are retained.
By default, broker storage and credentials are also retained for future setup.
EOF
}

cluster_name=freekubelab
dry_run=false
delete_data=false
while (( $# )); do
  case "$1" in
    --cluster)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
        printf 'Error: --cluster requires a name.\n' >&2
        exit 1
      fi
      cluster_name="$2"
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    --delete-data) delete_data=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 1 ;;
  esac
done
if [[ ! "$cluster_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  printf 'Error: invalid Kind cluster name.\n' >&2
  exit 1
fi
for dependency in kubectl python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Error: %s is required.\n' "$dependency" >&2
    exit 1
  fi
done

context="kind-$cluster_name"
namespace=keda-rabbitmq-autoscaling
kube=(kubectl --context "$context")
stage='checking cluster access'
trap 'printf "Error during %s. Review the preceding command output.\n" "$stage" >&2' ERR
"${kube[@]}" cluster-info >/dev/null
namespace_resource="$("${kube[@]}" get namespace "$namespace" --ignore-not-found -o name)"
if [[ -z "$namespace_resource" ]]; then
  printf 'Namespace %s is absent in %s; nothing to remove.\n' "$namespace" "$context"
  exit 0
fi
printf 'Context: %s | Namespace: %s | Preview: %s | Delete data: %s\n' \
  "$context" "$namespace" "$dry_run" "$delete_data"

stage='listing generated load Jobs'
# Require both the script label and its name prefix; never delete all Jobs.
load_jobs="$("${kube[@]}" get jobs -n "$namespace" \
  -l app.kubernetes.io/component=load-generator -o json | python3 -c '
import json, re, sys
for job in json.load(sys.stdin).get("items", []):
    metadata = job["metadata"]
    name = metadata["name"]
    labels = metadata.get("labels", {})
    if re.fullmatch(r"producer-load-[a-z0-9-]+", name) and labels.get("app.kubernetes.io/component") == "load-generator":
        print(name)
')"
stage='checking KEDA resource types'
keda_resources="$("${kube[@]}" api-resources --api-group=keda.sh -o name)"

has_resource() {
  local resource
  while IFS= read -r resource; do
    if [[ "$resource" == "$1" ]]; then return 0; fi
  done <<< "$keda_resources"
  return 1
}

remove_resource() {
  local kind="$1" name="$2"
  if [[ "$dry_run" == true ]]; then
    printf 'Would remove: %s/%s\n' "$kind" "$name"
  else
    stage="removing $kind/$name"
    "${kube[@]}" delete "$kind" "$name" -n "$namespace" \
      --ignore-not-found --wait=true --timeout=180s
  fi
}

# Stop publication, then remove autoscaling before removing its target.
remove_resource job producer-job
while IFS= read -r job_name; do
  if [[ -n "$job_name" ]]; then remove_resource job "$job_name"; fi
done <<< "$load_jobs"
if has_resource scaledobjects.keda.sh; then
  # Kubernetes garbage collection removes the HPA owned by this ScaledObject.
  remove_resource scaledobjects.keda.sh rabbitmq-scaledobject
fi
if has_resource triggerauthentications.keda.sh; then
  remove_resource triggerauthentications.keda.sh keda-trigger-auth-rabbitmq
fi
remove_resource deployment worker-deployment
remove_resource statefulset rabbitmq
remove_resource service rabbitmq

if [[ "$delete_data" == true ]]; then
  remove_resource pvc data-rabbitmq-0
  remove_resource secret rabbitmq-credentials
else
  printf 'Retaining PVC data-rabbitmq-0 and Secret rabbitmq-credentials.\n'
fi
if [[ "$dry_run" == true ]]; then
  printf 'Preview complete; no resources deleted.\n'
else
  printf 'Cleanup complete. Namespace, cluster, and KEDA installation retained.\n'
fi
