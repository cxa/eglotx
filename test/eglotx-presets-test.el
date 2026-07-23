;;; eglotx-presets-test.el --- Tests for Eglotx presets  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;;; Commentary:

;; These tests exercise the public presets interface through temporary
;; project trees.  No language server process is started.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'eglotx-presets)

(defconst eglotx-presets-test--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing the preset tests and project fixtures.")

(cl-defmacro eglotx-presets-test--with-directory ((directory) &body body)
  "Create DIRECTORY and remove it after evaluating BODY."
  (declare (indent 1) (debug (sexp body)))
  `(let ((,directory (file-name-as-directory
                      (make-temp-file "eglotx presets test-" t))))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,directory t))))

(cl-defmacro eglotx-presets-test--with-mode-state (&body body)
  "Evaluate BODY without changing the global presets mode default."
  (declare (indent 0) (debug body))
  `(let ((saved-mode (default-value 'eglotx-presets-mode)))
     (unwind-protect
         (progn
           (set-default 'eglotx-presets-mode nil)
           ,@body)
       (set-default 'eglotx-presets-mode saved-mode))))

(defun eglotx-presets-test--write-file (root relative contents)
  "Under ROOT, write CONTENTS to RELATIVE and return its path."
  (let ((path (expand-file-name relative root)))
    (make-directory (file-name-directory path) t)
    (write-region contents nil path nil 'silent)
    path))

(defun eglotx-presets-test--make-executable (root relative)
  "Under ROOT, create executable RELATIVE and return its path."
  (let ((path (eglotx-presets-test--write-file root relative "")))
    (set-file-modes path #o755)
    path))

(defun eglotx-presets-test--local-server (root name)
  "Under ROOT, create a project-local server named NAME."
  (eglotx-presets-test--make-executable
   root (concat "node_modules/.bin/" name)))

(defun eglotx-presets-test--vue-language-server (root)
  "Install a realistic project-local Vue language server under ROOT.
Return a cons of its executable and package directory."
  (let* ((package-directory
          (expand-file-name "node_modules/@vue/language-server/" root))
         (program
          (eglotx-presets-test--make-executable
           package-directory "bin/vue-language-server.js"))
         (link (expand-file-name
                "node_modules/.bin/vue-language-server" root)))
    (eglotx-presets-test--write-file
     package-directory "package.json"
     "{\"name\":\"@vue/language-server\",\"version\":\"3.3.7\"}")
    (eglotx-presets-test--write-file
     root "node_modules/@vue/typescript-plugin/package.json"
     "{\"name\":\"@vue/typescript-plugin\",\"version\":\"3.3.7\"}")
    (make-directory (file-name-directory link) t)
    (make-symbolic-link program link t)
    (cons link package-directory)))

(defun eglotx-presets-test--biome-server (root version)
  "Install a realistic project-local Biome VERSION under ROOT."
  (let* ((package-directory
          (expand-file-name "node_modules/@biomejs/biome/" root))
         (program
          (eglotx-presets-test--make-executable
           package-directory "bin/biome"))
         (link (expand-file-name "node_modules/.bin/biome" root)))
    (eglotx-presets-test--write-file
     package-directory "package.json"
     (format "{\"name\":\"@biomejs/biome\",\"version\":\"%s\"}"
             version))
    (make-directory (file-name-directory link) t)
    (make-symbolic-link program link t)
    link))

(defun eglotx-presets-test--python-server (root name)
  "Under ROOT, create a Python virtual-environment server named NAME."
  (eglotx-presets-test--make-executable
   root (concat ".venv/bin/" name)))

(defun eglotx-presets-test--project-bin-server (root name)
  "Under ROOT, create a fixed project `bin' server named NAME."
  (eglotx-presets-test--make-executable root (concat "bin/" name)))

(defun eglotx-presets-test--global-server (directory name)
  "Under DIRECTORY, create a PATH server named NAME."
  (eglotx-presets-test--make-executable directory name))

(defun eglotx-presets-test--project (root)
  "Return a transient project rooted at ROOT."
  (cons 'transient (file-name-as-directory root)))

(defun eglotx-presets-test--backend-specs (contact)
  "Return backend specifications from Eglotx CONTACT."
  (plist-get (cdr contact) :backend-specs))

(defun eglotx-presets-test--backend (contact name)
  "Return backend NAME from Eglotx CONTACT."
  (seq-find (lambda (backend) (equal (plist-get backend :name) name))
            (eglotx-presets-test--backend-specs contact)))

(defun eglotx-presets-test--project-fixture (name)
  "Return the absolute root of project fixture NAME."
  (file-name-as-directory
   (expand-file-name (concat "projects/" name)
                     eglotx-presets-test--directory)))

(defconst eglotx-presets-test--package-json
  "{\"devDependencies\":{\"typescript\":\"1\",\"eslint\":\"1\",\"tailwindcss\":\"1\",\"@biomejs/biome\":\"1\"}}"
  "Manifest activating every bundled TypeScript backend.")

(ert-deftest eglotx-presets-typescript-prefers-nearest-project-servers ()
  (eglotx-presets-test--with-directory (root)
    (let* ((package (expand-file-name "packages/app/" root))
           (source (expand-file-name "src/" package))
           (names '("typescript-language-server"
                    "vscode-eslint-language-server"
                    "biome"
                    "tailwindcss-language-server")))
      (make-directory source t)
      (eglotx-presets-test--write-file
       package "package.json" eglotx-presets-test--package-json)
      (dolist (name names)
        (eglotx-presets-test--local-server root name)
        (eglotx-presets-test--local-server package name))
      (let* ((default-directory source)
             (exec-path nil)
             (contact
              (cl-letf (((symbol-function 'directory-files)
                         (lambda (&rest _args)
                           (ert-fail
                            "Manifest fast path enumerated a directory"))))
                (eglotx-presets-typescript-contact
                 nil (eglotx-presets-test--project root)))))
        (should (eq (car contact) 'eglotx-server))
        (should (= (length (eglotx-presets-test--backend-specs contact)) 4))
        (dolist (entry '(("typescript" . "typescript-language-server")
                         ("eslint" . "vscode-eslint-language-server")
                         ("biome" . "biome")
                         ("tailwindcss" . "tailwindcss-language-server")))
          (let* ((backend
                  (eglotx-presets-test--backend contact (car entry)))
                 (actual (car (plist-get backend :command)))
                 (expected
                  (expand-file-name
                   (concat "node_modules/.bin/" (cdr entry)) package)))
            (should (equal actual expected))))))))

(ert-deftest eglotx-presets-react-fixtures-isolate-optional-backends ()
  (eglotx-presets-test--with-directory (global-bin)
    (dolist (name '("typescript-language-server"
                    "vscode-eslint-language-server"
                    "biome"
                    "tailwindcss-language-server"
                    "ngserver"))
      (eglotx-presets-test--global-server global-bin name))
    (dolist (case '(("react_ts_tailwind_eslint"
                     . ("typescript" "eslint" "tailwindcss"))
                    ("react_ts_tailwind_biome"
                     . ("typescript" "biome" "tailwindcss"))))
      (let* ((root (eglotx-presets-test--project-fixture (car case)))
             (default-directory (expand-file-name "src/" root))
             (exec-path (list global-bin))
             (contact
              (eglotx-presets-javascript-typescript-react-contact
               nil (eglotx-presets-test--project root))))
        (should
         (equal (mapcar (lambda (backend) (plist-get backend :name))
                        (eglotx-presets-test--backend-specs contact))
                (cdr case)))))))

(ert-deftest eglotx-presets-angular-fixture-selects-framework-stack ()
  (eglotx-presets-test--with-directory (global-bin)
    (let ((typescript
           (eglotx-presets-test--global-server
            global-bin "typescript-language-server"))
          (ngserver
           (eglotx-presets-test--global-server global-bin "ngserver"))
          (root (eglotx-presets-test--project-fixture "angular_ts")))
      (let* ((default-directory (expand-file-name "src/app/" root))
             (exec-path (list global-bin))
             (eglotx-presets-prefer-project-local-servers nil)
             (contact
              (eglotx-presets-javascript-typescript-react-contact
               nil (eglotx-presets-test--project root)))
             (backends (eglotx-presets-test--backend-specs contact))
             (typescript-backend
              (eglotx-presets-test--backend contact "typescript"))
             (angular (eglotx-presets-test--backend contact "angular")))
        (should
         (equal (mapcar (lambda (backend) (plist-get backend :name)) backends)
                '("typescript" "angular")))
        (should (equal (plist-get typescript-backend :command)
                       (list typescript "--stdio")))
        (should (= (plist-get typescript-backend :priority) 100))
        (should (plist-get typescript-backend :required))
        (should-not (plist-get typescript-backend :languages))
        (should
         (equal (plist-get angular :command)
                (list ngserver "--stdio"
                      "--tsProbeLocations" root
                      "--ngProbeLocations" root)))
        (should (= (plist-get angular :priority) 120))
        (should (plist-member angular :required))
        (should-not (plist-get angular :required))
        (should (equal (plist-get angular :languages) '("typescript")))
        (should (equal (plist-get angular :only)
                       eglotx-presets--angular-only))))))

(ert-deftest eglotx-presets-typescript-contact-omits-angular-for-fixture ()
  (eglotx-presets-test--with-directory (global-bin)
    (let ((typescript
           (eglotx-presets-test--global-server
            global-bin "typescript-language-server"))
          (root (eglotx-presets-test--project-fixture "angular_ts")))
      (eglotx-presets-test--global-server global-bin "ngserver")
      (let ((default-directory (expand-file-name "src/app/" root))
            (exec-path (list global-bin))
            (eglotx-presets-prefer-project-local-servers nil))
        (should
         (equal (eglotx-presets-typescript-contact
                 nil (eglotx-presets-test--project root))
                (list typescript "--stdio")))))))

(ert-deftest eglotx-presets-vue-builds-current-hybrid-stack-local-first ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let* ((package (expand-file-name "packages/app/" root))
             (source (expand-file-name "src/" package))
             (vue-install (eglotx-presets-test--vue-language-server package))
             (vue (car vue-install))
             (vue-package (cdr vue-install))
             (typescript
              (eglotx-presets-test--local-server
               package "typescript-language-server"))
             (eslint
              (eglotx-presets-test--local-server
               package "vscode-eslint-language-server"))
             (tailwind
              (eglotx-presets-test--local-server
               package "tailwindcss-language-server"))
             (tsdk
              (file-name-as-directory
               (expand-file-name "node_modules/typescript/lib" package))))
        (make-directory source t)
        (eglotx-presets-test--write-file
         package "node_modules/typescript/lib/typescript.js" "")
        (dolist (name '("vue-language-server"
                        "typescript-language-server"
                        "vscode-eslint-language-server"
                        "tailwindcss-language-server"))
          (eglotx-presets-test--global-server global-bin name))
        (eglotx-presets-test--write-file
         package "package.json"
         "{\"dependencies\":{\"vue\":\"3\",\"tailwindcss\":\"4\"},\"devDependencies\":{\"typescript\":\"6\",\"eslint\":\"10\"}}")
        (let* ((default-directory source)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-vue-contact
                 nil (eglotx-presets-test--project root)))
               (backends (eglotx-presets-test--backend-specs contact))
               (vue-backend
                (eglotx-presets-test--backend contact "vue"))
               (typescript-backend
                (eglotx-presets-test--backend contact "typescript"))
               (options
                (plist-get typescript-backend :initialization-options))
               (plugin (aref (plist-get options :plugins) 0)))
          (should (eq (car contact) 'eglotx-server))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          backends)
                  '("vue" "typescript" "eslint" "tailwindcss")))
          (should (equal (plist-get vue-backend :command)
                         (list vue "--stdio" (concat "--tsdk=" tsdk))))
          (should (equal (plist-get typescript-backend :command)
                         (list typescript "--stdio")))
          (should (equal (plist-get
                          (eglotx-presets-test--backend contact "eslint")
                          :command)
                         (list eslint "--stdio")))
          (should (equal (plist-get
                          (eglotx-presets-test--backend contact "tailwindcss")
                          :command)
                         (list tailwind "--stdio")))
          (should (equal (plist-get vue-backend :languages) '("vue")))
          (should (equal (plist-get typescript-backend :languages) '("vue")))
          (should
           (equal (plist-get vue-backend :notification-handlers)
                  '(("tsserver/request"
                     . eglotx-presets-vue--tsserver-request))))
          (should (equal (plist-get plugin :name) "@vue/typescript-plugin"))
          (should (equal (plist-get plugin :location) vue-package))
          (should (equal (plist-get plugin :languages) ["vue"]))
          (should (equal (plist-get options :tsserver)
                         (list :path tsdk))))))))

(ert-deftest eglotx-presets-vue-gates-biome-on-supported-local-version ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--vue-language-server root)
    (eglotx-presets-test--local-server root "typescript-language-server")
    (eglotx-presets-test--local-server root "biome")
    (eglotx-presets-test--write-file
     root "package.json"
     "{\"dependencies\":{\"vue\":\"3\"},\"devDependencies\":{\"typescript\":\"6\",\"@biomejs/biome\":\"2\"}}")
    (let ((default-directory root)
          (exec-path nil))
      (dolist (case '(("2.2.4" . ("vue" "typescript"))
                      ("2.3.0" . ("vue" "typescript" "biome"))))
        (eglotx-presets-test--write-file
         root "node_modules/@biomejs/biome/package.json"
         (format "{\"name\":\"@biomejs/biome\",\"version\":\"%s\"}"
                 (car case)))
        (let ((contact
               (eglotx-presets-vue-contact
                nil (eglotx-presets-test--project root))))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          (eglotx-presets-test--backend-specs contact))
                  (cdr case)))
          (when-let* ((backend
                       (eglotx-presets-test--backend contact "biome")))
            (should-not
             (memq :textDocument/formatting (plist-get backend :only))))))
      (eglotx-presets-test--write-file
       root "biome.jsonc"
       (concat "{\n  // Biome's supported JSONC form\n"
               "  /* Comment-looking string content must survive. */\n"
               "  \"note\": \"https://example.invalid/*literal*/\",\n"
               "  \"html\": {\n"
               "    \"experimentalFullSupportEnabled\": true,\n"
               "  },\n}\n"))
      (let* ((contact
              (eglotx-presets-vue-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "biome")))
        (should (memq :textDocument/formatting (plist-get backend :only)))))))

(ert-deftest eglotx-presets-vue-fixtures-isolate-optional-backends ()
  (eglotx-presets-test--with-directory (tools)
    (eglotx-presets-test--vue-language-server tools)
    (dolist (name '("typescript-language-server"
                    "vscode-eslint-language-server"
                    "tailwindcss-language-server"))
      (eglotx-presets-test--local-server tools name))
    (eglotx-presets-test--biome-server tools "2.5.0")
    (let ((exec-path (list (expand-file-name "node_modules/.bin" tools))))
      (dolist (case '(($vue-eslint
                      "vue_ts_tailwind_eslint"
                      ("vue" "typescript" "eslint" "tailwindcss"))
                     ($vue-biome
                      "vue_ts_tailwind_biome"
                      ("vue" "typescript" "biome" "tailwindcss"))))
        (let* ((root (eglotx-presets-test--project-fixture (nth 1 case)))
               (default-directory (expand-file-name "src/" root))
               (contact
                (eglotx-presets-vue-contact
                 nil (eglotx-presets-test--project root))))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          (eglotx-presets-test--backend-specs contact))
                  (nth 2 case))))))))

(ert-deftest eglotx-presets-vue-entry-is-specific-and-precedes-web-entries ()
  (should
   (< (cl-position eglotx-presets--vue-entry eglotx-presets--entries :test #'eq)
      (cl-position eglotx-presets--javascript-typescript-react-entry
                   eglotx-presets--entries :test #'eq)))
  (should
   (< (cl-position eglotx-presets--vue-entry eglotx-presets--entries :test #'eq)
      (cl-position eglotx-presets--html-entry
                   eglotx-presets--entries :test #'eq)))
  (should (eq (cdr eglotx-presets--vue-entry)
              'eglotx-presets-vue-contact))
  (let ((modes (car eglotx-presets--vue-entry)))
    (dolist (mode '(vue-ts-mode vue-mode vue-html-mode))
      (should (equal (assq mode modes) (list mode :language-id "vue"))))
    (should-not (assq 'web-mode modes))))

(ert-deftest eglotx-presets-vue-version-gates-vls-tsdk-argument ()
  (eglotx-presets-test--with-directory (root)
    (let* ((install (eglotx-presets-test--vue-language-server root))
           (package (cdr install))
           (tsdk (file-name-as-directory
                  (expand-file-name "node_modules/typescript/lib" root))))
      (eglotx-presets-test--local-server root "typescript-language-server")
      (eglotx-presets-test--write-file
       root "node_modules/typescript/lib/typescript.js" "")
      (let ((default-directory root)
            (exec-path nil))
        (dolist (case '(("3.0.8" . nil)
                        ("3.0.9-beta.1" . nil)
                        ("3.0.9+fixture" . t)
                        ("3.0.9" . t)))
          (eglotx-presets-test--write-file
           package "package.json"
           (format
            "{\"name\":\"@vue/language-server\",\"version\":\"%s\"}"
            (car case)))
          (let* ((contact
                  (eglotx-presets-vue-contact
                   nil (eglotx-presets-test--project root)))
                 (command
                  (plist-get
                   (eglotx-presets-test--backend contact "vue") :command)))
            (should
             (eq (and (member (concat "--tsdk=" tsdk) command) t)
                 (cdr case)))))))))

(ert-deftest eglotx-presets-vue-preserves-fallback-when-plugin-is-missing ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--vue-language-server root)
    (delete-directory
     (expand-file-name "node_modules/@vue/typescript-plugin" root) t)
    (eglotx-presets-test--local-server root "typescript-language-server")
    (let* ((fallback '("user-vue-language-server" "--stdio"))
           (eglotx-presets--fallback-resolver
            (lambda (_interactive _project) fallback))
           (default-directory root)
           (exec-path nil))
      (should
       (equal (eglotx-presets-vue-contact
               nil (eglotx-presets-test--project root))
              fallback)))))

(ert-deftest eglotx-presets-vue-resolves-plugin-through-pnpm-symlink ()
  (eglotx-presets-test--with-directory (root)
    (let* ((store
            (expand-file-name
             "node_modules/.pnpm/vue-tools/node_modules/" root))
           (real-vue-package
            (file-name-as-directory
             (expand-file-name "@vue/language-server" store)))
           (plugin-package
            (file-name-as-directory
             (expand-file-name "@vue/typescript-plugin" store)))
           (selected-vue-package
            (file-name-as-directory
             (expand-file-name "node_modules/@vue/language-server" root))))
      (eglotx-presets-test--write-file
       real-vue-package "package.json"
       "{\"name\":\"@vue/language-server\",\"version\":\"3.3.7\"}")
      (eglotx-presets-test--write-file
       plugin-package "package.json"
       "{\"name\":\"@vue/typescript-plugin\",\"version\":\"3.3.7\"}")
      (make-directory
       (file-name-directory (directory-file-name selected-vue-package)) t)
      (make-symbolic-link real-vue-package
                          (directory-file-name selected-vue-package) t)
      (let ((context
             (eglotx-presets--make-context
              (eglotx-presets-test--project root))))
        (should
         (file-equal-p
          (eglotx-presets--node-resolvable-package-directory
           context selected-vue-package
           "@vue/typescript-plugin" "@vue/typescript-plugin")
          plugin-package))))))

(ert-deftest eglotx-presets-vue-adds-graphql-only-for-structural-config ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--vue-language-server root)
    (eglotx-presets-test--local-server root "typescript-language-server")
    (let ((graphql (eglotx-presets-test--local-server root "graphql-lsp"))
          (default-directory root)
          (exec-path nil))
      (eglotx-presets-test--write-file
       root "package.json"
       "{\"dependencies\":{\"vue\":\"3\",\"graphql\":\"16\"}}")
      (let ((contact
             (eglotx-presets-vue-contact
              nil (eglotx-presets-test--project root))))
        (should-not (eglotx-presets-test--backend contact "graphql")))
      (eglotx-presets-test--write-file
       root "my-graphql.config.preview.mjs" "export default {};\n")
      (let* ((contact
              (eglotx-presets-vue-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "graphql")))
        (should (equal (plist-get backend :command)
                       (list graphql "server" "-m" "stream"
                             "--configDir" root)))
        (should (equal (plist-get backend :languages) '("vue")))
        (should (memq :textDocument/completion (plist-get backend :only)))
        (should-not
         (memq :textDocument/formatting (plist-get backend :only)))))))

(ert-deftest eglotx-presets-astro-builds-local-complementary-stack ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let* ((package (expand-file-name "packages/app/" root))
             (source (expand-file-name "src/pages/" package))
             (astro (eglotx-presets-test--local-server package "astro-ls"))
             (eslint
              (eglotx-presets-test--local-server
               package "vscode-eslint-language-server"))
             (tailwind
              (eglotx-presets-test--local-server
               package "tailwindcss-language-server"))
             (graphql
              (eglotx-presets-test--local-server package "graphql-lsp"))
             (tsdk
              (file-name-as-directory
               (expand-file-name "node_modules/typescript/lib" package))))
        (make-directory source t)
        (eglotx-presets-test--write-file
         package "node_modules/typescript/lib/typescript.js" "")
        (eglotx-presets-test--write-file
         package "package.json"
         (concat "{\"dependencies\":{\"astro\":\"5\","
                 "\"tailwindcss\":\"4\"},"
                 "\"devDependencies\":{\"eslint\":\"10\","
                 "\"typescript\":\"6\"}}"))
        (eglotx-presets-test--write-file
         package "my-graphql.config.preview.mjs" "export default {};\n")
        ;; Astro Language Server owns the embedded markup, styles, and
        ;; TypeScript regions.  None of these structural servers may receive
        ;; a complete .astro document.
        (dolist (name '("astro-ls"
                        "vscode-eslint-language-server"
                        "tailwindcss-language-server"
                        "graphql-lsp"
                        "typescript-language-server"
                        "vscode-html-language-server"
                        "vscode-css-language-server"
                        "vue-language-server"
                        "svelteserver"))
          (eglotx-presets-test--global-server global-bin name))
        (let* ((default-directory source)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-astro-contact
                 nil (eglotx-presets-test--project root)))
               (backends (eglotx-presets-test--backend-specs contact)))
          (should (eq (car contact) 'eglotx-server))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          backends)
                  '("astro" "eslint" "tailwindcss" "graphql")))
          (dolist (backend backends)
            (should (equal (plist-get backend :languages) '("astro"))))
          (let ((primary (eglotx-presets-test--backend contact "astro")))
            (should (equal (plist-get primary :command)
                           (list astro "--stdio")))
            (should
             (equal (plist-get primary :initialization-options)
                    (list :typescript (list :tsdk tsdk)))))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "eslint") :command)
                  (list eslint "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "tailwindcss")
                   :command)
                  (list tailwind "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "graphql") :command)
                  (list graphql "server" "-m" "stream" "--configDir"
                        package))))))))

(ert-deftest eglotx-presets-astro-single-server-keeps-initialized-fast-path ()
  (eglotx-presets-test--with-directory (root)
    (let ((astro (eglotx-presets-test--local-server root "astro-ls"))
          (tsdk
           (file-name-as-directory
            (expand-file-name "node_modules/typescript/lib" root)))
          (default-directory root)
          (exec-path nil))
      (eglotx-presets-test--write-file
       root "node_modules/typescript/lib/tsserverlibrary.js" "")
      (should
       (equal
        (eglotx-presets-astro-contact
         nil (eglotx-presets-test--project root))
        (list astro "--stdio"
              :initializationOptions
              (list :typescript (list :tsdk tsdk))))))))

(ert-deftest eglotx-presets-astro-gates-biome-embedded-language-support ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--local-server root "astro-ls")
    (eglotx-presets-test--write-file
     root "node_modules/typescript/lib/typescript.js" "")
    (eglotx-presets-test--biome-server root "2.2.4")
    (eglotx-presets-test--write-file
     root "package.json"
     "{\"dependencies\":{\"astro\":\"5\"},\"devDependencies\":{\"@biomejs/biome\":\"2\",\"typescript\":\"6\"}}")
    (let ((default-directory root)
          (exec-path nil))
      (let ((contact
             (eglotx-presets-astro-contact
              nil (eglotx-presets-test--project root))))
        (should-not (eglotx-presets-test--backend contact "biome")))
      (eglotx-presets-test--write-file
       root "node_modules/@biomejs/biome/package.json"
       "{\"name\":\"@biomejs/biome\",\"version\":\"2.3.0\"}")
      (let* ((contact
              (eglotx-presets-astro-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "biome")))
        (should (equal (plist-get backend :languages) '("astro")))
        (should (= (plist-get backend :priority) 70))
        (should-not
         (memq :textDocument/formatting (plist-get backend :only))))
      (eglotx-presets-test--write-file
       root "biome.json"
       "{\"html\":{\"experimentalFullSupportEnabled\":true}}\n")
      (let* ((contact
              (eglotx-presets-astro-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "biome")))
        (should (= (plist-get backend :priority) 120))
        (should
         (memq :textDocument/formatting (plist-get backend :only)))))))

(ert-deftest eglotx-presets-astro-fixtures-isolate-optional-backends ()
  (eglotx-presets-test--with-directory (tools)
    (dolist (name '("astro-ls"
                    "vscode-eslint-language-server"
                    "tailwindcss-language-server"))
      (eglotx-presets-test--local-server tools name))
    (eglotx-presets-test--biome-server tools "2.5.4")
    (let ((exec-path (list (expand-file-name "node_modules/.bin" tools))))
      (dolist (case '(("astro_ts_tailwind_eslint"
                       ("astro" "eslint" "tailwindcss")
                       "eslint.config.js")
                      ("astro_ts_tailwind_biome"
                       ("astro" "biome" "tailwindcss")
                       "biome.json")))
        (eglotx-presets-test--with-directory (root)
          (let ((fixture (eglotx-presets-test--project-fixture (car case))))
            (dolist (name (list "package.json" (nth 2 case)))
              (copy-file (expand-file-name name fixture)
                         (expand-file-name name root))))
          (eglotx-presets-test--write-file
           root "node_modules/typescript/lib/typescript.js" "")
          (make-directory (expand-file-name "src/pages/" root) t)
          (let* ((default-directory (expand-file-name "src/pages/" root))
                 (contact
                  (eglotx-presets-astro-contact
                   nil (eglotx-presets-test--project root))))
            (should
             (equal (mapcar (lambda (backend) (plist-get backend :name))
                            (eglotx-presets-test--backend-specs contact))
                    (nth 1 case)))))))))

(ert-deftest eglotx-presets-astro-entry-is-specific ()
  (should (eq (cdr eglotx-presets--astro-entry)
              'eglotx-presets-astro-contact))
  (should (< (cl-position eglotx-presets--astro-entry
                          eglotx-presets--entries)
             (cl-position eglotx-presets--html-entry
                          eglotx-presets--entries)))
  (let ((modes (car eglotx-presets--astro-entry)))
    (dolist (mode '(astro-ts-mode astro-mode))
      (should
       (equal (assq mode modes) (list mode :language-id "astro"))))
    (should-not (assq 'web-mode modes))))

(ert-deftest eglotx-presets-astro-preserves-fallback-without-typescript-sdk ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--local-server root "astro-ls")
    (let* ((fallback '("user-astro-language-server" "--stdio"))
           (eglotx-presets--fallback-resolver
            (lambda (_interactive _project) fallback))
           (default-directory root)
           (exec-path nil))
      (should
       (equal (eglotx-presets-astro-contact
               nil (eglotx-presets-test--project root))
              fallback)))))

(ert-deftest eglotx-presets-astro-preserves-fallback-without-server ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--write-file
     root "node_modules/typescript/lib/typescript.js" "")
    (let* ((fallback '("user-astro-language-server" "--stdio"))
           (eglotx-presets--fallback-resolver
            (lambda (_interactive _project) fallback))
           (default-directory root)
           (exec-path nil))
      (should
       (equal (eglotx-presets-astro-contact
               nil (eglotx-presets-test--project root))
              fallback)))))

(ert-deftest eglotx-presets-svelte-builds-local-complementary-stack ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let* ((package (expand-file-name "packages/app/" root))
             (source (expand-file-name "src/" package))
             (svelte
              (eglotx-presets-test--local-server package "svelteserver"))
             (eslint
              (eglotx-presets-test--local-server
               package "vscode-eslint-language-server"))
             (tailwind
              (eglotx-presets-test--local-server
               package "tailwindcss-language-server"))
             (graphql
              (eglotx-presets-test--local-server package "graphql-lsp")))
        (make-directory source t)
        (eglotx-presets-test--write-file
         package "package.json"
         (concat "{\"dependencies\":{\"svelte\":\"5\","
                 "\"tailwindcss\":\"4\"},"
                 "\"devDependencies\":{\"eslint\":\"10\"}}"))
        (eglotx-presets-test--write-file
         package "my-graphql.config.preview.mjs" "export default {};\n")
        ;; These structural servers must not join a Svelte document: the
        ;; official Svelte server already embeds TypeScript, HTML, and CSS.
        (dolist (name '("svelteserver"
                        "vscode-eslint-language-server"
                        "tailwindcss-language-server"
                        "graphql-lsp"
                        "typescript-language-server"
                        "vscode-html-language-server"
                        "vscode-css-language-server"))
          (eglotx-presets-test--global-server global-bin name))
        (let* ((default-directory source)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-svelte-contact
                 nil (eglotx-presets-test--project root)))
               (backends (eglotx-presets-test--backend-specs contact)))
          (should (eq (car contact) 'eglotx-server))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          backends)
                  '("svelte" "eslint" "tailwindcss" "graphql")))
          (dolist (backend backends)
            (should (equal (plist-get backend :languages) '("svelte"))))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "svelte") :command)
                  (list svelte "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "eslint") :command)
                  (list eslint "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "tailwindcss")
                   :command)
                  (list tailwind "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "graphql") :command)
                  (list graphql "server" "-m" "stream" "--configDir"
                        package)))
          (should
           (equal (plist-get
                   (plist-get
                    (eglotx-presets-test--backend contact "eslint")
                    :settings)
                   :validate)
                  "on"))
          (let ((eslint-only
                 (plist-get
                  (eglotx-presets-test--backend contact "eslint") :only))
                (tailwind-only
                 (plist-get
                  (eglotx-presets-test--backend contact "tailwindcss")
                  :only)))
            (should (memq :textDocument/diagnostic eslint-only))
            (should (memq :textDocument/codeAction eslint-only))
            (should-not (memq :textDocument/completion eslint-only))
            (should-not (memq :textDocument/formatting eslint-only))
            (should (memq :textDocument/completion tailwind-only))
            (should (memq :completionItem/resolve tailwind-only))
            (should (memq :codeAction/resolve tailwind-only))
            (should (memq :workspace/didChangeWorkspaceFolders tailwind-only))
            (should-not (memq :textDocument/formatting tailwind-only))
            (should-not (memq :textDocument/rename tailwind-only))))))))

(ert-deftest eglotx-presets-svelte-single-server-keeps-eglot-fast-path ()
  (eglotx-presets-test--with-directory (root)
    (let ((svelte (eglotx-presets-test--local-server root "svelteserver"))
          (default-directory root)
          (exec-path nil))
      (should
       (equal (eglotx-presets-svelte-contact
               nil (eglotx-presets-test--project root))
              (list svelte "--stdio"))))))

(ert-deftest eglotx-presets-svelte-gates-biome-embedded-language-support ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--local-server root "svelteserver")
    (eglotx-presets-test--biome-server root "2.2.4")
    (eglotx-presets-test--write-file
     root "package.json"
     "{\"dependencies\":{\"svelte\":\"5\"},\"devDependencies\":{\"@biomejs/biome\":\"2\"}}")
    (let ((default-directory root)
          (exec-path nil))
      (let ((contact
             (eglotx-presets-svelte-contact
              nil (eglotx-presets-test--project root))))
        (should-not (eglotx-presets-test--backend contact "biome")))
      (eglotx-presets-test--write-file
       root "node_modules/@biomejs/biome/package.json"
       "{\"name\":\"@biomejs/biome\",\"version\":\"2.3.0\"}")
      (let* ((contact
              (eglotx-presets-svelte-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "biome")))
        (should (equal (plist-get backend :languages) '("svelte")))
        (should (= (plist-get backend :priority) 70))
        (should-not
         (memq :textDocument/formatting (plist-get backend :only))))
      (eglotx-presets-test--write-file
       root "biome.jsonc"
       (concat "{\n  // Opt in to Biome's whole-document Svelte support.\n"
               "  \"html\": {\n"
               "    \"experimentalFullSupportEnabled\": true,\n"
               "  },\n}\n"))
      (let* ((contact
              (eglotx-presets-svelte-contact
               nil (eglotx-presets-test--project root)))
             (backend (eglotx-presets-test--backend contact "biome")))
        (should (= (plist-get backend :priority) 120))
        (should
         (memq :textDocument/formatting (plist-get backend :only)))))))

(ert-deftest eglotx-presets-svelte-fixtures-isolate-optional-backends ()
  (eglotx-presets-test--with-directory (tools)
    (dolist (name '("svelteserver"
                    "vscode-eslint-language-server"
                    "tailwindcss-language-server"))
      (eglotx-presets-test--local-server tools name))
    (eglotx-presets-test--biome-server tools "2.5.4")
    (let ((exec-path (list (expand-file-name "node_modules/.bin" tools))))
      (dolist (case '(("svelte_ts_tailwind_eslint"
                       ("svelte" "eslint" "tailwindcss"))
                      ("svelte_ts_tailwind_biome"
                       ("svelte" "biome" "tailwindcss"))))
        (let* ((root (eglotx-presets-test--project-fixture (car case)))
               (default-directory (expand-file-name "src/" root))
               (contact
                (eglotx-presets-svelte-contact
                 nil (eglotx-presets-test--project root))))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          (eglotx-presets-test--backend-specs contact))
                  (cadr case))))))))

(ert-deftest eglotx-presets-svelte-global-addons-require-project-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((svelte (eglotx-presets-test--local-server root "svelteserver")))
        (dolist (name '("vscode-eslint-language-server"
                        "tailwindcss-language-server"))
          (eglotx-presets-test--global-server global-bin name))
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal (eglotx-presets-svelte-contact
                   nil (eglotx-presets-test--project root))
                  (list svelte "--stdio")))
          ;; vscode-langservers-extracted exposes an ESLint binary alongside
          ;; unrelated HTML/CSS tools.  Local availability is not ESLint
          ;; intent for an embedded document.
          (eglotx-presets-test--local-server
           root "vscode-eslint-language-server")
          (eglotx-presets-test--local-server
           root "tailwindcss-language-server")
          (let ((contact
                 (eglotx-presets-svelte-contact
                  nil (eglotx-presets-test--project root))))
            (should
             (equal (mapcar
                     (lambda (backend) (plist-get backend :name))
                     (eglotx-presets-test--backend-specs contact))
                    '("svelte" "tailwindcss"))))
          (eglotx-presets-test--write-file root ".eslintignore" "dist\n")
          (let ((contact
                 (eglotx-presets-svelte-contact
                  nil (eglotx-presets-test--project root))))
            (should
             (equal (mapcar
                     (lambda (backend) (plist-get backend :name))
                     (eglotx-presets-test--backend-specs contact))
                    '("svelte" "tailwindcss"))))
          (eglotx-presets-test--write-file root "eslint.config.js" "")
          (let ((contact
                 (eglotx-presets-svelte-contact
                  nil (eglotx-presets-test--project root))))
            (should
             (equal (mapcar
                     (lambda (backend) (plist-get backend :name))
                     (eglotx-presets-test--backend-specs contact))
                    '("svelte" "eslint" "tailwindcss")))))))))

(ert-deftest eglotx-presets-svelte-entry-is-specific-and-first ()
  (should (eq (car eglotx-presets--entries) eglotx-presets--svelte-entry))
  (should (eq (cdr eglotx-presets--svelte-entry)
              'eglotx-presets-svelte-contact))
  (let ((modes (car eglotx-presets--svelte-entry)))
    (dolist (mode '(svelte-ts-mode svelte-mode))
      (should
       (equal (assq mode modes) (list mode :language-id "svelte"))))
    (should-not (assq 'web-mode modes))))

(ert-deftest eglotx-presets-svelte-preserves-fallback-when-primary-is-missing ()
  (eglotx-presets-test--with-directory (root)
    (let* ((fallback '("user-svelte-language-server" "--stdio"))
           (eglotx-presets--fallback-resolver
            (lambda (_interactive _project) fallback))
           (default-directory root)
           (exec-path nil))
      (should
       (equal (eglotx-presets-svelte-contact
               nil (eglotx-presets-test--project root))
              fallback)))))

(ert-deftest eglotx-presets-community-fixtures-select-safe-cohorts ()
  (eglotx-presets-test--with-directory (global-bin)
    (dolist (name '("pyright-langserver" "ruff" "gopls"
                    "golangci-lint-langserver" "golangci-lint"
                    "ruby-lsp" "srb"))
      (eglotx-presets-test--global-server global-bin name))
    (let ((exec-path (list global-bin)))
      (dolist
          (case
           `(("python_ruff" "src/" ,#'eglotx-presets-python-contact
              ("pyright" "ruff"))
             ("go_golangci" "" ,#'eglotx-presets-go-contact
              ("gopls" "golangci-lint"))
             ("ruby_sorbet" "lib/" ,#'eglotx-presets-ruby-contact
              ("ruby-lsp" "sorbet"))))
        (let* ((root (eglotx-presets-test--project-fixture (nth 0 case)))
               (default-directory (expand-file-name (nth 1 case) root))
               (contact
                (funcall (nth 2 case) nil
                         (eglotx-presets-test--project root))))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          (eglotx-presets-test--backend-specs contact))
                  (nth 3 case))))))))

(ert-deftest eglotx-presets-typescript-falls-back-to-project-root-then-path ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let* ((source (expand-file-name "packages/app/src/" root))
             (typescript
              (eglotx-presets-test--local-server
               root "typescript-language-server"))
             (eslint
              (eglotx-presets-test--global-server
               global-bin "vscode-eslint-language-server"))
             (biome
              (eglotx-presets-test--global-server global-bin "biome"))
             (tailwind
              (eglotx-presets-test--global-server
               global-bin "tailwindcss-language-server")))
        (make-directory source t)
        (eglotx-presets-test--write-file
         root "package.json" eglotx-presets-test--package-json)
        (let* ((default-directory source)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-typescript-contact
                 nil (eglotx-presets-test--project root))))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "typescript")
                   :command)
                  (list typescript "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "eslint") :command)
                  (list eslint "--stdio")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "biome") :command)
                  (list biome "lsp-proxy")))
          (should
           (equal (plist-get
                   (eglotx-presets-test--backend contact "tailwindcss")
                   :command)
                  (list tailwind "--stdio"))))))))

(ert-deftest eglotx-presets-typescript-detects-configs-with-broken-manifest ()
  (eglotx-presets-test--with-directory (root)
    (dolist (name '("typescript-language-server"
                    "vscode-eslint-language-server"
                    "biome"
                    "tailwindcss-language-server"))
      (eglotx-presets-test--local-server root name))
    (eglotx-presets-test--write-file root "package.json" "{")
    (eglotx-presets-test--write-file root "eslint.config.mjs" "")
    (eglotx-presets-test--write-file root ".biome.jsonc" "{}")
    (eglotx-presets-test--write-file root "tailwind.config.ts" "")
    (let ((default-directory root)
          (exec-path nil))
      (should
       (= (length
           (eglotx-presets-test--backend-specs
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))))
          4)))))

(ert-deftest eglotx-presets-typescript-detects-keyword-config-variants ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (dolist (name '("typescript-language-server"
                      "vscode-eslint-language-server"
                      "biome"
                      "tailwindcss-language-server"))
        (eglotx-presets-test--global-server global-bin name))
      (eglotx-presets-test--write-file
       root "package.json" "{\"devDependencies\":{\"typescript\":\"1\"}}")
      (eglotx-presets-test--write-file
       root "my-eslint.config.experimental.mjs" "")
      (eglotx-presets-test--write-file root "biome.json" "{}")
      (eglotx-presets-test--write-file
       root "config.tailwindcss.preview.mts" "")
      (let ((default-directory root)
            (exec-path (list global-bin)))
        (should
         (= (length
             (eglotx-presets-test--backend-specs
              (eglotx-presets-typescript-contact
               nil (eglotx-presets-test--project root))))
            4))))))

(ert-deftest eglotx-presets-typescript-ignores-keyword-artifacts ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server
         global-bin "vscode-eslint-language-server")
        (eglotx-presets-test--global-server
         global-bin "tailwindcss-language-server")
        (eglotx-presets-test--global-server global-bin "biome")
        (eglotx-presets-test--write-file
         root "package.json" "{\"devDependencies\":{\"typescript\":\"1\"}}")
        (eglotx-presets-test--write-file root "eslint-report.json" "")
        (eglotx-presets-test--write-file root "eslint.config.js.backup" "")
        (eglotx-presets-test--write-file root "myeslint.config.js" "")
        (eglotx-presets-test--write-file root "eslintreport.config.js" "")
        (eglotx-presets-test--write-file root "eslintplugin.config.js" "")
        (eglotx-presets-test--write-file root "tailwind.css" "")
        (eglotx-presets-test--write-file root "tailwind-plugin.js" "")
        (eglotx-presets-test--write-file root "tailwindplugin.config.js" "")
        (eglotx-presets-test--write-file root "notailwind.config.js" "")
        (eglotx-presets-test--write-file root "biome-report.json" "")
        (eglotx-presets-test--write-file root "biome.config.jsonc" "")
        (eglotx-presets-test--write-file root ".biome.json.backup" "")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-eslint-rejects-null-manifest-config ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server
         global-bin "vscode-eslint-language-server")
        (dolist (value '("null" "false"))
          (eglotx-presets-test--write-file
           root "package.json" (format "{\"eslintConfig\":%s}" value))
          (let ((default-directory root)
                (exec-path (list global-bin)))
            (should
             (equal
              (eglotx-presets-typescript-contact
               nil (eglotx-presets-test--project root))
              (list typescript "--stdio")))))))))

(ert-deftest eglotx-presets-typescript-ignores-marker-shaped-directories ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server
         global-bin "vscode-eslint-language-server")
        (eglotx-presets-test--global-server
         global-bin "tailwindcss-language-server")
        (eglotx-presets-test--global-server global-bin "biome")
        (eglotx-presets-test--write-file
         root "package.json" "{\"devDependencies\":{\"typescript\":\"1\"}}")
        (make-directory (expand-file-name "eslint.config.js" root))
        (make-directory (expand-file-name "tailwind.config.js" root))
        (make-directory (expand-file-name ".biome.jsonc" root))
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-marker-discovery-skips-remote-listing ()
  (cl-letf (((symbol-function 'file-remote-p)
             (lambda (_path) "/ssh:test.example:"))
            ((symbol-function 'directory-files)
             (lambda (&rest _args)
               (ert-fail "Preset discovery listed a remote directory"))))
    (let ((intent
           (eglotx-presets--directory-marker-intent
            "/ssh:test.example:/srv/project/" t t t)))
      (should-not (eglotx-presets--intent-eslint intent))
      (should-not (eglotx-presets--intent-tailwind intent))
      (should-not (eglotx-presets--intent-biome intent)))))

(ert-deftest eglotx-presets-marker-discovery-bounds-candidate-results ()
  (let (observed-arguments)
    (cl-letf (((symbol-function 'file-remote-p) (lambda (_path) nil))
              ((symbol-function 'directory-files)
               (lambda (&rest arguments)
                 (setq observed-arguments arguments)
                 nil)))
      (eglotx-presets--directory-marker-intent "/tmp/project/" t t t))
    (should
     (= (nth 4 observed-arguments)
        eglotx-presets--marker-candidate-limit))))

(ert-deftest eglotx-presets-typescript-detects-tailwind-v4-without-config ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--global-server
       global-bin "typescript-language-server")
      (let ((tailwind
             (eglotx-presets-test--global-server
              global-bin "tailwindcss-language-server")))
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"devDependencies\":{\"typescript\":\"1\",\"tailwindcss\":\"^4.1.0\"}}")
        (eglotx-presets-test--write-file
         root "src/styles.css" "@import 'tailwindcss';\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          ;; Only Tailwind is executable, and its manifest signal satisfies
          ;; discovery.  Do not list directories looking for unrelated tools;
          ;; the server owns recursive v4 CSS/import discovery.
          (cl-letf (((symbol-function 'directory-files)
                     (lambda (&rest _arguments)
                       (ert-fail "Tailwind v4 manifest caused a listing"))))
            (let* ((contact
                    (eglotx-presets-typescript-contact
                     nil (eglotx-presets-test--project root)))
                   (backend
                    (eglotx-presets-test--backend contact "tailwindcss")))
              (should backend)
              (should (equal (plist-get backend :command)
                             (list tailwind "--stdio"))))))))))

(ert-deftest eglotx-presets-typescript-ignores-tailwind-plugin-only-manifest ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server
         global-bin "tailwindcss-language-server")
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"devDependencies\":{\"typescript\":\"1\",\"@tailwindcss/typography\":\"1\"}}")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-manifest-read-is-size-bounded ()
  (eglotx-presets-test--with-directory (root)
    (let ((manifest
           (eglotx-presets-test--write-file
            root "package.json" eglotx-presets-test--package-json))
          (eglotx-presets--manifest-size-limit 4))
      (should-not (eglotx-presets--read-manifest manifest)))))

(ert-deftest eglotx-presets-typescript-uses-plain-contact-for-one-server ()
  (eglotx-presets-test--with-directory (root)
    (let ((typescript
           (eglotx-presets-test--local-server
            root "typescript-language-server")))
      (let ((default-directory root)
            (exec-path nil))
        (should
         (equal
          (eglotx-presets-typescript-contact
           nil (eglotx-presets-test--project root))
          (list typescript "--stdio")))))))

(ert-deftest eglotx-presets-typescript-activates-biome-from-manifest ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--global-server
       global-bin "typescript-language-server")
      (let ((biome
             (eglotx-presets-test--global-server global-bin "biome")))
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"devDependencies\":{\"typescript\":\"1\",\"@biomejs/biome\":\"2\"}}")
        (let* ((default-directory root)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-typescript-contact
                 nil (eglotx-presets-test--project root)))
               (backend (eglotx-presets-test--backend contact "biome")))
          (should backend)
          (should (equal (plist-get backend :command)
                         (list biome "lsp-proxy")))
          (should (= (plist-get backend :priority) 120))
          (should-not (plist-get backend :required)))))))

(ert-deftest eglotx-presets-typescript-detects-biome-configs ()
  (dolist (config '("biome.json" "biome.jsonc"
                    ".biome.json" ".biome.jsonc"))
    (eglotx-presets-test--with-directory (root)
      (eglotx-presets-test--with-directory (global-bin)
        (eglotx-presets-test--global-server
         global-bin "typescript-language-server")
        (let ((biome
               (eglotx-presets-test--global-server global-bin "biome")))
          (eglotx-presets-test--write-file
           root "package.json"
           "{\"devDependencies\":{\"typescript\":\"1\"}}")
          (eglotx-presets-test--write-file root config "{}")
          (let* ((default-directory root)
                 (exec-path (list global-bin))
                 (contact
                  (eglotx-presets-typescript-contact
                   nil (eglotx-presets-test--project root)))
                 (backend (eglotx-presets-test--backend contact "biome")))
            (should backend)
            (should (equal (plist-get backend :command)
                           (list biome "lsp-proxy")))))))))

(ert-deftest eglotx-presets-typescript-local-biome-signals-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--local-server root "typescript-language-server")
    (let ((biome (eglotx-presets-test--local-server root "biome")))
      (eglotx-presets-test--write-file
       root "package.json" "{\"devDependencies\":{\"typescript\":\"1\"}}")
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-typescript-contact
               nil (eglotx-presets-test--project root))))
        (should
         (equal
          (plist-get (eglotx-presets-test--backend contact "biome") :command)
          (list biome "lsp-proxy")))))))

(ert-deftest eglotx-presets-typescript-omits-missing-biome ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"devDependencies\":{\"typescript\":\"1\",\"@biomejs/biome\":\"2\"}}")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-typescript-ignores-unrequested-global-tools ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server
         global-bin "vscode-eslint-language-server")
        (eglotx-presets-test--global-server
         global-bin "tailwindcss-language-server")
        (eglotx-presets-test--global-server global-bin "biome")
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"devDependencies\":{\"typescript\":\"1\"}}")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-typescript-can-disable-local-precedence ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--local-server
       root "typescript-language-server")
      (let ((global
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (let ((default-directory root)
              (exec-path (list global-bin))
              (eglotx-presets-prefer-project-local-servers nil))
          (cl-letf (((symbol-function 'eglotx-presets--local-executable)
                     (lambda (&rest _arguments)
                       (ert-fail "Local executable discovery was not disabled"))))
            (should
             (equal
              (eglotx-presets-typescript-contact
               nil (eglotx-presets-test--project root))
              (list global "--stdio")))))))))

(ert-deftest eglotx-presets-typescript-resolves-through-symlink-project-root ()
  (eglotx-presets-test--with-directory (outer)
    (let* ((root (expand-file-name "real-project/" outer))
           (link (expand-file-name "linked-project" outer))
           (package (expand-file-name "packages/app/" root))
           (source (expand-file-name "src/" package)))
      (make-directory source t)
      (make-symbolic-link root link)
      (let ((typescript
             (eglotx-presets-test--local-server
              package "typescript-language-server")))
        (let ((default-directory source)
              (exec-path nil))
          (let ((contact
                 (eglotx-presets-typescript-contact
                  nil (eglotx-presets-test--project link))))
            (should (file-equal-p (car contact) typescript))
            (should (equal (cdr contact) '("--stdio")))))))))

(ert-deftest eglotx-presets-typescript-preserves-interactive-server-choice ()
  (eglotx-presets-test--with-directory (root)
    (let ((default-directory root)
          (exec-path nil))
      (should-not
       (eglotx-presets-typescript-contact
        t (eglotx-presets-test--project root)))
      (should-error
       (eglotx-presets-typescript-contact
        nil (eglotx-presets-test--project root))
       :type 'eglotx-configuration-error))))

(ert-deftest eglotx-presets-typescript-settings-are-project-specific ()
  (eglotx-presets-test--with-directory (root)
    (dolist (name '("typescript-language-server"
                    "vscode-eslint-language-server"))
      (eglotx-presets-test--local-server root name))
    (eglotx-presets-test--write-file root "eslint.config.js" "")
    (let* ((default-directory root)
           (exec-path nil)
           (contact
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root)))
           (settings
            (plist-get
             (eglotx-presets-test--backend contact "eslint") :settings))
           (workspace (plist-get settings :workspaceFolder))
           (working-directory (plist-get settings :workingDirectory))
           (experimental (plist-get settings :experimental)))
      (should (equal (plist-get workspace :uri) (eglot-path-to-uri root)))
      (should (equal (plist-get workspace :name)
                     (file-name-nondirectory (directory-file-name root))))
      (should (equal (plist-get settings :validate) "on"))
      (should (equal (plist-get working-directory :mode) "auto"))
      (should (eq (plist-get settings :nodePath) nil))
      (should (eq (plist-get settings :format) :json-false))
      (should (hash-table-p (plist-get settings :options)))
      (should (hash-table-p experimental))
      (should (= (hash-table-count experimental) 0)))))

(ert-deftest eglotx-presets-mode-is-idempotent-and-reversible ()
  (eglotx-presets-test--with-mode-state
    (let ((original '((text-mode . ("text-server"))))
          (eglotx-presets--installed-entries nil))
      (let ((eglot-server-programs (copy-tree original)))
        (unwind-protect
            (progn
              (eglotx-presets-mode 1)
              (eglotx-presets-mode 1)
              (dolist (entry eglotx-presets--entries)
                (should (= (cl-count entry eglot-server-programs
                                     :test #'equal)
                           1)))
              (should
               (eq (cdr (car eglot-server-programs))
                   'eglotx-presets-svelte-contact)))
          (eglotx-presets-mode -1))
        (should (equal eglot-server-programs original))))))

(ert-deftest eglotx-presets-mode-preserves-equal-user-entry ()
  (eglotx-presets-test--with-mode-state
    (let* ((user-entry
            (copy-tree eglotx-presets--javascript-typescript-react-entry))
           (eglot-server-programs (list user-entry))
           (eglotx-presets--installed-entries nil))
      (unwind-protect
          (progn
            (eglotx-presets-mode 1)
            (should (= (cl-count
                        eglotx-presets--javascript-typescript-react-entry
                        eglot-server-programs :test #'equal)
                       2)))
        (eglotx-presets-mode -1))
      (should (equal eglot-server-programs (list user-entry)))
      (should (eq (car eglot-server-programs) user-entry)))))

(ert-deftest eglotx-presets-mode-falls-back-to-earlier-static-contact ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-mode-state
      (let* ((project (eglotx-presets-test--project root))
             (fallback '("custom-python-server" "--stdio"))
             (eglot-server-programs
              `((python-mode . ,fallback)))
             (eglotx-presets--installed-entries nil)
             (eglotx-presets--fallback-programs nil)
             (eglotx-presets--fallback-resolver nil)
             (default-directory root)
             (major-mode 'python-mode)
             (exec-path nil))
        (unwind-protect
            (progn
              (eglotx-presets-mode 1)
              (should
               (equal (eglotx-presets-python-contact nil project)
                      fallback)))
          (eglotx-presets-mode -1))
        (should-not eglotx-presets--fallback-programs)
        (should-not eglotx-presets--fallback-resolver)))))

(ert-deftest eglotx-presets-mode-calls-earlier-functional-contact ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-mode-state
      (let* ((project (eglotx-presets-test--project root))
             observed
             (fallback
              (lambda (interactive received-project)
                (setq observed (list interactive received-project))
                '("custom-python-server")))
             (eglot-server-programs
              `((python-mode . ,fallback)))
             (eglotx-presets--installed-entries nil)
             (eglotx-presets--fallback-programs nil)
             (eglotx-presets--fallback-resolver nil)
             (default-directory root)
             (major-mode 'python-mode)
             (exec-path nil))
        (unwind-protect
            (progn
              (eglotx-presets-mode 1)
              (should
               (equal (eglotx-presets-python-contact nil project)
                      '("custom-python-server")))
              (should (equal observed (list nil project))))
          (eglotx-presets-mode -1))))))

(ert-deftest eglotx-presets-mode-calls-one-argument-fallback-contact ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-mode-state
      (let* ((project (eglotx-presets-test--project root))
             observed
             (fallback
              (lambda (interactive)
                (setq observed interactive)
                '("custom-python-server")))
             (eglot-server-programs
              `((python-mode . ,fallback)))
             (eglotx-presets--installed-entries nil)
             (eglotx-presets--fallback-programs nil)
             (eglotx-presets--fallback-resolver nil)
             (default-directory root)
             (major-mode 'python-mode)
             (exec-path nil))
        (unwind-protect
            (progn
              (eglotx-presets-mode 1)
              (should
               (equal (eglotx-presets-python-contact t project)
                      '("custom-python-server")))
              (should observed))
          (eglotx-presets-mode -1))))))

(ert-deftest eglotx-presets-decodes-version-dependent-contact-lookups ()
  (should
   (equal
    (eglotx-presets--contact-from-lookup
     '((python-mode python-ts-mode) "python"
       ("legacy-python" "--stdio")))
    '("legacy-python" "--stdio")))
  (should
   (equal
    (eglotx-presets--contact-from-lookup
     (cons '((python-mode . "python") (python-ts-mode . "python"))
           '("modern-python" "--stdio")))
    '("modern-python" "--stdio"))))

(ert-deftest eglotx-presets-engine-bounds-ancestor-discovery ()
  (eglotx-presets-test--with-directory (root)
    (let ((start root))
      (dotimes (index (+ eglotx-presets--ancestor-limit 8))
        (setq start (expand-file-name (format "d%d/" index) start)))
      (make-directory start t)
      (let ((directories
             (eglotx-presets--discovery-directories start root)))
        (should (equal (car (last directories)) root))
        (should (<= (length directories)
                    (1+ eglotx-presets--ancestor-limit)))))))

(ert-deftest eglotx-presets-python-bounds-environment-ancestor-probes ()
  (eglotx-presets-test--with-directory (root)
    (let ((start root)
          outside-prefix)
      (dotimes (index (+ eglotx-presets-python--executable-ancestor-limit 3))
        (setq start (expand-file-name (format "d%d/" index) start)))
      (make-directory start t)
      (let* ((default-directory start)
             (project (eglotx-presets-test--project root))
             (context (eglotx-presets--make-context project))
             (directories (eglotx-presets--context-directories context)))
        (setq outside-prefix
              (nth eglotx-presets-python--executable-ancestor-limit
                   directories))
        (let ((nearest (expand-file-name ".venv/bin/" (car directories)))
              (outside (expand-file-name ".venv/bin/" outside-prefix))
              (at-root (expand-file-name ".venv/bin/" root)))
          (make-directory nearest t)
          (make-directory outside t)
          (make-directory at-root t)
          (let ((actual (eglotx-presets-python--bin-directories context)))
            (should (member nearest actual))
            (should (member at-root actual))
            (should-not (member outside actual))))))))

(ert-deftest eglotx-presets-engine-caches-bounded-metadata-reads ()
  (eglotx-presets-test--with-directory (root)
    (let* ((path
            (eglotx-presets-test--write-file root "package.json" "{}"))
           (context (eglotx-presets--context-create
                     :root root :start root :directories (list root)))
           (calls 0)
           (original (symbol-function 'insert-file-contents)))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (&rest arguments)
                   (cl-incf calls)
                   (apply original arguments))))
        (should (hash-table-p (eglotx-presets--read-json context path)))
        (should (hash-table-p (eglotx-presets--read-json context path))))
      (should (= calls 1)))))

(ert-deftest eglotx-presets-engine-enforces-aggregate-read-budget ()
  (eglotx-presets-test--with-directory (root)
    (let* ((first (eglotx-presets-test--write-file root "first.toml" "abc"))
           (second
            (eglotx-presets-test--write-file root "second.toml" "def"))
           (context (eglotx-presets--context-create
                     :root root :start root :directories (list root)))
           (eglotx-presets--discovery-byte-limit 5))
      (should (equal (eglotx-presets--read-file context first) "abc"))
      (should-not (eglotx-presets--read-file context second))
      (should (= (eglotx-presets--context-bytes-read context) 3)))))

(ert-deftest eglotx-presets-engine-budgets-decoded-text-by-bytes ()
  (eglotx-presets-test--with-directory (root)
    (let* ((path (eglotx-presets-test--write-file root "metadata" "x"))
           (context (eglotx-presets--context-create
                     :root root :start root :directories (list root)))
           (eglotx-presets--discovery-byte-limit 1))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (&rest _arguments) (insert "é") 1)))
        (should-not (eglotx-presets--read-file context path)))
      (should (= (eglotx-presets--context-bytes-read context) 1)))))

(ert-deftest eglotx-presets-engine-failed-read-consumes-reservation ()
  (eglotx-presets-test--with-directory (root)
    (let* ((path (eglotx-presets-test--write-file root "metadata" "x"))
           (context (eglotx-presets--context-create
                     :root root :start root :directories (list root)))
           (eglotx-presets--discovery-byte-limit 5))
      (cl-letf (((symbol-function 'insert-file-contents)
                 (lambda (&rest _arguments) (error "decode failed"))))
        (should-not (eglotx-presets--read-file context path)))
      (should (= (eglotx-presets--context-bytes-read context) 5)))))

(ert-deftest eglotx-presets-skips-marker-listing-without-optional-tools ()
  (eglotx-presets-test--with-directory (root)
    (let ((typescript
           (eglotx-presets-test--local-server
            root "typescript-language-server"))
          (html
           (eglotx-presets-test--local-server
            root "vscode-html-language-server"))
          (gopls (eglotx-presets-test--project-bin-server root "gopls")))
      (let ((default-directory root)
            (exec-path nil))
        (cl-letf (((symbol-function 'directory-files)
                   (lambda (&rest _arguments)
                     (ert-fail "Discovery listed without an optional tool"))))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio")))
          (should
           (equal
            (eglotx-presets-html-contact
             nil (eglotx-presets-test--project root))
            (list html "--stdio")))
          (should
           (equal
            (eglotx-presets-go-contact
             nil (eglotx-presets-test--project root))
            (list gopls))))))))

(ert-deftest eglotx-presets-python-prefers-nearest-primary-alternative ()
  (eglotx-presets-test--with-directory (root)
    (let* ((package (expand-file-name "packages/app/" root))
           (source (expand-file-name "src/" package))
           (basedpyright
            (eglotx-presets-test--python-server
             root "basedpyright-langserver"))
           (pyright
            (eglotx-presets-test--python-server
             package "pyright-langserver")))
      (make-directory source t)
      (let ((default-directory source)
            (exec-path nil))
        (should
         (equal
          (eglotx-presets-python-contact
           nil (eglotx-presets-test--project root))
          (list pyright "--stdio")))
        (should-not (equal pyright basedpyright))))))

(ert-deftest eglotx-presets-python-config-keeps-local-ahead-of-path ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((pyright
             (eglotx-presets-test--python-server
              root "pyright-langserver")))
        (eglotx-presets-test--global-server
         global-bin "basedpyright-langserver")
        (eglotx-presets-test--write-file
         root "pyrightconfig.json" "{}\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-python-contact
             nil (eglotx-presets-test--project root))
            (list pyright "--stdio"))))))))

(ert-deftest eglotx-presets-python-stops-after-first-local-primary ()
  (eglotx-presets-test--with-directory (root)
    (let* ((source (expand-file-name "src/" root))
           (basedpyright
            (eglotx-presets-test--python-server
             source "basedpyright-langserver"))
           (primary-programs
            (mapcar (lambda (candidate) (plist-get candidate :program))
                    eglotx-presets-python--primary-candidates))
           (local-probes nil)
           (original-local
            (symbol-function 'eglotx-presets--local-executable)))
      (let ((default-directory source)
            (exec-path nil))
        (cl-letf
            (((symbol-function 'eglotx-presets--local-executable)
              (lambda (program directories)
                (when (member program primary-programs)
                  (push (cons program (copy-sequence directories))
                        local-probes))
                (funcall original-local program directories)))
             ((symbol-function 'eglotx-presets--path-executable)
              (lambda (program _root)
                (when (member program primary-programs)
                  (ert-fail (format "Probed PATH for local %s" program)))
                nil)))
          (should
           (equal
            (eglotx-presets-python-contact
             nil (eglotx-presets-test--project root))
            (list basedpyright "--stdio")))))
      (should
       (equal
        (nreverse local-probes)
        (list
         (cons "basedpyright-langserver"
               (list (expand-file-name ".venv/bin/" source)))))))))

(ert-deftest eglotx-presets-python-config-selects-primary-before-path-order ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--global-server
       global-bin "basedpyright-langserver")
      (let ((ty (eglotx-presets-test--global-server global-bin "ty"))
            path-probes
            (original-path
             (symbol-function 'eglotx-presets--path-executable)))
        (eglotx-presets-test--write-file root "ty.toml" "[environment]\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (cl-letf
              (((symbol-function 'eglotx-presets--path-executable)
                (lambda (program project-root)
                  (push program path-probes)
                  (funcall original-path program project-root))))
            (should
             (equal
              (eglotx-presets-python-contact
               nil (eglotx-presets-test--project root))
              (list ty "server"))))
          (should (equal (nreverse path-probes) '("ty"))))))))

(ert-deftest eglotx-presets-python-adds-ruff-for-structured-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((pyright
             (eglotx-presets-test--global-server
              global-bin "pyright-langserver"))
            (ruff (eglotx-presets-test--global-server global-bin "ruff")))
        (eglotx-presets-test--write-file
         root "pyproject.toml" "[tool.ruff]\nline-length = 88\n")
        (let* ((default-directory root)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-python-contact
                 nil (eglotx-presets-test--project root)))
               (ruff-backend
                (eglotx-presets-test--backend contact "ruff")))
          (should (eq (car contact) 'eglotx-server))
          (should
           (equal (mapcar (lambda (backend) (plist-get backend :name))
                          (eglotx-presets-test--backend-specs contact))
                  '("pyright" "ruff")))
          (should (equal (plist-get ruff-backend :command)
                         (list ruff "server")))
          (should (memq :textDocument/formatting
                        (plist-get ruff-backend :only)))
          (should-not (memq :textDocument/definition
                            (plist-get ruff-backend :only)))
          (should (equal (plist-get
                          (eglotx-presets-test--backend contact "pyright")
                          :command)
                         (list pyright "--stdio"))))))))

(ert-deftest eglotx-presets-python-global-ruff-alone-is-not-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((pyright
             (eglotx-presets-test--global-server
              global-bin "pyright-langserver")))
        (eglotx-presets-test--global-server global-bin "ruff")
        (eglotx-presets-test--write-file
         root "pyproject.toml" "[project]\nname = \"example\"\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-python-contact
             nil (eglotx-presets-test--project root))
            (list pyright "--stdio"))))))))

(ert-deftest eglotx-presets-python-detects-exact-ruff-dependency ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--global-server
       global-bin "pyright-langserver")
      (eglotx-presets-test--global-server global-bin "ruff")
      (eglotx-presets-test--write-file
       root "pyproject.toml"
       "[dependency-groups]\ndev = [\"pytest\", \"ruff>=0.12\"]\n")
      (let* ((default-directory root)
             (exec-path (list global-bin))
             (contact
              (eglotx-presets-python-contact
               nil (eglotx-presets-test--project root))))
        (should (eglotx-presets-test--backend contact "ruff"))))))

(ert-deftest eglotx-presets-python-ruff-dependency-parser-is-structural ()
  (should
   (eglotx-presets-python--toml-dependency-p
    "[tool.poetry.group.dev.dependencies]\nruff = \"^0.12\"\n" "ruff"))
  (should
   (eglotx-presets-python--toml-dependency-p
    "[project]\ndependencies = [\n  \"ruff[format]>=0.12\",\n]\n"
    "ruff"))
  (should
   (eglotx-presets-python--toml-dependency-p
    (concat "[project]\ndependencies = [\n"
            "  \"requests[socks]>=2\",\n"
            "  \"ruff>=0.12\",\n]\n")
    "ruff"))
  (should-not
   (eglotx-presets-python--toml-dependency-p
    "[project]\ndescription = \"ruff is fast\"\n" "ruff"))
  (should-not
   (eglotx-presets-python--toml-dependency-p
    "[dependency-groups]\n# dev = [\"ruff\"]\n" "ruff")))

(ert-deftest eglotx-presets-python-project-ruff-executable-is-intent ()
  (eglotx-presets-test--with-directory (root)
    (let ((pyright
           (eglotx-presets-test--python-server
            root "pyright-langserver"))
          (ruff (eglotx-presets-test--python-server root "ruff")))
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-python-contact
               nil (eglotx-presets-test--project root))))
        (should
         (equal (plist-get
                 (eglotx-presets-test--backend contact "pyright") :command)
                (list pyright "--stdio")))
        (should
         (equal (plist-get
                 (eglotx-presets-test--backend contact "ruff") :command)
                (list ruff "server")))))))

(ert-deftest eglotx-presets-python-disabled-ruff-uses-fast-path ()
  (eglotx-presets-test--with-directory (root)
    (let ((pyright
           (eglotx-presets-test--python-server
            root "pyright-langserver")))
      (eglotx-presets-test--python-server root "ruff")
      (let ((default-directory root)
            (exec-path nil)
            (eglotx-presets-disabled-backends '(ruff)))
        (should
         (equal
          (eglotx-presets-python-contact
           nil (eglotx-presets-test--project root))
          (list pyright "--stdio")))))))

(ert-deftest eglotx-presets-python-never-promotes-ruff-without-primary ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--python-server root "ruff")
    (eglotx-presets-test--write-file
     root "pyproject.toml" "[tool.ruff]\n")
    (let ((default-directory root)
          (exec-path nil)
          (project (eglotx-presets-test--project root)))
      (should-not (eglotx-presets-python-contact t project))
      (should-error (eglotx-presets-python-contact nil project)
                    :type 'eglotx-configuration-error))))

(ert-deftest eglotx-presets-go-adds-golangci-v2-for-config-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((gopls (eglotx-presets-test--global-server global-bin "gopls"))
            (server
             (eglotx-presets-test--global-server
              global-bin "golangci-lint-langserver"))
            (linter
             (eglotx-presets-test--global-server
              global-bin "golangci-lint"))
            (config
             (eglotx-presets-test--write-file
              root ".golangci.custom.yaml"
              "version: \"2\"\nlinters:\n")))
        (let* ((default-directory root)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-go-contact
                 nil (eglotx-presets-test--project root)))
               (backend
                (eglotx-presets-test--backend contact "golangci-lint"))
               (options (plist-get backend :initialization-options)))
          (should (equal (plist-get
                          (eglotx-presets-test--backend contact "gopls")
                          :command)
                         (list gopls)))
          (should (equal (plist-get backend :command) (list server)))
          (should (equal (plist-get backend :languages) '("go")))
          (should
           (equal (plist-get options :command)
                  (vector linter "run" "--output.json.path" "stdout"
                          "--show-stats=false" "--issues-exit-code=1"
                          "--config" config)))
          (should (memq :textDocument/didOpen (plist-get backend :only)))
          (should-not (memq :textDocument/hover (plist-get backend :only))))))))

(ert-deftest eglotx-presets-go-uses-v1-command-for-legacy-config ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (dolist (name '("gopls" "golangci-lint-langserver" "golangci-lint"))
        (eglotx-presets-test--global-server global-bin name))
      (eglotx-presets-test--write-file
       root ".golangci.yml" "linters:\n  enable: []\n")
      (let* ((default-directory root)
             (exec-path (list global-bin))
             (contact
              (eglotx-presets-go-contact
               nil (eglotx-presets-test--project root)))
             (command
              (plist-get
               (plist-get
                (eglotx-presets-test--backend contact "golangci-lint")
                :initialization-options)
               :command)))
        (should (seq-contains-p command "--out-format"))
        (should-not (seq-contains-p command "--output.json.path"))))))

(ert-deftest eglotx-presets-go-global-addon-alone-is-not-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((gopls (eglotx-presets-test--global-server global-bin "gopls")))
        (eglotx-presets-test--global-server
         global-bin "golangci-lint-langserver")
        (eglotx-presets-test--global-server global-bin "golangci-lint")
        (eglotx-presets-test--write-file root "go.mod" "module example\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-go-contact
             nil (eglotx-presets-test--project root))
            (list gopls))))))))

(ert-deftest eglotx-presets-go-never-promotes-linter-without-gopls ()
  (eglotx-presets-test--with-directory (root)
    (dolist (name '("golangci-lint-langserver" "golangci-lint"))
      (eglotx-presets-test--project-bin-server root name))
    (eglotx-presets-test--write-file
     root ".golangci.yml" "linters:\n  enable: []\n")
    (let ((default-directory root)
          (exec-path nil)
          (project (eglotx-presets-test--project root)))
      (should-not (eglotx-presets-go-contact t project))
      (should-error (eglotx-presets-go-contact nil project)
                    :type 'eglotx-configuration-error))))

(ert-deftest eglotx-presets-go-config-matching-accepts-keyword-variants ()
  (should (eglotx-presets-go--config-name-p ".golangci.yml"))
  (should (eglotx-presets-go--config-name-p "golangci.yaml"))
  (should
   (eglotx-presets-go--config-name-p
    "workspace-golangci.config.preview.toml"))
  (should-not (eglotx-presets-go--config-name-p "golangci-report.json"))
  (should-not
   (eglotx-presets-go--config-name-p "golangcireport.config.yml"))
  (should-not (eglotx-presets-go--config-name-p "mygolangci.config.yml")))

(ert-deftest eglotx-presets-go-detects-v2-across-config-syntaxes ()
  (dolist (config
           '(("config.yaml" . "version: \"2\" # current schema\n")
             ("config.toml" . "version = '2' # current schema\n")
             ("config.json" . "{\"version\":\"2\",\"linters\":{}}")))
    (should (eglotx-presets-go--v2-config-p config)))
  (should-not
   (eglotx-presets-go--v2-config-p
    (cons "config.yaml" "version: \"20\"\n")))
  (should-not
   (eglotx-presets-go--v2-config-p
    (cons "config.yaml"
          "linters-settings:\n  custom:\n    version: 2\n")))
  (should-not
   (eglotx-presets-go--v2-config-p
    (cons "config.json"
          "{\"plugin\":{\"version\":2},\"version\":1}"))))

(ert-deftest eglotx-presets-go-config-choice-ignores-listing-order ()
  (eglotx-presets-test--with-directory (root)
    (let* ((official
            (eglotx-presets-test--write-file
             root ".golangci.yml" "linters: {}\n"))
           (_variant
            (eglotx-presets-test--write-file
             root "workspace-golangci.config.yml" "version: \"2\"\n"))
           (project (eglotx-presets-test--project root)))
      (dolist (entries
               '(("workspace-golangci.config.yml" ".golangci.yml")
                 (".golangci.yml" "workspace-golangci.config.yml")))
        (let ((context (eglotx-presets--make-context project)))
          (cl-letf (((symbol-function
                      'eglotx-presets--directory-candidates)
                     (lambda (&rest _arguments) entries)))
            (should
             (equal (car (eglotx-presets-go--config context))
                    official))))))))

(ert-deftest eglotx-presets-go-ignores-marker-shaped-directory ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((gopls (eglotx-presets-test--global-server global-bin "gopls")))
        (eglotx-presets-test--global-server
         global-bin "golangci-lint-langserver")
        (eglotx-presets-test--global-server global-bin "golangci-lint")
        (make-directory (expand-file-name ".golangci.yaml" root))
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-go-contact
             nil (eglotx-presets-test--project root))
            (list gopls))))))))

(ert-deftest eglotx-presets-go-entry-keeps-the-complete-gopls-cohort ()
  (let ((modes (car eglotx-presets--go-entry)))
    (should (member '(go-mode :language-id "go") modes))
    (should (member '(go-ts-mode :language-id "go") modes))
    (should (member '(go-dot-mod-mode :language-id "go.mod") modes))
    (should (member '(go-mod-ts-mode :language-id "go.mod") modes))
    (should (member '(go-dot-work-mode :language-id "go.work") modes))
    (should (member '(go-work-ts-mode :language-id "go.work") modes))))

(ert-deftest eglotx-presets-ruby-adds-sorbet-for-config-intent ()
  (eglotx-presets-test--with-directory (root)
    (let ((ruby-lsp
           (eglotx-presets-test--project-bin-server root "ruby-lsp"))
          (srb (eglotx-presets-test--project-bin-server root "srb")))
      (eglotx-presets-test--write-file root "sorbet/config" ".\n")
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-ruby-contact
               nil (eglotx-presets-test--project root)))
             (sorbet (eglotx-presets-test--backend contact "sorbet")))
        (should
         (equal (plist-get
                 (eglotx-presets-test--backend contact "ruby-lsp") :command)
                (list ruby-lsp)))
        (should (equal (plist-get sorbet :command)
                       (list srb "tc" "--lsp")))
        (should (> (plist-get sorbet :priority) 100))
        (should (memq :textDocument/rename (plist-get sorbet :only)))
        (should-not
         (memq :textDocument/formatting (plist-get sorbet :only)))))))

(ert-deftest eglotx-presets-ruby-keeps-local-primary-ahead-of-path ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((solargraph
             (eglotx-presets-test--project-bin-server root "solargraph")))
        (eglotx-presets-test--global-server global-bin "ruby-lsp")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-ruby-contact
             nil (eglotx-presets-test--project root))
            (list solargraph "stdio"))))))))

(ert-deftest eglotx-presets-ruby-global-sorbet-alone-is-not-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((ruby-lsp
             (eglotx-presets-test--global-server global-bin "ruby-lsp")))
        (eglotx-presets-test--global-server global-bin "srb")
        (eglotx-presets-test--write-file root "Gemfile" "source 'x'\n")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-ruby-contact
             nil (eglotx-presets-test--project root))
            (list ruby-lsp))))))))

(ert-deftest eglotx-presets-typescript-adds-graphql-for-config-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (eglotx-presets-test--global-server
       global-bin "typescript-language-server")
      (let ((graphql
             (eglotx-presets-test--global-server global-bin "graphql-lsp")))
        (eglotx-presets-test--write-file
         root "package.json" "{\"devDependencies\":{\"typescript\":\"1\"}}")
        (eglotx-presets-test--write-file
         root "graphql.config.mjs" "export default {}\n")
        (let* ((default-directory root)
               (exec-path (list global-bin))
               (contact
                (eglotx-presets-typescript-contact
                 nil (eglotx-presets-test--project root)))
               (backend
                (eglotx-presets-test--backend contact "graphql")))
          (should (equal (plist-get backend :command)
                         (list graphql "server" "-m" "stream"
                               "--configDir" root)))
          (should (memq :textDocument/completion
                        (plist-get backend :only)))
          (should-not (memq :textDocument/formatting
                            (plist-get backend :only))))))))

(ert-deftest eglotx-presets-typescript-graphql-dependency-alone-is-not-intent ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-directory (global-bin)
      (let ((typescript
             (eglotx-presets-test--global-server
              global-bin "typescript-language-server")))
        (eglotx-presets-test--global-server global-bin "graphql-lsp")
        (eglotx-presets-test--write-file
         root "package.json"
         "{\"dependencies\":{\"graphql\":\"1\"},\"devDependencies\":{\"typescript\":\"1\"}}")
        (let ((default-directory root)
              (exec-path (list global-bin)))
          (should
           (equal
            (eglotx-presets-typescript-contact
             nil (eglotx-presets-test--project root))
            (list typescript "--stdio"))))))))

