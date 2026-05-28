#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
TEST_API_KEY="PMAK-template-test-key"
TEST_ACCESS_TOKEN="template-access-token"
TEST_TEAM_ID="template-team-id"

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
  echo "Expected to find '$expected' in $file"
  sed -n '1,180p' "$file"
  return 1
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -Fq "$unexpected" "$file"; then
    echo "Did not expect to find '$unexpected' in $file"
    sed -n '1,180p' "$file"
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

get_output() {
  local file="$1"
  local name="$2"
  grep -E "^${name}=" "$file" | tail -n 1 | cut -d= -f2-
}

install_fake_curl() {
  local bin_dir="$1"
  cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

out_file=""
url=""

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

write_response() {
  local code="$1"
  local body="$2"
  printf '%s' "$body" > "$out_file"
  printf '%s' "$code"
}

case "$MOCK_SCENARIO:$url" in
  service_account:*service-account-tokens)
    write_response 200 '{"access_token":"template-access-token"}'
    ;;
  service_account:*/me)
    write_response 200 '{"user":{"teamId":"template-team-id"}}'
    ;;
  provided_token:*/me)
    echo "/me should be skipped because template passes postman-team-id" >&2
    exit 92
    ;;
  *)
    echo "Unexpected mock curl call for scenario '$MOCK_SCENARIO': $url" >&2
    exit 99
    ;;
esac
CURL
  chmod +x "$bin_dir/curl"
}

run_resolver_like_template() {
  local name="$1"
  local scenario="$2"
  local api_key="$3"
  local access_token="$4"
  local team_id="$5"
  local case_dir="$TMP_DIR/$name"
  local bin_dir="$case_dir/bin"
  mkdir -p "$bin_dir"
  install_fake_curl "$bin_dir"

  PATH="$bin_dir:$PATH" \
  MOCK_SCENARIO="$scenario" \
  POSTMAN_API_KEY="$api_key" \
  EXISTING_TOKEN="$access_token" \
  EXISTING_TEAM_ID="$team_id" \
  STACK="prod" \
  GITHUB_OUTPUT="$case_dir/outputs" \
    bash "$ROOT_DIR/scripts/resolve-service-token.sh" > "$case_dir/resolve.log" 2>&1

  printf '%s\n' "$case_dir"
}

run_resolver_like_reusable_template() {
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
  : > "$case_dir/outputs"

  set +e
  PATH="$bin_dir:$PATH" \
  MOCK_SCENARIO="$scenario" \
  POSTMAN_API_KEY="$api_key" \
  EXISTING_TOKEN="$access_token" \
  EXISTING_TEAM_ID="$team_id" \
  STACK="prod" \
  GITHUB_OUTPUT="$case_dir/outputs" \
    bash "$ROOT_DIR/scripts/resolve-service-token.sh" > "$case_dir/resolve.log" 2>&1
  local status=$?
  set -e

  if [ "$expected_status" = "success" ] && [ "$status" -ne 0 ]; then
    echo "Expected success but got exit $status"
    sed -n '1,180p' "$case_dir/resolve.log"
    return 1
  fi
  if [ "$expected_status" = "failure" ] && [ "$status" -eq 0 ]; then
    echo "Expected failure but got success"
    sed -n '1,180p' "$case_dir/resolve.log"
    return 1
  fi

  printf '%s\n' "$case_dir"
}

simulate_downstream_cse_template() {
  local case_dir="$1"
  local api_key="$2"
  local access_token="$3"
  local team_id="$4"
  local log_file="$case_dir/downstream.log"

  {
    if [ -n "$access_token" ]; then
      test -n "$team_id"
      echo "auth_method=access-token"
      echo "team_id_present=true"
      echo "api_key_still_available=$([ -n "$api_key" ] && echo true || echo false)"
    else
      test -n "$api_key"
      echo "auth_method=api-key"
      echo "team_id_present=false"
    fi
  } > "$log_file"
}

simulate_downstream_cse_template_with_workspace_role() {
  local case_dir="$1"
  local api_key="$2"
  local access_token="$3"
  local team_id="$4"
  local workspace_role="$5"
  local required_role="${6:-Admin}"
  local log_file="$case_dir/downstream-role.log"

  {
    test -n "$api_key"
    test -n "$access_token"
    test -n "$team_id"
    if [ "$workspace_role" != "$required_role" ]; then
      echo "::error::Postman service account requires $required_role role on the target workspace; got ${workspace_role:-unassigned}."
      return 1
    fi
    echo "workspace_role_ok=true"
  } > "$log_file"
}

