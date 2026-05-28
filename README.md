# postman-resolve-service-token-action

Composite GitHub Action for resolving Postman auth for CSE-managed automations.

The action accepts either:

- a Postman service-account API key, then exchanges it for a short-lived access token; or
- an existing Postman access token, then passes it through without minting a new token.

It also resolves the Postman team ID and can optionally refresh repo secrets for downstream workflows.

## When To Use

- Keep existing PMAK/API-key workflows running unchanged while templates add optional access-token support.
- Mint a short-lived access token inline before a downstream CSE automation step.
- Refresh repo secrets such as `POSTMAN_ACCESS_TOKEN` and `POSTMAN_TEAM_ID` on a schedule.
- Validate the GitHub Actions path before porting the same pattern into Azure DevOps templates.

## Customer Usage

### Existing API-Key Flow

Existing customers that already pass a Postman API key directly to a CSE automation do not need to change anything.

```yaml
- uses: postman-cs/postman-api-onboarding-action@v0
  with:
    project-name: my-service
    spec-path: openapi.yaml
    postman-api-key: ${{ secrets.POSTMAN_API_KEY }}
```

For template migrations, keep this path available. Add access-token inputs to downstream templates as optional enhancements rather than replacing the PMAK input outright.

### Service-Account API-Key Flow

Use a service-account API key as `POSTMAN_API_KEY`. The action exchanges it for a short-lived access token, masks the generated token, resolves the team ID, and exposes both as outputs.

```yaml
jobs:
  onboarding:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - id: postman_auth
        uses: postman-cs/postman-resolve-service-token-action@v0
        with:
          postman-api-key: ${{ secrets.POSTMAN_API_KEY }}

      - uses: postman-cs/postman-api-onboarding-action@v0
        with:
          project-name: my-service
          spec-path: openapi.yaml
          postman-api-key: ${{ secrets.POSTMAN_API_KEY }}
          postman-access-token: ${{ steps.postman_auth.outputs.access-token }}
          postman-team-id: ${{ steps.postman_auth.outputs.team-id }}
```

### Access-Token-Provided Flow

If a workflow already manages `POSTMAN_ACCESS_TOKEN`, pass it in. The mint step is skipped and the supplied token is returned as the action output.

```yaml
- id: postman_auth
  uses: postman-cs/postman-resolve-service-token-action@v0
  with:
    postman-access-token: ${{ secrets.POSTMAN_ACCESS_TOKEN }}
    postman-team-id: ${{ secrets.POSTMAN_TEAM_ID }}
```

If `postman-team-id` is omitted, the action calls `/me` with only `Authorization: Bearer <token>` and attempts to resolve the team ID from the response.

Production validation on May 28, 2026 found that short-lived tokens minted from service-account PMAKs did not authorize `/me` when replayed later as Bearer-only tokens. For that token type, pass `postman-team-id` when using `postman-access-token` directly, or pass the service-account PMAK to this action so it can mint the token and resolve Team ID in the same step.

You can also pass a PMAK alongside `postman-access-token` purely for Team ID lookup. The action still skips token minting when `postman-access-token` is set.

```yaml
- id: postman_auth
  uses: postman-cs/postman-resolve-service-token-action@v0
  with:
    postman-access-token: ${{ secrets.POSTMAN_ACCESS_TOKEN }}
    postman-api-key: ${{ secrets.POSTMAN_API_KEY }}
```

### GitHub Actions Template Integration

A minimal downstream template integration is available at [`examples/github-actions-template-integration.yml`](examples/github-actions-template-integration.yml).

The least disruptive migration path is:

1. Keep `POSTMAN_API_KEY` as an accepted downstream input.
2. Add optional `POSTMAN_ACCESS_TOKEN` and `POSTMAN_TEAM_ID` support.
3. Prefer the access token when present.
4. Fall back to the existing API-key behavior when the access token is absent.

### Scheduled Secret Refresh

Use this when downstream CSE automations expect repo secrets such as `POSTMAN_ACCESS_TOKEN`.

```yaml
name: Refresh Postman service-account token

on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:

concurrency:
  group: postman-service-token-refresh
  cancel-in-progress: false

jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - uses: postman-cs/postman-resolve-service-token-action@v0
        with:
          postman-api-key: ${{ secrets.POSTMAN_API_KEY }}
          write-github-secret: 'true'
          github-token: ${{ secrets.SECRETS_WRITE_PAT }}
```

