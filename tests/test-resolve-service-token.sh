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

assert_secret_masked_before_first_output() {
  local file="$1"
  local secret="$2"
  local mask_line
  local first_unmasked_line
  mask_line="$(grep -nF "::add-mask::$secret" "$file" | head -n 1 | cut -d: -f1 || true)"
  first_unmasked_line="$(grep -nF "$secret" "$file" | grep -Fv "::add-mask::$secret" | head -n 1 | cut -d: -f1 || true)"

  if [ -z "$mask_line" ]; then
    echo "Expected mask command for secret in $file"
    sed -n '1,160p' "$file"
    return 1
  fi

  if [ -z "$first_unmasked_line" ]; then
    echo "Expected secret to appear in a simulated output line in $file"
    sed -n '1,160p' "$file"
    return 1
  fi

  if [ "$mask_line" -ge "$first_unmasked_line" ]; then
    echo "Expected mask command before first output containing the secret"
    sed -n '1,160p' "$file"
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
  provided_team_id_skips_me:*/me)
    echo "/me should not have been called when postman-team-id is provided" >&2
    exit 92
    ;;
  token_passthrough_with_api_key:*/me)
    if has_header "x-api-key: PMAK-test-api-key"; then
      write_response 200 '{"team":{"id":"team-from-api-key-lookup"}}'
    else
      write_response 401 '{"error":{"message":"api key required for this lookup"}}'
    fi
    ;;
  numeric_team_id:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  numeric_team_id:*/me)
    write_response 200 '{"user":{"teamId":13569807}}'
    ;;
  bearer_only:*/me)
    if has_header "x-api-key: PMAK-test-api-key"; then
      write_response 400 '{"error":{"message":"x-api-key should not be sent"}}'
    else
      write_response 200 '{"identity":{"team":"team-bearer-only"}}'
    fi
    ;;
  bearer_only_unauthorized:*/me)
    write_response 401 '{"error":{"name":"unauthorizedError","message":"You are not authorized to perform this action for existing-access-token."},"authorization":"Bearer existing-access-token"}'
    ;;
  invalid_key:*service-account-tokens)
    write_response 401 '{"error":{"message":"inactive key PMAK-test-api-key Bearer minted-access-token","apiKey":"PMAK-test-api-key","access_token":"minted-access-token","nested":{"secret":"do-not-log","authorization":"Bearer minted-access-token","auth":{"token":"minted-access-token"}}}}'
    ;;
  service_account_role_denied:*service-account-tokens)
    write_response 403 '{"status":403,"title":"Forbidden","detail":"Service account does not have permission to mint access tokens for this team.","requiredRole":"Team Admin","type":"https://api.postman.com/problems/forbidden"}'
    ;;
  no_token:*service-account-tokens)
    write_response 200 '{"token_type":"bearer"}'
    ;;
  malformed_token_response:*service-account-tokens)
    write_response 200 '<html>not json</html>'
    ;;
  me_unauthorized:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  me_unauthorized:*/me)
    write_response 403 '{"error":{"name":"forbiddenError","message":"Team lookup forbidden for Bearer minted-access-token"},"authorization":"Bearer minted-access-token"}'
    ;;
  workspace_role_missing:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  workspace_role_missing:*/me)
    write_response 403 '{"error":{"name":"forbiddenError","message":"Service account is not assigned to this workspace or lacks required workspace role."},"requiredWorkspaceRole":"Admin"}'
    ;;
  me_network_error:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  me_network_error:*/me)
    echo "curl: (28) Operation timed out" >&2
    exit 28
    ;;
  malformed_me_response:*service-account-tokens)
    write_response 200 '{"access_token":"minted-access-token"}'
    ;;
  malformed_me_response:*/me)
    write_response 200 'not-json'
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

