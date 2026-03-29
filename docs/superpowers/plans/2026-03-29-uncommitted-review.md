# Uncommitted Changes Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow `agent-review` to review uncommitted (staged + unstaged) working tree changes, with "uncommitted" appearing as the default option in the base-ref prompt when uncommitted changes exist.

**Architecture:** Extend the git helpers to dispatch on nil base-ref for uncommitted diffs, add `review_type` to the store schema, restructure the entry point to select the review target before determining the file path, and adjust rendering to hide commit-specific sections for uncommitted reviews. Anchors use `head_commit = nil` and are remapped on every refresh.

**Tech Stack:** Emacs Lisp, ERT, local Git CLI, JSON.

---

## File Structure and Responsibilities

1. `agent-review-git.el` (modify): extend diff/changed-files/summary functions to accept nil base-ref for uncommitted mode; add `agent-review-git-has-uncommitted-changes` helper; extend `agent-review-git-prompt-base-ref` to prepend "uncommitted" when changes exist.
2. `agent-review-store.el` (modify): add `review_type` field to `agent-review-store-create`; add `agent-review-store-uncommitted-review-file` helper; default `review_type` to `"branch"` on read when absent.
3. `agent-review.el` (modify): restructure entry point to prompt for target first; dispatch to uncommitted or branch flow; adjust anchor creation, refresh, and rendering for uncommitted reviews.
4. `skills/agent-review-claude/SKILL.md` (modify): document uncommitted review file path.
5. `skills/agent-review-codex/SKILL.md` (modify): document uncommitted review file path.
6. `tests/agent-review-git-test.el` (modify): add tests for nil base-ref dispatch and uncommitted detection.
7. `tests/agent-review-store-test.el` (modify): add tests for uncommitted review creation and file path.
8. `tests/agent-review-entrypoint-test.el` (modify): add tests for uncommitted entry point flow.

### Task 1: Extend Git Layer for Uncommitted Diffs

**Files:**
- Modify: `agent-review-git.el`
- Modify: `tests/agent-review-git-test.el`

- [ ] **Step 1: Write failing tests for nil base-ref dispatch and uncommitted detection**

Add these tests to `tests/agent-review-git-test.el`:

```elisp
(ert-deftest agent-review-git-nil-base-ref-returns-uncommitted-diff ()
  "Nil base-ref should produce a diff of uncommitted changes."
  (agent-review-test-with-temp-repo (repo)
    ;; Add uncommitted change
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((diff (agent-review-git-unified-diff repo nil)))
      (should (stringp diff))
      (should (string-match-p "three" diff)))))

(ert-deftest agent-review-git-nil-base-ref-changed-files ()
  "Nil base-ref should list uncommitted changed files."
  (agent-review-test-with-temp-repo (repo)
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((files (agent-review-git-changed-files repo nil)))
      (should (equal 1 (length files)))
      (should (equal "demo.txt" (alist-get 'path (car files)))))))

(ert-deftest agent-review-git-nil-base-ref-diff-summary ()
  "Nil base-ref should return summary of uncommitted changes."
  (agent-review-test-with-temp-repo (repo)
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((summary (agent-review-git-diff-summary repo nil)))
      (should (equal 1 (alist-get 'files summary)))
      (should (equal 1 (alist-get 'additions summary))))))

(ert-deftest agent-review-git-nil-base-ref-commit-list-returns-nil ()
  "Nil base-ref should return nil for commit list and headlines."
  (agent-review-test-with-temp-repo (repo)
    (should (null (agent-review-git-commit-list repo nil)))
    (should (null (agent-review-git-commit-headlines repo nil)))))

(ert-deftest agent-review-git-has-uncommitted-changes ()
  "Detects uncommitted changes in the working tree."
  (agent-review-test-with-temp-repo (repo)
    (should-not (agent-review-git-has-uncommitted-changes repo))
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (should (agent-review-git-has-uncommitted-changes repo))))

(ert-deftest agent-review-git-prompt-base-ref-includes-uncommitted ()
  "Uncommitted option appears first when uncommitted changes exist."
  (let ((captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection predicate require-match initial hist def inherit)
                 (setq captured (list prompt collection predicate require-match initial hist def inherit))
                 "uncommitted")))
      (agent-review-test-with-temp-repo (repo)
        (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
        (should (equal "uncommitted" (agent-review-git-prompt-base-ref repo)))))
    ;; "uncommitted" should be first in the collection
    (should (equal "uncommitted" (car (nth 1 captured))))
    ;; "uncommitted" should be the default
    (should (equal "uncommitted" (nth 6 captured)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-git-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `agent-review-git-has-uncommitted-changes` is void, nil base-ref causes format errors.

- [ ] **Step 3: Implement nil base-ref dispatch in git functions**

In `agent-review-git.el`, make these changes:

Add the `agent-review-git--diff-ref` helper after the existing `agent-review-git-rev-parse` function:

```elisp
(defun agent-review-git--diff-ref (base-ref)
  "Return the git diff ref argument for BASE-REF.
When BASE-REF is nil, returns \"HEAD\" for uncommitted changes.
Otherwise returns \"BASE-REF..HEAD\"."
  (if base-ref (format "%s..HEAD" base-ref) "HEAD"))
