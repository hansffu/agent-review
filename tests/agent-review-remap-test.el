;;; agent-review-remap-test.el --- Remap tests -*- lexical-binding: t; -*-

(require 'test-helper)

(defun agent-review-remap-test--thread (anchor)
  `((thread_id . "thread-1")
    (state . "open")
    (anchor . ,anchor)
    (anchor_status . "active")
    (remap_history . nil)
    (messages . nil)))

(ert-deftest agent-review-collect-diff-anchors-keeps-deleted-file-path ()
  (should (fboundp 'agent-review--collect-diff-anchors))
  (let* ((diff (string-join
                '("diff --git a/removed.txt b/removed.txt"
                  "deleted file mode 100644"
                  "index 1111111..0000000 100644"
                  "--- a/removed.txt"
                  "+++ /dev/null"
                  "@@ -1,2 +0,0 @@"
                  "-gone"
                  "-still gone")
                "\n"))
         (anchors (agent-review--collect-diff-anchors diff "base-1" "head-2"))
         (first (car anchors)))
    (should (equal "removed.txt" (alist-get 'path first)))
    (should (equal "LEFT" (alist-get 'side first)))
    (should (equal 1 (alist-get 'line first)))))

(ert-deftest agent-review-remap-thread-marks-remapped-with-history ()
  (should (fboundp 'agent-review--remap-thread))
  (let* ((thread (agent-review-remap-test--thread
                  '((base_commit . "base-old")
                    (head_commit . "head-old")
                    (path . "demo.txt")
                    (side . "RIGHT")
                    (line . 9)
                    (diff_hunk . "@@ -1,2 +1,3 @@"))))
         (candidates (list '((base_commit . "base-new")
                             (head_commit . "head-new")
                             (path . "demo.txt")
                             (side . "RIGHT")
                             (line . 2)
                             (diff_hunk . "@@ -1,2 +1,3 @@"))))
         (result (agent-review--remap-thread thread candidates "head-new" "2026-03-29T12:00:00Z"))
         (anchor (alist-get 'anchor result))
         (history (car (last (alist-get 'remap_history result)))))
    (should (equal "remapped" (alist-get 'anchor_status result)))
    (should (equal "head-new" (alist-get 'head_commit anchor)))
    (should (equal 2 (alist-get 'line anchor)))
    (should (equal "remapped" (alist-get 'result history)))
    (should (equal "diff_hunk" (alist-get 'method history)))
    (should (equal "head-old"
                   (alist-get 'head_commit (alist-get 'from_anchor history))))))

(ert-deftest agent-review-remap-thread-marks-outdated-when-no-match ()
  (should (fboundp 'agent-review--remap-thread))
  (let* ((thread (agent-review-remap-test--thread
                  '((base_commit . "base-old")
                    (head_commit . "head-old")
                    (path . "demo.txt")
                    (side . "RIGHT")
                    (line . 9)
                    (diff_hunk . "@@ -1,2 +1,3 @@"))))
         (candidates (list '((base_commit . "base-new")
                             (head_commit . "head-new")
                             (path . "other.txt")
                             (side . "RIGHT")
                             (line . 2)
                             (diff_hunk . "@@ -5,2 +5,3 @@"))))
         (result (agent-review--remap-thread thread candidates "head-new" "2026-03-29T12:00:00Z"))
         (anchor (alist-get 'anchor result))
         (history (car (last (alist-get 'remap_history result)))))
    (should (equal "outdated" (alist-get 'anchor_status result)))
    (should (equal "head-old" (alist-get 'head_commit anchor)))
    (should (equal 9 (alist-get 'line anchor)))
    (should (equal "outdated" (alist-get 'result history)))
    (should (equal "none" (alist-get 'method history)))))

(provide 'agent-review-remap-test)
;;; agent-review-remap-test.el ends here
