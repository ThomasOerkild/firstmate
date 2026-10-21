#!/usr/bin/env bash
# Behavior tests for PR hygiene: the GitHub PR poll's hygiene line
# (bin/fm-pr-poll.sh) and its dedup, steer, and wake routing
# (bin/fm-pr-hygiene.sh).
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
HYGIENE="$ROOT/bin/fm-pr-hygiene.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-hygiene)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "the fake gh runs the poll's --jq program with the real jq, which was not found"
export FM_TEST_REAL_JQ="$REAL_JQ"
URL=https://github.com/o/r/pull/7
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
program=
while [ "$#" -gt 0 ]; do
  [ "$1" != --jq ] || program=$2
  shift
done
"$FM_TEST_REAL_JQ" -r "$program" "$FM_TEST_PR_JSON"
SH
chmod +x "$FAKEBIN/gh"

# pr_json <file> <jq-edit>: an open, clean PR record with <jq-edit> applied.
pr_json() {
  "$REAL_JQ" -n "{data: {viewer: {login: \"me\"}, repository: {pullRequest: {
    state: \"OPEN\", isDraft: false, mergeable: \"MERGEABLE\", mergeStateStatus: \"CLEAN\",
    headRefOid: \"$HEAD_A\", author: {login: \"me\"},
    reviewThreads: {nodes: []}, latestReviews: {nodes: []}, comments: {nodes: []},
    commits: {nodes: [{commit: {oid: \"$HEAD_A\", statusCheckRollup: {contexts: {nodes: []}}}}]}
  }}}} | .data.repository.pullRequest |= ($2)" > "$1"
}

run_poll() {  # <json-file>
  FM_TEST_PR_JSON=$1 PATH="$FAKEBIN:$BASE_PATH" \
    bash "$POLL" --validated github "$URL" github.com o/r 7
}

BOT='{__typename: "Bot", login: "coderabbitai"}'
PERSON='{__typename: "User", login: "reviewer"}'
ME='{__typename: "User", login: "me"}'

test_poll_clean_draft_and_merged() {
  local f="$TMP_ROOT/clean.json" out
  pr_json "$f" .
  out=$(run_poll "$f")
  [ -z "$out" ] || fail "clean PR emitted: $out"
  pr_json "$f" ".isDraft = true | .mergeable = \"CONFLICTING\" | .reviewThreads.nodes = [{isResolved: false, comments: {nodes: [{databaseId: 5, author: $BOT}]}}]"
  out=$(run_poll "$f")
  [ -z "$out" ] || fail "draft PR emitted: $out"
  pr_json "$f" '.state = "CLOSED" | .mergeable = "CONFLICTING"'
  out=$(run_poll "$f")
  [ -z "$out" ] || fail "closed PR emitted: $out"
  pr_json "$f" '.state = "MERGED"'
  out=$(run_poll "$f")
  [ "$out" = merged ] || fail "merged PR did not emit merged: $out"
  pass "a clean, draft, or closed PR emits nothing and a merged PR emits only merged"
}

