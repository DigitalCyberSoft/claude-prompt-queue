---
description: Queue a prompt to run after the current task finishes
argument-hint: <prompt>
disable-model-invocation: true
---
The prompt-queue hook did not intercept this command, so nothing was queued. Either the prompt-queue plugin is not installed/enabled, or its UserPromptSubmit hook failed (for example, `jq` is missing). Tell the user their prompt was NOT queued and to check the plugin setup, then stop. Do not execute the prompt below.

$ARGUMENTS
