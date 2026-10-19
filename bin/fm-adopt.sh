#!/usr/bin/env bash
# Adopt an agent that already runs in a herdr pane firstmate did not start, so
# firstmate supervises it like a spawned task.
# Usage: fm-adopt.sh <task-id> --pane <herdr-pane-id> --project <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--branch <name>] [--session <herdr-session>] [--title <text>]
#        fm-adopt.sh <task-id> --pane <herdr-pane-id> --project <project-dir> --kind scout [--session <herdr-session>] [--title <text>]
#   --kind defaults to ship. A ship takes the same explicit --mode and --yolo a
#   ship spawn takes; --branch names the agent's existing branch and defaults
#   to the branch checked out in the pane's directory.
#   --session defaults to $HERDR_SESSION, else herdr's "default" session.
#   --title is the backlog item's title and defaults to the pane's terminal title.
# The live pane facts come from `herdr agent get`: workspace, tab, the agent's
# harness label, and its working directory (foreground_cwd, else cwd).
# Refuses, before anything is written:
#   - a pane herdr does not know, or one with no detected agent;
#   - an agent label that is not a firstmate harness name;
#   - firstmate's own pane: the supervisor pane (bin/fm-supervisor-target-lib.sh),
#     this process's own herdr pane, or a pane whose directory is this home;
#   - a pane a task record in this home already names, or a task id that
#     already has a record or a brief;
#   - an automatic backlog whose backend is unavailable, or an existing
#     backlog item for the id that is not dispatchable.
# Then, in order:
#   1. bin/fm-brief.sh --adopted scaffolds data/<id>/brief.md: the ordinary
#      rules, inbox, and Definition of done, with a Setup that keeps the
#      agent's current work, directory, and branch.
#   2. state/<id>.meta is published with the fields bin/fm-spawn.sh writes for
#      a herdr task, worktree= set to the pane's directory, and adopted=1.
#      adopted=1 makes bin/fm-teardown.sh remove only firstmate's own records
#      (never the directory, never the pane), makes bin/fm-spawn.sh --relaunch
#      refuse, and lets bin/fm-busy-lib.sh read herdr's native idle, because no
#      busy hooks are installed in a directory firstmate does not own.
#   3. The backlog item is added when absent and moved to In flight through the
#      same transition a spawn commits; a failure removes the record and brief.
#   4. The worker role contract (bin/fm-dod-lib.sh) followed by the brief is
#      written once into the task's steering inbox, and bin/fm-send.sh types one
#      line into the pane that names that record by its absolute path, because
#      an adopted agent has no FM_TASK_INBOX in its environment.
# A typed line whose submit stays unconfirmed is reported and still succeeds:
# the record is durable and bin/fm-watch.sh re-rings it. Any other failure to
# type it exits 1 after the adoption is complete, naming the record to point
# the agent at by hand.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

die() {
  echo "error: $*" >&2
  exit 1
}

ID=
PANE=
PROJECT=
KIND=ship
MODE=
YOLO=
BRANCH=
SESSION=
TITLE=
while [ "$#" -gt 0 ]; do
  case "$1" in
  --pane | --project | --kind | --mode | --yolo | --branch | --session | --title)
    [ "$#" -ge 2 ] || die "$1 requires a value"
    case "$1" in
    --pane) PANE=$2 ;;
    --project) PROJECT=$2 ;;
    --kind) KIND=$2 ;;
    --mode) MODE=$2 ;;
    --yolo) YOLO=$2 ;;
    --branch) BRANCH=$2 ;;
    --session) SESSION=$2 ;;
    --title) TITLE=$2 ;;
    esac
    shift 2
    ;;
  -*) die "unknown option $1" ;;
  *)
    [ -z "$ID" ] || die "unexpected argument $1"
    ID=$1
    shift
    ;;
  esac
done

fm_task_id_creation_valid "$ID" || die "invalid task id"
[ -n "$PANE" ] || die "--pane is required"
[ -n "$PROJECT" ] || die "--project is required"
PROJ_ABS=$(cd "$PROJECT" 2>/dev/null && pwd -P) || die "project directory not found: $PROJECT"
case "$KIND" in
ship)
  case "$MODE" in
  no-mistakes | direct-PR | local-only) ;;
  *) die "a ship adoption requires --mode <no-mistakes|direct-PR|local-only>" ;;
  esac
  case "$YOLO" in
  on | off) ;;
  *) die "a ship adoption requires --yolo <on|off>" ;;
  esac
  ;;
scout)
  [ -z "$MODE$YOLO$BRANCH" ] || die "--mode, --yolo, and --branch apply only to a ship adoption"
  ;;
*) die "--kind must be ship or scout" ;;
esac

fm_backend_source herdr || die "the herdr backend could not be loaded"
[ -n "$SESSION" ] || SESSION=$(fm_backend_herdr_session)
TARGET="$SESSION:$PANE"