`github-token` must be a PAT or GitHub App installation token with repo secret write permission. The default workflow `GITHUB_TOKEN` cannot write repo secrets.

Use action outputs for downstream steps in the same workflow run. Refreshed repo secrets are intended for later workflow runs after the refresh completes. Use a workflow `concurrency` group so overlapping scheduled or manual refresh runs do not race to update the same secret names. Schedule refresh with a buffer shorter than the token TTL reported by `token-expires-in` / `token-expires-at`.

### Fork And PR Safety

Do not run this action with Postman or secret-write credentials on untrusted fork pull requests. Use `workflow_dispatch`, `schedule`, or trusted-branch `push` for customer-facing automations that read `secrets.POSTMAN_API_KEY`, `secrets.POSTMAN_ACCESS_TOKEN`, or `secrets.SECRETS_WRITE_PAT`.

Avoid `pull_request_target` for workflows that check out and execute PR code. If a validation workflow must run on `pull_request`, keep it secret-free and read-only, like this repository's CI. Fork PRs should exercise mocked tests only; the resolver will fail before network calls when required secret inputs are absent.

### Azure DevOps Adaptation Notes

This repository is a GitHub composite action, so Azure DevOps should not consume it directly. After the GitHub path is validated, port the same shell behavior into an ADO template step:

- Store the service-account API key in a secure pipeline variable.
- Call the production `/service-account-tokens` endpoint to mint the access token.
- Call `/me` with the minted Bearer token plus the service-account API key to resolve the team ID when needed, or require the caller to provide `POSTMAN_TEAM_ID`.
- Mark generated tokens with ADO secret masking, for example `##vso[task.setsecret]`.
- Set output variables for downstream tasks, for example `POSTMAN_ACCESS_TOKEN` and `POSTMAN_TEAM_ID`.
- Preserve the current PMAK/API-key-only path as a fallback for existing customers.

## Inputs

| Input | Default | Notes |
| --- | --- | --- |
| `postman-api-key` | | Postman API key (PMAK). Use a service-account API key to mint a short-lived access token. Required when `postman-access-token` is not provided. |
| `postman-access-token` | | Optional pre-existing access token. When set, the mint step is skipped and the value is returned via `token` and `access-token`. |
| `postman-team-id` | | Optional pre-known team ID. When set, the `/me` lookup is skipped. |
| `postman-stack` | `prod` | One of `prod` (`api.getpostman.com`) or `beta` (`api.getpostman-beta.com`). |
| `write-github-secret` | `'false'` | When `'true'`, writes the resolved token and team ID to repo secrets. |
| `access-token-secret-name` | `POSTMAN_ACCESS_TOKEN` | Secret name to receive the access token. Used only when `write-github-secret` is `'true'`. |
| `team-id-secret-name` | `POSTMAN_TEAM_ID` | Secret name to receive the team ID. Used only when `write-github-secret` is `'true'`. |
| `github-token` | | PAT or GitHub App installation token with secrets write permission on the target repo. Required when `write-github-secret` is `'true'`. |

## Outputs

| Output | Description |
| --- | --- |
| `access-token` | Resolved Postman access token. Prefer this output in new workflows. |
| `token` | Same value as `access-token`; retained for existing callers. |
| `team-id` | Resolved Postman team ID. Either looked up via `/me` or passed through from `postman-team-id`. |
| `skipped` | `'true'` when the mint step was skipped because `postman-access-token` was provided. |
| `auth-method` | `provided-access-token` or `service-account-api-key`. |
| `token-expires-at` | Expiration timestamp returned by the service-account token endpoint when available. Empty for provided access tokens or endpoint responses without expiry metadata. |
| `token-expires-in` | Token lifetime in seconds returned by the service-account token endpoint when available. Empty for provided access tokens or endpoint responses without lifetime metadata. |

## Token And Team Resolution

When `postman-access-token` is provided:

- the action does not call `/service-account-tokens`;
- the provided token is masked;
- `skipped` is set to `true`;
- expiry outputs are empty because the action did not mint the token;
- `/me` is called only if `postman-team-id` was not provided;
- if Bearer-only `/me` returns `401`, provide `postman-team-id` explicitly. This is expected for short-lived service-account tokens in current production validation.

When only `postman-api-key` is provided:

