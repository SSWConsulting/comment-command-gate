#!/usr/bin/env bash
# Decides if a slash command in a comment may run. action.yml sets the inputs as env vars.
set -euo pipefail

# Role ranks, highest first. Unknown roles rank 0.
rank() {
  case "$1" in
    admin) echo 5 ;;
    maintain) echo 4 ;;
    write) echo 3 ;;
    triage) echo 2 ;;
    read) echo 1 ;;
    *) echo 0 ;;
  esac
}

# Fill the {placeholders} in a message. $1 is the template, $2 the reason.
fill() {
  local s=$1
  s=${s//'{commenter}'/$COMMENTER}
  s=${s//'{command}'/$COMMAND}
  s=${s//'{role}'/$MIN_ROLE}
  s=${s//'{reason}'/${2:-}}
  printf '%s' "$s"
}

# GET an API path and print the --jq result. Return 4 if GitHub answers
# 404. For any other error, log it and return 1.
api_get() {
  local out err rc=0
  err=$(mktemp)
  out=$(gh api "$1" --jq "$2" 2>"$err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  if grep -q 'HTTP 404' "$err"; then
    rm -f "$err"
    return 4
  fi
  echo "::error::GitHub API call to $1 failed: $(cat "$err")" >&2
  rm -f "$err"
  return 1
}

# Post a reply on the issue or PR. An empty message posts nothing. A failed
# post must not hide the reason for the refusal, so it only warns.
comment() {
  [ -n "$1" ] || return 0
  gh api "repos/$REPO/issues/$ISSUE_NUMBER/comments" -f body="$1" --silent \
    || echo "::warning::Could not post the refusal comment."
}

# Composite actions do not enforce required inputs, and an empty command
# matches every comment.
if [ -z "$COMMAND" ]; then
  echo "::error::command is required."
  exit 1
fi

# A value other than true or false must not turn a check off.
bool() {
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
    true) echo true ;;
    false) echo false ;;
    *)
      echo "::error::$1 must be true or false - got '$2'." >&2
      return 1
      ;;
  esac
}
REQUIRE_PR=$(bool require_pull_request "$REQUIRE_PR")
REQUIRE_SAME_REPO=$(bool require_same_repo_branch "$REQUIRE_SAME_REPO")

if [ "$(rank "$MIN_ROLE")" -eq 0 ]; then
  echo "::error::min_role must be one of admin, maintain, write, triage, read - got '$MIN_ROLE'."
  exit 1
fi

# 1. The comment must start with the command, followed by whitespace or
# the end of the comment, so /deploy does not match /deploy-prod.
# No API call needed.
if [[ "$COMMENT_BODY" != "$COMMAND" && "$COMMENT_BODY" != "$COMMAND"[[:space:]]* ]]; then
  echo "::error::The comment does not start with the command $COMMAND."
  exit 1
fi

# 2. The commenter must have at least the required role.
# Read the role from user.permissions. The top-level "permission" field
# reports maintain as write and triage as read. A custom role sets the
# flags of its base role.
role_filter='.user.permissions // {} |
  if .admin then "admin" elif .maintain then "maintain" elif .push then "write"
  elif .triage then "triage" elif .pull then "read" else "none" end'
rc=0
permission=$(api_get "repos/$REPO/collaborators/$COMMENTER/permission" "$role_filter") || rc=$?
case "$rc" in
  0) ;;
  4) permission=none ;;
  *) exit 1 ;;
esac
echo "permission=$permission" >> "$GITHUB_OUTPUT"
if [ "$(rank "$permission")" -lt "$(rank "$MIN_ROLE")" ]; then
  comment "$(fill "$DENY_MESSAGE")"
  echo "::error::$COMMENTER has '$permission' permission - $COMMAND needs $MIN_ROLE."
  exit 1
fi
echo "✅ $COMMENTER has '$permission' permission."

# 3. Optional: the comment must be on an open PR, from a branch in this repo
if [ "$REQUIRE_PR" = "true" ] || [ "$REQUIRE_SAME_REPO" = "true" ]; then
  rc=0
  pr=$(api_get "repos/$REPO/pulls/$ISSUE_NUMBER" \
    '[.state, .head.ref, .head.sha, (.head.repo.full_name // "")] | @tsv') || rc=$?
  case "$rc" in
    0) ;;
    4)
      echo "::error::$COMMAND only runs on pull requests - #$ISSUE_NUMBER is not one."
      exit 1
      ;;
    *) exit 1 ;;
  esac
  IFS=$'\t' read -r state head_ref head_sha head_repo <<< "$pr"
  if [ "$state" != "open" ]; then
    echo "::error::PR #$ISSUE_NUMBER is not open (state: $state) - $COMMAND can't run."
    exit 1
  fi
  if [ "$REQUIRE_SAME_REPO" = "true" ] && [ "$head_repo" != "$REPO" ]; then
    if [ -z "$head_repo" ]; then reason="its fork was deleted"; else reason="it comes from the fork $head_repo"; fi
    comment "$(fill "$REFUSE_MESSAGE" "$reason")"
    echo "::error::$COMMAND refused: $reason. It only runs for branches in $REPO."
    exit 1
  fi
  {
    echo "head_ref=$head_ref"
    echo "head_sha=$head_sha"
    echo "head_repository=$head_repo"
  } >> "$GITHUB_OUTPUT"
fi

# 4. Allowed. Acknowledge it. A missing reaction scope must not stop the command.
if [ -n "$REACTION" ]; then
  gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" -f content="$REACTION" --silent \
    || echo "::warning::Could not add the reaction to the command."
fi

echo "✅ $COMMAND allowed for $COMMENTER on #$ISSUE_NUMBER"