```

Update `agent-review-git-unified-diff` — replace `(format "%s..HEAD" base-ref)` with `(agent-review-git--diff-ref base-ref)`:

```elisp
(defun agent-review-git-unified-diff (repo-root base-ref)
  "Return the unified diff for BASE-REF..HEAD in REPO-ROOT.
When BASE-REF is nil, returns the diff of uncommitted changes against HEAD."
  (agent-review-git--call repo-root "diff" "--no-color" "--no-ext-diff" "--unified=3"
                          (agent-review-git--diff-ref base-ref)))
```

Update `agent-review-git-changed-files` — replace `(format "%s..HEAD" base-ref)` with `(agent-review-git--diff-ref base-ref)`:

```elisp
(defun agent-review-git-changed-files (repo-root base-ref)
  "Return changed files for BASE-REF..HEAD or uncommitted changes in REPO-ROOT."
  (mapcar
   (lambda (line)
     (let* ((parts (split-string line "\t"))
            (status (car parts))
            (path (cond
                   ((and (string-prefix-p "R" status) (= (length parts) 3))
                    (format "%s -> %s" (nth 1 parts) (nth 2 parts)))
                   ((>= (length parts) 2)
                    (nth 1 parts))
                   (t (or (cadr parts) "")))))
       `((status . ,status)
         (path . ,path))))
   (agent-review-git--lines repo-root "diff" "--name-status" "--no-color"
                            (agent-review-git--diff-ref base-ref))))
```

Update `agent-review-git-diff-summary` — replace `(format "%s..HEAD" base-ref)` with `(agent-review-git--diff-ref base-ref)`:

```elisp
(defun agent-review-git-diff-summary (repo-root base-ref)
  "Return diff summary counts for BASE-REF..HEAD or uncommitted changes in REPO-ROOT."
  (let ((files 0)
        (additions 0)
        (deletions 0))
    (dolist (line (agent-review-git--lines repo-root "diff" "--numstat" "--no-color"
                                           (agent-review-git--diff-ref base-ref)))
      (pcase-let* ((`(,additions-str ,deletions-str . ,_) (split-string line "\t"))
                   (binary-file (or (equal additions-str "-")
                                    (equal deletions-str "-"))))
        (setq files (1+ files))
        (unless binary-file
          (setq additions (+ additions (string-to-number additions-str))
                deletions (+ deletions (string-to-number deletions-str))))))
    `((files . ,files)
      (additions . ,additions)
      (deletions . ,deletions))))
```

Update `agent-review-git-commit-list` — return nil when base-ref is nil:

```elisp
(defun agent-review-git-commit-list (repo-root base-ref)
  "Return commits in BASE-REF..HEAD for REPO-ROOT.
Returns nil when BASE-REF is nil."
  (when base-ref
    (agent-review-git--lines repo-root "rev-list" "--reverse" (format "%s..HEAD" base-ref))))
```

Update `agent-review-git-commit-headlines` — return nil when base-ref is nil:

```elisp
(defun agent-review-git-commit-headlines (repo-root base-ref)
  "Return commit headlines in BASE-REF..HEAD for REPO-ROOT.
Returns nil when BASE-REF is nil."
  (when base-ref
    (mapcar
     (lambda (line)
       (pcase-let ((`(,short ,subject)
                    (split-string line "\t" t)))
         `((short . ,short)
           (subject . ,subject))))
     (agent-review-git--lines repo-root "log" "--format=%h%x09%s"
                              (format "%s..HEAD" base-ref)))))
```

