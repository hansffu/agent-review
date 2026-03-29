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

(defun agent-review-git-untracked-files (&optional repo-root)
  "Return list of untracked files in REPO-ROOT."
  (let ((output (string-trim-right
                 (agent-review-git--call repo-root "ls-files" "--others" "--exclude-standard"))))
    (when (> (length output) 0)
      (split-string output "\n" t))))

(defun agent-review-git-has-uncommitted-changes (&optional repo-root)
  "Return non-nil if REPO-ROOT has uncommitted changes against HEAD."
  (let ((default-directory (or repo-root default-directory)))
    (or (not (eq 0 (process-file "git" nil nil nil "diff" "--quiet" "HEAD")))
        (not (null (agent-review-git-untracked-files repo-root))))))

(defun agent-review-git-prompt-base-ref (&optional repo-root)
  "Prompt for a base ref in REPO-ROOT with free-form input enabled.
When uncommitted changes exist, \"uncommitted\" is offered as the default."
  (let* ((refs (agent-review-git-local-refs repo-root))
         (has-uncommitted (agent-review-git-has-uncommitted-changes repo-root))
         (candidates (if has-uncommitted (cons "uncommitted" refs) refs))
         (default (if has-uncommitted
                      "uncommitted"
                    (agent-review-git-default-base-ref repo-root))))
    (completing-read
     (if default
         (format "Base ref (default %s): " default)
       "Base ref: ")
     candidates
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

(defun agent-review-git--diff-ref (base-ref)
  "Return the git diff ref argument for BASE-REF.
When BASE-REF is nil, returns \"HEAD\" for uncommitted changes.
Otherwise returns \"BASE-REF..HEAD\"."
  (if base-ref (format "%s..HEAD" base-ref) "HEAD"))

(defun agent-review-git-commit-list (repo-root base-ref)
  "Return commits in BASE-REF..HEAD for REPO-ROOT.
Returns nil when BASE-REF is nil."
  (when base-ref
    (agent-review-git--lines repo-root "rev-list" "--reverse" (format "%s..HEAD" base-ref))))

(defun agent-review-git-unified-diff (repo-root base-ref)
  "Return the unified diff for BASE-REF..HEAD in REPO-ROOT.
When BASE-REF is nil, returns the diff of uncommitted changes against HEAD."
  (agent-review-git--call repo-root "diff" "--no-color" "--no-ext-diff" "--unified=3"
                          (agent-review-git--diff-ref base-ref)))

(defun agent-review-git-commit-headlines (repo-root base-ref)
  "Return commit headlines in BASE-REF..HEAD for REPO-ROOT.
Each entry is an alist with keys `short' and `subject'.
Returns nil when BASE-REF is nil."
  (when base-ref
    (mapcar
     (lambda (line)
       (pcase-let ((`(,short ,subject)
                    (split-string line "\t" t)))
         `((short . ,short)
           (subject . ,subject))))
     (agent-review-git--lines repo-root "log" "--format=%h%x09%s"
                              (format "%s..HEAD" base-ref)))))

(defun agent-review-git-changed-files (repo-root base-ref)
  "Return changed files in BASE-REF..HEAD for REPO-ROOT.
Each entry is an alist with keys `status' and `path'."
  (mapcar
   (lambda (line)
     (let* ((parts (split-string line "\t"))
            (status (car parts))
            (path (cond
                   ((and (string-prefix-p "R" status) (= (length parts) 3))
                    (format "%s -> %s" (nth 1 parts) (nth 2 parts)))
                   ((>= (length parts) 2)
                    (nth 1 parts))
                   (t (or (cadr parts) "")))))
       `((status . ,status)
         (path . ,path))))
   (agent-review-git--lines repo-root "diff" "--name-status" "--no-color"
                            (agent-review-git--diff-ref base-ref))))

(defun agent-review-git-diff-summary (repo-root base-ref)
  "Return diff summary counts in BASE-REF..HEAD for REPO-ROOT."
  (let ((files 0)
        (additions 0)
        (deletions 0))
    (dolist (line (agent-review-git--lines repo-root "diff" "--numstat" "--no-color"
                                           (agent-review-git--diff-ref base-ref)))
      (pcase-let* ((`(,additions-str ,deletions-str . ,_) (split-string line "\t"))
                   (binary-file (or (equal additions-str "-")
                                    (equal deletions-str "-"))))
        (setq files (1+ files))
        (unless binary-file
          (setq additions (+ additions (string-to-number additions-str))
                deletions (+ deletions (string-to-number deletions-str))))))
    `((files . ,files)
      (additions . ,additions)
      (deletions . ,deletions))))

(provide 'agent-review-git)
;;; agent-review-git.el ends here
