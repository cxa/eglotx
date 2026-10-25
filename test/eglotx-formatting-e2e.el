;;; eglotx-formatting-e2e.el --- Actual formatting E2E assertion -*- lexical-binding: t; -*-

;; This helper is only used by opt-in real-server tests.

;;; Code:

(require 'eglot)

(defun eglotx-formatting-e2e-assert ()
  "Require a real formatting edit and an idempotent second pass.
The current buffer must already be managed by Eglot.  Changes are kept
in memory only; the calling fixture is responsible for discarding them."
  ;; Surplus final blank lines are valid in all the fixture languages.
  ;; They guarantee an edit even if the checked-in source is formatted.
  (goto-char (point-max))
  (insert "\n\n")
  (eglot--signal-textDocument/didChange)
  (let ((before (buffer-string)))
    (eglot-format-buffer)
    (when (equal before (buffer-string))
      (error "Formatting returned no effective edit")))
  (eglot--signal-textDocument/didChange)
  (let ((formatted (buffer-string)))
    (eglot-format-buffer)
    (unless (equal formatted (buffer-string))
      (error "Formatting was not idempotent")))
  (eglot--signal-textDocument/didChange)
  t)

(provide 'eglotx-formatting-e2e)
;;; eglotx-formatting-e2e.el ends here
