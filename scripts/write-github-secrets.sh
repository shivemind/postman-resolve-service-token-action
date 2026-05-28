#!/usr/bin/env bash
set -euo pipefail

GH_TOKEN="${GH_TOKEN:-}"
REPO="${REPO:-}"
TOKEN="${TOKEN:-}"
TEAM_ID="${TEAM_ID:-}"
ACCESS_TOKEN_SECRET_NAME="${ACCESS_TOKEN_SECRET_NAME:-POSTMAN_ACCESS_TOKEN}"
TEAM_ID_SECRET_NAME="${TEAM_ID_SECRET_NAME:-POSTMAN_TEAM_ID}"

if [ -n "$TOKEN" ]; then
  echo "::add-mask::$TOKEN"
fi

if [ -z "$GH_TOKEN" ]; then
  echo "::error::github-token is required when write-github-secret is 'true'."
  exit 1
fi

if [ -z "$REPO" ]; then
  echo "::error::github.repository is required to write repo secrets."
  exit 1
fi

if [ -z "$TOKEN" ] || [ -z "$TEAM_ID" ]; then
  echo "::error::Resolved token and team ID are required to write repo secrets."
  exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "::error::gh CLI not found on runner. Use a runner image that includes gh, or install it before invoking this action."
  exit 1
fi

write_secret() {
  local name="$1"
  local value="$2"
  if ! printf '%s' "$value" | gh secret set "$name" --repo "$REPO"; then
    echo "::error::Failed to write GitHub secret $name. Ensure github-token has repo Actions secrets write permission for $REPO."
    exit 1
  fi
}

write_secret "$ACCESS_TOKEN_SECRET_NAME" "$TOKEN"
write_secret "$TEAM_ID_SECRET_NAME" "$TEAM_ID"
echo "Wrote secrets: $ACCESS_TOKEN_SECRET_NAME, $TEAM_ID_SECRET_NAME"
