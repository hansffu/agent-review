;;; agent-review-action.el --- Action part for agent-review  -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Yikai Zhao

;; Author: Yikai Zhao <yikai@z1k.dev>
;; Keywords: tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'agent-review-common)
(require 'agent-review-input)
(require 'agent-review-api)
(require 'magit-section)
(require 'magit-diff)
(require 'browse-url)

(declare-function agent-review-refresh "agent-review")

(defconst agent-review--review-actions '("COMMENT" "APPROVE" "REQUEST_CHANGES")
  "Available actions for `agent-review-submit-review'.")

(defconst agent-review--merge-methods '("MERGE" "REBASE" "SQUASH")
  "Available methods for `agent-review-merge'.")

(defconst agent-review--subscription-states '("IGNORED" "SUBSCRIBED" "UNSUBSCRIBED")
  "Available states for `agent-review-update-subscription'.")

(defun agent-review--insert-quoted-content (body)
  "Insert BODY as quoted in markdown format."
  (when body
    (insert (replace-regexp-in-string "^" "> " body)
            "\n")))

(defun agent-review-reply-to-thread (&rest _)
  "Reply to current thread."
  (interactive)
  (let ((section (magit-current-section))
        reply-content)
    (when (agent-review--review-thread-item-section-p section)
      (setq reply-content (oref section body)
            section (oref section parent)))
    (when (agent-review--review-thread-section-p section)
      (agent-review--open-input-buffer
       "Reply to thread."
       (apply-partially #'agent-review--insert-quoted-content reply-content)
       (apply-partially #'agent-review--post-review-comment-reply
                        (alist-get 'id agent-review--pr-info)
                        (oref section top-comment-id))
       'refresh-after-exit))))

(declare-function agent-review-refresh "agent-review")

(defun agent-review-resolve-thread (&rest _)
  "Resolve or unresolve current thread."
  (interactive)
  (when-let ((section (magit-current-section)))
    (when (agent-review--review-thread-item-section-p section)
      (setq section (oref section parent)))
    (when (agent-review--review-thread-section-p section)
      (let ((resolved (oref section is-resolved))
            (thread-id (oref section value)))
        (when (y-or-n-p (format "Really %s this thread? "
                                (if resolved "unresolve" "resolve")))
          (agent-review--post-resolve-review-thread
           thread-id (not resolved))
          (agent-review-refresh))))))

(defun agent-review-comment (&rest _)
  "Post comment to this PR."
  (interactive)
  (let ((section (magit-current-section))
        reply-content)
    (when (or (agent-review--comment-section-p section)
              (agent-review--review-section-p section))
      (setq reply-content (oref section body)))
    (agent-review--open-input-buffer
     "Comment to PR."
     (apply-partially #'agent-review--insert-quoted-content reply-content)
     (apply-partially #'agent-review--post-comment
                      (alist-get 'id agent-review--pr-info))
     'refresh-after-exit)))


(defun agent-review--get-diff-line-info (pt)
  "Return (side . (filename . line)) for diff line at PT."
  (save-excursion
    (goto-char pt)
    (beginning-of-line)
    (let (prop)
      (cond
       ((setq prop (get-text-property (point) 'agent-review-diff-line-left))
        (cons "LEFT" prop))
       ((setq prop (get-text-property (point) 'agent-review-diff-line-right))
        (cons "RIGHT" prop))))))


(declare-function agent-review--insert-in-diff-pending-review-thread "agent-review-render")

(defun agent-review--add-pending-review-thread-exit-callback (orig-buffer review-thread body)
  "Exit callback for adding pending review thread.
ORIG-BUFFER is the original pr review buffer;
REVIEW-THREAD is the related thread;
BODY is the result text user entered."
  (setf (alist-get 'body review-thread) body)
  (when (buffer-live-p orig-buffer)
    (with-current-buffer orig-buffer
      (let ((inhibit-read-only t))
        (agent-review--insert-in-diff-pending-review-thread review-thread))
      (set-buffer-modified-p t)
      (push review-thread agent-review--pending-review-threads))))

(defun agent-review-add-pending-review-thread ()
  "Add pending review thread under current point (must be in a diff line).
When a region is active, the review thread is added for multiple lines."
  (interactive)
  (let* ((line-info (agent-review--get-diff-line-info
                     (if (use-region-p) (1- (region-end)) (point))))
         (start-line-info (when (use-region-p)
                            (agent-review--get-diff-line-info (region-beginning))))
         region-text
         review-thread)
    (when (equal line-info start-line-info)
      (setq start-line-info nil))
    (if (or (null line-info)
            (and start-line-info
                 (not (equal (cadr line-info) (cadr start-line-info)))))
        (message "Cannot add review thread at current point")
      (setq review-thread `((path . ,(cadr line-info))
                            (line . ,(cddr line-info))
                            (side . ,(car line-info))))
      (when start-line-info
        (setq review-thread (append `((startLine . ,(cddr start-line-info))
                                      (startSide . ,(car start-line-info)))
                                    review-thread)))
      (when (use-region-p)
        (setq region-text (replace-regexp-in-string
                           (rx line-start (any ?+ ?- ?\s)) ""
                           (buffer-substring-no-properties (region-beginning) (region-end))))
        (unless (string-suffix-p "\n" region-text)
          (setq region-text (concat region-text "\n"))))
      (agent-review--open-input-buffer
       "Start review thread."
       (when region-text
         (lambda ()
           (insert "```suggestion\n" region-text "```")
           (goto-char (point-min))))
       (apply-partially #'agent-review--add-pending-review-thread-exit-callback
                        (current-buffer)
                        review-thread))
      t)))

(defun agent-review-edit-pending-review-thread ()
  "Edit pending review thread under current point."
  (interactive)
  (when-let* ((review-thread (get-text-property (point) 'agent-review-pending-review-thread))
              (end (next-single-property-change (point) 'agent-review-pending-review-thread))
              (beg (previous-single-property-change end 'agent-review-pending-review-thread)))
    (let ((inhibit-read-only t))
      (delete-region beg end))
    (setq-local agent-review--pending-review-threads
                (delq review-thread agent-review--pending-review-threads))
    (agent-review--open-input-buffer
     "Edit review thread."
     (lambda ()
       (insert (alist-get 'body review-thread))
       (goto-char (point-min)))
     (apply-partially #'agent-review--add-pending-review-thread-exit-callback
                      (current-buffer)
                      review-thread))
    t))

(defun agent-review-edit-or-add-pending-review-thread ()
  "Edit pending review thread or add a new one, depending on the current point."
  (interactive)
  (or (and (not (use-region-p))  ;; if region is active, always add instead of edit
           (agent-review-edit-pending-review-thread))
      (agent-review-add-pending-review-thread)))

(defun agent-review--submit-review-exit-callback (orig-buffer event body)
  "Exit callback for submitting reviews.
ORIG-BUFFER is the original pr review buffer;
EVENT is the review action user selected;
BODY is the result text user entered."
  (when (buffer-live-p orig-buffer)
    (with-current-buffer orig-buffer
      (agent-review--post-review (alist-get 'id agent-review--pr-info)
                              (or agent-review--selected-commit-head
                                  (alist-get 'headRefOid agent-review--pr-info))
                              event
                              (nreverse agent-review--pending-review-threads)
                              body)
      (setq-local agent-review--pending-review-threads nil))))

(defun agent-review-submit-review (event)
  "Submit review with pending review threads, with action EVENT.
When called interactively, user will be asked to choose an event."
  (interactive (list (completing-read "Select review action: "
                                      agent-review--review-actions
                                      nil 'require-match)))
  (agent-review--open-input-buffer
   (format "Submit review %s (%s threads)." event (length agent-review--pending-review-threads))
   nil
   (apply-partially #'agent-review--submit-review-exit-callback
                    (current-buffer) event)
   'refresh-after-exit
   'allow-empty))

(defun agent-review-merge (method)
  "Merge current PR with METHOD.
Available methods is `agent-review--merge-methods'.
Will confirm before sending the request."
  (interactive (list (completing-read "Select merge method: "
                                      agent-review--merge-methods
                                      nil 'require-match)))
  (when (y-or-n-p (format "Really merge this PR with method %s? " method))
    (agent-review--post-merge-pr (alist-get 'id agent-review--pr-info) method)
    (agent-review-refresh)))

(defun agent-review--close-or-reopen-action ()
  "Return the expected action if `agent-review-close-or-reopen' is called.
Maybe \='close or \='reopen or nil."
  (pcase (alist-get 'state agent-review--pr-info)
    ("CLOSED" 'reopen)
    ("OPEN" 'close)
    (_ nil)))

(defun agent-review-close-or-reopen ()
  "Close or re-open PR based on current state.
Will confirm before sending the request."
  (interactive)
  (pcase (alist-get 'state agent-review--pr-info)
    ("CLOSED" (when (y-or-n-p "Really re-open this PR? ")
                (agent-review--post-reopen-pr (alist-get 'id agent-review--pr-info))
                (agent-review-refresh)))
    ("OPEN" (when (y-or-n-p "Really close this PR? ")
              (agent-review--post-close-pr (alist-get 'id agent-review--pr-info))
              (agent-review-refresh)))
    (_
     (error "Cannot close or reopen PR in current state"))))

(defun agent-review-close-or-reopen-or-merge (action)
  "Close or re-open or merge based on ACTION.
Used for interactive selection one of them."
  (interactive (list (let ((actions agent-review--merge-methods))
                       (when-let ((close-or-reopen-action (agent-review--close-or-reopen-action)))
                         (setq actions
                               (append actions
                                       (list (upcase (symbol-name close-or-reopen-action))))))
                       (completing-read "Select action: "
                                        actions nil 'require-match))))
  (if (member action agent-review--merge-methods)
      (agent-review-merge action)
    (agent-review-close-or-reopen)))

(defun agent-review-edit-comment ()
  "Edit comment under current point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (-is-comment-section (agent-review--comment-section-p section))
              (updatable (oref section updatable))
              (id (oref section value))
              (body (oref section body)))
    (agent-review--open-input-buffer
     "Update comment."
     (lambda () (insert body))
     (apply-partially #'agent-review--update-comment id)
     'refresh-after-exit)))

(defun agent-review-edit-review ()
  "Edit review body under current point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (-is-review-section (agent-review--review-section-p section))
              (updatable (oref section updatable))
              (id (oref section value))
              (body (oref section body)))
    (agent-review--open-input-buffer
     "Update review."
     (lambda () (insert body))
     (apply-partially #'agent-review--update-review id)
     'refresh-after-exit)))

(defun agent-review-edit-review-comment ()
  "Edit review comment under current point."
  (interactive)
  (when-let* ((section (magit-current-section))
              (-is-review-thread-item (agent-review--review-thread-item-section-p section))
              (updatable (oref section updatable))
              (id (oref section value))
              (body (oref section body)))
    (agent-review--open-input-buffer
     "Update review comment."
     (lambda () (insert body))
     (apply-partially #'agent-review--update-review-comment id)
     'refresh-after-exit)))

(defun agent-review-edit-pr-description ()
  "Edit pr description (body)."
  (interactive)
  (when-let* ((section (magit-current-section))
              (-is-description-section (agent-review--description-section-p section))
              (updatable (oref section updatable))
              (body (oref section body)))
    (agent-review--open-input-buffer
     "Update PR description."
     (lambda () (insert body))
     (apply-partially #'agent-review--update-pr-body (alist-get 'id agent-review--pr-info))
     'refresh-after-exit)))

(defun agent-review-edit-pr-title ()
  "Edit pr title."
  (interactive)
  (when-let* ((section (magit-current-section))
              (-is-root-section (agent-review--root-section-p section))
              (updatable (oref section updatable))
              (title (oref section title)))
    (agent-review--open-input-buffer
     "Update PR title."
     (lambda () (insert title))
     (apply-partially #'agent-review--update-pr-title (alist-get 'id agent-review--pr-info))
     'refresh-after-exit)))

(defun agent-review--make-temp-file (head-or-base filepath content)
  (make-temp-file (concat (upcase (symbol-name head-or-base)) "~")
                  nil
                  (concat "~" (file-name-nondirectory filepath))
                  content))

(defun agent-review-view-file (head-or-base filepath &optional line)
  "View the full file content in a temporary buffer.
By default, view the file under current point (must in some diff).
When invoked with prefix, prompt for head-or-base and filepath."
  (interactive
   (let (head-or-base filepath line)
     (when-let* ((line-info (agent-review--get-diff-line-info (point))))
       (setq head-or-base (if (equal (car line-info) "LEFT") 'base 'head)
             filepath (cadr line-info)
             line (cddr line-info)))
     (when (or current-prefix-arg (null head-or-base) (null filepath))
       (let ((res (completing-read "Ref: " '("head" "base") nil t)))
         (setq head-or-base (intern res)))
       (setq filepath (read-from-minibuffer "File path: " filepath)))
     (list head-or-base filepath line)))
  (when (and head-or-base filepath)
    (let* ((content (agent-review--fetch-file filepath head-or-base))
           (tempfile (agent-review--make-temp-file head-or-base filepath content)))
      (with-current-buffer (find-file-other-window tempfile)
        (goto-char (point-min))
        (when line
          (forward-line (1- line)))))))

(defun agent-review-ediff-file (filepath)
  "View the diff using `ediff'.
By default, view the file under current point (must in some diff).
When invoked with prefix, prompt for filepath."
  (interactive
   (let (filepath)
     (when-let* ((line-info (agent-review--get-diff-line-info (point))))
       (setq filepath (cadr line-info)))
     (when (or current-prefix-arg (null filepath))
       (setq filepath (completing-read "File:" (agent-review--find-all-file-names) nil 'require-match)))
     (list filepath)))
  (let* ((base-content (agent-review--fetch-file filepath 'base))
         (head-content (agent-review--fetch-file filepath 'head)))
    (ediff-files (agent-review--make-temp-file 'base filepath base-content)
                 (agent-review--make-temp-file 'head filepath head-content))))

(defun agent-review-open-in-default-browser ()
  "Open current PR in default browser."
  (interactive)
  (browse-url-default-browser (alist-get 'url agent-review--pr-info)))

;; general dispatching functions, call other functions based on current context

(defun agent-review--review-thread-context-p (section)
  "Check whether SECTION is a review thread (or its children)."
  (or (agent-review--review-thread-section-p section)
      (agent-review--review-thread-item-section-p section)))

(defun agent-review--diff-context-p (section)
  "Check whether SECTION is a diff section (or its children)."
  (or (agent-review--diff-section-p section)
      (magit-hunk-section-p section)
      (magit-file-section-p section)
      (magit-module-section-p section)
      (get-text-property (point) 'agent-review-pending-review-thread)))

(defun agent-review-context-comment ()
  "Comment on current point.
Based on current context, may be:
reply to thread, post comment, add/edit review on diff."
  (interactive)
  (pcase (magit-current-section)
    ((pred agent-review--review-thread-context-p)
     (agent-review-reply-to-thread))
    ((pred agent-review--diff-context-p)
     (agent-review-edit-or-add-pending-review-thread))
    (_
     (agent-review-comment))))


(defun agent-review-context-action ()
  "Action on current point.
Based on current context, may be: resolve thread, submit review."
  (interactive)
  (pcase (magit-current-section)
    ((pred agent-review--review-thread-context-p)
     (agent-review-resolve-thread))
    ;; in diff, or has pending review threads
    ((or (pred agent-review--diff-context-p)
         (pred (lambda (_) agent-review--pending-review-threads)))
     (call-interactively #'agent-review-submit-review))
    (_
     (call-interactively #'agent-review-close-or-reopen-or-merge))))


(defun agent-review-context-edit ()
  "Edit on current point.
Based on current context, may be:
edit description, edit review comment, edit comment, edit pending diff review."
  (interactive)
  (pcase (magit-current-section)
    ((pred agent-review--description-section-p)
     (agent-review-edit-pr-description))
    ((pred agent-review--review-thread-item-section-p)
     (agent-review-edit-review-comment))
    ((pred agent-review--comment-section-p)
     (agent-review-edit-comment))
    ((pred agent-review--review-section-p)
     (agent-review-edit-review))
    ((pred agent-review--diff-context-p)
     (agent-review-edit-pending-review-thread))
    ((pred agent-review--root-section-p)
     (agent-review-edit-pr-title))
    (_
     (message "No action available in current context"))))


(defun agent-review--find-all-file-sections (section)
  "Recursively find all file sections in SECTION."
  (if (magit-file-section-p section)
      (list section)
    (mapcan #'agent-review--find-all-file-sections
            (oref section children))))

(defun agent-review--find-all-file-names ()
  "Return all file names in current buffer."
  (mapcar (lambda (section) (oref section value))
          (agent-review--find-all-file-sections magit-root-section)))

(defun agent-review-goto-file (filepath)
  "Goto section for FILEPATH in current buffer.
When called interactively, user can select filepath from list."
  (interactive (list (completing-read
                      "Goto file:"
                      (agent-review--find-all-file-names)
                      nil 'require-match)))
  (when-let ((section (seq-find (lambda (section) (equal (oref section value) filepath))
                                (agent-review--find-all-file-sections magit-root-section))))
    (push-mark)
    (goto-char (oref section start))
    (recenter)))

(defun agent-review-request-reviews (reviewer-logins)
  "Request reviewers for current PR, with a list of usernames REVIEWER-LOGINS.
This will override all existing reviewers (will clear all reviewers on empty).
When called interactively, user can select reviewers from list."
  (interactive
   (list
    (let* ((assignable-users (agent-review--get-assignable-users))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (login)
                    (concat " " (alist-get 'name (gethash login assignable-users)))))))
      (completing-read-multiple
       "Request review: "
       (hash-table-keys assignable-users)
       nil 'require-match
       (string-join
        (mapcar (lambda (reviewer) (let-alist reviewer .requestedReviewer.login))
                (let-alist agent-review--pr-info .reviewRequests.nodes))
        ",")))))
  (let* ((assignable-users (agent-review--get-assignable-users))
         (ids (mapcar (lambda (login)
                        (let ((usr (gethash login assignable-users)))
                          (unless usr
                            (error "User %s not found" login))
                          (alist-get 'id usr)))
                      reviewer-logins)))
    (agent-review--post-request-reviews (alist-get 'id agent-review--pr-info) ids)
    (agent-review-refresh)))

(defun agent-review-set-labels (label-names)
  "Set labels for current PR, with a list of label names LABEL-NAMES.
This will override all existing labels (will clear all labels on empty).
When called interactively, user can select labels from list."
  (interactive
   (list
    (let* ((repo-labels (agent-review--get-repo-labels))
           (completion-extra-properties
            (list :annotation-function
                  (lambda (name)
                    (concat " " (alist-get 'description (gethash name repo-labels)))))))
      (completing-read-multiple
       "Labels: "
       (hash-table-keys repo-labels)
       nil 'require-match
       (string-join
        (mapcar (lambda (label-node) (alist-get 'name label-node))
                (let-alist agent-review--pr-info .labels.nodes))
        ",")))))
  (let* ((repo-labels (agent-review--get-repo-labels))
         (label-node-ids (mapcar (lambda (name)
                                   (let ((label (gethash name repo-labels)))
                                     (unless label
                                       (error "Label %s not found" name))
                                     (alist-get 'node_id label)))
                                 label-names))
         (pr-node-id (alist-get 'id agent-review--pr-info)))
    (agent-review--clear-labels pr-node-id)
    (when label-node-ids
      (agent-review--add-labels pr-node-id label-node-ids))
    (agent-review-refresh)))

(defun agent-review-update-subscription (state)
  "Update subscription to STATE for current PR.
Valid state (string): IGNORED, SUBSCRIBED, UNSUBSCRIBED."
  (interactive (list (completing-read "Update subscription: "
                                      agent-review--subscription-states
                                      nil 'require-match)))
  (when (member state agent-review--subscription-states)
    (agent-review--post-subscription-update (alist-get 'id agent-review--pr-info) state)
    (agent-review-refresh)))

(defun agent-review-goto-database-id (database-id)
  "Goto section with DATABASE-ID, which is used as the anchor in github urls.
Return t if found, nil otherwise."
  (let (pos)
    (save-excursion
      (goto-char (point-min))
      (when-let ((match (text-property-search-forward
                         'magit-section database-id
                         (lambda (target prop-value)
                           (when (or (agent-review--review-section-p prop-value)
                                     (agent-review--comment-section-p prop-value)
                                     (agent-review--review-thread-item-section-p prop-value))
                             (equal (number-to-string (oref prop-value databaseId))
                                    target))))))
        (setq pos (prop-match-beginning match))))
    (when pos
      (goto-char pos)
      t)))

;; short helper for next function
(defun agent-review--make-abbrev-oid-to-commit-nodes (commit-nodes)
  (let* ((abbrev-oid-to-val (make-hash-table :test 'equal)))
    (dolist (n commit-nodes)
      (let-alist n
        (puthash .commit.abbreviatedOid n abbrev-oid-to-val)))
    abbrev-oid-to-val))

(defun agent-review-select-commit (&optional initial-input)
  "Interactively select some commits for review, with INITIAL-INPUT."
  (interactive)
  (let* ((commit-nodes (let-alist agent-review--pr-info .commits.nodes))
         (abbrev-oid-to-val (agent-review--make-abbrev-oid-to-commit-nodes commit-nodes))
         (completion-extra-properties
          (list :annotation-function (lambda (s) (let-alist (gethash s abbrev-oid-to-val)
                                                   (concat " " .commit.messageHeadline)))))
         (abbrev-oids
          (completing-read-multiple
           "Select commit (select two for a range, empty to reset): "
           (mapcar (lambda (n) (let-alist n .commit.abbreviatedOid)) commit-nodes)
           nil t initial-input))
         (indices (mapcar (lambda (x) (seq-position
                                       commit-nodes x (lambda (n xx) (equal (let-alist n .commit.abbreviatedOid) xx))))
                          abbrev-oids)))
    (when (seq-contains-p indices nil)
      (user-error "Invalid commit abbrev-oids"))
    (setq indices (sort (seq-uniq indices)))

    (if (null indices)
        (setq agent-review--selected-commits nil
              agent-review--selected-commit-base nil
              agent-review--selected-commit-head nil)
      (unless (length< indices 3)
        (user-error "Must input 1 commit (to select only the commit) or 2 commits (to select a commit range)"))
      (setq agent-review--selected-commits
            (mapcar (lambda (i) (let-alist (nth i commit-nodes) .commit.oid))
                    (number-sequence (car indices) (car (last indices))))
            agent-review--selected-commit-head
            (car (last agent-review--selected-commits))
            agent-review--selected-commit-base
            (if (= (car indices) 0)
                (let-alist agent-review--pr-info .baseRefOid)
              (let-alist (nth (- (car indices) 1) commit-nodes)
                .commit.oid)))))
  (agent-review-refresh))

(defun agent-review-update-reactions ()
  "Interactively select reactions for comment or description under point."
  (interactive)
  (let* ((section (magit-current-section))
         (all-reaction-names (mapcar (lambda (item) (car item)) agent-review-reaction-emojis))
         (completion-extra-properties
          (list :annotation-function
                (lambda (n) (concat " " (alist-get n agent-review-reaction-emojis "" nil 'equal)))))
         subject-id current-reaction-groups current-my-reactions)
    (if (or (agent-review--description-section-p section)
            (agent-review--review-section-p section)
            (agent-review--comment-section-p section)
            (agent-review--review-thread-item-section-p section))
        (setq subject-id (oref section value)
              current-reaction-groups (oref section reaction-groups))
      (user-error "Current point is not reactable"))
    (dolist (x current-reaction-groups)
      (when (alist-get 'viewerHasReacted x)
        (push (alist-get 'content x) current-my-reactions)))

    (agent-review--update-reactions
     subject-id
     (completing-read-multiple "Reactions: " all-reaction-names nil t
                               (concat (string-join current-my-reactions ",") ",")))
    (agent-review-refresh)))

(provide 'agent-review-action)
;;; agent-review-action.el ends here
