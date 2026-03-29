;;; agent-review-search.el --- Search PRs               -*- lexical-binding: t; -*-

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

(require 'agent-review-common)
(require 'agent-review-listview)
(require 'agent-review-api)

(declare-function agent-review-open "agent-review")

(define-derived-mode agent-review-search-mode agent-review-listview-mode
  "AgentReviewSearch"
  :interactive nil
  :group 'agent-review

  (add-hook 'tabulated-list-revert-hook #'agent-review--search-refresh nil 'local)
  (setq-local agent-review--listview-open-callback #'agent-review--search-open-item
              tabulated-list-use-header-line nil
              tabulated-list-padding 2))

(defvar-local agent-review--search-query nil
  "The query string for searching.")

(defun agent-review--search-open-item (item)
  "Open the selected ITEM."
  (let-alist item
    (agent-review-open .repository.owner.login .repository.name .number)))

(defun agent-review--search-format-status (entry)
  "Format status for search item ENTRY."
  (let ((my-login (let-alist (agent-review--whoami-cached) .viewer.login))
        assigned review-requested commenters)
    (let-alist entry
      (setq assigned (cl-find-if (lambda (node) (equal my-login (let-alist node .login)))
                                 .assignees.nodes)
            review-requested (cl-find-if (lambda (node) (equal my-login (let-alist node .requestedReviewer.login)))
                                         .reviewRequests.nodes)))
    (dolist (participant-item (let-alist entry .participants.nodes))
      (let ((login (let-alist participant-item .login)))
        (unless (equal login my-login)
          (push login commenters))))
    (concat (let-alist entry
              (concat (propertize (downcase .state) 'face 'agent-review-listview-status-face) " "))
            (when assigned
              (propertize "assigned " 'face 'agent-review-listview-status-face))
            (when review-requested (propertize "review_requested " 'face 'agent-review-listview-status-face))
            (when commenters
              (mapconcat (lambda (s) (propertize (format "%s " s) 'face 'agent-review-listview-unimportant-activity-face))
                         (delete-dups (reverse commenters)) ""))
            )))

(defun agent-review--search-refresh ()
  "Refresh search buffer."
  (unless (eq major-mode 'agent-review-search-mode)
    (user-error "Not in search buffer"))

  (setq-local tabulated-list-format
              [("Opened" 12 nil)
               ("Author" 10 nil)
               ("Title" 85 nil)
               ("Status" 25 nil)])
  (let* ((all-items (agent-review--search-prs agent-review--search-query))
         (items (seq-filter (lambda (item) (equal (alist-get '__typename item) "PullRequest")) all-items)))
    (setq-local header-line-format
                (concat (format "Search results: %d. " (length items))
                        (unless (equal (length all-items) (length items))
                          (format "(%d non-PRs not displayed) " (- (length all-items) (length items))))
                        (propertize (format "Query: %s" agent-review--search-query)
                                    'face 'font-lock-comment-face)))
    (setq-local tabulated-list-entries
                (mapcar (lambda (item)
                          (let-alist item
                            (list item
                                  (vector
                                   (agent-review--listview-format-time .createdAt)
                                   .author.login
                                   (format "[%s] %s" .repository.nameWithOwner .title)
                                   (agent-review--search-format-status item)
                                   ))))
                        items))
    (tabulated-list-init-header)
    (message (format "Search result refreshed, %d items." (length items)))))

(defcustom agent-review-search-predefined-queries
  '(("is:pr archived:false author:@me is:open" . "Created")
    ("is:pr archived:false assignee:@me is:open" . "Assigned")
    ("is:pr archived:false mentions:@me is:open" . "Mentioned")
    ("is:pr archived:false review-requested:@me is:open" . "Review requests"))
  "Predefined queries for `agent-review-search'.  List of (query . name)."
  :type '(alist :key-type string :value-type string)
  :group 'agent-review)

(defcustom agent-review-search-default-query nil
  "Default query for `agent-review-search-open'."
  :type 'string
  :group 'agent-review)


(defun agent-review--search-read-query ()
  "Read query for search."
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (q) (concat " " (alist-get q agent-review-search-predefined-queries nil nil 'equal))))))
    (completing-read "Search GitHub> "
                     agent-review-search-predefined-queries
                     nil
                     nil  ;; no require-match
                     agent-review-search-default-query)))

;;;###autoload
(defun agent-review-search (query)
  "Search PRs using a custom QUERY and list result in buffer.
See github docs for syntax of QUERY.
When called interactively, you will be asked to enter the QUERY."
  (interactive (list (agent-review--search-read-query)))
  (with-current-buffer (get-buffer-create "*agent-review search*")
    (agent-review-search-mode)
    (setq-local agent-review--search-query query)
    (agent-review--search-refresh)
    (tabulated-list-print)
    (switch-to-buffer (current-buffer))))

;;;###autoload
(defun agent-review-search-open (query)
  "Search PRs using a custom QUERY and open one of them.
See github docs for syntax of QUERY.
When called interactively, you will be asked to enter the QUERY."
  (interactive (list (agent-review--search-read-query)))
  (let* ((prs (agent-review--search-prs query))
         (prs-alist
          (mapcar
           (lambda (pr)
             (let-alist pr
               (cons (format "%s/%s: [%s] %s" .repository.nameWithOwner .number .state .title)
                     (list .repository.owner.login .repository.name .number))))
           prs))
         (selected-pr (completing-read "Select:" prs-alist nil 'require-match)))
    (when-let ((selected-value (alist-get selected-pr prs-alist nil nil 'equal)))
      (apply #'agent-review-open selected-value))))



(provide 'agent-review-search)
;;; agent-review-search.el ends here