run_resolve_with_stack() {
  local name="$1"
  local scenario="$2"
  local api_key="$3"
  local access_token="$4"
  local team_id="$5"
  local stack="$6"
  local expected_status="$7"
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
  STACK="$stack" \
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

run_resolve_with_stdout_outputs() {
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

  local log_file="$case_dir/run.log"
  set +e
  PATH="$bin_dir:$PATH" \
  MOCK_SCENARIO="$scenario" \
  POSTMAN_API_KEY="$api_key" \
  EXISTING_TOKEN="$access_token" \
  EXISTING_TEAM_ID="$team_id" \
  STACK="prod" \
  GITHUB_OUTPUT="/dev/stdout" \
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

run_write_github_secrets() {
  local name="$1"
  local gh_token="$2"
  local repo="$3"
  local token="$4"
  local team_id="$5"
  local install_gh="${6:-yes}"
  local expected_status="$7"
  local case_dir="$TMP_DIR/$name"
  local bin_dir="$case_dir/bin"
  local log_file="$case_dir/run.log"
  local gh_log="$case_dir/gh.log"
  mkdir -p "$bin_dir"

  case "$install_gh" in
    yes)
      cat > "$bin_dir/gh" <<'GH'
#!/bin/bash
set -euo pipefail
payload="$(cat)"
printf 'gh %s payload_length=%s\n' "$*" "${#payload}" >> "$MOCK_GH_LOG"
GH
      chmod +x "$bin_dir/gh"
      ;;
    fail-permission)
      cat > "$bin_dir/gh" <<'GH'
#!/bin/bash
set -euo pipefail
cat >/dev/null
echo "HTTP 403: Resource not accessible by integration" >&2
exit 1
GH
      chmod +x "$bin_dir/gh"
      ;;
    no)
      ;;
    *)
      echo "Unknown gh install mode: $install_gh" >&2
      return 1
      ;;
  esac
  local run_path="$bin_dir"
  if [ "$install_gh" != "no" ]; then
    run_path="$bin_dir:/bin:/usr/bin"
  fi

  set +e
  PATH="$run_path" \
  MOCK_GH_LOG="$gh_log" \
  GH_TOKEN="$gh_token" \
  REPO="$repo" \
  TOKEN="$token" \
  TEAM_ID="$team_id" \
  ACCESS_TOKEN_SECRET_NAME="POSTMAN_ACCESS_TOKEN" \
  TEAM_ID_SECRET_NAME="POSTMAN_TEAM_ID" \
    /bin/bash "$ROOT_DIR/scripts/write-github-secrets.sh" > "$log_file" 2>&1
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

test_missing_required_auth_inputs() {
  local case_dir
  case_dir="$(run_resolve "missing_required_auth_inputs" "mint_success" "" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::postman-api-key is required when postman-access-token is not provided."
}

