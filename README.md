# Emacs Agent Review

Review local branch changes from Emacs.

![](images/overview.png)

## Status

This project is still a work in progress (WIP).

It is a vibe-coded rewrite of `pr-review` to support local review of AI-generated code.

## Credits

`agent-review` builds on `pr-review` by Yikai Zhao.
Original project: <https://github.com/blahgeek/emacs-pr-review>

## Install

MELPA release pending. Load this package from a local checkout for now.

## Usage

`M-x agent-review` opens an offline review for the current git branch.

The command will:

1. detect the repository root and current branch
2. read or create `.agent-review/<branch>.json`
3. if a review file already exists, prompt for `Continue` or `Replace`
4. when creating or replacing, prompt for a base ref and default to `main` or `master` when present
5. render the review metadata, thread summary, and full `base..HEAD` diff

Suggested config:

```elisp
(evil-ex-define-cmd "prr" #'agent-review)
```

## Offline Review File

Each branch gets its own review file under `.agent-review/`.
Comments, replies, and thread state changes are persisted immediately.

## Keybindings

- `C-c C-r`: refresh the current review from git and disk
- `C-c C-c`: reply when point is on a thread, or create a new thread when point is on a diff line
- `C-c C-s`: toggle the thread at point between `open` and `resolved`
- `C-c C-m`: remap stale anchors against the current `base..HEAD` diff

## Workflow Notes

- Start from the branch you want to review.
- Use `Continue` to resume an existing local review.
- Use `Replace` to create a fresh review against a new base ref while keeping a new review record on disk.
- Run `agent-review-remap-anchors` after the branch moves forward to update stale thread anchors or mark them outdated.
