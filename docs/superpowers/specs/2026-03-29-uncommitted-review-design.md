# Uncommitted Changes Review

**Goal:** Allow `agent-review` to review uncommitted (staged + unstaged) changes, with the option appearing in the existing base-ref completing-read when uncommitted changes are present.

**Approach:** Diff-source layer — extend the git helpers to handle uncommitted diffs, add `review_type` to the store schema, and adjust the entry point flow. Rendering and threading remain unchanged.

---

## Store / File Format

The schema gains a `review_type` field:

- `"branch"` (default) — existing behavior, inferred when absent for backwards compatibility
- `"uncommitted"` — uncommitted working tree review

Uncommitted review shape:

```json
{
  "version": 1,
  "review_type": "uncommitted",
  "review_id": "review-...",
  "repo_root": "/path/to/repo",
  "branch": "my-feature",
  "base_ref": null,
  "head_ref": null,
  "head_commits": [],
  "threads": [],
  "events": []
}
```

File path: `.agent-review/<branch>-uncommitted.json`

## Git Layer

Extend existing functions rather than adding new ones:

- `agent-review-git-unified-diff`: when `base-ref` is nil, run `git diff HEAD` instead of `git diff <base-ref>..HEAD`.
- `agent-review-git-changed-files`: same nil-dispatch pattern.
- `agent-review-git-diff-summary`: same nil-dispatch pattern.
- `agent-review-git-commit-headlines`: return nil when base-ref is nil.
- `agent-review-git-commit-list`: return nil when base-ref is nil.

New helper:

- `agent-review-git-has-uncommitted-changes`: quick check via `git diff HEAD --quiet`, returns non-nil if working tree has uncommitted changes.

Extend `agent-review-git-prompt-base-ref`: if `agent-review-git-has-uncommitted-changes` returns non-nil, prepend `"uncommitted"` to the completion list and make it the default.

## Entry Point

The `agent-review` function changes:

1. Prompt for base-ref **first** (moved out of `agent-review--create-review`), since the choice determines the review file path and type.
2. If `"uncommitted"` is selected:
   - Review file: `.agent-review/<branch>-uncommitted.json`
   - Create/load review with `review_type: "uncommitted"`, `base_ref: nil`, `head_ref: nil`
   - Diff via `agent-review-git-unified-diff` with nil base-ref
3. If a branch ref is selected:
   - Existing flow, unchanged.

Continue/Replace prompt still applies to uncommitted reviews when the file already exists.

## Anchors and Remap

- Anchors in uncommitted reviews store `head_commit: nil` and `base_commit` as the resolved HEAD hash at comment time.
- `agent-review--recompute-thread-status` treats `head_commit: nil` as always potentially stale — triggers remap on every refresh.
- `agent-review--collect-diff-anchors` and `agent-review--remap-thread` work unchanged — they operate on diff text regardless of source.
- `agent-review--refresh-review-state` skips updating `head_ref` and `head_commits` for uncommitted reviews (they stay nil/empty).

## Rendering

- Header shows `"Uncommitted changes"` instead of branch-to-base arrow for uncommitted reviews.
- Commits section is hidden for uncommitted reviews.
- Diff section, thread rendering, inline threads, comment/reply/resolve actions — all unchanged.
