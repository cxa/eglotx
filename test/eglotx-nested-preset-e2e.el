;;; eglotx-nested-preset-e2e.el --- Nested TypeScript/ESLint regression  -*- lexical-binding: t; -*-

;; Opt-in real-server test for discussion #3.  Each scenario uses a temporary
;; Git repository, actual project.el discovery, and the bundled mode catalog.

(require 'ert)
(require 'flymake)
(require 'eglotx-presets)
(require 'treesit)
(require 'typescript-ts-mode)

(defvar treesit-auto-install-grammar)

(defconst eglotx-nested-preset-e2e--fixture
  (expand-file-name "projects/nested_ts_eslint/frontend/"
                    (file-name-directory (or load-file-name buffer-file-name))))

(ert-deftest eglotx-nested-typescript-eslint-e2e ()
  (dolist (markers '(nil ("package.json")))
    (let* ((temporary (make-temp-file "eglotx nested e2e-" t))
           (repo (expand-file-name "repo/" temporary))
           (frontend (expand-file-name "frontend/" repo))
           (bin (expand-file-name "bin/" temporary))
           (typescript (expand-file-name "toolchain/typescript-language-server"
                                        temporary))
           (expected-root (if markers frontend repo))
           (project-vc-extra-root-markers markers)
           (treesit-auto-install-grammar nil)
           (auto-mode-alist (cons '("\\.ts\\'" . typescript-ts-mode)
                                  auto-mode-alist))
           (eglot-server-programs (copy-tree eglot-server-programs))
           (process-environment (copy-sequence process-environment))
           buffer server)
      (unwind-protect
          (progn
            (dolist (name '("typescript-language-server"
                            "vscode-eslint-language-server"))
              (unless (file-executable-p
                       (expand-file-name (concat "node_modules/.bin/" name)
                                         eglotx-nested-preset-e2e--fixture))
                (error "Run npm install --prefix %s first"
                       eglotx-nested-preset-e2e--fixture)))
            (make-directory repo t)
            (copy-directory eglotx-nested-preset-e2e--fixture frontend
                            nil t t)
            (make-directory bin t)
            (dolist (name '("node" "git"))
              (make-symbolic-link
               (or (executable-find name) (error "%s is required" name))
               (expand-file-name name bin)))
            ;; Keep TLS outside both the repository and PATH, as with a
            ;; manually configured nvm executable.  Change only the copy.
            (let ((local (expand-file-name
                          "node_modules/.bin/typescript-language-server"
                          frontend)))
              (make-directory (file-name-directory typescript) t)
              (make-symbolic-link (file-truename local) typescript)
              (delete-file local))
            (setenv "PATH" bin)
            (let ((exec-path (list bin)))
              (should (= 0 (call-process "git" nil nil nil "init" "-q" repo)))
              (should-not (executable-find "typescript-language-server"))
              (let ((entry (cons 'typescript-ts-base-mode
                                 (list typescript "--stdio"))))
                (add-to-list 'eglot-server-programs entry)
                (eglotx-presets-mode 1)
                (setq buffer (find-file-noselect
                              (expand-file-name "src/main.ts" frontend)))
                (with-current-buffer buffer
                  (should (eq major-mode 'typescript-ts-mode))
                  (let ((project (project-current)))
                    (should (eq (car project) 'vc))
                    (should (file-equal-p (project-root project) expected-root)))
                  ;; A later user entry intentionally overrides the presets.
                  (let ((eglot-server-programs
                         (cons entry eglot-server-programs)))
                    (should (eq (nth 2 (eglot--guess-contact))
                                'eglot-lsp-server)))
                  (call-interactively #'eglot)
                  (let ((deadline (+ (float-time) 15)))
                    (while (and (not (setq server (eglot-current-server)))
                                (< (float-time) deadline))
                      (accept-process-output nil 0.1)))
                  (should (and server (object-of-class-p server 'eglotx-server)))
                  (should
                   (file-equal-p (project-root (eglot--project server))
                                 expected-root))
                  (should (equal (mapcar #'eglotx--backend-name
                                         (eglotx--backends server))
                                 '("typescript" "eslint")))
                  (should (equal (eglotx--backend-command
                                  (car (eglotx--backends server)))
                                 (list typescript "--stdio")))
                  (should (eq (plist-get (eglotx-status server) :state) 'running))
                  (flymake-start nil t)
                  (let ((deadline (+ (float-time) 15)) diagnostics lint type)
                    (while (and (not (and lint type)) (< (float-time) deadline))
                      (accept-process-output nil 0.1)
                      (setq diagnostics
                            (mapcar #'flymake-diagnostic-text
                                    (flymake-diagnostics))
                            lint (seq-find (lambda (text)
                                             (string-match-p "Unexpected var" text))
                                           diagnostics)
                            type (seq-find (lambda (text)
                                             (string-match-p
                                              "does not exist on type.*Math" text))
                                           diagnostics)))
                    (should lint)
                    (should type))
                  (let ((actions (eglot-code-actions
                                  (point-min) (point-max) "source.fixAll.eslint")))
                    (should actions)
                    (eglot-execute server (car actions)))
                  (should (string-match-p "let count = 1" (buffer-string)))
                  (should-not (string-match-p "var count" (buffer-string)))
                  (message "Nested E2E: root=%s, TypeScript+ESLint, fix-all passed"
                           (if markers "frontend/package.json" "repo/.git"))))))
        (when (and server (jsonrpc-running-p server))
          (ignore-errors (eglot-shutdown server)))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))
        (eglotx-presets-mode -1)
        (delete-directory temporary t)))))

(ert-run-tests-batch-and-exit 'eglotx-nested-typescript-eslint-e2e)

;;; eglotx-nested-preset-e2e.el ends here
