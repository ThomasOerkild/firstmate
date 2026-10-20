#!/usr/bin/env bash
# Behavior tests for bin/fm-adopt.sh against a fake herdr: the record, brief,
# backlog item, and contract an adoption writes, and every refusal before any
# of them exists.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND TASKS_AXI_FILE FM_SUPERVISOR_TARGET TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION || :

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

ADOPT="$ROOT/bin/fm-adopt.sh"
TMP_ROOT=$(fm_test_tmproot fm-adopt)
cd "$TMP_ROOT" || exit 1

# The fake serves one agent pane (w1:p1), one pane without an agent (w1:p5),
# and nothing else. Typed text and keys are logged; Enter turns the agent's
# status to working, which is how a submit is confirmed.
write_fake_herdr() {  # <fakebin>
  cat > "$1/herdr" <<'SH'
#!/usr/bin/env bash
set -u
dir=${FAKE_HERDR_DIR:?}
printf '%s\n' "$*" >> "$dir/log"
status=$(cat "$dir/status" 2>/dev/null || printf idle)
agent_record() {
  printf '{"result":{"agent":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","agent":"%s","agent_status":"%s","cwd":"/","foreground_cwd":"%s","terminal_title_stripped":"fix login"}}}\n' \
    "${FAKE_HERDR_AGENT:-opencode}" "$status" "${FAKE_HERDR_CWD:?}"
}
case "${1:-} ${2:-}" in
  "status --json") printf '%s\n' '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}' ;;
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"/nonexistent/herdr.sock"}]}' ;;
  "agent get")
    case "${3:-}" in
      w1:p1) agent_record ;;
      w1:p5) printf '%s\n' '{"error":{"code":"agent_not_found"}}'; exit 1 ;;
      *) printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
    esac ;;
  "pane get")
    case "${3:-}" in
      w1:p1|w1:p5) printf '{"result":{"pane":{"pane_id":"%s","tab_id":"w1:t1","workspace_id":"w1","agent_status":"%s"}}}\n' "$3" "$status" ;;
      *) printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
    esac ;;
  "pane process-info")
    printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":1,"foreground_process_group_id":424242,"foreground_processes":[{"pid":424242,"name":"opencode","argv0":"opencode"}]}}}' ;;
  "pane send-text") printf '%s\n' "${4:-}" >> "$dir/typed" ;;
  "pane send-keys") [ "${4:-}" != enter ] || printf working > "$dir/status" ;;
  "pane read") printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$1/herdr"
}

# A home with a markdown backlog, a project, and the agent's own checkout on
# its own branch, outside any pool.
make_case() {  # <name>
  local dir="$TMP_ROOT/$1" fakebin
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/herdr"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$dir/home/data/backlog.md"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$dir/home/.tasks.toml"
  write_fake_herdr "$fakebin"
  fm_git_init_commit "$dir/project"
  git clone -q "$dir/project" "$dir/agent-dir"
  git -C "$dir/agent-dir" switch -q -c feature/login
  printf '%s\n' "$dir"
}

run_adopt() {  # <case> <args...>
  local dir=$1
  shift
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FAKE_HERDR_DIR="$dir/herdr" FAKE_HERDR_CWD="${FAKE_HERDR_CWD:-$dir/agent-dir}" \
    FM_SEND_SLEEP=0.05 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.05 \
    "$ADOPT" "$@"
}

backlog_section_of() {  # <case> <id>
  awk -v id="$2" '/^## / { section = substr($0, 4) } index($0, "**" id "**") || index($0, " " id " ") { print section; exit }' \
    "$1/home/data/backlog.md"
}

assert_nothing_adopted() {  # <case> <id> <label>
  assert_absent "$1/home/state/$2.meta" "$3: a task record was written"
  assert_absent "$1/home/data/$2/brief.md" "$3: a brief was written"
  assert_absent "$1/home/state/$2.inbox" "$3: a steering inbox was written"
  [ ! -s "$1/herdr/typed" ] || fail "$3: text was typed into a pane: $(cat "$1/herdr/typed")"
}