- the action calls `POST /service-account-tokens` on the selected Postman stack;
- the API key is sent in both the `x-api-key` header and JSON body for compatibility with the existing endpoint behavior;
- the generated access token is masked and exposed as `token` and `access-token`;
- `token-expires-at` and `token-expires-in` are populated when the token endpoint returns expiry metadata;
- `/me` is called with the minted token and service-account API key to resolve the team ID.

## Secret Handling

- The action masks the Postman API key and any resolved access token.
- Generated tokens are written to `$GITHUB_OUTPUT`, not printed as normal log messages.
- Error responses are redacted before logging keys such as `token`, `access_token`, `apiKey`, `secret`, `authorization`, and similar auth fields.
- `write-github-secret: 'true'` writes the resolved values with `gh secret set` and logs only the secret names.

## Failure Modes

The action fails with explicit GitHub Actions errors when:

- `postman-api-key` is missing and `postman-access-token` is not provided;
- `postman-stack` is not `prod` or `beta`;
- `github-token` is missing while `write-github-secret` is `'true'`;
- the service-account token endpoint rejects the key, including invalid, inactive, disabled, revoked, or deleted keys;
- a network error prevents the token or `/me` call;
- the token endpoint succeeds but does not return an access token;
- `/me` succeeds but no team ID can be read from the response;
- `/me` returns multiple possible team IDs and no singular/current team field, in which case `postman-team-id` must be supplied;
- Bearer-only `/me` rejects a provided access token and no `postman-team-id` was supplied;
- Postman returns `403` because the service account lacks the required team/workspace role or permission;
- GitHub secret refresh fails because `github-token` cannot write repo Actions secrets;
- `gh` is unavailable when secret writing is enabled.

## Stack Selection

| `postman-stack` | API host |
| --- | --- |
| `prod` | `https://api.getpostman.com` |
| `beta` | `https://api.getpostman-beta.com` |

Production is the default. `beta` is useful for internal validation but may require a runner with access to the beta perimeter.

## Local Validation

```bash
tests/test-resolve-service-token.sh
tests/test-github-actions-template-integration.sh
$(go env GOPATH)/bin/actionlint
```

The test harnesses use mocked HTTP calls. `test-github-actions-template-integration.sh` verifies that the example template wires resolver outputs into a downstream CSE action, that provided-token flows skip minting, and that legacy PMAK-only downstream usage remains possible without invoking the resolver. Do not commit real Postman API keys, access tokens, customer data, or test secrets.

For old-flow versus service-account workflow timing, see [`docs/performance-testing.md`](docs/performance-testing.md). For controlled pipeline war games and red-team scenarios, see [`docs/security-war-games.md`](docs/security-war-games.md).

## Migration Lift

For GitHub Actions templates, the expected lift is low to moderate:

- Low when downstream automations already accept `postman-access-token` and `postman-team-id`.
- Moderate when downstream automations only accept `postman-api-key`; those templates need optional access-token inputs and auth selection logic.
- Higher only when a customer requires scheduled repo-secret refresh, because they must provide a GitHub PAT or App token that can write repo secrets.

## Benefits

- Short-lived access tokens reduce reliance on long-lived manually copied tokens.
- Service-account ownership is easier to reason about than user-owned session tokens.
- Scheduled refresh enables existing downstream workflows to keep reading stable secret names.
- The action gives CSE templates one consistent place to resolve token and team ID values.

## Risk Vectors

- Customers may provide a personal PMAK instead of a service-account PMAK; the mint endpoint should fail clearly.
- Secret-writing mode introduces a GitHub PAT or App-token management requirement.
- Bearer-only `/me` team ID resolution depends on Postman's token type support. Validated short-lived service-account tokens currently need either `postman-team-id` or same-step resolution with the service-account PMAK.
- Downstream templates must preserve PMAK fallback behavior until customer migrations are complete.
- Service accounts must be assigned to the target team/workspaces with the roles required by each downstream CSE automation; token resolution alone does not grant workspace access.
- Access-token TTL and refresh cadence need to be aligned with long-running or scheduled customer workflows.

## Open-Alpha Release Strategy

- Open-alpha channel tags use `v0.x.y`.
- Pin immutable tags such as `v0.1.0` for reproducibility.
- Moving tag `v0` is the rolling open-alpha channel.

## License

[MIT](LICENSE)
