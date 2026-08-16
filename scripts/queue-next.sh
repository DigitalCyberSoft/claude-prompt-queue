#!/bin/bash
# UserPromptSubmit hook: intercepts "/queue" messages and queues them
INPUT=$(cat)

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

mkdir -p "$QUEUE_DIR"
jq '. + $ARGS.positional' --args "${TASKS[@]}" <<< "$QUEUE" > "$QUEUE_FILE.tmp" \
  && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"

TOTAL=$(jq 'length' "$QUEUE_FILE")
TOTAL_NOUN=$([ "$TOTAL" -eq 1 ] && echo task || echo tasks)

if [ "${#TASKS[@]}" -eq 1 ]; then
  MSG="Queued: ${TASKS[0]%%$'\n'*} (${TOTAL} ${TOTAL_NOUN} in queue)"
else
  MSG="Queued ${#TASKS[@]} tasks (${TOTAL} in queue):"
  for T in "${TASKS[@]}"; do
    MSG+=$'\n'"  • ${T%%$'\n'*}"
  done
fi

# Pasted images/text arrive as attachments hooks can't capture — only the
# "[Image #1]"-style placeholder survives, so the task would run without them
PASTE_RE='\[(Image|Pasted text) #[0-9]+'
for T in "${TASKS[@]}"; do
  if [[ "$T" =~ $PASTE_RE ]]; then
    MSG+=$'\n'"⚠ pasted images/text can't be queued — this task will run without the attachment"
    break
  fi
done

jq -n --arg msg "$MSG" '{
  "decision": "block",
  "reason": $msg
}'
exit 0
