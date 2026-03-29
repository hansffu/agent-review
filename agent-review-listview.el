;;; agent-review-listview.el --- Common list view mode for PRs  -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Yikai Zhao

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

(require 'tabulated-list)
(require 'agent-review-common)


(defface agent-review-listview-unread-face
  '((t :inherit bold))
  "Face used for unread notification rows."
  :group 'agent-review)

(defface agent-review-listview-read-face
  '((t :weight normal))
  "Face used for read notification&search rows."
  :group 'agent-review)

(defface agent-review-listview-unsubscribed-face
  '((t :inherit font-lock-comment-face))
  "Face used for unsubscribed notification&search rows."
  :group 'agent-review)

(defface agent-review-listview-status-face
  '((t :inherit font-lock-keyword-face))
  "Face used for PR status in notification&search list."
  :group 'agent-review)

(defface agent-review-listview-important-activity-face
  '((t :inherit font-lock-warning-face))
  "Face used for important activities in notification&search list."
  :group 'agent-review)

(defface agent-review-listview-unimportant-activity-face
  '((t :weight normal :slant italic))
  "Face used for unimportant activities in notification&search list."
  :group 'agent-review)


(defvar agent-review-listview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "C-c C-n") #'agent-review-listview-next-page)
    (define-key map (kbd "C-c C-p") #'agent-review-listview-prev-page)
    (define-key map (kbd "RET") #'agent-review-listview-open)
    map))

(defvar agent-review--listview-mode-map-setup-for-evil-done nil)

(defun agent-review--listview-mode-map-setup-for-evil ()
  "Setup map in `agent-review-listview-mode' for evil mode (if loaded)."
  (when (and (fboundp 'evil-define-key*)
             (not agent-review--listview-mode-map-setup-for-evil-done))
    (setq agent-review--listview-mode-map-setup-for-evil-done t)
    (evil-define-key* '(normal motion) agent-review-listview-mode-map
      (kbd "RET") #'agent-review-listview-open
      (kbd "gj") #'agent-review-listview-next-page
      (kbd "gk") #'agent-review-listview-prev-page
      (kbd "gn") #'agent-review-listview-goto-page
      (kbd "q") #'kill-current-buffer)))


(defvar-local agent-review--listview-page 1)
(defvar-local agent-review--listview-open-callback nil
  "Function to open an item in list view.  Accept one argument: the item.")

(define-derived-mode agent-review-listview-mode tabulated-list-mode
  "AgentReviewListview"
  "Base mode for PR list view.
Derived modes must set the following variables:
- `tabulated-list-revert-hook'
- `agent-review--listview-open-callback'
And optional:
- `tabulated-list-printer'"
  :interactive nil
  :group 'agent-review
  (agent-review--listview-mode-map-setup-for-evil)
  (use-local-map agent-review-listview-mode-map))

(defun agent-review-listview-next-page ()
  "Go to next page of `agent-review-listview-mode'."
  (interactive)
  (unless (derived-mode-p 'agent-review-listview-mode)
    (error "Only available in agent-review-listview-mode"))
  (setq-local agent-review--listview-page (1+ agent-review--listview-page))
  (revert-buffer))

(defun agent-review-listview-prev-page ()
  "Go to previous page of `agent-review-listview-mode'."
  (interactive)
  (unless (derived-mode-p 'agent-review-listview-mode)
    (error "Only available in agent-review-listview-mode"))
  (when (> agent-review--listview-page 1)
    (setq-local agent-review--listview-page (1- agent-review--listview-page)))
  (revert-buffer))

(defun agent-review-listview-goto-page (page)
  "Go to page PAGE of `agent-review-listview-mode'."
  (interactive "nPage: ")
  (unless (derived-mode-p 'agent-review-listview-mode)
    (error "Only available in agent-review-listview-mode"))
  (setq-local agent-review--listview-page (max page 1))
  (revert-buffer))

(defun agent-review-listview-open ()
  "Open listview at current cursor."
  (interactive)
  (when-let ((entry (get-text-property (point) 'tabulated-list-id)))
    (when (functionp agent-review--listview-open-callback)
      (funcall agent-review--listview-open-callback entry))))


(defun agent-review--listview-format-time (time-str)
  "Format TIME-STR as human readable relative string."
  (let* ((time (date-to-time time-str))
         (delta (float-time (time-subtract (current-time) time))))
    (cond
     ((< delta 3600)
      (format "%.0f min. ago" (/ delta 60)))
     ((equal (time-to-days time) (time-to-days (current-time)))
      (format-time-string "Today %H:%M" time))
     ((< delta (* 5 24 3600))
      (format-time-string "%a. %H:%M" time))
     ((< delta (* 365 24 3600))
      (format-time-string "%b %d" time))
     (t
      (format-time-string "%b %d, %Y" time)))))


(provide 'agent-review-listview)
;;; agent-review-listview.el ends here