AGENT_JSON=$(fm_backend_herdr_cli "$SESSION" agent get "$PANE" 2>&1) || true
case "$(printf '%s' "$AGENT_JSON" | jq -r '.error.code // empty' 2>/dev/null)" in
'') ;;
pane_not_found) die "herdr pane $TARGET does not exist" ;;
agent_not_found) die "herdr pane $TARGET runs no detected agent" ;;
*) die "herdr could not read pane $TARGET: $AGENT_JSON" ;;
esac
pane_field() {
  printf '%s' "$AGENT_JSON" | jq -r --arg k "$1" '.result.agent[$k] // empty' 2>/dev/null
}
[ "$(pane_field pane_id)" = "$PANE" ] || die "herdr returned no agent record for pane $TARGET"
WORKSPACE_ID=$(pane_field workspace_id)
TAB_ID=$(pane_field tab_id)
HARNESS=$(pane_field agent)
WT=$(pane_field foreground_cwd)
[ -n "$WT" ] || WT=$(pane_field cwd)
[ -n "$WORKSPACE_ID" ] && [ -n "$TAB_ID" ] || die "herdr returned no workspace or tab for pane $TARGET"
[ -n "$WT" ] && [ -d "$WT" ] || die "pane $TARGET has no readable working directory (${WT:-none})"
[ -n "$TITLE" ] || TITLE=$(pane_field terminal_title_stripped)
[ -n "$TITLE" ] || TITLE="adopted herdr pane $TARGET"

case "$HARNESS" in
claude | codex | opencode | pi | pi-signed | grok | kimi | cursor | gemini | muse | rovo | omp | agy | devin | commandcode | polytoken) ;;
*) die "pane $TARGET runs agent '${HARNESS:-unknown}', which is not a firstmate harness" ;;
esac

OWN_TARGET=$(discover_supervisor_target 2>/dev/null) || OWN_TARGET=
if [ "$TARGET" = "$OWN_TARGET" ] \
  || { [ -n "${HERDR_PANE_ID:-}" ] && [ "$TARGET" = "$(fm_backend_herdr_session):$HERDR_PANE_ID" ]; } \
  || [ "$(cd "$WT" && pwd -P)" = "$(cd "$FM_HOME" 2>/dev/null && pwd -P)" ]; then
  die "pane $TARGET is firstmate's own pane"
fi
OWNER=$(fm_backend_meta_for_window "$TARGET" "$STATE" 2>/dev/null) || OWNER=
[ -z "$OWNER" ] || die "pane $TARGET is already task $(basename "$OWNER" .meta)'s endpoint"
[ ! -e "$STATE/$ID.meta" ] || die "task $ID already has a record at $STATE/$ID.meta"
[ ! -e "$DATA/$ID/brief.md" ] || die "task $ID already has a brief at $DATA/$ID/brief.md"

if [ "$KIND" = ship ] && [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) \
    || die "pane $TARGET's directory $WT has no checked-out branch; pass --branch"
fi

