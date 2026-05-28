#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/compare-workflow-performance.sh --repo OWNER/REPO --runs OLD_RUN_ID,NEW_RUN_ID

Example:
  scripts/compare-workflow-performance.sh \
    --repo shivemind/jadeGlobal \
    --runs 26494706385,NEW_RUN_ID

Requires:
  gh auth login
  jq
USAGE
}

REPO=""
RUNS=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --runs)
      RUNS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO" ] || [ -z "$RUNS" ]; then
  usage >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

duration_seconds() {
  local start="$1"
  local end="$2"
  if [ -z "$start" ] || [ "$start" = "null" ] || [ -z "$end" ] || [ "$end" = "null" ]; then
    printf '0'
    return
  fi
  local start_epoch end_epoch
  start_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$start" "+%s" 2>/dev/null || date -u -d "$start" "+%s")"
  end_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$end" "+%s" 2>/dev/null || date -u -d "$end" "+%s")"
  printf '%s' "$((end_epoch - start_epoch))"
}

IFS=',' read -r -a RUN_IDS <<< "$RUNS"

printf '| Run | Job | Step | Seconds | Conclusion |\n'
printf '| --- | --- | --- | ---: | --- |\n'

for run_id in "${RUN_IDS[@]}"; do
  tmp_file="$(mktemp)"
  gh run view "$run_id" --repo "$REPO" --json jobs > "$tmp_file"

  while IFS=$'\t' read -r job_name job_start job_end job_conclusion; do
    seconds="$(duration_seconds "$job_start" "$job_end")"
    printf '| `%s` | `%s` | `_job total_` | %s | `%s` |\n' \
      "$run_id" "$job_name" "$seconds" "$job_conclusion"
  done < <(jq -r '.jobs[] | [.name, .startedAt, .completedAt, .conclusion] | @tsv' "$tmp_file")

  while IFS=$'\t' read -r job_name step_name step_start step_end step_conclusion; do
    seconds="$(duration_seconds "$step_start" "$step_end")"
    printf '| `%s` | `%s` | `%s` | %s | `%s` |\n' \
      "$run_id" "$job_name" "$step_name" "$seconds" "$step_conclusion"
  done < <(jq -r '.jobs[] as $job | $job.steps[] | [$job.name, .name, .startedAt, .completedAt, .conclusion] | @tsv' "$tmp_file")

  rm -f "$tmp_file"
done
