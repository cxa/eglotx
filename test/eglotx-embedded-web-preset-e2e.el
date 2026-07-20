;;; eglotx-embedded-web-preset-e2e.el --- Shared real-server smoke driver  -*- lexical-binding: t; -*-

;; This helper is loaded only by opt-in embedded-Web E2E scripts.  It starts
;; one structural server, one lint/format add-on, and Tailwind from a minimal
;; project under test/projects.

;;; Code:

(require 'seq)
(require 'flymake)
(require 'eglot)
(require 'eglotx-presets)

(defun eglotx-embedded-web-preset-e2e--diagnostic-source (diagnostic)
  "Return the LSP source recorded on Flymake DIAGNOSTIC."
  (when-let* ((data (flymake-diagnostic-data diagnostic))
              (wire (alist-get 'eglot-lsp-diag data)))
    (plist-get wire :source)))

(defun eglotx-embedded-web-preset-e2e--assert-completion
    (server marker label expected-owner)
  "Assert SERVER resolves LABEL after MARKER through EXPECTED-OWNER."
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

(defun eglotx-embedded-web-preset-e2e--wait-for-server ()
  "Return the current Eglot server, waiting up to thirty seconds."
  (let ((deadline (+ (float-time) 30.0)) server)
    (while (and (not (setq server (eglot-current-server)))
                (< (float-time) deadline))
      (accept-process-output nil 0.1))
    server))

(defun eglotx-embedded-web-preset-e2e-run (config)
  "Run a real embedded-Web preset smoke test described by CONFIG.

CONFIG declares `:language', `:mode', `:contact', `:test-directory',
`:source', `:primary-program', `:scenarios', `:completion-marker',
`:completion-label', and `:type-diagnostic-regexp'.  Optional
`:required-files' are checked below the selected fixture, and
`:validate-diagnostics' receives the final Flymake diagnostic list."
  (let* ((language (plist-get config :language))
         (display-name (capitalize language))
         (mode (plist-get config :mode))
         (contact (plist-get config :contact))
         (optional-backend (or (getenv "EGLOTX_E2E_BACKEND") "eslint"))
         (scenario
          (or (cdr (assoc optional-backend (plist-get config :scenarios)))
              (error "Unsupported %s E2E backend %S"
                     display-name optional-backend)))
         (project-name (plist-get scenario :project))
         (expected-backends (plist-get scenario :backends))
         (expected-formatter (plist-get scenario :formatter))
         (root
          (file-name-as-directory
           (expand-file-name
            (concat "projects/" project-name)
            (plist-get config :test-directory))))
         (source (expand-file-name (plist-get config :source) root))
         (bin (expand-file-name "node_modules/.bin/" root))
         buffer server tailwind-label primary-label)
    (dolist (program
             (list (plist-get config :primary-program)
                   "tailwindcss-language-server"
                   (plist-get scenario :program)))
      (unless (file-executable-p (expand-file-name program bin))
        (error "%s is required under %s" program bin)))
    (dolist (relative (plist-get config :required-files))
      (unless (file-exists-p (expand-file-name relative root))
        (error "%s is required under %s" relative root)))
    (eglotx-presets-mode 1)
    (add-to-list
     'eglot-server-programs
     (cons (list (list mode :language-id language)) contact))
    (unwind-protect
        (progn
          (setq buffer (find-file-noselect source))
          (with-current-buffer buffer
            (funcall mode)
            (let ((default-directory root)
                  (project-find-functions
                   (list (lambda (_directory) (cons 'transient root)))))
              (call-interactively #'eglot)
              (setq server
                    (eglotx-embedded-web-preset-e2e--wait-for-server)))
            (unless (and server (object-of-class-p server 'eglotx-server))
              (error "%s did not create an Eglotx facade" project-name))
            (unless
                (equal (mapcar #'eglotx--backend-name
                               (eglotx--backends server))
                       expected-backends)
              (error "Unexpected %s backends: %S"
                     display-name (eglotx-status server)))
            (unless (seq-every-p
                     (lambda (backend)
                       (eq (eglotx--backend-state backend) 'ready))
                     (eglotx--backends server))
              (error "%s backend is not ready: %S"
                     display-name (eglotx-status server)))
            (dolist (backend (eglotx--backends server))
              (unless (string-prefix-p
                       bin (car (eglotx--backend-command backend)))
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
                (error "%s formatter is %S, expected %S"
                       display-name formatter expected-formatter)))
            (setq tailwind-label
                  (eglotx-embedded-web-preset-e2e--assert-completion
                   server "class=\"p-4 " "block" "tailwindcss")
                  primary-label
                  (eglotx-embedded-web-preset-e2e--assert-completion
                   server
                   (plist-get config :completion-marker)
                   (plist-get config :completion-label)
                   language))
            (flymake-start nil t)
            (let ((deadline (+ (float-time) 20.0))
                  type-diagnostic optional-diagnostic diagnostics)
              (while (and (not (and type-diagnostic optional-diagnostic))
                          (< (float-time) deadline))
                (accept-process-output nil 0.1)
                (setq
                 diagnostics (flymake-diagnostics)
                 type-diagnostic
                 (seq-find
                  (lambda (item)
                    (and
                     (string-prefix-p
                      language
                      (or
                       (eglotx-embedded-web-preset-e2e--diagnostic-source item)
                       ""))
                     (string-match-p
                      (plist-get config :type-diagnostic-regexp)
                      (flymake-diagnostic-text item))))
                  diagnostics)
                 optional-diagnostic
                 (seq-find
                  (lambda (item)
                    (and
                     (string-prefix-p
                      optional-backend
                      (or
                       (eglotx-embedded-web-preset-e2e--diagnostic-source item)
                       ""))
                     (string-match-p "unused"
                                     (flymake-diagnostic-text item))))
                  diagnostics)))
              (unless (and type-diagnostic optional-diagnostic)
                (error
                 "%s type and %s diagnostics did not arrive: %S"
                 display-name optional-backend
                 (mapcar
                  (lambda (item)
                    (list
                     (eglotx-embedded-web-preset-e2e--diagnostic-source item)
                     (flymake-diagnostic-text item)))
                  diagnostics)))
              (when-let* ((validator (plist-get config :validate-diagnostics)))
                (funcall validator diagnostics))
              (prin1
               (list :project project-name
                     :backends
                     (mapcar #'eglotx--backend-name
                             (eglotx--backends server))
                     :formatter expected-formatter
                     :tailwindResolvedLabel tailwind-label
                     :primaryResolvedLabel primary-label
                     :typeDiagnostic
                     (flymake-diagnostic-text type-diagnostic)
                     :optionalDiagnostic
                     (flymake-diagnostic-text optional-diagnostic)))
              (terpri))))
      (when (and server (jsonrpc-running-p server))
        (ignore-errors (eglot-shutdown server)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(provide 'eglotx-embedded-web-preset-e2e)
;;; eglotx-embedded-web-preset-e2e.el ends here