test_adopt_records_the_pane_and_delivers_the_contract() {
  command -v tasks-axi >/dev/null 2>&1 || { pass "fm-adopt: adoption skipped (tasks-axi is not installed)"; return; }
  local dir rc rec meta state
  dir=$(make_case adopt-ship)
  meta="$dir/home/state/login-fix.meta"
  state=$(cd "$dir/home/state" && pwd -P)

  rc=0
  run_adopt "$dir" login-fix --pane w1:p1 --project "$dir/project" --mode direct-PR --yolo off \
    > "$dir/stdout" 2> "$dir/stderr" || rc=$?
  expect_code 0 "$rc" "fm-adopt: adopting a live agent pane ($(cat "$dir/stderr"))"

  assert_equals "default:w1:p1" "$(fm_meta_get "$meta" window)" "the record names the adopted pane"
  assert_equals "login-fix" "$(fm_meta_get "$meta" endpoint_task_id)" "the record binds the endpoint to the task"
  assert_equals "$dir/agent-dir" "$(fm_meta_get "$meta" worktree)" "the record's worktree is the agent's own directory"
  assert_equals "opencode" "$(fm_meta_get "$meta" harness)" "the record's harness is the agent herdr detected"
  assert_equals "ship" "$(fm_meta_get "$meta" kind)" "the record is a ship"
  assert_equals "direct-PR" "$(fm_meta_get "$meta" mode)" "the record carries the delivery mode"
  assert_equals "off" "$(fm_meta_get "$meta" yolo)" "the record carries the merge posture"
  assert_equals "feature/login" "$(fm_meta_get "$meta" branch)" "the record names the agent's current branch"
  assert_equals "herdr" "$(fm_meta_get "$meta" backend)" "the record is herdr-backed"
  assert_equals "w1:t1" "$(fm_meta_get "$meta" herdr_tab_id)" "the record carries the pane's tab"
  assert_equals "w1" "$(fm_meta_get "$meta" herdr_workspace_id)" "the record carries the pane's workspace"
  assert_equals "1" "$(fm_meta_get "$meta" adopted)" "the record is marked adopted"
  bash -c '. "$1/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$2" login-fix' _ "$ROOT" "$meta" \
    || fail "the adopted record fails the shared endpoint validation"

  assert_equals "In flight" "$(backlog_section_of "$dir" login-fix)" "the backlog item is In flight"
  assert_grep "fix login" "$dir/home/data/backlog.md" "the backlog item takes the pane's title"

  assert_grep "Firstmate adopted you" "$dir/home/data/login-fix/brief.md" "the brief carries the adoption setup"
  assert_no_grep "git checkout -b" "$dir/home/data/login-fix/brief.md" "the brief must not tell the agent to branch again"
  rec="$state/login-fix.inbox/001.msg"
  assert_present "$rec" "the contract is the task's first steering record"
  assert_grep "# Current worker role contract" "$rec" "the contract opens with the worker role"
  assert_grep "address the captain" "$rec" "the contract forbids addressing the captain"
  assert_grep "Your steering inbox is \`$state/login-fix.inbox\`" "$rec" "the contract names the exact steering inbox"
  assert_grep "$state/login-fix.status" "$rec" "the contract names the status file"
  assert_grep "Report status by appending one line" "$rec" "the contract carries the status protocol"
  assert_grep "Keep your current work" "$rec" "the contract tells the agent to keep its work"
  assert_grep "reports your current state" "$rec" "the contract asks for the current state first"
  assert_grep "$rec" "$dir/herdr/typed" "the typed pointer names the contract record by absolute path"
  [ "$(wc -l < "$dir/herdr/typed")" -eq 1 ] || fail "exactly one line is typed into the pane: $(cat "$dir/herdr/typed")"
  assert_grep "contract delivered" "$dir/stdout" "a confirmed pointer is reported as delivered"
  pass "fm-adopt: an adopted pane gets a record, an In flight backlog item, and one contract"
}

