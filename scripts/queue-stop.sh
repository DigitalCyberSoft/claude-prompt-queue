#!/bin/bash
# Stop hook: pops the next prompt from the session queue, injects it, and
# reports how many tasks remain queued
. "$(dirname "$0")/queue-lib.sh"

INPUT=$(cat)

SESSION_ID=$(pq_extract_session_id <<< "$INPUT")
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

QUEUE_FILE="$(pq_queue_dir)/${SESSION_ID}.queue"
pq_load_queue "$QUEUE_FILE"

if [ "${#PQ_ITEMS[@]}" -eq 0 ]; then
  rm -f "$QUEUE_FILE"
  exit 0
fi

NEXT_PROMPT="${PQ_ITEMS[0]}"
REST=("${PQ_ITEMS[@]:1}")
pq_save_queue "$QUEUE_FILE" "${REST[@]}"
REMAINING=${#REST[@]}

if [ "$REMAINING" -eq 0 ]; then
  MSG="Prompt queue: running last queued task — queue is now empty"
elif [ "$REMAINING" -eq 1 ]; then
  MSG="Prompt queue: running next task — 1 more queued"
else
  MSG="Prompt queue: running next task — ${REMAINING} more queued"
fi

printf '{"decision":"block","reason":%s,"systemMessage":%s}' \
  "$(pq_json_str "$NEXT_PROMPT")" "$(pq_json_str "$MSG")"
exit 0