BACKLOG_TRANSITION=0
BACKLOG_ADD=0
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_TRANSITION=1
  if fm_backlog_row_probe "$DATA" "$ID"; then
    fm_backlog_row_dispatchable "$FM_BACKLOG_ROW_STATE" \
      || die "backlog item $ID is not dispatchable in state $FM_BACKLOG_ROW_STATE"
  elif [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    BACKLOG_ADD=1
  else
    die "backlog item $ID could not be read: $FM_BACKLOG_ROW_ERROR"
  fi
else
  [ "$?" -ne 2 ] || die "the backlog backend is unavailable (${FM_BACKLOG_TRANSITION_ERROR:-unknown reason}); nothing was adopted"
  echo "note: no automatic backlog transition ($FM_BACKLOG_TRANSITION_SKIP); record task $ID in the backlog by hand" >&2
fi

mkdir -p "$STATE" "$DATA" || die "could not create this home's state or data directory"
# The typed pointer names the record by an absolute path.
STATE=$(cd "$STATE" && pwd -P)
DATA=$(cd "$DATA" && pwd -P)
TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || die "could not resolve the task-set lock for $STATE"
TASK_LOCK="$STATE/.spawn-$ID.lock"
META_LOCK=$(fm_meta_lock_path "$STATE/$ID.meta") || die "could not resolve the record lock for $ID"
HELD_LOCKS=()
BRIEF_CREATED=0
DATA_DIR_EXISTED=0
[ ! -e "$DATA/$ID" ] || DATA_DIR_EXISTED=1
INBOX_EXISTED=0
[ ! -e "$(fm_task_inbox_dir "$STATE" "$ID")" ] || INBOX_EXISTED=1
META_TMP=
cleanup() {
  local lock
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  for lock in "${HELD_LOCKS[@]+"${HELD_LOCKS[@]}"}"; do
    fm_lock_release "$lock" || true
  done
}
trap cleanup EXIT
rollback() {
  fm_backlog_atomic_transition remove "$STATE/$ID.meta" "task record" "$STATE" >/dev/null 2>&1 || true
  [ "$INBOX_EXISTED" = 1 ] || rm -rf -- "$(fm_task_inbox_dir "$STATE" "$ID")"
  if [ "$BRIEF_CREATED" = 1 ]; then
    rm -f -- "$DATA/$ID/brief.md"
    [ "$DATA_DIR_EXISTED" = 1 ] || rmdir -- "$DATA/$ID" 2>/dev/null || true
  fi
}

fm_lock_try_acquire "$TASK_SET_LOCK" || die "this home's task set is locked by another operation; refusing to adopt $ID rather than racing it"
HELD_LOCKS+=("$TASK_SET_LOCK")
fm_lock_set_role "$TASK_SET_LOCK" task-spawn || die "could not mark the task-set lock for $ID"
fm_lock_try_acquire "$TASK_LOCK" || die "another spawn is already creating task $ID"
HELD_LOCKS+=("$TASK_LOCK")
fm_lock_try_acquire "$META_LOCK" || die "task $ID's record is locked by another operation"
HELD_LOCKS+=("$META_LOCK")
[ ! -e "$STATE/$ID.meta" ] || die "task $ID already has a record at $STATE/$ID.meta"
OWNER=$(fm_backend_meta_for_window "$TARGET" "$STATE" 2>/dev/null) || OWNER=
[ -z "$OWNER" ] || die "pane $TARGET is already task $(basename "$OWNER" .meta)'s endpoint"

BRIEF_ARGS=("$ID" "$(basename "$PROJ_ABS")" --adopted)
if [ "$KIND" = ship ]; then
  BRIEF_ARGS+=(--mode "$MODE" --branch "$BRANCH")
else
  BRIEF_ARGS+=(--scout)
fi
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
  "$SCRIPT_DIR/fm-brief.sh" "${BRIEF_ARGS[@]}" >/dev/null || die "could not write the brief for $ID"
BRIEF_CREATED=1

META_TMP="$STATE/.$ID.meta.adopt.${BASHPID:-$$}"
{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ_ABS"
  echo "harness=$HARNESS"
  echo "kind=$KIND"
  if [ "$KIND" = ship ]; then
    echo "mode=$MODE"
    echo "yolo=$YOLO"
    echo "branch=$BRANCH"
  fi
  echo "model=default"
  echo "effort=default"
  echo "spawn_gen=a$(date +%s).${BASHPID:-$$}.$RANDOM"
  echo "backend=herdr"
  fm_backend_herdr_endpoint_meta_lines "$SESSION" "$WORKSPACE_ID" "$TAB_ID" "$PANE"
  echo "adopted=1"
} >"$META_TMP" || { rollback; die "could not prepare the task record for $ID"; }
fm_backend_validate_task_endpoint "$META_TMP" "$ID" || { rollback; die "the prepared task record for $ID failed endpoint validation"; }
if ! fm_backlog_atomic_transition publish "$META_TMP" "$STATE/$ID.meta" "task record" "$STATE"; then
  rollback
  die "the task record for $ID could not be published ($FM_BACKLOG_TRANSITION_ERROR)"
fi
META_TMP=

if [ "$BACKLOG_ADD" = 1 ]; then
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-tasks-axi.sh" add "$ID" "$TITLE" --kind "$KIND" >/dev/null \
    || { rollback; die "could not add backlog item $ID; nothing was adopted"; }
fi
if [ "$BACKLOG_TRANSITION" = 1 ]; then
  FM_TASKS_AXI_TIMEOUT=${FM_TASKS_AXI_TIMEOUT:-30}
  if ! fm_backlog_atomic_transition dispatch "$STATE/$ID.meta" "$DATA" "$ID" "$STATE"; then
    rollback
    die "backlog item $ID could not move to In flight ($FM_BACKLOG_TRANSITION_ERROR); the record and brief were removed"
  fi
fi

CONTRACT=$(fm_brief_worker_role "$STATE" "$ID" "$FM_ROOT" && printf '\n' && cat "$DATA/$ID/brief.md") \
  || { rollback; die "could not render the worker contract for $ID"; }
RECORD=$(fm_task_inbox_write "$STATE" "$ID" "$CONTRACT") || { rollback; die "could not write the contract into $ID's steering inbox"; }
for lock in "${HELD_LOCKS[@]}"; do
  fm_lock_release "$lock" || true
done
HELD_LOCKS=()

echo "adopted $ID: pane $TARGET ($HARNESS) in $WT, kind=$KIND${MODE:+ mode=$MODE yolo=$YOLO branch=$BRANCH}"
POINTER=": Firstmate adopted this session as task $ID. Read $RECORD now and follow it, then mv it into its handled/ directory."
send_rc=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-send.sh" "$TARGET" "$POINTER" >/dev/null || send_rc=$?
case "$send_rc" in
0) echo "contract delivered: $RECORD" ;;
3) echo "warning: the pointer to $RECORD was typed into $TARGET but its submit is unconfirmed; check the pane before typing anything again" >&2 ;;
*)
  echo "error: $ID is adopted, but the pointer to its contract could not be typed into $TARGET; tell the agent to read $RECORD" >&2
  exit 1
  ;;
esac
