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

write_output() {
  local name="$1"
  local value="$2"
  printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
}

log_error() {
  echo "::error::$*"
}

sanitize_response() {
  local body="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$body" | jq '
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
        else
          .
        end;
      redact
    ' 2>/dev/null || printf '%s\n' '[unparseable response omitted]'
  else
    printf '%s\n' '[response omitted: jq is required to safely redact error responses]'
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

mask_if_set "$POSTMAN_API_KEY"
mask_if_set "$EXISTING_TOKEN"

if [ -n "$EXISTING_TOKEN" ]; then
  write_output "skipped" "true"
  write_output "auth-method" "provided-access-token"
  write_output "token" "$EXISTING_TOKEN"
  write_output "access-token" "$EXISTING_TOKEN"
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

  TOKEN="$(printf '%s' "$RESPONSE" | jq -r '.access_token // .accessToken // .token // .session.token // empty')"
  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    log_error "Mint succeeded but no access token in response"
    sanitize_response "$RESPONSE"
    exit 1
  fi
  mask_if_set "$TOKEN"
  write_output "token" "$TOKEN"
  write_output "access-token" "$TOKEN"
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
    log_error "/me failed (HTTP $ME_CODE)"
    sanitize_response "$ME_BODY"
    exit 1
  fi

  TEAM_ID="$(printf '%s' "$ME_BODY" | jq -r '
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
    ]
    | map(select(type == "string" and length > 0))
    | .[0] // empty
  ')"
  if [ -z "$TEAM_ID" ] || [ "$TEAM_ID" = "null" ]; then
    log_error "Could not read team id from /me response"
    sanitize_response "$ME_BODY"
    exit 1
  fi
  write_output "team-id" "$TEAM_ID"
fi
