;;; eglotx-lifecycle-test.el --- Bounded backend exit tests -*- lexical-binding: t; -*-
(require 'eglotx-test)

(defun eglotx-lifecycle-test--command (name delay)
  "Return fake backend NAME that delays exit by DELAY seconds.
A nil DELAY makes the backend ignore exit forever."
  (list
   (eglotx-test--emacs-program) "-Q" "--batch"
   "--eval" "(setq noninteractive nil)"
   "-l" eglotx-test--fake-server
   "--eval"
   (format
    (concat
     "(progn (setq noninteractive t) "
     "(advice-add 'eglotx-test--handle-notification :around "
     "(lambda (original method params) "
     "(if (string= method \"exit\") "
     "%s (funcall original method params)))) "
     "(kill-emacs (eglotx-test--main)))")
    (if delay
        (format "(progn (sleep-for %S) (funcall original method params))" delay)
      "nil"))
   "--" name))

(defun eglotx-lifecycle-test--spec (name delay)
  "Return backend NAME with DELAY before exit."
  (list :name name :command (eglotx-lifecycle-test--command name delay)))

(ert-deftest eglotx-lifecycle-delayed-exit-is-natural-and-not-in-callback ()
  (eglotx-test--with-server
      (server (list (eglotx-lifecycle-test--spec "slow-exit-alpha" 1.0)
                    (eglotx-lifecycle-test--spec "slow-exit-beta" 1.0)))
    (eglotx-test--initialize server)
    (let ((processes (eglotx-test--child-processes server))
          (started (float-time)))
      (jsonrpc-request server :shutdown nil :timeout 2)
      (jsonrpc-notify server :exit nil)
      ;; Request/notification handling must not perform the exit wait.
      (should (< (- (float-time) started) 0.5))
      (setq started (float-time))
      (jsonrpc-shutdown server t)
      (should (< (- (float-time) started) 1.5))
      (dolist (process processes)
        (should (eq (process-status process) 'exit))
        (should (= (process-exit-status process) 0))
        (should-not (buffer-live-p (process-buffer process))))
      (should-not (seq-some #'eglotx--backend-last-error
                            (eglotx--backends server)))
      (should (eq (eglotx--state server) 'dead))
      (should-not (eglotx--work-timer server)))))

(ert-deftest eglotx-lifecycle-hung-exits-share-deadline-and-report-kills ()
  (let ((eglotx-shutdown-timeout 0.15)
        warnings)
    (eglotx-test--with-server
        (server (list (eglotx-lifecycle-test--spec "hung-alpha" nil)
                      (eglotx-lifecycle-test--spec "hung-beta" nil)
                      (eglotx-lifecycle-test--spec "hung-gamma" nil)))
      (eglotx-test--initialize server)
      (jsonrpc-request server :shutdown nil :timeout 2)
      (jsonrpc-notify server :exit nil)
      (let ((started (float-time))
            (processes (eglotx-test--child-processes server)))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _args) (push message warnings))))
          (jsonrpc-shutdown server nil))
        (should (< (- (float-time) started) 0.6))
        (should (= (length warnings) 3))
        (dolist (backend (eglotx--backends server))
          (should (string-match-p "force terminating"
                                  (eglotx--backend-last-error backend))))
        (dolist (process processes)
          (should-not (process-live-p process))
          (should-not (zerop (process-exit-status process))))
        ;; Escalating an already-complete shutdown must still release buffers.
        (jsonrpc-shutdown server t)
        (dolist (process processes)
          (should-not (buffer-live-p (process-buffer process))))))))

(ert-deftest eglotx-lifecycle-unrecoverable-failure-skips-exit-grace ()
  (let ((eglotx-shutdown-timeout 10))
    (eglotx-test--with-server
        (server (list (eglotx-lifecycle-test--spec "hung-alpha" nil)
                      (eglotx-lifecycle-test--spec "hung-beta" nil)))
      (eglotx-test--initialize server)
      (setf (eglotx--state server) 'failed)
      (let ((started (float-time)))
        (jsonrpc-shutdown server t)
        (should (< (- (float-time) started) 0.5))
        (should (eq (eglotx--state server) 'dead))
        (should-not (seq-some #'process-live-p
                              (eglotx-test--child-processes server)))))))
(provide 'eglotx-lifecycle-test)
