# Security War Games

This playbook covers controlled service-account auth testing for CSE-managed customer-facing automations.

## Scope

Allowed:

- Validate service-account token exchange in GitHub Actions.
- Validate access-token passthrough behavior.
- Validate Team ID resolution through `/me`.
- Validate invalid-key, expired-token, and missing-input failures.
- Validate secret masking and absence of token payloads in normal logs.
- Validate downstream CSE action compatibility using a non-production test repo.

Out of scope:

- Credential theft or attempts to recover secret values.
- Testing outside repos, teams, or accounts explicitly approved for the exercise.
- Rate-limit abuse, brute force, fuzzing production auth endpoints, or destructive mutation.
- Secret overwrites unless a test explicitly opts into secret-refresh mode with a scoped token.

## Test Harness

The Jade Global test branch contains a workflow-dispatch/push harness:

- Repo: `shivemind/jadeGlobal`
- Branch: `dan/service-account-auth-wargames`
- Workflow: `.github/workflows/service-account-auth-wargame.yml`
- Action under test: `shivemind/postman-resolve-service-token-action@dan/validate-cse-pipeline-integration`

The harness runs:

- old API-key `/me`;
- current `POSTMAN_ACCESS_TOKEN` passthrough;
- service-account PMAK to access-token exchange;
- Bearer-only `/me`;
- provided-token passthrough;
- invalid API-key negative test;
- missing-input negative test;
- optional downstream bootstrap smoke.

## Current Findings

Initial Jade Global auth-only runs:

| Run | Result | Finding |
| --- | --- | --- |
| `26605685160` | failure | Existing `POSTMAN_API_KEY` returned `401` for old API-key `/me`; harness was updated to continue after baseline failure. |
| `26605714995` | failure | Service-account token exchange returned `401`; invalid-key and missing-input negative tests behaved as expected. |
| `26605752107` | failure | Existing `POSTMAN_ACCESS_TOKEN` also failed `/me` with `401`; service-account exchange still returned `401`. |
| `26605880602` | mixed | Fresh non-service PMAK succeeded for old API-key `/me` and failed `/service-account-tokens` as expected. Fresh supplied access token failed Bearer `/me` with `401`. |
| `26605968824` | success | Controlled scale run completed: 8 service-account resolver attempts, 8 non-service PMAK baseline attempts, and 4 fresh-token passthrough attempts. |
| `26606131433` | mixed | Backward compatibility existing PMAK test passed; secret-refresh canary passed; Bearer-only Team ID fallback failed because supplied Bearer token returned `/me` HTTP `401`. |
| `26606256142` | mixed | Winter Trinity service-account PMAK minted a token and resolved numeric Team ID after parser fix. Secret refresh passed. Bearer-only replay of the minted token still failed `/me` with HTTP `401`. |
| `26606300164` | mixed | Direct probes confirmed the minted service-account token returned HTTP `401` for `/me` with both `Authorization: Bearer` and `x-access-token`. Backward compatibility and secret refresh still passed. |
| `26606482912` | mixed | Added hybrid lookup canary. Minted service-account token plus non-service PMAK resolved Team ID successfully while skipping the second mint. Bearer-only replay still failed with HTTP `401`. |

Interpretation: the non-service PMAK negative control confirms the token endpoint rejects normal PMAKs. The Winter Trinity service-account PMAK validates successful token minting and same-step Team ID resolution. Fresh supplied tokens and minted service-account tokens did not work as Bearer-only credentials for `/me`, but a PMAK supplied alongside `postman-access-token` did resolve Team ID successfully. Customers can therefore use one of three working paths: same-step service-account mint, explicit `postman-team-id`, or provided token plus PMAK Team ID lookup.

## Controlled Scale Findings

The first scale run used capped GitHub Actions matrix parallelism rather than a load test:

- Run: `26605968824`
- Matrix size: 20 jobs total
- Max parallelism per matrix: 2
- Service-account resolver attempts: 8
- Non-service PMAK baseline attempts: 8
- Fresh access-token passthrough attempts: 4

Results:

| Path | Count | Result |
| --- | ---: | --- |
| Non-service PMAK `/me` baseline | 8 | 8/8 returned HTTP `200`; min `0.288s`, max `0.576s`, avg `0.413s`. |
| Non-service PMAK service-token exchange | 8 | 8/8 failed as expected. |
| Current service-account resolver path | 8 | 8/8 failed because `POSTMAN_API_KEY` is not a valid service-account PMAK. |
| Fresh access-token passthrough | 4 | 4/4 failed Team ID resolution because Bearer `/me` returned `401`. |

