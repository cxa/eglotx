;;; eglotx-formatting-e2e-test.el --- Check formatting E2E guards -*- lexical-binding: t; -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eglotx-formatting-e2e)

(ert-deftest eglotx-formatting-e2e-requires-effective-edit ()
  (with-temp-buffer
    (insert "export const value = 1;\n")
    (cl-letf (((symbol-function 'eglot--signal-textDocument/didChange)
               #'ignore)
              ((symbol-function 'eglot-format-buffer) #'ignore))
      (should-error (eglotx-formatting-e2e-assert)))))

(ert-deftest eglotx-formatting-e2e-requires-idempotence ()
  (with-temp-buffer
    (insert "export const value = 1;\n")
    (cl-letf (((symbol-function 'eglot--signal-textDocument/didChange)
               #'ignore)
              ((symbol-function 'eglot-format-buffer)
               (lambda () (goto-char (point-max)) (insert "\n"))))
      (should-error (eglotx-formatting-e2e-assert)))))

(ert-deftest eglotx-formatting-e2e-accepts-idempotent-edit ()
  (with-temp-buffer
    (insert "export const value = 1;\n")
    (let ((calls 0))
      (cl-letf (((symbol-function 'eglot--signal-textDocument/didChange)
                 #'ignore)
                ((symbol-function 'eglot-format-buffer)
                 (lambda ()
                   (cl-incf calls)
                   (goto-char (point-max))
                   (skip-chars-backward "\n")
                   (delete-region (point) (point-max))
                   (insert "\n"))))
        (should (eglotx-formatting-e2e-assert))
        (should (= calls 2))
        (should (equal (buffer-string) "export const value = 1;\n"))))))

;;; eglotx-formatting-e2e-test.el ends here
