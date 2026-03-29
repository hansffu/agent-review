;;; agent-review.el --- Offline agent review -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Offline diff review for the current git branch.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'agent-review-git)
(require 'agent-review-store)

(defvar agent-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'agent-review-refresh)
    (define-key map (kbd "C-c C-c") #'agent-review-context-comment)
    (define-key map (kbd "C-c C-s") #'agent-review-toggle-thread-state)
    map)
  "Keymap for `agent-review-mode'.")

(defvar-local agent-review--review nil)
(defvar-local agent-review--review-file nil)
(defvar-local agent-review--diff-text nil)
(defvar-local agent-review--base-commit nil)
(defvar-local agent-review--head-commit nil)

(define-derived-mode agent-review-mode special-mode "Agent Review"
  "Major mode for offline branch reviews."
  (setq-local truncate-lines t))

(defun agent-review--now ()
  "Return the current UTC timestamp."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" (current-time) t))

(defun agent-review--event (kind &optional extra)
  "Return an event alist for KIND merged with EXTRA."
  (append `((kind . ,kind)
            (created_at . ,(agent-review--now)))
          extra))

(defun agent-review--property-at-point (property)
  "Return PROPERTY around point."
  (or (get-text-property (point) property)
      (and (> (point) (point-min))
           (get-text-property (1- (point)) property))))

(defun agent-review--thread-summary (thread)
  "Return a summary string for THREAD."
  (let* ((anchor (alist-get 'anchor thread))
         (messages (alist-get 'messages thread))
         (latest (car (last messages))))
    (format "[%s] %s:%s %s"
            (alist-get 'state thread)
            (alist-get 'path anchor)
            (alist-get 'line anchor)
            (replace-regexp-in-string
             "\n+" " "
             (or (alist-get 'body latest) "")))))

(defun agent-review--goto-thread (thread-id)
  "Move point to THREAD-ID if present."
  (goto-char (point-min))
  (let ((pos (text-property-any (point-min) (point-max)
                                'agent-review-thread-id thread-id)))
    (when pos
      (goto-char pos)
      (beginning-of-line)
      t)))

(defun agent-review--insert-thread-line (thread)
  "Insert a summary line for THREAD."
  (let ((start (point)))
    (insert (agent-review--thread-summary thread) "\n")
    (add-text-properties start (point)
                         `(agent-review-thread-id ,(alist-get 'thread_id thread)
                                                  mouse-face highlight))))

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

(defun agent-review--insert-diff (diff-text)
  "Insert DIFF-TEXT and annotate diff lines."
  (let ((old-path nil)
        (new-path nil)
        (old-line 0)
        (new-line 0)
        (diff-hunk nil))
    (dolist (line (split-string diff-text "\n"))
      (let ((start (point)))
        (insert line "\n")
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
          (put-text-property start (1- (point)) 'agent-review-diff-anchor
                             (agent-review--make-anchor (or new-path old-path) "RIGHT" new-line diff-hunk))
          (setq new-line (1+ new-line)))
         ((and (or old-path new-path) diff-hunk
               (string-prefix-p "-" line)
               (not (string-prefix-p "---" line)))
          (put-text-property start (1- (point)) 'agent-review-diff-anchor
                             (agent-review--make-anchor (or old-path new-path) "LEFT" old-line diff-hunk))
          (setq old-line (1+ old-line)))
         ((and (or new-path old-path) diff-hunk (string-prefix-p " " line))
          (put-text-property start (1- (point)) 'agent-review-diff-anchor
                             (agent-review--make-anchor (or new-path old-path) "RIGHT" new-line diff-hunk))
          (setq old-line (1+ old-line)
                new-line (1+ new-line))))))))

(defun agent-review--render ()
  "Render the current review buffer."
  (let* ((review agent-review--review)
         (threads (alist-get 'threads review))
         (open-count (cl-count "open" threads :key (lambda (thread) (alist-get 'state thread))
                               :test #'equal))
         (resolved-count (cl-count "resolved" threads
                                   :key (lambda (thread) (alist-get 'state thread))
                                   :test #'equal))
         (inhibit-read-only t))
    (erase-buffer)
    (insert (format "Agent Review: %s\n" (alist-get 'branch review)))
    (insert (format "Repo: %s\n" (alist-get 'repo_root review)))
    (insert (format "Base: %s\n" (alist-get 'base_ref review)))
    (insert (format "Head: %s\n" (alist-get 'head_ref review)))
    (insert (format "Updated: %s\n\n" (alist-get 'updated_at review)))
    (insert (format "Threads: open=%d resolved=%d\n" open-count resolved-count))
    (if threads
        (dolist (thread threads)
          (agent-review--insert-thread-line thread))
      (insert "No threads yet.\n"))
    (insert "\nDiff:\n")
    (if (string-empty-p agent-review--diff-text)
        (insert "No changes.\n")
      (agent-review--insert-diff agent-review--diff-text))
    (goto-char (point-min))))

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

(provide 'agent-review)
;;; agent-review.el ends here