test_adopt_refuses_before_writing_anything() {
  local dir rc
  dir=$(make_case adopt-refusals)

  rc=0
  run_adopt "$dir" gone --pane w1:p9 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a pane herdr does not know"
  assert_grep "does not exist" "$dir/stderr" "a missing pane names the reason"
  assert_nothing_adopted "$dir" gone "missing pane"

  rc=0
  run_adopt "$dir" husk --pane w1:p5 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a pane with no agent"
  assert_grep "no detected agent" "$dir/stderr" "an agent-less pane names the reason"
  assert_nothing_adopted "$dir" husk "agent-less pane"

  rc=0
  FAKE_HERDR_AGENT=vim run_adopt "$dir" editor --pane w1:p1 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted an agent that is not a firstmate harness"
  assert_grep "not a firstmate harness" "$dir/stderr" "an unknown agent names the reason"
  assert_nothing_adopted "$dir" editor "unknown agent"

  rc=0
  FM_SUPERVISOR_TARGET=default:w1:p1 run_adopt "$dir" self --pane w1:p1 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted firstmate's own pane"
  assert_grep "firstmate's own pane" "$dir/stderr" "firstmate's own pane names the reason"
  assert_nothing_adopted "$dir" self "own pane"

  rc=0
  FAKE_HERDR_CWD="$dir/home" run_adopt "$dir" home --pane w1:p1 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a pane running in the firstmate home"
  assert_grep "firstmate's own pane" "$dir/stderr" "a pane in the firstmate home names the reason"
  assert_nothing_adopted "$dir" home "pane in the home"

  fm_write_meta "$dir/home/state/owner.meta" "window=default:w1:p1" "worktree=$dir/agent-dir"
  rc=0
  run_adopt "$dir" second --pane w1:p1 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a pane another task already owns"
  assert_grep "already task owner's endpoint" "$dir/stderr" "an owned pane names its owner"
  assert_nothing_adopted "$dir" second "owned pane"
  rm -f "$dir/home/state/owner.meta"

  fm_write_meta "$dir/home/state/taken.meta" "window=default:w2:p2"
  rc=0
  run_adopt "$dir" taken --pane w1:p1 --project "$dir/project" --kind scout > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt overwrote an existing task record"
  assert_grep "already has a record" "$dir/stderr" "an existing task id names the reason"
  assert_equals "default:w2:p2" "$(fm_meta_get "$dir/home/state/taken.meta" window)" "the existing record is unchanged"

  rc=0
  FAKE_HERDR_CWD="$dir/home/data" run_adopt "$dir" detached --pane w1:p1 --project "$dir/project" --mode local-only --yolo off \
    > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a ship with no branch to name"
  assert_grep "pass --worktree" "$dir/stderr" "a ship in a directory that is not a git copy names the fix"
  assert_nothing_adopted "$dir" detached "ship without a branch"
  pass "fm-adopt: a missing, agent-less, unknown, own, or owned pane is refused before anything is written"
}

test_adopt_stops_when_the_backlog_backend_is_unavailable() {
  local dir rc
  dir=$(make_case adopt-backlog-down)
  printf '#!/usr/bin/env bash\nprintf "0.0.1\\n"\n' > "$dir/fakebin/tasks-axi"
  chmod +x "$dir/fakebin/tasks-axi"
  rc=0
  run_adopt "$dir" login-fix --pane w1:p1 --project "$dir/project" --mode direct-PR --yolo off \
    > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a pane while the backlog backend was unavailable"
  assert_grep "backlog backend is unavailable" "$dir/stderr" "an unavailable backlog names the reason"
  assert_nothing_adopted "$dir" login-fix "unavailable backlog"
  pass "fm-adopt: an unavailable backlog backend stops the adoption with a clear message"
}

test_adopted_task_refuses_relaunch() {
  local dir rc
  dir=$(make_case adopt-relaunch)
  fm_write_meta "$dir/home/state/adopted.meta" \
    "window=default:w1:p1" "endpoint_task_id=adopted" "worktree=$dir/agent-dir" \
    "project=$dir/project" "harness=opencode" "kind=scout" "spawn_gen=a1.1.1" \
    "backend=herdr" "herdr_session=default" "herdr_workspace_id=w1" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" "adopted=1"
  : > "$dir/agent-dir/sentinel"
  rc=0
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" PATH="$dir/fakebin:$PATH" \
    FAKE_HERDR_DIR="$dir/herdr" FAKE_HERDR_CWD="$dir/agent-dir" \
    "$ROOT/bin/fm-spawn.sh" adopted --relaunch > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn relaunched an adopted agent"
  assert_grep "adopted agent" "$dir/stderr" "the relaunch refusal names the adoption"
  assert_present "$dir/agent-dir/sentinel" "the refused relaunch changed the adopted directory"
  [ ! -s "$dir/herdr/typed" ] || fail "the refused relaunch typed into the adopted pane"
  pass "fm-spawn: an adopted task refuses relaunch"
}

# A session directory that holds several clones of one origin: the agent's
# branch is pushed to origin and checked out in session/brain only, while the
# project clone is single-branch and has never seen it.
make_session_case() {  # <name>
  local dir
  dir=$(make_case "$1")
  git clone -q --bare "$dir/project" "$dir/origin.git"
  rm -rf "$dir/project"
  git clone -q --single-branch "$dir/origin.git" "$dir/project"
  mkdir -p "$dir/session/tools"
  git clone -q "$dir/origin.git" "$dir/session/brain"
  git -C "$dir/session/brain" switch -q -c feature/login
  git -C "$dir/session/brain" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m login
  git -C "$dir/session/brain" push -q origin feature/login
  git clone -q "$dir/origin.git" "$dir/session/api"
  git clone -q "$dir/origin.git" "$dir/session/tools/web"
  git -C "$dir/session/tools/web" switch -q -c feature/other
  printf '%s\n' "$dir"
}

