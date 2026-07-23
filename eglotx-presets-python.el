;;; eglotx-presets-python.el --- Python contacts for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Select exactly one full Python language server, then add native Ruff only
;; when the project declares Ruff intent.  Merely finding Ruff on PATH never
;; opts every Python project into a second server.

;;; Code:

(require 'cl-lib)
(require 'eglotx-preset-engine)
(require 'subr-x)

(defconst eglotx-presets--python-entry
  '(((python-mode :language-id "python")
     (python-ts-mode :language-id "python"))
    . eglotx-presets-python-contact)
  "Entry installed for Python source buffers.")

(defconst eglotx-presets-python--primary-candidates
  '((:id basedpyright :name "basedpyright"
     :program "basedpyright-langserver" :arguments ("--stdio"))
    (:id pyright :name "pyright"
     :program "pyright-langserver" :arguments ("--stdio"))
    (:id pyrefly :name "pyrefly"
     :program "pyrefly" :arguments ("lsp"))
    (:id ty :name "ty"
     :program "ty" :arguments ("server"))
    (:id pylsp :name "pylsp"
     :program "pylsp" :arguments nil)
    (:id jedi :name "jedi-language-server"
     :program "jedi-language-server" :arguments nil))
  "Ordered full Python language-server alternatives.")

(defconst eglotx-presets-python--executable-ancestor-limit 8
  "Maximum nearest ancestors probed for Python environments.

The project root remains a final probe when it is outside this prefix.")

(defconst eglotx-presets-python--ruff-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/configuration
    :textDocument/codeAction
    :codeAction/resolve
    :workspace/executeCommand
    :textDocument/formatting
    :textDocument/rangeFormatting
    :textDocument/diagnostic)
  "Methods Ruff may own in the bundled Python recipe.")

(defun eglotx-presets-python--bin-directories (context)
  "Return fixed virtual-environment executable directories for CONTEXT."
  (let* ((directories (eglotx-presets--context-directories context))
         (root (eglotx-presets--context-root context))
         (nearest
          (cl-loop for directory in directories
                   repeat eglotx-presets-python--executable-ancestor-limit
                   collect directory))
         (roots (if (member root nearest) nearest (append nearest (list root))))
         (candidates
          (apply
           #'append
           (mapcar
            (lambda (directory)
              (mapcar
               (lambda (relative) (expand-file-name relative directory))
               '(".venv/bin/" "venv/bin/"
                 ".venv/Scripts/" "venv/Scripts/")))
            roots))))
    (eglotx-presets--existing-directories context candidates)))

(defun eglotx-presets-python--candidate-enabled-p (candidate ids)
  "Return non-nil when CANDIDATE is allowed by optional IDS."
  (or (null ids) (memq (plist-get candidate :id) ids)))

