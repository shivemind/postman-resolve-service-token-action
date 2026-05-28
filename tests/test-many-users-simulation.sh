#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SIM_USERS="${SIM_USERS:-100}"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "ok - $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "not ok - $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local file="$1"
  local expected="$2"
  if grep -Fq "$expected" "$file"; then
    return 0
  fi
  echo "Expected '$expected' in $file"
  sed -n '1,120p' "$file"
  return 1
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    echo "Did not expect '$unexpected' in $file"
    sed -n '1,120p' "$file"
    return 1
  fi
}

assert_secret_only_masked_in_log() {
  local file="$1"
  local secret="$2"
  local leaks
  leaks="$(grep -F "$secret" "$file" | grep -Fv "::add-mask::$secret" || true)"
  if [ -n "$leaks" ]; then
    echo "Secret appeared outside an add-mask workflow command"
    printf '%s\n' "$leaks"
    return 1
  fi
}

install_fake_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

out_file=""
url=""
headers=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      out_file="$2"
      shift 2
      ;;
    -w)
      shift 2
      ;;
    -X)
      shift 2
      ;;
    -H)
      headers+=("$2")
      shift 2
      ;;
    --data)
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

has_header_prefix() {
  local prefix="$1"
  local header
  for header in "${headers[@]}"; do
    case "$header" in
      "$prefix"*)
        return 0
        ;;
    esac
  done
  return 1
}

write_response() {
  local code="$1"
  local body="$2"
  printf '%s' "$body" > "$out_file"
  printf '%s' "$code"
}

user_id="${SIM_USER_ID:-0}"
sleep "0.0$((user_id % 5))"

case "$SIM_MODE:$url" in
  service_account:*service-account-tokens)
    write_response 200 "{\"access_token\":\"minted-token-${user_id}\",\"expires_in\":900,\"expires_at\":\"2026-05-29T00:00:00Z\"}"
    ;;
  service_account:*/me)
    if has_header_prefix "x-api-key:" && has_header_prefix "Authorization: Bearer minted-token-${user_id}"; then
      write_response 200 "{\"team\":{\"id\":\"team-${user_id}\"}}"
    else
      write_response 401 '{"error":{"message":"missing service-account auth headers"}}'
    fi
    ;;
  provided_token:*/me)
    if has_header_prefix "Authorization: Bearer provided-token-${user_id}"; then
      write_response 200 "{\"user\":{\"teamId\":\"team-provided-${user_id}\"}}"
    else
      write_response 401 '{"error":{"message":"missing bearer header"}}'
    fi
    ;;
  mixed:*service-account-tokens)
    if [ $((user_id % 10)) -eq 0 ]; then
      write_response 401 "{\"error\":{\"message\":\"inactive key PMAK-sim-user-${user_id} Bearer should-not-leak\",\"apiKey\":\"PMAK-sim-user-${user_id}\",\"token\":\"should-not-leak\"}}"
    else
      write_response 200 "{\"access_token\":\"mixed-token-${user_id}\",\"expires_in\":300}"
    fi
    ;;
  mixed:*/me)
    write_response 200 "{\"identity\":{\"teamId\":\"team-mixed-${user_id}\"}}"
    ;;
  legacy_pmak:*/me)
    if has_header_prefix "x-api-key: PMAK-sim-user-${user_id}"; then
      write_response 200 "{\"user\":{\"teamId\":\"legacy-team-${user_id}\"}}"
    else
      write_response 401 '{"error":{"message":"missing api key"}}'
    fi
    ;;
  *)
    echo "Unexpected mock curl call for ${SIM_MODE}: ${url}" >&2
    exit 99
    ;;
esac
CURL
  chmod +x "$bin_dir/curl"
}

run_resolver_case() {
  local phase="$1"
  local user_id="$2"
  local expected="$3"
  local api_key="${4:-}"
  local access_token="${5:-}"
  local case_dir="$TMP_DIR/$phase/$user_id"
  local bin_dir="$case_dir/bin"
  mkdir -p "$bin_dir"
  install_fake_curl "$bin_dir"
  : > "$case_dir/github_output"

  set +e
  PATH="$bin_dir:$PATH" \
  SIM_MODE="$phase" \
  SIM_USER_ID="$user_id" \
  POSTMAN_API_KEY="$api_key" \
  EXISTING_TOKEN="$access_token" \
  EXISTING_TEAM_ID="" \
  STACK="prod" \
  GITHUB_OUTPUT="$case_dir/github_output" \
    /bin/bash "$ROOT_DIR/scripts/resolve-service-token.sh" > "$case_dir/run.log" 2>&1
  local status=$?
  set -e

  if [ "$expected" = "success" ] && [ "$status" -ne 0 ]; then
    echo "Expected success for $phase user $user_id but got exit $status"
    sed -n '1,120p' "$case_dir/run.log"
    return 1
  fi

  if [ "$expected" = "failure" ] && [ "$status" -eq 0 ]; then
    echo "Expected failure for $phase user $user_id but got success"
    sed -n '1,120p' "$case_dir/run.log"
    return 1
  fi

  printf '%s\n' "$case_dir"
}

