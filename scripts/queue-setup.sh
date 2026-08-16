#!/bin/bash
# SessionStart hook: installs a user-level /queue command stub, cleans up
# stale queue files, and injects the standing instruction that makes mid-turn
# "queue: <task>" messages work (they arrive as steering messages, which
# hooks never see — the model itself must append them via queue-add.sh).
. "$(dirname "$0")/queue-lib.sh"

INPUT=$(cat)
SESSION_ID=$(pq_extract_session_id <<< "$INPUT")

# Plugin commands only resolve as /prompt-queue:queue; a stub in
# ~/.claude/commands lets the bare /queue name resolve so the
# UserPromptSubmit hook can catch it
STUB_SRC="${CLAUDE_PLUGIN_ROOT}/commands/queue.md"
STUB_DST="${HOME}/.claude/commands/queue.md"
if [ -f "$STUB_SRC" ] && ! cmp -s "$STUB_SRC" "$STUB_DST"; then
  mkdir -p "${HOME}/.claude/commands"
  cp -f "$STUB_SRC" "$STUB_DST"
fi

# Queues are per session, so files left by ended sessions are dead weight
QUEUE_DIR="$(pq_queue_dir)"
if [ -d "$QUEUE_DIR" ]; then
  find "$QUEUE_DIR" -type f -mtime +7 -delete 2>/dev/null
fi

if [ -z "$SESSION_ID" ]; then
  exit 0
fi

# The model has neither CLAUDE_PLUGIN_DATA nor the session id in its Bash
# environment, so bake the exact command into the instruction
QUEUE_FILE="${QUEUE_DIR}/${SESSION_ID}.queue"
ADD_SH="${CLAUDE_PLUGIN_ROOT}/scripts/queue-add.sh"

CTX="prompt-queue plugin: a user message starting with \"queue:\" that arrives while you are mid-task is a request to DEFER that task, not to act on it now. Append it to the prompt queue by piping the message verbatim into the helper:

bash \"${ADD_SH}\" \"${QUEUE_FILE}\" <<'PQ_EOF'
queue: the task text here
PQ_EOF

Then briefly confirm it is queued and continue the work you were doing — queued tasks run automatically in later rounds. Each line starting with \"queue:\" or \"/queue\" begins its own task; other lines continue the task above them. Exception: if the message came with a \"prompt-queue: execute exactly this task now\" hook context, the hook already queued everything — follow that context and do not run the helper."

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}' \
  "$(pq_json_str "$CTX")"
exit 0