(defun eglotx-presets-python--local-primary
    (context bin-directories &optional ids)
  "Return the first project-local Python primary in CONTEXT.

Probe BIN-DIRECTORIES nearest-first.  Within one directory, use
`eglotx-presets-python--primary-candidates' as the stable tie-breaker.  When
IDS is non-nil, consider only candidates whose IDs it contains."
  (when eglotx-presets-prefer-project-local-servers
    (catch 'selected
      (cl-loop
       for directory in bin-directories
       for local-index from 0
       do
       (dolist (candidate eglotx-presets-python--primary-candidates)
         (when (eglotx-presets-python--candidate-enabled-p candidate ids)
           (let* ((program (plist-get candidate :program))
                  (local
                   (eglotx-presets--context-local-executable
                    context program (list directory))))
             (when local
               (throw
                'selected
                (list :candidate candidate
                      :path (eglotx-presets--process-path local)
                      :local local
                      :local-index local-index))))))))))

(defun eglotx-presets-python--path-primary (context &optional ids)
  "Return the first allowed Python primary on CONTEXT's PATH.
When IDS is non-nil, consider only candidates whose IDs it contains."
  (catch 'selected
    (dolist (candidate eglotx-presets-python--primary-candidates)
      (when (eglotx-presets-python--candidate-enabled-p candidate ids)
        (let* ((program (plist-get candidate :program))
               (path (eglotx-presets--context-resolve-executable
                      context program nil)))
          (when path
            (throw 'selected
                   (list :candidate candidate :path path
                         :local nil :local-index nil))))))))

(defun eglotx-presets-python--pyproject-section-p (text section)
  "Return non-nil when bounded TOML TEXT declares SECTION or a child."
  (let ((case-fold-search nil))
    (string-match-p
     (concat "^[ \t]*\\[" (regexp-quote section)
             "\\(?:\\.[^]]+\\)?\\][ \t]*\\(?:#.*\\)?$")
     text)))

(defun eglotx-presets-python--requirement-on-line-p (line package)
  "Return non-nil when LINE contains an exact quoted PACKAGE requirement."
  (let* ((case-fold-search nil)
         (pattern
          (concat "[\"']" (regexp-quote package)
                  "\\(?:\\[[^]\"']*\\]\\)?"
                  "\\(?:[<>=!~; @][^\"']*\\)?[\"']"))
         (match (string-match pattern line))
         (comment (string-match "[ \t]#" line)))
    (and match (or (null comment) (< match comment)))))

(defun eglotx-presets-python--dependency-section-p (section)
  "Return non-nil when TOML SECTION contains dependency declarations."
  (or (string= section "dependency-groups")
      (string-prefix-p "project.optional-dependencies" section)
      (string-match-p "\\.dependencies\\'" section)
      (string-match-p "dev-dependencies\\'" section)))

(defun eglotx-presets-python--toml-array-closes-p (line)
  "Return non-nil when LINE closes an array outside strings and comments."
  (let ((index 0)
        quote
        escaped
        found)
    (while (and (< index (length line)) (not found))
      (let ((character (aref line index)))
        (cond
         (escaped
          (setq escaped nil))
         (quote
          (cond
           ((and (eq quote ?\") (eq character ?\\))
            (setq escaped t))
           ((eq character quote)
            (setq quote nil))))
         ((eq character ?#)
          (setq index (length line)))
         ((or (eq character ?\") (eq character ?'))
          (setq quote character))
         ((eq character ?\])
          (setq found t))))
      (cl-incf index))
    found))

(defun eglotx-presets-python--toml-dependency-p (text package)
  "Return non-nil when bounded TOML TEXT declares exact PACKAGE dependency."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((case-fold-search nil)
          (section "")
          array-p
          found)
      (while (and (not found) (not (eobp)))
        (let* ((line (buffer-substring-no-properties
                      (line-beginning-position) (line-end-position)))
               (closes-array
                (eglotx-presets-python--toml-array-closes-p line)))
          (cond
           ((string-match "^[ \t]*\\[\\([^]]+\\)\\]" line)
            (setq section (match-string 1 line)
                  array-p nil))
           ((string-match-p "^[ \t]*#" line))
           ((and (string-match-p "\\.dependencies\\'" section)
                 (string-match-p
                  (concat "^[ \t]*" (regexp-quote package) "[ \t]*=")
                  line))
            (setq found t))
           ((and (eglotx-presets-python--dependency-section-p section)
                 (eglotx-presets-python--requirement-on-line-p
                  line package))
            (setq found t))
           ((and (member section '("project" "tool.uv"))
                 (string-match-p
                  "^[ \t]*\\(?:dev-\\)?dependencies[ \t]*=" line))
            (setq array-p (not closes-array)
                  found
                  (eglotx-presets-python--requirement-on-line-p
                   line package)))
           (array-p
            (setq found
                  (eglotx-presets-python--requirement-on-line-p
                   line package))
            (when closes-array
              (setq array-p nil)))))
        (forward-line 1))
      found)))

(defun eglotx-presets-python--configured-ids (context directory)
  "Return Python primary IDs configured by DIRECTORY in CONTEXT."
  (let* ((ty-file (expand-file-name "ty.toml" directory))
         (pyright-file (expand-file-name "pyrightconfig.json" directory))
         (pyrefly-file (expand-file-name "pyrefly.toml" directory))
         (pyproject-file (expand-file-name "pyproject.toml" directory))
         (pyproject (eglotx-presets--read-file context pyproject-file))
         ids)
    (when (eglotx-presets--regular-file-p context ty-file)
      (push 'ty ids))
    (when (eglotx-presets--regular-file-p context pyrefly-file)
      (push 'pyrefly ids))
    (when (eglotx-presets--regular-file-p context pyright-file)
      ;; basedpyright intentionally shares Pyright's configuration format.
      (setq ids (append ids '(basedpyright pyright))))
    (when pyproject
      (when (eglotx-presets-python--pyproject-section-p pyproject "tool.ty")
        (cl-pushnew 'ty ids))
      (when (eglotx-presets-python--pyproject-section-p
             pyproject "tool.pyrefly")
        (cl-pushnew 'pyrefly ids))
      (when (eglotx-presets-python--pyproject-section-p
             pyproject "tool.basedpyright")
        (cl-pushnew 'basedpyright ids))
      (when (eglotx-presets-python--pyproject-section-p
             pyproject "tool.pyright")
        (cl-pushnew 'basedpyright ids)
        (cl-pushnew 'pyright ids))
      (when (eglotx-presets-python--pyproject-section-p
             pyproject "tool.pylsp")
        (cl-pushnew 'pylsp ids)))
    ids))

(defun eglotx-presets-python--config-primary (context bin-directories)
  "Select an available config-backed Python primary in CONTEXT.

Nearest configuration wins.  Candidate declaration order is the stable
tie-breaker when one directory configures compatible alternatives."
  (catch 'selected
    (dolist (directory (eglotx-presets--context-directories context))
      (let ((ids
             (eglotx-presets-python--configured-ids context directory)))
        (when ids
          ;; A configured project-local compatible server still outranks every
          ;; PATH alternative.  Only consult PATH after checking the complete
          ;; local candidate set for this nearest configuration.
          (when-let* ((resolution
                       (or (eglotx-presets-python--local-primary
                            context bin-directories ids)
                           (eglotx-presets-python--path-primary context ids))))
            (throw 'selected resolution)))))))

(defun eglotx-presets-python--select-primary (context bin-directories)
  "Resolve exactly one full Python server for CONTEXT."
  (or (eglotx-presets-python--config-primary context bin-directories)
      (eglotx-presets-python--local-primary context bin-directories)
      (eglotx-presets-python--path-primary context)))

(defun eglotx-presets-python--ruff-marker-p (context directory)
  "Return non-nil when DIRECTORY has a structural Ruff config in CONTEXT."
  (cl-some
   (lambda (name)
     (and (equal (eglotx-presets--config-name-segments name) '("ruff"))
          (string= (or (file-name-extension name) "") "toml")
          (eglotx-presets--regular-file-p
           context (expand-file-name name directory))))
   (eglotx-presets--directory-candidates
    context directory "\\(?:\\`\\|[._-]\\)ruff")))

