# Agent Review Design Spec

Date: 2026-03-29  
Status: Approved (brainstorming)

## Summary

Turn `emacs-pr-review` into a fully offline package named `agent-review` for reviewing local branch changes (typically current branch vs `main`/`master`), persisting review conversations to a local file, and enabling agent-driven follow-up using explicit skills for Codex and Claude.

## Goals

1. Rename package and user-facing commands from `pr-review` to `agent-review`.
2. Remove all provider/network integrations (GitHub, GraphQL, notifications, search, subscriptions, reviewer requests).
3. Persist review comments to disk in a per-branch review file.
4. Support session resume by loading the existing review file with prior comments.
5. Keep comments stable across new commits using commit-based anchors.
6. Support optional anchor remapping after branch updates.
7. Provide agent skill docs (Codex + Claude) that define how to read and act on the review file.

## Non-Goals

1. No online PR APIs or provider backends.
2. No MCP server in v1.
3. No separate close/reopen review lifecycle command.
4. No creation of agent-originated top-level PR comments/threads.

## Key Product Decisions

1. Offline-only: all `ghub`/GraphQL/provider code paths are removed.
2. One command: `M-x agent-review` is DWIM for create/resume/replace.
3. One review file per branch: `.agent-review/<current-branch>.json`.
4. Existing file prompt: `Continue` or `Replace`.
   - `Replace` overwrites the existing review file with a new review record in v1 (no automatic backup).
5. Base ref selection via `completing-read`:
   - Defaults to `main` or `master` when present.
   - `require-match` is `nil` to allow direct commit hash input.
6. No draft vs submitted distinction in local review state.
7. Agent behavior:
   - Can ask user questions in chat when needed.
   - Must also append thread replies in review file.
   - Must only reply to existing threads (no new top-level threads/comments).

## Chosen Approach

Adapter-first architecture: preserve the current interactive Emacs review UI where possible, but replace provider API surfaces with local git + local review-store adapters.

Why this approach:

1. Keeps familiar review UX.
2. Delivers required behavior quickly with lower regression risk.
3. Allows future MCP server by reusing the same store contract.

## Architecture

Planned modules:

1. `agent-review.el`
   - Entry command, mode bootstrap, DWIM open flow.
2. `agent-review-git.el`
   - Local diff/context extraction from git refs.
3. `agent-review-store.el`
   - Read/write `.agent-review/<branch>.json`.
   - Thread/message append APIs.
   - Remap metadata updates.
4. `agent-review-adapter.el`
   - Converts git/store data into render/action-ready objects.
5. Existing render/action/input modules
   - Renamed and adapted from `pr-review-*` to `agent-review-*`.

Remove entirely:

1. Provider API layer (`pr-review-api.el` equivalent).
2. GraphQL assets under `graphql/`.
3. Notification/search/provider-specific actions and entrypoints.

## Review Store Schema

Store location:

- `.agent-review/<branch>.json`

Top-level JSON fields:

1. `version`: schema version.
2. `review_id`: stable identifier.
3. `repo_root`: absolute repo path.
4. `branch`: reviewed branch.
5. `base_ref`: chosen base ref (`main`, `master`, branch name, or commit SHA).
6. `head_ref`: branch head at last refresh.
7. `created_at`, `updated_at`.
8. `head_commits`: ordered commit SHAs in scope.
9. `threads`: thread list.
10. `events`: system events (create, replace, remap).
11. `agent_handoff`: optional metadata for agent runs.

Thread fields:

1. `thread_id`.
2. `state`: `open` or `resolved`.
3. `anchor`.
4. `anchor_status`: `active`, `outdated`, or `remapped`.
5. `remap_history`: remap attempts and outcomes.
6. `messages`: append-only conversation entries.

Anchor fields:

1. `anchor_type`: `line_range`.
2. `base_commit`: immutable original base commit.
3. `head_commit`: immutable original head commit.
4. `path`.
5. `side`: `RIGHT` or `LEFT`.
6. `line`.
7. `start_line` (optional).
8. `diff_hunk` (snapshot for matching/remap support).

Message fields:

1. `message_id`.
2. `author_type`: `human`, `agent`, or `system`.
3. `author_id` (e.g., user handle, `codex`, `claude`).
4. `kind`: `comment`, `reply`, `resolution_note`, `agent_action`.
5. `body` (markdown).
6. `created_at`.

