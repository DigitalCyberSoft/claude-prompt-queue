# claude-prompt-queue

Queue prompts in Claude Code. Type `/queue <prompt>` to queue tasks that auto-execute after the current one finishes.

<img src="demo.png" width="86%">

## Install & Usage

```
/plugin marketplace add DigitalCyberSoft/claude-prompt-queue
/plugin install prompt-queue@prompt-queue-marketplace
/reload-plugins
/queue do this
```

If `/queue` reports "Unknown command" right after installing, start a new session once — the plugin registers the bare `/queue` name at session start (`/prompt-queue:queue` always works).

Queue several tasks in one message by putting each on its own `/queue` line (lines without the prefix are appended to the task above them):

```
/queue fix the login bug
/queue add tests for it
/queue update the changelog
```

- `/queue` with no arguments lists the pending tasks
- Each time a queued task starts, a status line reports how many tasks are still queued

## How it works

- **SessionStart hook** — copies a `/queue` command stub to `~/.claude/commands/queue.md` so the bare `/queue` name resolves (unregistered slash commands are rejected before hooks run, and plugin commands only resolve as `/prompt-queue:queue`)
- **UserPromptSubmit hook** — intercepts `/queue` messages, appends them to a per-session queue file (a single JSON array), blocks them from reaching Claude
- **Stop hook** — when Claude finishes, pops the next task from the queue, injects it, and reports how many remain
- The stub's body is only ever seen by Claude if the hook fails (e.g. plugin disabled, `jq` missing); it then tells you the prompt was not queued instead of executing it

## Limitations

- Queuing only works while Claude is idle (steering messages during processing bypass hooks)
- Queued prompts show as "Stop hook error" — cosmetic only, not an actual error
- Pasted images and large text pastes can't be queued — hooks only see the `[Image #1]` placeholder, not the attachment, so a queued task runs without it (you get a warning when this happens)
- Requires `jq`
