#!/usr/bin/env bash
# Act on one PR hygiene line from bin/fm-pr-poll.sh for a recorded task PR.
# Usage: fm-pr-hygiene.sh <task-id> <pr-url> <hygiene-line>
#
# The watcher runs this for every poll that prints
#   hygiene head=<sha> work=<tokens|-> human=<tokens|->
# (bin/fm-pr-poll.sh owns the token meanings). Work findings - review-bot
# threads, a merge conflict, failing checks, a branch behind its base - become
# one steer through bin/fm-send.sh telling the task's own worker to run
# make-it-green. Human findings - review threads, changes-requested reviews,
# and conversation comments from people - are never sent to the worker; they
# are printed as a wake reason so firstmate takes them to the captain.
#
# Each side fires once per new state. state/<id>.pr-hygiene keeps the last
# fired head and token sets; a work set fires when the head changed, a finding
# kind is new, or a kind's newest comment id grew, and a human set fires when a
# kind is new or its newest id grew. A set that only shrank, or that repeats,
# stays silent, so an unanswered finding never loops.
#
# Stdout is empty, or one wake reason line for firstmate: human review, a
# worker endpoint that is gone (no recorded target, or an agent the backend
# reports dead), or a steer fm-send could not record. The script exits 0 for
# every handled line, also when it prints nothing.
# Present config/no-pr-hygiene turns the whole feature off; the poll still
# reports merges. A secondmate record is ignored, as is a malformed line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
esac
[ "$#" -eq 3 ] || { echo "usage: fm-pr-hygiene.sh <task-id> <pr-url> <hygiene-line>" >&2; exit 2; }
ID=$1
URL=$2
LINE=$3
fm_pr_task_id_valid "$ID" || exit 2
fm_pr_url_parse "$URL" && [ "$FM_PR_URL" = "$URL" ] || exit 2

TOKEN='[a-z]+(:[0-9]+(@[0-9]+)?)?'
LIST="(-|$TOKEN(,$TOKEN)*)"
[[ $LINE =~ ^hygiene\ head=([0-9a-f]{40})\ work=$LIST\ human=$LIST$ ]] || exit 0
read -r _ head_field work_field human_field <<< "$LINE"
HEAD=${head_field#head=}
WORK=${work_field#work=}
HUMAN=${human_field#human=}

[ ! -e "$CONFIG/no-pr-hygiene" ] || exit 0
META="$STATE/$ID.meta"
[ -f "$META" ] || exit 0
[ "$(fm_meta_get "$META" kind)" != secondmate ] || exit 0

RECORD="$STATE/$ID.pr-hygiene"
LAST_HEAD=
LAST_WORK=-
LAST_HUMAN=-
if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      head) LAST_HEAD=$value ;;
      work) LAST_WORK=$value ;;
      human) LAST_HUMAN=$value ;;
    esac
  done < "$RECORD"
fi

# 0 when every token in <new> has a same-kind token in <old> with a mark at
# least as new. A token without @<id> is covered by its kind alone.
covered() {  # <new-list> <old-list>
  local tok kind mark old okind omark found
  [ "$1" != - ] || return 0
  for tok in ${1//,/ }; do
    kind=${tok%%:*}
    case "$tok" in *@*) mark=${tok##*@} ;; *) mark=0 ;; esac
    found=0
    for old in ${2//,/ }; do
      okind=${old%%:*}
      case "$old" in *@*) omark=${old##*@} ;; *) omark=0 ;; esac
      if [ "$okind" = "$kind" ] && [ "$mark" -le "$omark" ]; then
        found=1
        break
      fi
    done
    [ "$found" = 1 ] || return 1
  done
}

describe() {  # <list> <people|bot>
  local tok kind count out=
  for tok in ${1//,/ }; do
    kind=${tok%%:*}
    count=${tok#*:}
    count=${count%%@*}
    case "$2:$kind" in
      bot:threads) out="$out, $count unresolved review-bot thread(s)" ;;
      bot:conflict) out="$out, a merge conflict with the base branch" ;;
      bot:checks) out="$out, $count failing check(s) on the current head" ;;
      bot:behind) out="$out, a branch behind its base where the repository requires up-to-date branches" ;;
      people:threads) out="$out, $count unresolved review thread(s) from people" ;;
      people:changes) out="$out, $count changes-requested review(s) from people" ;;
      people:comments) out="$out, $count new conversation comment(s) from people" ;;
      *) out="$out, $kind" ;;
    esac
  done
  printf '%s' "${out#, }"
}

REASONS=
add_reason() { REASONS="${REASONS:+$REASONS; }$1"; }

if [ "$WORK" != - ] && { [ "$HEAD" != "$LAST_HEAD" ] || ! covered "$WORK" "$LAST_WORK"; }; then
  FINDINGS=$(describe "$WORK" bot)
  BACKEND=$(fm_backend_of_meta "$META")
  TARGET=$(fm_backend_target_of_meta "$META")
  if [ -z "$TARGET" ] || [ "$(fm_backend_agent_alive "$BACKEND" "$TARGET" 2>/dev/null)" = dead ]; then
    add_reason "pr-hygiene $URL needs make-it-green ($FINDINGS) but its worker is gone"
  else
    if [ "$(fm_meta_get "$META" mode)" = no-mistakes ]; then
      PUBLISH="publish the result through /no-mistakes as your delivery path requires; never push around it"
    else
      PUBLISH="push to the PR branch"
    fi
    MESSAGE="PR hygiene for $URL at head $HEAD: $FINDINGS.
Run make-it-green for this PR now: fix each valid review-bot comment, reply with a short reason to each one you do not fix, and resolve those threads; merge the PR's base branch from origin into your branch to clear a conflict or a behind branch (no rebase, no force push); fix the failing checks; $PUBLISH; then report on your status line.
Do not answer review threads or comments from people; firstmate takes those to the captain. Do not merge the PR."
    if ! FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$FM_ROOT/bin/fm-send.sh" "$ID" "$MESSAGE" >/dev/null 2>&1; then
      add_reason "pr-hygiene $URL needs make-it-green ($FINDINGS) but the steer to its worker could not be recorded"
    fi
  fi
  LAST_HEAD=$HEAD
  LAST_WORK=$WORK
fi

if [ "$HUMAN" != - ] && ! covered "$HUMAN" "$LAST_HUMAN"; then
  add_reason "pr-hygiene $URL has review from people for the captain: $(describe "$HUMAN" people)"
  LAST_HUMAN=$HUMAN
fi

TMP=$(mktemp "$STATE/.fm-pr-hygiene.XXXXXX") || exit 0
if ! printf 'head=%s\nwork=%s\nhuman=%s\n' "$LAST_HEAD" "$LAST_WORK" "$LAST_HUMAN" > "$TMP" \
  || ! mv -f -- "$TMP" "$RECORD"; then
  rm -f -- "$TMP"
fi
[ -z "$REASONS" ] || printf '%s\n' "$REASONS"
exit 0
