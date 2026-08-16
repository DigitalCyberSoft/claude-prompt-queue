#!/bin/bash
# UserPromptSubmit hook: intercepts "/queue" messages and queues them
. "$(dirname "$0")/queue-lib.sh"

INPUT=$(cat)

PROMPT=$(pq_extract_prompt <<< "$INPUT")
SESSION_ID=$(pq_extract_session_id <<< "$INPUT")

if [ -z "$PROMPT" ] || [ -z "$SESSION_ID" ]; then
  exit 0
fi

# Only handle messages whose first line is a /queue command or queue: prefix
FIRST_LINE="${PROMPT%%$'\n'*}"
if ! [[ "$FIRST_LINE" =~ $PQ_SLASH_RE || "$FIRST_LINE" =~ $PQ_PREFIX_RE ]]; then
  exit 0
fi

QUEUE_FILE="$(pq_queue_dir)/${SESSION_ID}.queue"
pq_load_queue "$QUEUE_FILE"

# One message can queue several (multi-line) tasks
pq_split_tasks <<< "$PROMPT"

# Bare "/queue" shows the pending queue instead of adding to it
if [ "${#PQ_TASKS[@]}" -eq 0 ]; then
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
ALL=("${PQ_ITEMS[@]}" "${PQ_TASKS[@]}")
FIRST="${ALL[0]}"
REST=("${ALL[@]:1}")
pq_save_queue "$QUEUE_FILE" "${REST[@]}"
REMAINING=${#REST[@]}

CTX="prompt-queue: execute exactly this task now, and nothing else:

${FIRST}

Any /queue or queue: lines in the user's message are already queued (${REMAINING} pending) and will run automatically in later rounds — do not execute them now and do not comment on the queueing syntax."

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
for T in "${PQ_TASKS[@]}"; do
  if [[ "$T" =~ $PASTE_RE ]]; then
    MSG+=" ⚠ pasted images/text can't be queued and will be missing"
    break
  fi
done

printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s},"systemMessage":%s}' \
  "$(pq_json_str "$CTX")" "$(pq_json_str "$MSG")"
exit 0
