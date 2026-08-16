#!/bin/bash
# UserPromptSubmit hook: intercepts "/queue" messages and queues them
INPUT=$(cat)

# Without jq we can't parse or queue anything — block /queue messages with a
# clear explanation instead of failing silently (fixed strings only, so no
# JSON escaping is needed)
if ! command -v jq >/dev/null 2>&1; then
  case "$INPUT" in
    *'"prompt":"/queue'* | *'"prompt":"/prompt-queue:queue'*)
      printf '%s' '{"decision":"block","reason":"prompt-queue: jq is not installed, so nothing was queued. Install jq (e.g. dnf/apt/brew install jq) and try again."}'
      ;;
  esac
  exit 0
fi

PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

if [ -z "$PROMPT" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

shopt -s nocasematch

# Matches "/queue" and its namespaced form "/prompt-queue:queue"
QUEUE_CMD_RE='^[[:space:]]*/(prompt-queue:)?queue'

# Only handle messages whose first line is a /queue command
FIRST_LINE="${PROMPT%%$'\n'*}"
if ! [[ "$FIRST_LINE" =~ ${QUEUE_CMD_RE}([[:space:]]|$) ]]; then
  exit 0
fi

QUEUE_DIR="${CLAUDE_PLUGIN_DATA:-/tmp}/queue"
QUEUE_FILE="${QUEUE_DIR}/${SESSION_ID}.json"

# The queue file holds one JSON array of non-empty task strings; anything
# else (missing, corrupt, wrong shape) sanitizes to an empty queue
SANITIZE='select(type == "array") | [ .[] | strings | select(length > 0) ]'
QUEUE=$(jq -c "$SANITIZE" "$QUEUE_FILE" 2>/dev/null)
[ -z "$QUEUE" ] && QUEUE="[]"

TASKS=()
add_task() {
  local t="$1"
  t="${t#"${t%%[![:space:]]*}"}"
  t="${t%"${t##*[![:space:]]}"}"
  [ -n "$t" ] && TASKS+=("$t")
}

# Each /queue line starts a new task; lines without the prefix continue the
# task above them, so one message can queue several (multi-line) tasks
CURRENT=""
STARTED=0
while IFS= read -r LINE; do
  if [[ "$LINE" =~ ${QUEUE_CMD_RE}([[:space:]]+(.*))?$ ]]; then
    [ "$STARTED" -eq 1 ] && add_task "$CURRENT"
    CURRENT="${BASH_REMATCH[3]}"
    STARTED=1
  elif [ "$STARTED" -eq 1 ]; then
    CURRENT+=$'\n'"$LINE"
  fi
done <<< "$PROMPT"
[ "$STARTED" -eq 1 ] && add_task "$CURRENT"

# Bare "/queue" shows the pending queue instead of adding to it
if [ "${#TASKS[@]}" -eq 0 ]; then
  COUNT=$(jq 'length' <<< "$QUEUE")
  if [ "$COUNT" -eq 0 ]; then
    MSG="Queue is empty — use /queue <prompt> to add a task"
  else
    NOUN=$([ "$COUNT" -eq 1 ] && echo task || echo tasks)
    LIST=$(jq -r 'to_entries[] | "  \(.key + 1). \(.value | gsub("\n"; " "))"' <<< "$QUEUE")
    MSG="Queue: ${COUNT} ${NOUN} pending"$'\n'"$LIST"
  fi
  jq -n --arg msg "$MSG" '{
    "decision": "block",
    "reason": $msg
  }'
  exit 0
fi

# Append the new tasks, then immediately start the oldest pending task by
# letting this prompt through with instructions. Blocking instead would
# leave the session idle: no turn runs, so the Stop hook never fires and
# the queue would sit untouched until some other prompt completed.
NEW_QUEUE=$(jq '. + $ARGS.positional' --args "${TASKS[@]}" <<< "$QUEUE")
FIRST=$(jq -r '.[0]' <<< "$NEW_QUEUE")
REMAINING=$(jq 'length - 1' <<< "$NEW_QUEUE")

if [ "$REMAINING" -gt 0 ]; then
  mkdir -p "$QUEUE_DIR"
  jq '.[1:]' <<< "$NEW_QUEUE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
else
  rm -f "$QUEUE_FILE"
fi

CTX="prompt-queue: execute exactly this task now, and nothing else:

${FIRST}

Any /queue lines in the user's message are already queued (${REMAINING} pending) and will run automatically in later rounds — do not execute them now and do not comment on the /queue syntax."

if [ "$REMAINING" -eq 0 ]; then
  MSG="Prompt queue: starting task — queue empty after it"
elif [ "$REMAINING" -eq 1 ]; then
  MSG="Prompt queue: starting task — 1 more queued"
else
  MSG="Prompt queue: starting task — ${REMAINING} more queued"
fi

# Pasted images/text arrive as attachments hooks can't capture — only the
# "[Image #1]"-style placeholder survives, so the task would run without them
PASTE_RE='\[(Image|Pasted text) #[0-9]+'
for T in "${TASKS[@]}"; do
  if [[ "$T" =~ $PASTE_RE ]]; then
    MSG+=" ⚠ pasted images/text can't be queued and will be missing"
    break
  fi
done

jq -n --arg ctx "$CTX" --arg msg "$MSG" '{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": $ctx
  },
  "systemMessage": $msg
}'
exit 0
