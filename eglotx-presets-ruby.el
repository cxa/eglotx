;;; eglotx-presets-ruby.el --- Ruby contacts for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Prefer Ruby LSP, whose upstream explicitly coordinates with Sorbet.  Keep
;; Solargraph as a single-server fallback, never as another concurrent primary.

;;; Code:

(require 'cl-lib)
(require 'eglotx-preset-engine)

(defconst eglotx-presets--ruby-entry
  '(((ruby-mode :language-id "ruby")
     (ruby-ts-mode :language-id "ruby"))
    . eglotx-presets-ruby-contact)
  "Entry installed only for Ruby source buffers.")

(defconst eglotx-presets-ruby--sorbet-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/configuration
    :textDocument/completion
    :completionItem/resolve
    :textDocument/hover
    :textDocument/signatureHelp
    :textDocument/declaration
    :textDocument/definition
    :textDocument/typeDefinition
    :textDocument/implementation
    :textDocument/references
    :textDocument/documentHighlight
    :textDocument/documentSymbol
    :textDocument/rename
    :textDocument/prepareRename
    :textDocument/codeAction
    :codeAction/resolve
    :textDocument/diagnostic
    :workspace/diagnostic
    :workspace/symbol
    :workspace/executeCommand)
  "Type-oriented methods Sorbet may own in the Ruby recipe.")

(defun eglotx-presets-ruby--bin-directories (context)
  "Return fixed Ruby binstub directories for CONTEXT."
  (eglotx-presets--existing-directories
   context
   (mapcar (lambda (directory) (expand-file-name "bin/" directory))
           (eglotx-presets--context-directories context))))

(defun eglotx-presets-ruby--resolve
    (context program bin-directories)
  "Resolve PROGRAM from Ruby BIN-DIRECTORIES and CONTEXT's PATH."
  (let ((local (eglotx-presets--context-local-executable
                context program bin-directories)))
    (cons local
          (eglotx-presets--context-resolve-executable
           context program local))))

(defun eglotx-presets-ruby--primary-resolution
    (context bin-directories)
  "Select one Ruby primary in CONTEXT using BIN-DIRECTORIES.

The nearest project binstub wins across both supported alternatives.  Only
when no local alternative exists does declaration order choose a PATH server."
  (let ((candidates '((ruby-lsp "ruby-lsp" nil)
                      (solargraph "solargraph" ("stdio")))))
    (or
     (when eglotx-presets-prefer-project-local-servers
       (catch 'selected
         (cl-loop
          for directory in bin-directories
          do
          (dolist (candidate candidates)
            (when-let* ((local
                         (eglotx-presets--context-local-executable
                          context (nth 1 candidate) (list directory))))
              (throw 'selected
                     (list :id (car candidate)
                           :path (eglotx-presets--process-path local)
                           :arguments
                           (copy-sequence (nth 2 candidate)))))))))
     (catch 'selected
       (dolist (candidate candidates)
         (when-let* ((path
                      (eglotx-presets--context-resolve-executable
                       context (nth 1 candidate) nil)))
           (throw 'selected
                  (list :id (car candidate)
                        :path path
                        :arguments (copy-sequence (nth 2 candidate))))))))))

(defun eglotx-presets-ruby--sorbet-intent-p (context)
  "Return non-nil when CONTEXT has Sorbet's official project config."
  (catch 'intent
    (dolist (directory (eglotx-presets--context-directories context))
      (when (eglotx-presets--regular-file-p
             context (expand-file-name "sorbet/config" directory))
        (throw 'intent t)))
    nil))

;;;###autoload
(defun eglotx-presets-ruby-contact (&optional interactive project)
  "Return one Ruby primary, plus Sorbet for an explicitly typed project.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets-ruby--bin-directories context))
         (primary
          (eglotx-presets-ruby--primary-resolution
           context bin-directories))
         (srb-resolution
          (and (eq (plist-get primary :id) 'ruby-lsp)
               (not (eglotx-presets--backend-disabled-p 'sorbet))
               (eglotx-presets-ruby--sorbet-intent-p context)
               (eglotx-presets-ruby--resolve
                context "srb" bin-directories)))
         (srb (cdr srb-resolution))
         backends)
    (when primary
      (push (list :name (symbol-name (plist-get primary :id))
                  :command
                  (cons (plist-get primary :path)
                        (plist-get primary :arguments))
                  :priority 100
                  :required t)
            backends))
    (when srb
      (push (list :name "sorbet"
                  :command (list srb "tc" "--lsp")
                  :priority 120
                  :required nil
                  :only eglotx-presets-ruby--sorbet-only)
            backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "Neither ruby-lsp nor solargraph is executable"
     (eglotx-presets--context-project context))))

(provide 'eglotx-presets-ruby)
;;; eglotx-presets-ruby.el ends here
