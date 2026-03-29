;;; agent-review.el --- Review github PR    -*- lexical-binding: t; -*-

;; Copyright (C) 2021  Yikai Zhao

;; Author: Yikai Zhao <yikai@z1k.dev>
;; Keywords: tools
;; Version: 0.1
;; URL: https://github.com/blahgeek/emacs-agent-review
;; Package-Requires: ((emacs "27.1") (magit-section "4.0") (magit "4.0") (markdown-mode "2.5") (ghub "5.0"))

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

;; Review github PR in EMACS.

;;; Code:

(require 'agent-review-common)
(require 'agent-review-api)
(require 'agent-review-input)
(require 'agent-review-render)
(require 'agent-review-action)
(require 'tabulated-list)

(defun agent-review--confirm-kill-buffer ()
  "Hook for `kill-buffer-query-functions', confirm if there's pending reviews."
  (or (null agent-review--pending-review-threads)
      (yes-or-no-p "Pending review threads exist in current buffer, really exit? ")))

(defvar agent-review-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map magit-section-mode-map)
    (define-key map (kbd "C-c C-r") #'agent-review-refresh)
    (define-key map (kbd "C-c C-c") #'agent-review-context-comment)
    (define-key map (kbd "C-c C-s") #'agent-review-context-action)
    (define-key map (kbd "C-c C-e") #'agent-review-context-edit)
    (define-key map (kbd "C-c C-v") #'agent-review-view-file)
    (define-key map (kbd "C-c C-f") #'agent-review-goto-file)
    (define-key map (kbd "C-c C-d") #'agent-review-ediff-file)
    (define-key map (kbd "C-c C-o") #'agent-review-open-in-default-browser)
    (define-key map (kbd "C-c C-q") #'agent-review-request-reviews)
    (define-key map (kbd "C-c C-l") #'agent-review-set-labels)
    (define-key map (kbd "C-c C-j") #'agent-review-update-reactions)
    map))

(defvar agent-review--mode-map-setup-for-evil-done nil)

(defun agent-review--mode-map-setup-for-evil ()
  "Setup map in `agent-review-mode-map' for evil mode (if loaded)."
  (when (and (fboundp 'evil-define-key*)
             (not agent-review--mode-map-setup-for-evil-done))
    (setq agent-review--mode-map-setup-for-evil-done t)
    (evil-define-key* '(normal motion) agent-review-mode-map
      (kbd "g r") #'agent-review-refresh
      (kbd "TAB") #'magit-section-toggle
      (kbd "z a") #'magit-section-toggle
      (kbd "z o") #'magit-section-show
      (kbd "z O") #'magit-section-show-children
      (kbd "z c") #'magit-section-hide
      (kbd "z C") #'magit-section-hide-children
      (kbd "z r") #'agent-review-increase-show-level
      (kbd "z R") #'agent-review-maximize-show-level
      (kbd "z m") #'agent-review-decrease-show-level
      (kbd "z M") #'agent-review-minimize-show-level
      (kbd "g h") #'magit-section-up
      (kbd "C-j") #'magit-section-forward
      (kbd "g j") #'magit-section-forward-sibling
      (kbd "C-k") #'magit-section-backward
      (kbd "g k") #'magit-section-backward-sibling
      (kbd "g f") #'agent-review-goto-file
      (kbd "g o") #'agent-review-open-in-default-browser
      [remap evil-previous-line] 'evil-previous-visual-line
      [remap evil-next-line] 'evil-next-visual-line
      (kbd "C-o") #'pop-to-mark-command
      (kbd "q") #'kill-current-buffer)))

(defvar-local agent-review--current-show-level 3)

(defun agent-review-increase-show-level ()
  "Increase the level of showing sections in current buffer.
Also see `magit-section-show-level'."
  (interactive)
  (when (< agent-review--current-show-level 4)
    (setq agent-review--current-show-level (1+ agent-review--current-show-level)))
  (magit-section-show-level (- agent-review--current-show-level)))

(defun agent-review-decrease-show-level ()
  "Decrease the level of showing sections in current buffer.
Also see `magit-section-show-level'."
  (interactive)
  (when (> agent-review--current-show-level 1)
    (setq agent-review--current-show-level (1- agent-review--current-show-level)))
  (magit-section-show-level (- agent-review--current-show-level)))

(defun agent-review-maximize-show-level ()
  "Set the level of showing sections to maximum in current buffer.
Which means that all sections are expanded."
  (interactive)
  (setq agent-review--current-show-level 4)
  (magit-section-show-level -4))

(defun agent-review-minimize-show-level ()
  "Set the level of showing sections to minimum in current buffer.
Which means that all sections are collapsed."
  (interactive)
  (setq agent-review--current-show-level 1)
  (magit-section-show-level -1))

(defun agent-review--eldoc-function (&rest _)
  "Hook for `eldoc-documentation-function', return content at current point."
  (get-text-property (point) 'agent-review-eldoc-content))

(define-derived-mode agent-review-mode magit-section-mode "AgentReview"
  :interactive nil
  :group 'agent-review
  (agent-review--mode-map-setup-for-evil)
  (use-local-map agent-review-mode-map)
  (setq-local font-lock-defaults nil)  ;; https://github.com/magit/magit/commit/7de0f1335f8c4954d6d07413c5ec19fc8200078c
  (setq-local magit-hunk-section-map nil
              magit-file-section-map nil
              magit-diff-highlight-hunk-body nil)
  (setq-local imenu-create-index-function #'magit--imenu-create-index
              imenu-default-goto-function #'magit--imenu-goto-function
              magit--imenu-item-types '(agent-review--review-section
                                        agent-review--comment-section
                                        agent-review--diff-section
                                        agent-review--check-section
                                        agent-review--commit-section
                                        agent-review--description-section
                                        agent-review--event-section))
  (when agent-review-fringe-icons
    (unless (and left-fringe-width (>= left-fringe-width 16))
      (setq left-fringe-width 16)))
  (add-to-list 'kill-buffer-query-functions 'agent-review--confirm-kill-buffer)
  (add-hook 'eldoc-documentation-functions #'agent-review--eldoc-function nil t)
  (eldoc-mode))

(defun agent-review--refresh-internal ()
  "Fetch and reload current AgentReview buffer."
  (let* ((pr-info (agent-review--fetch-pr-info))
         (pr-diff (let-alist pr-info
                    (agent-review--fetch-compare-cached
                     (or agent-review--selected-commit-base .baseRefOid)
                     (or agent-review--selected-commit-head .headRefOid))))
         section-id)
    (setq-local agent-review--pr-info pr-info
                mark-ring nil)
    (when-let ((section (magit-current-section)))
      (setq section-id (oref section value)))
    (let ((inhibit-read-only t))
      (erase-buffer)
      (agent-review--insert-pr pr-info pr-diff)
      (mapc (lambda (th) (agent-review--insert-in-diff-pending-review-thread
                          th 'allow-fallback))
            agent-review--pending-review-threads))
    (if section-id
        (agent-review--goto-section-with-value section-id)
      (goto-char (point-min)))
    (magit-map-sections 'magit-section-maybe-update-visibility-indicator)
    (apply #'message "PR %s/%s/%s loaded" agent-review--pr-path)))

(defun agent-review-refresh (&optional clear-pending-reviews)
  "Fetch and reload current AgentReview buffer.
If CLEAR-PENDING-REVIEWS is not nil, delete pending reviews if any,
otherwise, ask interactively."
  (interactive)
  (when (and agent-review--pending-review-threads
             (or clear-pending-reviews
                 (not (yes-or-no-p "Keep pending review threads (may not work if the changes are updated)? "))))
    (setq-local agent-review--pending-review-threads nil))
  (agent-review--refresh-internal))

;;;###autoload
(defun agent-review-url-parse (url)
  "Return pr path (repo-owner repo-name pr-id) for URL, or nil on error."
  (when-let* ((url-parsed (url-generic-parse-url url))
              (path (url-filename url-parsed)))
    (when (and (member (url-type url-parsed) '("http" "https"))
               (string-match (rx "/" (group (+ (any alphanumeric ?- ?_ ?.)))
                                 "/" (group (+ (any alphanumeric ?- ?_ ?.)))
                                 "/pull" (? "s") "/" (group (+ (any digit))))
                             (url-filename url-parsed)))
      (list (match-string 1 path)
            (match-string 2 path)
            (string-to-number (match-string 3 path))))))

(defun agent-review--url-parse-anchor (url)
  "Return anchor id for URL, or nil on error.
Example: given pr url https://github.com/.../pull/123#discussion_r12345,
return 12345 (as string).
This is used to jump to specific section after opening the buffer."
  (when-let ((fragment (cadr (split-string url "#"))))
    (when (string-match (rx (group (+ (any digit)))) fragment)
      (match-string 1 fragment))))

;;;###autoload
(defun agent-review-open (repo-owner repo-name pr-id &optional new-window anchor last-read-time)
  "Open review buffer for REPO-OWNER/REPO-NAME PR-ID (number).
Open in current window if NEW-WINDOW is nil, in other window otherwise.
ANCHOR is a database id that may be present in the url fragment
of a github pr notification, if it's not nil, try to jump to specific
location after open.
LAST-READ-TIME is the time when the PR is last read (in ISO string,
mostly from notification buffer),
if it's not nil, newer comments will be highlighted,
and it will jump to first unread comment if ANCHOR is nil."
  (with-current-buffer (get-buffer-create (format "*agent-review %s/%s/%s*" repo-owner repo-name pr-id))
    (unless (eq major-mode 'agent-review-mode)
      (agent-review-mode))
    (setq-local agent-review--pr-path (list repo-owner repo-name pr-id))
    (let ((agent-review--last-read-time last-read-time))
      (agent-review-refresh))
    (unless (and anchor (agent-review-goto-database-id anchor))
      (when-let ((m (text-property-search-forward 'agent-review-unread t t)))
        (goto-char (prop-match-beginning m))))
    (funcall (if new-window
                 'switch-to-buffer-other-window
               'switch-to-buffer)
             (current-buffer))
    ;; for some known reason, recenter only works reliably after a redisplay
    (redisplay)
    (recenter)))

(defun agent-review--find-url-in-buffer ()
  "Return a possible pr url in current buffer.
It's used as the default value of `agent-review'."
  (or
   ;; url at point
   (when-let ((url (thing-at-point 'url t)))
     (when (agent-review-url-parse url)
       url))
   ;; find links in buffer. Useful in buffer with github notification emails
   (when-let ((prop (text-property-search-forward
                     'shr-url nil
                     (lambda (_ val) (and val (agent-review-url-parse val))))))
     (goto-char (prop-match-beginning prop))
     (prop-match-value prop))))

(defun agent-review--interactive-arg ()
  "Return args for interactive call for `agent-review'."
  (list
   ;; url
   (let* ((default-url (agent-review--find-url-in-buffer))
          (default-pr-path (and default-url (agent-review-url-parse default-url)))
          (input-url (read-string (concat "URL to review"
                                          (when default-pr-path
                                            (apply #'format " (default: %s/%s/%s)"
                                                   default-pr-path))
                                          ": "))))
     (if (string-empty-p input-url)
         (or default-url "")
       input-url))
   ;; new-window
   current-prefix-arg))

;;;###autoload
(defun agent-review (url &optional new-window)
  "Open Pr Review with URL (which is a link to github pr).
This is the main entrypoint of `agent-review'.
If NEW-WINDOW is not nil, open it in a new window.
When called interactively, user will be prompted to enter a PR url
and new window will be used when called with prefix."
  (interactive (agent-review--interactive-arg))
  (let ((res (agent-review-url-parse url))
        (anchor (agent-review--url-parse-anchor url)))
    (if (not res)
        (message "Cannot parse URL %s" url)
      (apply #'agent-review-open (append res (list new-window anchor))))))

;;;###autoload
(defun agent-review-open-url (url &optional new-window &rest _)
  "Open Pr Review with URL, in a new window if NEW-WINDOW is not nil.
This function is the same as `agent-review',
but it can be used in `browse-url-handlers' with `agent-review-url-parse'."
  (agent-review url new-window))


(provide 'agent-review)
;;; agent-review.el ends here
