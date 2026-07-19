;;; eglotx-packages.el --- Initialize Eglotx test dependencies  -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Initialize package.el for every `emacs -Q' development command.  When
;; EGLOTX_INSTALL_DEPS is set, install missing minimum dependencies from GNU
;; ELPA.  A normal `make check' performs no network access and fails early with
;; a useful error if its Emacs does not already provide the required versions.

;;; Code:

(require 'package)
(require 'seq)

(defconst eglotx-ci--minimum-packages
  '((jsonrpc . (1 0 29))
    (eglot . (1 24)))
  "Minimum package versions required to build and test Eglotx.")

(defconst eglotx-ci--corfu-e2e-packages
  '((corfu . nil)
    (orderless . nil))
  "Optional packages required by the real Corfu E2E path.")

(defun eglotx-ci--package-ready-p (spec)
  "Return non-nil when package SPEC is installed at its minimum version."
  (package-installed-p (car spec) (cdr spec)))

(package-initialize)

(let ((required
       (append eglotx-ci--minimum-packages
               (when (getenv "EGLOTX_E2E_CORFU")
                 eglotx-ci--corfu-e2e-packages))))
  (when (and (getenv "EGLOTX_INSTALL_DEPS")
             (not (seq-every-p #'eglotx-ci--package-ready-p required)))
    (setq package-archives
          '(("gnu" . "https://elpa.gnu.org/packages/")))
    (package-refresh-contents)
    (let ((package-install-upgrade-built-in t))
      (dolist (spec required)
        (unless (eglotx-ci--package-ready-p spec)
          (package-install (car spec))))))
  (dolist (spec required)
    (unless (eglotx-ci--package-ready-p spec)
      (if (cdr spec)
          (error "Eglotx needs %s %s or newer; run `make deps'"
                 (car spec) (package-version-join (cdr spec)))
        (error "Eglotx Corfu E2E needs %s; run `make deps-corfu-e2e'"
               (car spec))))))

(when (getenv "EGLOTX_E2E_CORFU")
  (require 'corfu)
  (require 'orderless)
  (unless (fboundp 'corfu--capf-wrapper)
    (error "Corfu E2E needs a release providing corfu--capf-wrapper")))

(provide 'eglotx-packages)
;;; eglotx-packages.el ends here
