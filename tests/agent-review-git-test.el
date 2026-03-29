;;; agent-review-git-test.el --- Git tests -*- lexical-binding: t; -*-

(require 'test-helper)

(ert-deftest agent-review-git-reads-repo-state ()
  (should (fboundp 'agent-review-git-repo-root))
  (should (fboundp 'agent-review-git-current-branch))
  (should (fboundp 'agent-review-git-local-refs))
  (should (fboundp 'agent-review-git-default-base-ref))
  (should (fboundp 'agent-review-git-head-commit))
  (should (fboundp 'agent-review-git-commit-list))
  (should (fboundp 'agent-review-git-unified-diff))
  (should (fboundp 'agent-review-git-commit-headlines))
  (should (fboundp 'agent-review-git-changed-files))
  (should (fboundp 'agent-review-git-diff-summary))
  (agent-review-test-with-temp-repo (repo)
    (should (equal repo (agent-review-git-repo-root repo)))
    (should (equal "feature/offline" (agent-review-git-current-branch repo)))
    (should (member "main" (agent-review-git-local-refs repo)))
    (should (equal "main" (agent-review-git-default-base-ref repo)))
    (should (string-match-p "^[0-9a-f]+$" (agent-review-git-head-commit repo)))
    (should (= 1 (length (agent-review-git-commit-list repo "main"))))
    (should (string-match-p "two" (agent-review-git-unified-diff repo "main")))
    (let ((headlines (agent-review-git-commit-headlines repo "main"))
          (files (agent-review-git-changed-files repo "main"))
          (summary (agent-review-git-diff-summary repo "main")))
      (should (equal 1 (length headlines)))
      (should (equal "feature change" (alist-get 'subject (car headlines))))
      (should (equal "M" (alist-get 'status (car files))))
      (should (equal "demo.txt" (alist-get 'path (car files))))
      (should (equal 1 (alist-get 'files summary)))
      (should (equal 1 (alist-get 'additions summary)))
      (should (equal 0 (alist-get 'deletions summary))))))

(ert-deftest agent-review-git-prompt-base-ref-allows-freeform-input ()
  (should (fboundp 'agent-review-git-prompt-base-ref))
  (let ((captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection predicate require-match initial hist def inherit)
                 (setq captured (list prompt collection predicate require-match initial hist def inherit))
                 "abc1234")))
      (agent-review-test-with-temp-repo (repo)
        (should (equal "abc1234" (agent-review-git-prompt-base-ref repo)))))
    (should-not (nth 3 captured))
    (should (equal "main" (nth 6 captured)))))

(ert-deftest agent-review-git-nil-base-ref-returns-uncommitted-diff ()
  "Nil base-ref should produce a diff of uncommitted changes."
  (agent-review-test-with-temp-repo (repo)
    ;; Add uncommitted change
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((diff (agent-review-git-unified-diff repo nil)))
      (should (stringp diff))
      (should (string-match-p "three" diff)))))

(ert-deftest agent-review-git-nil-base-ref-changed-files ()
  "Nil base-ref should list uncommitted changed files."
  (agent-review-test-with-temp-repo (repo)
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((files (agent-review-git-changed-files repo nil)))
      (should (equal 1 (length files)))
      (should (equal "demo.txt" (alist-get 'path (car files)))))))

(ert-deftest agent-review-git-nil-base-ref-diff-summary ()
  "Nil base-ref should return summary of uncommitted changes."
  (agent-review-test-with-temp-repo (repo)
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (let ((summary (agent-review-git-diff-summary repo nil)))
      (should (equal 1 (alist-get 'files summary)))
      (should (equal 1 (alist-get 'additions summary))))))

(ert-deftest agent-review-git-nil-base-ref-commit-list-returns-nil ()
  "Nil base-ref should return nil for commit list and headlines."
  (agent-review-test-with-temp-repo (repo)
    (should (null (agent-review-git-commit-list repo nil)))
    (should (null (agent-review-git-commit-headlines repo nil)))))

(ert-deftest agent-review-git-has-uncommitted-changes ()
  "Detects uncommitted changes in the working tree."
  (agent-review-test-with-temp-repo (repo)
    (should-not (agent-review-git-has-uncommitted-changes repo))
    (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
    (should (agent-review-git-has-uncommitted-changes repo))))

(ert-deftest agent-review-git-prompt-base-ref-includes-uncommitted ()
  "Uncommitted option appears first when uncommitted changes exist."
  (let ((captured nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt collection predicate require-match initial hist def inherit)
                 (setq captured (list prompt collection predicate require-match initial hist def inherit))
                 "uncommitted")))
      (agent-review-test-with-temp-repo (repo)
        (agent-review-test--write-file (expand-file-name "demo.txt" repo) "one\ntwo\nthree\n")
        (should (equal "uncommitted" (agent-review-git-prompt-base-ref repo)))))
    ;; "uncommitted" should be first in the collection
    (should (equal "uncommitted" (car (nth 1 captured))))
    ;; "uncommitted" should be the default
    (should (equal "uncommitted" (nth 6 captured)))))

(provide 'agent-review-git-test)
;;; agent-review-git-test.el ends here
