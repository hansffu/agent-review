;;; agent-review-git.el --- Offline git helpers -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Git helpers for offline agent review.

;;; Code:

(require 'subr-x)

(defun agent-review-git--call (repo-root &rest args)
  "Run git with ARGS inside REPO-ROOT and return stdout."
  (let ((default-directory (or repo-root default-directory)))
    (with-temp-buffer
      (let ((exit-code (apply #'process-file "git" nil (current-buffer) nil args)))
        (unless (eq exit-code 0)
          (error "git %s failed: %s"
                 (string-join args " ")
                 (string-trim (buffer-string))))
        (buffer-string)))))

(defun agent-review-git--lines (repo-root &rest args)
  "Run git with ARGS inside REPO-ROOT and return non-empty lines."
  (split-string (string-trim-right (apply #'agent-review-git--call repo-root args))
                "\n"
                t))

(defun agent-review-git-repo-root (&optional dir)
  "Return the repository root for DIR or `default-directory'."
  (directory-file-name
   (string-trim-right
    (agent-review-git--call dir "rev-parse" "--show-toplevel"))))

(defun agent-review-git-current-branch (&optional repo-root)
  "Return the current branch name for REPO-ROOT."
  (string-trim-right
   (agent-review-git--call repo-root "branch" "--show-current")))

(defun agent-review-git-local-refs (&optional repo-root)
  "Return local branch refs for REPO-ROOT."
  (agent-review-git--lines repo-root "for-each-ref" "--format=%(refname:short)" "refs/heads"))

(defun agent-review-git-default-base-ref (&optional repo-root)
  "Choose the default base ref for REPO-ROOT."
  (let ((refs (agent-review-git-local-refs repo-root)))
    (cond
     ((member "main" refs) "main")
     ((member "master" refs) "master")
     (t (car refs)))))

(defun agent-review-git-prompt-base-ref (&optional repo-root)
  "Prompt for a base ref in REPO-ROOT with free-form input enabled."
  (let* ((refs (agent-review-git-local-refs repo-root))
         (default (agent-review-git-default-base-ref repo-root)))
    (completing-read
     (if default
         (format "Base ref (default %s): " default)
       "Base ref: ")
     refs
     nil
     nil
     nil
     nil
     default
     nil)))

(defun agent-review-git-head-commit (&optional repo-root)
  "Return the current HEAD commit for REPO-ROOT."
  (string-trim-right
   (agent-review-git--call repo-root "rev-parse" "HEAD")))

(defun agent-review-git-rev-parse (repo-root rev)
  "Resolve REV to a full commit in REPO-ROOT."
  (string-trim-right
   (agent-review-git--call repo-root "rev-parse" rev)))

(defun agent-review-git-commit-list (repo-root base-ref)
  "Return commits in BASE-REF..HEAD for REPO-ROOT."
  (agent-review-git--lines repo-root "rev-list" "--reverse" (format "%s..HEAD" base-ref)))

(defun agent-review-git-unified-diff (repo-root base-ref)
  "Return the unified diff for BASE-REF..HEAD in REPO-ROOT."
  (agent-review-git--call repo-root "diff" "--no-color" "--no-ext-diff" "--unified=3"
                          (format "%s..HEAD" base-ref)))

(provide 'agent-review-git)
;;; agent-review-git.el ends here
