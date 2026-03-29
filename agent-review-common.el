;;; agent-review-common.el --- Common definitions for agent-review  -*- lexical-binding: t; -*-

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

(require 'magit-section)

(defgroup agent-review nil "Pr review."
  :group 'tools)

(defface agent-review-title-face
  '((t :inherit outline-1))
  "Face used for title."
  :group 'agent-review)

(defface agent-review-state-face
  '((t :inherit bold))
  "Face used for default state keywords."
  :group 'agent-review)

(defface agent-review-error-state-face
  '((t :inherit font-lock-warning-face :weight bold))
  "Face used for error state (e.g. changes requested)."
  :group 'agent-review)

(defface agent-review-success-state-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face used for success state (e.g. merged)."
  :group 'agent-review)

(defface agent-review-info-state-face
  '((t :slant italic))
  "Face used for info (unimportant) state (e.g. resolved)."
  :group 'agent-review)

(defface agent-review-author-face
  '((t :inherit font-lock-keyword-face))
  "Face used for author names."
  :group 'agent-review)

(defface agent-review-check-face
  '((t :inherit agent-review-author-face))
  "Face used for check names."
  :group 'agent-review)

(defface agent-review-timestamp-face
  '((t :slant italic))
  "Face used for timestamps."
  :group 'agent-review)

(defface agent-review-branch-face
  '((t :inherit font-lock-variable-name-face))
  "Face used for branchs."
  :group 'agent-review)

(defface agent-review-hash-face
  '((t :inherit font-lock-comment-face))
  "Face used for commit hash."
  :group 'agent-review)

(defface agent-review-label-face
  '((t :box t :foregroud "black"))
  "Face used for labels."
  :group 'agent-review)

(defface agent-review-thread-item-title-face
  '((t :inherit magit-section-secondary-heading))
  "Face used for title of review thread item."
  :group 'agent-review)

(defface agent-review-thread-diff-begin-face
  '((t :underline t :extend t :inherit font-lock-comment-face))
  "Face used for the beginning of thread diff hunk."
  :group 'agent-review)

(defface agent-review-thread-diff-body-face
  '((t))
  "Extra face added to the body of thread diff hunk."
  :group 'agent-review)

(defface agent-review-thread-diff-end-face
  '((t :overline t :extend t :inherit font-lock-comment-face))
  "Face used for the beginning of thread diff hunk."
  :group 'agent-review)

(defface agent-review-thread-comment-face
  '((t))
  "Extra face added to review thread comments."
  :group 'agent-review)

(defface agent-review-in-diff-thread-title-face
  '((t :inherit font-lock-comment-face))
  "Face used for the title of the in-diff thread title."
  :group 'agent-review)

(defface agent-review-in-diff-pending-begin-face
  '((t :underline t :extend t :inherit bold-italic))
  "Face used for start line of pending-thread in the diff."
  :group 'agent-review)

(defface agent-review-in-diff-pending-body-face
  '((t))
  "Extra face added to the comment body of pending-thread in the diff."
  :group 'agent-review)

(defface agent-review-in-diff-pending-end-face
  '((t :overline t :extend t :height 0.5 :inherit bold-italic))
  "Face used for end line of pending-thread in the diff."
  :group 'agent-review)

(defface agent-review-link-face
  '((t :underline t))
  "Face used for links."
  :group 'agent-review)

(defface agent-review-button-face
  '((t :underline t :slant italic))
  "Face used for buttons."
  :group 'agent-review)

(defface agent-review-reaction-face
  '((t :height 0.7 :box t))
  "Face used for reaction emojis."
  :group 'agent-review)

(defface agent-review-fringe-comment-pending
  '((t :inherit warning))
  "Face used for fringe icons for pending comments.")

(defface agent-review-fringe-comment-open
  '((t :inherit font-lock-constant-face))
  "Face used for fringe icons for open comments.")

(defface agent-review-fringe-comment-resolved
  '((t :inherit shadow))
  "Face used for fringe icons for resolved comments.")

;; section classes
(defclass agent-review--review-section (magit-section)
  ((body :initform nil)
   (updatable :initform nil)
   (databaseId :initform nil)
   (reaction-groups :initform nil)))

(defclass agent-review--comment-section (magit-section)
  ((body :initform nil)
   (updatable :initform nil)
   (databaseId :initform nil)
   (reaction-groups :initform nil)))

(defclass agent-review--diff-section (magit-section) ())
(defclass agent-review--check-section (magit-section) ())
(defclass agent-review--commit-section (magit-section) ())

(defclass agent-review--review-thread-section (magit-section)
  ((top-comment-id :initform nil)
   (is-resolved :initform nil)))

(defclass agent-review--review-thread-item-section (magit-section)
  ((body :initform nil)
   (updatable :initform nil)
   (databaseId :initform nil)
   (reaction-groups :initform nil)))

(defclass agent-review--root-section (magit-section)
  ((title :initform nil)
   (updatable :initform nil)))

(defclass agent-review--description-section (magit-section)
  ((body :initform nil)
   (updatable :initform nil)
   (reaction-groups :initform nil)))

(defclass agent-review--event-section (magit-section) ())

(defvar-local agent-review--pr-path nil "List of repo-owner, repo-name, pr-id.")
(defvar-local agent-review--pr-info nil "Result of fetch-pr-info, useful for actions.")
(defvar-local agent-review--pending-review-threads nil)
(defvar-local agent-review--selected-commits nil)
(defvar-local agent-review--selected-commit-base nil)
(defvar-local agent-review--selected-commit-head nil)

(defcustom agent-review-generated-file-regexp ".*generated/.*"
  "Regexe that match generated files, which would be collapsed in review."
  :type 'regexp
  :group 'agent-review)

(defcustom agent-review-diff-font-lock-syntax 'hunk-also
  "This value is assigned to `diff-font-lock-syntax' to fontify hunk.
Set to nil to disable source language syntax highlighting."
  :type (get 'diff-font-lock-syntax 'custom-type)
  :group 'agent-review)

(defcustom agent-review-diff-hunk-limit 4
  "Maximum number of lines shown for diff hunks in review threads."
  :type 'number
  :group 'agent-review)

(defvar agent-review-reaction-emojis
  '(("CONFUSED" . "😕")
    ("EYES" . "👀")
    ("HEART" . "❤️")
    ("HOORAY" . "🎉")
    ("LAUGH" . "😄")
    ("ROCKET" . "🚀")
    ("THUMBS_DOWN" . "👎")
    ("THUMBS_UP" . "👍"))
  "Alist of github reaction name to emoji unicode.
See https://docs.github.com/en/graphql/reference/enums#reactioncontent")

(provide 'agent-review-common)
;;; agent-review-common.el ends here
