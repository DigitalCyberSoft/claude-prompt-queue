#!/bin/bash
# Test suite for the prompt-queue hook scripts.
# Needs bash, awk, sed (what the plugin itself uses) plus python3 as the
# JSON oracle for building hook input and validating hook output.
set -u
cd "$(dirname "$0")/.."

export CLAUDE_PLUGIN_DATA="$(mktemp -d)"
trap 'rm -rf "$CLAUDE_PLUGIN_DATA"' EXIT
SID="test-session"
QF="$CLAUDE_PLUGIN_DATA/queue/$SID.queue"
RS=$'\x1e'

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }

mkin() {
  python3 - "$1" "$SID" <<'PY'
import json, sys
print(json.dumps({"session_id": sys.argv[2], "transcript_path": "/x.jsonl",
                  "cwd": "/tmp", "hook_event_name": "UserPromptSubmit",
                  "prompt": sys.argv[1]}, separators=(",", ":"), ensure_ascii=False))
PY
}
stopin() { printf '{"session_id":"%s","hook_event_name":"Stop"}' "$SID"; }
jfield() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
print(d, end="")' "$1"
}
jvalid() { python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null; }

echo "== single task on empty queue starts immediately =="
rm -f "$QF"
OUT=$(mkin '/queue say hello' | bash scripts/queue-next.sh)
printf '%s' "$OUT" | jvalid; check $? "output is valid JSON"
CTX=$(printf '%s' "$OUT" | jfield hookSpecificOutput.additionalContext)
case "$CTX" in *"say hello"*) ok "context contains the task";; *) bad "context contains the task";; esac
SM=$(printf '%s' "$OUT" | jfield systemMessage)
[ "$SM" = "Prompt queue: starting task — queue empty after it" ]; check $? "systemMessage reports empty queue"
[ ! -f "$QF" ]; check $? "no queue file left behind"

echo "== multi-line message: several tasks, continuation, namespaced form =="
rm -f "$QF"
OUT=$(mkin $'/queue first task\nwith continuation\n/prompt-queue:queue second task\n/queue' | bash scripts/queue-next.sh)
SM=$(printf '%s' "$OUT" | jfield systemMessage)
[ "$SM" = "Prompt queue: starting task — 1 more queued" ]; check $? "one task queued behind the started one"
CTX=$(printf '%s' "$OUT" | jfield hookSpecificOutput.additionalContext)
case "$CTX" in *$'first task\nwith continuation'*) ok "continuation line kept in task";; *) bad "continuation line kept in task";; esac
[ "$(cat "$QF")" = "second task$RS" ]; check $? "queue file holds second task with record separator"

echo "== FIFO: oldest pending task starts first =="
printf 'old task%s' "$RS" > "$QF"
OUT=$(mkin '/queue new task' | bash scripts/queue-next.sh)
CTX=$(printf '%s' "$OUT" | jfield hookSpecificOutput.additionalContext)
case "$CTX" in *"old task"*) ok "pre-existing task starts";; *) bad "pre-existing task starts";; esac
[ "$(cat "$QF")" = "new task$RS" ]; check $? "new task waits in the file"

echo "== bare /queue lists pending tasks =="
OUT=$(mkin '/queue' | bash scripts/queue-next.sh)
printf '%s' "$OUT" | jvalid; check $? "status output is valid JSON"
[ "$(printf '%s' "$OUT" | jfield decision)" = "block" ]; check $? "status blocks the prompt"
REASON=$(printf '%s' "$OUT" | jfield reason)
case "$REASON" in "Queue: 1 task pending"*"1. new task"*) ok "status lists the task";; *) bad "status lists the task";; esac
rm -f "$QF"
REASON=$(mkin '/queue' | bash scripts/queue-next.sh | jfield reason)
case "$REASON" in "Queue is empty"*) ok "empty queue status";; *) bad "empty queue status";; esac

echo "== hostile content round-trips byte-exact through next -> file -> stop =="
rm -f "$QF"
NASTY1='say "hello \n world" with back\slash	and a tab'
NASTY2=$'multi line first\nsecond with émoji 🎉 and '\''quotes'\''\nthird'
OUT=$(mkin $'/queue starter\n/queue '"$NASTY1"$'\n/queue '"$NASTY2" | bash scripts/queue-next.sh)
printf '%s' "$OUT" | jvalid; check $? "queueing output is valid JSON"
OUT=$(stopin | bash scripts/queue-stop.sh)
printf '%s' "$OUT" | jvalid; check $? "stop output is valid JSON"
[ "$(printf '%s' "$OUT" | jfield reason)" = "$NASTY1" ]; check $? "quotes/backslash/literal-\\n/tab exact"
[ "$(printf '%s' "$OUT" | jfield systemMessage)" = "Prompt queue: running next task — 1 more queued" ]; check $? "stop reports remaining count"
OUT=$(stopin | bash scripts/queue-stop.sh)
[ "$(printf '%s' "$OUT" | jfield reason)" = "$NASTY2" ]; check $? "multi-line/emoji task exact"
[ "$(printf '%s' "$OUT" | jfield systemMessage)" = "Prompt queue: running last queued task — queue is now empty" ]; check $? "stop reports empty queue"
[ ! -f "$QF" ]; check $? "queue file removed when drained"

echo "== stop hook is silent with nothing queued =="
OUT=$(stopin | bash scripts/queue-stop.sh)
[ -z "$OUT" ]; check $? "no output on empty queue"

echo "== non-queue prompts pass through untouched =="
OUT=$(mkin 'hello /queue not at start' | bash scripts/queue-next.sh)
[ -z "$OUT" ]; check $? "normal prompt ignored"
OUT=$(stopin | bash scripts/queue-next.sh)
[ -z "$OUT" ]; check $? "input without prompt field ignored"

echo "== /QUEUE is case-insensitive =="
rm -f "$QF"
OUT=$(mkin '/QUEUE shout task' | bash scripts/queue-next.sh)
CTX=$(printf '%s' "$OUT" | jfield hookSpecificOutput.additionalContext)
case "$CTX" in *"shout task"*) ok "uppercase prefix accepted";; *) bad "uppercase prefix accepted";; esac

echo "== pasted-attachment placeholder warns =="
rm -f "$QF"
SM=$(mkin '/queue describe [Image #1] please' | bash scripts/queue-next.sh | jfield systemMessage)
case "$SM" in *"pasted images/text can't be queued"*) ok "warning present";; *) bad "warning present";; esac

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
