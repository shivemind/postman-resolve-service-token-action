# Performance Testing

Use this playbook to compare the existing PMAK plus manually managed access-token workflow against the service-account token resolution flow.

## What To Measure

Measure workflow runtime first. Browser DevTools can help inspect the GitHub Actions UI, but it does not measure the action runtime itself. The useful measurements are:

- total workflow duration;
- job duration;
- auth-resolution step duration;
- downstream action durations;
- failure/retry rate for token minting and `/me`;
- whether secret-refresh mode adds meaningful time.

## Baseline: Old Workflow

Use recent successful runs from the existing Jade Global workflow as the baseline.

```bash
gh run list \
  --repo shivemind/jadeGlobal \
  --workflow postman-api-catalog.yml \
  --limit 20 \
  --json databaseId,conclusion,event,headBranch,createdAt,startedAt,updatedAt,url
```

For a step-level table:

```bash
scripts/compare-workflow-performance.sh \
  --repo shivemind/jadeGlobal \
  --runs OLD_RUN_ID
```

Known useful old-flow baselines:

| Run | Workflow | Result | Notes |
| --- | --- | --- | --- |
| `26494706385` | `postman-api-catalog.yml` | success | Full six-service dispatch on May 27, 2026. |
| `24069719084` | `postman-api-catalog.yml` | success | Full six-service dispatch on Apr 7, 2026. |
| `24066971326` | `insights-onboarding.yml` | success | Insights-only dispatch on Apr 7, 2026. |

## New Workflow Comparison

For a full pipeline comparison, run the same workflow with only auth changed:

```yaml
- id: postman_auth
  uses: postman-cs/postman-resolve-service-token-action@v0
  with:
    postman-api-key: ${{ secrets.POSTMAN_API_KEY }}

- uses: postman-cs/postman-bootstrap-action@v0
  with:
    postman-api-key: ${{ secrets.POSTMAN_API_KEY }}
    postman-access-token: ${{ steps.postman_auth.outputs.access-token }}
```

For workflows that need Team ID:

```yaml
postman-team-id: ${{ steps.postman_auth.outputs.team-id }}
```

Then compare:

```bash
scripts/compare-workflow-performance.sh \
  --repo shivemind/jadeGlobal \
  --runs OLD_RUN_ID,NEW_RUN_ID
```

## Isolated Auth Benchmark

Add an isolated benchmark job before changing the full customer workflow:

```yaml
jobs:
  auth-benchmark:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Old auth shape
        env:
          POSTMAN_API_KEY: ${{ secrets.POSTMAN_API_KEY }}
          POSTMAN_ACCESS_TOKEN: ${{ secrets.POSTMAN_ACCESS_TOKEN }}
        run: |
          set -euo pipefail
          curl -sS -o /dev/null -w "old_me_http=%{http_code} total=%{time_total}\n" \
            "https://api.getpostman.com/me" \
            -H "x-api-key: ${POSTMAN_API_KEY}"
          if [ -n "${POSTMAN_ACCESS_TOKEN:-}" ]; then
            curl -sS -o /dev/null -w "old_bearer_me_http=%{http_code} total=%{time_total}\n" \
              "https://api.getpostman.com/me" \
              -H "Authorization: Bearer ${POSTMAN_ACCESS_TOKEN}"
          fi

      - id: postman_auth
        uses: postman-cs/postman-resolve-service-token-action@v0
        with:
          postman-api-key: ${{ secrets.POSTMAN_API_KEY }}

      - name: New auth output check
        run: |
          test -n "${{ steps.postman_auth.outputs.access-token }}"
          test -n "${{ steps.postman_auth.outputs.team-id }}"
```

This isolates the cost of minting and Team ID resolution from the much larger downstream onboarding work.

## DevTools Performance Tab

Use DevTools when the question is about the GitHub Actions page or log UI, not backend workflow execution:

1. Open the old run URL in Chrome.
2. Open DevTools, then the Performance tab.
3. Start recording.
4. Reload the run page and expand the slowest job logs.
5. Stop recording and save the trace.
6. Repeat the same steps for the new run URL.

Compare:

- page load time;
- log expansion responsiveness;
- network waterfall for log chunks;
- long main-thread tasks.

For workflow performance, prefer GitHub Actions run and step durations from the API. DevTools cannot see runner-side shell execution time beyond what GitHub renders back into the UI.

## Early Baseline Observations

On the current Jade Global old-flow runs, the expensive part is not auth. The six-service `postman-api-catalog.yml` workflow is dominated by downstream bootstrap/repo-sync/Insights work, especially Insights onboarding and polling. Adding token resolution should be a small fixed overhead unless the service-account token endpoint or `/me` call is slow or flaky.

Track auth separately so a healthy migration is not hidden inside normal downstream runtime variance.