This confirms normal PMAK behavior is stable under modest concurrency and the action handles repeated auth failures without leaking secrets or causing workflow instability. It does not yet validate successful service-account token minting at scale; that remains blocked on a valid service-account PMAK.

## Compatibility And Secret Refresh Findings

Run `26606131433` added three explicit canaries:

| Test | Result | Notes |
| --- | --- | --- |
| Backward compatibility: existing PMAK | Pass | Non-service PMAK succeeded against direct `/me` API-key auth in `0.426s`. The resolver rejected the same non-service PMAK at `/service-account-tokens` with HTTP `401`, as expected. |
| Bearer-only Team ID fallback | Fail | The action skipped minting and attempted `/me` with only `Authorization: Bearer <token>`, but `/me` returned HTTP `401`; no Team ID was resolved. |
| Secret refresh behavior | Pass | The action wrote canary repo secrets `POSTMAN_WARGAME_REFRESH_TOKEN` and `POSTMAN_WARGAME_REFRESH_TEAM_ID`, verified they existed, then cleaned them up. |

Backward compatibility conclusion: existing customers that continue passing PMAKs directly to downstream CSE automations remain unaffected. The resolver should not be inserted in front of a normal PMAK-only customer flow unless the customer provides a service-account PMAK.

Secret refresh conclusion: the GitHub secret write path works with a token that has repo secret write permission. The canary used explicit `postman-team-id` so the test covered GitHub secret refresh behavior without depending on Bearer `/me` success.

## Winter Trinity Service-Account Findings

The Winter Trinity service-account PMAK changed the result from "invalid key" to "mint succeeds." Production returned `user.teamId` as a number from `/me`, which required the action to normalize numeric Team IDs to strings before writing outputs.

Validated:

- service-account PMAK to access-token exchange succeeds;
- generated token is masked;
- numeric Team ID is parsed and exposed as `team-id`;
- repo secret refresh canary writes, verifies, and cleans up the configured secret names;
- provided access token plus non-service PMAK resolves Team ID while skipping token mint;
- non-service PMAK old flow remains valid.

Not validated as passing:

- Bearer-only Team ID fallback. The minted token failed `/me` when replayed without an API key. Direct probes with `Authorization: Bearer` and `x-access-token` both returned HTTP `401`.

## Token Safety Findings

The mocked unit harness now treats token safety as a required behavior:

- API keys, provided access tokens, and generated access tokens must be emitted through `::add-mask::`;
- generated/provided tokens are masked before any simulated stdout output line contains the token value;
- token endpoint error bodies redact auth-like keys such as `apiKey`, `access_token`, `secret`, `authorization`, and nested `auth` values;
- known input/output secret values are redacted even when an API error echoes them inside ordinary message text;
- PMAK-shaped, Bearer-shaped, and JWT-shaped strings are scrubbed from logged error strings;
- `/me` success bodies that do not contain a Team ID are omitted because they may include account metadata;
- `gh secret set` tests verify the token/team values are passed via stdin and not written to the mock command log.

## Token Lifecycle Coverage

The mocked suite validates token lifecycle behavior without live Postman calls:

- service-account token responses can expose expiry metadata through `token-expires-at` and `token-expires-in`;
- provided access-token flows skip minting and leave expiry outputs empty;
- repeated service-account resolution mints a fresh token each run instead of reusing a prior output;
- expired provided tokens fail during Team ID lookup with a clear `/me` error and do not trigger a replacement mint;
- disabled or deleted service-account keys fail at token mint with the Postman HTTP status and redacted response details;
- secret refresh continues to write the configured repo secret names with the resolved token and Team ID while keeping token values masked.

## Customer Failure-Mode Coverage

The mocked unit suite now covers the failure modes customers are most likely to hit during setup and migration:

| Failure | Expected behavior |
| --- | --- |
| Missing `postman-api-key` and missing `postman-access-token` | Fails before network calls with a required-input message. |
| Invalid `postman-stack` | Fails before network calls and lists supported stack values. |
| Normal/customer PMAK sent to service-token endpoint | Fails with the Postman HTTP status and redacted response. |
| Disabled service account or service-account key | Fails at token mint with Postman HTTP status and redacted response. |
| Deleted or revoked service account API key | Fails at token mint with Postman HTTP status and redacted response. |
| Token endpoint returns success without a token | Fails with `Mint succeeded but no access token in response`. |
| Token endpoint returns malformed JSON | Fails with `Mint succeeded but token response was not valid JSON`. |
| Service account lacks role/scope to mint tokens | Fails with Postman HTTP `403` and redacted response details. |
| Provided `postman-team-id` | Skips `/me` lookup and returns the provided Team ID. |
| Bearer-only `/me` rejects provided token | Fails with guidance to provide `postman-team-id` or `postman-api-key`. |
| `/me` rejects service-account Team ID lookup | Fails with the HTTP status and redacted error summary. |
| Service account lacks workspace assignment/role | Fails with the Postman HTTP status and redacted role error summary. |
| `/me` network timeout/error | Fails with `Network error calling /me`. |
| `/me` returns malformed JSON | Fails with `/me succeeded but response was not valid JSON`. |
| `/me` returns JSON without Team ID | Fails with guidance to provide `postman-team-id` and omits account metadata. |
| Secret refresh missing GitHub token | Fails before `gh secret set`. |
| Secret refresh missing repo context | Fails before `gh secret set`. |
| Secret refresh missing resolved token or Team ID | Fails before `gh secret set`. |
| Runner without `gh` CLI | Fails with a clear runner setup message. |
| GitHub token lacks repo secret write permission | Fails with a clear `Failed to write GitHub secret ...` message. |

