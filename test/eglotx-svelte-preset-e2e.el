;;; eglotx-svelte-preset-e2e.el --- Real Svelte preset smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.  It starts
;; the real Svelte, optional lint/format, and Tailwind servers declared by one
;; minimal project under test/projects.

(require 'seq)
(require 'flymake)
(require 'eglot)
(require 'eglotx-presets)

(define-derived-mode eglotx-svelte-preset-e2e-mode prog-mode
  "Eglotx-E2E-Svelte")

(defconst eglotx-svelte-preset-e2e--test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst eglotx-svelte-preset-e2e--scenarios
  '(("eslint"
     :project "svelte_ts_tailwind_eslint"
     :program "vscode-eslint-language-server"
     :backends ("svelte" "eslint" "tailwindcss")
     :formatter "svelte")
    ("biome"
     :project "svelte_ts_tailwind_biome"
     :program "biome"
     :backends ("biome" "svelte" "tailwindcss")
     :formatter "biome"))
  "Real-server test parameters keyed by optional backend name.")

(defun eglotx-svelte-preset-e2e--diagnostic-source (diagnostic)
  "Return the LSP source recorded on Flymake DIAGNOSTIC."
  (when-let* ((data (flymake-diagnostic-data diagnostic))
              (wire (alist-get 'eglot-lsp-diag data)))
    (plist-get wire :source)))

(defun eglotx-svelte-preset-e2e--assert-resolvable-completion
    (server marker label expected-owner)
  "Assert SERVER resolves LABEL after MARKER through EXPECTED-OWNER.

Return the resolved completion label.  Operate on the current managed buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (search-forward marker nil t)
      (error "Completion position %S was not found" marker))
    (let* ((params
            (list
             :textDocument
             (list :uri (eglotx-presets--path-to-uri buffer-file-name))
             :position (eglot--pos-to-lsp-position)
             :context (list :triggerKind 1)))
           (completion
            (jsonrpc-request
             server :textDocument/completion params :timeout 30))
           (items (plist-get completion :items))
           (item
            (seq-find
             (lambda (candidate)
               (equal (plist-get candidate :label) label))
             items))
           (owner (and item (eglotx--owner-for-params server item))))
      (unless item
        (error "Completion %S was not returned after %S" label marker))
      (unless
          (and owner
               (equal
                (eglotx--backend-name (eglotx--owner-backend owner))
                expected-owner))
        (error "Completion %S lost owner %S: %S"
               label expected-owner item))
      (let ((resolved-label
             (plist-get
              (jsonrpc-request
               server :completionItem/resolve item :timeout 15)
              :label)))
        (unless (equal resolved-label label)
          (error "%s resolve returned %S" expected-owner resolved-label))
        resolved-label))))

(let* ((optional-backend (or (getenv "EGLOTX_E2E_BACKEND") "eslint"))
       (scenario
        (or (cdr (assoc optional-backend
                        eglotx-svelte-preset-e2e--scenarios))
            (error "Unsupported Svelte E2E backend %S" optional-backend)))
       (project-name (plist-get scenario :project))
       (optional-program (plist-get scenario :program))
       (expected-backends (plist-get scenario :backends))
       (expected-formatter (plist-get scenario :formatter))
       (root
        (file-name-as-directory
         (expand-file-name (concat "projects/" project-name)
                           eglotx-svelte-preset-e2e--test-directory)))
       (source (expand-file-name "src/App.svelte" root))
       (bin (expand-file-name "node_modules/.bin/" root))
       buffer server tailwind-resolved-label svelte-resolved-label)
  (dolist (program
           (list "svelteserver" "tailwindcss-language-server"
                 optional-program))
    (unless (file-executable-p (expand-file-name program bin))
      (error "%s is required under %s" program bin)))
  (eglotx-presets-mode 1)
  (add-to-list
   'eglot-server-programs
   '(((eglotx-svelte-preset-e2e-mode :language-id "svelte"))
     . eglotx-presets-svelte-contact))
  (unwind-protect
      (progn
        (setq buffer (find-file-noselect source))
        (with-current-buffer buffer
          (eglotx-svelte-preset-e2e-mode)
          (let ((default-directory root)
                (project-find-functions
                 (list (lambda (_directory) (cons 'transient root)))))
            (call-interactively #'eglot)
            (let ((deadline (+ (float-time) 20.0)))
              (while (and (not (setq server (eglot-current-server)))
                          (< (float-time) deadline))
                (accept-process-output nil 0.1))))
          (unless (and server (object-of-class-p server 'eglotx-server))
            (error "%s did not create an Eglotx facade" project-name))
          (unless
              (equal (mapcar #'eglotx--backend-name
                             (eglotx--backends server))
                     expected-backends)
            (error "Unexpected Svelte backends: %S" (eglotx-status server)))
          (unless (seq-every-p
                   (lambda (backend)
                     (eq (eglotx--backend-state backend) 'ready))
                   (eglotx--backends server))
            (error "Svelte backend is not ready: %S" (eglotx-status server)))
          (dolist (backend (eglotx--backends server))
            (unless (string-prefix-p bin
                                     (car (eglotx--backend-command backend)))
              (error "%s did not use its project-local executable: %S"
                     (eglotx--backend-name backend)
                     (eglotx--backend-command backend))))
          (let* ((params
                  (list :textDocument
                        (list :uri
                              (eglotx-presets--path-to-uri
                               buffer-file-name))))
                 (targets
                  (eglotx--select-request-targets
                   server :textDocument/formatting params
                   (eglotx--policy :textDocument/formatting)))
                 (formatter
                  (and targets (eglotx--backend-name (car targets)))))
            (unless (equal formatter expected-formatter)
              (error "Svelte formatter is %S, expected %S"
                     formatter expected-formatter)))
          (setq tailwind-resolved-label
                (eglotx-svelte-preset-e2e--assert-resolvable-completion
                 server "class=\"p-4 " "block" "tailwindcss")
                svelte-resolved-label
                (eglotx-svelte-preset-e2e--assert-resolvable-completion
                 server "count." "toFixed" "svelte"))
          (flymake-start nil t)
          (let ((deadline (+ (float-time) 15.0))
                type-diagnostic optional-diagnostic)
            (while (and (not (and type-diagnostic optional-diagnostic))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)
              (setq
               type-diagnostic
               (seq-find
                (lambda (item)
                  (and
                   (string-prefix-p
                    "svelte"
                    (or (eglotx-svelte-preset-e2e--diagnostic-source item)
                        ""))
                   (string-match-p
                    "not assignable to type.*string"
                    (flymake-diagnostic-text item))))
                (flymake-diagnostics))
               optional-diagnostic
               (seq-find
                (lambda (item)
                  (and
                   (string-prefix-p
                    optional-backend
                    (or (eglotx-svelte-preset-e2e--diagnostic-source item)
                        ""))
                   (string-match-p "unused"
                                   (flymake-diagnostic-text item))))
                (flymake-diagnostics))))
            (unless (and type-diagnostic optional-diagnostic)
              (error
               "Svelte type and %s diagnostics did not arrive: %S"
               optional-backend
               (mapcar
                (lambda (item)
                  (list
                   (eglotx-svelte-preset-e2e--diagnostic-source item)
                   (flymake-diagnostic-text item)))
                (flymake-diagnostics))))
            (when-let* ((rune-diagnostic
                         (seq-find
                          (lambda (item)
                            (string-match-p
                             (regexp-quote "$state")
                             (flymake-diagnostic-text item)))
                          (flymake-diagnostics))))
              (error "Svelte 5 rune produced a stale diagnostic: %S"
                     (flymake-diagnostic-text rune-diagnostic)))
            (prin1
             (list :project project-name
                   :backends
                   (mapcar #'eglotx--backend-name (eglotx--backends server))
                   :formatter
                   expected-formatter
                   :tailwindResolvedLabel tailwind-resolved-label
                   :svelteResolvedLabel svelte-resolved-label
                   :typeDiagnostic
                   (flymake-diagnostic-text type-diagnostic)
                   :optionalDiagnostic
                   (flymake-diagnostic-text optional-diagnostic)))
            (terpri))))
    (when (and server (jsonrpc-running-p server))
      (ignore-errors (eglot-shutdown server)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;; eglotx-svelte-preset-e2e.el ends here
