;;; eglotx-preset-e2e.el --- Real preset server smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.  It starts
;; real language servers declared by one minimal project under test/projects.

(require 'cl-lib)
(require 'seq)
(require 'flymake)
(require 'eglot)
(require 'eglotx-presets)

(define-derived-mode eglotx-preset-e2e--tsx-mode js-jsx-mode "Eglotx-E2E-TSX")

(defconst eglotx-preset-e2e--test-directory
  (file-name-directory (or load-file-name buffer-file-name)))

(defun eglotx-preset-e2e--required-environment (name)
  "Return required environment variable NAME or signal an error."
  (or (getenv name)
      (error "The %s environment variable is required" name)))

(defun eglotx-preset-e2e--diagnostic-source (diagnostic)
  "Return the LSP source recorded on Flymake DIAGNOSTIC."
  (when-let* ((data (flymake-diagnostic-data diagnostic))
              (wire (alist-get 'eglot-lsp-diag data)))
    (plist-get wire :source)))

(defun eglotx-preset-e2e--backend (server name)
  "Return SERVER backend named NAME."
  (seq-find (lambda (backend)
              (equal (eglotx--backend-name backend) name))
            (eglotx--backends server)))

(defun eglotx-preset-e2e--median (numbers)
  "Return the median of non-empty NUMBERS."
  (let* ((ordered (sort (copy-sequence numbers) #'<))
         (count (length ordered))
         (middle (/ count 2)))
    (if (cl-oddp count)
        (nth middle ordered)
      (/ (+ (nth (1- middle) ordered) (nth middle ordered)) 2.0))))

(defun eglotx-preset-e2e--corfu-probe (server)
  "Exercise real Tailwind completion through Eglot, Orderless, and Corfu."
  (dolist (library '(orderless corfu))
    (unless (require library nil t)
      (error "%s is required for EGLOTX_E2E_CORFU" library)))
  (unless (fboundp 'corfu--capf-wrapper)
    (error "Installed Corfu has no compatible CAPF wrapper"))
  (save-excursion
    (goto-char (point-min))
    (unless (search-forward "className=\"" nil t)
      (error "Corfu Tailwind probe class was not found"))
    (let ((value-start (point)))
      (unless (search-forward "\"" nil t)
        (error "Corfu Tailwind probe class is unterminated"))
      (delete-region value-start (1- (point)))
      (goto-char value-start))
    (eglot--signal-textDocument/didChange)
    (let ((completion-category-overrides
           '((eglot-capf (styles orderless))))
          (completion-styles '(orderless basic))
          (max-seconds
           (string-to-number
            (or (getenv "EGLOTX_CORFU_MAX_SECONDS") "0.15")))
          samples capf allocation stale-candidate stale-docsig)
      (corfu-mode 1)
      (cl-labels
          ((compute
            ()
            (eglot--capf-session-flush)
            (or (corfu--capf-wrapper #'eglot-completion-at-point)
                (error "Corfu rejected Eglot's completion CAPF"))))
        ;; Warm the language server, JSON decoder, Eglot CAPF, Orderless, and
        ;; Corfu's candidate state before collecting end-to-end samples.  Keep
        ;; that first candidate and its metadata callback alive while later
        ;; CAPFs evict the facade's bounded lookup cache.  Corfu Echo performs
        ;; this same delayed docs lookup from a timer.
        (let* ((stale-capf (compute))
               (stale-properties (nthcdr 4 stale-capf))
               (stale-state (plist-get stale-properties :corfu--state)))
          (setq stale-candidate
                (seq-find
                 (lambda (candidate) (equal candidate "block"))
                 (alist-get 'corfu--candidates stale-state))
                stale-docsig
                (plist-get stale-properties :company-docsig)))
        (unless (and stale-candidate (functionp stale-docsig))
          (error "Corfu did not expose a delayed Tailwind docs lookup"))
        (dotimes (_ 3)
          (garbage-collect)
          (let ((started (float-time)))
            (setq capf (compute))
            (push (- (float-time) started) samples)))
        (setq samples (nreverse samples))
        (garbage-collect)
        (let ((before (memory-use-counts)) after)
          (setq capf (compute)
                after (memory-use-counts)
                allocation (cl-mapcar #'- after before))))
      ;; The old candidate must resolve after fixed-size batch eviction while
      ;; the original Corfu metadata closure still owns it.
      (funcall stale-docsig stale-candidate)
      (let* ((properties (nthcdr 4 capf))
             (state (plist-get properties :corfu--state))
             (candidates (alist-get 'corfu--candidates state))
             (median (eglotx-preset-e2e--median samples))
             (selected
              (seq-find
               (lambda (candidate)
                 (when (equal candidate "block")
                   (when-let* ((item
                                (get-text-property
                                 0 'eglot--lsp-item candidate))
                               (owner
                                (eglotx--owner-for-params server item)))
                     (equal
                      (eglotx--backend-name
                       (eglotx--owner-backend owner))
                      "tailwindcss"))))
               candidates))
             (item (and selected
                        (get-text-property 0 'eglot--lsp-item selected))))
        (unless (> (length candidates) 8192)
          (error "Corfu saw only %d candidates" (length candidates)))
        (unless selected
          (error "Corfu omitted Tailwind's block candidate"))
        (when (plist-member item :textEdit)
          (error "Tailwind editRange was eagerly expanded before selection"))
        (when (and (> max-seconds 0) (> median max-seconds))
          (error "Corfu median %.3fs exceeded %.3fs"
                 median max-seconds))
        (pcase-let ((`(,_ ,beg ,end ,_ . ,exit-properties) capf))
          (delete-region beg end)
          (goto-char beg)
          (insert selected)
          (funcall (plist-get exit-properties :exit-function)
                   selected 'finished))
        (save-excursion
          (goto-char (point-min))
          (unless (search-forward "className=\"block\"" nil t)
            (error "Corfu selection did not apply Tailwind's resolved edit")))
        (list
         :candidateCount (length candidates)
         :samplesMilliseconds
         (vconcat (mapcar (lambda (sample) (* sample 1000.0)) samples))
         :medianMilliseconds (* median 1000.0)
         :allocationConses (nth 0 allocation)
         :allocationStrings (nth 6 allocation)
         :allocationStringCharacters (nth 4 allocation)
         :staleDocsigResolved t
         :selected "block")))))

(let* ((project-name
        (eglotx-preset-e2e--required-environment "EGLOTX_E2E_PROJECT"))
       (optional
        (eglotx-preset-e2e--required-environment "EGLOTX_E2E_BACKEND"))
       (root
        (file-name-as-directory
         (expand-file-name (concat "projects/" project-name)
                           eglotx-preset-e2e--test-directory)))
       (source (expand-file-name "src/App.tsx" root))
       (optional-program
        (pcase optional
          ("biome" "biome")
          ("eslint" "vscode-eslint-language-server")
          (_ (error "Unsupported E2E backend %S" optional))))
       buffer server completion-count completion-elapsed
       completion-resolved-labels corfu-profile)
  (dolist (program
           (list "typescript-language-server"
                 "tailwindcss-language-server"
                 optional-program))
    (unless (or (executable-find program)
                (file-executable-p
                 (expand-file-name (concat "node_modules/.bin/" program)
                                   root)))
      (error "%s is required on PATH or under %s/node_modules/.bin"
             program root)))
  (eglotx-presets-mode 1)
  (add-to-list
   'eglot-server-programs
   '(((eglotx-preset-e2e--tsx-mode :language-id "typescriptreact"))
     . eglotx-presets-javascript-typescript-react-contact))
  (unwind-protect
      (progn
        (setq buffer (find-file-noselect source))
        (with-current-buffer buffer
          (eglotx-preset-e2e--tsx-mode)
          ;; Keep each nested fixture independent from the enclosing Eglotx
          ;; Git repository without adding VCS metadata to test data.
          (let ((default-directory root)
                (project-find-functions
                 (list (lambda (_directory) (cons 'transient root)))))
            (call-interactively #'eglot)
            (let ((deadline (+ (float-time) 15.0)))
              (while (and (not (setq server (eglot-current-server)))
                          (< (float-time) deadline))
                (accept-process-output nil 0.1))))
          (unless (and server (object-of-class-p server 'eglotx-server))
            (error "%s did not create an Eglotx facade" project-name))
          (unless (seq-every-p
                   (lambda (backend)
                     (eq (eglotx--backend-state backend) 'ready))
                   (eglotx--backends server))
            (error "%s has a backend that is not ready: %S"
                   project-name (eglotx-status server)))
          (let* ((names (mapcar #'eglotx--backend-name
                                (eglotx--backends server)))
                 (expected (if (equal optional "biome")
                               '("biome" "typescript" "tailwindcss")
                             '("typescript" "eslint" "tailwindcss"))))
            (unless (equal names expected)
              (error "%s resolved backends %S, expected %S"
                     project-name names expected)))
          (let* ((backend (eglotx-preset-e2e--backend server optional))
                 (command (eglotx--backend-command backend)))
            (unless
                (equal (cdr command)
                       (if (equal optional "biome")
                           '("lsp-proxy")
                         '("--stdio")))
              (error "%s used unexpected command %S" optional command)))
          (let* ((params
                  (list :textDocument
                        (list :uri
                              (eglotx-presets--path-to-uri
                               buffer-file-name))))
                 (targets
                  (eglotx--select-request-targets
                   server :textDocument/formatting params
                   (eglotx--policy :textDocument/formatting)))
                 (formatter (and targets
                                 (eglotx--backend-name (car targets))))
                 (expected-formatter
                  (if (equal optional "biome") "biome" "typescript")))
            (unless (equal formatter expected-formatter)
              (error "%s formatter is %S, expected %S"
                     project-name formatter expected-formatter)))
          (save-excursion
            (goto-char (point-min))
            (unless (search-forward "className=\"p-4 " nil t)
              (error "Tailwind completion probe position was not found"))
            (let* ((params
                    (list
                     :textDocument
                     (list :uri
                           (eglotx-presets--path-to-uri buffer-file-name))
                     :position (eglot--pos-to-lsp-position)
                     :context (list :triggerKind 1)))
                   (started (float-time))
                   (completion
                    (jsonrpc-request
                     server :textDocument/completion params :timeout 30))
                   (items (plist-get completion :items))
                   (probe-labels '("*:" "block" "zoom-200"))
                   (known-tailwind-items
                    (mapcar
                     (lambda (label)
                       (seq-find
                        (lambda (item)
                          (equal (plist-get item :label) label))
                        items))
                     probe-labels)))
              (setq completion-elapsed (- (float-time) started)
                    completion-count (length items))
              (unless (> completion-count 8192)
                (error "Facade returned only %d completion items"
                       completion-count))
              (unless (seq-every-p #'identity known-tailwind-items)
                (error "Facade completion omitted Tailwind probes: %S"
                       (cl-loop for label in probe-labels
                                for item in known-tailwind-items
                                unless item collect label)))
              (setq completion-resolved-labels
                    (mapcar
                     (lambda (item)
                       (plist-get
                        (jsonrpc-request
                         server :completionItem/resolve item :timeout 15)
                        :label))
                     known-tailwind-items))
              (unless (equal completion-resolved-labels probe-labels)
                (error "Tailwind resolve returned unexpected labels: %S"
                       completion-resolved-labels))))
          (when (getenv "EGLOTX_E2E_CORFU")
            (setq corfu-profile
                  (eglotx-preset-e2e--corfu-probe server)))
          (goto-char (point-max))
          (insert
           "\nvar eglotxPresetProbe = 1;\n"
           "const eglotxPresetTypeProbe = Math.eglotxMissingProperty;\n")
          ;; Batch Emacs never goes idle while this harness pumps process
          ;; output, so explicitly flush Eglot's idle-coalesced change.
          (eglot--signal-textDocument/didChange)
          (flymake-start nil t)
          (let ((deadline (+ (float-time) 10.0))
                optional-diagnostic type-diagnostic)
            (while (and (not (and optional-diagnostic type-diagnostic))
                        (< (float-time) deadline))
              (accept-process-output nil 0.1)
              (setq optional-diagnostic
                    (seq-find
                     (lambda (item)
                       (string-prefix-p
                        optional
                        (or (eglotx-preset-e2e--diagnostic-source item) "")))
                     (flymake-diagnostics))
                    type-diagnostic
                    (seq-find
                     (lambda (item)
                       (string-match-p
                        "does not exist on type.*Math"
                        (flymake-diagnostic-text item)))
                     (flymake-diagnostics))))
            (unless (and optional-diagnostic type-diagnostic)
              (error "%s and TypeScript diagnostics did not reach Flymake: %S"
                     optional
                     (mapcar
                      (lambda (item)
                        (list (eglotx-preset-e2e--diagnostic-source item)
                              (flymake-diagnostic-text item)))
                      (flymake-diagnostics))))
            (when (and (equal optional "eslint")
                       (not (string-match-p
                             "Unexpected var"
                             (flymake-diagnostic-text optional-diagnostic))))
              (error "ESLint did not run no-var: %s"
                     (flymake-diagnostic-text optional-diagnostic)))
            (prin1
             (list :project project-name
                   :backends
                   (mapcar #'eglotx--backend-name (eglotx--backends server))
                   :optionalCommand
                   (eglotx--backend-command
                    (eglotx-preset-e2e--backend server optional))
                   :diagnosticSource
                   (eglotx-preset-e2e--diagnostic-source
                    optional-diagnostic)
                   :diagnostic
                   (flymake-diagnostic-text optional-diagnostic)
                   :typescriptDiagnosticSource
                   (eglotx-preset-e2e--diagnostic-source type-diagnostic)
                   :typescriptDiagnostic
                   (flymake-diagnostic-text type-diagnostic)
                   :completionCount completion-count
                   :completionSeconds completion-elapsed
                   :resolvedLabels completion-resolved-labels
                   :corfuProfile corfu-profile))
            (terpri))))
    (when (and server (jsonrpc-running-p server))
      (ignore-errors (eglot-shutdown server)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (set-buffer-modified-p nil))
      (kill-buffer buffer))))

;;; eglotx-preset-e2e.el ends here
