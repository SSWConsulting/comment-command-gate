# Comment command gate

Stops "pwn requests" in GitHub Actions: a `/deploy` (or any `/command`) comment on a pull request from a fork running that PR's code with your repo's secrets.

## The problem

A workflow triggered by `issue_comment` runs in the base repository, with its secrets and a write-scoped token, even when the comment is on a PR from a fork. If the workflow then checks out or builds the PR's code, anyone who can open a PR can run code with your secrets. The only thing standing in the way is the command itself: a maintainer who types `/deploy` on a fork PR, or a fork that pushes new code after the command, makes the attack work. This is the "pwn request" pattern, and GitHub documents it:

- [Securely using pull_request_target](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target) (GitHub Docs)
- [Keeping your GitHub Actions and workflows secure: Preventing pwn requests](https://securitylab.github.com/research/github-actions-preventing-pwn-requests/) (GitHub Security Lab)
- [The Pwn Request Reckoning](https://www.wiz.io/blog/github-actions-security-pwn-request-reckoning) (Wiz, third-party)

## The mitigation

The gate is a job that runs before any build or deploy job. It checks, in order, that the comment starts with the command, that the commenter has at least the required repo role, and (for PR commands) that the PR is open and its head branch is in this repo. Any failure exits `1`, so jobs that `need` the gate never run, and the PR's code is never built with your secrets.

Pin the caller to a release tag or commit SHA, and build the PR's head SHA, not the mutable `refs/pull/N/merge`.

## What it does

A composite GitHub Action that decides whether a slash command typed in an issue or PR comment, such as `/deploy`, may run.

It checks, cheapest first, and stops at the first failure:

1. the comment starts with the command;
2. the commenter has at least `min_role` in the repo (default `write`);
3. optional, for PR-only commands: the PR is open, and its head branch is in this repo (refuses forks and deleted forks).

It exits `0` if the command may run and `1` if not. A refusal posts a comment saying why. An allowed command gets a reaction (`+1` by default).

It only calls the GitHub API, so a caller does not need `actions/checkout`.

## Usage

```yaml
on:
  issue_comment:
    types: [created]

jobs:
  gate:
    if: github.event.issue.pull_request && startsWith(github.event.comment.body, '/deploy')
    runs-on: ubuntu-latest
    permissions:
      issues: write
      pull-requests: write
    outputs:
      head_ref: ${{ steps.gate.outputs.head_ref }}
      head_sha: ${{ steps.gate.outputs.head_sha }}
    steps:
      - id: gate
        uses: SSWConsulting/comment-command-gate@v2.0.0
        with:
          token: ${{ github.token }}
          repository: ${{ github.repository }}
          issue_number: ${{ github.event.issue.number }}
          comment_id: ${{ github.event.comment.id }}
          comment_body: ${{ github.event.comment.body }}
          commenter: ${{ github.event.comment.user.login }}
          command: /deploy
          min_role: write
          require_same_repo_branch: "true"

  deploy:
    needs: gate
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying ${{ needs.gate.outputs.head_sha }}"
```

A command that only needs a role, and works on issues too, leaves out the PR options:

```yaml
- id: gate
  uses: SSWConsulting/comment-command-gate@v2.0.0
  with:
    token: ${{ github.token }}
    repository: ${{ github.repository }}
    issue_number: ${{ github.event.issue.number }}
    comment_id: ${{ github.event.comment.id }}
    comment_body: ${{ github.event.comment.body }}
    commenter: ${{ github.event.comment.user.login }}
    command: /label
    min_role: triage
```

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `token` | yes | | Token for `gh`, usually `github.token`. Needs `issues: write`, and `pull-requests: write` if the PR checks run. |
| `repository` | yes | | `github.repository` |
| `issue_number` | yes | | `github.event.issue.number` |
| `comment_id` | yes | | `github.event.comment.id` |
| `comment_body` | yes | | `github.event.comment.body` |
| `commenter` | yes | | `github.event.comment.user.login` |
| `command` | yes | | The text the comment must start with, e.g. `/deploy` |
| `min_role` | no | `write` | Lowest repo role allowed: `admin`, `maintain`, `write`, `triage` or `read` |
| `require_pull_request` | no | `false` | `"true"` to refuse unless the comment is on an open PR |
| `require_same_repo_branch` | no | `false` | `"true"` to refuse PRs whose head branch is not in this repo. Implies `require_pull_request`. |
| `deny_message` | no | see `action.yml` | Comment on a role refusal. `{commenter}`, `{command}`, `{role}` are replaced. |
| `refuse_message` | no | see `action.yml` | Comment on a PR refusal. `{commenter}`, `{command}`, `{reason}` are replaced. |
| `reaction` | no | `+1` | Reaction for an allowed command. Empty to skip. |

## Outputs

| Output | Description |
| --- | --- |
| `permission` | The commenter's role in the repo |
| `head_ref` | The PR's head branch. Empty unless the PR checks ran. |
| `head_sha` | The PR's head commit SHA. Empty unless the PR checks ran. |
| `head_repository` | The PR's head repo. Empty if the PR checks did not run or the fork was deleted. |

## Versioning

Callers pin to a release tag (`@v2.0.0`) or to a full commit SHA. Do not use `@main`: the action runs with each caller's token, so any change on `main` reaches every caller on its next run.

Releases are tags of the form `vX.Y.Z`. A change to inputs or outputs that breaks existing callers gets a new major version. `v1.0.0` was the first release and was specific to `/deploy`; `v2.0.0` replaced it with the generic action above.

## Development

The gate logic is in `gate.sh`. `action.yml` passes the inputs to it as environment variables.

The tests in `test/gate.bats` run `gate.sh` against a stub `gh` (`test/bin/gh`), so they make no network calls. Each test sets the API responses it needs. To run them, install [bats](https://github.com/bats-core/bats-core), `jq` and `shellcheck`, then run:

```sh
bats test/
shellcheck gate.sh test/bin/gh
shellcheck -s bash test/gate.bats
```

CI runs these checks and `actionlint` on every pull request. A smoke job also runs `action.yml` against the pull request, in read-only mode.
