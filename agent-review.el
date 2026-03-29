;;; agent-review.el --- Offline agent review -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Offline diff review for the current git branch.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'magit-section)
(require 'agent-review-git)
(require 'agent-review-store)
(require 'agent-review-render)

(defgroup agent-review nil
  "Offline review workflow for local branches."
  :group 'tools)

(defface agent-review-title-face
  '((t :inherit outline-1))
  "Face used for the review title."
  :group 'agent-review)

(defface agent-review-section-face
  '((t :inherit outline-3 :weight bold))
  "Face used for section headers."
  :group 'agent-review)

(defface agent-review-meta-key-face
  '((t :inherit font-lock-keyword-face))
  "Face used for metadata labels."
  :group 'agent-review)

(defface agent-review-meta-value-face
  '((t :inherit default))
  "Face used for metadata values."
  :group 'agent-review)

(defface agent-review-branch-face
  '((t :inherit font-lock-variable-name-face))
  "Face used for branch names."
  :group 'agent-review)

(defface agent-review-hash-face
  '((t :inherit font-lock-comment-face))
  "Face used for commit hash labels."
  :group 'agent-review)

(defface agent-review-state-face
  '((t :inherit bold))
  "Default face for state labels."
  :group 'agent-review)

(defface agent-review-success-state-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face used for successful states."
  :group 'agent-review)

(defface agent-review-error-state-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face used for problematic states."
  :group 'agent-review)

(defface agent-review-info-state-face
  '((t :inherit italic))
  "Face used for informational state labels."
  :group 'agent-review)

(defface agent-review-thread-location-face
  '((t :inherit font-lock-variable-name-face))
  "Face used for thread location labels."
  :group 'agent-review)

(defface agent-review-thread-body-face
  '((t :inherit default))
  "Face used for thread body summaries."
  :group 'agent-review)

(defface agent-review-author-face
  '((t :inherit font-lock-keyword-face))
  "Face used for message author labels."
  :group 'agent-review)

(defface agent-review-timestamp-face
  '((t :inherit italic))
  "Face used for message timestamps."
  :group 'agent-review)

(defface agent-review-empty-state-face
  '((t :inherit shadow))
  "Face used for empty section placeholders."
  :group 'agent-review)

(defcustom agent-review-diff-font-lock-syntax 'hunk-also
  "Value used for `diff-font-lock-syntax' while rendering diffs."
  :type (get 'diff-font-lock-syntax 'custom-type)
  :group 'agent-review)

(defvar agent-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "C-c C-r") #'agent-review-refresh)
    (define-key map (kbd "C-c C-c") #'agent-review-context-comment)
    (define-key map (kbd "C-c C-s") #'agent-review-toggle-thread-state)
    (define-key map (kbd "C-c C-m") #'agent-review-remap-anchors)
    map)
  "Keymap for `agent-review-mode'.")

(defvar-local agent-review--review nil)
(defvar-local agent-review--review-file nil)
(defvar-local agent-review--diff-text nil)
(defvar-local agent-review--base-commit nil)
(defvar-local agent-review--head-commit nil)

(defclass agent-review--diff-section (magit-section) ())
(defclass agent-review--threads-section (magit-section) ())
(defclass agent-review--thread-section (magit-section) ())
(defclass agent-review--thread-message-section (magit-section) ())

(define-derived-mode agent-review-mode magit-section-mode "Agent Review"
  "Major mode for offline branch reviews."
  (use-local-map agent-review-mode-map)
  (agent-review-render-setup-mode)
  (setq-local truncate-lines t))

(defun agent-review--now ()
  "Return the current UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" (current-time) t))

(defun agent-review--event (kind &optional extra)
  "Return an event alist for KIND merged with EXTRA."
  (append `((kind . ,kind)
            (created_at . ,(agent-review--now)))
          extra))

(defun agent-review--alist-set (alist key value)
  "Set KEY in ALIST to VALUE and return ALIST."
  (let ((cell (assoc key alist)))
    (if cell
        (setcdr cell value)
      (setq alist (append alist (list (cons key value)))))
    alist))

(defun agent-review--alist-delete (alist key)
  "Delete KEY from ALIST."
  (assq-delete-all key alist))

(defun agent-review--property-at-point (property)
  "Return PROPERTY around point."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) property))))

(defun agent-review--state-face (state)
  "Return face symbol for thread STATE."
  (pcase state
    ("resolved" 'agent-review-success-state-face)
    ("open" 'agent-review-state-face)
    (_ 'agent-review-state-face)))

(defun agent-review--anchor-status-face (status)
  "Return face symbol for anchor STATUS."
  (pcase status
    ("remapped" 'agent-review-success-state-face)
    ("outdated" 'agent-review-error-state-face)
    ("active" 'agent-review-info-state-face)
    (_ 'agent-review-info-state-face)))

(defun agent-review--insert-section-label (label)
  "Insert section LABEL with heading face."
  (let ((start (point)))
    (insert label "\n")
    (add-face-text-property start (1- (point)) 'agent-review-section-face)))

(defun agent-review--insert-labeled-line (label value)
  "Insert LABEL and VALUE on one line with metadata faces."
  (let ((label-start (point)))
    (insert label ": ")
    (add-face-text-property label-start (point) 'agent-review-meta-key-face)
    (let ((value-start (point)))
      (insert (format "%s\n" value))
      (add-face-text-property value-start (1- (point)) 'agent-review-meta-value-face))))

(defun agent-review--format-display-time (iso-timestamp)
  "Format ISO-TIMESTAMP for display."
  (format-time-string "%b %d, %Y, %H:%M" (date-to-time iso-timestamp)))

(defun agent-review--insert-header (review open-count)
  "Insert top review header for REVIEW using OPEN-COUNT."
  (let* ((branch (alist-get 'branch review))
         (base-ref (alist-get 'base_ref review))
         (actor (or user-login-name user-real-login-name "user"))
         (updated (agent-review--format-display-time (alist-get 'updated_at review)))
         (state-label (if (> open-count 0) "OPEN" "CLEAN"))
         (state-face (if (> open-count 0)
                         'agent-review-state-face
                       'agent-review-success-state-face))
         (title-start (point)))
    (insert (format "Agent Review: %s\n" branch))
    (add-face-text-property title-start (1- (point)) 'agent-review-title-face)
    (let ((base-start (point)))
      (insert (format "%s <- %s\n" base-ref branch))
      (add-face-text-property base-start (+ base-start (length base-ref))
                              'agent-review-branch-face)
      (add-face-text-property (+ base-start (length base-ref) 4)
                              (1- (point))
                              'agent-review-branch-face))
    (insert (propertize state-label 'face state-face)
            " - "
            (propertize (format "@%s" actor) 'face 'agent-review-meta-value-face)
            " - "
            (propertize updated 'face 'agent-review-info-state-face)
            "\n\n")))

(defun agent-review--insert-commits-section (commits)
  "Insert commit list section for COMMITS."
  (agent-review--insert-section-label (format "Total %d commits" (length commits)))
  (if commits
      (dolist (commit commits)
        (let ((hash-start (point)))
          (insert "* " (alist-get 'short commit))
          (add-face-text-property (+ hash-start 2) (point) 'agent-review-hash-face)
          (insert " " (alist-get 'subject commit) "\n")))
    (let ((empty-start (point)))
      (insert "No new commits.\n")
      (add-face-text-property empty-start (1- (point)) 'agent-review-empty-state-face)))
  (insert "\n"))

(defun agent-review--status-code-label (status)
  "Return display label for git STATUS."
  (pcase (and status (> (length status) 0) (substring status 0 1))
    ("A" "added")
    ("D" "deleted")
    ("R" "renamed")
    ("C" "copied")
    ("M" "modified")
    (_ "changed")))

(defun agent-review--status-code-face (status)
  "Return face for git STATUS."
  (pcase (and status (> (length status) 0) (substring status 0 1))
    ((or "A" "R" "C") 'agent-review-success-state-face)
    ("D" 'agent-review-error-state-face)
    ("M" 'agent-review-state-face)
    (_ 'agent-review-info-state-face)))

(defun agent-review--safe-commit-headlines (repo-root base-ref)
  "Return commit headlines for REPO-ROOT/BASE-REF or nil on failure."
  (condition-case nil
      (agent-review-git-commit-headlines repo-root base-ref)
    (error nil)))

(defun agent-review--safe-changed-files (repo-root base-ref)
  "Return changed files for REPO-ROOT/BASE-REF or nil on failure."
  (condition-case nil
      (agent-review-git-changed-files repo-root base-ref)
    (error nil)))

(defun agent-review--safe-diff-summary (repo-root base-ref)
  "Return diff summary for REPO-ROOT/BASE-REF or zeros on failure."
  (condition-case nil
      (agent-review-git-diff-summary repo-root base-ref)
    (error '((files . 0)
             (additions . 0)
             (deletions . 0)))))

(defun agent-review--goto-thread (thread-id)
  "Move point to THREAD-ID if present."
  (goto-char (point-min))
  (let* ((inline-pos (and (bound-and-true-p agent-review--diff-begin-point)
                          (text-property-any agent-review--diff-begin-point (point-max)
                                             'agent-review-thread-id thread-id)))
         (pos (or inline-pos
                  (text-property-any (point-min) (point-max)
                                     'agent-review-thread-id thread-id))))
    (when pos
      (goto-char pos)
      (beginning-of-line)
      t)))

(defun agent-review--insert-thread-line (thread)
  "Insert a summary line for THREAD."
  (let* ((anchor (or (alist-get 'current_anchor thread)
                     (alist-get 'anchor thread)))
         (messages (alist-get 'messages thread))
         (latest (car (last messages)))
         (state (or (alist-get 'state thread) "open"))
         (status (alist-get 'anchor_status thread))
         (location (format "%s:%s"
                           (or (alist-get 'path anchor) "?")
                           (or (alist-get 'line anchor) "?")))
         (summary (replace-regexp-in-string
                   "\n+" " "
                   (or (alist-get 'body latest) "")))
         (start (point)))
    (insert "[")
    (let ((state-start (point)))
      (insert state)
      (add-face-text-property state-start (point) (agent-review--state-face state)))
    (when (and status (not (equal status "active")))
      (insert "/")
      (let ((status-start (point)))
        (insert status)
        (add-face-text-property status-start (point)
                                (agent-review--anchor-status-face status))))
    (insert "] ")
    (let ((location-start (point)))
      (insert location)
      (add-face-text-property location-start (point) 'agent-review-thread-location-face))
    (insert " ")
    (let ((summary-start (point)))
      (insert summary)
      (add-face-text-property summary-start (point) 'agent-review-thread-body-face))
    (insert "\n")
    (add-text-properties start (point)
                         `(agent-review-thread-id ,(alist-get 'thread_id thread)
                                                  mouse-face highlight))))

(defun agent-review--insert-thread-message (thread-id message)
  "Insert MESSAGE in a thread section for THREAD-ID."
  (let* ((author (or (alist-get 'author_id message) "unknown"))
         (created-at (or (alist-get 'created_at message) ""))
         (timestamp (if (string-empty-p created-at)
                        ""
                      (agent-review--format-display-time created-at)))
         (body (or (alist-get 'body message) ""))
         (start (point)))
    (magit-insert-section message-section (agent-review--thread-message-section)
      (magit-insert-heading
        "  "
        (propertize (format "@%s" author) 'face 'agent-review-thread-location-face)
        (if (string-empty-p timestamp)
            ""
          (concat " - " (propertize timestamp 'face 'agent-review-info-state-face))))
      (insert "    ")
      (insert (replace-regexp-in-string "\n" "\n    " body))
      (insert "\n"))
    (add-text-properties start (point)
                         `(agent-review-thread-id ,thread-id
                                                  mouse-face highlight))))

(defun agent-review--insert-thread-section (thread)
  "Insert THREAD as a Magit section with nested message sections."
  (let* ((thread-id (alist-get 'thread_id thread))
         (start (point)))
    (magit-insert-section thread-section (agent-review--thread-section thread-id)
      (agent-review--insert-thread-line thread)
      (dolist (message (alist-get 'messages thread))
        (agent-review--insert-thread-message thread-id message))
      (insert "\n"))
    (add-text-properties start (point)
                         `(agent-review-thread-id ,thread-id
                                                  mouse-face highlight))))

(defun agent-review--thread-anchor (thread)
  "Return current anchor for THREAD."
  (or (alist-get 'current_anchor thread)
      (alist-get 'anchor thread)))

(defun agent-review--thread-status-suffix (thread)
  "Return status suffix string for THREAD."
  (let ((state (alist-get 'state thread))
        (anchor-status (alist-get 'anchor_status thread)))
    (concat
     (when (equal state "resolved")
       " - RESOLVED")
     (when (and anchor-status (not (equal anchor-status "active")))
       (format " - %s" (upcase anchor-status))))))

(defun agent-review--message-display-time (message)
  "Return display timestamp for MESSAGE."
  (let ((created-at (or (alist-get 'created_at message) "")))
    (if (string-empty-p created-at)
        ""
      (agent-review--format-display-time created-at))))

(defun agent-review--insert-inline-thread (thread)
  "Insert THREAD inline in the diff if its anchor is visible."
  (let* ((anchor (agent-review--thread-anchor thread))
         (path (alist-get 'path anchor))
         (side (alist-get 'side anchor))
         (line (alist-get 'line anchor))
         (messages (alist-get 'messages thread)))
    (when (and path side line
               (agent-review-render-goto-diff-line path side line))
      (forward-line 1)
      (let* ((authors (delete-dups
                       (mapcar (lambda (message)
                                 (or (alist-get 'author_id message) "unknown"))
                               messages)))
             (thread-id (alist-get 'thread_id thread))
             (start (point)))
        (insert (propertize
                 (format "> %d comment%s from %s%s\n"
                         (length messages)
                         (if (= (length messages) 1) "" "s")
                         (mapconcat (lambda (author) (concat "@" author)) authors ", ")
                         (agent-review--thread-status-suffix thread))
                 'face 'font-lock-comment-face))
        (dolist (message messages)
          (let ((author (or (alist-get 'author_id message) "unknown"))
                (timestamp (agent-review--message-display-time message))
                (body (or (alist-get 'body message) "")))
            (insert "  ")
            (insert (propertize (format "@%s" author) 'face 'agent-review-author-face))
            (unless (string-empty-p timestamp)
              (insert " - ")
              (insert (propertize timestamp 'face 'agent-review-timestamp-face)))
            (insert "\n")
            (agent-review-render-insert-markdown body 4 'agent-review-thread-body-face)
            (insert "\n")))
        (insert "  ")
        (insert-button
         "Reply"
         'face 'agent-review-meta-key-face
         'action (lambda (button)
                   (save-excursion
                     (goto-char (button-start button))
                     (call-interactively #'agent-review-context-comment))))
        (insert "  ")
        (insert-button
         (if (equal (alist-get 'state thread) "resolved") "Unresolve" "Resolve")
         'face 'agent-review-meta-key-face
         'action (lambda (button)
                   (save-excursion
                     (goto-char (button-start button))
                     (call-interactively #'agent-review-toggle-thread-state))))
        (insert "\n")
        (insert "\n")
        (add-text-properties start (point)
                             `(agent-review-thread-id ,thread-id
                                                      mouse-face highlight))
        t))))

(defun agent-review--parse-hunk-header (line)
  "Return parsed line numbers for diff hunk LINE."
  (when (string-match "^@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? +\\+\\([0-9]+\\)\\(?:,[0-9]+\\)? @@" line)
    (list (string-to-number (match-string 1 line))
          (string-to-number (match-string 2 line)))))

(defun agent-review--sync-commit-cache (review repo-root)
  "Cache commit ids for REVIEW in REPO-ROOT."
  (setq agent-review--base-commit
        (agent-review-git-rev-parse repo-root (alist-get 'base_ref review))
        agent-review--head-commit
        (alist-get 'head_ref review)))

(defun agent-review--make-anchor (path side line diff-hunk)
  "Build a thread anchor for PATH, SIDE, LINE and DIFF-HUNK."
  `((base_commit . ,agent-review--base-commit)
    (head_commit . ,agent-review--head-commit)
    (path . ,path)
    (side . ,side)
    (line . ,line)
    (diff_hunk . ,diff-hunk)))

(defun agent-review--collect-diff-anchors (diff-text base-commit head-commit)
  "Collect anchor candidates from DIFF-TEXT using BASE-COMMIT and HEAD-COMMIT."
  (let ((old-path nil)
        (new-path nil)
        (old-line 0)
        (new-line 0)
        (diff-hunk nil)
        (anchors nil))
    (dolist (line (split-string diff-text "\n"))
      (cond
       ((string-match "^diff --git a/\\(.+\\) b/\\(.+\\)$" line)
        (setq old-path (match-string 1 line)
              new-path (match-string 2 line)
              diff-hunk nil))
       ((string-prefix-p "--- /dev/null" line)
        (setq old-path nil))
       ((string-prefix-p "+++ /dev/null" line)
        (setq new-path nil))
       ((string-prefix-p "--- a/" line)
        (setq old-path (substring line 6)))
       ((string-prefix-p "+++ b/" line)
        (setq new-path (substring line 6)))
       ((string-prefix-p "@@ " line)
        (pcase-let ((`(,old ,new) (agent-review--parse-hunk-header line)))
          (setq old-line old
                new-line new
                diff-hunk line)))
       ((and (or new-path old-path) diff-hunk
             (string-prefix-p "+" line)
             (not (string-prefix-p "+++" line)))
        (push `((base_commit . ,base-commit)
                (head_commit . ,head-commit)
                (path . ,(or new-path old-path))
                (side . "RIGHT")
                (line . ,new-line)
                (diff_hunk . ,diff-hunk))
              anchors)
        (setq new-line (1+ new-line)))
       ((and (or old-path new-path) diff-hunk
             (string-prefix-p "-" line)
             (not (string-prefix-p "---" line)))
        (push `((base_commit . ,base-commit)
                (head_commit . ,head-commit)
                (path . ,(or old-path new-path))
                (side . "LEFT")
                (line . ,old-line)
                (diff_hunk . ,diff-hunk))
              anchors)
        (setq old-line (1+ old-line)))
       ((and (or new-path old-path) diff-hunk (string-prefix-p " " line))
        (push `((base_commit . ,base-commit)
                (head_commit . ,head-commit)
                (path . ,(or new-path old-path))
                (side . "RIGHT")
                (line . ,new-line)
                (diff_hunk . ,diff-hunk))
              anchors)
        (setq old-line (1+ old-line)
              new-line (1+ new-line)))))
    (nreverse anchors)))

(defun agent-review--find-remap-candidate (anchor candidates)
  "Find the best remap candidate for ANCHOR from CANDIDATES."
  (let* ((same-side (seq-filter
                     (lambda (candidate)
                       (equal (alist-get 'side candidate) (alist-get 'side anchor)))
                     candidates))
         (line-match (seq-find
                      (lambda (candidate)
                        (and (equal (alist-get 'path candidate) (alist-get 'path anchor))
                             (equal (alist-get 'line candidate) (alist-get 'line anchor))))
                      same-side))
         (hunk-match (seq-find
                      (lambda (candidate)
                        (and (equal (alist-get 'diff_hunk candidate) (alist-get 'diff_hunk anchor))
                             (equal (alist-get 'path candidate) (alist-get 'path anchor))))
                      same-side))
         (nearest (car (sort
                        (seq-filter
                         (lambda (candidate)
                           (equal (alist-get 'path candidate) (alist-get 'path anchor)))
                         same-side)
                        (lambda (left right)
                          (< (abs (- (alist-get 'line left) (alist-get 'line anchor)))
                             (abs (- (alist-get 'line right) (alist-get 'line anchor)))))))))
    (cond
     (line-match (cons "line" line-match))
     (hunk-match (cons "diff_hunk" hunk-match))
     (nearest (cons "nearest_line" nearest))
     (t nil))))

(defun agent-review--remap-thread (thread candidates current-head timestamp)
  "Remap THREAD using CANDIDATES to CURRENT-HEAD at TIMESTAMP."
  (let* ((anchor (copy-tree (alist-get 'anchor thread)))
         (history (copy-sequence (alist-get 'remap_history thread)))
         (match (agent-review--find-remap-candidate anchor candidates)))
    (if match
        (let* ((method (car match))
               (candidate (cdr match))
               (updated-anchor (copy-tree anchor)))
          (setq updated-anchor (agent-review--alist-set updated-anchor 'head_commit current-head))
          (setq updated-anchor (agent-review--alist-set updated-anchor 'path (alist-get 'path candidate)))
          (setq updated-anchor (agent-review--alist-set updated-anchor 'side (alist-get 'side candidate)))
          (setq updated-anchor (agent-review--alist-set updated-anchor 'line (alist-get 'line candidate)))
          (setq updated-anchor (agent-review--alist-set updated-anchor 'diff_hunk
                                                        (alist-get 'diff_hunk candidate)))
          (if-let ((start-line (alist-get 'start_line candidate)))
              (setq updated-anchor (agent-review--alist-set updated-anchor 'start_line start-line))
            (setq updated-anchor (agent-review--alist-delete updated-anchor 'start_line)))
          (setq thread (agent-review--alist-set thread 'current_anchor updated-anchor))
          (setq thread (agent-review--alist-set thread 'anchor_status "remapped"))
          (setq thread
                (agent-review--alist-set
                 thread 'remap_history
                 (append history
                         (list `((timestamp . ,timestamp)
                                 (result . "remapped")
                                 (method . ,method)
                                 (from_anchor . ,anchor)
                                 (to_anchor . ,(copy-tree updated-anchor)))))))
          thread)
      (setq thread (agent-review--alist-set thread 'anchor_status "outdated"))
      (setq thread (agent-review--alist-delete thread 'current_anchor))
      (setq thread
            (agent-review--alist-set
             thread 'remap_history
             (append history
                     (list `((timestamp . ,timestamp)
                             (result . "outdated")
                             (method . "none")
                             (from_anchor . ,anchor))))))
      thread)))

(defun agent-review--render ()
  "Render the current review buffer."
  (let* ((review agent-review--review)
         (repo-root (alist-get 'repo_root review))
         (base-ref (alist-get 'base_ref review))
         (threads (alist-get 'threads review))
         (commits (agent-review--safe-commit-headlines repo-root base-ref))
         (diff-summary (agent-review--safe-diff-summary repo-root base-ref))
         (open-count (cl-count "open" threads :key (lambda (thread) (alist-get 'state thread))
                               :test #'equal))
         (resolved-count (cl-count "resolved" threads
                                   :key (lambda (thread) (alist-get 'state thread))
                                   :test #'equal))
         (inhibit-read-only t))
    (erase-buffer)
    (agent-review--insert-header review open-count)
    (agent-review--insert-labeled-line "Repo" (alist-get 'repo_root review))
    (agent-review--insert-labeled-line "Base" (alist-get 'base_ref review))
    (agent-review--insert-labeled-line "Head" (alist-get 'head_ref review))
    (agent-review--insert-labeled-line "Updated" (alist-get 'updated_at review))
    (insert "\n")
    (magit-insert-section section (agent-review--threads-section)
      (magit-insert-heading
        (format "Threads: %d open thread%s (%d resolved)"
                open-count
                (if (= open-count 1) "" "s")
                resolved-count))
      (if threads
          (dolist (thread threads)
            (agent-review--insert-thread-section thread))
        (let ((empty-start (point)))
          (insert "No threads yet.\n")
          (add-face-text-property empty-start (1- (point)) 'agent-review-empty-state-face)))
      (insert "\n"))
    (agent-review--insert-commits-section commits)
    (magit-insert-section section (agent-review--diff-section)
      (magit-insert-heading
        (format "Files changed (%d files; %d additions, %d deletions)"
                (alist-get 'files diff-summary)
                (alist-get 'additions diff-summary)
                (alist-get 'deletions diff-summary)))
      (if (string-empty-p agent-review--diff-text)
          (let ((empty-start (point)))
            (insert "No changes.\n")
            (add-face-text-property empty-start (1- (point)) 'agent-review-empty-state-face))
        (agent-review-render-insert-diff agent-review--diff-text)
        ;; Insert inline thread blocks after diff lines. Iterate in reverse
        ;; so older comments stay above newer ones at the same anchor.
        (dolist (thread (reverse threads))
          (save-excursion
            (agent-review--insert-inline-thread thread)))))
    (goto-char (point-min))))

(defun agent-review--recompute-thread-status (thread current-head)
  "Recompute THREAD anchor status against CURRENT-HEAD."
  (let ((anchor (alist-get 'anchor thread))
        (current-anchor (alist-get 'current_anchor thread))
        (status (alist-get 'anchor_status thread)))
    (cond
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

(defun agent-review--refresh-review-state (review repo-root)
  "Refresh REVIEW with current git state from REPO-ROOT."
  (let* ((repo-root (or repo-root (alist-get 'repo_root review)))
         (base-ref (alist-get 'base_ref review))
         (head-ref (agent-review-git-head-commit repo-root))
         (head-commits (agent-review-git-commit-list repo-root base-ref)))
    (setf (alist-get 'repo_root review) repo-root)
    (setf (alist-get 'head_ref review) head-ref)
    (setf (alist-get 'head_commits review) head-commits)
    (setf (alist-get 'updated_at review) (agent-review--now))
    (setf (alist-get 'threads review)
          (mapcar (lambda (thread)
                    (agent-review--recompute-thread-status thread head-ref))
                  (alist-get 'threads review)))
    review))

(defun agent-review--persist-and-rerender (&optional thread-id)
  "Persist current review and rerender, restoring THREAD-ID when possible."
  (agent-review-store-write agent-review--review-file agent-review--review)
  (setq agent-review--diff-text
        (agent-review-git-unified-diff (alist-get 'repo_root agent-review--review)
                                       (alist-get 'base_ref agent-review--review)))
  (agent-review--sync-commit-cache agent-review--review
                                   (alist-get 'repo_root agent-review--review))
  (agent-review--render)
  (when thread-id
    (agent-review--goto-thread thread-id)))

(defun agent-review-refresh ()
  "Refresh the current review buffer."
  (interactive)
  (unless agent-review--review-file
    (user-error "No review is active in this buffer"))
  (setq agent-review--review
        (agent-review--refresh-review-state
         (agent-review-store-read agent-review--review-file)
         (alist-get 'repo_root agent-review--review)))
  (agent-review--persist-and-rerender))

(defun agent-review--prompt-existing-review-action (branch)
  "Prompt for how to handle an existing review for BRANCH."
  (completing-read
   (format "Existing review for %s: " branch)
   '("Continue" "Replace")
   nil
   t
   nil
   nil
   "Continue"))

(defun agent-review--create-review (repo-root branch)
  "Create a fresh review in REPO-ROOT for BRANCH."
  (let* ((base-ref (agent-review-git-prompt-base-ref repo-root))
         (head-ref (agent-review-git-head-commit repo-root))
         (head-commits (agent-review-git-commit-list repo-root base-ref))
         (review (agent-review-store-create repo-root branch base-ref head-ref head-commits)))
    review))

(defun agent-review--replace-review (repo-root branch previous-review)
  "Create a replacement review in REPO-ROOT for BRANCH from PREVIOUS-REVIEW."
  (let ((review (agent-review--create-review repo-root branch)))
    (setf (alist-get 'events review)
          (append (copy-tree (alist-get 'events previous-review))
                  (alist-get 'events review)
                  (list (agent-review--event "replaced"))))
    review))

(defun agent-review--load-review (repo-root branch review-file)
  "Load or create a review for REPO-ROOT, BRANCH and REVIEW-FILE."
  (let ((review (if (file-exists-p review-file)
                    (let* ((existing-review (agent-review-store-read review-file))
                           (action (agent-review--prompt-existing-review-action branch)))
                      (if (equal action "Continue")
                          existing-review
                        (agent-review--replace-review repo-root branch existing-review)))
                  (agent-review--create-review repo-root branch))))
    (setq review (agent-review--refresh-review-state review repo-root))
    (agent-review-store-write review-file review)
    review))

(defun agent-review--open-buffer (review-file review)
  "Open a review buffer for REVIEW-FILE using REVIEW."
  (let ((buffer (get-buffer-create
                 (format "*agent-review:%s*" (alist-get 'branch review)))))
    (with-current-buffer buffer
      (agent-review-mode)
      (setq agent-review--review-file review-file
            agent-review--review review
            agent-review--diff-text
            (agent-review-git-unified-diff (alist-get 'repo_root review)
                                           (alist-get 'base_ref review)))
      (agent-review--sync-commit-cache review (alist-get 'repo_root review))
      (agent-review--render))
    (pop-to-buffer buffer)
    buffer))

;;;###autoload
(defun agent-review ()
  "Open an offline review for the current git branch."
  (interactive)
  (let* ((repo-root (agent-review-git-repo-root default-directory))
         (branch (agent-review-git-current-branch repo-root))
         (review-file (agent-review-store-review-file repo-root branch))
         (review (agent-review--load-review repo-root branch review-file)))
    (agent-review--open-buffer review-file review)))

;;;###autoload
(defun agent-review-open (_repo-owner _repo-name _pr-id &optional _new-window _anchor _last-read-time)
  "Compatibility entrypoint for older callers."
  (interactive)
  (agent-review))

;;;###autoload
(defun agent-review-open-url (_url &optional _new-window &rest _args)
  "Compatibility wrapper for legacy browse-url handlers."
  (agent-review))

;;;###autoload
(defun agent-review-url-parse (_url)
  "Compatibility predicate for legacy browse-url handlers."
  nil)

(defun agent-review-context-comment ()
  "Reply to the thread at point or create a new thread from the diff line at point."
  (interactive)
  (unless agent-review--review
    (user-error "No review is active in this buffer"))
  (let ((thread-id (agent-review--property-at-point 'agent-review-thread-id))
        (anchor (agent-review--property-at-point 'agent-review-diff-anchor))
        (author (or user-login-name user-real-login-name "user")))
    (cond
     (thread-id
      (let ((body (read-string "Reply: ")))
        (when (string-blank-p body)
          (user-error "Reply cannot be empty"))
        (setq agent-review--review
              (agent-review-store-append-reply agent-review--review
                                               thread-id body "human" author))
        (agent-review--persist-and-rerender thread-id)))
     (anchor
      (let ((body (read-string "Comment: ")))
        (when (string-blank-p body)
          (user-error "Comment cannot be empty"))
        (setq agent-review--review
              (agent-review-store-add-thread agent-review--review anchor body "human" author))
        (agent-review--persist-and-rerender
         (alist-get 'thread_id (car (last (alist-get 'threads agent-review--review)))))))
     (t
      (user-error "Point is not on a thread or diff line")))))

(defun agent-review-toggle-thread-state ()
  "Toggle the thread state at point between open and resolved."
  (interactive)
  (unless agent-review--review
    (user-error "No review is active in this buffer"))
  (let ((thread-id (agent-review--property-at-point 'agent-review-thread-id)))
    (unless thread-id
      (user-error "Point is not on a thread"))
    (let* ((thread (cl-find thread-id (alist-get 'threads agent-review--review)
                            :key (lambda (item) (alist-get 'thread_id item))
                            :test #'equal))
           (next-state (if (equal (alist-get 'state thread) "resolved")
                           "open"
                         "resolved")))
      (setq agent-review--review
            (agent-review-store-set-thread-state agent-review--review thread-id next-state))
      (agent-review--persist-and-rerender thread-id))))

(defun agent-review-remap-anchors ()
  "Remap stale thread anchors against the current diff."
  (interactive)
  (unless agent-review--review-file
    (user-error "No review is active in this buffer"))
  (let* ((repo-root (alist-get 'repo_root agent-review--review))
         (timestamp (agent-review--now))
         (review (agent-review--refresh-review-state
                  (agent-review-store-read agent-review--review-file)
                  repo-root))
         (current-head (alist-get 'head_ref review))
         (base-commit (agent-review-git-rev-parse repo-root (alist-get 'base_ref review)))
         (diff-text (agent-review-git-unified-diff repo-root (alist-get 'base_ref review)))
         (candidates (agent-review--collect-diff-anchors diff-text base-commit current-head))
         (remapped 0)
         (outdated 0))
    (setq review
          (agent-review--alist-set
           review 'threads
           (mapcar
            (lambda (thread)
              (let ((anchor (alist-get 'anchor thread))
                    (current-anchor (alist-get 'current_anchor thread)))
                (if (or (equal (alist-get 'head_commit anchor) current-head)
                        (equal (alist-get 'head_commit current-anchor) current-head))
                    thread
                  (let ((updated (agent-review--remap-thread thread candidates current-head timestamp)))
                    (pcase (alist-get 'anchor_status updated)
                      ("remapped" (setq remapped (1+ remapped)))
                      ("outdated" (setq outdated (1+ outdated))))
                    updated))))
            (alist-get 'threads review))))
    (setq review
          (agent-review--alist-set
           review 'events
           (append (alist-get 'events review)
                   (list (agent-review--event
                          "anchors_remapped"
                          `((remapped_count . ,remapped)
                            (outdated_count . ,outdated)
                            (head_commit . ,current-head)))))))
    (setq agent-review--review review
          agent-review--diff-text diff-text)
    (agent-review--persist-and-rerender)
    (message "Remapped %d threads; marked %d outdated" remapped outdated)))

(provide 'agent-review)
;;; agent-review.el ends here
