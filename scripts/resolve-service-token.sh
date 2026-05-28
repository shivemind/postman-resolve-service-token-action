#!/usr/bin/env bash
set -euo pipefail

POSTMAN_API_KEY="${POSTMAN_API_KEY:-}"
EXISTING_TOKEN="${EXISTING_TOKEN:-}"
EXISTING_TEAM_ID="${EXISTING_TEAM_ID:-}"
STACK="${STACK:-prod}"
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"

mask_if_set() {
  local value="${1:-}"
  if [ -n "$value" ]; then
    echo "::add-mask::$value"
  fi
}

contains_line_break() {
  local value="${1:-}"
  case "$value" in
    *$'\n'*|*$'\r'*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_no_line_breaks() {
  local label="$1"
  local value="${2:-}"
  if contains_line_break "$value"; then
    log_error "$label must not contain newline or carriage return characters."
    exit 1
  fi
}

write_output() {
  local name="$1"
  local value="$2"
  if contains_line_break "$value"; then
    log_error "Refusing to write unsafe output '$name': value contains newline or carriage return characters."
    exit 1
  fi
  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}

log_error() {
  echo "::error::$*"
}

redact_known_values() {
  local text="$1"
  local value
  for value in "$POSTMAN_API_KEY" "$EXISTING_TOKEN" "${TOKEN:-}"; do
    if [ -n "$value" ]; then
      text="${text//$value/[REDACTED]}"
    fi
  done
  printf '%s\n' "$text"
}

sanitize_response() {
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    local sanitized
    sanitized="$(printf '%s' "$body" | jq '
      def scrub_secret_string:
        gsub("PMAK-[A-Za-z0-9._-]+"; "[REDACTED]")
        | gsub("Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+"; "Bearer [REDACTED]")
        | gsub("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[REDACTED]");
      def redact:
        if type == "object" then
          with_entries(
            if (.key | test("(token|secret|api[-_]?key|apikey|authorization|auth)"; "i")) then
              .value = "[REDACTED]"
            else
              .value |= redact
            end
          )
        elif type == "array" then
          map(redact)
        elif type == "string" then
          scrub_secret_string
        else
          .
        end;
      redact
    ' 2>/dev/null)" || sanitized='[unparseable response omitted]'
    redact_known_values "$sanitized"
  else
    printf '%s\n' '[response omitted: jq is required to safely redact error responses]'
  fi
}

summarize_me_response() {
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    if ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' '[unparseable /me response omitted]'
      return
    fi
    if printf '%s' "$body" | jq -e 'has("error") or has("errors") or has("status") or has("title") or has("detail")' >/dev/null 2>&1; then
      local summary
      summary="$(printf '%s' "$body" | jq '
        def scrub_secret_string:
          gsub("PMAK-[A-Za-z0-9._-]+"; "[REDACTED]")
          | gsub("Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+"; "Bearer [REDACTED]")
          | gsub("[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "[REDACTED]");
        {
          status: .status?,
          title: (.title? | if type == "string" then scrub_secret_string else . end),
          detail: (.detail? | if type == "string" then scrub_secret_string else . end),
          error: (
            if (.error | type) == "object" then
              {
                name: .error.name?,
                message: (.error.message? | if type == "string" then scrub_secret_string else . end)
              }
            else
              (.error? | if type == "string" then scrub_secret_string else . end)
            end
          ),
          errors: .errors?
        }
        | with_entries(select(.value != null))
      ' 2>/dev/null)" || summary='[unparseable /me response omitted]'
      redact_known_values "$summary"
    else
      printf '%s\n' '[/me response omitted: response may include account metadata]'
    fi
  else
    printf '%s\n' '[/me response omitted: jq is required to safely summarize /me responses]'
  fi
}

call_curl() {
  local response_file="$1"
  shift
  local http_code
  if ! http_code="$(curl -sS -o "$response_file" -w "%{http_code}" "$@")"; then
    return 1
  fi
  printf '%s' "$http_code"
}

case "$STACK" in
  prod)
    API_HOST="https://api.getpostman.com"
    ;;
  beta)
    API_HOST="https://api.getpostman-beta.com"
    ;;
  *)
    log_error "postman-stack must be one of: prod, beta; got: $STACK"
    exit 1
    ;;
esac

validate_no_line_breaks "postman-api-key" "$POSTMAN_API_KEY"
validate_no_line_breaks "postman-access-token" "$EXISTING_TOKEN"
validate_no_line_breaks "postman-team-id" "$EXISTING_TEAM_ID"

mask_if_set "$POSTMAN_API_KEY"
mask_if_set "$EXISTING_TOKEN"

if [ -n "$EXISTING_TOKEN" ]; then
  write_output "skipped" "true"
  write_output "auth-method" "provided-access-token"
  write_output "token" "$EXISTING_TOKEN"
  write_output "access-token" "$EXISTING_TOKEN"
  write_output "token-expires-at" ""
  write_output "token-expires-in" ""
  TOKEN="$EXISTING_TOKEN"
  echo "Skipped mint - using provided postman-access-token."