(defun eglotx-presets-python--ruff-intent-p (context)
  "Return non-nil when CONTEXT explicitly adopts Ruff."
  (catch 'intent
    (dolist (directory (eglotx-presets--context-directories context))
      (when-let* ((pyproject
                   (eglotx-presets--read-file
                    context (expand-file-name "pyproject.toml" directory))))
        (when (or (eglotx-presets-python--pyproject-section-p
                   pyproject "tool.ruff")
                  (eglotx-presets-python--toml-dependency-p
                   pyproject "ruff"))
          (throw 'intent t)))
      (when (eglotx-presets-python--ruff-marker-p context directory)
        (throw 'intent t)))
    nil))

(defun eglotx-presets-python--backend (resolution)
  "Build the required primary backend from RESOLUTION."
  (let ((candidate (plist-get resolution :candidate)))
    (list :name (plist-get candidate :name)
          :command (cons (plist-get resolution :path)
                         (copy-sequence
                          (plist-get candidate :arguments)))
          :priority 100
          :required t)))

;;;###autoload
(defun eglotx-presets-python-contact (&optional interactive project)
  "Return a zero-configuration Python primary plus optional Ruff contact.

Choose one full server from basedpyright, Pyright, Pyrefly, ty,
python-lsp-server and Jedi.  The nearest project virtual environment wins
unless a nearer server-specific configuration selects an available
alternative.  Add `ruff server' only for a Ruff config, `[tool.ruff]' section,
an exact Ruff dependency, or a project-local executable.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories
          (eglotx-presets-python--bin-directories context))
         (primary
          (eglotx-presets-python--select-primary context bin-directories))
         (ruff-enabled
          (and primary
               (not (eglotx-presets--add-on-disabled-p 'ruff))))
         (ruff-local
          (when ruff-enabled
            (eglotx-presets--context-local-executable
             context "ruff" bin-directories)))
         (ruff
          (and ruff-enabled
               (or ruff-local
                   (eglotx-presets-python--ruff-intent-p context))
               (eglotx-presets--context-resolve-executable
                context "ruff" ruff-local)))
         backends)
    (when primary
      (push (eglotx-presets-python--backend primary) backends))
    (when ruff
      (push (list :name "ruff"
                  :command (list ruff "server")
                  ;; Ruff is the project's explicit lint/format owner.  Its
                  ;; narrow method filter keeps structural requests on the
                  ;; full Python primary while allowing formatting to win over
                  ;; primaries such as pylsp that also advertise it.
                  :priority 120
                  :required nil
                  :only eglotx-presets-python--ruff-only)
            backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "No supported Python language server is executable"
     (eglotx-presets--context-project context))))

(provide 'eglotx-presets-python)
;;; eglotx-presets-python.el ends here