test_example_workflow_wires_resolver_outputs_to_downstream() {
  local example="$ROOT_DIR/examples/github-actions-template-integration.yml"
  assert_contains "$example" "id: postman_auth" &&
    assert_contains "$example" "uses: postman-cs/postman-resolve-service-token-action@v0" &&
    assert_contains "$example" "postman-api-key: \${{ secrets.POSTMAN_API_KEY }}" &&
    assert_contains "$example" "postman-access-token: \${{ steps.postman_auth.outputs.access-token }}" &&
    assert_contains "$example" "postman-team-id: \${{ steps.postman_auth.outputs.team-id }}"
}

test_example_workflow_is_not_fork_pr_secret_entrypoint() {
  local example="$ROOT_DIR/examples/github-actions-template-integration.yml"
  assert_contains "$example" "workflow_dispatch:" &&
    assert_contains "$example" "permissions:" &&
    assert_contains "$example" "contents: read" &&
    assert_not_contains "$example" "pull_request:" &&
    assert_not_contains "$example" "pull_request_target:" &&
    assert_not_contains "$example" "write-github-secret: 'true'" &&
    assert_not_contains "$example" "github-token:"
}

test_reusable_workflow_declares_customer_contract() {
  local reusable="$ROOT_DIR/examples/reusable-cse-postman-auth-template.yml"
  assert_contains "$reusable" "workflow_call:" &&
    assert_contains "$reusable" "project-name:" &&
    assert_contains "$reusable" "spec-path:" &&
    assert_contains "$reusable" "POSTMAN_API_KEY:" &&
    assert_contains "$reusable" "POSTMAN_ACCESS_TOKEN:" &&
    assert_contains "$reusable" "POSTMAN_TEAM_ID:" &&
    assert_contains "$reusable" "SECRETS_WRITE_PAT:" &&
    assert_contains "$reusable" "auth-method:" &&
    assert_contains "$reusable" "team-id:" &&
    assert_contains "$reusable" "permissions:" &&
    assert_contains "$reusable" "contents: read" &&
    assert_not_contains "$reusable" "pull_request:" &&
    assert_not_contains "$reusable" "pull_request_target:"
}

test_reusable_workflow_wires_resolver_outputs_to_downstream() {
  local reusable="$ROOT_DIR/examples/reusable-cse-postman-auth-template.yml"
  assert_contains "$reusable" "id: postman_auth" &&
    assert_contains "$reusable" "uses: postman-cs/postman-resolve-service-token-action@v0" &&
    assert_contains "$reusable" "write-github-secret: \${{ inputs.write-github-secret }}" &&
    assert_contains "$reusable" "github-token: \${{ secrets.SECRETS_WRITE_PAT }}" &&
    assert_contains "$reusable" "postman-api-key: \${{ secrets.POSTMAN_API_KEY }}" &&
    assert_contains "$reusable" "postman-access-token: \${{ steps.postman_auth.outputs.access-token }}" &&
    assert_contains "$reusable" "postman-team-id: \${{ steps.postman_auth.outputs.team-id }}"
}

test_reusable_template_service_account_contract_run() {
  local case_dir
  case_dir="$(run_resolver_like_reusable_template "reusable_service_account" "service_account" "$TEST_API_KEY" "" "" "success")"

  local access_token
  local team_id
  access_token="$(get_output "$case_dir/outputs" "access-token")"
  team_id="$(get_output "$case_dir/outputs" "team-id")"

  simulate_downstream_cse_template "$case_dir" "$TEST_API_KEY" "$access_token" "$team_id"

  test "$access_token" = "$TEST_ACCESS_TOKEN" &&
    test "$team_id" = "$TEST_TEAM_ID" &&
    assert_contains "$case_dir/downstream.log" "auth_method=access-token" &&
    assert_contains "$case_dir/downstream.log" "team_id_present=true" &&
    assert_secret_only_masked_in_log "$case_dir/resolve.log" "$TEST_ACCESS_TOKEN"
}

test_reusable_template_missing_auth_secrets_fails_before_downstream() {
  local case_dir
  case_dir="$(run_resolver_like_reusable_template "reusable_missing_auth" "service_account" "" "" "" "failure")"
  assert_contains "$case_dir/resolve.log" "::error::postman-api-key is required when postman-access-token is not provided." &&
    assert_not_contains "$case_dir/outputs" "access-token="
}

test_ci_pull_request_workflow_does_not_reference_customer_secrets() {
  local ci="$ROOT_DIR/.github/workflows/ci.yml"
  assert_contains "$ci" "pull_request:" &&
    assert_contains "$ci" "permissions:" &&
    assert_contains "$ci" "contents: read" &&
    assert_not_contains "$ci" "pull_request_target:" &&
    assert_not_contains "$ci" "secrets." &&
    assert_not_contains "$ci" "POSTMAN_API_KEY" &&
    assert_not_contains "$ci" "POSTMAN_ACCESS_TOKEN" &&
    assert_not_contains "$ci" "write-github-secret"
}

