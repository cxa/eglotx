;;; eglotx-symbol-test.el --- Symbol response validation -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'eglotx-test)

(defun eglotx-symbol-test--range (line character end-line end-character)
  "Build an LSP range from LINE, CHARACTER, END-LINE, END-CHARACTER."
  (list :start (list :line line :character character)
        :end (list :line end-line :character end-character)))

(defun eglotx-symbol-test--symbol (name &optional range selection)
  "Build a DocumentSymbol named NAME with RANGE and SELECTION."
  (let ((range (or range (eglotx-symbol-test--range 0 0 2 0))))
    (list :name name :kind 12 :range range
          :selectionRange (or selection range))))

(defun eglotx-symbol-test--command (name)
  "Return a fake LSP argv serving controlled symbol responses for NAME."
  (list
   (eglotx-test--emacs-program) "-Q" "--batch"
   "--eval" "(setq noninteractive nil)"
   "-l" eglotx-test--fake-server
   "--eval"
   (concat
    "(progn (setq noninteractive t) "
    "(advice-add 'eglotx-test--capabilities :filter-return "
    "(lambda (caps) (append caps '(:documentSymbolProvider t)))) "
    "(advice-add 'eglotx-test--handle-request-now :around "
    "(lambda (old id method params) "
    "(if (string= method \"textDocument/documentSymbol\") "
    "(eglotx-test--send-result id "
    "(plist-get params (if (string-prefix-p \"bad\" eglotx-test--name) :bad :good))) "
    "(funcall old id method params)))) "
    "(kill-emacs (eglotx-test--main)))")
   "--" name))

(defun eglotx-symbol-test--spec (name)
  "Build a fake backend spec for NAME."
  (list :name name :command (eglotx-symbol-test--command name)))

(defun eglotx-symbol-test--params (bad good)
  "Build document-symbol request parameters with BAD and GOOD fixture results."
  (list :textDocument '(:uri "file:///eglotx-test/symbols.el")
        :bad bad :good good))

