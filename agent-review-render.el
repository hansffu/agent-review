;;; agent-review-render.el --- Magit renderer for agent-review -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Magit-section based diff rendering for offline reviews.

;;; Code:

(require 'subr-x)
(require 'magit)
(require 'magit-section)
(require 'magit-diff)

(defvar agent-review-diff-font-lock-syntax 'hunk-also)

(defcustom agent-review-use-delta t
  "When non-nil, use delta for syntax highlighting in diffs.
Requires the `delta' executable and the `xterm-color' package."
  :type 'boolean
  :group 'agent-review)

(defcustom agent-review-delta-executable "delta"
  "Path to the delta executable."
  :type 'string
  :group 'agent-review)

(defcustom agent-review-delta-args
  '("--max-line-distance" "0.6"
    "--true-color" "always"
    "--color-only" "--paging" "never"
    "--dark" "--syntax-theme" "OneHalfDark")
  "Arguments passed to delta for diff syntax highlighting."
  :type '(repeat string)
  :group 'agent-review)

(defvar-local agent-review--diff-begin-point 0)
(defvar-local agent-review--base-commit nil)
(defvar-local agent-review--head-commit nil)

(defvar agent-review--delta-faces-to-remap
  '(magit-diff-context-highlight
    magit-diff-added
    magit-diff-added-highlight
    magit-diff-removed
    magit-diff-removed-highlight)
  "Magit faces remapped to `default' when delta provides coloring.")

(defun agent-review-render-setup-mode ()
  "Configure the current buffer for Magit-style review rendering."
  (setq-local font-lock-defaults nil)
  (setq-local magit-hunk-section-map nil
              magit-file-section-map nil
              magit-diff-highlight-hunk-body nil)
  (when (and agent-review-use-delta
             (executable-find agent-review-delta-executable))
    (setq-local magit-diff-refine-hunk nil)
    (setq-local face-remapping-alist
                (append (mapcar (lambda (face) (cons face 'default))
                                agent-review--delta-faces-to-remap)
                        face-remapping-alist))))

(defun agent-review-render--fontify (body lang-mode &optional margin)
  "Fontify BODY as LANG-MODE and return a propertized string.
If MARGIN is non-nil, indent each line by MARGIN spaces."
  (with-current-buffer
      (get-buffer-create (format " *agent-review-fontification:%s*" lang-mode))
    (let ((inhibit-modification-hooks nil))
      (erase-buffer)
      (insert "\n"
              (replace-regexp-in-string "\r\n" "\n" (or body "") nil t))
      (unless (or (string-empty-p body)
                  (string-suffix-p "\n" body))
        (insert "\n"))
      (unless (eq major-mode lang-mode)
        (funcall lang-mode))
      (when (eq lang-mode 'diff-mode)
        (setq-local diff-font-lock-syntax agent-review-diff-font-lock-syntax))
      (condition-case-unless-debug nil
          (font-lock-ensure)
        (error nil)))

    ;; Strip invisible text so output is stable in review buffers.
    (let (match)
      (goto-char (point-min))
      (while (setq match (text-property-search-forward 'invisible))
        (remove-text-properties (prop-match-beginning match)
                                (prop-match-end match)
                                '(invisible nil))))

    (when (eq lang-mode 'diff-mode)
      (dolist (overlay (overlays-in (point-min) (point-max)))
        (when (eq (overlay-get overlay 'diff-mode) 'syntax)
          (when-let ((face (overlay-get overlay 'face)))
            (add-face-text-property (overlay-start overlay)
                                    (overlay-end overlay)
                                    face))))
      (remove-overlays (point-min) (point-max) 'diff-mode 'syntax))

    (let ((result (buffer-substring 2 (point-max))))
      (when margin
        (setq result
              (replace-regexp-in-string (rx bol) (make-string margin ?\s) result)))
      result)))

(defun agent-review-render--insert-fontified (body lang-mode &optional margin)
  "Fontify BODY as LANG-MODE and insert it.
If MARGIN is non-nil, indent each line by MARGIN spaces."
  (insert (agent-review-render--fontify body lang-mode margin)))

(defun agent-review-render-insert-markdown (body &optional margin extra-face)
  "Insert BODY as markdown with optional MARGIN and EXTRA-FACE.
Falls back to plain text insertion when `gfm-mode' is unavailable."
  (let ((start (point))
        (text (or body "")))
    (if (fboundp 'gfm-mode)
        (condition-case nil
            (agent-review-render--insert-fontified text 'gfm-mode margin)
          (error
           (when margin
             (setq text
                   (replace-regexp-in-string (rx bol) (make-string margin ?\s) text)))
           (insert text)
           (unless (or (string-empty-p text) (string-suffix-p "\n" text))
             (insert "\n"))))
      (when margin
        (setq text
              (replace-regexp-in-string (rx bol) (make-string margin ?\s) text)))
      (insert text)
      (unless (or (string-empty-p text) (string-suffix-p "\n" text))
        (insert "\n")))
    (when extra-face
      (add-face-text-property start (point) extra-face))))

(defun agent-review-render--line-side (line-beg)
  "Return review side for diff line at LINE-BEG."
  (pcase (char-after line-beg)
    (?\s "RIGHT")
    (?- "LEFT")
    (?+ "RIGHT")
    (_ nil)))

(defun agent-review-render--line-anchor (line-beg diff-hunk)
  "Build anchor for the diff line at LINE-BEG and DIFF-HUNK."
  (let* ((left (get-text-property line-beg 'agent-review-diff-line-left))
         (right (get-text-property line-beg 'agent-review-diff-line-right))
         (side (agent-review-render--line-side line-beg))
         (payload (if (equal side "LEFT") left right)))
    (when (and side payload diff-hunk)
      `((base_commit . ,agent-review--base-commit)
        (head_commit . ,agent-review--head-commit)
        (path . ,(car payload))
        (side . ,side)
        (line . ,(cdr payload))
        (diff_hunk . ,diff-hunk)))))

(defun agent-review-render--normalize-path (path)
  "Normalize PATH so anchors can match diff properties across formats."
  (when path
    (let ((trimmed path))
      (when (string-match "\\`a/\\(.+\\) -> b/\\(.+\\)\\'" trimmed)
        (setq trimmed (match-string 2 trimmed)))
      (when (string-match "\\`[ab]/\\(.+\\)\\'" trimmed)
        (setq trimmed (match-string 1 trimmed)))
      trimmed)))

(defun agent-review-render--annotate-diff-anchors (beg)
  "Annotate lines from BEG with `agent-review-diff-anchor' properties."
  (save-excursion
    (goto-char beg)
    (forward-line -1)
    (let (diff-hunk)
      (while (zerop (forward-line))
        (let* ((line-beg (line-beginning-position))
               (line-end (line-end-position))
               (line (buffer-substring-no-properties line-beg line-end)))
          (when (string-prefix-p "@@ " line)
            (setq diff-hunk line))
          (when-let ((anchor (agent-review-render--line-anchor line-beg diff-hunk)))
            (put-text-property line-beg line-end 'agent-review-diff-anchor anchor)))))))

(defun agent-review-render-goto-diff-line (filepath diffside line)
  "Go to diff line for FILEPATH, DIFFSIDE (LEFT/RIGHT) and LINE.
Return non-nil on success."
  (goto-char agent-review--diff-begin-point)
  (when-let ((match (text-property-search-forward
                     (if (equal diffside "LEFT")
                         'agent-review-diff-line-left
                       'agent-review-diff-line-right)
                     (cons filepath line)
                     (lambda (target value)
                       (and value
                            (let ((target-path (car target))
                                  (value-path (car value))
                                  (target-line (cdr target))
                                  (value-line (cdr value)))
                              (and (or (equal target-path value-path)
                                       (equal (agent-review-render--normalize-path target-path)
                                              (agent-review-render--normalize-path value-path)))
                                   (or (null target-line)
                                       (equal target-line value-line)))))))))
    (goto-char (prop-match-beginning match))
    t))

(defun agent-review-render--apply-delta (beg end)
  "Pipe region BEG to END through delta and convert ANSI to overlays.
Return the end position of the replacement text."
  (require 'xterm-color)
  (let* ((input (buffer-substring-no-properties beg end))
         (process-directory (if (file-directory-p default-directory)
                                default-directory
                              temporary-file-directory))
         (output
          (with-temp-buffer
            (let ((default-directory process-directory))
              (insert input)
              (apply #'call-process-region (point-min) (point-max)
                     agent-review-delta-executable t t nil
                     agent-review-delta-args)
              (buffer-string))))
        (inhibit-read-only t)
        (buffer-read-only nil)
        end-marker)
    (delete-region beg end)
    (goto-char beg)
    (insert output)
    (setq end-marker (copy-marker (point) t))
    (save-restriction
      (narrow-to-region beg end-marker)
      (xterm-color-colorize-buffer 'use-overlays))
    (prog1 (marker-position end-marker)
      (set-marker end-marker nil))))

(defun agent-review-render--wash-diff (beg end)
  "Wash the diff between BEG and END into Magit sections."
  (let ((end-marker (copy-marker end t)))
    (unwind-protect
        (save-restriction
          (narrow-to-region beg end-marker)
          (goto-char (point-min))
          (magit-wash-sequence
           (apply-partially #'magit-diff-wash-diff nil)))
      (set-marker end-marker nil))))

(defun agent-review-render--sanitize-diff-chunk-for-magit (chunk)
  "Return CHUNK with enough file headers for Magit's diff washer."
  (cond
   ((and (string-match "\\`diff --git \\(.+\\)\n" chunk)
         (not (string-match-p (rx line-start "--- ") chunk))
         (not (string-match-p (rx line-start "+++ ") chunk))
         (string-match-p (rx line-start "Binary files ") chunk))
    (let* ((header (match-string 1 chunk))
           (binary-paths (and (string-match
                               "^Binary files \\(.+?\\) and \\(.+?\\) differ"
                               chunk)
                              (cons (match-string 1 chunk)
                                    (match-string 2 chunk))))
           (parts (split-string header " "))
           (old (or (car binary-paths) (car parts)))
           (new (or (cdr binary-paths) (car (last parts))))
           (line-end (string-search "\n" chunk)))
      (if (and old new line-end)
          (concat (substring chunk 0 (1+ line-end))
                  "--- " old "\n"
                  "+++ " new "\n"
                  (substring chunk (1+ line-end)))
        chunk)))
   ((and (string-match-p (rx line-start "deleted file ") chunk)
         (string-match "^--- \\(.+\\)$" chunk)
         (string-match-p (rx line-start "+++ /dev/null") chunk))
    (replace-regexp-in-string (rx line-start "+++ /dev/null")
                              (concat "+++ " (match-string 1 chunk))
                              chunk
                              t t))
   (t chunk)))

(defun agent-review-render--sanitize-diff-for-magit (diff)
  "Return DIFF adjusted for Magit's internal diff washer."
  (let ((start 0)
        next
        chunks)
    (while (< start (length diff))
      (setq next (string-match (rx line-start "diff --") diff (1+ start)))
      (push (agent-review-render--sanitize-diff-chunk-for-magit
             (substring diff start next))
            chunks)
      (setq start (or next (length diff))))
    (apply #'concat (nreverse chunks))))

(defun agent-review-render-insert-diff (diff)
  "Insert pull request DIFF with Magit section washing."
  (let ((beg (point)))
    (setq-local agent-review--diff-begin-point beg)
    (if (not diff)
        (insert (propertize "Diff not available\n" 'face 'font-lock-warning-face))
      (let ((diff (agent-review-render--sanitize-diff-for-magit diff))
            (use-delta (and agent-review-use-delta
                            (executable-find agent-review-delta-executable)))
            end)
        (if use-delta
            (progn
              (insert diff)
              (setq end (agent-review-render--apply-delta beg (point))))
          (agent-review-render--insert-fontified diff 'diff-mode)
          (setq end (point)))
        (agent-review-render--wash-diff beg end)))

    ;; Keep the same line tracking behavior as original pr-review.
    (goto-char beg)
    (forward-line -1)
    (let (filename left right current-left-right)
      (while (zerop (forward-line))
        (let ((section-data (get-text-property (point) 'magit-section)))
          (when (magit-file-section-p section-data)
            (setq filename (oref section-data value))
            (set-text-properties 0 (length filename) nil filename))
          (when (magit-hunk-section-p section-data)
            (when-let ((parent (oref section-data parent)))
              (when (magit-file-section-p parent)
                (setq filename (oref parent value))))
            (when (looking-at "@@ ")
              (setq left (car (oref section-data from-range))
                    right (car (oref section-data to-range)))))
          (pcase (char-after)
            (?\s (if (and left right)
                     (setq current-left-right (cons left right)
                           left (1+ left)
                           right (1+ right))
                   (setq current-left-right nil)))
            (?- (if left
                    (setq current-left-right (cons left nil)
                          left (1+ left))
                  (setq current-left-right nil)))
            (?+ (if right
                    (setq current-left-right (cons nil right)
                          right (1+ right))
                  (setq current-left-right nil)))
            (_ (setq current-left-right nil)))
          (when (car current-left-right)
            (add-text-properties
             (point) (1+ (point))
             `(agent-review-diff-line-left ,(cons filename (car current-left-right)))))
          (when (cdr current-left-right)
            (add-text-properties
             (point) (1+ (point))
             `(agent-review-diff-line-right ,(cons filename (cdr current-left-right))))))))
    (agent-review-render--annotate-diff-anchors beg)))

(provide 'agent-review-render)
;;; agent-review-render.el ends here
