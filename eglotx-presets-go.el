;;; eglotx-presets-go.el --- Go contacts for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Keep gopls authoritative and add golangci-lint-langserver only for projects
;; which explicitly carry GolangCI configuration or a project-local toolchain.

;;; Code:

(require 'cl-lib)
(require 'eglotx-preset-engine)

(defconst eglotx-presets--go-entry
  '(((go-dot-mod-mode :language-id "go.mod")
     (go-mod-ts-mode :language-id "go.mod")
     (go-dot-work-mode :language-id "go.work")
     (go-work-ts-mode :language-id "go.work")
     (go-mode :language-id "go")
     (go-ts-mode :language-id "go"))
    . eglotx-presets-go-contact)
  "Entry installed for gopls's complete Go document cohort.")

(defconst eglotx-presets-go--golangci-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/configuration
    :textDocument/diagnostic)
  "Methods allowed for the diagnostic-only GolangCI backend.")

(defun eglotx-presets-go--bin-directories (context)
  "Return fixed project executable directories for CONTEXT."
  (eglotx-presets--existing-directories
   context
   (apply
    #'append
    (mapcar
     (lambda (directory)
       (list (expand-file-name "bin/" directory)
             (expand-file-name ".bin/" directory)))
     (eglotx-presets--context-directories context)))))

(defun eglotx-presets-go--config-name-p (name)
  "Return non-nil when NAME structurally resembles GolangCI config."
  (let ((segments (eglotx-presets--config-name-segments name))
        (extension (or (file-name-extension name) "")))
    (and (eglotx-presets--keyword-segment-p "golangci" segments)
         (or (string-prefix-p ".golangci." name)
             (equal segments '("golangci"))
             (member "config" segments))
         (string-match-p "\\`\\(?:json\\|toml\\|ya?ml\\)\\'"
                         extension))))

(defun eglotx-presets-go--config-name-less-p (left right)
  "Return non-nil when config name LEFT deterministically precedes RIGHT."
  (let* ((left-segments (eglotx-presets--config-name-segments left))
         (right-segments (eglotx-presets--config-name-segments right))
         (left-rank
          (cond ((and (string-prefix-p ".golangci." left)
                      (equal left-segments '("golangci"))) 0)
                ((equal left-segments '("golangci")) 1)
                (t 2)))
         (right-rank
          (cond ((and (string-prefix-p ".golangci." right)
                      (equal right-segments '("golangci"))) 0)
                ((equal right-segments '("golangci")) 1)
                (t 2))))
    (if (= left-rank right-rank)
        (string-lessp left right)
      (< left-rank right-rank))))

(defun eglotx-presets-go--config (context)
  "Return the nearest GolangCI config path and bounded text in CONTEXT."
  (catch 'found
    (dolist (directory (eglotx-presets--context-directories context))
      (dolist (name
               (sort
                (copy-sequence
                 (eglotx-presets--directory-candidates
                  context directory "\\(?:\\`\\|[._-]\\)golangci"))
                #'eglotx-presets-go--config-name-less-p))
        (let ((path (expand-file-name name directory)))
          (when (and (eglotx-presets-go--config-name-p name)
                     (eglotx-presets--regular-file-p context path))
            (throw 'found
                   (cons path (eglotx-presets--read-file context path)))))))
    nil))

(defun eglotx-presets-go--v2-config-p (config)
  "Return non-nil when CONFIG's bounded text declares GolangCI v2."
  (when-let* ((text (cdr config)))
    (let ((case-fold-search nil)
          (extension (file-name-extension (car config))))
      (if (string= extension "json")
          (condition-case nil
              (let* ((object
                      (json-parse-string
                       text :object-type 'hash-table
                       :array-type 'list :null-object nil
                       :false-object :json-false))
                     (version (and (hash-table-p object)
                                   (gethash "version" object))))
                (or (equal version 2) (equal version "2")))
            (error nil))
        ;; GolangCI's YAML and TOML schema version is a top-level key.  Requiring
        ;; column zero avoids mistaking a nested tool/plugin version for it.
        (string-match-p
         (concat
          "^[\"']?version[\"']?[ \t]*[:=][ \t]*[\"']?2[\"']?[ \t]*"
          "\\(?:[,}#\n\r]\\|\\'\\)")
         text)))))

(defun eglotx-presets-go--initialization-options (linter v2-p config)
  "Return GolangCI initialization options for LINTER, V2-P, and CONFIG."
  (list
   :command
   (vconcat
    (list linter "run")
    (if v2-p
        '("--output.json.path" "stdout" "--show-stats=false")
      '("--out-format" "json"))
    '("--issues-exit-code=1")
    (when config
      (list "--config"
            (eglotx-presets--process-path (car config)))))))

;;;###autoload
(defun eglotx-presets-go-contact (&optional interactive project)
  "Return gopls plus an intent-gated GolangCI diagnostic backend.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets-go--bin-directories context))
         (gopls-local
          (eglotx-presets--context-local-executable
           context "gopls" bin-directories))
         (gopls
          (eglotx-presets--context-resolve-executable
           context "gopls" gopls-local))
         (server-local
          (when (and gopls
                     (not (eglotx-presets--backend-disabled-p
                           'golangci-lint)))
            (eglotx-presets--context-local-executable
             context "golangci-lint-langserver" bin-directories)))
         (linter-local
          (when (and gopls
                     (not (eglotx-presets--backend-disabled-p
                           'golangci-lint)))
            (eglotx-presets--context-local-executable
             context "golangci-lint" bin-directories)))
         (server-executable
          (and gopls
               (not (eglotx-presets--backend-disabled-p 'golangci-lint))
               (eglotx-presets--context-resolve-executable
                context "golangci-lint-langserver" server-local)))
         (linter-executable
          (and gopls
               (not (eglotx-presets--backend-disabled-p 'golangci-lint))
               (eglotx-presets--context-resolve-executable
                context "golangci-lint" linter-local)))
         (config
          (and server-executable linter-executable
               (eglotx-presets-go--config context)))
         (intent (or config server-local linter-local))
         (server (and intent server-executable))
         (linter (and intent linter-executable))
         backends)
    (when gopls
      (push (list :name "gopls" :command (list gopls)
                  :priority 100 :required t)
            backends))
    (when (and server linter)
      (push (list :name "golangci-lint"
                  :command (list server)
                  :priority 40
                  :required nil
                  :initialization-options
                  (eglotx-presets-go--initialization-options
                   linter (or (null config)
                              (eglotx-presets-go--v2-config-p config))
                   config)
                  :languages '("go")
                  :only eglotx-presets-go--golangci-only)
            backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive "gopls is not executable"
     (eglotx-presets--context-project context))))

(provide 'eglotx-presets-go)
;;; eglotx-presets-go.el ends here
