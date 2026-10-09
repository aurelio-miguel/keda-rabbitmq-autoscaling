#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate-load.sh [MESSAGE_COUNT] [--dry-run]

Create a fresh producer Job in the current kubectl context.
Message count defaults to MESSAGE_COUNT from the environment, or 1000.
--dry-run prints the generated JSON manifest without creating a Job.
EOF
}

message_count="${MESSAGE_COUNT:-1000}"
dry_run=false
count_provided=false
for argument in "$@"; do
  case "$argument" in
    --help|-h) usage; exit 0 ;;
    --dry-run) dry_run=true ;;
    *)
      if [[ "$count_provided" == true ]]; then
        printf 'Error: unexpected argument: %s\n' "$argument" >&2
        usage >&2
        exit 1
      fi
      message_count="$argument"
      count_provided=true
      ;;
  esac
done

if [[ ! "$message_count" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Error: MESSAGE_COUNT must be a positive integer.\n' >&2
  exit 1
fi

for dependency in kubectl python3; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'Error: %s is required.\n' "$dependency" >&2
    exit 1
  fi
done

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_manifest="$script_directory/../k8s/producer-job.yaml"
if [[ ! -f "$source_manifest" ]]; then
  printf 'Error: producer manifest not found: %s\n' "$source_manifest" >&2
  exit 1
fi

context="$(kubectl config current-context)"
if [[ -z "$context" ]]; then
  printf 'Error: select a kubectl context before generating load.\n' >&2
  exit 1
fi

job_manifest="$(
  kubectl --context "$context" create --dry-run=client --validate=false -f "$source_manifest" -o json |
    python3 -c '
import json
import sys

job = json.load(sys.stdin)
if job.get("kind") != "Job":
    raise SystemExit("Error: producer manifest must contain one Job")
metadata = job["metadata"]
namespace = metadata.get("namespace")
if not namespace:
    raise SystemExit("Error: producer Job must specify a namespace")
metadata.pop("name", None)
metadata["generateName"] = "producer-load-"
metadata.setdefault("labels", {})["app.kubernetes.io/component"] = "load-generator"
spec = job["spec"]
spec["backoffLimit"] = 0
spec["template"]["spec"]["restartPolicy"] = "Never"
containers = spec["template"]["spec"]["containers"]
if len(containers) != 1:
    raise SystemExit("Error: producer Job must contain exactly one container")
container = containers[0]
environment = [item for item in container.get("env", []) if item["name"] != "MESSAGE_COUNT"]
environment.append({"name": "MESSAGE_COUNT", "value": sys.argv[1]})
container["env"] = environment
print(json.dumps(job, indent=2))
' "$message_count"
)"

namespace="$(printf '%s\n' "$job_manifest" | python3 -c 'import json, sys; print(json.load(sys.stdin)["metadata"]["namespace"])')"
printf 'Context: %s | Namespace: %s | Messages: %s\n' "$context" "$namespace" "$message_count" >&2

if [[ "$dry_run" == true ]]; then
  printf '%s\n' "$job_manifest"
  exit 0
fi

job_name="$(printf '%s\n' "$job_manifest" | kubectl --context "$context" create -f - -o jsonpath='{.metadata.name}')"
printf 'Created Job: %s\n' "$job_name"
printf 'Follow logs: kubectl --context %q logs -f job/%q -n %q\n' "$context" "$job_name" "$namespace"
printf 'Check completion: kubectl --context %q get job %q -n %q\n' "$context" "$job_name" "$namespace"