test_service_account_resolution_feeds_downstream_template() {
  local case_dir
  case_dir="$(run_resolver_like_template "service_account_template" "service_account" "$TEST_API_KEY" "" "")"

  local access_token
  local team_id
  local skipped
  local auth_method
  access_token="$(get_output "$case_dir/outputs" "access-token")"
  team_id="$(get_output "$case_dir/outputs" "team-id")"
  skipped="$(get_output "$case_dir/outputs" "skipped")"
  auth_method="$(get_output "$case_dir/outputs" "auth-method")"

  simulate_downstream_cse_template "$case_dir" "$TEST_API_KEY" "$access_token" "$team_id"

  test "$access_token" = "$TEST_ACCESS_TOKEN" &&
    test "$team_id" = "$TEST_TEAM_ID" &&
    test "$skipped" = "false" &&
    test "$auth_method" = "service-account-api-key" &&
    assert_contains "$case_dir/downstream.log" "auth_method=access-token" &&
    assert_contains "$case_dir/downstream.log" "team_id_present=true" &&
    assert_contains "$case_dir/downstream.log" "api_key_still_available=true" &&
    assert_secret_only_masked_in_log "$case_dir/resolve.log" "$TEST_ACCESS_TOKEN"
}

test_provided_access_token_template_skips_mint_and_feeds_downstream() {
  local case_dir
  case_dir="$(run_resolver_like_template "provided_token_template" "provided_token" "$TEST_API_KEY" "$TEST_ACCESS_TOKEN" "$TEST_TEAM_ID")"

  local access_token
  local team_id
  local skipped
  local auth_method
  access_token="$(get_output "$case_dir/outputs" "access-token")"
  team_id="$(get_output "$case_dir/outputs" "team-id")"
  skipped="$(get_output "$case_dir/outputs" "skipped")"
  auth_method="$(get_output "$case_dir/outputs" "auth-method")"

  simulate_downstream_cse_template "$case_dir" "$TEST_API_KEY" "$access_token" "$team_id"

  test "$access_token" = "$TEST_ACCESS_TOKEN" &&
    test "$team_id" = "$TEST_TEAM_ID" &&
    test "$skipped" = "true" &&
    test "$auth_method" = "provided-access-token" &&
    assert_contains "$case_dir/resolve.log" "Skipped mint - using provided postman-access-token." &&
    assert_contains "$case_dir/downstream.log" "auth_method=access-token"
}

test_legacy_pmak_only_template_path_still_works_without_resolver() {
  local case_dir="$TMP_DIR/legacy_pmak_template"
  mkdir -p "$case_dir"

  simulate_downstream_cse_template "$case_dir" "$TEST_API_KEY" "" ""

  assert_contains "$case_dir/downstream.log" "auth_method=api-key" &&
    assert_contains "$case_dir/downstream.log" "team_id_present=false"
}

test_downstream_template_surfaces_workspace_role_gap() {
  local case_dir
  case_dir="$(run_resolver_like_template "workspace_role_template" "service_account" "$TEST_API_KEY" "" "")"

  local access_token
  local team_id
  access_token="$(get_output "$case_dir/outputs" "access-token")"
  team_id="$(get_output "$case_dir/outputs" "team-id")"

  set +e
  simulate_downstream_cse_template_with_workspace_role "$case_dir" "$TEST_API_KEY" "$access_token" "$team_id" "" "Admin"
  local status=$?
  set -e

  test "$status" -ne 0 &&
    assert_contains "$case_dir/downstream-role.log" "::error::Postman service account requires Admin role on the target workspace; got unassigned."
}

test_downstream_template_accepts_required_workspace_role() {
  local case_dir
  case_dir="$(run_resolver_like_template "workspace_role_ok_template" "service_account" "$TEST_API_KEY" "" "")"

  local access_token
  local team_id
  access_token="$(get_output "$case_dir/outputs" "access-token")"
  team_id="$(get_output "$case_dir/outputs" "team-id")"

  simulate_downstream_cse_template_with_workspace_role "$case_dir" "$TEST_API_KEY" "$access_token" "$team_id" "Admin" "Admin"

  assert_contains "$case_dir/downstream-role.log" "workspace_role_ok=true"
}

for test_name in \
  test_example_workflow_wires_resolver_outputs_to_downstream \
  test_example_workflow_is_not_fork_pr_secret_entrypoint \
  test_reusable_workflow_declares_customer_contract \
  test_reusable_workflow_wires_resolver_outputs_to_downstream \
  test_reusable_template_service_account_contract_run \
  test_reusable_template_missing_auth_secrets_fails_before_downstream \
  test_ci_pull_request_workflow_does_not_reference_customer_secrets \
  test_service_account_resolution_feeds_downstream_template \
  test_provided_access_token_template_skips_mint_and_feeds_downstream \
  test_legacy_pmak_only_template_path_still_works_without_resolver \
  test_downstream_template_surfaces_workspace_role_gap \
  test_downstream_template_accepts_required_workspace_role
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
