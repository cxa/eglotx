;;; eglotx-vue-preset-e2e.el --- Real Vue preset smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.  It starts
;; the real Vue, TypeScript, ESLint, and Tailwind servers declared by the
;; minimal Vue project under test/projects.

(require 'seq)
(require 'flymake)
(require 'eglot)
(require 'eglotx-presets)

(define-derived-mode eglotx-vue-preset-e2e-mode prog-mode
  "Eglotx-E2E-Vue")

(defconst eglotx-vue-preset-e2e--test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun eglotx-vue-preset-e2e--diagnostic-source (diagnostic)
  "Return the LSP source recorded on Flymake DIAGNOSTIC."
  (when-let* ((data (flymake-diagnostic-data diagnostic))
              (wire (alist-get 'eglot-lsp-diag data)))
    (plist-get wire :source)))

(let* ((root
        (file-name-as-directory
         (expand-file-name "projects/vue_ts_tailwind_eslint"
                           eglotx-vue-preset-e2e--test-directory)))
       (source (expand-file-name "src/App.vue" root))
       (bin (expand-file-name "node_modules/.bin/" root))
       (programs '("vue-language-server"
                   "typescript-language-server"
                   "vscode-eslint-language-server"
                   "tailwindcss-language-server"))
       buffer server)
  (dolist (program programs)
    (unless (file-executable-p (expand-file-name program bin))
      (error "%s is required under %s" program bin)))
  (eglotx-presets-mode 1)
  (add-to-list
   'eglot-server-programs
   '(((eglotx-vue-preset-e2e-mode :language-id "vue"))
     . eglotx-presets-vue-contact))
  (unwind-protect
      (progn
        (setq buffer (find-file-noselect source))
        (with-current-buffer buffer
          (eglotx-vue-preset-e2e-mode)
          (let ((default-directory root)
                (project-find-functions
                 (list (lambda (_directory) (cons 'transient root)))))
            (call-interactively #'eglot)
            (let ((deadline (+ (float-time) 20.0)))
              (while (and (not (setq server (eglot-current-server)))
                          (< (float-time) deadline))
                (accept-process-output nil 0.1))))
          (unless (and server (object-of-class-p server 'eglotx-server))
            (error "Vue fixture did not create an Eglotx facade"))
          (unless
              (equal (mapcar #'eglotx--backend-name
                             (eglotx--backends server))
                     '("vue" "typescript" "eslint" "tailwindcss"))
            (error "Unexpected Vue backends: %S" (eglotx-status server)))
          (unless (seq-every-p
                   (lambda (backend)
                     (eq (eglotx--backend-state backend) 'ready))
                   (eglotx--backends server))
            (error "Vue backend is not ready: %S" (eglotx-status server)))
          (dolist (backend (eglotx--backends server))
            (unless (string-prefix-p bin
                                     (car (eglotx--backend-command backend)))
              (error "%s did not use its project-local executable: %S"
                     (eglotx--backend-name backend)
                     (eglotx--backend-command backend))))
          ;; A Vue hover causes VLS to consult the TypeScript child through
          ;; tsserver/request on current language-tools releases.  The exact
          ;; hover contents are upstream policy; bounded completion is ours.
          (jsonrpc-request
           server :textDocument/hover
           (list :textDocument
                 (list :uri (eglotx-presets--path-to-uri buffer-file-name))
                 :position (list :line 8 :character 36))
           :timeout 15)
          (let ((deadline (+ (float-time) 5.0)))
            (while (and (zerop
                         (plist-get (eglotx--status-snapshot server)
                                    :bridgeRequests))
                        (< (float-time) deadline))
              (accept-process-output nil 0.05)))
          (unless (and (> (plist-get (eglotx--status-snapshot server)
                                     :bridgeRequests)
                          0)
                       (zerop
                        (plist-get (eglotx--status-snapshot server)
                                   :pendingBridgeRequests)))
            (error "Vue TypeScript bridge did not settle: %S"
                   (eglotx-status server)))
          (flymake-start nil t)
          (let ((deadline (+ (float-time) 15.0))
                type-diagnostic eslint-diagnostic)
            (while (and (not (and type-diagnostic eslint-diagnostic))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)
              (setq
               type-diagnostic
               (seq-find
                (lambda (item)
                  (string-match-p
                   "not assignable to type.*string"
                   (flymake-diagnostic-text item)))
                (flymake-diagnostics))
               eslint-diagnostic
               (seq-find
                (lambda (item)
                  (and
                   (string-prefix-p
                    "eslint"
                    (or (eglotx-vue-preset-e2e--diagnostic-source item) ""))
                   (string-match-p "unused"
                                   (flymake-diagnostic-text item))))
                (flymake-diagnostics))))
            (unless (and type-diagnostic eslint-diagnostic)
              (error
               "Vue TypeScript and ESLint diagnostics did not arrive: %S"
               (mapcar
                (lambda (item)
                  (list (eglotx-vue-preset-e2e--diagnostic-source item)
                        (flymake-diagnostic-text item)))
                (flymake-diagnostics))))
            (prin1
             (list :backends
                   (mapcar #'eglotx--backend-name (eglotx--backends server))
                   :bridgeRequests
                   (plist-get (eglotx--status-snapshot server)
                              :bridgeRequests)
                   :typescriptDiagnostic
                   (flymake-diagnostic-text type-diagnostic)
                   :eslintDiagnostic
                   (flymake-diagnostic-text eslint-diagnostic)))
            (terpri))))
    (when (and server (jsonrpc-running-p server))
      (ignore-errors (eglot-shutdown server)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;; eglotx-vue-preset-e2e.el ends here