test_poll_work_findings() {
  local f="$TMP_ROOT/work.json" out
  pr_json "$f" ".mergeable = \"CONFLICTING\" | .mergeStateStatus = \"DIRTY\"
    | .reviewThreads.nodes = [
        {isResolved: false, comments: {nodes: [{databaseId: 11, author: $BOT}]}},
        {isResolved: false, comments: {nodes: [{databaseId: 19, author: {__typename: \"Bot\", login: \"other[bot]\"}}]}},
        {isResolved: false, comments: {nodes: [{databaseId: 30, author: $ME}]}},
        {isResolved: true, comments: {nodes: [{databaseId: 40, author: $BOT}]}}]
    | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes = [
        {__typename: \"CheckRun\", conclusion: \"FAILURE\", isRequired: true},
        {__typename: \"StatusContext\", state: \"ERROR\", isRequired: true},
        {__typename: \"CheckRun\", conclusion: \"SUCCESS\", isRequired: true},
        {__typename: \"CheckRun\", conclusion: \"FAILURE\", isRequired: false}]"
  out=$(run_poll "$f")
  [ "$out" = "hygiene head=$HEAD_A work=threads:2@19,conflict,checks:2 human=-" ] \
    || fail "work findings line was wrong: $out"

  pr_json "$f" '.mergeStateStatus = "BEHIND"
    | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes = [
        {__typename: "CheckRun", conclusion: "TIMED_OUT", isRequired: false},
        {__typename: "CheckRun", conclusion: null, isRequired: false}]'
  out=$(run_poll "$f")
  [ "$out" = "hygiene head=$HEAD_A work=checks:1,behind human=-" ] \
    || fail "behind branch or unrequired failing check was not reported: $out"

  pr_json "$f" ".commits.nodes[0].commit.oid = \"$HEAD_B\"
    | .commits.nodes[0].commit.statusCheckRollup.contexts.nodes = [
        {__typename: \"CheckRun\", conclusion: \"FAILURE\", isRequired: true}]"
  out=$(run_poll "$f")
  [ -z "$out" ] || fail "checks from a commit other than the head were reported: $out"
  pass "the poll reports bot threads not answered by us, conflicts, failing required checks, and a behind branch"
}

test_poll_human_findings() {
  local f="$TMP_ROOT/human.json" out
  pr_json "$f" ".reviewThreads.nodes = [{isResolved: false, comments: {nodes: [{databaseId: 50, author: $PERSON}]}}]
    | .latestReviews.nodes = [
        {databaseId: 60, state: \"CHANGES_REQUESTED\", author: $PERSON},
        {databaseId: 61, state: \"CHANGES_REQUESTED\", author: $BOT},
        {databaseId: 62, state: \"APPROVED\", author: {__typename: \"User\", login: \"lead\"}}]
    | .comments.nodes = [
        {databaseId: 70, author: $PERSON},
        {databaseId: 71, author: $ME},
        {databaseId: 72, author: $BOT},
        {databaseId: 73, author: $PERSON}]"
  out=$(run_poll "$f")
  [ "$out" = "hygiene head=$HEAD_A work=- human=threads:1@50,changes:1@60,comments:1@73" ] \
    || fail "human findings line was wrong: $out"
  pass "the poll separates review from people, and counts only conversation comments after our last one"
}

# --- handler ----------------------------------------------------------------

HOME_DIR="$TMP_ROOT/home"
FAKE_ROOT="$TMP_ROOT/root"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$FAKE_ROOT/bin"
cat > "$FAKE_ROOT/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_HOME:-}" ] || exit 9
{ printf 'target=%s\n' "$1"; printf '%s\n' "$2"; printf -- '--\n'; } >> "$FM_TEST_SEND_LOG"
exit "${FM_TEST_SEND_RC:-0}"
SH
chmod +x "$FAKE_ROOT/bin/fm-send.sh"
SEND_LOG="$TMP_ROOT/send.log"

reset_task() {  # <meta lines...>
  rm -f "$HOME_DIR/state/task-a.pr-hygiene" "$HOME_DIR/config/no-pr-hygiene"
  : > "$SEND_LOG"
  fm_write_meta "$HOME_DIR/state/task-a.meta" "$@" "pr=$URL"
}

handle() {  # <line>
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FAKE_ROOT" FM_TEST_SEND_LOG="$SEND_LOG" \
    bash "$HYGIENE" task-a "$URL" "$1"
}

sends() { grep -c '^target=task-a$' "$SEND_LOG"; }

test_handler_steers_once_per_state() {
  local out
  reset_task kind=ship backend=zellij window=fm-task-a mode=direct-PR
  out=$(handle "hygiene head=$HEAD_A work=threads:2@19,conflict human=-")
  [ -z "$out" ] || fail "a worker steer also woke firstmate: $out"
  [ "$(sends)" = 1 ] || fail "first work finding was not steered once"
  grep -qF "PR hygiene for $URL at head $HEAD_A: 2 unresolved review-bot thread(s), a merge conflict with the base branch." "$SEND_LOG" \
    || fail "steer did not name the PR, head, and findings"
  grep -qF 'Run make-it-green for this PR now' "$SEND_LOG" || fail "steer did not ask for make-it-green"
  grep -qF 'push to the PR branch' "$SEND_LOG" || fail "direct-PR steer did not say to push"

  handle "hygiene head=$HEAD_A work=threads:2@19,conflict human=-" >/dev/null
  handle "hygiene head=$HEAD_A work=threads:1@19 human=-" >/dev/null
  [ "$(sends)" = 1 ] || fail "a repeated or shrunk finding set steered again"

  handle "hygiene head=$HEAD_A work=threads:2@25 human=-" >/dev/null
  [ "$(sends)" = 2 ] || fail "a new review comment did not steer again"
  handle "hygiene head=$HEAD_A work=threads:2@25,checks:1 human=-" >/dev/null
  [ "$(sends)" = 3 ] || fail "a new finding kind did not steer again"
  handle "hygiene head=$HEAD_B work=threads:2@25,checks:1 human=-" >/dev/null
  [ "$(sends)" = 4 ] || fail "a new head with findings did not steer again"
  handle "hygiene head=$HEAD_B work=threads:2@25,checks:1 human=-" >/dev/null
  [ "$(sends)" = 4 ] || fail "an unchanged state on the new head steered again"
  pass "a work finding steers the worker once per new head, kind, or comment, and never repeats"
}

test_handler_no_mistakes_wording() {
  reset_task kind=ship backend=zellij window=fm-task-a mode=no-mistakes
  handle "hygiene head=$HEAD_A work=behind human=-" >/dev/null
  grep -qF 'publish the result through /no-mistakes' "$SEND_LOG" \
    || fail "no-mistakes steer did not keep the pipeline as the publisher"
  ! grep -qF 'push to the PR branch' "$SEND_LOG" || fail "no-mistakes steer told the worker to push directly"
  pass "a no-mistakes task is told to publish through its pipeline"
}

test_handler_routes_human_review_to_firstmate() {
  local out
  reset_task kind=ship backend=zellij window=fm-task-a mode=direct-PR
  out=$(handle "hygiene head=$HEAD_A work=- human=threads:1@50,changes:1@60")
  [ "$out" = "pr-hygiene $URL has review from people for the captain: 1 unresolved review thread(s) from people, 1 changes-requested review(s) from people" ] \
    || fail "human review did not produce the firstmate wake reason: $out"
  [ "$(sends)" = 0 ] || fail "human review was sent to the worker"
  out=$(handle "hygiene head=$HEAD_B work=- human=threads:1@50,changes:1@60")
  [ -z "$out" ] || fail "the same human review woke firstmate again: $out"
  out=$(handle "hygiene head=$HEAD_B work=- human=changes:1@60,comments:1@80")
  case "$out" in *"1 new conversation comment(s) from people"*) ;; *) fail "a new human comment did not wake firstmate: $out" ;; esac
  out=$(handle "hygiene head=$HEAD_B work=checks:1 human=changes:1@60,comments:1@80")
  [ -z "$out" ] && [ "$(sends)" = 1 ] || fail "mixed findings did not steer only the work part: $out"
  pass "review from people wakes firstmate once per new comment and never reaches the worker"
}

test_handler_gone_worker_and_failed_steer_wake_firstmate() {
  local out
  reset_task kind=ship backend=zellij mode=direct-PR
  out=$(handle "hygiene head=$HEAD_A work=conflict human=-")
  [ "$out" = "pr-hygiene $URL needs make-it-green (a merge conflict with the base branch) but its worker is gone" ] \
    || fail "a task with no endpoint did not wake firstmate: $out"
  [ "$(sends)" = 0 ] || fail "a steer was sent to a task with no endpoint"
  out=$(handle "hygiene head=$HEAD_A work=conflict human=-")
  [ -z "$out" ] || fail "the gone-worker wake repeated: $out"

  reset_task kind=ship backend=zellij window=fm-task-a mode=direct-PR
  out=$(FM_TEST_SEND_RC=1 handle "hygiene head=$HEAD_A work=conflict human=-")
  case "$out" in *"the steer to its worker could not be recorded"*) ;; *) fail "a failed steer did not wake firstmate: $out" ;; esac
  pass "a gone worker or an unrecorded steer wakes firstmate once instead"
}

test_handler_skips() {
  local out
  reset_task kind=ship backend=zellij window=fm-task-a mode=direct-PR
  : > "$HOME_DIR/config/no-pr-hygiene"
  out=$(handle "hygiene head=$HEAD_A work=conflict human=changes:1@60")
  [ -z "$out" ] && [ "$(sends)" = 0 ] || fail "the opt-out file did not turn hygiene off"

  reset_task kind=secondmate window=fm-task-a
  out=$(handle "hygiene head=$HEAD_A work=conflict human=changes:1@60")
  [ -z "$out" ] && [ "$(sends)" = 0 ] || fail "a secondmate record got hygiene"

  reset_task kind=ship backend=zellij window=fm-task-a mode=direct-PR
  for line in "hygiene head=$HEAD_A work=conflict;rm human=-" "hygiene head=short work=conflict human=-" \
    "hygiene head=$HEAD_A work=Conflict human=-" "merged"; do
    out=$(handle "$line")
    [ -z "$out" ] || fail "malformed line produced output: $line"
  done
  [ "$(sends)" = 0 ] || fail "a malformed line steered the worker"
  pass "the opt-out file, a secondmate record, and a malformed line do nothing"
}

test_poll_clean_draft_and_merged
test_poll_work_findings
test_poll_human_findings
test_handler_steers_once_per_state
test_handler_no_mistakes_wording
test_handler_routes_human_review_to_firstmate
test_handler_gone_worker_and_failed_steer_wake_firstmate
test_handler_skips
