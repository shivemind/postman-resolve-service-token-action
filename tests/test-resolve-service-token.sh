#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
TEST_API_KEY="PMAK-test-api-key"
TEST_EXISTING_TOKEN="existing-access-token"
TEST_MINTED_TOKEN="minted-access-token"

fail() {
  echo "not ok - $*"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  echo "ok - $*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_contains() {
  local file="$1"
  local expected="$2"
  if grep -Fq "$expected" "$file"; then
    return 0
  fi
  echo "Expected to find '$expected' in $file"
  echo "--- $file ---"
  sed -n '1,160p' "$file"
  return 1
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    echo "Did not expect to find '$unexpected' in $file"
    echo "--- $file ---"
    sed -n '1,160p' "$file"
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

has_header() {
  local needle="$1"
  local header
  for header in "${headers[@]}"; do
    if [ "$header" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

write_response() {
  local code="$1"
  local body="$2"
  printf '%s' "$body" > "$out_file"
  printf '%s' "$code"
}

case "$MOCK_SCENARIO:$url" in
  mint_success:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  mint_success:*/me)
    write_response 200 '{"team":{"id":"team-minted"}}'
    ;;
  token_passthrough:*service-account-tokens)
    echo "service-account-tokens should not have been called" >&2
    exit 91
    ;;
  token_passthrough:*/me)
    write_response 200 '{"user":{"teamId":"team-existing"}}'
    ;;
  bearer_only:*/me)
    if has_header "x-api-key: PMAK-test-api-key"; then
      write_response 400 '{"error":{"message":"x-api-key should not be sent"}}'
    else
      write_response 200 '{"identity":{"team":"team-bearer-only"}}'
    fi
    ;;
  invalid_key:*service-account-tokens)
    write_response 401 '{"error":{"message":"inactive key","apiKey":"PMAK-test-api-key","access_token":"minted-access-token","nested":{"secret":"do-not-log"}}}'
    ;;
  no_team:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  no_team:*/me)
    write_response 200 '{"user":{"name":"No Team Here"}}'
    ;;
  network_error:*service-account-tokens)
    echo "curl: (6) Could not resolve host" >&2
    exit 6
    ;;
  *)
    echo "Unexpected mock curl call for scenario '$MOCK_SCENARIO': $url" >&2
    exit 99
    ;;
esac
CURL
  chmod +x "$bin_dir/curl"
}

run_resolve() {
  local name="$1"
  local scenario="$2"
  local api_key="$3"
  local access_token="$4"
  local team_id="$5"
  local expected_status="$6"
  local case_dir="$TMP_DIR/$name"
  local bin_dir="$case_dir/bin"
  mkdir -p "$bin_dir"
  install_fake_curl "$bin_dir"

  local output_file="$case_dir/github_output"
  local log_file="$case_dir/run.log"
  set +e
  PATH="$bin_dir:$PATH" \
  MOCK_SCENARIO="$scenario" \
  POSTMAN_API_KEY="$api_key" \
  EXISTING_TOKEN="$access_token" \
  EXISTING_TEAM_ID="$team_id" \
  STACK="prod" \
  GITHUB_OUTPUT="$output_file" \
    bash "$ROOT_DIR/scripts/resolve-service-token.sh" > "$log_file" 2>&1
  local status=$?
  set -e

  if [ "$expected_status" = "success" ] && [ "$status" -ne 0 ]; then
    echo "Expected success but got exit $status"
    sed -n '1,160p' "$log_file"
    return 1
  fi
  if [ "$expected_status" = "failure" ] && [ "$status" -eq 0 ]; then
    echo "Expected failure but got success"
    sed -n '1,160p' "$log_file"
    return 1
  fi

  printf '%s\n' "$case_dir"
}

