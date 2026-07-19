;;; eglotx-preset-engine.el --- Bounded discovery for Eglotx presets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Internal, policy-free machinery shared by the optional Eglotx presets.
;; A context owns every filesystem and executable lookup performed while one
;; Eglot contact is resolved.  Its caches deliberately do not outlive that
;; resolution: installing dependencies or editing configuration must take
;; effect on the next Eglot session without an invalidation protocol.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)
(require 'eglotx)
(require 'eglotx-eglot)

(declare-function eglot-path-to-uri "eglot" (path))

(defvar eglot-lsp-context)

(defgroup eglotx-presets nil
  "Project-aware contacts supplied separately from Eglotx core."
  :group 'eglotx
  :prefix "eglotx-presets-")

(defcustom eglotx-presets-prefer-project-local-servers t
  "Whether bundled contacts prefer project-local language servers.

When non-nil, each recipe probes only its ecosystem's fixed executable
directories between the current buffer and the Eglot project root before
consulting PATH.  Enabling this executes code installed in the project, so
enable the presets only for projects whose dependencies you trust."
  :type 'boolean
  :group 'eglotx-presets)

(defcustom eglotx-presets-disabled-backends nil
  "Backend names that bundled recipes must not start.

Each value is a symbol such as `ruff' or `golangci-lint'.  Primary backends
are not disabled by this option; selecting an alternative primary belongs to
the corresponding language recipe."
  :type '(repeat symbol)
  :group 'eglotx-presets)

(defconst eglotx-presets--manifest-size-limit (* 1024 1024)
  "Maximum number of bytes read from one project metadata file.")

(defconst eglotx-presets--discovery-byte-limit (* 4 1024 1024)
  "Maximum aggregate bytes read during one contact resolution.")

(defconst eglotx-presets--ancestor-limit 32
  "Maximum nearest ancestors retained in one discovery context.")

(defconst eglotx-presets--marker-candidate-limit 64
  "Maximum marker candidates retained from one local directory.")

(defconst eglotx-presets--cache-miss
  (make-symbol "eglotx-presets-cache-miss")
  "Private sentinel used to cache negative discovery results.")

(defvar eglotx-presets--fallback-resolver nil
  "Optional function used to preserve a pre-preset Eglot contact.
The function receives INTERACTIVE and PROJECT arguments.")

(cl-defstruct (eglotx-presets--context
               (:constructor eglotx-presets--context-create))
  "Bounded state for one project contact resolution."
  project
  root
  start
  directories
  remote-p
  (bytes-read 0)
  (attribute-cache (make-hash-table :test #'equal))
  (text-cache (make-hash-table :test #'equal))
  (json-cache (make-hash-table :test #'equal))
  (listing-cache (make-hash-table :test #'equal))
  (local-executable-cache (make-hash-table :test #'equal))
  (path-executable-cache (make-hash-table :test #'equal)))

(defun eglotx-presets--project-root (project)
  "Return PROJECT's normalized root, or the current directory."
  (file-name-as-directory
   (expand-file-name (if project (project-root project) default-directory))))

(defun eglotx-presets--start-directory (root)
  "Return the current buffer directory when it is below ROOT."
  (let ((candidate
         (file-name-as-directory
          (expand-file-name
           (if buffer-file-name
               (file-name-directory buffer-file-name)
             default-directory)))))
    (condition-case nil
        (if (or (equal candidate root)
                (file-in-directory-p candidate root))
            candidate
          root)
      (file-error root))))

(defun eglotx-presets--canonical-local-directory (directory)
  "Canonicalize local DIRECTORY while leaving remote names untouched."
  (if (file-remote-p directory)
      directory
    (condition-case nil
        (file-name-as-directory (file-truename directory))
      (file-error directory))))

(defun eglotx-presets--discovery-directories (start root)
  "Return bounded discovery directories between START and ROOT.

Preserve ordinary path spelling.  Canonicalize local paths only when a symlink
or case difference keeps START from sharing ROOT's lexical prefix."
  (unless (or (equal start root) (string-prefix-p root start))
    (setq start (eglotx-presets--canonical-local-directory start)
          root (eglotx-presets--canonical-local-directory root)))
  (eglotx-presets--ancestor-directories start root))

(defun eglotx-presets--ancestor-directories (start root)
  "Return bounded directories from START upward through ROOT, nearest first."
  (let ((directory start)
        directories
        done)
    (while (and (not done)
                (< (length directories) eglotx-presets--ancestor-limit))
      (push directory directories)
      (if (equal directory root)
          (setq done t)
        (let ((parent (file-name-directory (directory-file-name directory))))
          (if (or (null parent) (equal parent directory))
              (setq done t)
            (setq directory parent)))))
    (let ((nearest-first (nreverse directories)))
      (cond
       ((member root nearest-first)
        (let ((tail (member root nearest-first)))
          (nbutlast nearest-first (1- (length tail)))))
       ((equal start root) (list root))
       ;; The root is a reserved final probe even for unusually deep trees.
       (t (append nearest-first (list root)))))))

(defun eglotx-presets--make-context (&optional project)
  "Create a bounded discovery context for PROJECT."
  (let* ((project (or project
                      (let ((eglot-lsp-context t))
                        (project-current))))
         (root (eglotx-presets--project-root project))
         (start (eglotx-presets--start-directory root)))
    (eglotx-presets--context-create
     :project project
     :root root
     :start start
     :directories (eglotx-presets--discovery-directories start root)
     :remote-p (file-remote-p root))))

(defun eglotx-presets--cached-attributes (context path)
  "Return cached file attributes for PATH in CONTEXT, or nil."
  (let* ((cache (eglotx-presets--context-attribute-cache context))
         (cached (gethash path cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let ((attributes
             (condition-case nil
                 (let ((value (file-attributes path)))
                   ;; `file-regular-p' follows symlinks.  Match that behavior
                   ;; while retaining the target size used by bounded reads.
                   (if (stringp (car-safe value))
                       (file-attributes (file-truename path))
                     value))
               (file-error nil))))
        (puthash path (or attributes 'missing) cache)
        attributes))))

(defun eglotx-presets--regular-file-p (context path)
  "Return non-nil when PATH is a regular file according to CONTEXT."
  (when-let* ((attributes (eglotx-presets--cached-attributes context path)))
    (null (car attributes))))

(defun eglotx-presets--directory-p (context path)
  "Return non-nil when PATH is a directory according to CONTEXT."
  (when-let* ((attributes (eglotx-presets--cached-attributes context path)))
    (eq (car attributes) t)))

(defun eglotx-presets--existing-directories (context directories)
  "Return existing DIRECTORIES in stable order using CONTEXT's cache."
  (and eglotx-presets-prefer-project-local-servers
       (cl-remove-if-not
        (lambda (directory)
          (eglotx-presets--directory-p context directory))
        directories)))

(defun eglotx-presets--read-file (context path)
  "Return bounded contents of PATH using CONTEXT, or nil.

Malformed, unreadable, oversized, and over-budget files are negative-cached."
  (let* ((cache (eglotx-presets--context-text-cache context))
         (cached (gethash path cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let* ((attributes (eglotx-presets--cached-attributes context path))
             (size (and attributes (file-attribute-size attributes)))
             (remaining (- eglotx-presets--discovery-byte-limit
                           (eglotx-presets--context-bytes-read context)))
             value)
        (when (and attributes
                   (null (car attributes))
                   (integerp size)
                   (<= size eglotx-presets--manifest-size-limit)
                   (<= size remaining))
          ;; Reserve the observed size before I/O.  A failing decoder or a file
          ;; that changes after `file-attributes' must not bypass the aggregate
          ;; budget repeatedly.  The read itself is capped by both limits.
          (cl-incf (eglotx-presets--context-bytes-read context) size)
          (let ((unreserved (- remaining size)))
            (condition-case nil
                (with-temp-buffer
                  (insert-file-contents
                   path nil 0
                   (1+ (min eglotx-presets--manifest-size-limit remaining)))
                  (let* ((text (buffer-string))
                         (bytes (string-bytes text))
                         (extra (max 0 (- bytes size))))
                    (cl-incf (eglotx-presets--context-bytes-read context)
                             (min extra unreserved))
                    ;; Recheck actual bytes after the read.  The file may have
                    ;; grown since `file-attributes', and decoded character
                    ;; count is not a byte budget for non-ASCII metadata.
                    (when (and (<= bytes
                                   eglotx-presets--manifest-size-limit)
                               (<= bytes remaining))
                      (setq value text))))
              ;; The amount consumed by a failed decoder is unknowable.  Spend
              ;; the remaining reservation so repeated failures stay bounded.
              (error
               (cl-incf (eglotx-presets--context-bytes-read context)
                        unreserved)))))
        (puthash path (or value 'missing) cache)
        value))))

(defun eglotx-presets--parse-json-object (text)
  "Return JSON object parsed from TEXT, or nil."
  (condition-case nil
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (let ((parsed
               (json-parse-buffer
                :object-type 'hash-table
                :array-type 'list
                :null-object nil
                :false-object :json-false)))
          (and (hash-table-p parsed) parsed)))
    (error nil)))

(defun eglotx-presets--jsonc-normalize (text)
  "Return TEXT with JSONC comments and trailing commas replaced by spaces.

The scanner recognizes JSON strings and escapes, so comment-looking text in a
string is preserved.  It does not evaluate the configuration."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (in-string escaped)
      ;; Remove comments before looking for trailing commas.  Replacing each
      ;; comment with whitespace prevents adjacent tokens from being joined.
      (while (< (point) (point-max))
        (let ((character (char-after))
              (next (char-after (1+ (point)))))
          (cond
           (in-string
            (cond
             (escaped (setq escaped nil))
             ((eq character ?\\) (setq escaped t))
             ((eq character ?\") (setq in-string nil)))
            (forward-char 1))
           ((eq character ?\")
            (setq in-string t)
            (forward-char 1))
           ((and (eq character ?/) (eq next ?/))
            (let ((start (point))
                  (end (if (search-forward "\n" nil t)
                           (1- (point))
                         (point-max))))
              (delete-region start end)
              (insert " ")))
           ((and (eq character ?/) (eq next ?*))
            (let ((start (point))
                  (end (if (search-forward "*/" nil t)
                           (point)
                         (point-max))))
              (delete-region start end)
              (insert " ")))
           (t (forward-char 1)))))
      ;; A comma is trailing only when the next non-whitespace character is a
      ;; closing array or object delimiter outside a string.
      (goto-char (point-min))
      (setq in-string nil escaped nil)
      (while (< (point) (point-max))
        (let ((character (char-after)))
          (cond
           (in-string
            (cond
             (escaped (setq escaped nil))
             ((eq character ?\\) (setq escaped t))
             ((eq character ?\") (setq in-string nil)))
            (forward-char 1))
           ((eq character ?\")
            (setq in-string t)
            (forward-char 1))
           ((eq character ?,)
            (let ((comma (point)))
              (save-excursion
                (forward-char 1)
                (skip-chars-forward " \t\r\n")
                (when (memq (char-after) '(?} ?\]))
                  (delete-region comma (1+ comma))
                  (goto-char comma)
                  (insert " "))))
            (forward-char 1))
           (t (forward-char 1))))))
    (buffer-string)))

(defun eglotx-presets--read-json (context path)
  "Return a bounded JSON object from PATH using CONTEXT, or nil."
  (let* ((cache (eglotx-presets--context-json-cache context))
         (cached (gethash path cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let ((value
             (when-let* ((text (eglotx-presets--read-file context path)))
               (eglotx-presets--parse-json-object text))))
        (puthash path (or value 'missing) cache)
        value))))

(defun eglotx-presets--read-jsonc (context path)
  "Return a bounded JSON-or-JSONC object from PATH using CONTEXT, or nil."
  (let* ((cache (eglotx-presets--context-json-cache context))
         (key (cons 'jsonc path))
         (cached (gethash key cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let ((value
             (when-let* ((text (eglotx-presets--read-file context path)))
               (eglotx-presets--parse-json-object
                (eglotx-presets--jsonc-normalize text)))))
        (puthash key (or value 'missing) cache)
        value))))

(defun eglotx-presets--read-manifest (path)
  "Read a bounded JSON object from project manifest PATH.

This compatibility helper owns a one-file context.  Recipes should share the
contact's context via `eglotx-presets--read-json' instead."
  (let* ((directory (file-name-directory (expand-file-name path)))
         (context (eglotx-presets--context-create
                   :root directory :start directory
                   :directories (list directory)
                   :remote-p (file-remote-p directory))))
    (eglotx-presets--read-json context path)))

(defun eglotx-presets--directory-candidates (context directory regexp)
  "Return bounded local entries in DIRECTORY matching REGEXP.

Results, including failures, are cached in CONTEXT.  Remote directories are
never enumerated because TRAMP must fetch a complete listing before filtering."
  (let* ((key (cons directory regexp))
         (cache (eglotx-presets--context-listing-cache context))
         (cached (gethash key cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let ((entries
             (unless (or (eglotx-presets--context-remote-p context)
                         (file-remote-p directory))
               (condition-case nil
                   (directory-files directory nil regexp t
                                    eglotx-presets--marker-candidate-limit)
                 (file-error nil)))))
        (puthash key (or entries 'missing) cache)
        entries))))

(defun eglotx-presets--config-name-segments (name)
  "Return punctuation-delimited stem segments in config NAME."
  (split-string (file-name-sans-extension name) "[._-]+" t))

(defun eglotx-presets--keyword-segment-p (keyword segments)
  "Return non-nil when KEYWORD is a punctuation-delimited SEGMENTS token."
  (member keyword segments))

(defun eglotx-presets--exec-suffixes ()
  "Return executable suffixes on Emacs 29 and newer."
  (if (fboundp 'exec-suffixes)
      (funcall (intern "exec-suffixes"))
    (symbol-value 'exec-suffixes)))

(defun eglotx-presets--local-executable (program bin-directories)
  "Find PROGRAM in project BIN-DIRECTORIES, nearest directory first."
  (locate-file program bin-directories
               (eglotx-presets--exec-suffixes) #'file-executable-p))

(defun eglotx-presets--context-local-executable
    (context program bin-directories)
  "Resolve PROGRAM in BIN-DIRECTORIES once per CONTEXT."
  (when eglotx-presets-prefer-project-local-servers
    (let* ((key (cons program bin-directories))
           (cache (eglotx-presets--context-local-executable-cache context))
           (cached (gethash key cache eglotx-presets--cache-miss)))
      (if (not (eq cached eglotx-presets--cache-miss))
          (unless (eq cached 'missing) cached)
        (let ((path (eglotx-presets--local-executable program bin-directories)))
          (puthash key (or path 'missing) cache)
          path)))))

(defun eglotx-presets--path-executable (program root)
  "Find PROGRAM on the correct local or remote PATH for ROOT."
  (let ((default-directory root))
    (executable-find program (file-remote-p root))))

(defun eglotx-presets--context-path-executable (context program)
  "Resolve PROGRAM on CONTEXT's PATH once."
  (let* ((cache (eglotx-presets--context-path-executable-cache context))
         (cached (gethash program cache eglotx-presets--cache-miss)))
    (if (not (eq cached eglotx-presets--cache-miss))
        (unless (eq cached 'missing) cached)
      (let ((path (eglotx-presets--path-executable
                   program (eglotx-presets--context-root context))))
        (puthash program (or path 'missing) cache)
        path))))

(defun eglotx-presets--process-path (path)
  "Convert executable PATH into a name suitable for `make-process'."
  (when path
    (if (file-remote-p path) (file-local-name path) path)))

(defun eglotx-presets--resolve-executable (program local root)
  "Resolve PROGRAM from LOCAL or ROOT's PATH according to user policy."
  (eglotx-presets--process-path
   (or (and eglotx-presets-prefer-project-local-servers local)
       (eglotx-presets--path-executable program root))))

(defun eglotx-presets--context-resolve-executable (context program local)
  "Resolve PROGRAM from LOCAL or CONTEXT's PATH according to user policy."
  (eglotx-presets--process-path
   (or (and eglotx-presets-prefer-project-local-servers local)
       (eglotx-presets--context-path-executable context program))))

(defun eglotx-presets--path-to-uri (path)
  "Return the LSP URI corresponding to PATH on supported Eglot versions."
  (if (fboundp 'eglot-path-to-uri)
      (eglot-path-to-uri path)
    (funcall (intern "eglot--path-to-uri") path)))

(defun eglotx-presets--backend-disabled-p (name)
  "Return non-nil when optional backend NAME is disabled."
  (memq name eglotx-presets-disabled-backends))

(defun eglotx-presets--missing-contact
    (interactive missing-message &optional project)
  "Return a preserved contact or report MISSING-MESSAGE.
INTERACTIVE and PROJECT are forwarded to the optional fallback resolver."
  (or (and (functionp eglotx-presets--fallback-resolver)
           (funcall eglotx-presets--fallback-resolver interactive project))
      (if interactive
          nil
        (signal 'eglotx-configuration-error (list missing-message)))))

(defun eglotx-presets--materialize-contact
    (backends interactive missing-message &optional project)
  "Turn BACKENDS into an ordinary or multiplexed Eglot contact.

When BACKENDS is empty, first resolve any Eglot mapping preserved for PROJECT.
Without one, return nil for INTERACTIVE lookup and otherwise signal
`eglotx-configuration-error' with MISSING-MESSAGE."
  (pcase backends
    ('nil
     (eglotx-presets--missing-contact interactive missing-message project))
    (`(,backend)
     (copy-sequence (plist-get backend :command)))
    (_ (apply #'eglotx-contact backends))))

(provide 'eglotx-preset-engine)
;;; eglotx-preset-engine.el ends here
