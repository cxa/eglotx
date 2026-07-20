;;; eglotx-presets.el --- Project-aware contacts for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This optional module supplies project-aware Eglot contacts.  It owns
;; language and toolchain policy; `eglotx.el' remains a protocol multiplexer
;; with no knowledge of project manifests or particular language servers.
;;
;; Enable `eglotx-presets-mode' for the bundled project-aware contact catalog.
;; Server resolution happens only when Eglot starts a new project session.
;; Project executables take precedence over PATH by default, and no shell or
;; package manager is involved.

;;; Code:

(require 'cl-lib)
(require 'eglotx)
(require 'eglotx-preset-engine)
(require 'eglotx-presets-go)
(require 'eglotx-presets-python)
(require 'eglotx-presets-ruby)
(require 'subr-x)

(declare-function eglotx-backend-request
                  "eglotx"
                  (server source target-name method params
                          success-function error-function))

(defconst eglotx-presets--marker-candidate-regexp
  "\\(?:\\`\\|[._-]\\)\\(?:\\.eslint\\|eslint\\|tailwind\\|biome\\)"
  "Boundary-aware prefilter for possible tool configuration markers.")

(defconst eglotx-presets--script-extension-regexp
  "\\`[cm]?[jt]s\\'"
  "JavaScript/TypeScript-family extension used by config markers.")

(defconst eglotx-presets--eslint-legacy-extension-regexp
  "\\`\\(?:[cm]?[jt]s\\|json\\|ya?ml\\)\\'"
  "Extension accepted for a legacy .eslintrc variant.")

(defconst eglotx-presets--config-extension-regexp
  "\\`\\(?:[cm]?[jt]s\\|jsonc?\\|toml\\|ya?ml\\)\\'"
  "Data or script extension accepted for structural config markers.")

(defconst eglotx-presets--graphql-only
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
    :textDocument/definition
    :textDocument/references
    :textDocument/documentSymbol
    :workspace/symbol
    :textDocument/codeAction
    :codeAction/resolve
    :textDocument/diagnostic
    :workspace/diagnostic)
  "Methods used by GraphQL Language Service in bundled contacts.")

(defconst eglotx-presets--angular-only
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
    :textDocument/definition
    :textDocument/typeDefinition
    :textDocument/references
    :textDocument/implementation
    :textDocument/codeAction
    :codeAction/resolve
    :textDocument/rename
    :textDocument/prepareRename
    :textDocument/diagnostic
    :workspace/executeCommand)
  "Angular-aware methods allowed alongside TypeScript Language Server.")

(defconst eglotx-presets--biome-addon-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/configuration
    :textDocument/codeAction
    :codeAction/resolve
    :workspace/executeCommand
    :textDocument/formatting
    :textDocument/rangeFormatting
    :textDocument/diagnostic
    :workspace/diagnostic)
  "Lint and format methods Biome may own beside a structural primary.")

(defconst eglotx-presets--biome-embedded-partial-only
  (cl-remove-if
   (lambda (method)
     (memq method '(:textDocument/formatting
                    :textDocument/rangeFormatting)))
   eglotx-presets--biome-addon-only)
  "Safe Biome methods for an embedded language in partial-support mode.")

(defconst eglotx-presets--eslint-addon-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/didChangeWorkspaceFolders
    :workspace/configuration
    :textDocument/codeAction
    :codeAction/resolve
    :textDocument/diagnostic
    :workspace/diagnostic
    :workspace/executeCommand)
  "Methods owned by an ESLint backend beside a structural primary.")

(defconst eglotx-presets--tailwind-embedded-only
  '(:textDocument/didOpen
    :textDocument/didChange
    :textDocument/didClose
    :textDocument/didSave
    :workspace/didChangeConfiguration
    :workspace/didChangeWatchedFiles
    :workspace/didChangeWorkspaceFolders
    :workspace/configuration
    :textDocument/completion
    :completionItem/resolve
    :textDocument/hover
    :textDocument/codeAction
    :codeAction/resolve
    :textDocument/documentColor
    :textDocument/colorPresentation
    :textDocument/codeLens
    :textDocument/documentLink
    :textDocument/diagnostic
    :workspace/diagnostic)
  "Methods owned by Tailwind beside an embedded-language primary.")

(defconst eglotx-presets--typescript-entry
  '(((js-jsx-mode :language-id "javascriptreact")
     (rjsx-mode :language-id "javascriptreact")
     (js2-jsx-mode :language-id "javascriptreact")
     (jtsx-jsx-mode :language-id "javascriptreact")
     (jtsx-tsx-mode :language-id "typescriptreact")
     (tsx-mode :language-id "typescriptreact")
     (tsx-ts-mode :language-id "typescriptreact")
     (typescript-tsx-mode :language-id "typescriptreact")
     (js2-mode :language-id "javascript")
     (js-mode :language-id "javascript")
     (js-ts-mode :language-id "javascript")
     (jtsx-typescript-mode :language-id "typescript")
     (typescript-mode :language-id "typescript")
     (typescript-ts-mode :language-id "typescript"))
    . eglotx-presets-angular-contact)
  "Entry installed for one JavaScript/TypeScript/React project cohort.")

(defconst eglotx-presets--svelte-entry
  '(((svelte-ts-mode :language-id "svelte")
     (svelte-mode :language-id "svelte"))
    . eglotx-presets-svelte-contact)
  "Entry installed for Svelte single-file components.")

(defconst eglotx-presets--astro-entry
  '(((astro-ts-mode :language-id "astro")
     (astro-mode :language-id "astro"))
    . eglotx-presets-astro-contact)
  "Entry installed for Astro components.")

(defconst eglotx-presets--vue-entry
  '(((vue-ts-mode :language-id "vue")
     (vue-mode :language-id "vue")
     (vue-html-mode :language-id "vue"))
    . eglotx-presets-vue-contact)
  "Entry installed for Vue single-file components.")

(defconst eglotx-presets--html-entry
  '(((html-mode :language-id "html")) . eglotx-presets-html-contact)
  "Entry installed for ordinary HTML buffers.")

(defconst eglotx-presets--css-entry
  '(((scss-mode :language-id "scss")
     (scss-ts-mode :language-id "scss")
     (less-css-mode :language-id "less")
     (css-mode :language-id "css")
     (css-ts-mode :language-id "css"))
    . eglotx-presets-css-contact)
  "Entry installed for the CSS Language Server document cohort.")

(defconst eglotx-presets--json-entry
  '(((jsonc-mode :language-id "jsonc")
     (js-json-mode :language-id "json")
     (json-mode :language-id "json")
     (json-ts-mode :language-id "json"))
    . eglotx-presets-json-contact)
  "Entry installed for JSON and JSON-with-comments buffers.")

(defconst eglotx-presets--graphql-entry
  '(((graphql-mode :language-id "graphql")
     (graphql-ts-mode :language-id "graphql"))
    . eglotx-presets-graphql-contact)
  "Entry installed for standalone GraphQL buffers.")

(defconst eglotx-presets--entries
  (list eglotx-presets--svelte-entry
        eglotx-presets--astro-entry
        eglotx-presets--vue-entry
        eglotx-presets--typescript-entry
        eglotx-presets--html-entry
        eglotx-presets--css-entry
        eglotx-presets--json-entry
        eglotx-presets--graphql-entry
        eglotx-presets--python-entry
        eglotx-presets--go-entry
        eglotx-presets--ruby-entry)
  "Ordered bundled entries installed in `eglot-server-programs'.")

(defvar eglotx-presets--installed-entries nil
  "Exact `eglot-server-programs' entries installed by the presets mode.")