test_pmak_only_legacy_path() {
  local case_dir
  case_dir="$(run_resolve "pmak_only_legacy_path" "mint_success" "$TEST_API_KEY" "" "" "success")"
  assert_contains "$case_dir/github_output" "skipped=false" &&
    assert_contains "$case_dir/github_output" "auth-method=service-account-api-key" &&
    assert_contains "$case_dir/github_output" "token=$TEST_MINTED_TOKEN" &&
    assert_contains "$case_dir/github_output" "access-token=$TEST_MINTED_TOKEN" &&
    assert_contains "$case_dir/github_output" "team-id=team-minted" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_service_account_api_key_to_access_token() {
  local case_dir
  case_dir="$(run_resolve "service_account_api_key_to_access_token" "mint_success" "$TEST_API_KEY" "" "" "success")"
  assert_contains "$case_dir/github_output" "token=$TEST_MINTED_TOKEN" &&
    assert_contains "$case_dir/github_output" "team-id=team-minted"
}

test_access_token_already_provided() {
  local case_dir
  case_dir="$(run_resolve "access_token_already_provided" "token_passthrough" "$TEST_API_KEY" "$TEST_EXISTING_TOKEN" "" "success")"
  assert_contains "$case_dir/github_output" "skipped=true" &&
    assert_contains "$case_dir/github_output" "auth-method=provided-access-token" &&
    assert_contains "$case_dir/github_output" "token=$TEST_EXISTING_TOKEN" &&
    assert_contains "$case_dir/github_output" "team-id=team-existing" &&
    assert_contains "$case_dir/run.log" "Skipped mint - using provided postman-access-token." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_EXISTING_TOKEN"
}

test_bearer_only_team_id_fallback() {
  local case_dir
  case_dir="$(run_resolve "bearer_only_team_id_fallback" "bearer_only" "" "$TEST_EXISTING_TOKEN" "" "success")"
  assert_contains "$case_dir/github_output" "skipped=true" &&
    assert_contains "$case_dir/github_output" "team-id=team-bearer-only"
}

test_invalid_or_inactive_api_key_response() {
  local case_dir
  case_dir="$(run_resolve "invalid_or_inactive_api_key_response" "invalid_key" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::service-account-tokens failed (HTTP 401)" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_not_contains "$case_dir/run.log" "$TEST_MINTED_TOKEN" &&
    assert_not_contains "$case_dir/run.log" "do-not-log" &&
    assert_contains "$case_dir/run.log" "[REDACTED]"
}

test_unable_to_resolve_team_id() {
  local case_dir
  case_dir="$(run_resolve "unable_to_resolve_team_id" "no_team" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Could not read team id from /me response"
}

test_network_error() {
  local case_dir
  case_dir="$(run_resolve "network_error" "network_error" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Network error calling service-account-tokens"
}

test_write_github_secrets_masks_token_and_writes_expected_names() {
  local case_dir="$TMP_DIR/write_github_secrets"
  local bin_dir="$case_dir/bin"
  local log_file="$case_dir/run.log"
  local gh_log="$case_dir/gh.log"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
payload="$(cat)"
printf 'gh %s payload_length=%s\n' "$*" "${#payload}" >> "$MOCK_GH_LOG"
GH
  chmod +x "$bin_dir/gh"

  PATH="$bin_dir:$PATH" \
  MOCK_GH_LOG="$gh_log" \
  GH_TOKEN="github-token-test" \
  REPO="postman-cs/example" \
  TOKEN="$TEST_MINTED_TOKEN" \
  TEAM_ID="team-minted" \
  ACCESS_TOKEN_SECRET_NAME="POSTMAN_ACCESS_TOKEN" \
  TEAM_ID_SECRET_NAME="POSTMAN_TEAM_ID" \
    bash "$ROOT_DIR/scripts/write-github-secrets.sh" > "$log_file" 2>&1

  assert_contains "$log_file" "Wrote secrets: POSTMAN_ACCESS_TOKEN, POSTMAN_TEAM_ID" &&
    assert_secret_only_masked_in_log "$log_file" "$TEST_MINTED_TOKEN" &&
    assert_contains "$gh_log" "gh secret set POSTMAN_ACCESS_TOKEN --repo postman-cs/example" &&
    assert_contains "$gh_log" "gh secret set POSTMAN_TEAM_ID --repo postman-cs/example" &&
    assert_not_contains "$gh_log" "$TEST_MINTED_TOKEN" &&
    assert_not_contains "$gh_log" "team-minted"
}

for test_name in \
  test_pmak_only_legacy_path \
  test_service_account_api_key_to_access_token \
  test_access_token_already_provided \
  test_bearer_only_team_id_fallback \
  test_invalid_or_inactive_api_key_response \
  test_unable_to_resolve_team_id \
  test_network_error \
  test_write_github_secrets_masks_token_and_writes_expected_names
do
  if "$test_name"; then
    pass "$test_name"
  else
    fail "$test_name"
  fi
done

echo "$PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -ne 0 ]; then
  exit 1
fi
