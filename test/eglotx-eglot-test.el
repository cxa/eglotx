;;; eglotx-eglot-test.el --- Tests for the Eglot adapter  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eglotx)
(require 'eglotx-eglot)

(defconst eglotx-eglot-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute repository root used by the adapter tests.")

(ert-deftest eglotx-preset-engine-loads-eglot-adapter ()
  (with-temp-buffer
    (let* ((program (expand-file-name invocation-name invocation-directory))
           (packages
            (expand-file-name "ci/eglotx-packages.el"
                              eglotx-eglot-test--root))
           (form
            (concat
             "(progn (require 'eglotx) "
             "(when (featurep 'eglotx-eglot) (error \"loaded eagerly\")) "
             "(require 'eglotx-preset-engine) "
             "(eglotx-contact '(\"one\") '(\"two\")) "
             "(unless (featurep 'eglotx-eglot) "
             "  (error \"preset engine did not load adapter\")))"))
           (status
            (call-process
             program nil t nil "-Q" "--batch"
             "--eval" "(setq load-prefer-newer t)"
             "-l" packages "-L" eglotx-eglot-test--root
             "--eval" form)))
      (unless (equal status 0)
        (ert-fail
         (format "Adapter autoload subprocess failed (%S): %s"
                 status (buffer-string)))))))

(ert-deftest eglotx-eglot-advertises-resolved-text-edits ()
  (let (server)
    (unwind-protect
        (cl-letf (((symbol-function 'eglotx--start-backend)
                   (lambda (_server _backend) nil))
                  ((symbol-function 'eglot--trampish-p)
                   (lambda (_server) nil)))
          (setq server
                (make-instance
                 'eglotx-server
                 :backend-specs
                 '((:name "one" :command ("one"))
                   (:name "two" :command ("two")))))
          (let* ((capabilities (eglot-client-capabilities server))
                 (text-document
                  (plist-get capabilities :textDocument))
                 (completion (plist-get text-document :completion))
                 (completion-item
                  (plist-get completion :completionItem))
                 (resolve-support
                  (plist-get completion-item :resolveSupport))
                 (properties
                  (append (plist-get resolve-support :properties) nil)))
            (dolist (property '("documentation" "additionalTextEdits"
                                "textEdit"))
              (should (member property properties)))
            (should (= (cl-count "textEdit" properties :test #'equal) 1))))
      (when server
        (when-let* ((process (jsonrpc--process server)))
          (when (process-live-p process)
            (set-process-sentinel process #'ignore)
            (delete-process process)))))))

(provide 'eglotx-eglot-test)
;;; eglotx-eglot-test.el ends here
