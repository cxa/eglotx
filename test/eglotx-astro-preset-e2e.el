;;; eglotx-astro-preset-e2e.el --- Real Astro preset smoke test  -*- lexical-binding: t; -*-

;; This file is intentionally excluded from the default ERT suite.

;;; Code:

(require 'eglotx-embedded-web-preset-e2e)

(define-derived-mode eglotx-astro-preset-e2e-mode prog-mode
  "Eglotx-E2E-Astro")

(eglotx-embedded-web-preset-e2e-run
 (list
  :language "astro"
  :mode 'eglotx-astro-preset-e2e-mode
  :contact 'eglotx-presets-astro-contact
  :test-directory (file-name-directory (or load-file-name buffer-file-name))
  :source "src/pages/index.astro"
  :primary-program "astro-ls"
  :required-files '("node_modules/typescript/lib/typescript.js")
  :completion-marker "count."
  :completion-label "toFixed"
  :type-diagnostic-regexp "not assignable to type.*string"
  :scenarios
  '(("eslint"
     :project "astro_ts_tailwind_eslint"
     :program "vscode-eslint-language-server"
     :backends ("astro" "eslint" "tailwindcss")
     :formatter "astro")
    ("biome"
     :project "astro_ts_tailwind_biome"
     :program "biome"
     :backends ("biome" "astro" "tailwindcss")
     :formatter "biome"))))

;;; eglotx-astro-preset-e2e.el ends here
