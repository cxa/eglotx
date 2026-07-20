;;; eglotx-svelte-preset-e2e.el --- Real Svelte preset smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.

;;; Code:

(require 'eglotx-embedded-web-preset-e2e)

(define-derived-mode eglotx-svelte-preset-e2e-mode prog-mode
  "Eglotx-E2E-Svelte")

(defun eglotx-svelte-preset-e2e--validate-diagnostics (diagnostics)
  "Reject stale Svelte 5 rune errors in DIAGNOSTICS."
  (when-let* ((rune-diagnostic
               (seq-find
                (lambda (item)
                  (string-match-p
                   (regexp-quote "$state")
                   (flymake-diagnostic-text item)))
                diagnostics)))
    (error "Svelte 5 rune produced a stale diagnostic: %S"
           (flymake-diagnostic-text rune-diagnostic))))

(eglotx-embedded-web-preset-e2e-run
 (list
  :language "svelte"
  :mode 'eglotx-svelte-preset-e2e-mode
  :contact 'eglotx-presets-svelte-contact
  :test-directory (file-name-directory (or load-file-name buffer-file-name))
  :source "src/App.svelte"
  :primary-program "svelteserver"
  :completion-marker "count."
  :completion-label "toFixed"
  :type-diagnostic-regexp "not assignable to type.*string"
  :validate-diagnostics #'eglotx-svelte-preset-e2e--validate-diagnostics
  :scenarios
  '(("eslint"
     :project "svelte_ts_tailwind_eslint"
     :program "vscode-eslint-language-server"
     :backends ("svelte" "eslint" "tailwindcss")
     :formatter "svelte")
    ("biome"
     :project "svelte_ts_tailwind_biome"
     :program "biome"
     :backends ("biome" "svelte" "tailwindcss")
     :formatter "biome"))))

;;; eglotx-svelte-preset-e2e.el ends here