else
  if [ -z "$POSTMAN_API_KEY" ]; then
    log_error "postman-api-key is required when postman-access-token is not provided."
    exit 1
  fi

  write_output "skipped" "false"
  write_output "auth-method" "service-account-api-key"
  MINT_URL="$API_HOST/service-account-tokens"
  MINT_BODY="$(jq -nc --arg k "$POSTMAN_API_KEY" '{apiKey:$k}')"
  MINT_RESPONSE_FILE="$(mktemp)"
  if ! HTTP_CODE="$(call_curl "$MINT_RESPONSE_FILE" -X POST "$MINT_URL" \
    -H "Content-Type: application/json" \
    -H "x-api-key: $POSTMAN_API_KEY" \
    --data "$MINT_BODY")"; then
    rm -f "$MINT_RESPONSE_FILE"
    log_error "Network error calling service-account-tokens"
    exit 1
  fi
  RESPONSE="$(cat "$MINT_RESPONSE_FILE")"
  rm -f "$MINT_RESPONSE_FILE"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    log_error "service-account-tokens failed (HTTP $HTTP_CODE)"
    sanitize_response "$RESPONSE"
    exit 1
  fi

  if ! TOKEN="$(printf '%s' "$RESPONSE" | jq -r '.access_token // .accessToken // .token // .session.token // empty')"; then
    log_error "Mint succeeded but token response was not valid JSON"
    sanitize_response "$RESPONSE"
    exit 1
  fi
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log_error "Mint succeeded but no access token in response"
    sanitize_response "$RESPONSE"
    exit 1
  fi
  validate_no_line_breaks "resolved access token" "$TOKEN"
  mask_if_set "$TOKEN"
  write_output "token" "$TOKEN"
  write_output "access-token" "$TOKEN"
  TOKEN_EXPIRES_AT="$(printf '%s' "$RESPONSE" | jq -r '.expires_at // .expiresAt // .expiration // .expiresAtUtc // empty')"
  TOKEN_EXPIRES_IN="$(printf '%s' "$RESPONSE" | jq -r '.expires_in // .expiresIn // .expires // empty | tostring')"
  write_output "token-expires-at" "$TOKEN_EXPIRES_AT"
  write_output "token-expires-in" "$TOKEN_EXPIRES_IN"
fi

if [ -n "$EXISTING_TEAM_ID" ]; then
  write_output "team-id" "$EXISTING_TEAM_ID"
  echo "Using provided postman-team-id."
else
  ME_URL="$API_HOST/me"
  ME_RESPONSE_FILE="$(mktemp)"
  if [ -n "$POSTMAN_API_KEY" ]; then
    if ! ME_CODE="$(call_curl "$ME_RESPONSE_FILE" "$ME_URL" \
      -H "Authorization: Bearer $TOKEN" \
      -H "x-api-key: $POSTMAN_API_KEY")"; then
      rm -f "$ME_RESPONSE_FILE"
      log_error "Network error calling /me"
      exit 1
    fi
  else
    if ! ME_CODE="$(call_curl "$ME_RESPONSE_FILE" "$ME_URL" \
      -H "Authorization: Bearer $TOKEN")"; then
      rm -f "$ME_RESPONSE_FILE"
      log_error "Network error calling /me"
      exit 1
    fi
  fi
  ME_BODY="$(cat "$ME_RESPONSE_FILE")"
  rm -f "$ME_RESPONSE_FILE"

  if [ "$ME_CODE" -lt 200 ] || [ "$ME_CODE" -ge 300 ]; then
    if [ -z "$POSTMAN_API_KEY" ]; then
      log_error "/me failed (HTTP $ME_CODE) while resolving team ID from postman-access-token. Provide postman-team-id to skip Bearer-only lookup, or provide postman-api-key for Team ID lookup."
    else
      log_error "/me failed (HTTP $ME_CODE) while resolving team ID."
    fi
    summarize_me_response "$ME_BODY"
    exit 1
  fi

  if ! TEAM_SELECTION="$(printf '%s' "$ME_BODY" | jq -r '
    def team_value:
      if type == "string" then
        .
      elif type == "number" then
        tostring
      elif type == "object" then
        (.teamId? // .team_id? // .id? // empty | tostring)
      else
        empty
      end;

    def clean_ids:
      map(team_value)
      | map(select(. != "" and . != "null"))
      | unique;

    def singleton_ids:
      [
        .user.teamId?,
        .user.team.id?,
        .teamId?,
        .team.id?,
        .identity.teamId?,
        .identity.team.id?,
        .session.identity.teamId?,
        .session.identity.team.id?,
        .user.team?,
        .team?,
        .identity.team?,
        .session.identity.team?
      ] | clean_ids;

    def membership_ids:
      [
        .teams[]?,
        .user.teams[]?,
        .memberships[]?.teamId?,
        .memberships[]?.team_id?,
        .memberships[]?.team?,
        .user.memberships[]?.teamId?,
        .user.memberships[]?.team_id?,
        .user.memberships[]?.team?,
        .organizations[]?.teamId?,
        .organizations[]?.team_id?,
        .organizations[]?.team?
      ] | clean_ids;

    (singleton_ids) as $singleton |
    (membership_ids) as $memberships |
    (
      if ($singleton | length) > 0 then
        {team_id: $singleton[0], ambiguous: false}
      elif ($memberships | length) == 1 then
        {team_id: $memberships[0], ambiguous: false}
      elif ($memberships | length) > 1 then
        {team_id: "", ambiguous: true}
      else
        {team_id: "", ambiguous: false}
      end
    )
    | "\(.team_id)|\(.ambiguous)"
  ' 2>/dev/null)"; then
    log_error "/me succeeded but response was not valid JSON"
    summarize_me_response "$ME_BODY"
    exit 1
  fi
  TEAM_ID="${TEAM_SELECTION%%|*}"
  TEAM_ID_AMBIGUOUS="${TEAM_SELECTION##*|}"
  if [ "$TEAM_ID_AMBIGUOUS" = "true" ]; then
    log_error "Multiple team IDs were present in /me response. Provide postman-team-id to disambiguate Team ID."
    summarize_me_response "$ME_BODY"
    exit 1
  fi
  if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "null" ]; then
    log_error "Could not read team id from /me response. Provide postman-team-id to skip Team ID lookup."
    summarize_me_response "$ME_BODY"
    exit 1
  fi
  write_output "team-id" "$TEAM_ID"
fi
