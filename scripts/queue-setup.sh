#!/bin/bash
# SessionStart hook: installs a user-level /queue command stub. Plugin
# commands only resolve as /prompt-queue:queue; a stub in ~/.claude/commands
# lets the bare /queue name resolve so the UserPromptSubmit hook can catch it.
STUB_SRC="${CLAUDE_PLUGIN_ROOT}/commands/queue.md"
STUB_DST="${HOME}/.claude/commands/queue.md"

if [ -f "$STUB_SRC" ] && ! cmp -s "$STUB_SRC" "$STUB_DST"; then
  mkdir -p "${HOME}/.claude/commands"
  cp -f "$STUB_SRC" "$STUB_DST"
fi
exit 0
