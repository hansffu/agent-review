;;; agent-review-input.el --- Input functions for agent-review  -*- lexical-binding: t; -*-

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

(require 'agent-review-api)
(require 'markdown-mode)

(defvar-local agent-review--input-saved-window-config nil)
(defvar-local agent-review--input-exit-callback nil)
(defvar-local agent-review--input-allow-empty nil)
(defvar-local agent-review--input-refresh-after-exit nil)
(defvar-local agent-review--input-prev-marker nil)

(defvar agent-review-input-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-c" 'agent-review-input-exit)
    (define-key map "\C-c\C-k" 'agent-review-input-abort)
    (define-key map (kbd "C-c @") 'agent-review-input-mention-user)
    map))

(define-derived-mode agent-review-input-mode gfm-mode "AgentReviewInput"
  :interactive nil
  :group 'agent-review
  (use-local-map agent-review-input-mode-map)
  (setq-local truncate-lines nil))

(defun agent-review-input-abort ()
  "Abort current comment input buffer, discard content."
  (interactive)
  (unless (eq major-mode 'agent-review-input-mode) (error "Invalid mode"))
  (let ((saved-window-config agent-review--input-saved-window-config))
    (kill-buffer)
    (when saved-window-config
      (unwind-protect
          (set-window-configuration saved-window-config)))))

(defun agent-review-input-mention-user ()
  "Insert @XXX at current point to mention an user."
  (interactive)
  (let* ((assignable-users (agent-review--get-assignable-users))
         (completion-extra-properties
          (list :annotation-function
                (lambda (login)
                  (concat " " (alist-get 'name (gethash login assignable-users))))))
         (user (completing-read
                "Mention user: "
                (hash-table-keys assignable-users)
                nil 'require-match)))
    (insert "@" user " ")))

(declare-function agent-review-refresh "agent-review")
(defun agent-review-input-exit ()
  "Apply content and exit current comment input buffer."
  (interactive)
  (unless (eq major-mode 'agent-review-input-mode) (error "Invalid mode"))
  (let ((content (buffer-substring-no-properties (point-min) (point-max))))
    (when (and agent-review--input-exit-callback
               (or agent-review--input-allow-empty
                   (not (string-empty-p content))))
      (funcall agent-review--input-exit-callback content)))
  (let ((refresh-after-exit agent-review--input-refresh-after-exit)
        (prev-marker agent-review--input-prev-marker))
    (agent-review-input-abort)
    (when refresh-after-exit
      (when-let ((prev-buffer (marker-buffer prev-marker))
                 (prev-pos (marker-position prev-marker)))
        (switch-to-buffer prev-buffer)
        (agent-review-refresh)
        (goto-char prev-pos)))))

(defun agent-review--open-input-buffer (description open-callback exit-callback &optional refresh-after-exit allow-empty)
  "Open a comment buffer for user input with DESCRIPTION.
OPEN-CALLBACK is called when the buffer is opened,
EXIT-CALLBACK is called when the buffer is exit (not abort),
both callbacks are called inside the comment buffer,
if REFRESH-AFTER-EXIT is not nil,
refresh the current `agent-review' buffer after exit.
If ALLOW-EMPTY is not nil, empty body is also considered a valid result."
  (let ((marker (point-marker))
        (pr-path agent-review--pr-path))
    (with-current-buffer (generate-new-buffer "*agent-review input*")
      (agent-review-input-mode)

      (setq-local
       header-line-format (concat description " "
                                  (substitute-command-keys
                                   (concat "Confirm with `\\[agent-review-input-exit]' or "
                                           "abort with `\\[agent-review-input-abort]'")))
       agent-review--input-saved-window-config (current-window-configuration)
       agent-review--input-exit-callback exit-callback
       agent-review--input-refresh-after-exit refresh-after-exit
       agent-review--input-prev-marker marker
       agent-review--input-allow-empty allow-empty
       ;; for get-assignable-users
       agent-review--pr-path pr-path)

      (when open-callback
        (funcall open-callback))

      (goto-char (point-min))
      (while (search-forward "\r\n" nil t)
        (replace-match "\n" nil t))
      (switch-to-buffer-other-window (current-buffer)))))


(provide 'agent-review-input)
;;; agent-review-input.el ends here