test_adopt_resolves_the_git_copy_below_a_session_directory() {
  command -v tasks-axi >/dev/null 2>&1 || { pass "fm-adopt: session-directory adoption skipped (tasks-axi is not installed)"; return; }
  local dir rc meta head
  dir=$(make_session_case adopt-session)
  meta="$dir/home/state/login-fix.meta"
  head=$(git -C "$dir/session/brain" rev-parse HEAD)

  rc=0
  FAKE_HERDR_CWD="$dir/session" run_adopt "$dir" login-fix --pane w1:p1 --project "$dir/project" \
    --mode direct-PR --yolo off --branch feature/login > /dev/null 2> "$dir/stderr" || rc=$?
  expect_code 0 "$rc" "fm-adopt: adopting a pane in a session directory ($(cat "$dir/stderr"))"
  assert_equals "$dir/session/brain" "$(fm_meta_get "$meta" worktree)" "the record's worktree is the one clone on the agent's branch"
  assert_equals "$head" "$(git -C "$dir/project" rev-parse --verify --quiet refs/remotes/origin/feature/login)" \
    "the agent's pushed branch is fetched into the project clone's remote-tracking ref"
  assert_present "$dir/session/brain/.git" "the adopted git copy is untouched"
  pass "fm-adopt: a session directory resolves to the one clone on the branch, and the branch is fetched"

  dir=$(make_session_case adopt-explicit)
  meta="$dir/home/state/web.meta"
  rc=0
  FAKE_HERDR_CWD="$dir/session" run_adopt "$dir" web --pane w1:p1 --project "$dir/project" \
    --mode direct-PR --yolo off --worktree "$dir/session/tools/web" > /dev/null 2> "$dir/stderr" || rc=$?
  expect_code 0 "$rc" "fm-adopt: adopting with --worktree ($(cat "$dir/stderr"))"
  assert_equals "$dir/session/tools/web" "$(fm_meta_get "$meta" worktree)" "--worktree is recorded as the worktree"
  assert_equals "feature/other" "$(fm_meta_get "$meta" branch)" "the branch defaults to the --worktree copy's branch"
  assert_grep "could not be fetched" "$dir/stderr" "a branch absent from origin is reported"
  pass "fm-adopt: --worktree names the git copy and a branch absent from origin does not stop the adoption"
}

test_adopt_refuses_an_unresolvable_git_copy() {
  local dir rc
  dir=$(make_session_case adopt-session-refusals)

  rc=0
  FAKE_HERDR_CWD="$dir/session" run_adopt "$dir" nobranch --pane w1:p1 --project "$dir/project" \
    --mode direct-PR --yolo off --branch feature/missing > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a session directory with no clone on the branch"
  assert_grep "no git copy below" "$dir/stderr" "no matching clone names the reason"
  assert_grep "pass --worktree" "$dir/stderr" "no matching clone names --worktree"
  assert_nothing_adopted "$dir" nobranch "no matching clone"

  git -C "$dir/session/api" switch -q -c feature/login
  rc=0
  FAKE_HERDR_CWD="$dir/session" run_adopt "$dir" twice --pane w1:p1 --project "$dir/project" \
    --mode direct-PR --yolo off --branch feature/login > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt chose between two clones on the same branch"
  assert_grep "several git copies" "$dir/stderr" "several matching clones name the reason"
  assert_grep "pass --worktree" "$dir/stderr" "several matching clones name --worktree"
  assert_nothing_adopted "$dir" twice "several matching clones"

  rc=0
  FAKE_HERDR_CWD="$dir/session" run_adopt "$dir" scout --pane w1:p1 --project "$dir/project" --kind scout \
    > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt adopted a scout whose directory is not a git copy"
  assert_grep "pass --worktree" "$dir/stderr" "a scout outside a git copy names --worktree"
  assert_nothing_adopted "$dir" scout "scout outside a git copy"

  rc=0
  run_adopt "$dir" notgit --pane w1:p1 --project "$dir/project" --kind scout --worktree "$dir/session" \
    > /dev/null 2> "$dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-adopt accepted a --worktree that is not a git copy"
  assert_grep "is not a git copy" "$dir/stderr" "a --worktree that is not a git copy names the reason"
  assert_nothing_adopted "$dir" notgit "--worktree that is not a git copy"
  pass "fm-adopt: a git copy that is missing, ambiguous, or not git is refused before anything is written"
}

test_adopt_records_the_pane_and_delivers_the_contract
test_adopt_refuses_before_writing_anything
test_adopt_resolves_the_git_copy_below_a_session_directory
test_adopt_refuses_an_unresolvable_git_copy
test_adopt_stops_when_the_backlog_backend_is_unavailable
test_adopted_task_refuses_relaunch

echo "all fm-adopt tests passed"
