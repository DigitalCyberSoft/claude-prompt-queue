#!/bin/bash
# UserPromptSubmit hook: intercepts "/queue" messages and queues them
. "$(dirname "$0")/queue-lib.sh"

INPUT=$(cat)

PROMPT=$(pq_extract_prompt <<< "$INPUT")
SESSION_ID=$(pq_extract_session_id <<< "$INPUT")

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

QUEUE_FILE="$(pq_queue_dir)/${SESSION_ID}.queue"
pq_load_queue "$QUEUE_FILE"

TASKS=()
add_task() {
  local t="$1"
  t="${t//$PQ_RS/}"
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
  COUNT=${#PQ_ITEMS[@]}
  if [ "$COUNT" -eq 0 ]; then
    MSG="Queue is empty — use /queue <prompt> to add a task"
  else
    NOUN=$([ "$COUNT" -eq 1 ] && echo task || echo tasks)
    MSG="Queue: ${COUNT} ${NOUN} pending"
    I=0
    for ITEM in "${PQ_ITEMS[@]}"; do
      I=$((I + 1))
      MSG+=$'\n'"  ${I}. ${ITEM//$'\n'/ }"
    done
  fi
  printf '{"decision":"block","reason":%s}' "$(pq_json_str "$MSG")"
  exit 0
fi

# Append the new tasks, then immediately start the oldest pending task by
# letting this prompt through with instructions. Blocking instead would
# leave the session idle: no turn runs, so the Stop hook never fires and
# the queue would sit untouched until some other prompt completed.
ALL=("${PQ_ITEMS[@]}" "${TASKS[@]}")
FIRST="${ALL[0]}"
REST=("${ALL[@]:1}")
pq_save_queue "$QUEUE_FILE" "${REST[@]}"
REMAINING=${#REST[@]}

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

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s},"systemMessage":%s}' \
  "$(pq_json_str "$CTX")" "$(pq_json_str "$MSG")"
exit 0