Add the new helper after `agent-review-git-default-base-ref`:

```elisp
(defun agent-review-git-has-uncommitted-changes (&optional repo-root)
  "Return non-nil if REPO-ROOT has uncommitted changes against HEAD."
  (let ((default-directory (or repo-root default-directory)))
    (not (eq 0 (process-file "git" nil nil nil "diff" "--quiet" "HEAD")))))
```

Update `agent-review-git-prompt-base-ref` to prepend "uncommitted" when changes exist:

```elisp
(defun agent-review-git-prompt-base-ref (&optional repo-root)
  "Prompt for a base ref in REPO-ROOT with free-form input enabled.
When uncommitted changes exist, \"uncommitted\" is offered as the default."
  (let* ((refs (agent-review-git-local-refs repo-root))
         (has-uncommitted (agent-review-git-has-uncommitted-changes repo-root))
         (candidates (if has-uncommitted (cons "uncommitted" refs) refs))
         (default (if has-uncommitted
                      "uncommitted"
                    (agent-review-git-default-base-ref repo-root))))
    (completing-read
     (if default
         (format "Base ref (default %s): " default)
       "Base ref: ")
     candidates
     nil
     nil
     nil
     nil
     default
     nil)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-git-test.el -f ert-run-tests-batch-and-exit`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-review-git.el tests/agent-review-git-test.el