run_legacy_case() {
  local user_id="$1"
  local case_dir="$TMP_DIR/legacy_pmak/$user_id"
  local bin_dir="$case_dir/bin"
  mkdir -p "$bin_dir"
  install_fake_curl "$bin_dir"

  local api_key="PMAK-sim-user-${user_id}"
  local response_file="$case_dir/me.json"
  PATH="$bin_dir:$PATH" \
  SIM_MODE="legacy_pmak" \
  SIM_USER_ID="$user_id" \
    curl -sS -o "$response_file" -w "%{http_code}" \
      "https://api.getpostman.com/me" \
      -H "x-api-key: $api_key" > "$case_dir/http_code"

  assert_contains "$case_dir/http_code" "200" &&
    assert_contains "$response_file" "legacy-team-${user_id}"
}

run_parallel_phase() {
  local phase="$1"
  local users="$2"
  local pids_file="$TMP_DIR/$phase.pids"
  local i
  mkdir -p "$TMP_DIR/$phase"
  : > "$pids_file"

  for i in $(seq 1 "$users"); do
    (
      case "$phase" in
        service_account)
          case_dir="$(run_resolver_case "$phase" "$i" "success" "PMAK-sim-user-${i}" "")"
          assert_contains "$case_dir/github_output" "access-token=minted-token-${i}" &&
            assert_contains "$case_dir/github_output" "team-id=team-${i}" &&
            assert_contains "$case_dir/github_output" "token-expires-in=900" &&
            assert_secret_only_masked_in_log "$case_dir/run.log" "PMAK-sim-user-${i}" &&
            assert_secret_only_masked_in_log "$case_dir/run.log" "minted-token-${i}"
          ;;
        provided_token)
          case_dir="$(run_resolver_case "$phase" "$i" "success" "" "provided-token-${i}")"
          assert_contains "$case_dir/github_output" "skipped=true" &&
            assert_contains "$case_dir/github_output" "access-token=provided-token-${i}" &&
            assert_contains "$case_dir/github_output" "team-id=team-provided-${i}" &&
            assert_secret_only_masked_in_log "$case_dir/run.log" "provided-token-${i}"
          ;;
        mixed)
          if [ $((i % 10)) -eq 0 ]; then
            case_dir="$(run_resolver_case "$phase" "$i" "failure" "PMAK-sim-user-${i}" "")"
            assert_contains "$case_dir/run.log" "::error::service-account-tokens failed (HTTP 401)" &&
              assert_secret_only_masked_in_log "$case_dir/run.log" "PMAK-sim-user-${i}" &&
              assert_not_contains "$case_dir/run.log" "should-not-leak" &&
              assert_not_contains "$case_dir/github_output" "access-token="
          else
            case_dir="$(run_resolver_case "$phase" "$i" "success" "PMAK-sim-user-${i}" "")"
            assert_contains "$case_dir/github_output" "access-token=mixed-token-${i}" &&
              assert_contains "$case_dir/github_output" "team-id=team-mixed-${i}" &&
              assert_secret_only_masked_in_log "$case_dir/run.log" "mixed-token-${i}"
          fi
          ;;
        legacy_pmak)
          run_legacy_case "$i"
          ;;
        *)
          echo "Unknown phase: $phase" >&2
          exit 1
          ;;
      esac
    ) > "$TMP_DIR/$phase/$i.stdout" 2> "$TMP_DIR/$phase/$i.stderr" &
    echo "$! $i" >> "$pids_file"
  done

  local failures=0
  local pid
  local user_id
  while read -r pid user_id; do
    if ! wait "$pid"; then
      echo "--- $phase user $user_id failed ---"
      sed -n '1,160p' "$TMP_DIR/$phase/$user_id.stdout" 2>/dev/null || true
      sed -n '1,160p' "$TMP_DIR/$phase/$user_id.stderr" 2>/dev/null || true
      failures=$((failures + 1))
    fi
  done < "$pids_file"

  if [ "$failures" -ne 0 ]; then
    echo "$phase had $failures failed simulated users"
    return 1
  fi
}

run_phase() {
  local phase="$1"
  if run_parallel_phase "$phase" "$SIM_USERS"; then
    pass "$phase $SIM_USERS concurrent users"
  else
    fail "$phase $SIM_USERS concurrent users"
  fi
}

start_epoch="$(date +%s)"
run_phase "service_account"
run_phase "provided_token"
run_phase "mixed"
run_phase "legacy_pmak"
end_epoch="$(date +%s)"

echo "$PASS_COUNT passed, $FAIL_COUNT failed"
echo "simulated_users_per_phase=$SIM_USERS"
echo "total_simulated_user_runs=$((SIM_USERS * 4))"
echo "elapsed_seconds=$((end_epoch - start_epoch))"

if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
