;;; eglotx-angular-preset-e2e.el --- Real Angular preset smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.  It starts
;; the real Angular and TypeScript language servers declared by the minimal
;; Angular project under test/projects.

;;; Code:

(require 'seq)
(require 'flymake)
(require 'eglot)
(require 'eglotx-presets)

(define-derived-mode eglotx-angular-preset-e2e-mode prog-mode
  "Eglotx-E2E-Angular")

(defconst eglotx-angular-preset-e2e--test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun eglotx-angular-preset-e2e--lsp-diagnostic (diagnostic)
  "Return the wire diagnostic recorded on Flymake DIAGNOSTIC."
  (when-let* ((data (flymake-diagnostic-data diagnostic))
              (wire (alist-get 'eglot-lsp-diag data)))
    wire))

(defun eglotx-angular-preset-e2e--diagnostic-source (diagnostic)
  "Return the LSP source recorded on Flymake DIAGNOSTIC."
  (plist-get (eglotx-angular-preset-e2e--lsp-diagnostic diagnostic) :source))

(defun eglotx-angular-preset-e2e--diagnostic-p
    (diagnostic owner code message-regexp)
  "Return non-nil when DIAGNOSTIC matches OWNER, CODE, and MESSAGE-REGEXP."
  (let ((wire (eglotx-angular-preset-e2e--lsp-diagnostic diagnostic)))
    (and
     (string-prefix-p
      (concat owner "/") (or (plist-get wire :source) ""))
     (equal (plist-get wire :code) code)
     (string-match-p message-regexp (flymake-diagnostic-text diagnostic)))))

(let* ((root
        (file-name-as-directory
         (expand-file-name "projects/angular_ts"
                           eglotx-angular-preset-e2e--test-directory)))
       (source (expand-file-name "src/app/app.component.ts" root))
       (node-modules
        (file-name-as-directory (expand-file-name "node_modules" root)))
       (bin (file-name-as-directory (expand-file-name ".bin" node-modules)))
       (typescript (expand-file-name "typescript-language-server" bin))
       (ngserver (expand-file-name "ngserver" bin))
       buffer server)
  (dolist (program (list typescript ngserver))
    (unless (file-executable-p program)
      (error "%s is required; run npm install under %s" program root)))
  (eglotx-presets-mode 1)
  (add-to-list
   'eglot-server-programs
   '(((eglotx-angular-preset-e2e-mode :language-id "typescript"))
     . eglotx-presets-javascript-typescript-contact))
  (unwind-protect
      (progn
        (setq buffer (find-file-noselect source))
        (with-current-buffer buffer
          (eglotx-angular-preset-e2e-mode)
          (let ((default-directory root)
                (project-find-functions
                 (list (lambda (_directory) (cons 'transient root)))))
            (call-interactively #'eglot)
            (let ((deadline (+ (float-time) 20.0)))
              (while (and (not (setq server (eglot-current-server)))
                          (< (float-time) deadline))
                (accept-process-output nil 0.1))))
          (unless (and server (object-of-class-p server 'eglotx-server))
            (error "Angular fixture did not create an Eglotx facade"))
          (unless
              (equal (mapcar #'eglotx--backend-name
                             (eglotx--backends server))
                     '("angular" "typescript"))
            (error "Unexpected Angular backends: %S" (eglotx-status server)))
          (unless (seq-every-p
                   (lambda (backend)
                     (eq (eglotx--backend-state backend) 'ready))
                   (eglotx--backends server))
            (error "Angular backend is not ready: %S" (eglotx-status server)))
          (let ((angular
                 (seq-find
                  (lambda (backend)
                    (equal (eglotx--backend-name backend) "angular"))
                  (eglotx--backends server)))
                (typescript-backend
                 (seq-find
                  (lambda (backend)
                    (equal (eglotx--backend-name backend) "typescript"))
                  (eglotx--backends server))))
            (unless (equal (eglotx--backend-command typescript-backend)
                           (list typescript "--stdio"))
              (error "TypeScript did not use its project-local executable: %S"
                     (eglotx--backend-command typescript-backend)))
            (unless
                (equal (eglotx--backend-command angular)
                       (list ngserver "--stdio"
                             "--tsProbeLocations" node-modules
                             "--ngProbeLocations" node-modules))
              (error "Angular used unexpected probe arguments: %S"
                     (eglotx--backend-command angular)))
            (unless (equal (eglotx--backend-languages angular)
                           '("typescript"))
              (error "Angular accepted unexpected languages: %S"
                     (eglotx--backend-languages angular))))
          (flymake-start nil t)
          (let ((deadline (+ (float-time) 20.0))
                angular-diagnostic type-diagnostic)
            (while (and (not (and angular-diagnostic type-diagnostic))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)
              (setq
               angular-diagnostic
               (seq-find
                (lambda (item)
                  (eglotx-angular-preset-e2e--diagnostic-p
                   item "angular" 2339 "missingTemplateProperty"))
                (flymake-diagnostics))
               type-diagnostic
               (seq-find
                (lambda (item)
                  (eglotx-angular-preset-e2e--diagnostic-p
                   item "typescript" 2322 "not assignable"))
                (flymake-diagnostics))))
            (unless (and angular-diagnostic type-diagnostic)
              (error
               "Angular and TypeScript diagnostics did not arrive: %S"
               (mapcar
                (lambda (item)
                  (list
                   (eglotx-angular-preset-e2e--diagnostic-source item)
                   (flymake-diagnostic-text item)))
                (flymake-diagnostics))))
            (prin1
             (list
              :backends
              (mapcar #'eglotx--backend-name (eglotx--backends server))
              :angularDiagnosticSource
              (eglotx-angular-preset-e2e--diagnostic-source
               angular-diagnostic)
              :angularDiagnostic
              (flymake-diagnostic-text angular-diagnostic)
              :typescriptDiagnosticSource
              (eglotx-angular-preset-e2e--diagnostic-source type-diagnostic)
              :typescriptDiagnostic
              (flymake-diagnostic-text type-diagnostic)))
            (terpri))))
    (when (and server (jsonrpc-running-p server))
      (ignore-errors (eglot-shutdown server)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;; eglotx-angular-preset-e2e.el ends here
