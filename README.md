# PR deploy gate

A composite GitHub Action that gates a `/deploy` comment on a pull request:

- the commenter has write access to the repo;
- the PR is open;
- the PR's head branch is in the same repo. Fork PRs, and PRs whose fork was deleted, are refused.

A refused command gets a comment saying why and fails the job, so jobs that `need` it are skipped. An accepted command gets a 🚀 reaction.

It only calls the GitHub API, so a caller does not need `actions/checkout`.

## Usage

```yaml
on:
  issue_comment:
    types: [created]

jobs:
  validate:
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
        uses: SSWConsulting/pr-deploy-gate@v1.0.0
        with:
          token: ${{ github.token }}
          repository: ${{ github.repository }}
          pr_number: ${{ github.event.issue.number }}
          commenter: ${{ github.event.comment.user.login }}
          comment_id: ${{ github.event.comment.id }}

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    steps:
      - run: echo "Deploying ${{ needs.validate.outputs.head_sha }}"
```

## Inputs

| Input | Required | Description |
| --- | --- | --- |
| `token` | yes | Token for `gh`, usually `github.token`. Needs `issues` and `pull-requests` write. |
| `repository` | yes | `github.repository` |
| `pr_number` | yes | `github.event.issue.number` |
| `commenter` | yes | `github.event.comment.user.login` |
| `comment_id` | yes | `github.event.comment.id` |
| `refuse_message` | no | Comment posted on a refusal. `{reason}` and `{commenter}` are replaced. |

## Outputs

| Output | Description |
| --- | --- |
| `head_ref` | The PR's head branch |
| `head_sha` | The PR's head commit SHA |
| `head_repository` | The head repo's full name. Empty if the fork was deleted. |

## Versioning

Callers pin to a release tag (`@v1.0.0`) or to a full commit SHA. Do not use `@main`: the action runs with each caller's token, so any change on `main` reaches every caller on its next run.

Releases are tags of the form `vX.Y.Z`. Patch and minor releases only add behaviour that existing callers can ignore; a breaking change to inputs or outputs gets a new major version.