## GitHub Actions Template Integration Coverage

`tests/test-github-actions-template-integration.sh` validates the customer-facing workflow shape without calling live Postman APIs:

- the example workflow includes a `postman_auth` resolver step;
- downstream CSE automation receives `steps.postman_auth.outputs.access-token`;
- downstream CSE automation receives `steps.postman_auth.outputs.team-id`;
- service-account PMAK resolution feeds the downstream action as access-token auth;
- provided access-token plus Team ID skips minting and still feeds downstream;
- legacy PMAK-only downstream auth still works without invoking the resolver.
- downstream workspace-role checks surface a clear error when a service account is unassigned or lacks the required role;
- downstream workspace-role checks pass when the service account has the required role.

## Permission And Role Notes

The resolver can validate auth resolution and report Postman/GitHub permission failures, but downstream CSE automations still need their own workspace/resource permission checks. For customer setup, the service account should have:

- permission to mint short-lived tokens for the team;
- access to the target Postman team;
- the required role on each target workspace/API resource used by the downstream automation;
- a separate GitHub PAT or App token with repo Actions secret write permission if `write-github-secret` is enabled.

## Full Pipeline War Game

After downstream templates are ready to accept the resolved access token:

1. Re-run `service-account-auth-wargame` in `auth-only` mode.
2. Confirm:
   - old API-key `/me` behavior is recorded;
   - service-account token exchange succeeds;
   - Team ID is resolved in the same action step;
   - Bearer-only `/me` behavior is recorded, with `postman-team-id` as the documented fallback if it continues to return `401`;
   - invalid-key and missing-input negative tests fail cleanly.
3. Run `downstream-smoke` mode against one `target_service`.
4. Compare timing against old Jade Global baselines using:

```bash
scripts/compare-workflow-performance.sh \
  --repo shivemind/jadeGlobal \
  --runs OLD_RUN_ID,NEW_RUN_ID
```

5. Only after the smoke is clean, adapt `postman-api-catalog.yml` to call the resolver before downstream CSE actions.

## Red-Team Test Matrix

| Vector | Expected Result |
| --- | --- |
| Missing `postman-api-key` and missing `postman-access-token` | Action fails before network calls. |
| Invalid, inactive, disabled, revoked, or deleted PMAK | Action fails with HTTP status and redacted response. |
| Personal PMAK sent to service-account token endpoint | Action fails clearly; no token output. |
| Expired access token provided | Action skips mint, then Team ID `/me` fails clearly. |
| Bearer-only Team ID fallback | If supported by the token type, `/me` succeeds without `x-api-key` and returns `team-id`; otherwise the action fails clearly and caller supplies `postman-team-id`. |
| Token endpoint network failure | Action fails with network error, no token output. |
| `/me` response without Team ID | Action fails with unable-to-resolve-Team-ID error. |
| Error response contains token-like fields | Logs redact auth-like keys. |
| Generated token output | Token is masked with `::add-mask::`. |
| Secret-refresh mode without GitHub token | Action fails before attempting writes. |
| Secret-refresh mode with scoped token | Writes only configured secret names. |
| Downstream action compatibility | Existing PMAK input still works; access-token input is additive. |

## Service Account Improvements Suggested By Testing

- Expose a clear service-account key validation endpoint or error code.
- Document whether service-account PMAKs should work with `/me` via `x-api-key`.
- Document access-token TTL and recommended refresh cadence.
- Return Team ID in the token-exchange response when safe, reducing one network call.
- Allow `/me` or a dedicated identity endpoint to accept short-lived service-account tokens without needing the original API key.
- Provide stable error codes for inactive key, wrong key type, expired token, and missing permissions.
- Provide an official CI/CD service-account setup guide with GitHub Actions and ADO examples.