(defvar eglotx-presets--fallback-programs nil
  "Eglot contacts that preceded the currently installed preset entries.")

(defvar eglotx-presets--resolving-fallback nil
  "Non-nil while resolving a contact preserved by the presets mode.")

(defconst eglotx-presets--contact-functions
  '(eglotx-presets-svelte-contact
    eglotx-presets-astro-contact
    eglotx-presets-vue-contact
    eglotx-presets-angular-contact
    eglotx-presets-typescript-contact
    eglotx-presets-html-contact
    eglotx-presets-css-contact
    eglotx-presets-json-contact
    eglotx-presets-graphql-contact
    eglotx-presets-python-contact
    eglotx-presets-go-contact
    eglotx-presets-ruby-contact)
  "Contact functions owned by the bundled presets.")

(cl-defstruct (eglotx-presets--intent
               (:constructor eglotx-presets--intent-create))
  "Project intent discovered for optional Web and Node preset backends."
  eslint
  tailwind
  biome)

(defun eglotx-presets--eslint-dependency-p (name)
  "Return non-nil when package NAME indicates ESLint use."
  (or (string= name "eslint")
      (string-prefix-p "eslint-" name)
      (string-prefix-p "@eslint/" name)
      (string-prefix-p "@typescript-eslint/" name)))

