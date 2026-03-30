# Agent Review Codex Skill

Use this skill when working on an offline review stored in `.agent-review/<branch>.json` or `.agent-review/<branch>-uncommitted.json`.

## Rules

1. Read the current review file before taking action. Check for both `<branch>.json` and `<branch>-uncommitted.json`. Use the `review_type` field to determine the type.
2. Only reply to existing threads. Do not create new top-level comments or threads.
3. You may ask clarification questions in chat when the code or requested outcome is ambiguous.
4. For each addressed thread, append a per-thread reply summary into the review file.
5. Preserve append-only history. Never delete or rewrite prior messages.

## Workflow

1. Detect the current branch and look for review files: `.agent-review/<branch>.json` and `.agent-review/<branch>-uncommitted.json`.
2. Filter to existing threads, prioritizing `open` threads.
3. Inspect the thread anchor, current messages, and any `anchor_status` or `remap_history`. Note: uncommitted reviews (`review_type: "uncommitted"`) always mark threads as outdated on refresh — remap is attempted automatically.
4. If blocked, ask the user a direct clarification question in chat.
5. When responding to a thread, append a new reply entry describing what changed or why no change was made.
6. Leave untouched threads untouched.

## Constraints

1. No new top-level review comments.
2. No history rewriting.
3. Replies in chat do not replace replies in the review file; do both when you act on a thread.
