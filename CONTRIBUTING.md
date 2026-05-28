# Contributing to postman-resolve-service-token-action

Thank you for your interest in contributing. This guide covers the workflow and standards for submitting changes.

## Getting Started

1. Fork and clone the repository.
2. Create a feature branch: `git checkout -b my-change`.

This repository is a pure composite GitHub Action - no Node.js, TypeScript, or build step. Runtime logic lives in `scripts/`, tests live in `tests/`, and metadata lives in `action.yml`.

## Local Validation

Before opening a PR, lint the action with [`actionlint`](https://github.com/rhysd/actionlint):

```bash
tests/test-resolve-service-token.sh
go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.11
$(go env GOPATH)/bin/actionlint
```

`actionlint` runs the embedded shell scripts through `shellcheck` automatically when `shellcheck` is on `PATH`.

## Before Submitting a PR

- [ ] `tests/test-resolve-service-token.sh` passes locally.
- [ ] `actionlint` passes locally.
- [ ] Changes are focused and address a single concern.
- [ ] README inputs/outputs tables match `action.yml`.
- [ ] Behavior changes are reflected in `README.md`.

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). All commits must follow this format:

```
<type>: <description>

[optional body]

[optional footer(s)]
```

**Types:** `feat`, `fix`, `docs`, `chore`, `ci`, `refactor`, `test`, `perf`, `revert`

**Examples:**

```
feat: add postman-team-id passthrough input
fix: handle 429 from /service-account-tokens
docs: clarify github-token PAT requirement
ci: pin actionlint to v1.7.11
```

## Reporting Issues

Use the GitHub issue tracker for bug reports and feature requests. For questions, open a Discussion thread.

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