(defun eglotx-presets--tailwind-dependency-p (name)
  "Return non-nil when package NAME indicates Tailwind CSS use."
  ;; Official v4 integrations install the core package too.  Do not treat
  ;; arbitrary @tailwindcss/* packages as project intent: plugins such as
  ;; @tailwindcss/typography can appear without defining a Tailwind project.
  (string= name "tailwindcss"))

(defun eglotx-presets--biome-dependency-p (name)
  "Return non-nil when package NAME is Biome's official package."
  (string= name "@biomejs/biome"))

(defun eglotx-presets--manifest-dependency-p (manifest predicate)
  "Return non-nil when MANIFEST has a dependency satisfying PREDICATE."
  (catch 'found
    (dolist (section '("dependencies" "devDependencies" "peerDependencies"
                       "optionalDependencies"))
      (let ((dependencies (gethash section manifest)))
        (when (hash-table-p dependencies)
          (maphash (lambda (name _version)
                     (when (funcall predicate name)
                       (throw 'found t)))
                   dependencies))))
    nil))

(defun eglotx-presets--script-config-name-p (name)
  "Return non-nil when NAME has a JavaScript/TypeScript extension."
  (when-let* ((extension (file-name-extension name)))
    (string-match-p eglotx-presets--script-extension-regexp extension)))

(defun eglotx-presets--eslint-marker-p (name &optional config-only)
  "Return non-nil when file NAME indicates ESLint use.

When CONFIG-ONLY is non-nil, exclude the legacy ignore-only signal."
  (or (string= name ".eslintrc")
      (and (not config-only) (string= name ".eslintignore"))
      (and (string-prefix-p ".eslintrc." name)
           (when-let* ((extension (file-name-extension name)))
             (string-match-p
              eglotx-presets--eslint-legacy-extension-regexp extension)))
      (and (eglotx-presets--script-config-name-p name)
           (let ((segments (eglotx-presets--config-name-segments name)))
             (and (eglotx-presets--keyword-segment-p "eslint" segments)
                  (member "config" segments))))))

(defun eglotx-presets--tailwind-v3-marker-p (name)
  "Return non-nil when file NAME indicates a legacy Tailwind config."
  (and (eglotx-presets--script-config-name-p name)
       (let ((segments (eglotx-presets--config-name-segments name)))
         (and (or (eglotx-presets--keyword-segment-p "tailwind" segments)
                  (eglotx-presets--keyword-segment-p
                   "tailwindcss" segments))
              (or (equal segments '("tailwind"))
                  (equal segments '("tailwindcss"))
                  (member "config" segments))))))

(defun eglotx-presets--biome-marker-p (name)
  "Return non-nil when file NAME is structurally a Biome config."
  (and (when-let* ((extension (file-name-extension name)))
         (string-match-p "\\`jsonc?\\'" extension))
       (equal (eglotx-presets--config-name-segments name) '("biome"))))

(defun eglotx-presets--graphql-marker-p (name)
  "Return non-nil when NAME structurally identifies GraphQL configuration."
  (let ((extension (file-name-extension name))
        (segments (eglotx-presets--config-name-segments name)))
    (or (string= name ".graphqlrc")
        (and extension
             (string-match-p eglotx-presets--config-extension-regexp
                             extension)
             (or (string-prefix-p ".graphqlrc." name)
                 (and (eglotx-presets--keyword-segment-p
                       "graphql" segments)
                      (member "config" segments)))))))

(defun eglotx-presets--graphql-config-directory (context)
  "Return CONTEXT's nearest structural GraphQL config directory."
  (catch 'intent
    (dolist (directory (eglotx-presets--context-directories context))
      (when-let* ((manifest
                   (eglotx-presets--read-json
                    context (expand-file-name "package.json" directory))))
        (let* ((missing (make-symbol "missing"))
               (value (gethash "graphql" manifest missing)))
          (unless (or (eq value missing)
                      (null value)
                      (eq value :json-false))
            (throw 'intent directory))))
      (dolist (name
               (eglotx-presets--directory-candidates
                context directory "\\(?:\\`\\|[._-]\\)graphql"))
        (let ((path (expand-file-name name directory)))
          (when (and (eglotx-presets--graphql-marker-p name)
                     (eglotx-presets--regular-file-p context path))
            (throw 'intent directory)))))
    nil))

(defun eglotx-presets--graphql-intent-p (context)
  "Return non-nil when CONTEXT has structural GraphQL configuration."
  (and (eglotx-presets--graphql-config-directory context) t))

(defun eglotx-presets--angular-intent-p (context)
  "Return non-nil when CONTEXT structurally identifies an Angular project."
  (catch 'intent
    (dolist (directory (eglotx-presets--context-directories context))
      (when (eglotx-presets--regular-file-p
             context (expand-file-name "angular.json" directory))
        (throw 'intent t))
      (when-let* ((manifest
                   (eglotx-presets--read-json
                    context (expand-file-name "package.json" directory))))
        (when (eglotx-presets--manifest-dependency-p
               manifest (lambda (name) (string= name "@angular/core")))
          (throw 'intent t))))
    nil))

(defun eglotx-presets--regular-marker-p (directory name)
  "Return non-nil when NAME in local DIRECTORY is a regular file."
  (condition-case nil
      (file-regular-p (expand-file-name name directory))
    (file-error nil)))

(defun eglotx-presets--directory-marker-intent
    (directory find-eslint find-tailwind find-biome
               &optional eslint-config-only)
  "Return marker intent found in DIRECTORY.

Only inspect the categories selected by FIND-ESLINT, FIND-TAILWIND, and
FIND-BIOME.  ESLINT-CONFIG-ONLY excludes `.eslintignore', which signals generic
ESLint use but cannot configure an embedded document parser.  Use one unsorted,
keyword-prefiltered local directory read, retain only a bounded number of
candidates, and stop as soon as every selected category is found.  Remote
listings are deliberately skipped because TRAMP must fetch the complete
directory before applying the regexp; remote manifests and executable probes
remain available as bounded intent signals."
  (if (file-remote-p directory)
      (eglotx-presets--intent-create)
    (let ((case-fold-search nil)
          eslint tailwind biome entries)
      (condition-case nil
          (setq entries
                (directory-files
                 directory nil eglotx-presets--marker-candidate-regexp t
                 eglotx-presets--marker-candidate-limit))
        (file-error nil))
      (while (and entries
                  (or (and find-eslint (not eslint))
                      (and find-tailwind (not tailwind))
                      (and find-biome (not biome))))
        (let* ((name (pop entries))
               (eslint-marker
                (and find-eslint
                     (not eslint)
                     (eglotx-presets--eslint-marker-p
                      name eslint-config-only)))
               (tailwind-marker
                (and find-tailwind
                     (not tailwind)
                     (eglotx-presets--tailwind-v3-marker-p name)))
               (biome-marker
                (and find-biome
                     (not biome)
                     (eglotx-presets--biome-marker-p name))))
          (when (and (or eslint-marker tailwind-marker biome-marker)
                     (eglotx-presets--regular-marker-p directory name))
            (when eslint-marker (setq eslint t))
            (when tailwind-marker (setq tailwind t))
            (when biome-marker (setq biome t)))))
      (eglotx-presets--intent-create
       :eslint eslint :tailwind tailwind :biome biome))))

(defun eglotx-presets--project-intent
    (directories &optional context categories eslint-config-only)
  "Return requested optional-backend intent for DIRECTORIES.

Use optional discovery CONTEXT.  CATEGORIES is a list containing any of
`eslint', `tailwind', and `biome'; nil preserves the compatibility behavior of
checking every category.  Unrequested categories remain nil in the result.
ESLINT-CONFIG-ONLY excludes an ignore file as ESLint intent."
  (let* ((all (null categories))
         (find-eslint (or all (memq 'eslint categories)))
         (find-tailwind (or all (memq 'tailwind categories)))
         (find-biome (or all (memq 'biome categories)))
         eslint tailwind biome)
    ;; Manifests are the common fast path.  Probe their single fixed name at
    ;; each ancestor before paying for keyword-filtered directory reads.
    (dolist (directory directories)
      (unless (and (or (not find-eslint) eslint)
                   (or (not find-tailwind) tailwind)
                   (or (not find-biome) biome))
        (when-let* ((path (expand-file-name "package.json" directory))
                    (manifest
                     (if context
                         (eglotx-presets--read-json context path)
                       (eglotx-presets--read-manifest path))))
          (when (and find-eslint (not eslint))
            (let* ((missing (make-symbol "missing"))
                   (eslint-config
                    (gethash "eslintConfig" manifest missing)))
              (setq eslint
                    (or (not (or (eq eslint-config missing)
                                 (null eslint-config)
                                 (eq eslint-config :json-false)))
                        (eglotx-presets--manifest-dependency-p
                         manifest #'eglotx-presets--eslint-dependency-p)))))
          (when (and find-tailwind (not tailwind))
            (setq tailwind
                  (eglotx-presets--manifest-dependency-p
                   manifest #'eglotx-presets--tailwind-dependency-p)))
          (when (and find-biome (not biome))
            (setq biome
                  (eglotx-presets--manifest-dependency-p
                   manifest #'eglotx-presets--biome-dependency-p))))))
    (dolist (directory directories)
      (unless (and (or (not find-eslint) eslint)
                   (or (not find-tailwind) tailwind)
                   (or (not find-biome) biome))
        (let ((markers
               (eglotx-presets--directory-marker-intent
                directory
                (and find-eslint (not eslint))
                (and find-tailwind (not tailwind))
                (and find-biome (not biome))
                eslint-config-only)))
          (setq eslint
                (or eslint (eglotx-presets--intent-eslint markers))
                tailwind
                (or tailwind (eglotx-presets--intent-tailwind markers))
                biome
                (or biome (eglotx-presets--intent-biome markers))))))
    (eglotx-presets--intent-create
     :eslint eslint :tailwind tailwind :biome biome)))

(defun eglotx-presets--node-bin-directories (context)
  "Return nearest-first Node executable directories for CONTEXT."
  (eglotx-presets--existing-directories
   context
   (mapcar (lambda (directory)
             (expand-file-name "node_modules/.bin/" directory))
           (eglotx-presets--context-directories context))))

(defun eglotx-presets--node-resolution
    (context program bin-directories)
  "Return PROGRAM's local and effective paths for CONTEXT."
  (let ((local
         (and eglotx-presets-prefer-project-local-servers
              (eglotx-presets--context-local-executable
               context program bin-directories))))
    (cons local
          (eglotx-presets--context-resolve-executable
           context program local))))

(defun eglotx-presets--select-node-primary
    (context candidates bin-directories)
  "Select one executable from ordered Node CANDIDATES in CONTEXT.

Each candidate is (NAME PROGRAM . ARGUMENTS).  A project-local executable wins
over every PATH executable; the nearest bin directory and declaration order
break local ties deterministically."
  (let (resolutions)
    (dolist (candidate candidates)
      (let* ((program (nth 1 candidate))
             (resolution
              (eglotx-presets--node-resolution
               context program bin-directories))
             (local (car resolution))
             (path (cdr resolution)))
        (when path
          (push (list :candidate candidate :path path
                      :local-index
                      (and local
                           (cl-position-if
                            (lambda (directory)
                              (string-prefix-p
                               (file-name-as-directory directory) local))
                            bin-directories)))
                resolutions))))
    (setq resolutions (nreverse resolutions))
    (or (let ((best nil))
          (dolist (resolution resolutions best)
            (when (and (numberp (plist-get resolution :local-index))
                       (or (null best)
                           (< (plist-get resolution :local-index)
                              (plist-get best :local-index))))
              (setq best resolution))))
        (car resolutions))))

(defun eglotx-presets--node-primary-backend (resolution priority)
  "Build a required Node backend from RESOLUTION with PRIORITY."
  (let ((candidate (plist-get resolution :candidate)))
    (list :name (car candidate)
          :command (cons (plist-get resolution :path)
                         (copy-sequence (cddr candidate)))
          :priority priority
          :required t)))

(defun eglotx-presets--contact-backends (contact name priority)
  "Return backend specs represented by CONTACT.

NAME and PRIORITY describe CONTACT when it is an ordinary argv fast path."
  (if (eq (car-safe contact) 'eglotx-server)
      (copy-tree (plist-get (cdr contact) :backend-specs))
    (and contact
         (list (list :name name :command (copy-sequence contact)
                     :priority priority :required t)))))

(defun eglotx-presets--biome-addon-backend (path &optional languages)
  "Return a restricted optional Biome backend using PATH.
When LANGUAGES is non-nil, accept only those LSP language IDs."
  (list :name "biome"
        :command (list path "lsp-proxy")
        :priority 120
        :required nil
        :settings (eglotx-presets--biome-settings)
        :only eglotx-presets--biome-addon-only
        :languages languages))

(defun eglotx-presets--tailwind-backend (path)
  "Return an optional Tailwind backend using PATH."
  (list :name "tailwindcss"
        :command (list path "--stdio")
        :priority 60
        :required nil
        :settings (eglotx-presets--tailwind-settings)))

(defun eglotx-presets--node-package-directory-p
    (context directory package-name)
  "Return non-nil when DIRECTORY contains Node PACKAGE-NAME.
Use discovery CONTEXT so metadata reads share the contact's fixed budget."
  (when-let* ((manifest
               (eglotx-presets--read-json
                context (expand-file-name "package.json" directory))))
    (equal (gethash "name" manifest) package-name)))

(defun eglotx-presets--node-package-from-executable
    (context executable package-name)
  "Return PACKAGE-NAME's directory when it owns EXECUTABLE.
Resolve only a bounded chain of local ancestors and validate package metadata."
  (when executable
    (condition-case nil
        (let ((directory
               (file-name-directory (file-truename executable)))
              (remaining 8)
              found)
          (while (and directory (> remaining 0) (not found))
            (when (eglotx-presets--node-package-directory-p
                   context directory package-name)
              (setq found (file-name-as-directory directory)))
            (let ((parent
                   (file-name-directory (directory-file-name directory))))
              (setq directory (unless (equal parent directory) parent)
                    remaining (1- remaining))))
          found)
      (file-error nil))))

(defun eglotx-presets--node-source-executable
    (context program local-executable effective-executable)
  "Return selected PROGRAM's filesystem path in CONTEXT.

LOCAL-EXECUTABLE already retains its local or TRAMP spelling.  When PATH won,
EFFECTIVE-EXECUTABLE has been stripped for `make-process', so recover the
cached source spelling before inspecting package ownership."
  (or local-executable
      (and effective-executable
           (eglotx-presets--context-path-executable context program))))

(defun eglotx-presets--node-package-directory
    (context local-executable executable relative-package package-name)
  "Return validated PACKAGE-NAME directory for EXECUTABLE in CONTEXT.
RELATIVE-PACKAGE is its path below node_modules.  LOCAL-EXECUTABLE preserves
the project spelling before process-path handling."
  (or
   (when local-executable
     (let* ((bin-directory (file-name-directory local-executable))
            (node-modules
             (file-name-directory (directory-file-name bin-directory)))
            (candidate
             (file-name-as-directory
              (expand-file-name relative-package node-modules))))
       (and (eglotx-presets--node-package-directory-p
             context candidate package-name)
            candidate)))
   (eglotx-presets--node-package-from-executable
    context executable package-name)))

(defun eglotx-presets--node-resolvable-package-directory
    (context from-directory relative-package package-name)
  "Find PACKAGE-NAME as Node would from FROM-DIRECTORY in CONTEXT.

RELATIVE-PACKAGE is the scoped or unscoped path below `node_modules'.  Probe a
fixed number of ancestors without invoking Node or a package manager.  Follow
the package symlink first for pnpm's virtual store, then retain the lexical
spelling as a hoisted-package fallback."
  (let* ((spelling (file-name-as-directory from-directory))
         (truename
          (condition-case nil
              (file-name-as-directory (file-truename spelling))
            (file-error nil)))
         (origins (delete-dups (delq nil (list truename spelling)))))
    (catch 'found
      (dolist (origin origins)
        (let ((directory origin)
              (remaining 8))
          (while (and directory (> remaining 0))
            (let ((candidate
                   (file-name-as-directory
                    (expand-file-name
                     (concat "node_modules/" relative-package) directory))))
              (when (eglotx-presets--node-package-directory-p
                     context candidate package-name)
                (throw 'found candidate)))
            (let ((parent
                   (file-name-directory (directory-file-name directory))))
              (setq directory (unless (equal parent directory) parent)
                    remaining (1- remaining))))))
      nil)))

(defun eglotx-presets--vue-package-directory
    (context local-executable executable)
  "Return the validated Vue package for selected EXECUTABLE in CONTEXT."
  (eglotx-presets--node-package-directory
   context local-executable executable
   "@vue/language-server" "@vue/language-server"))

(defun eglotx-presets--node-package-version (context package-directory)
  "Return the version of PACKAGE-DIRECTORY using discovery CONTEXT."
  (when-let* ((manifest
               (eglotx-presets--read-json
                context (expand-file-name "package.json" package-directory)))
              (version (gethash "version" manifest))
              ((stringp version)))
    version))

(defun eglotx-presets--parse-semver (version)
  "Return VERSION's numeric core and prerelease as a cons, or nil."
  (when (and
         (stringp version)
         (string-match
          (concat
           "\\`\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)"
           "\\(?:-\\([0-9A-Za-z.-]+\\)\\)?"
           "\\(?:[+][0-9A-Za-z.-]+\\)?\\'")
          version))
    (cons (vector (string-to-number (match-string 1 version))
                  (string-to-number (match-string 2 version))
                  (string-to-number (match-string 3 version)))
          (match-string 4 version))))

(defun eglotx-presets--numeric-version-compare (left right)
  "Compare three-component numeric version vectors LEFT and RIGHT."
  (cl-loop for left-part across left
           for right-part across right
           when (/= left-part right-part)
           return (if (< left-part right-part) -1 1)
           finally return 0))

(defun eglotx-presets--version-at-least-p (version minimum)
  "Return non-nil when semver VERSION is at least stable MINIMUM.

Build metadata is ignored.  A prerelease with the same numeric core remains
  below the stable minimum; a prerelease with a newer core remains above it."
  (when-let* ((candidate (eglotx-presets--parse-semver version))
              (minimum-version (eglotx-presets--parse-semver minimum))
              ((null (cdr minimum-version))))
    (let ((comparison
           (eglotx-presets--numeric-version-compare
            (car candidate) (car minimum-version))))
      (or (> comparison 0)
          (and (zerop comparison) (null (cdr candidate)))))))

(defun eglotx-presets--typescript-sdk-directory (context)
  "Return CONTEXT's nearest validated project TypeScript lib directory."
  (catch 'found
    (dolist (directory (eglotx-presets--context-directories context))
      (let ((candidate
             (file-name-as-directory
              (expand-file-name "node_modules/typescript/lib" directory))))
        (when (and (eglotx-presets--directory-p context candidate)
                   (or (eglotx-presets--regular-file-p
                        context (expand-file-name "typescript.js" candidate))
                       (eglotx-presets--regular-file-p
                        context
                        (expand-file-name "tsserverlibrary.js" candidate))))
          (throw 'found (eglotx-presets--process-path candidate)))))
    nil))

(defun eglotx-presets--vue-vls-accepts-tsdk-p (version)
  "Return non-nil when Vue Language Server VERSION accepts `--tsdk'."
  (eglotx-presets--version-at-least-p version "3.0.9"))

(defun eglotx-presets--vue-request-tuple (params)
  "Return the validated Volar request tuple contained in PARAMS, or nil."
  (let ((outer
         (cond ((vectorp params) (append params nil))
               ((proper-list-p params) params))))
    (when (= (length outer) 1)
      (let ((tuple
             (cond ((vectorp (car outer)) (append (car outer) nil))
                   ((proper-list-p (car outer)) (car outer)))))
        (when (and (= (length tuple) 3)
                   (stringp (nth 1 tuple)))
          tuple)))))

(defun eglotx-presets--vue-tsserver-response (server backend id body)
  "Notify Vue BACKEND in SERVER that TypeScript request ID returned BODY."
  (eglotx--notify-backend
   server backend :tsserver/response (vector (vector id body)) t))

(defun eglotx-presets-vue--tsserver-request (server backend params)
  "Bridge Vue Language Server PARAMS to SERVER's TypeScript BACKEND."
  (if-let* ((tuple (eglotx-presets--vue-request-tuple params)))
      (let ((id (nth 0 tuple))
            (command (nth 1 tuple))
            (payload (nth 2 tuple)))
        (eglotx-backend-request
         server backend "typescript" :workspace/executeCommand
         (list :command "typescript.tsserverRequest"
               :arguments (vector command payload))
         (lambda (result)
           (eglotx-presets--vue-tsserver-response
            server backend id (and (listp result) (plist-get result :body))))
         (lambda (error-data)
           ;; Always settle the Vue-side promise.  A missing response wedges
           ;; every feature waiting on this tsserver request.
           (eglotx-presets--vue-tsserver-response server backend id nil)
           (display-warning
            'eglotx-presets
            (format "Vue TypeScript bridge request failed: %S" error-data)
            :warning))))
    (display-warning
     'eglotx-presets
     (format "Ignored malformed Vue tsserver/request params: %S" params)
     :warning))
  t)

(defun eglotx-presets--vue-typescript-options (package-directory tsdk)
  "Return TLS initialization options for Vue PACKAGE-DIRECTORY and TSDK."
  (append
   (list :plugins
         (vector
          (list :name "@vue/typescript-plugin"
                :location
                (eglotx-presets--process-path package-directory)
                :languages ["vue"])))
   (when tsdk (list :tsserver (list :path tsdk)))))

(defun eglotx-presets--biome-config-path (context)
  "Return CONTEXT's nearest structurally matched Biome configuration."
  (catch 'found
    (dolist (directory (eglotx-presets--context-directories context))
      (dolist (name
               (eglotx-presets--directory-candidates
                context directory "\\(?:\\`\\|[._-]\\)biome"))
        (let ((path (expand-file-name name directory)))
          (when (and (eglotx-presets--biome-marker-p name)
                     (eglotx-presets--regular-file-p context path))
            (throw 'found path)))))
    nil))

(defun eglotx-presets--biome-embedded-full-support-p (context)
  "Return non-nil when CONTEXT enables full Biome embedded-language support."
  (when-let* ((path (eglotx-presets--biome-config-path context))
              (config (eglotx-presets--read-jsonc context path))
              (html (gethash "html" config))
              ((hash-table-p html)))
    (eq (gethash "experimentalFullSupportEnabled" html) t)))

(defun eglotx-presets--embedded-biome-backend
    (context executable language-id)
  "Return an embedded LANGUAGE-ID Biome backend for EXECUTABLE in CONTEXT."
  (let ((backend
         (eglotx-presets--biome-addon-backend
          executable (list language-id))))
    (unless (eglotx-presets--biome-embedded-full-support-p context)
      ;; Biome's partial SFC mode extracts only script blocks.  Keep
      ;; whole-document formatting with the structural language server.
      (setq backend
            (plist-put backend :priority 70)
            backend
            (plist-put backend :only
                       eglotx-presets--biome-embedded-partial-only)))
    backend))

(defun eglotx-presets--embedded-web-addon-backends
    (context bin-directories language-id)
  "Return intent-gated embedded Web add-ons for LANGUAGE-ID in CONTEXT.

Use BIN-DIRECTORIES for project-local Node resolution.  The returned order is
Biome, ESLint, Tailwind CSS, then GraphQL.  Every backend is restricted to
LANGUAGE-ID, and Biome is admitted only when its installed version supports
embedded documents."
  (let* ((root (eglotx-presets--context-root context))
         (directories (eglotx-presets--context-directories context))
         (languages (list language-id))
         (eslint-resolution
          (unless (eglotx-presets--backend-disabled-p 'eslint)
            (eglotx-presets--node-resolution
             context "vscode-eslint-language-server" bin-directories)))
         (eslint-executable (cdr eslint-resolution))
         (tailwind-resolution
          (unless (eglotx-presets--backend-disabled-p 'tailwindcss)
            (eglotx-presets--node-resolution
             context "tailwindcss-language-server" bin-directories)))
         (tailwind-local (car tailwind-resolution))
         (tailwind-executable (cdr tailwind-resolution))
         (biome-resolution
          (unless (eglotx-presets--backend-disabled-p 'biome)
            (eglotx-presets--node-resolution context "biome" bin-directories)))
         (biome-local (car biome-resolution))
         (biome-executable (cdr biome-resolution))
         (biome-source-executable
          (eglotx-presets--node-source-executable
           context "biome" biome-local biome-executable))
         (biome-package
          (and biome-executable
               (eglotx-presets--node-package-directory
                context biome-local biome-source-executable
                "@biomejs/biome" "@biomejs/biome")))
         (biome-version
          (and biome-package
               (eglotx-presets--node-package-version context biome-package)))
         (graphql-resolution
          (unless (eglotx-presets--backend-disabled-p 'graphql)
            (eglotx-presets--node-resolution
             context "graphql-lsp" bin-directories)))
         (graphql-executable (cdr graphql-resolution))
         (intent-categories
          (delq nil
                (list (and eslint-executable 'eslint)
                      (and tailwind-executable (not tailwind-local) 'tailwind)
                      (and biome-executable (not biome-local) 'biome))))
         (intent
          (if intent-categories
              (eglotx-presets--project-intent
               directories context intent-categories t)
            (eglotx-presets--intent-create)))
         (eslint
          (and eslint-executable
               (eglotx-presets--intent-eslint intent)
               eslint-executable))
         (tailwind
          (and tailwind-executable
               (or tailwind-local (eglotx-presets--intent-tailwind intent))
               tailwind-executable))
         (biome
          (and biome-executable
               (eglotx-presets--version-at-least-p biome-version "2.3.0")
               (or biome-local (eglotx-presets--intent-biome intent))
               biome-executable))
         (graphql-config
          (and graphql-executable
               (eglotx-presets--graphql-config-directory context)))
         backends)
    (when biome
      (push (eglotx-presets--embedded-biome-backend
             context biome language-id)
            backends))
    (when eslint
      (push (list :name "eslint"
                  :command (list eslint "--stdio")
                  :priority 80
                  :required nil
                  :languages languages
                  :settings (eglotx-presets--eslint-settings root)
                  :only eglotx-presets--eslint-addon-only)
            backends))
    (when tailwind
      (let ((backend (eglotx-presets--tailwind-backend tailwind)))
        (setq backend
              (plist-put backend :languages languages)
              backend
              (plist-put backend :only
                         eglotx-presets--tailwind-embedded-only))
        (push backend backends)))
    (when graphql-config
      (push (list :name "graphql"
                  :command
                  (list graphql-executable "server" "-m" "stream"
                        "--configDir"
                        (eglotx-presets--process-path graphql-config))
                  :priority 50
                  :required nil
                  :languages languages
                  :only eglotx-presets--graphql-only)
            backends))
    (nreverse backends)))

;;;###autoload
(defun eglotx-presets-astro-contact (&optional interactive project)
  "Return Astro Language Server plus detected complementary backends.

Astro Language Server is the required structural server and owns Astro,
TypeScript/JavaScript, HTML, and CSS regions of an Astro document.  It also
requires the nearest project TypeScript SDK.  ESLint, Tailwind CSS, GraphQL,
and Biome 2.3 or newer join only under their existing strong-intent policy.
Biome may format the whole document only when its experimental full HTML
support is explicitly enabled.

Project-local executables take precedence over PATH, and the TypeScript SDK is
resolved from the project.  With no add-ons, return an ordinary Eglot contact
that retains Astro's required initialization options.  INTERACTIVE and PROJECT
have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (resolution
          (eglotx-presets--node-resolution context "astro-ls" bin-directories))
         (executable (cdr resolution))
         (tsdk (and executable
                    (eglotx-presets--typescript-sdk-directory context)))
         backends)
    (when (and executable tsdk)
      (setq backends
            (cons
             (list :name "astro"
                   :command (list executable "--stdio")
                   :priority 100
                   :required t
                   :languages '("astro")
                   :initialization-options
                   (list :typescript (list :tsdk tsdk)))
             (eglotx-presets--embedded-web-addon-backends
              context bin-directories "astro"))))
    (eglotx-presets--materialize-contact
     backends interactive
     (if executable
         "a project TypeScript SDK is required by astro-ls"
       "astro-ls is not executable")
     (eglotx-presets--context-project context))))

;;;###autoload
(defun eglotx-presets-svelte-contact (&optional interactive project)
  "Return Svelte Language Server plus detected complementary backends.

Svelte Language Server is the required structural server and already owns the
Svelte, TypeScript/JavaScript, HTML, and CSS regions of a Svelte document.
ESLint, Tailwind CSS, GraphQL, and Biome 2.3 or newer join only when their
existing project-intent policy applies.  Biome may format the whole document
only when its experimental full HTML support is explicitly enabled.

Project-local executables take precedence over PATH.  With only
`svelteserver', return an ordinary argv instead of starting the multiplexer.
INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (resolution
          (eglotx-presets--node-resolution
           context "svelteserver" bin-directories))
         (executable (cdr resolution))
         backends)
    (when executable
      (setq backends
            (cons
             (list :name "svelte"
                   :command (list executable "--stdio")
                   :priority 100
                   :required t
                   :languages '("svelte"))
             (eglotx-presets--embedded-web-addon-backends
              context bin-directories "svelte"))))
    (eglotx-presets--materialize-contact
     backends interactive "svelteserver is not executable"
     (eglotx-presets--context-project context))))

;;;###autoload
(defun eglotx-presets-vue-contact (&optional interactive project)
  "Return the current Vue/TypeScript hybrid stack plus detected add-ons.

Both Vue Language Server and TypeScript Language Server are required.  The
TypeScript child loads Vue's official plugin, and Eglotx bridges Vue's private
tsserver notifications without exposing them to Eglot.  ESLint, Tailwind CSS,
GraphQL, and Biome 2.3 or newer join only when the project declares their
existing preset intent.  Project-local executables take precedence over PATH
when `eglotx-presets-prefer-project-local-servers' is non-nil.

When any required component is unavailable, preserve the Eglot contact that
preceded `eglotx-presets-mode'.  INTERACTIVE and PROJECT follow the other
bundled contact functions."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (vue-resolution
          (eglotx-presets--node-resolution
           context "vue-language-server" bin-directories))
         (vue-local (car vue-resolution))
         (vue-executable (cdr vue-resolution))
         (vue-source-executable
          (eglotx-presets--node-source-executable
           context "vue-language-server" vue-local vue-executable))
         (typescript-resolution
          (eglotx-presets--node-resolution
           context "typescript-language-server" bin-directories))
         (typescript-executable (cdr typescript-resolution))
         (vue-package
          (and vue-executable
               (eglotx-presets--vue-package-directory
                context vue-local vue-source-executable)))
         (vue-version
          (and vue-package
               (eglotx-presets--node-package-version context vue-package)))
         (vue-typescript-plugin
          (and vue-package
               (eglotx-presets--node-resolvable-package-directory
                context vue-package
                "@vue/typescript-plugin" "@vue/typescript-plugin")))
         (tsdk (and vue-package
                    (eglotx-presets--typescript-sdk-directory context)))
         backends)
    (if (not (and vue-executable typescript-executable vue-package
                  vue-typescript-plugin))
        (eglotx-presets--missing-contact
         interactive
         (cond ((not vue-executable)
                "vue-language-server is not executable")
               ((not typescript-executable)
                "typescript-language-server is not executable")
               ((not vue-package)
                "@vue/language-server package directory is unavailable")
               (t
                (concat
                 "@vue/typescript-plugin is not resolvable from the "
                 "selected Vue server")))
         (eglotx-presets--context-project context))
      (setq backends
            (list
             (list :name "vue"
                   :command
                   (append
                    (list vue-executable "--stdio")
                    (when (and tsdk
                               (eglotx-presets--vue-vls-accepts-tsdk-p
                                vue-version))
                      (list (concat "--tsdk=" tsdk))))
                   :priority 110
                   :required t
                   :languages '("vue")
                   :notification-handlers
                   '(("tsserver/request"
                      . eglotx-presets-vue--tsserver-request)))
             (list :name "typescript"
                   :command (list typescript-executable "--stdio")
                   :priority 100
                   :required t
                   :languages '("vue")
                   :initialization-options
                   (eglotx-presets--vue-typescript-options vue-package tsdk))))
      (setq backends
            (append
             backends
             (eglotx-presets--embedded-web-addon-backends
              context bin-directories "vue")))
      (apply #'eglotx-contact backends))))

(defun eglotx-presets--eslint-settings (root)
  "Return vscode-eslint workspace settings for ROOT."
  (list
   ;; Unlike lsp-mode's unconditional add-on client, this backend is started
   ;; only after project intent is established.  Force validation so older
   ;; vscode-eslint servers do not disable TypeScript after a failed probe.
   :validate "on"
   :useESLintClass t
   :useRealpaths t
   :codeAction
   (list :disableRuleComment (list :enable t :location "separateLine")
         :showDocumentation (list :enable t))
   :codeActionOnSave (list :enable t :mode "all" :rules [])
   :format :json-false
   :quiet :json-false
   :onIgnoredFiles "off"
   :options (make-hash-table :test #'equal)
   :rulesCustomizations []
   :run "onType"
   :problems (list :shortenToSingleLine :json-false)
   :nodePath nil
   :workingDirectory (list :mode "auto")
   :workspaceFolder
   (list :uri (eglotx-presets--path-to-uri root)
         :name (file-name-nondirectory (directory-file-name root)))
   ;; Keep the object present for vscode-eslint 2.x, but let every ESLint
   ;; generation select legacy or flat config from its own supported rules.
   ;; The old experimental flag is deprecated for ESLint >= 8.57 and forcing
   ;; it off breaks ESLint 9's flat-config default.
   :experimental (make-hash-table :test #'equal)))

(defun eglotx-presets--tailwind-settings ()
  "Return workspace settings for Tailwind CSS Language Server."
  (list :classFunctions ["cn" "clsx" "cva"]))

(defun eglotx-presets--biome-settings ()
  "Return Biome's default workspace settings object."
  (make-hash-table :test #'equal))

(defun eglotx-presets--typescript-contact-for-context
    (context interactive &optional suppress-fallback)
  "Resolve the TypeScript contact in discovery CONTEXT.

INTERACTIVE has the same meaning as in `eglotx-presets-typescript-contact'.
When SUPPRESS-FALLBACK is non-nil, return nil if the primary is unavailable so
an outer framework recipe can decide whether to preserve an earlier contact."
  (let* ((root (eglotx-presets--context-root context))
         (directories (eglotx-presets--context-directories context))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (typescript-local
          (eglotx-presets--context-local-executable
           context "typescript-language-server" bin-directories))
         (typescript
          (eglotx-presets--context-resolve-executable
           context "typescript-language-server" typescript-local))
         (eslint-local
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'eslint))
               (eglotx-presets--context-local-executable
                context "vscode-eslint-language-server" bin-directories)))
         (tailwind-local
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'tailwindcss))
               (eglotx-presets--context-local-executable
                context "tailwindcss-language-server" bin-directories)))
         (biome-local
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'biome))
               (eglotx-presets--context-local-executable
                context "biome" bin-directories)))
         (graphql-local
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'graphql))
               (eglotx-presets--context-local-executable
                context "graphql-lsp" bin-directories)))
         (graphql-executable
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'graphql))
               (eglotx-presets--context-resolve-executable
                context "graphql-lsp" graphql-local)))
         (eslint-executable
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'eslint))
               (eglotx-presets--context-resolve-executable
                context "vscode-eslint-language-server" eslint-local)))
         (tailwind-executable
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'tailwindcss))
               (eglotx-presets--context-resolve-executable
                context "tailwindcss-language-server" tailwind-local)))
         (biome-executable
          (and typescript
               (not (eglotx-presets--backend-disabled-p 'biome))
               (eglotx-presets--context-resolve-executable
                context "biome" biome-local)))
         (intent-categories
          (delq nil
                (list (and eslint-executable (not eslint-local) 'eslint)
                      (and tailwind-executable (not tailwind-local)
                           'tailwind)
                      (and biome-executable (not biome-local) 'biome))))
         (intent
          (if intent-categories
              (eglotx-presets--project-intent
               directories context intent-categories)
            (eglotx-presets--intent-create)))
         (eslint
          (and eslint-executable
               (or (eglotx-presets--intent-eslint intent) eslint-local)
               eslint-executable))
         (tailwind
          (and tailwind-executable
               (or (eglotx-presets--intent-tailwind intent)
                   tailwind-local)
               tailwind-executable))
         (biome
          (and biome-executable
               (or (eglotx-presets--intent-biome intent) biome-local)
               biome-executable))
         (graphql
          (and graphql-executable
               (eglotx-presets--graphql-config-directory context)))
         backends)
    (if (not typescript)
        (unless suppress-fallback
          (eglotx-presets--missing-contact
           interactive "typescript-language-server is not executable"
           (eglotx-presets--context-project context)))
      (push (list :name "typescript"
                  :command (list typescript "--stdio")
                  :priority 100
                  :required t)
            backends)
      (when biome
        (push (list :name "biome"
                    :command (list biome "lsp-proxy")
                    ;; Prefer the project's declared formatter over tsserver.
                    ;; Priority also makes Biome the documented fallback for
                    ;; unknown extension methods while it is active.
                    :priority 120
                    :required nil
                    :settings (eglotx-presets--biome-settings))
              backends))
      (when eslint
        (push (list :name "eslint"
                    :command (list eslint "--stdio")
                    :priority 80
                    :required nil
                    :settings (eglotx-presets--eslint-settings root))
              backends))
      (when tailwind
        (push (list :name "tailwindcss"
                    :command (list tailwind "--stdio")
                    :priority 60
                    :required nil
                    :settings (eglotx-presets--tailwind-settings))
              backends))
      (when graphql
        (push (list :name "graphql"
                    :command
                    (list graphql-executable "server" "-m" "stream"
                          "--configDir"
                          (eglotx-presets--process-path graphql))
                    :priority 50
                    :required nil
                    :only eglotx-presets--graphql-only)
              backends))
      (setq backends (nreverse backends))
      (if (= (length backends) 1)
          (plist-get (car backends) :command)
        (apply #'eglotx-contact backends)))))

;;;###autoload
(defun eglotx-presets-typescript-contact (&optional interactive project)
  "Return a project-aware Eglot contact for JavaScript, TypeScript, and React.

PROJECT defaults to the current project.  TypeScript is the required language
server for JavaScript, JSX, TypeScript, and TSX.  ESLint, Tailwind CSS, and
Biome join only when project signals or project-local server executables show
intent.  GraphQL additionally requires structural GraphQL configuration; a
local `graphql-lsp' alone is not intent.
Tailwind v4 uses its core manifest dependency as the cheap signal and leaves
CSS entrypoint discovery to the language server; legacy config markers remain
a v3 fallback.  Project-local executables win over PATH when
`eglotx-presets-prefer-project-local-servers' is non-nil.  When only
TypeScript is available, return its ordinary Eglot argv and avoid the
multiplexer entirely.

When INTERACTIVE is non-nil and TypeScript Language Server is unavailable,
prefer the contact that preceded `eglotx-presets-mode', then return nil so
Eglot can prompt for a command.  Noninteractive startup signals
`eglotx-configuration-error' only when no preserved contact applies."
  (eglotx-presets--typescript-contact-for-context
   (eglotx-presets--make-context project) interactive))

(defun eglotx-presets--angular-probe-directory (ngserver-local context)
  "Return a Node resolution base for NGSERVER-LOCAL and CONTEXT."
  (eglotx-presets--process-path
   (if ngserver-local
       (file-name-directory
        (directory-file-name (file-name-directory ngserver-local)))
     (eglotx-presets--context-root context))))

;;;###autoload
(defun eglotx-presets-angular-contact (&optional interactive project)
  "Return an Angular-aware TypeScript-only contact, or the generic contact.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (ngserver-resolution
          (unless (eglotx-presets--backend-disabled-p 'angular)
            (eglotx-presets--node-resolution
             context "ngserver" bin-directories)))
         (ngserver-local (car ngserver-resolution))
         (ngserver (cdr ngserver-resolution))
         (intent (and ngserver
                      (or ngserver-local
                          (eglotx-presets--angular-intent-p context)))))
    (if (not intent)
        (eglotx-presets--typescript-contact-for-context context interactive)
      (let* ((base-contact
             (eglotx-presets--typescript-contact-for-context
               context interactive t))
             (backends
              (eglotx-presets--contact-backends
               base-contact "typescript" 100))
             (probe-directory
              (eglotx-presets--angular-probe-directory
               ngserver-local context)))
        (if (null backends)
            (eglotx-presets--missing-contact
             interactive "typescript-language-server is not executable"
             (eglotx-presets--context-project context))
          (setq backends
                (append
                 backends
                 (list
                  (list
                   :name "angular"
                   :command
                   (list ngserver "--stdio"
                         "--tsProbeLocations" probe-directory
                         "--ngProbeLocations" probe-directory)
                   :priority 120
                   :required nil
                   :languages '("typescript")
                   :only eglotx-presets--angular-only))))
          (apply #'eglotx-contact backends))))))

;;;###autoload
(defun eglotx-presets-html-contact (&optional interactive project)
  "Return HTML Language Server plus intent-gated Tailwind CSS.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (directories (eglotx-presets--context-directories context))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (primary
          (eglotx-presets--select-node-primary
           context
           '(("html" "vscode-html-language-server" "--stdio")
             ("html" "html-languageserver" "--stdio"))
           bin-directories))
         (tailwind-resolution
          (unless (eglotx-presets--backend-disabled-p 'tailwindcss)
            (eglotx-presets--node-resolution
             context "tailwindcss-language-server" bin-directories)))
         (tailwind-local (car tailwind-resolution))
         (tailwind-executable (cdr tailwind-resolution))
         (intent
          (if (and primary tailwind-executable (not tailwind-local))
              (eglotx-presets--project-intent
               directories context '(tailwind))
            (eglotx-presets--intent-create)))
         (tailwind
          (and primary
               (or tailwind-local
                   (eglotx-presets--intent-tailwind intent))
               tailwind-executable))
         backends)
    (when primary
      (push (eglotx-presets--node-primary-backend primary 100) backends))
    (when tailwind
      (push (eglotx-presets--tailwind-backend tailwind) backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "No supported HTML language server is executable"
     (eglotx-presets--context-project context))))

;;;###autoload
(defun eglotx-presets-css-contact (&optional interactive project)
  "Return CSS Language Server plus intent-gated Biome and Tailwind CSS.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (directories (eglotx-presets--context-directories context))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (primary
          (eglotx-presets--select-node-primary
           context
           '(("css" "vscode-css-language-server" "--stdio")
             ("css" "css-languageserver" "--stdio"))
           bin-directories))
         (biome-resolution
          (unless (eglotx-presets--backend-disabled-p 'biome)
            (eglotx-presets--node-resolution
             context "biome" bin-directories)))
         (biome-local (car biome-resolution))
         (biome-executable (cdr biome-resolution))
         (tailwind-resolution
          (unless (eglotx-presets--backend-disabled-p 'tailwindcss)
            (eglotx-presets--node-resolution
             context "tailwindcss-language-server" bin-directories)))
         (tailwind-local (car tailwind-resolution))
         (tailwind-executable (cdr tailwind-resolution))
         (intent-categories
          (and primary
               (delq nil
                     (list (and biome-executable (not biome-local) 'biome)
                           (and tailwind-executable (not tailwind-local)
                                'tailwind)))))
         (intent
          (if intent-categories
              (eglotx-presets--project-intent
               directories context intent-categories)
            (eglotx-presets--intent-create)))
         (biome
          (and primary biome-executable
               (or biome-local (eglotx-presets--intent-biome intent))
               biome-executable))
         (tailwind
          (and primary tailwind-executable
               (or tailwind-local
                   (eglotx-presets--intent-tailwind intent))
               tailwind-executable))
         backends)
    (when primary
      (push (eglotx-presets--node-primary-backend primary 100) backends))
    (when biome
      (push (eglotx-presets--biome-addon-backend biome '("css")) backends))
    (when tailwind
      (push (eglotx-presets--tailwind-backend tailwind) backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "No supported CSS language server is executable"
     (eglotx-presets--context-project context))))

;;;###autoload
(defun eglotx-presets-json-contact (&optional interactive project)
  "Return JSON Language Server plus intent-gated Biome.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (directories (eglotx-presets--context-directories context))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (primary
          (eglotx-presets--select-node-primary
           context
           '(("json" "vscode-json-language-server" "--stdio")
             ("json" "vscode-json-languageserver" "--stdio")
             ("json" "json-languageserver" "--stdio"))
           bin-directories))
         (biome-resolution
          (unless (eglotx-presets--backend-disabled-p 'biome)
            (eglotx-presets--node-resolution
             context "biome" bin-directories)))
         (biome-local (car biome-resolution))
         (biome-executable (cdr biome-resolution))
         (intent
          (if (and primary biome-executable (not biome-local))
              (eglotx-presets--project-intent directories context '(biome))
            (eglotx-presets--intent-create)))
         (biome
          (and primary biome-executable
               (or biome-local (eglotx-presets--intent-biome intent))
               biome-executable))
         backends)
    (when primary
      (push (eglotx-presets--node-primary-backend primary 100) backends))
    (when biome
      (push (eglotx-presets--biome-addon-backend biome) backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "No supported JSON language server is executable"
     (eglotx-presets--context-project context))))

;;;###autoload
(defun eglotx-presets-graphql-contact (&optional interactive project)
  "Return GraphQL Language Service plus Biome for an adopted GraphQL project.

INTERACTIVE and PROJECT have the common preset-contact semantics documented by
`eglotx-presets-mode'."
  (let* ((context (eglotx-presets--make-context project))
         (directories (eglotx-presets--context-directories context))
         (bin-directories (eglotx-presets--node-bin-directories context))
         (graphql-resolution
          (eglotx-presets--node-resolution
           context "graphql-lsp" bin-directories))
         (graphql-executable (cdr graphql-resolution))
         (config-directory
          (and graphql-executable
               (eglotx-presets--graphql-config-directory context)))
         (graphql (and config-directory graphql-executable))
         (biome-resolution
          (unless (eglotx-presets--backend-disabled-p 'biome)
            (eglotx-presets--node-resolution
             context "biome" bin-directories)))
         (biome-local (car biome-resolution))
         (biome-executable (cdr biome-resolution))
         (intent
          (if (and graphql biome-executable (not biome-local))
              (eglotx-presets--project-intent directories context '(biome))
            (eglotx-presets--intent-create)))
         (biome
          (and graphql biome-executable
               (or biome-local (eglotx-presets--intent-biome intent))
               biome-executable))
         backends)
    (when graphql
      (push (list :name "graphql"
                  :command
                  (list graphql "server" "-m" "stream"
                        "--configDir"
                        (eglotx-presets--process-path config-directory))
                  :priority 100
                  :required t)
            backends))
    (when biome
      (push (eglotx-presets--biome-addon-backend biome) backends))
    (eglotx-presets--materialize-contact
     (nreverse backends) interactive
     "graphql-lsp or GraphQL project configuration is unavailable"
     (eglotx-presets--context-project context))))

(defun eglotx-presets--contact-from-lookup (lookup)
  "Return the contact proxy from version-dependent Eglot LOOKUP output."
  (if (and (proper-list-p lookup)
           (= (length lookup) 3)
           (proper-list-p (car lookup))
           (cl-every #'symbolp (car lookup))
           (or (null (nth 1 lookup)) (stringp (nth 1 lookup))))
      ;; Bundled Eglot 29: (MANAGED-MODES LANGUAGE-ID CONTACT).
      (nth 2 lookup)
    ;; Eglot 30+: (LANGUAGES . CONTACT).
    (cdr lookup)))

(defun eglotx-presets--fallback-contact (interactive project)
  "Resolve the Eglot contact preserved for INTERACTIVE and PROJECT startup."
  (when (and eglotx-presets--fallback-programs
             (not eglotx-presets--resolving-fallback))
    (let* ((eglotx-presets--resolving-fallback t)
           (eglot-server-programs eglotx-presets--fallback-programs)
           (contact
            (eglotx-presets--contact-from-lookup
             (eglot--lookup-mode major-mode))))
      (unless (memq contact eglotx-presets--contact-functions)
        (if (functionp contact)
            (pcase (cdr (func-arity contact))
              (1 (funcall contact interactive))
              (_ (funcall contact interactive project)))
          contact)))))

(defun eglotx-presets--install ()
  "Install bundled contacts without duplicating owned entries."
  (unless (and (= (length eglotx-presets--installed-entries)
                  (length eglotx-presets--entries))
               (cl-every (lambda (entry)
                           (memq entry eglot-server-programs))
                         eglotx-presets--installed-entries))
    (eglotx-presets--uninstall)
    (setq eglotx-presets--fallback-programs
          (copy-sequence eglot-server-programs))
    (setq eglotx-presets--fallback-resolver
          #'eglotx-presets--fallback-contact)
    (setq eglotx-presets--installed-entries
          (mapcar #'copy-tree eglotx-presets--entries))
    (setq eglot-server-programs
          (append eglotx-presets--installed-entries
                  eglot-server-programs))))

(defun eglotx-presets--uninstall ()
  "Remove exactly the contacts installed by this module."
  (dolist (entry eglotx-presets--installed-entries)
    (setq eglot-server-programs (delq entry eglot-server-programs)))
  (setq eglotx-presets--installed-entries nil)
  (setq eglotx-presets--fallback-programs nil)
  (when (eq eglotx-presets--fallback-resolver
            #'eglotx-presets--fallback-contact)
    (setq eglotx-presets--fallback-resolver nil)))

;;;###autoload
(define-minor-mode eglotx-presets-mode
  "Globally install the bundled project-aware Eglot contact catalog.

Enabling prepends its owned entries to `eglot-server-programs' and snapshots
the contacts they shadow.  Each contact discovers servers only when Eglot
starts a project session, delegates a missing required toolchain to the
matching snapshot contact, returns a native Eglot contact for one resolved
backend, and constructs an Eglotx facade for two or more.  INTERACTIVE may
return nil for Eglot to prompt; noninteractive resolution without a fallback
signals `eglotx-configuration-error'.  PROJECT defaults to the current project.

Disabling removes only entries owned by this mode and clears its snapshot."
  :global t
  :group 'eglotx-presets
  (if eglotx-presets-mode
      (eglotx-presets--install)
    (eglotx-presets--uninstall)))

(defun eglotx-presets-unload-function ()
  "Remove bundled contacts before unloading `eglotx-presets'."
  (eglotx-presets-mode -1)
  nil)

(provide 'eglotx-presets)
;;; eglotx-presets.el ends here
