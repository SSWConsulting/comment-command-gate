#!/usr/bin/env bats

setup() {
  GATE="$BATS_TEST_DIRNAME/../gate.sh"
  PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : > "$GH_LOG"
  : > "$GITHUB_OUTPUT"

  export REPO=acme/site
  export ISSUE_NUMBER=42
  export COMMENT_ID=1001
  export COMMENT_BODY=/deploy
  export COMMENTER=octocat
  export COMMAND=/deploy
  export MIN_ROLE=write
  export REQUIRE_PR=false
  export REQUIRE_SAME_REPO=false
  export DENY_MESSAGE='denied @{commenter} {command} {role}'
  export REFUSE_MESSAGE='refused @{commenter} {command}: {reason}'
  export REACTION=+1

  has_role write
  open_pr_from acme/site
}

# Sets the permission API response to what GitHub returns for a base role.
has_role() {
  local permission=$1 admin=false maintain=false push=false triage=false pull=false
  case "$1" in
    admin) admin=true maintain=true push=true triage=true pull=true ;;
    maintain) permission=write maintain=true push=true triage=true pull=true ;;
    write) push=true triage=true pull=true ;;
    triage) permission=read triage=true pull=true ;;
    read) pull=true ;;
    none) ;;
  esac
  export GH_STUB_PERMISSION_BODY="{\"permission\":\"$permission\",\"role_name\":\"$1\",\"user\":{\"login\":\"$COMMENTER\",\"permissions\":{\"admin\":$admin,\"maintain\":$maintain,\"push\":$push,\"triage\":$triage,\"pull\":$pull}}}"
}

# Sets the pull request API response. An empty repo means the fork was deleted.
open_pr_from() {
  local repo=${1:-} state=${2:-open} head_repo=null
  [ -n "$repo" ] && head_repo="{\"full_name\":\"$repo\"}"
  export GH_STUB_PULL_BODY="{\"state\":\"$state\",\"head\":{\"ref\":\"feature\",\"sha\":\"abc123\",\"repo\":$head_repo}}"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

called() {
  grep -q -- "$1" "$GH_LOG"
}

not_called() {
  ! grep -q -- "$1" "$GH_LOG"
}

@test "allows a writer and adds a reaction" {
  run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(output_value permission)" = write ]
  called "repos/acme/site/issues/comments/1001/reactions"
}

@test "skips the reaction when reaction is empty" {
  REACTION='' run "$GATE"
  [ "$status" -eq 0 ]
  not_called reactions
}

@test "a failed reaction does not stop the command" {
  GH_STUB_REACTION_STATUS=403 run "$GATE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not add the reaction"* ]]
}

@test "refuses a comment that does not start with the command, with no API call" {
  COMMENT_BODY='please /deploy' run "$GATE"
  [ "$status" -eq 1 ]
  [ ! -s "$GH_LOG" ]
}

@test "allows the command followed by arguments or a new line" {
  for body in '/deploy now' $'/deploy\nthanks' $'/deploy\r\n' $'/deploy\tstaging'; do
    COMMENT_BODY=$body run "$GATE"
    [ "$status" -eq 0 ]
  done
}

@test "refuses a longer command that starts with the command" {
  for body in /deploy-prod /deployment '/deploy-prod now'; do
    COMMENT_BODY=$body run "$GATE"
    [ "$status" -eq 1 ]
  done
  [ ! -s "$GH_LOG" ]
}

@test "rejects an empty command" {
  COMMAND='' run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"command is required"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "rejects a require_same_repo_branch value that is not true or false" {
  open_pr_from someone/site
  for value in yes 1 on ''; do
    REQUIRE_SAME_REPO=$value run "$GATE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"require_same_repo_branch must be true or false"* ]]
  done
  [ ! -s "$GH_LOG" ]
}

@test "rejects a require_pull_request value that is not true or false" {
  REQUIRE_PR=yes run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"require_pull_request must be true or false"* ]]
}

@test "accepts True as true" {
  open_pr_from someone/site
  REQUIRE_SAME_REPO=True run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"it comes from the fork someone/site"* ]]
}

@test "rejects an unknown min_role" {
  MIN_ROLE=owner run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"min_role must be one of"* ]]
}

@test "refuses a commenter below min_role and posts the deny message" {
  has_role read
  run "$GATE"
  [ "$status" -eq 1 ]
  called "repos/acme/site/issues/42/comments"
  not_called reactions
}

@test "allows a maintainer when min_role is maintain" {
  has_role maintain
  MIN_ROLE=maintain run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(output_value permission)" = maintain ]
}

@test "allows a triager when min_role is triage" {
  has_role triage
  MIN_ROLE=triage run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(output_value permission)" = triage ]
}