test_invalid_stack_input() {
  local case_dir
  case_dir="$(run_resolve_with_stack "invalid_stack_input" "mint_success" "$TEST_API_KEY" "" "" "staging" "failure")"
  assert_contains "$case_dir/run.log" "::error::postman-stack must be one of: prod, beta; got: staging"
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

test_numeric_team_id_resolution() {
  local case_dir
  case_dir="$(run_resolve "numeric_team_id_resolution" "numeric_team_id" "$TEST_API_KEY" "" "" "success")"
  assert_contains "$case_dir/github_output" "token=$TEST_MINTED_TOKEN" &&
    assert_contains "$case_dir/github_output" "team-id=13569807"
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

test_provided_team_id_skips_lookup() {
  local case_dir
  case_dir="$(run_resolve "provided_team_id_skips_lookup" "provided_team_id_skips_me" "" "$TEST_EXISTING_TOKEN" "team-known" "success")"
  assert_contains "$case_dir/github_output" "skipped=true" &&
    assert_contains "$case_dir/github_output" "team-id=team-known" &&
    assert_contains "$case_dir/run.log" "Using provided postman-team-id."
}

test_access_token_with_api_key_team_lookup() {
  local case_dir
  case_dir="$(run_resolve "access_token_with_api_key_team_lookup" "token_passthrough_with_api_key" "$TEST_API_KEY" "$TEST_EXISTING_TOKEN" "" "success")"
  assert_contains "$case_dir/github_output" "skipped=true" &&
    assert_contains "$case_dir/github_output" "auth-method=provided-access-token" &&
    assert_contains "$case_dir/github_output" "team-id=team-from-api-key-lookup" &&
    assert_not_contains "$case_dir/run.log" "service-account-tokens should not have been called"
}

test_token_endpoint_success_without_token() {
  local case_dir
  case_dir="$(run_resolve "token_endpoint_success_without_token" "no_token" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Mint succeeded but no access token in response" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_token_endpoint_malformed_json() {
  local case_dir
  case_dir="$(run_resolve "token_endpoint_malformed_json" "malformed_token_response" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Mint succeeded but token response was not valid JSON" &&
    assert_contains "$case_dir/run.log" "[unparseable response omitted]" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_service_account_role_denied_on_token_mint() {
  local case_dir
  case_dir="$(run_resolve "service_account_role_denied_on_token_mint" "service_account_role_denied" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::service-account-tokens failed (HTTP 403)" &&
    assert_contains "$case_dir/run.log" "Service account does not have permission to mint access tokens for this team." &&
    assert_contains "$case_dir/run.log" "Team Admin" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_bearer_only_team_id_fallback() {
  local case_dir
  case_dir="$(run_resolve "bearer_only_team_id_fallback" "bearer_only" "" "$TEST_EXISTING_TOKEN" "" "success")"
  assert_contains "$case_dir/github_output" "skipped=true" &&
    assert_contains "$case_dir/github_output" "team-id=team-bearer-only"
}

test_bearer_only_team_id_fallback_failure_message() {
  local case_dir
  case_dir="$(run_resolve "bearer_only_team_id_fallback_failure_message" "bearer_only_unauthorized" "" "$TEST_EXISTING_TOKEN" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::/me failed (HTTP 401) while resolving team ID from postman-access-token. Provide postman-team-id to skip Bearer-only lookup, or provide postman-api-key for Team ID lookup." &&
    assert_contains "$case_dir/run.log" "unauthorizedError" &&
    assert_contains "$case_dir/run.log" "[REDACTED]" &&
    assert_not_contains "$case_dir/run.log" "Bearer $TEST_EXISTING_TOKEN" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_EXISTING_TOKEN"
}

test_me_lookup_forbidden_with_service_account() {
  local case_dir
  case_dir="$(run_resolve "me_lookup_forbidden_with_service_account" "me_unauthorized" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::/me failed (HTTP 403) while resolving team ID." &&
    assert_contains "$case_dir/run.log" "forbiddenError" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_workspace_role_missing_for_team_lookup() {
  local case_dir
  case_dir="$(run_resolve "workspace_role_missing_for_team_lookup" "workspace_role_missing" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::/me failed (HTTP 403) while resolving team ID." &&
    assert_contains "$case_dir/run.log" "Service account is not assigned to this workspace or lacks required workspace role." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_me_lookup_network_error() {
  local case_dir
  case_dir="$(run_resolve "me_lookup_network_error" "me_network_error" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Network error calling /me" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_me_lookup_malformed_json() {
  local case_dir
  case_dir="$(run_resolve "me_lookup_malformed_json" "malformed_me_response" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::/me succeeded but response was not valid JSON" &&
    assert_contains "$case_dir/run.log" "[unparseable /me response omitted]" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_invalid_or_inactive_api_key_response() {
  local case_dir
  case_dir="$(run_resolve "invalid_or_inactive_api_key_response" "invalid_key" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::service-account-tokens failed (HTTP 401)" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY" &&
    assert_not_contains "$case_dir/run.log" "$TEST_MINTED_TOKEN" &&
    assert_not_contains "$case_dir/run.log" "$TEST_API_KEY $TEST_MINTED_TOKEN" &&
    assert_not_contains "$case_dir/run.log" "do-not-log" &&
    assert_contains "$case_dir/run.log" "[REDACTED]"
}

test_generated_token_masked_before_stdout_output() {
  local case_dir
  case_dir="$(run_resolve_with_stdout_outputs "generated_token_masked_before_stdout_output" "mint_success" "$TEST_API_KEY" "" "" "success")"
  assert_secret_masked_before_first_output "$case_dir/run.log" "$TEST_MINTED_TOKEN" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_provided_token_masked_before_stdout_output() {
  local case_dir
  case_dir="$(run_resolve_with_stdout_outputs "provided_token_masked_before_stdout_output" "token_passthrough" "$TEST_API_KEY" "$TEST_EXISTING_TOKEN" "" "success")"
  assert_secret_masked_before_first_output "$case_dir/run.log" "$TEST_EXISTING_TOKEN" &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_API_KEY"
}

test_unable_to_resolve_team_id() {
  local case_dir
  case_dir="$(run_resolve "unable_to_resolve_team_id" "no_team" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Could not read team id from /me response. Provide postman-team-id to skip Team ID lookup." &&
    assert_contains "$case_dir/run.log" "[/me response omitted: response may include account metadata]" &&
    assert_not_contains "$case_dir/run.log" "No Team Here"
}

test_network_error() {
  local case_dir
  case_dir="$(run_resolve "network_error" "network_error" "$TEST_API_KEY" "" "" "failure")"
  assert_contains "$case_dir/run.log" "::error::Network error calling service-account-tokens"
}

test_write_github_secrets_masks_token_and_writes_expected_names() {
  local case_dir
  case_dir="$(run_write_github_secrets "write_github_secrets" "github-token-test" "postman-cs/example" "$TEST_MINTED_TOKEN" "team-minted" "yes" "success")"
  local log_file="$case_dir/run.log"
  local gh_log="$case_dir/gh.log"

  assert_contains "$log_file" "Wrote secrets: POSTMAN_ACCESS_TOKEN, POSTMAN_TEAM_ID" &&
    assert_secret_only_masked_in_log "$log_file" "$TEST_MINTED_TOKEN" &&
    assert_contains "$gh_log" "gh secret set POSTMAN_ACCESS_TOKEN --repo postman-cs/example" &&
    assert_contains "$gh_log" "gh secret set POSTMAN_TEAM_ID --repo postman-cs/example" &&
    assert_not_contains "$gh_log" "$TEST_MINTED_TOKEN" &&
    assert_not_contains "$gh_log" "team-minted"
}

test_secret_refresh_missing_github_token() {
  local case_dir
  case_dir="$(run_write_github_secrets "secret_refresh_missing_github_token" "" "postman-cs/example" "$TEST_MINTED_TOKEN" "team-minted" "yes" "failure")"
  assert_contains "$case_dir/run.log" "::error::github-token is required when write-github-secret is 'true'." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_secret_refresh_missing_repo() {
  local case_dir
  case_dir="$(run_write_github_secrets "secret_refresh_missing_repo" "github-token-test" "" "$TEST_MINTED_TOKEN" "team-minted" "yes" "failure")"
  assert_contains "$case_dir/run.log" "::error::github.repository is required to write repo secrets." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_secret_refresh_missing_resolved_values() {
  local case_dir
  case_dir="$(run_write_github_secrets "secret_refresh_missing_resolved_values" "github-token-test" "postman-cs/example" "" "" "yes" "failure")"
  assert_contains "$case_dir/run.log" "::error::Resolved token and team ID are required to write repo secrets."
}

test_secret_refresh_missing_gh_cli() {
  local case_dir
  case_dir="$(run_write_github_secrets "secret_refresh_missing_gh_cli" "github-token-test" "postman-cs/example" "$TEST_MINTED_TOKEN" "team-minted" "no" "failure")"
  assert_contains "$case_dir/run.log" "::error::gh CLI not found on runner." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

test_secret_refresh_github_token_lacks_secrets_write_permission() {
  local case_dir
  case_dir="$(run_write_github_secrets "secret_refresh_github_token_lacks_permission" "github-token-test" "postman-cs/example" "$TEST_MINTED_TOKEN" "team-minted" "fail-permission" "failure")"
  assert_contains "$case_dir/run.log" "HTTP 403: Resource not accessible by integration" &&
    assert_contains "$case_dir/run.log" "::error::Failed to write GitHub secret POSTMAN_ACCESS_TOKEN. Ensure github-token has repo Actions secrets write permission for postman-cs/example." &&
    assert_secret_only_masked_in_log "$case_dir/run.log" "$TEST_MINTED_TOKEN"
}

for test_name in \
  test_missing_required_auth_inputs \
  test_invalid_stack_input \
  test_pmak_only_legacy_path \
  test_service_account_api_key_to_access_token \
  test_numeric_team_id_resolution \
  test_access_token_already_provided \
  test_provided_team_id_skips_lookup \
  test_access_token_with_api_key_team_lookup \
  test_token_endpoint_success_without_token \
  test_token_endpoint_malformed_json \
  test_service_account_role_denied_on_token_mint \
  test_bearer_only_team_id_fallback \
  test_bearer_only_team_id_fallback_failure_message \
  test_me_lookup_forbidden_with_service_account \
  test_workspace_role_missing_for_team_lookup \
  test_me_lookup_network_error \
  test_me_lookup_malformed_json \
  test_invalid_or_inactive_api_key_response \
  test_generated_token_masked_before_stdout_output \
  test_provided_token_masked_before_stdout_output \
  test_unable_to_resolve_team_id \
  test_network_error \
  test_write_github_secrets_masks_token_and_writes_expected_names \
  test_secret_refresh_missing_github_token \
  test_secret_refresh_missing_repo \
  test_secret_refresh_missing_resolved_values \
  test_secret_refresh_missing_gh_cli \
  test_secret_refresh_github_token_lacks_secrets_write_permission
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
