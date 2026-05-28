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

Interpretation: the Jade Global repo secrets currently do not contain a valid active service-account API key or valid access token. Full downstream smoke and full-pipeline war games are blocked until `POSTMAN_API_KEY` is rotated to an active service-account key.

## Full Pipeline War Game

After `POSTMAN_API_KEY` is updated to a valid active service-account key:

1. Re-run `service-account-auth-wargame` in `auth-only` mode.
2. Confirm:
   - old API-key `/me` behavior is recorded;
   - service-account token exchange succeeds;
   - Bearer-only `/me` succeeds;
   - Team ID is resolved;
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
| Invalid or inactive PMAK | Action fails with HTTP status and redacted response. |
| Personal PMAK sent to service-account token endpoint | Action fails clearly; no token output. |
| Expired access token provided | Action skips mint, then Team ID `/me` fails clearly. |
| Bearer-only Team ID fallback | `/me` succeeds without `x-api-key` and returns `team-id`. |
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
- Provide stable error codes for inactive key, wrong key type, expired token, and missing permissions.
- Provide an official CI/CD service-account setup guide with GitHub Actions and ADO examples.
