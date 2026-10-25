;;; eglotx-transport-test.el --- Low-latency process reads -*- lexical-binding: t; -*-
(require 'eglotx-test)

(ert-deftest eglotx-transport-disables-adaptive-reads-only-for-owned-processes ()
  (let ((process-adaptive-read-buffering t)
        (original (symbol-function 'make-process))
        observed)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (push process-adaptive-read-buffering observed)
                 (apply original args))))
      (eglotx-test--with-server
          (server (list (eglotx-test--spec "alpha")
                        (eglotx-test--spec "beta")))
        (should (eq process-adaptive-read-buffering t))
        (should (= (length observed) 2))
        (should (equal observed '(nil nil)))
        (eglotx-test--initialize server)
        (should
         (plist-get
          (jsonrpc-request
           server :textDocument/completion
           '(:textDocument (:uri "file:///eglotx-test/transport.el")
             :position (:line 0 :character 0)) :timeout 3)
          :items))))
    (should (eq process-adaptive-read-buffering t))))

(provide 'eglotx-transport-test)
