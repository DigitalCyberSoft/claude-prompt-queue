#!/bin/bash
# Appends tasks to a queue file. Unlike the other scripts this is run by the
# MODEL, not by a hook: messages steered into a running turn never reach
# hooks, so mid-turn "queue: <task>" requests are queued through this helper
# (the SessionStart hook injects instructions with the exact command to run).
# Usage: bash queue-add.sh <queue-file>   — message text on stdin.
. "$(dirname "$0")/queue-lib.sh"

QUEUE_FILE="${1:-}"
if [ -z "$QUEUE_FILE" ]; then
  echo "usage: queue-add.sh <queue-file>  (message text on stdin)" >&2
  exit 1
fi

MSG=$(cat)
pq_split_tasks <<< "$MSG"

# No queue:/'/queue' lines — treat the whole input as a single task
if [ "${#PQ_TASKS[@]}" -eq 0 ]; then
  pq_add_task "$MSG"
fi
if [ "${#PQ_TASKS[@]}" -eq 0 ]; then
  echo "nothing to queue: no task text on stdin" >&2
  exit 1
fi

# Plain append, not read-modify-write, so a concurrent pop can't lose tasks
mkdir -p "$(dirname "$QUEUE_FILE")"
for T in "${PQ_TASKS[@]}"; do
  printf '%s%s' "$T" "$PQ_RS" >> "$QUEUE_FILE"
done

ADDED=${#PQ_TASKS[@]}
pq_load_queue "$QUEUE_FILE"
NOUN=$([ "$ADDED" -eq 1 ] && echo task || echo tasks)
echo "Queued ${ADDED} ${NOUN} — ${#PQ_ITEMS[@]} now pending"
exit 0