(ert-deftest eglotx-presets-graphql-config-matching-is-structural ()
  (should (eglotx-presets--graphql-marker-p ".graphqlrc.workspace.yml"))
  (should
   (eglotx-presets--graphql-marker-p
    "my-graphql.config.preview.mjs"))
  (should-not (eglotx-presets--graphql-marker-p "graphql-report.json"))
  (should-not
   (eglotx-presets--graphql-marker-p "graphqlreport.config.js"))
  (should-not (eglotx-presets--graphql-marker-p "mygraphql.config.js")))

(ert-deftest eglotx-presets-graphql-rejects-null-manifest-config ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--write-file root "package.json" "{\"graphql\":null}")
    (let ((default-directory root))
      (should-not
       (eglotx-presets--graphql-config-directory
        (eglotx-presets--make-context
         (eglotx-presets-test--project root)))))))

(ert-deftest
    eglotx-presets-javascript-typescript-react-adds-typescript-only-angular ()
  (eglotx-presets-test--with-directory (root)
    (let ((typescript
           (eglotx-presets-test--local-server
            root "typescript-language-server"))
          (ngserver (eglotx-presets-test--local-server root "ngserver")))
      (eglotx-presets-test--write-file root "angular.json" "{}\n")
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-javascript-typescript-react-contact
               nil (eglotx-presets-test--project root)))
             (angular (eglotx-presets-test--backend contact "angular")))
        (should (equal (plist-get
                        (eglotx-presets-test--backend contact "typescript")
                        :command)
                       (list typescript "--stdio")))
        (should (equal (car (plist-get angular :command)) ngserver))
        (should (equal (cadr (plist-get angular :command)) "--stdio"))
        (should (equal (plist-get angular :languages) '("typescript"))))
      (let ((modes
             (car eglotx-presets--javascript-typescript-react-entry)))
        (should (member '(typescript-mode :language-id "typescript") modes))
        (should (member '(js-mode :language-id "javascript") modes))
        (should
         (member '(tsx-ts-mode :language-id "typescriptreact") modes))))))

(ert-deftest eglotx-presets-javascript-typescript-react-entry-is-canonical ()
  (should
   (eq (cdr eglotx-presets--javascript-typescript-react-entry)
       'eglotx-presets-javascript-typescript-react-contact)))

(ert-deftest eglotx-presets-react-modes-use-exact-language-ids ()
  (let ((modes (car eglotx-presets--javascript-typescript-react-entry)))
    (dolist (mode '(js-jsx-mode rjsx-mode js2-jsx-mode
                    jtsx-jsx-mode))
      (should
       (member (list mode :language-id "javascriptreact") modes)))
    (dolist (mode '(tsx-ts-mode typescript-tsx-mode
                    jtsx-tsx-mode tsx-mode))
      (should
       (member (list mode :language-id "typescriptreact") modes)))
    (should (member '(js2-mode :language-id "javascript") modes))
    (should
     (member '(jtsx-typescript-mode :language-id "typescript") modes))
    (dolist (pair '((js-jsx-mode . js-mode)
                    (rjsx-mode . js2-mode)
                    (js2-jsx-mode . js2-mode)
                    (jtsx-jsx-mode . js-ts-mode)
                    (jtsx-tsx-mode . tsx-ts-mode)
                    (tsx-mode . tsx-ts-mode)))
      (should (< (cl-position (car pair) modes :key #'car)
                 (cl-position (cdr pair) modes :key #'car))))))

(ert-deftest
    eglotx-presets-javascript-typescript-react-delegates-outside-angular ()
  (eglotx-presets-test--with-directory (root)
    (let ((typescript
           (eglotx-presets-test--local-server
            root "typescript-language-server")))
      (let ((default-directory root)
            (exec-path nil))
        (should
         (equal
          (eglotx-presets-javascript-typescript-react-contact
           nil (eglotx-presets-test--project root))
          (list typescript "--stdio")))))))

(ert-deftest
    eglotx-presets-javascript-typescript-react-uses-preserved-contact ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--with-mode-state
      (eglotx-presets-test--local-server root "ngserver")
      (eglotx-presets-test--write-file root "angular.json" "{}\n")
      (let* ((project (eglotx-presets-test--project root))
             (fallback '("custom-typescript-server" "--stdio"))
             (eglot-server-programs
              `((typescript-mode . ,fallback)))
             (eglotx-presets--installed-entries nil)
             (eglotx-presets--fallback-programs nil)
             (eglotx-presets--fallback-resolver nil)
             (default-directory root)
             (major-mode 'typescript-mode)
             (exec-path nil))
        (unwind-protect
            (progn
              (eglotx-presets-mode 1)
              (should
               (equal
                (eglotx-presets-javascript-typescript-react-contact
                 nil project)
                fallback)))
          (eglotx-presets-mode -1))))))

(ert-deftest
    eglotx-presets-javascript-typescript-react-shares-one-context ()
  (eglotx-presets-test--with-directory (root)
    (eglotx-presets-test--local-server root "typescript-language-server")
    (eglotx-presets-test--local-server root "ngserver")
    (eglotx-presets-test--write-file root "angular.json" "{}\n")
    (let ((default-directory root)
          (exec-path nil)
          (calls 0)
          (original (symbol-function 'eglotx-presets--make-context)))
      (cl-letf (((symbol-function 'eglotx-presets--make-context)
                 (lambda (&optional project)
                   (cl-incf calls)
                   (funcall original project))))
        (eglotx-presets-javascript-typescript-react-contact
         nil (eglotx-presets-test--project root))
        (should (= calls 1))))))

(ert-deftest eglotx-presets-html-adds-tailwind-without-typescript ()
  (eglotx-presets-test--with-directory (root)
    (let ((html
           (eglotx-presets-test--local-server
            root "vscode-html-language-server"))
          (tailwind
           (eglotx-presets-test--local-server
            root "tailwindcss-language-server")))
      (eglotx-presets-test--write-file
       root "package.json" "{\"dependencies\":{\"tailwindcss\":\"4\"}}")
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-html-contact
               nil (eglotx-presets-test--project root))))
        (should (equal (plist-get
                        (eglotx-presets-test--backend contact "html")
                        :command)
                       (list html "--stdio")))
        (should (equal (plist-get
                        (eglotx-presets-test--backend contact "tailwindcss")
                        :command)
                       (list tailwind "--stdio")))))))

(ert-deftest eglotx-presets-css-adds-tailwind-and-biome ()
  (eglotx-presets-test--with-directory (root)
    (dolist (name '("vscode-css-language-server"
                    "tailwindcss-language-server" "biome"))
      (eglotx-presets-test--local-server root name))
    (eglotx-presets-test--write-file
     root "package.json"
     "{\"dependencies\":{\"tailwindcss\":\"4\",\"@biomejs/biome\":\"1\"}}")
    (let* ((default-directory root)
           (exec-path nil)
           (contact
            (eglotx-presets-css-contact
             nil (eglotx-presets-test--project root))))
      (should (equal (mapcar (lambda (backend) (plist-get backend :name))
                             (eglotx-presets-test--backend-specs contact))
                     '("css" "biome" "tailwindcss")))
      (should
       (equal
        (plist-get (eglotx-presets-test--backend contact "biome") :languages)
        '("css"))))))

(ert-deftest eglotx-presets-json-adds-biome-and-keeps-jsonc-cohort ()
  (eglotx-presets-test--with-directory (root)
    (let ((json
           (eglotx-presets-test--local-server
            root "vscode-json-language-server"))
          (biome (eglotx-presets-test--local-server root "biome")))
      (eglotx-presets-test--write-file root "biome.json" "{}\n")
      (let* ((default-directory root)
             (exec-path nil)
             (contact
              (eglotx-presets-json-contact
               nil (eglotx-presets-test--project root))))
        (should (equal (plist-get
                        (eglotx-presets-test--backend contact "json")
                        :command)
                       (list json "--stdio")))
        (should (equal (plist-get
                        (eglotx-presets-test--backend contact "biome")
                        :command)
                       (list biome "lsp-proxy"))))
      (should (member '(jsonc-mode :language-id "jsonc")
                      (car eglotx-presets--json-entry))))))

(ert-deftest eglotx-presets-derived-modes-use-specific-language-ids ()
  (let* ((parents '((jsonc-mode . json-mode)
                    (scss-mode . css-mode)
                    (js2-mode . js-mode)
                    (js2-jsx-mode . js2-mode)
                    (rjsx-mode . js2-mode)
                    (jtsx-jsx-mode . js-ts-mode)
                    (jtsx-tsx-mode . tsx-ts-mode)
                    (tsx-mode . tsx-ts-mode)))
         (saved-plists
          (mapcar (lambda (entry)
                    (cons (car entry)
                          (copy-sequence (symbol-plist (car entry)))))
                  parents)))
    (unwind-protect
        (progn
          (dolist (entry parents)
            (put (car entry) 'derived-mode-parent (cdr entry)))
          (dolist (case
                   `((jsonc-mode ,eglotx-presets--json-entry "jsonc")
                     (scss-mode ,eglotx-presets--css-entry "scss")
                     (js2-jsx-mode
                      ,eglotx-presets--javascript-typescript-react-entry
                      "javascriptreact")
                     (rjsx-mode
                      ,eglotx-presets--javascript-typescript-react-entry
                      "javascriptreact")
                     (jtsx-jsx-mode
                      ,eglotx-presets--javascript-typescript-react-entry
                      "javascriptreact")
                     (jtsx-tsx-mode
                      ,eglotx-presets--javascript-typescript-react-entry
                      "typescriptreact")
                     (tsx-mode
                      ,eglotx-presets--javascript-typescript-react-entry
                      "typescriptreact")))
            (let* ((mode (nth 0 case))
                   (eglot-server-programs (list (nth 1 case)))
                   (languages (car (eglot--lookup-mode mode)))
                   (actual
                    (cl-loop for (candidate . language) in languages
                             when (provided-mode-derived-p mode candidate)
                             return language)))
              (should (equal actual (nth 2 case))))))
      (dolist (entry saved-plists)
        (setplist (car entry) (cdr entry))))))

(ert-deftest eglotx-presets-supports-emacs-29-executable-suffix-variable ()
  (let ((exec-suffixes '(".cmd")))
    (cl-letf (((symbol-function 'exec-suffixes) nil))
      (should (equal (eglotx-presets--exec-suffixes) '(".cmd"))))))

(ert-deftest eglotx-presets-remote-path-resolution-stays-remote ()
  (let (observed-directory observed-remote)
    (cl-letf (((symbol-function 'file-remote-p)
               (lambda (_path) "/ssh:test.example:"))
              ((symbol-function 'executable-find)
               (lambda (_program remote)
                 (setq observed-directory default-directory
                       observed-remote remote)
                 "/ssh:test.example:/usr/bin/typescript-language-server")))
      (should
       (equal
        (eglotx-presets--path-executable
         "typescript-language-server" "/ssh:test.example:/srv/project/")
        "/ssh:test.example:/usr/bin/typescript-language-server")))
    (should (equal observed-directory "/ssh:test.example:/srv/project/"))
    (should observed-remote)
    (should
     (equal
      (eglotx-presets--process-path
       "/ssh:test.example:/usr/bin/typescript-language-server")
      "/usr/bin/typescript-language-server"))))

(ert-deftest eglotx-presets-remote-node-package-uses-source-path ()
  (let* ((remote-executable
          "/ssh:test.example:/opt/node_modules/@vue/language-server/bin/vue-language-server.js")
         (package-directory
          "/ssh:test.example:/opt/node_modules/@vue/language-server/")
         (context
          (eglotx-presets--context-create
           :root "/ssh:test.example:/srv/project/"
           :start "/ssh:test.example:/srv/project/"
           :directories '("/ssh:test.example:/srv/project/")
           :remote-p "/ssh:test.example:"
           :path-executable-cache (make-hash-table :test #'equal))))
    (puthash "vue-language-server" remote-executable
             (eglotx-presets--context-path-executable-cache context))
    (should
     (equal
      (eglotx-presets--node-source-executable
       context "vue-language-server" nil "/usr/bin/vue-language-server")
      remote-executable))
    (cl-letf (((symbol-function 'file-truename) #'identity)
              ((symbol-function 'eglotx-presets--node-package-directory-p)
               (lambda (_context directory package-name)
                 (and (equal directory package-directory)
                      (equal package-name "@vue/language-server")))))
      (should
       (equal
        (eglotx-presets--node-package-from-executable
         context remote-executable "@vue/language-server")
        package-directory)))))

(ert-deftest eglotx-presets-angular-probe-directory-is-process-local ()
  (let ((context
         (eglotx-presets--context-create
          :root "/ssh:test.example:/srv/project/"
          :start "/ssh:test.example:/srv/project/"
          :directories '("/ssh:test.example:/srv/project/")
          :remote-p "/ssh:test.example:")))
    (should
     (equal (eglotx-presets--angular-probe-directory nil context)
            "/srv/project/"))))

(provide 'eglotx-presets-test)
;;; eglotx-presets-test.el ends here