## `agent-review` Command Flow (DWIM)

1. Detect repo root and current branch.
2. Compute review file path `.agent-review/<branch>.json`.
3. If file exists:
   - Prompt `Continue` or `Replace`.
4. `Continue`:
   - Load file.
   - Refresh git data for current branch/base ref.
   - Recompute `anchor_status` against current head.
   - Render review with persisted threads/messages.
5. `Replace` or no existing file:
   - Prompt for base ref with `completing-read`.
   - Default to existing `main` or `master`.
   - `require-match=nil` to allow commit hashes.
   - Create fresh review file and render.

## Anchor Stability and Remap

Baseline behavior:

1. Original anchor commit context is immutable.
2. If location no longer maps at current head, mark thread `outdated`.
3. All comments remain visible regardless of status.

Optional remap command (`agent-review-remap-anchors`):

1. Build current diff mapping for `base_ref...HEAD`.
2. Try remap in priority order:
   - Exact hunk-content match.
   - Fuzzy context match.
   - Nearest-line heuristic in same file.
3. If successful:
   - Keep original anchor unchanged.
   - Record remap in `remap_history`.
   - Set `anchor_status=remapped`.
4. If unsuccessful:
   - Keep `anchor_status=outdated`.
   - Record failure in `remap_history`.

Safety rule: never silently overwrite original anchor metadata.

## UI and Action Scope

Keep:

1. Diff browsing.
2. Add/edit/reply/resolve/unresolve review-thread interactions.
3. Refresh and file/diff navigation.
4. Remap action.

Remove:

1. Merge action.
2. Request reviewers.
3. Subscription updates.
4. Provider notification dashboard.
5. Provider search entrypoints.

## Agent Skills (Codex + Claude)

Files:

1. `skills/agent-review-codex/SKILL.md`
2. `skills/agent-review-claude/SKILL.md`

Shared behavior contract:

1. Read `.agent-review/<branch>.json`.
2. Process only existing threads.
3. Prefer `open` threads; use `anchor_status` for confidence.
4. Agent may ask questions in chat when blocked/ambiguous.
5. Agent must also append per-thread replies in review file for addressed threads.
6. Agent must not create new top-level PR comments/threads.
7. Agent can mark existing threads resolved when appropriate.
8. Use append-only message semantics; do not delete history.

## MCP-Ready Interface Contract (Schema First)

Not implemented in v1, but storage semantics align with future tool operations:

1. `list_reviews`
2. `get_review(review_id)`
3. `list_threads(review_id, filters)`
4. `reply_thread(review_id, thread_id, body, author)`
5. `set_thread_state(review_id, thread_id, state)`
6. `remap_anchors(review_id, target_head)`

v1 skills operate via file edits using these same logical semantics.

## Migration Plan

1. Introduce `agent-review-*` modules and command entrypoint.
2. Add store + git + adapter layers.
3. Port rendering/actions to local data backend.
4. Remove provider modules and dependencies (`ghub`, GraphQL files, provider commands).
5. Update README and package metadata for new command names and offline workflow.
6. Add skill docs and examples.

## Verification Strategy

1. ERT/unit tests for store schema read/write and append-only thread replies.
2. Unit tests for base-ref selection defaults and free-form commit hash input.
3. Integration tests for `agent-review` DWIM:
   - create new review
   - continue existing review
   - replace existing review
4. Anchor status tests:
   - active
   - outdated after new commit
   - remapped after remap command
5. Manual UX checks for inline review interactions in Emacs buffer.

## Risks and Mitigations

1. Remap false positives:
   - Mitigation: conservative matching and explicit remap history with confidence.
2. Large review files:
   - Mitigation: structured JSON with bounded thread payloads and optional compaction later.
3. Migration churn from rename:
   - Mitigation: staged refactor with compatibility aliases during transition period.

## Acceptance Criteria

1. Package functions without any network/provider dependency.
2. `M-x agent-review` handles create/continue/replace in one flow.
3. Existing review comments persist and resume correctly from file.
4. Comments remain traceable by commit-based anchors; outdated status shown when needed.
5. Optional remap updates visible mapping without losing original anchor context.
6. Agent skills for Codex and Claude exist and enforce reply-only thread behavior.
