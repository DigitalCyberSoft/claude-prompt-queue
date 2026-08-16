#!/bin/bash
# Stop hook: pops the next prompt from the session queue, injects it, and
# reports how many tasks remain queued
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

QUEUE_DIR="${CLAUDE_PLUGIN_DATA:-/tmp}/queue"
QUEUE_FILE="${QUEUE_DIR}/${SESSION_ID}.json"

if [ ! -f "$QUEUE_FILE" ]; then
  exit 0
fi

# The queue file holds one JSON array of non-empty task strings; anything
# else (missing, corrupt, wrong shape) sanitizes to an empty queue
SANITIZE='select(type == "array") | [ .[] | strings | select(length > 0) ]'
QUEUE=$(jq -c "$SANITIZE" "$QUEUE_FILE" 2>/dev/null)
[ -z "$QUEUE" ] && QUEUE="[]"

if [ "$(jq 'length' <<< "$QUEUE")" -eq 0 ]; then
  rm -f "$QUEUE_FILE"
  exit 0
fi

NEXT_PROMPT=$(jq -r '.[0]' <<< "$QUEUE")
REMAINING=$(jq 'length - 1' <<< "$QUEUE")

if [ "$REMAINING" -gt 0 ]; then
  jq '.[1:]' <<< "$QUEUE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
else
  rm -f "$QUEUE_FILE"
fi

if [ "$REMAINING" -eq 0 ]; then
  MSG="Prompt queue: running last queued task — queue is now empty"
elif [ "$REMAINING" -eq 1 ]; then
  MSG="Prompt queue: running next task — 1 more queued"
else
  MSG="Prompt queue: running next task — ${REMAINING} more queued"
fi

jq -n --arg prompt "$NEXT_PROMPT" --arg msg "$MSG" '{
  "decision": "block",
  "reason": $prompt,
  "systemMessage": $msg
}'
exit 0
