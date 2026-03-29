;;; agent-review-store-test.el --- Store tests -*- lexical-binding: t; -*-

(require 'test-helper)

(ert-deftest agent-review-store-create-produces-required-schema ()
  (should (fboundp 'agent-review-store-create))
  (let* ((review (agent-review-store-create "/tmp/repo" "feature/offline" "main" "deadbeef" '("deadbeef")))
         (keys '(version review_id repo_root branch base_ref head_ref
                 created_at updated_at head_commits events agent_handoff threads)))
    (dolist (key keys)
      (should (assoc key review)))
    (should (equal "feature/offline" (alist-get 'branch review)))
    (should (equal "main" (alist-get 'base_ref review)))
    (should (equal '("deadbeef") (alist-get 'head_commits review)))))

(ert-deftest agent-review-store-round-trips-and-updates-threads ()
  (should (fboundp 'agent-review-store-review-file))
  (should (fboundp 'agent-review-store-write))
  (should (fboundp 'agent-review-store-read))
  (should (fboundp 'agent-review-store-add-thread))
  (should (fboundp 'agent-review-store-append-reply))
  (should (fboundp 'agent-review-store-set-thread-state))
  (let* ((repo (make-temp-file "agent-review-store-" t))
         (file (agent-review-store-review-file repo "feature/offline"))
         (review (agent-review-store-create repo "feature/offline" "main" "headsha" '("headsha")))
         (anchor '((base_commit . "basesha")
                   (head_commit . "headsha")
                   (path . "demo.txt")
                   (side . "RIGHT")
                   (line . 2)
                   (diff_hunk . "@@ -1 +1,2 @@"))))
    (unwind-protect
        (progn
          (setq review (agent-review-store-add-thread review anchor "First comment" "human" "tester"))
          (let ((thread-id (alist-get 'thread_id (car (alist-get 'threads review)))))
            (setq review (agent-review-store-append-reply review thread-id "Follow-up" "agent" "codex"))
            (setq review (agent-review-store-set-thread-state review thread-id "resolved"))
            (agent-review-store-write file review)
            (setq review (agent-review-store-read file))
            (should (equal repo (alist-get 'repo_root review)))
            (should (equal 1 (length (alist-get 'threads review))))
            (should (equal "resolved" (alist-get 'state (car (alist-get 'threads review)))))
            (should (equal 2 (length (alist-get 'messages (car (alist-get 'threads review))))))))
      (delete-directory repo t))))

(provide 'agent-review-store-test)
;;; agent-review-store-test.el ends here
