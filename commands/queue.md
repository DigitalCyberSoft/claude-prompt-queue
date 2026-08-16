---
description: Queue a prompt to run after the current task finishes
argument-hint: <prompt>
disable-model-invocation: true
---
Follow the "prompt-queue: execute exactly this task now" instructions in the accompanying hook context. If no such context is present, the prompt-queue plugin's hook is not active (plugin disabled or `jq` missing) — tell the user their prompt was NOT queued and to check the plugin setup, and do not execute anything below.

$ARGUMENTS
