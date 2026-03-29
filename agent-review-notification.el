;;; agent-review-notification.el --- Notification view for agent-review  -*- lexical-binding: t; -*-

;; Copyright (C) 2022  Yikai Zhao

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

(require 'agent-review-api)
(require 'agent-review-listview)
(require 'cl-seq)

(declare-function agent-review-open "agent-review")


(defcustom agent-review-notification-include-read t
  "Include read notifications."
  :type 'boolean
  :group 'agent-review)

(defcustom agent-review-notification-include-unsubscribed t
  "Include unsubscribed notifications."
  :type 'boolean
  :group 'agent-review)

(defvar agent-review-notification-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map agent-review-listview-mode-map)
    (define-key map (kbd "C-c C-t") #'agent-review-notification-toggle-filter)
    (define-key map (kbd "C-c C-u") #'agent-review-notification-remove-mark)
    (define-key map (kbd "C-c C-s") #'agent-review-notification-execute-mark)
    (define-key map (kbd "C-c C-r") #'agent-review-notification-mark-read)
    (define-key map (kbd "C-c C-d") #'agent-review-notification-mark-delete)
    (define-key map (kbd "C-c C-o") #'agent-review-notification-open-in-browser)
    map))

(defvar agent-review--notification-mode-map-setup-for-evil-done nil)

(defun agent-review--notification-mode-map-setup-for-evil ()
  "Setup map in `agent-review-notification-mode' for evil mode (if loaded)."
  (when (and (fboundp 'evil-define-key*)
             (not agent-review--notification-mode-map-setup-for-evil-done))
    (setq agent-review--notification-mode-map-setup-for-evil-done t)
    (evil-define-key* '(normal motion) agent-review-notification-mode-map
      (kbd "u") #'agent-review-notification-remove-mark
      (kbd "r") #'agent-review-notification-mark-read
      (kbd "d") #'agent-review-notification-mark-delete
      (kbd "x") #'agent-review-notification-execute-mark
      (kbd "o") #'agent-review-notification-open-in-browser)))

(define-derived-mode agent-review-notification-mode agent-review-listview-mode
  "Agent Review Notification"
  "Major mode for list of github notifications.

- Open item: `agent-review-listview-open'
  (While this buffer lists all types of notifications,
  only Pull Requests can be opened by this package).
- Page navigation: `agent-review-listview-next-page',
  `agent-review-listview-prev-page', `agent-review-listview-goto-page'
- Mark items as \"read\" or \"unsubscribed\" with
  `agent-review-notification-mark-read',`agent-review-notification-mark-delete',
  then use `agent-review-notification-execute-mark' to execute the marks.
  Remove existing mark with `agent-review-notification-remove-mark'.
- Toggle filter with `agent-review-notification-toggle-filter'.
- Refresh with `revert-buffer'

\\{agent-review-notification-mode-map}"
  :interactive nil
  :group 'agent-review
  (agent-review--notification-mode-map-setup-for-evil)
  (use-local-map agent-review-notification-mode-map)

  (add-hook 'tabulated-list-revert-hook #'agent-review--notification-refresh nil 'local)
  (add-to-list 'kill-buffer-query-functions 'agent-review--notification-confirm-kill-buffer)

  (setq-local agent-review--listview-open-callback #'agent-review--notification-open
              tabulated-list-printer #'agent-review--notification-print-entry
              tabulated-list-use-header-line nil
              tabulated-list-padding 2))

(defun agent-review--notification-entry-sort-updated-at (a b)
  "Sort tabulated list entries by timestamp for A and B."
  (string< (alist-get 'updated_at (car a)) (alist-get 'updated_at (car b))))

;; list of (id type last_updated)
;; type is one of: 'read 'delete
;; last_updated is used to filter outdated marks
(defvar-local agent-review--notification-marks nil)

(defun agent-review--notification-mark (entry)
  "Return mark for ENTRY.
Return one of \='read, \='delete, nil."
  (let ((id (alist-get 'id entry)))
    (nth 1 (seq-find (lambda (item) (equal (nth 0 item) id)) agent-review--notification-marks))))

(defun agent-review--notification-confirm-kill-buffer ()
  "Hook for `kill-buffer-query-functions'.
Confirm if there's mark entries."
  (or (null agent-review--notification-marks)
      (yes-or-no-p (substitute-command-keys
                    "Marked entries exist in current buffer (use `\\[agent-review-notification-execute-mark]' to execute), really exit? "))))

(defun agent-review--notification-print-entry (entry cols)
  "Print ENTRY with COLS for tabulated-list, with custom properties."
  (let ((beg (point)))
    (tabulated-list-print-entry entry cols)
    (save-excursion
      (goto-char beg)  ;; we are already in the next line
      (tabulated-list-put-tag
       (pcase (agent-review--notification-mark entry)
         ('read "-")
         ('delete "D")
         (_ ""))))
    (if (alist-get 'unread entry)
        (add-face-text-property beg (point) 'agent-review-listview-unread-face 'append)
      (add-face-text-property beg (point) 'agent-review-listview-read-face))  ;; for read-face, its priority is higher. do not append
    (when (agent-review--notification-unsubscribed entry)
      (add-face-text-property beg (point) 'agent-review-listview-unsubscribed-face))
    (pulse-momentary-highlight-region 0 (point))))

(defun agent-review--notification-format-type (entry)
  "Format type column of notification ENTRY."
  (let-alist entry
    (pcase .subject.type
      ("PullRequest" "PR")
      ("Issue" "ISS")
      (_ .subject.type))))

(defun agent-review--notification-unsubscribed (entry)
  "Return the subscription state if ENTRY is unsubscribed, nil if subscribed."
  (let-alist entry
    (when (and .pr-info.viewerSubscription
               (not (equal .pr-info.viewerSubscription "SUBSCRIBED")))
      .pr-info.viewerSubscription)))

(defun agent-review--notification-format-activities (entry)
  "Format activities for notification ENTRY."
  (let ((my-login (let-alist (agent-review--whoami-cached) .viewer.login))
        (op (let-alist entry .pr-info.author.login))
        ;; for the following me-* status: t means yes, 'new means yes+new
        me-mentioned me-assigned me-review-requested me-approved
        new-participants all-participants
        all-reviewers approved-reviewers rejected-reviewers)
    (let-alist entry
      (when op
        (push op all-participants)
        (unless .last_read_at
          ;; add author to commenters if no last read
          (push op new-participants)))
      (dolist (opinionated-review .pr-info.latestOpinionatedReviews.nodes)
        (let-alist opinionated-review
          (pcase .state
            ("APPROVED" (push .author.login approved-reviewers))
            ("CHANGES_REQUESTED" (push .author.login rejected-reviewers)))))
      (setq all-reviewers (mapcar (lambda (n) (let-alist n .requestedReviewer.login)) .pr-info.reviewRequests.nodes)
            me-assigned (cl-find-if (lambda (node) (equal my-login (let-alist node .login)))
                                    .pr-info.assignees.nodes)
            me-review-requested (member my-login all-reviewers)
            me-approved (member my-login approved-reviewers)))
    (dolist (timeline-item (let-alist entry .pr-info.timelineItemsSince.nodes))
      (let-alist timeline-item
        (pcase .__typename
          ("AssignedEvent" (when (equal my-login .assignee.login)
                             (setq me-assigned 'new)))
          ("ReviewRequestedEvent" (when (and (equal my-login .requestedReviewer.login) (not me-approved))
                                    (setq me-review-requested 'new)))
          ("MentionedEvent" (when (equal my-login .actor.login)
                              (setq me-mentioned t)))
          ((or "IssueComment" "PullRequestReview")
           (unless (equal my-login .author.login)
             (push .author.login new-participants)))
          )))
    (dolist (participant-item (let-alist entry .pr-info.participants.nodes))
      (let ((login (let-alist participant-item .login)))
        (unless (or (equal login my-login) (member login new-participants))
          (push login all-participants))))
    (setq all-participants (delete-dups (append (reverse new-participants)
                                                (reverse all-participants))))
    (concat (let-alist entry
              (when (and .pr-info.state (not (equal .pr-info.state "OPEN")))
                (concat (propertize (downcase .pr-info.state) 'face 'agent-review-listview-status-face) " ")))
            (when me-mentioned (propertize "+mentioned " 'face 'agent-review-listview-important-activity-face))
            (pcase me-assigned
              ('new (propertize "+assigned " 'face 'agent-review-listview-important-activity-face))
              ('t (propertize "assigned " 'face 'agent-review-listview-status-face)))
            (pcase me-review-requested
             ('new (propertize "+review_requested " 'face 'agent-review-listview-important-activity-face))
             ('t (propertize "review_requested " 'face 'agent-review-listview-status-face)))
            (when me-approved
              (propertize "approved " 'face 'agent-review-listview-status-face))
            (when all-participants
              (mapconcat
               (lambda (x)
                 (let ((is-new (member x new-participants)))
                   (propertize
                    (concat
                     (when is-new "+")
                     x
                     (cond
                      ((equal x op) "@")
                      ((member x approved-reviewers) "#")
                      ((member x rejected-reviewers) "!")
                      ((member x all-reviewers) "?")))
                    'face
                    (if is-new nil 'agent-review-listview-unimportant-activity-face))))
               all-participants " ")))))

(defun agent-review--notification-refresh ()
  "Refresh notification buffer."
  (unless (eq major-mode 'agent-review-notification-mode)
    (error "Only available in agent-review-notification-mode"))

  (setq-local tabulated-list-format
              [("Updated at" 12 agent-review--notification-entry-sort-updated-at)
               ("Type" 4 t)
               ("Title" 85 nil)
               ("Activities" 25 nil)])
  (let* ((resp-orig (agent-review--get-notifications-with-extra-pr-info
                     agent-review-notification-include-read
                     agent-review--listview-page))
         (resp resp-orig))
    (unless agent-review-notification-include-unsubscribed
      ;; TODO: handle Issue
      (setq resp (seq-filter (lambda (item) (not (agent-review--notification-unsubscribed item)))
                             resp)))
    (setq-local header-line-format
                (substitute-command-keys
                 (format "Page %d, %d items. Filter: %s %s"
                         agent-review--listview-page
                         (length resp)
                         (if agent-review-notification-include-read "+read" "-read")
                         (if agent-review-notification-include-unsubscribed "+unsubscribed"
                           (format "-unsubscribed (%d filtered)" (- (length resp-orig) (length resp)))))))
    ;; refresh marks, remove those with outdated last_updated
    (let ((current-last-updated (make-hash-table :test 'equal)))
      (dolist (entry resp)
        (let-alist entry
          (puthash .id .updated_at current-last-updated)))
      (setq-local agent-review--notification-marks
                  (seq-filter (lambda (item) (equal (nth 2 item)
                                                    (gethash (nth 0 item) current-last-updated)))
                              agent-review--notification-marks)))
    (setq-local
     tabulated-list-entries
     (mapcar (lambda (entry)
               (let-alist entry
                 (list entry
                       (vector
                        (agent-review--listview-format-time .updated_at)
                        (agent-review--notification-format-type entry)
                        (format "[%s] %s" .repository.full_name (string-trim-right .subject.title))
                        (agent-review--notification-format-activities entry)
                        ;; .reason
                        ))))
             resp))
    (tabulated-list-init-header)
    (message (concat (format "Notifications refreshed, %d items." (length resp))
                     (when (> (length resp-orig) (length resp))
                       (format " (filtered %d unsubscribed items)" (- (length resp-orig) (length resp))))))))

(defun agent-review-notification-toggle-filter ()
  "Toggle filter of `agent-review-notification-mode'."
  (interactive)
  (unless (eq major-mode 'agent-review-notification-mode)
    (error "Only available in agent-review-notification-mode"))
  (let ((ans (completing-read "Filter: " '("+read +unsubscribed"
                                           "+read -unsubscribed"
                                           "-read -unsubscribed"
                                           "-read +unsubscribed")
                              nil 'require-match)))
    (setq-local agent-review-notification-include-read (string-match-p (rx "+read") ans)
                agent-review-notification-include-unsubscribed (string-match-p (rx "+unsubscribed") ans)))
  (revert-buffer))

(defun agent-review-notification-remove-mark ()
  "Remove any mark of the entry in current line."
  (interactive)
  (when-let ((entry (get-text-property (point) 'tabulated-list-id)))
    (when (agent-review--notification-mark entry)
      (setq-local agent-review--notification-marks
                  (cl-remove-if (lambda (elem) (equal (car elem) (alist-get 'id entry)))
                                agent-review--notification-marks))
      (tabulated-list-put-tag ""))
    entry))

(defun agent-review-notification-mark-read ()
  "Mark the entry in current line as read."
  (interactive)
  (when-let ((entry (agent-review-notification-remove-mark)))
    (let-alist entry
      (push (list .id 'read .updated_at) agent-review--notification-marks)
      (tabulated-list-put-tag "-"))
    (forward-line)))

(defun agent-review-notification-mark-delete ()
  "Mark the entry in current line as delete."
  (interactive)
  (when-let ((entry (agent-review-notification-remove-mark)))
    (let-alist entry
      (push (list .id 'delete .updated_at) agent-review--notification-marks)
      (tabulated-list-put-tag "D"))
    (forward-line)))

(defun agent-review-notification-execute-mark ()
  "Really execute all mark."
  (interactive)
  (dolist (mark agent-review--notification-marks)
    (pcase (nth 1 mark)
      ('read (agent-review--mark-notification-read (car mark)))
      ;; NOTE: github does not really allow to mark the notification as done/deleted, like in the web interface
      ;; what this API actually does is to mark the notification as unsubscribed.
      ;; in order to make this work, we would not display unsubscribed threads by default. See "filter" above
      ('delete (agent-review--delete-notification (car mark)))))
  (setq-local agent-review--notification-marks nil)
  (revert-buffer))

(defun agent-review--notification-open (entry)
  "Open notification ENTRY."
  (let-alist entry
    (when (and .unread
               (not (agent-review--notification-mark entry)))  ;; do not alter mark
      (push (list .id 'read .updated_at) agent-review--notification-marks)
      (tabulated-list-put-tag "-"))
    (if (equal .subject.type "PullRequest")
        (let ((pr-id (when (string-match (rx (group (+ (any digit))) eos) .subject.url)
                       (match-string 1 .subject.url))))
          (agent-review-open .repository.owner.login .repository.name
                          (string-to-number pr-id)
                          nil  ;; new window
                          nil  ;; anchor nil; do not go to latest comment, use last_read_at
                          .last_read_at))
      (browse-url .subject.url))))

(defun agent-review-notification-open-in-browser ()
  "Open current notification entry in browser."
  (interactive)
  (when-let ((entry (get-text-property (point) 'tabulated-list-id)))
    (let-alist entry
      (browse-url-with-browser-kind 'external .subject.url))))

;;;###autoload
(defun agent-review-notification ()
  "Show github notifications in a new buffer."
  (interactive)
  (with-current-buffer (get-buffer-create "*agent-review notifications*")
    (agent-review-notification-mode)
    (agent-review--notification-refresh)
    (tabulated-list-print)
    (switch-to-buffer (current-buffer))))

(provide 'agent-review-notification)
;;; agent-review-notification.el ends here