@test "refuses a triager when min_role is write" {
  has_role triage
  run "$GATE"
  [ "$status" -eq 1 ]
}

@test "ranks a custom role by the flags of its base role" {
  has_role maintain
  GH_STUB_PERMISSION_BODY=${GH_STUB_PERMISSION_BODY/'"role_name":"maintain"'/'"role_name":"release-manager"'}
  MIN_ROLE=maintain run "$GATE"
  [ "$status" -eq 0 ]
}

@test "an empty deny_message posts no comment" {
  has_role read
  DENY_MESSAGE='' run "$GATE"
  [ "$status" -eq 1 ]
  not_called "issues/42/comments"
}

@test "an empty refuse_message posts no comment" {
  open_pr_from someone/site
  REFUSE_MESSAGE='' REQUIRE_SAME_REPO=true run "$GATE"
  [ "$status" -eq 1 ]
  not_called "issues/42/comments"
}

@test "a failed deny comment still logs why the command was refused" {
  has_role read
  GH_STUB_COMMENT_STATUS=403 run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Could not post the refusal comment"* ]]
  [[ "$output" == *"octocat has 'read' permission - /deploy needs write"* ]]
}

@test "a failed refuse comment still logs why the command was refused" {
  open_pr_from someone/site
  GH_STUB_COMMENT_STATUS=403 REQUIRE_SAME_REPO=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"/deploy refused: it comes from the fork someone/site"* ]]
}

@test "allows an admin when min_role is write" {
  has_role admin
  run "$GATE"
  [ "$status" -eq 0 ]
}

@test "treats a 404 from the permission lookup as no role" {
  GH_STUB_PERMISSION_STATUS=404 GH_STUB_PERMISSION_BODY='{"message":"Not Found"}' run "$GATE"
  [ "$status" -eq 1 ]
  [ "$(output_value permission)" = none ]
  called "repos/acme/site/issues/42/comments"
  not_called reactions
}

@test "fails with the API error, and posts no deny message, when the permission lookup errors" {
  GH_STUB_PERMISSION_STATUS=500 run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GitHub API call to repos/acme/site/collaborators/octocat/permission failed"* ]]
  not_called "issues/42/comments"
}

@test "skips the PR checks by default" {
  run "$GATE"
  [ "$status" -eq 0 ]
  not_called pulls
  [ -z "$(output_value head_sha)" ]
}

@test "require_pull_request refuses an issue" {
  GH_STUB_PULL_STATUS=404 REQUIRE_PR=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"only runs on pull requests"* ]]
}

@test "require_pull_request fails with the API error when the PR lookup errors" {
  GH_STUB_PULL_STATUS=502 REQUIRE_PR=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GitHub API call to repos/acme/site/pulls/42 failed"* ]]
  [[ "$output" != *"only runs on pull requests"* ]]
}

@test "require_pull_request reads the PR once" {
  REQUIRE_PR=true run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'pulls/42' "$GH_LOG")" -eq 1 ]
}

@test "require_pull_request refuses a closed PR" {
  open_pr_from acme/site closed
  REQUIRE_PR=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not open"* ]]
}

@test "require_pull_request allows a fork PR" {
  open_pr_from someone/site
  REQUIRE_PR=true run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(output_value head_repository)" = someone/site ]
}

@test "require_same_repo_branch allows a branch in this repo and sets the outputs" {
  REQUIRE_SAME_REPO=true run "$GATE"
  [ "$status" -eq 0 ]
  [ "$(output_value head_ref)" = feature ]
  [ "$(output_value head_sha)" = abc123 ]
  [ "$(output_value head_repository)" = acme/site ]
}

@test "require_same_repo_branch refuses a fork PR and says why" {
  open_pr_from someone/site
  REQUIRE_SAME_REPO=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"it comes from the fork someone/site"* ]]
  called "repos/acme/site/issues/42/comments"
  [ -z "$(output_value head_sha)" ]
}

@test "require_same_repo_branch refuses a PR whose fork was deleted" {
  open_pr_from ''
  REQUIRE_SAME_REPO=true run "$GATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"its fork was deleted"* ]]
}

@test "fills the placeholders in the deny message" {
  has_role read
  run "$GATE"
  called "body=denied @octocat /deploy write"
}

@test "keeps an & in a placeholder value" {
  has_role read
  COMMAND='/a&b' COMMENT_BODY='/a&b' run "$GATE"
  called "body=denied @octocat /a&b write"
}

@test "fills the placeholders in the refuse message" {
  open_pr_from someone/site
  REQUIRE_SAME_REPO=true run "$GATE"
  called "body=refused @octocat /deploy: it comes from the fork someone/site"
}
