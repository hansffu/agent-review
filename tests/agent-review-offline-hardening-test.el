;;; agent-review-offline-hardening-test.el --- Offline hardening tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)

(defconst agent-review-offline-hardening-test-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name)))))

(add-to-list 'load-path agent-review-offline-hardening-test-root)

(ert-deftest agent-review-require-does-not-load-provider-lib ()
  (let ((provider-lib (intern (concat "g" "hub")))
        (provider-legacy (intern (concat "g" "hub" "-legacy")))
        (provider-pattern (concat "g" "hub")))
    (dolist (feature (list 'agent-review 'agent-review-git 'agent-review-store
                           provider-lib provider-legacy))
      (when (featurep feature)
        (ignore-errors (unload-feature feature t))))
    (require 'agent-review)
    (should (featurep 'agent-review))
    (should-not (featurep provider-lib))
    (should-not (featurep provider-legacy))
    (should-not
     (seq-some
      (lambda (entry)
        (let ((file (car-safe entry)))
          (and (stringp file)
               (string-match-p provider-pattern file))))
      load-history))))

(provide 'agent-review-offline-hardening-test)
;;; agent-review-offline-hardening-test.el ends here
