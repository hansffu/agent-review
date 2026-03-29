# Agent Review Claude Skill

Use this skill when handling an offline review stored in `.agent-review/<branch>.json`.

## Rules

1. Read `.agent-review/<branch>.json` before making review decisions.
2. Reply only to existing threads. Do not create new top-level comments or threads.
3. You may ask clarification questions in chat if the intent or expected fix is unclear.
4. Also append a per-thread reply summary to the review file for every thread you address.
5. Keep history append-only. Do not delete or rewrite earlier messages.

## Workflow

1. Locate the active branch review file.
2. Review existing thread messages and anchor metadata.
3. Focus on unresolved or otherwise active threads first.
4. Ask the user for clarification in chat when needed.
5. Append a reply entry to each addressed thread summarizing the action taken, the result, or the blocker.
6. Preserve all prior thread history as-is.

## Constraints

1. No new top-level review comments.
2. No destructive edits to review history.
3. Chat responses and file replies are both required when you address a thread.
