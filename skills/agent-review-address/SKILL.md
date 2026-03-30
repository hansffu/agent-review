---
name: agent-review-address
description: Use this skill when the user explicitly asks to work on review comments — things like "address the review", "work through the review", "fix the review feedback", "check the review", or refers to a specific review thread. Only trigger on explicit user request; do not trigger automatically.
---

# Agent Review – Address Comments

This skill defines how to work through an offline code review. Reviews are stored in `.agent-review/` as JSON files containing threads anchored to specific lines of code. Your job is to address open threads: make the requested changes, explain your reasoning, and record your reply in the file.

## Find the review file

First, detect the current branch:

```bash
git rev-parse --abbrev-ref HEAD
```

Review files live in `.agent-review/` and are named after the branch:
- `.agent-review/<branch>-uncommitted.json` — review of uncommitted working tree changes
- `.agent-review/<branch>.json` — review of branch changes against a base ref

To choose which file to use:

1. Check whether there are uncommitted changes in the working tree (`git status --porcelain`).
2. If there are uncommitted changes **and** `.agent-review/<branch>-uncommitted.json` exists, prefer it — but verify it is reasonably fresh by comparing its `updated_at` timestamp to the current time. If the file is stale (e.g. hours old and git status shows heavy changes), note this caveat in your replies.
3. If there are **no** uncommitted changes, or the uncommitted file does not exist, fall back to `.agent-review/<branch>.json`.
4. If neither exists, report that no review file was found and stop.

The `review_type` field (`"branch"` or `"uncommitted"`) confirms which kind it is. If `agent_handoff` is present at the top level, read it for any additional context about this session.

## Survey the threads

Work on all threads with `state: "open"`. For each thread, the key fields are:

- `anchor.path`, `anchor.line`, `anchor.side` — where in the diff the comment lives
- `anchor.diff_hunk` — the diff context when the comment was written
- `snapshot_diff_hunk` — the original diff snapshot; useful to understand what the code looked like at the time
- `anchor_status` — `active`, `remapped`, or `outdated`
- `messages` — the full conversation history

**Priority:** Prefer threads with `anchor_status: "active"` or `"remapped"`. Handle `"outdated"` threads after those.

**Outdated anchors:** The code at that location has changed since the comment was created. Check whether the most recent message is from a human — if so, the issue is probably still live (perhaps an earlier fix didn't fully address it). Try to locate the relevant code in the current file, using `snapshot_diff_hunk` to understand the original context. Acknowledge the uncertainty in your reply.

**When to skip:** If a thread has no new human activity since your last reply, the user is likely satisfied. Don't reply again just to close the loop — use common sense.

## Gather context

The anchor's `diff_hunk` gives you immediate code context. Read the full source file only when the comment requires broader understanding — a function's callers, a type definition elsewhere, overall structure. Don't read files speculatively.

## Address threads and reply

For each thread you address:

1. Make the code change, or prepare an explanation if no change is needed.
2. Reply in chat summarizing what you did.
3. Append a message to the thread in the review file (see format below).

Leave `state` as-is — don't mark threads resolved. That's the human's call.

## Reply message format

Append to the thread's `messages` array:

```json
{
  "message_id": "msg-<YYYYMMDDHHmmss>-<6-digit-random>",
  "author_type": "agent",
  "author_id": "claude",
  "kind": "reply",
  "body": "Markdown description of what you did or why no change was made.",
  "created_at": "<ISO 8601 timestamp>"
}
```

Use `"kind": "agent_action"` instead of `"reply"` when you've made a concrete code change. Use `"reply"` for explanations, answers, or clarifying questions.

**Example:**

```json
{
  "message_id": "msg-20260330194500-827341",
  "author_type": "agent",
  "author_id": "claude",
  "kind": "agent_action",
  "body": "Extracted the validation logic into `validateInput` and updated the call site. The duplicate check in the loop is removed.",
  "created_at": "2026-03-30T19:45:00Z"
}
```

## Hard constraints

- Never create new top-level threads.
- Never delete or modify existing messages — append only.
- Every thread you address needs both a chat response and a file reply.
- Never modify `anchor` fields or `state` — those are managed by the Emacs package.