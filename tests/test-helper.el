;;; test-helper.el --- Test helpers -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'json)
(require 'subr-x)

(defconst agent-review-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name)))))

(add-to-list 'load-path agent-review-test-root)
(add-to-list 'load-path (expand-file-name "tests" agent-review-test-root))

(load "agent-review-store.el" t t)
(load "agent-review-git.el" t t)
(load "agent-review.el" t t)

(defun agent-review-test--call (program &rest args)
  (with-temp-buffer
    (let ((exit-code (apply #'process-file program nil (current-buffer) nil args)))
      (unless (eq exit-code 0)
        (error "%s %s failed: %s"
               program
               (string-join args " ")
               (string-trim (buffer-string))))
      (string-trim-right (buffer-string)))))

(defun agent-review-test--git (repo &rest args)
  (let ((default-directory repo))
    (apply #'agent-review-test--call "git" args)))

(defun agent-review-test--write-file (path content)
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert content)))

(defun agent-review-test--sample-review (repo branch base-ref head-ref head-commits)
  `((version . 1)
    (review_id . "review-seed")
    (repo_root . ,repo)
    (branch . ,branch)
    (base_ref . ,base-ref)
    (head_ref . ,head-ref)
    (created_at . "2026-03-29T00:00:00Z")
    (updated_at . "2026-03-29T00:00:00Z")
    (head_commits . ,head-commits)
    (events . (((kind . "created")
                (created_at . "2026-03-29T00:00:00Z"))))
    (agent_handoff . nil)
    (threads . nil)))

(defun agent-review-test--write-review-file (path review)
  (make-directory (file-name-directory path) t)
  (let ((json-encoding-pretty-print t))
    (with-temp-file path
      (insert (json-encode review)))))

(defun agent-review-test--init-repo ()
  (let ((repo (make-temp-file "agent-review-test-" t)))
    (agent-review-test--git repo "init")
    (agent-review-test--git repo "config" "user.name" "Test User")
    (agent-review-test--git repo "config" "user.email" "test@example.com")
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\n")
    (agent-review-test--git repo "add" "demo.txt")
    (agent-review-test--git repo "commit" "-m" "initial")
    (agent-review-test--git repo "branch" "-M" "main")
    (agent-review-test--git repo "checkout" "-b" "feature/offline")
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\n")
    (agent-review-test--git repo "add" "demo.txt")
    (agent-review-test--git repo "commit" "-m" "feature change")
    repo))

(defmacro agent-review-test-with-temp-repo (binding &rest body)
  (declare (indent 1) (debug (sexp body)))
  (let ((repo (car binding)))
    `(let ((,repo (agent-review-test--init-repo)))
       (unwind-protect
           (progn ,@body)
         (ignore-errors (delete-directory ,repo t))))))

(provide 'test-helper)
;;; test-helper.el ends here