(ert-deftest eglotx-symbol-reversed-range-is-backend-error-and-recovers ()
  (eglotx-test--with-server
      (server (list (eglotx-symbol-test--spec "bad-symbols")
                    (eglotx-symbol-test--spec "good-symbols")))
    (eglotx-test--initialize server)
    (let* ((bad (vector (eglotx-symbol-test--symbol
                         "broken" (eglotx-symbol-test--range 4 0 2 3))))
           (good (vector (eglotx-symbol-test--symbol "valid")))
           (error (should-error
                   (jsonrpc-request server :textDocument/documentSymbol
                                    (eglotx-symbol-test--params bad good)
                                    :timeout 3)
                   :type 'jsonrpc-error)))
      (should (equal (alist-get 'jsonrpc-error-code (cddr error)) -32603))
      (should (string-match-p "Backend bad-symbols.*broken.*reversed range"
                              (error-message-string error)))
      (should (= (hash-table-count (eglotx--requests server)) 0))
      ;; Malformed symbols are a request error, not a reason to kill a backend.
      (should (equal
               (jsonrpc-request server :textDocument/documentSymbol
                                (eglotx-symbol-test--params good good) :timeout 3)
               good))
      (should (jsonrpc-request server :textDocument/hover
                              '(:textDocument (:uri "file:///eglotx-test/symbols.el")
                                :position (:line 0 :character 0)) :timeout 3)))))

(ert-deftest eglotx-symbol-nested-selection-and-flat-ranges-rejected ()
  (eglotx-test--with-server
      (server (list (eglotx-symbol-test--spec "bad-symbols")
                    (eglotx-symbol-test--spec "good-symbols")))
    (eglotx-test--initialize server)
    (let ((valid (eglotx-symbol-test--range 0 0 4 0)))
      (dolist
          (bad
           (list
            (vector (append (eglotx-symbol-test--symbol "parent" valid)
                            (list :children
                                  (vector (eglotx-symbol-test--symbol
                                           "nested" valid
                                           (eglotx-symbol-test--range 2 8 2 3))))))
            (vector (eglotx-symbol-test--symbol
                     "outside" valid (eglotx-symbol-test--range 4 0 5 0)))
            (vector (list :name "flat" :kind 12
                          :location (list :uri "file:///eglotx-test/symbols.el"
                                          :range (eglotx-symbol-test--range 1 9 1 2))))
            (vector (eglotx-symbol-test--symbol
                     "negative" (eglotx-symbol-test--range -1 0 1 0)))
            (vector (append (eglotx-symbol-test--symbol "bad-children")
                            '(:children "not an array")))))
        (let ((error (should-error
                      (jsonrpc-request server :textDocument/documentSymbol
                                       (eglotx-symbol-test--params bad []) :timeout 3)
                      :type 'jsonrpc-error)))
          (should (string-match-p "Backend bad-symbols returned malformed"
                                  (error-message-string error))))))))

(ert-deftest eglotx-symbol-valid-shapes-null-and-empty-pass-through ()
  (eglotx-test--with-server
      (server (list (eglotx-symbol-test--spec "bad-symbols")
                    (eglotx-symbol-test--spec "good-symbols")))
    (eglotx-test--initialize server)
    (dolist (payload
             (list nil []
                   (vector (eglotx-symbol-test--symbol
                            "point" (eglotx-symbol-test--range 0 0 0 0)))
                   (vector (list :name "flat" :kind 12
                                 :location (list :uri "file:///eglotx-test/symbols.el"
                                                 :range (eglotx-symbol-test--range 0 8 1 0))))
                   (vector (append (eglotx-symbol-test--symbol "parent")
                                   (list :children
                                         (vector (eglotx-symbol-test--symbol "child")))))))
      (should (equal (jsonrpc-request server :textDocument/documentSymbol
                                     (eglotx-symbol-test--params payload []) :timeout 3)
                     payload)))))

(ert-deftest eglotx-symbol-validation-keeps-normal-partial-result-policy ()
  ;; Default document-symbol routing is exclusive. Exercise the ordinary
  ;; request combiner with two legs without altering the shipped policy.
  (let ((eglotx--method-policy-table (copy-hash-table eglotx--method-policy-table)))
    (puthash :textDocument/documentSymbol
             '(:capability :documentSymbolProvider :route collect :merge first)
             eglotx--method-policy-table)
    (eglotx-test--with-server
        (server (list (eglotx-symbol-test--spec "bad-symbols")
                      (eglotx-symbol-test--spec "good-symbols")))
      (eglotx-test--initialize server)
      (let ((bad (vector (eglotx-symbol-test--symbol
                         "broken" (eglotx-symbol-test--range 4 0 2 3))))
            (good (vector (eglotx-symbol-test--symbol "healthy"))))
        (should (equal (jsonrpc-request server :textDocument/documentSymbol
                                       (eglotx-symbol-test--params bad good) :timeout 3)
                       good))
        (should (= (hash-table-count (eglotx--requests server)) 0))))))

(ert-deftest eglotx-symbol-validator-is-iterative-and-preserves-input ()
  ;; A pure-helper test avoids the JSON encoder's unrelated nesting limit.
  (let ((value (vector (eglotx-symbol-test--symbol "leaf"))))
    (dotimes (_ 2000)
      (setq value (vector (append (eglotx-symbol-test--symbol "parent")
                                  (list :children value)))))
    (should (eq value (eglotx--validate-document-symbols value))))
  (let* ((range (eglotx-symbol-test--range 8 2 4 0))
         (payload (vector (eglotx-symbol-test--symbol "bad" range)))
         (copy (copy-tree payload t)))
    (should-error (eglotx--validate-document-symbols payload) :type 'eglotx-error)
    (should (equal payload copy))))

(defvar eglotx-symbol-test--in-backend-callback nil)

(ert-deftest eglotx-symbol-validation-is-outside-backend-callback ()
  (let ((record-response (symbol-function 'eglotx--record-response))
        (validate (symbol-function 'eglotx--validate-document-symbols))
        (callbacks 0)
        contexts)
    (cl-letf (((symbol-function 'eglotx--record-response)
               (lambda (&rest args)
                 (cl-incf callbacks)
                 (let ((eglotx-symbol-test--in-backend-callback t))
                   (apply record-response args))))
              ((symbol-function 'eglotx--validate-document-symbols)
               (lambda (payload)
                 (push (list eglotx-symbol-test--in-backend-callback
                             jsonrpc--in-process-filter)
                       contexts)
                 (funcall validate payload))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "bad-symbols")
                        (eglotx-symbol-test--spec "good-symbols")))
        (eglotx-test--initialize server)
        (let ((valid (vector (eglotx-symbol-test--symbol "valid"))))
          (should (equal
                   (jsonrpc-request server :textDocument/documentSymbol
                                    (eglotx-symbol-test--params valid valid)
                                    :timeout 3)
                   valid)))
        (should (> callbacks 0))
        (should (equal contexts '((nil nil))))))))

(ert-deftest eglotx-symbol-cancellation-before-finalizer-skips-validation ()
  (let ((finish-ready (symbol-function 'eglotx--finish-ready-request))
        (validate (symbol-function 'eglotx--validate-document-symbols))
        (validations 0))
    (cl-letf (((symbol-function 'eglotx--finish-ready-request)
               (lambda (server request &optional urgent-p)
                 (funcall finish-ready server request urgent-p)
                 (when (eq (eglotx--request-method request)
                           :textDocument/documentSymbol)
                   ;; The response is recorded and finalization queued, but
                   ;; the client cancels before the queue processes it.
                   (eglotx--cancel-request
                    server (eglotx--request-id request) t))))
              ((symbol-function 'eglotx--validate-document-symbols)
               (lambda (payload)
                 (cl-incf validations)
                 (funcall validate payload))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "bad-symbols")
                        (eglotx-symbol-test--spec "good-symbols")))
        (eglotx-test--initialize server)
        (let* ((valid (vector (eglotx-symbol-test--symbol "valid")))
               (error (should-error
                       (jsonrpc-request server :textDocument/documentSymbol
                                        (eglotx-symbol-test--params valid valid)
                                        :timeout 3)
                       :type 'jsonrpc-error)))
          (should (equal (alist-get 'jsonrpc-error-code (cddr error)) -32800)))
        (should (= validations 0))
        (should (= (hash-table-count (eglotx--requests server)) 0))))))

(provide 'eglotx-symbol-test)
;;; eglotx-symbol-test.el ends here
