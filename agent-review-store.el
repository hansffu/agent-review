;;; agent-review-store.el --- Local review store -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Persistent JSON storage for offline agent reviews.

;;; Code:

(require 'json)

(defconst agent-review-store-version 1
  "Current on-disk schema version.")

(defconst agent-review-store--array-keys
  '(head_commits events threads remap_history messages)
  "Keys that should be serialized as JSON arrays.")

(defun agent-review-store--now ()
  "Return the current UTC timestamp in ISO-8601 form."
  (format-time-string "%Y-%m-%dT%H:%M:%SZ" (current-time) t))

(defun agent-review-store--id (prefix)
  "Return a new identifier using PREFIX."
  (format "%s-%s-%06d"
          prefix
          (format-time-string "%Y%m%d%H%M%S" (current-time) t)
          (random 1000000)))

(defun agent-review-store--append-event (review kind &optional extra)
  "Append an event with KIND and EXTRA fields to REVIEW."
  (let ((events (alist-get 'events review))
        (event `((kind . ,kind)
                 (created_at . ,(agent-review-store--now)))))
    (dolist (cell extra)
      (setq event (append event (list cell))))
    (setq review (agent-review-store--put review 'events (append events (list event))))
    review))

(defun agent-review-store--touch (review)
  "Update REVIEW timestamps."
  (agent-review-store--put review 'updated_at (agent-review-store--now)))

(defun agent-review-store--put (alist key value)
  "Set KEY in ALIST to VALUE and return ALIST."
  (let ((cell (assoc key alist)))
    (if cell
        (setcdr cell value)
      (setq alist (append alist (list (cons key value)))))
    alist))

(defun agent-review-store-review-file (repo-root branch)
  "Return the review file path for BRANCH inside REPO-ROOT."
  (expand-file-name (concat branch ".json")
                    (expand-file-name ".agent-review" repo-root)))

(defun agent-review-store-create (repo-root branch base-ref head-ref head-commits &optional review-type)
  "Create a new review for REPO-ROOT, BRANCH, BASE-REF, HEAD-REF and HEAD-COMMITS.
REVIEW-TYPE is \"branch\" (default) or \"uncommitted\"."
  (let ((now (agent-review-store--now)))
    (list
     (cons 'version agent-review-store-version)
     (cons 'review_type (or review-type "branch"))
     (cons 'review_id (agent-review-store--id "review"))
     (cons 'repo_root repo-root)
     (cons 'branch branch)
     (cons 'base_ref base-ref)
     (cons 'head_ref head-ref)
     (cons 'created_at now)
     (cons 'updated_at now)
     (cons 'head_commits (and head-commits (copy-sequence head-commits)))
     (cons 'events (list (list (cons 'kind "created")
                               (cons 'created_at now))))
     (cons 'agent_handoff nil)
     (cons 'threads nil))))

(defun agent-review-store-read (file)
  "Read review data from FILE."
  (let* ((json-object-type 'alist)
         (json-array-type 'list)
         (json-key-type 'symbol)
         (json-false :false)
         (review (json-read-file file)))
    (unless (alist-get 'review_type review)
      (setq review (cons (cons 'review_type "branch") review)))
    review))

(defun agent-review-store-uncommitted-review-file (repo-root branch)
  "Return the uncommitted review file path for BRANCH inside REPO-ROOT."
  (expand-file-name (concat branch "-uncommitted.json")
                    (expand-file-name ".agent-review" repo-root)))

(defun agent-review-store-write (file review)
  "Write REVIEW to FILE."
  (make-directory (file-name-directory file) t)
  (let ((json-encoding-pretty-print t))
    (with-temp-file file
      (insert (json-encode (agent-review-store--json-ready review)))))
  file)

(defun agent-review-store--json-ready (value &optional key)
  "Convert VALUE into a form that `json-encode' handles reliably for KEY."
  (cond
   ((memq key agent-review-store--array-keys)
    (vconcat (mapcar #'agent-review-store--json-ready value)))
   ((and (listp value)
         (or (null value)
             (and (consp (car value))
                  (symbolp (car (car value))))))
    (mapcar (lambda (cell)
              (cons (car cell)
                    (agent-review-store--json-ready (cdr cell) (car cell))))
            value))
   ((listp value)
    (mapcar #'agent-review-store--json-ready value))
   (t value)))

(defun agent-review-store-add-thread (review anchor body &optional author-type author-id snapshot-diff-hunk)
  "Add a new thread with ANCHOR and BODY to REVIEW.
SNAPSHOT-DIFF-HUNK stores the original reviewed diff snippet."
  (let* ((thread-id (agent-review-store--id "thread"))
         (now (agent-review-store--now))
         (message `((message_id . ,(agent-review-store--id "msg"))
                    (author_type . ,(or author-type "human"))
                    (author_id . ,(or author-id "unknown"))
                    (kind . "comment")
                    (body . ,body)
                    (created_at . ,now)))
         (thread `((thread_id . ,thread-id)
                   (state . "open")
                   (anchor . ,anchor)
                   (anchor_status . "active")
                   (remap_history . nil)
                   (messages . (,message)))))
    (when (and snapshot-diff-hunk (> (length snapshot-diff-hunk) 0))
      (setq thread (append thread `((snapshot_diff_hunk . ,snapshot-diff-hunk)))))
    (setq review
          (agent-review-store--put review 'threads
                                   (append (alist-get 'threads review) (list thread))))
    (agent-review-store--append-event
     (agent-review-store--touch review)
     "thread_created"
     `((thread_id . ,thread-id)))
    review))

(defun agent-review-store-append-reply (review thread-id body &optional author-type author-id)
  "Append a reply BODY to THREAD-ID inside REVIEW."
  (let ((found nil)
        (now (agent-review-store--now)))
    (setq review
          (agent-review-store--put
           review 'threads
           (mapcar
            (lambda (thread)
              (if (equal (alist-get 'thread_id thread) thread-id)
                  (progn
                    (setq found t)
                    (agent-review-store--put
                     thread 'messages
                     (append
                      (alist-get 'messages thread)
                      (list `((message_id . ,(agent-review-store--id "msg"))
                              (author_type . ,(or author-type "human"))
                              (author_id . ,(or author-id "unknown"))
                              (kind . "reply")
                              (body . ,body)
                              (created_at . ,now)))))
                    thread)
                thread))
            (alist-get 'threads review))))
    (unless found
      (error "Unknown thread: %s" thread-id))
    (agent-review-store--append-event
     (agent-review-store--touch review)
     "thread_replied"
     `((thread_id . ,thread-id)))
    review))

(defun agent-review-store-set-thread-state (review thread-id state)
  "Set THREAD-ID in REVIEW to STATE."
  (let ((found nil))
    (setq review
          (agent-review-store--put
           review 'threads
           (mapcar
            (lambda (thread)
              (if (equal (alist-get 'thread_id thread) thread-id)
                  (progn
                    (setq found t)
                    (agent-review-store--put thread 'state state))
                thread))
            (alist-get 'threads review))))
    (unless found
      (error "Unknown thread: %s" thread-id))
    (agent-review-store--append-event
     (agent-review-store--touch review)
     "thread_state_changed"
     `((thread_id . ,thread-id)
       (state . ,state)))
    review))

(provide 'agent-review-store)
;;; agent-review-store.el ends here
