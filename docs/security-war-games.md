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
| Invalid or inactive PMAK | Action fails with HTTP status and redacted response. |
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