git commit --author="Claude <claude@anthropic.com>" -m "feat: extend git layer for uncommitted diffs"
```

### Task 2: Extend Store for Uncommitted Reviews

**Files:**
- Modify: `agent-review-store.el`
- Modify: `tests/agent-review-store-test.el`

- [ ] **Step 1: Write failing tests for uncommitted store features**

Add these tests to `tests/agent-review-store-test.el`:

```elisp
(ert-deftest agent-review-store-create-with-review-type ()
  "Reviews should include review_type field."
  (let ((branch-review (agent-review-store-create "/tmp/repo" "feat" "main" "deadbeef" '("deadbeef"))))
    (should (equal "branch" (alist-get 'review_type branch-review))))
  (let ((uncommitted-review (agent-review-store-create "/tmp/repo" "feat" nil nil nil "uncommitted")))
    (should (equal "uncommitted" (alist-get 'review_type uncommitted-review)))
    (should (null (alist-get 'base_ref uncommitted-review)))
    (should (null (alist-get 'head_ref uncommitted-review)))
    (should (null (alist-get 'head_commits uncommitted-review)))))

(ert-deftest agent-review-store-read-infers-branch-type ()
  "Reading a review without review_type should default to branch."
  (let* ((repo (make-temp-file "agent-review-store-" t))
         (file (agent-review-store-review-file repo "feat"))
         (review (agent-review-store-create repo "feat" "main" "deadbeef" '("deadbeef"))))
    (unwind-protect
        (progn
          ;; Remove review_type to simulate old format
          (setq review (assq-delete-all 'review_type review))
          (agent-review-store-write file review)
          (let ((loaded (agent-review-store-read file)))
            (should (equal "branch" (alist-get 'review_type loaded)))))
      (delete-directory repo t))))

(ert-deftest agent-review-store-uncommitted-review-file ()
  "Uncommitted review file uses branch-uncommitted.json."
  (let ((file (agent-review-store-uncommitted-review-file "/tmp/repo" "feat")))
    (should (string-match-p "feat-uncommitted\\.json$" file))
    (should (string-match-p "\\.agent-review/" file))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-store-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — `agent-review-store-create` doesn't accept `review_type` arg, `agent-review-store-uncommitted-review-file` is void.

- [ ] **Step 3: Implement store changes**

In `agent-review-store.el`, update `agent-review-store-create` to accept an optional `review-type` parameter:

```elisp
(defun agent-review-store-create (repo-root branch base-ref head-ref head-commits &optional review-type)
  "Create a new review for REPO-ROOT, BRANCH, BASE-REF, HEAD-REF and HEAD-COMMITS.
REVIEW-TYPE is \"branch\" (default) or \"uncommitted\"."
  (let ((now (agent-review-store--now)))
    (list
     (cons 'version agent-review-store-version)
     (cons 'review_type (or review-type "branch"))
     (cons 'review_id (agent-review-store--id "review"))
     (cons 'repo_root repo-root)
     (cons 'branch branch)
     (cons 'base_ref base-ref)
     (cons 'head_ref head-ref)
     (cons 'created_at now)
     (cons 'updated_at now)
     (cons 'head_commits (and head-commits (copy-sequence head-commits)))
     (cons 'events (list (list (cons 'kind "created")
                               (cons 'created_at now))))
     (cons 'agent_handoff nil)
     (cons 'threads nil))))
```

Update `agent-review-store-read` to default `review_type` when absent:

```elisp
(defun agent-review-store-read (file)
  "Read review data from FILE."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (json-false :false)
         (review (json-read-file file)))
    (unless (alist-get 'review_type review)
      (setq review (cons (cons 'review_type "branch") review)))
    review))
```

Add the new file path helper after `agent-review-store-review-file`:

```elisp
(defun agent-review-store-uncommitted-review-file (repo-root branch)
  "Return the uncommitted review file path for BRANCH inside REPO-ROOT."
  (expand-file-name (concat branch "-uncommitted.json")
                    (expand-file-name ".agent-review" repo-root)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-store-test.el -f ert-run-tests-batch-and-exit`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-review-store.el tests/agent-review-store-test.el
git commit --author="Claude <claude@anthropic.com>" -m "feat: add review_type and uncommitted file path to store"
```

### Task 3: Restructure Entry Point for Uncommitted Reviews

**Files:**
- Modify: `agent-review.el:926-933` (the `agent-review` function)
- Modify: `agent-review.el:879-885` (`agent-review--create-review`)
- Modify: `agent-review.el:896-907` (`agent-review--load-review`)
- Modify: `tests/agent-review-entrypoint-test.el`

- [ ] **Step 1: Write failing test for uncommitted entry point**

Add this test to `tests/agent-review-entrypoint-test.el`:

```elisp
(ert-deftest agent-review-uncommitted-creates-uncommitted-review ()
  "Selecting 'uncommitted' creates a review with review_type uncommitted."
  (agent-review-test-with-temp-repo (repo)
    ;; Add uncommitted change
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((default-directory repo)
          (review nil))
      (cl-letf (((symbol-function 'agent-review-git-prompt-base-ref)
                 (lambda (&optional _repo) "uncommitted"))
                ((symbol-function 'agent-review--open-buffer)
                 (lambda (_file r) (setq review r))))
        (agent-review))
      (should review)
      (should (equal "uncommitted" (alist-get 'review_type review)))
      (should (null (alist-get 'base_ref review)))
      (should (null (alist-get 'head_ref review))))))
```

- [ ] **Step 2: Run tests to verify failure**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-entrypoint-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — entry point doesn't handle "uncommitted" selection.

- [ ] **Step 3: Restructure the entry point**

In `agent-review.el`, update `agent-review--create-review` to accept the base-ref as a parameter and support uncommitted type:

```elisp
(defun agent-review--create-review (repo-root branch base-ref)
  "Create a fresh review in REPO-ROOT for BRANCH with BASE-REF.
When BASE-REF is \"uncommitted\", creates an uncommitted review."
  (if (equal base-ref "uncommitted")
      (agent-review-store-create repo-root branch nil nil nil "uncommitted")
    (let* ((head-ref (agent-review-git-head-commit repo-root))
           (head-commits (agent-review-git-commit-list repo-root base-ref)))
      (agent-review-store-create repo-root branch base-ref head-ref head-commits))))
```

Update `agent-review--replace-review` to pass base-ref through:

```elisp
(defun agent-review--replace-review (repo-root branch base-ref previous-review)
  "Create a replacement review in REPO-ROOT for BRANCH from PREVIOUS-REVIEW."
  (let ((review (agent-review--create-review repo-root branch base-ref)))
    (setf (alist-get 'events review)
          (append (copy-tree (alist-get 'events previous-review))
                  (alist-get 'events review)
                  (list (agent-review--event "replaced"))))
    review))
```

Update `agent-review--load-review` to accept base-ref and pass it through:

```elisp
(defun agent-review--load-review (repo-root branch base-ref review-file)
  "Load or create a review for REPO-ROOT, BRANCH, BASE-REF and REVIEW-FILE."
  (let ((review (if (file-exists-p review-file)
                    (let* ((existing-review (agent-review-store-read review-file))
                           (action (agent-review--prompt-existing-review-action branch)))
                      (if (equal action "Continue")
                          existing-review
                        (agent-review--replace-review repo-root branch base-ref existing-review)))
                  (agent-review--create-review repo-root branch base-ref))))
    (setq review (agent-review--refresh-review-state review repo-root))
    (agent-review-store-write review-file review)
    review))
```

Update the main `agent-review` function to prompt for base-ref first and dispatch:

```elisp
;;;###autoload
(defun agent-review ()
  "Open an offline review for the current git branch."
  (interactive)
  (let* ((repo-root (agent-review-git-repo-root default-directory))
         (branch (agent-review-git-current-branch repo-root))
         (base-ref (agent-review-git-prompt-base-ref repo-root))
         (uncommitted-p (equal base-ref "uncommitted"))
         (review-file (if uncommitted-p
                          (agent-review-store-uncommitted-review-file repo-root branch)
                        (agent-review-store-review-file repo-root branch)))
         (review (agent-review--load-review repo-root branch base-ref review-file)))
    (agent-review--open-buffer review-file review)))
```

- [ ] **Step 4: Run all tests**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-entrypoint-test.el -l tests/agent-review-git-test.el -l tests/agent-review-store-test.el -f ert-run-tests-batch-and-exit`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-review.el tests/agent-review-entrypoint-test.el
git commit --author="Claude <claude@anthropic.com>" -m "feat: restructure entry point for uncommitted reviews"
```

### Task 4: Adapt Anchors and Refresh for Uncommitted Reviews

**Files:**
- Modify: `agent-review.el:586-591` (`agent-review--sync-commit-cache`)
- Modify: `agent-review.el:593-600` (`agent-review--make-anchor`)
- Modify: `agent-review.el:809-827` (`agent-review--recompute-thread-status`)
- Modify: `agent-review.el:829-843` (`agent-review--refresh-review-state`)

- [ ] **Step 1: Write failing test for uncommitted anchor behavior**

Add to `tests/agent-review-entrypoint-test.el`:

```elisp
(ert-deftest agent-review-uncommitted-recompute-always-remaps ()
  "Threads with nil head_commit should always be treated as stale."
  (require 'agent-review)
  (let* ((thread `((thread_id . "t1")
                   (state . "open")
                   (anchor_status . "active")
                   (anchor . ((base_commit . "abc123")
                              (head_commit . nil)
                              (path . "demo.txt")
                              (side . "RIGHT")
                              (line . 2)
                              (diff_hunk . "@@ -1 +1,2 @@")))))
         (result (agent-review--recompute-thread-status thread "def456")))
    ;; Should be marked outdated since head_commit is nil
    (should (equal "outdated" (alist-get 'anchor_status result)))))

(ert-deftest agent-review-uncommitted-refresh-skips-head-update ()
  "Refresh should not update head_ref or head_commits for uncommitted reviews."
  (agent-review-test-with-temp-repo (repo)
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((review (agent-review-store-create repo "feature/offline" nil nil nil "uncommitted")))
      (setq review (agent-review--refresh-review-state review repo))
      (should (null (alist-get 'head_ref review)))
      (should (null (alist-get 'head_commits review))))))
```

- [ ] **Step 2: Run tests to verify failure**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-entrypoint-test.el -f ert-run-tests-batch-and-exit`
Expected: FAIL — recompute treats nil head_commit same as mismatch (may pass by accident if it falls through to the `t` branch), refresh updates head_ref unconditionally.

- [ ] **Step 3: Update anchor and refresh logic**

In `agent-review.el`, update `agent-review--sync-commit-cache` to handle nil base-ref:

```elisp
(defun agent-review--sync-commit-cache (review repo-root)
  "Cache commit ids for REVIEW in REPO-ROOT."
  (let ((base-ref (alist-get 'base_ref review)))
    (setq agent-review--base-commit
          (when base-ref (agent-review-git-rev-parse repo-root base-ref))
          agent-review--head-commit
          (alist-get 'head_ref review))))
```

Update `agent-review--recompute-thread-status` to treat nil head_commit as always outdated:

```elisp
(defun agent-review--recompute-thread-status (thread current-head)
  "Recompute THREAD anchor status against CURRENT-HEAD."
  (let ((anchor (alist-get 'anchor thread))
        (current-anchor (alist-get 'current_anchor thread))
        (status (alist-get 'anchor_status thread)))
    (cond
     ;; Uncommitted review threads (nil head_commit) are always stale
     ((null (alist-get 'head_commit anchor))
      (setq thread (agent-review--alist-delete thread 'current_anchor))
      (agent-review--alist-set thread 'anchor_status "outdated"))
     ((and current-anchor
           (equal (alist-get 'head_commit current-anchor) current-head))
      (agent-review--alist-set
       thread 'anchor_status
       (if (or (null status) (equal status "active"))
           "remapped"
         status)))
     ((equal (alist-get 'head_commit anchor) current-head)
      (setq thread (agent-review--alist-delete thread 'current_anchor))
      (agent-review--alist-set thread 'anchor_status "active"))
     (t
      (setq thread (agent-review--alist-delete thread 'current_anchor))
      (agent-review--alist-set thread 'anchor_status "outdated")))))
```

Update `agent-review--refresh-review-state` to skip head updates for uncommitted reviews:

```elisp
(defun agent-review--refresh-review-state (review repo-root)
  "Refresh REVIEW with current git state from REPO-ROOT."
  (let* ((repo-root (or repo-root (alist-get 'repo_root review)))
         (base-ref (alist-get 'base_ref review))
         (uncommitted-p (equal (alist-get 'review_type review) "uncommitted")))
    (setf (alist-get 'repo_root review) repo-root)
    (unless uncommitted-p
      (let ((head-ref (agent-review-git-head-commit repo-root))
            (head-commits (agent-review-git-commit-list repo-root base-ref)))
        (setf (alist-get 'head_ref review) head-ref)
        (setf (alist-get 'head_commits review) head-commits)
        (setf (alist-get 'threads review)
              (mapcar (lambda (thread)
                        (agent-review--recompute-thread-status thread head-ref))
                      (alist-get 'threads review)))))
    (when uncommitted-p
      (setf (alist-get 'threads review)
            (mapcar (lambda (thread)
                      (agent-review--recompute-thread-status thread nil))
                    (alist-get 'threads review))))
    (setf (alist-get 'updated_at review) (agent-review--now))
    review))
```

- [ ] **Step 4: Run all tests**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-entrypoint-test.el -l tests/agent-review-git-test.el -l tests/agent-review-store-test.el -l tests/agent-review-remap-test.el -f ert-run-tests-batch-and-exit`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add agent-review.el tests/agent-review-entrypoint-test.el
git commit --author="Claude <claude@anthropic.com>" -m "feat: adapt anchors and refresh for uncommitted reviews"
```

### Task 5: Adjust Rendering for Uncommitted Reviews

**Files:**
- Modify: `agent-review.el:295-320` (`agent-review--insert-header`)
- Modify: `agent-review.el:752-807` (`agent-review--render`)

- [ ] **Step 1: Update header rendering for uncommitted reviews**

In `agent-review.el`, update `agent-review--insert-header` to accept and use `review-type`:

```elisp
(defun agent-review--insert-header (review open-count)
  "Insert top review header for REVIEW using OPEN-COUNT."
  (let* ((branch (alist-get 'branch review))
         (base-ref (alist-get 'base_ref review))
         (review-type (or (alist-get 'review_type review) "branch"))
         (actor (or user-login-name user-real-login-name "user"))
         (updated (agent-review--format-display-time (alist-get 'updated_at review)))
         (state-label (if (> open-count 0) "OPEN" "CLEAN"))
         (state-face (if (> open-count 0)
                         'agent-review-state-face
                       'agent-review-success-state-face))
         (title-start (point)))
    (if (equal review-type "uncommitted")
        (progn
          (insert (format "Agent Review: Uncommitted changes (%s)\n" branch))
          (add-face-text-property title-start (1- (point)) 'agent-review-title-face)
          (let ((sub-start (point)))
            (insert "Working tree changes against HEAD\n")
            (add-face-text-property sub-start (1- (point)) 'agent-review-branch-face)))
      (progn
        (insert (format "Agent Review: %s\n" branch))
        (add-face-text-property title-start (1- (point)) 'agent-review-title-face)
        (let ((base-start (point)))
          (insert (format "%s <- %s\n" base-ref branch))
          (add-face-text-property base-start (+ base-start (length base-ref))
                                  'agent-review-branch-face)
          (add-face-text-property (+ base-start (length base-ref) 4)
                                  (1- (point))
                                  'agent-review-branch-face))))
    (insert (propertize state-label 'face state-face)
            " - "
            (propertize (format "@%s" actor) 'face 'agent-review-meta-value-face)
            " - "
            (propertize updated 'face 'agent-review-info-state-face)
            "\n\n")))
```

- [ ] **Step 2: Update render to hide commits section for uncommitted reviews**

In `agent-review--render`, wrap the commits section insertion in a check:

```elisp
;; Inside agent-review--render, replace the commits section insertion:
;; Old:
;;   (agent-review--insert-commits-section commits)
;; New:
(unless (equal (alist-get 'review_type review) "uncommitted")
  (agent-review--insert-commits-section commits))
```

- [ ] **Step 3: Manually test rendering**

Open a repo with uncommitted changes, run `M-x agent-review`, select "uncommitted". Verify:
- Header shows "Uncommitted changes (branch-name)"
- No commits section
- Diff shows working tree changes
- Can add comments on diff lines

- [ ] **Step 4: Commit**

```bash
git add agent-review.el
git commit --author="Claude <claude@anthropic.com>" -m "feat: adjust rendering for uncommitted reviews"
```

### Task 6: Update Agent Skills

**Files:**
- Modify: `skills/agent-review-claude/SKILL.md`
- Modify: `skills/agent-review-codex/SKILL.md`

- [ ] **Step 1: Update Claude skill**

In `skills/agent-review-claude/SKILL.md`, replace the first line of the Rules section and update step 1 of Workflow:

```markdown
# Agent Review Claude Skill

Use this skill when handling an offline review stored in `.agent-review/<branch>.json` or `.agent-review/<branch>-uncommitted.json`.

## Rules

1. Read the review file (`.agent-review/<branch>.json` for branch reviews, `.agent-review/<branch>-uncommitted.json` for uncommitted reviews) before making review decisions. Check the `review_type` field to determine the type.
2. Reply only to existing threads. Do not create new top-level comments or threads.
3. You may ask clarification questions in chat if the intent or expected fix is unclear.
4. Also append a per-thread reply summary to the review file for every thread you address.
5. Keep history append-only. Do not delete or rewrite earlier messages.

## Workflow

1. Locate the active review file. Check for both `<branch>.json` and `<branch>-uncommitted.json`.
2. Review existing thread messages and anchor metadata.
3. Use `anchor_status` for confidence and prioritization. Prefer `open` threads with active or remapped anchors before outdated ones. Note: uncommitted reviews (`review_type: "uncommitted"`) always mark threads as outdated on refresh — remap is attempted automatically.
4. Ask the user for clarification in chat when needed.
5. Append a reply entry to each addressed thread summarizing the action taken, the result, or the blocker.
6. Preserve all prior thread history as-is.

## Constraints

1. No new top-level review comments.
2. No destructive edits to review history.
3. Chat responses and file replies are both required when you address a thread.
```

- [ ] **Step 2: Update Codex skill**

In `skills/agent-review-codex/SKILL.md`, apply matching changes:

```markdown
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
```

- [ ] **Step 3: Commit**

```bash
git add skills/agent-review-claude/SKILL.md skills/agent-review-codex/SKILL.md
git commit --author="Claude <claude@anthropic.com>" -m "docs: update agent skills for uncommitted reviews"
```

### Task 7: Run Full Test Suite and Verify

**Files:**
- All test files

- [ ] **Step 1: Run the complete test suite**

Run: `emacs -Q --batch -L . -L tests -l tests/test-helper.el -l tests/agent-review-git-test.el -l tests/agent-review-store-test.el -l tests/agent-review-entrypoint-test.el -l tests/agent-review-remap-test.el -l tests/agent-review-offline-hardening-test.el -f ert-run-tests-batch-and-exit`
Expected: All tests PASS.

- [ ] **Step 2: Manual smoke test**

In a repo with uncommitted changes:
1. Run `M-x agent-review`
2. Verify "uncommitted" appears first in the completion list
3. Select it — verify header shows "Uncommitted changes"
4. Add a comment on a diff line — verify it persists
5. Save a file to change the diff, run `C-c C-r` (refresh) — verify remap runs
6. Run `M-x agent-review` again, verify "Continue" / "Replace" prompt appears
