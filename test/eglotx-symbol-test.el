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
    "(unless (string-prefix-p \"hanging\" eglotx-test--name) "
    "(eglotx-test--send-result id "
    "(plist-get params (if (string-prefix-p \"bad\" eglotx-test--name) :bad :good)))) "
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
            "not an array"
            [nil]
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
        (validate (symbol-function 'eglotx--validate-symbol-chunk))
        (callbacks 0)
        contexts)
    (cl-letf (((symbol-function 'eglotx--record-response)
               (lambda (&rest args)
                 (cl-incf callbacks)
                 (let ((eglotx-symbol-test--in-backend-callback t))
                   (apply record-response args))))
              ((symbol-function 'eglotx--validate-symbol-chunk)
               (lambda (walker)
                 (push (list eglotx-symbol-test--in-backend-callback
                             jsonrpc--in-process-filter)
                       contexts)
                 (funcall validate walker))))
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

(ert-deftest eglotx-symbol-cancellation-before-first-chunk-skips-validation ()
  (let ((record-response (symbol-function 'eglotx--record-response))
        (validate (symbol-function 'eglotx--validate-symbol-chunk))
        (validations 0))
    (cl-letf (((symbol-function 'eglotx--record-response)
               (lambda (server id backend success payload)
                 (funcall record-response server id backend success payload)
                 (when-let* ((request (gethash id (eglotx--requests server)))
                             ((eq (eglotx--request-method request)
                                  :textDocument/documentSymbol)))
                   ;; The response is recorded and finalization queued, but
                   ;; the client cancels before the queue processes it.
                   (eglotx--cancel-request
                    server (eglotx--request-id request) t))))
              ((symbol-function 'eglotx--validate-symbol-chunk)
               (lambda (walker)
                 (cl-incf validations)
                 (funcall validate walker))))
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

(ert-deftest eglotx-symbol-wide-and-deep-walks-have-bounded-chunks ()
  (let* ((eglotx-symbol-chunk-size 4)
         (leaf (eglotx-symbol-test--symbol "leaf"))
         (wide (vector (append (eglotx-symbol-test--symbol "parent")
                               (list :children (make-vector 10000 leaf)))))
         (deep (vector leaf))
         (validate (symbol-function 'eglotx--validate-document-symbol)))
    (dotimes (_ 1000)
      (setq deep (vector (append (eglotx-symbol-test--symbol "parent")
                                 (list :children deep)))))
    (dolist (payload (list wide deep))
      (let ((walker (eglotx--make-symbol-walker payload))
            (chunks 0)
            (visited 0))
        (cl-letf (((symbol-function 'eglotx--validate-document-symbol)
                   (lambda (symbol)
                     (cl-incf visited)
                     (funcall validate symbol))))
          (while (progn
                   (setq visited 0)
                   (cl-incf chunks)
                   (let ((done (eglotx--validate-symbol-chunk walker)))
                     (should (<= visited eglotx-symbol-chunk-size))
                     (not done)))))
        (should (> chunks 100))))))

(ert-deftest eglotx-symbol-object-shape-is-checked-once ()
  (let ((symbol (eglotx-symbol-test--symbol "function"))
        (object-p (symbol-function 'eglotx--json-object-p))
        (checks 0))
    (cl-letf (((symbol-function 'eglotx--json-object-p)
               (lambda (value)
                 (when (eq value symbol) (cl-incf checks))
                 (funcall object-p value))))
      (eglotx--validate-document-symbols (vector symbol)))
    (should (= checks 1))))

(ert-deftest eglotx-symbol-chunks-yield-to-other-facade-work ()
  (let ((eglotx-symbol-chunk-size 2)
        (worker (symbol-function 'eglotx--validate-symbol-response))
        (chunks 0)
        interleaved timer)
    (cl-letf (((symbol-function 'eglotx--validate-symbol-response)
               (lambda (server id backend token)
                 (cl-incf chunks)
                 (if timer
                     (should (eq timer (eglotx--work-timer server)))
                   (setq timer (eglotx--work-timer server)))
                 (when (= chunks 1)
                   (eglotx--enqueue-work
                    server (lambda () (setq interleaved chunks))))
                 (funcall worker server id backend token))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "good-symbols")
                        (eglotx-symbol-test--spec "unused-symbols")))
        (eglotx-test--initialize server)
        (let ((payload (make-vector 20 (eglotx-symbol-test--symbol "valid"))))
          (should (equal
                   (jsonrpc-request server :textDocument/documentSymbol
                                    (eglotx-symbol-test--params nil payload) :timeout 3)
                   payload)))
        (should (= interleaved 1))
        (should (> chunks 1))
        (should-not (memq timer timer-list))
        (should-not (eglotx--work-timer server))
        (should-not (eglotx--work-running-p server))))))

(ert-deftest eglotx-symbol-validation-keeps-cancellation-and-deadline-ownership ()
  (dolist (action '(cancel deadline shutdown))
    (let ((eglotx-symbol-chunk-size 2)
          (worker (symbol-function 'eglotx--validate-symbol-response))
          (drain (symbol-function 'eglotx--drain-work))
          (turns 0)
          (chunks 0)
          request)
      (cl-letf (((symbol-function 'eglotx--drain-work)
                 (lambda (server)
                   (unless (eglotx--work-running-p server) (cl-incf turns))
                   (funcall drain server)))
                ((symbol-function 'eglotx--validate-symbol-response)
                 (lambda (server id backend token)
                   (let ((live (gethash id (eglotx--requests server))))
                     (when live (cl-incf chunks))
                     (funcall worker server id backend token)
                     (when (and live (= chunks 1))
                       (setq request (gethash id (eglotx--requests server)))
                       (should request)
                       (should-not (eglotx--request-completed request))
                       (should (memq (eglotx--request-timer request) timer-list))
                       ;; Interrupt before the next validation chunk.  A
                       ;; zero-delay timer can lose to the queue's repeating
                       ;; timer and run only after validation is complete.
                       (let ((chunk-turn turns))
                         (eglotx--enqueue-urgent-work
                          server
                          (lambda ()
                            (should (> turns chunk-turn))
                            (should (eq request (gethash id (eglotx--requests server))))
                            (should (gethash backend (eglotx--request-symbol-validations request)))
                            (pcase action
                              ('cancel (jsonrpc-notify server :$/cancelRequest (list :id id)))
                              ('deadline (eglotx--request-deadline server id))
                              ('shutdown (jsonrpc-shutdown server t)))))))))))
        (eglotx-test--with-server
         (server (list (eglotx-symbol-test--spec "good-symbols")
                       (eglotx-symbol-test--spec "unused-symbols")))
         (eglotx-test--initialize server)
         (let* ((payload (make-vector 20 (eglotx-symbol-test--symbol "valid")))
                (error (should-error
                        (jsonrpc-request server :textDocument/documentSymbol
                                         (eglotx-symbol-test--params nil payload)
                                         :timeout 3)
                        :type 'jsonrpc-error)))
           (should (equal (alist-get 'jsonrpc-error-code (cddr error))
                          (pcase action ('cancel -32800) ('deadline -32002) (_ -1)))))
         (should (eglotx-test--wait-until
                  (lambda () (null (eglotx--work-head server))) 1.0))
         (should (= chunks 1))
         (should (= (hash-table-count (eglotx--requests server)) 0))
         (should-not (eglotx--request-symbol-validations request))
         (should-not (memq (eglotx--request-timer request) timer-list)))))))

(ert-deftest eglotx-symbol-cancellation-after-validation-before-reply-is-terminal ()
  (let ((finish (symbol-function 'eglotx--finish-ready-request))
        request)
    (cl-letf (((symbol-function 'eglotx--finish-ready-request)
               (lambda (server ready &optional urgent)
                 (when (eq (eglotx--request-method ready) :textDocument/documentSymbol)
                   (setq request ready)
                   (should (eglotx--request-ready-p request))
                   (jsonrpc-notify server :$/cancelRequest
                                   (list :id (eglotx--request-id request))))
                 (funcall finish server ready urgent))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "good-symbols")
                        (eglotx-symbol-test--spec "unused-symbols")))
        (eglotx-test--initialize server)
        (let* ((payload (vector (eglotx-symbol-test--symbol "valid")))
               (error (should-error
                       (jsonrpc-request server :textDocument/documentSymbol
                                        (eglotx-symbol-test--params nil payload) :timeout 3)
                       :type 'jsonrpc-error)))
          (should (= (alist-get 'jsonrpc-error-code (cddr error)) -32800)))
        (should (eglotx--request-cancelled request))
        (should (eglotx--request-completed request))
        (should-not (eglotx--request-symbol-validations request))
        (should-not (memq (eglotx--request-timer request) timer-list))
        (should (zerop (hash-table-count (eglotx--requests server))))))))

(ert-deftest eglotx-symbol-validated-success-survives-pending-sibling-deadline ()
  (let ((eglotx--method-policy-table (copy-hash-table eglotx--method-policy-table)))
    (puthash :textDocument/documentSymbol
             '(:capability :documentSymbolProvider :route collect :merge first)
             eglotx--method-policy-table)
    (eglotx-test--with-server
        (server (list (eglotx-symbol-test--spec "good-symbols")
                      (eglotx-symbol-test--spec "hanging-symbols")))
      (eglotx-test--initialize server)
      (dolist (backend (eglotx--backends server))
        (setf (eglotx--backend-request-timeout backend) 0.1))
      (let ((payload (vector (eglotx-symbol-test--symbol "valid"))))
        (should (equal
                 (jsonrpc-request server :textDocument/documentSymbol
                                  (eglotx-symbol-test--params nil payload) :timeout 3)
                 payload)))
      (should (= (hash-table-count (eglotx--requests server)) 0)))))

(ert-deftest eglotx-symbol-deadline-before-validation-or-after-validation-is-terminal ()
  (dolist (phase '(before after))
    (let ((record (symbol-function 'eglotx--record-response))
          (finish (symbol-function 'eglotx--finish-ready-request))
          (deliver (symbol-function 'eglotx--deliver-message-now))
          (replies 0)
          expired)
      (cl-letf (((symbol-function 'eglotx--record-response)
                 (lambda (server id backend success payload)
                   (funcall record server id backend success payload)
                   (when-let* ((request (gethash id (eglotx--requests server)))
                               ((eq phase 'before))
                               ((eq (eglotx--request-method request)
                                    :textDocument/documentSymbol)))
                     (eglotx--request-deadline server id))))
                ((symbol-function 'eglotx--finish-ready-request)
                 (lambda (server request &optional urgent)
                   (when (and (eq phase 'after) (not expired)
                              (eq (eglotx--request-method request) :textDocument/documentSymbol))
                     (setq expired t)
                     (eglotx--request-deadline server (eglotx--request-id request)))
                   (funcall finish server request urgent)))
                ((symbol-function 'eglotx--deliver-message-now)
                 (lambda (server message shutdown)
                   (when (> (plist-get message :id) 1) (cl-incf replies))
                   (funcall deliver server message shutdown))))
        (eglotx-test--with-server
            (server (list (eglotx-symbol-test--spec "good-symbols")
                          (eglotx-symbol-test--spec "unused-symbols")))
          (eglotx-test--initialize server)
          (let ((payload (vector (eglotx-symbol-test--symbol "valid"))))
            (if (eq phase 'before)
                (let ((error (should-error
                              (jsonrpc-request server :textDocument/documentSymbol
                                               (eglotx-symbol-test--params nil payload) :timeout 3)
                              :type 'jsonrpc-error)))
                  (should (= (alist-get 'jsonrpc-error-code (cddr error)) -32002)))
              (should (equal
                       (jsonrpc-request server :textDocument/documentSymbol
                                        (eglotx-symbol-test--params nil payload) :timeout 3)
                       payload))))
          (should (eglotx-test--wait-until
                   (lambda () (null (eglotx--work-head server))) 1.0))
          (should (= replies 1))
          (should (= (hash-table-count (eglotx--requests server)) 0)))))))

(ert-deftest eglotx-symbol-validated-success-survives-sibling-validation-deadline ()
  (let ((eglotx--method-policy-table (copy-hash-table eglotx--method-policy-table))
        (eglotx-symbol-chunk-size 2)
        (worker (symbol-function 'eglotx--validate-symbol-response))
        expired)
    (puthash :textDocument/documentSymbol
             '(:capability :documentSymbolProvider :route collect :merge first)
             eglotx--method-policy-table)
    (cl-letf (((symbol-function 'eglotx--validate-symbol-response)
               (lambda (server id backend token)
                 (funcall worker server id backend token)
                 (when-let* ((request (gethash id (eglotx--requests server)))
                             (validations (eglotx--request-symbol-validations request))
                             ((not expired))
                             ((zerop (hash-table-count (eglotx--request-pending request))))
                             ((= (hash-table-count validations) 1))
                             (good (eglotx-test--backend server "good-symbols"))
                             ((gethash good (eglotx--request-results request)))
                             ((not (gethash good validations))))
                   (setq expired t)
                   (eglotx--request-deadline server id)))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "bad-symbols")
                        (eglotx-symbol-test--spec "good-symbols")))
        (eglotx-test--initialize server)
        (let ((large (make-vector 1000 (eglotx-symbol-test--symbol "pending")))
              (small (vector (eglotx-symbol-test--symbol "checked"))))
          (should (equal
                   (jsonrpc-request server :textDocument/documentSymbol
                                    (eglotx-symbol-test--params large small) :timeout 3)
                   small)))
        (should expired)
        (should (= (hash-table-count (eglotx--requests server)) 0))))))

(ert-deftest eglotx-symbol-stale-workers-and-finalizers-ignore-reused-ids ()
  (eglotx-test--with-server
      (server (list (eglotx-symbol-test--spec "good-symbols")
                    (eglotx-symbol-test--spec "unused-symbols")))
    (eglotx-test--initialize server)
    (let* ((backend (car (eglotx--backends server)))
           (old-token (make-symbol "old"))
           (token (make-symbol "new"))
           (validations (make-hash-table :test #'eq))
           (request (eglotx--request-create
                     :id 777 :method :textDocument/documentSymbol
                     :pending (make-hash-table :test #'eq)
                     :symbol-validations validations :symbol-validation-token token)))
      (puthash backend 'pending validations)
      (puthash 777 request (eglotx--requests server))
      (eglotx--validate-symbol-response server 777 backend old-token)
      (eglotx--finish-request-by-id server 777 old-token)
      (should (eq request (gethash 777 (eglotx--requests server))))
      (should (eq (gethash backend validations) 'pending))
      (should-not (eglotx--request-completed request))
      (should-not (eglotx--work-head server))
      (eglotx--cancel-request server 777))))

(ert-deftest eglotx-symbol-backend-exit-during-validation-respects-required-policy ()
  (dolist (required '(nil t))
    (let ((eglotx-symbol-chunk-size 2)
          (worker (symbol-function 'eglotx--validate-symbol-response))
          exited)
      (cl-letf (((symbol-function 'eglotx--validate-symbol-response)
                 (lambda (server id backend token)
                   (funcall worker server id backend token)
                   (unless exited
                     (setq exited t)
                     (delete-process (jsonrpc--process
                                      (eglotx--backend-connection backend)))))))
        (eglotx-test--with-server
            (server (list (append (eglotx-symbol-test--spec "good-symbols")
                                  (list :required required :priority 100))
                          (eglotx-symbol-test--spec "unused-symbols")))
          (eglotx-test--initialize server)
          (let ((payload (make-vector 20 (eglotx-symbol-test--symbol "valid"))))
            (if required
                (should-error
                 (jsonrpc-request server :textDocument/documentSymbol
                                  (eglotx-symbol-test--params nil payload) :timeout 3)
                 :type 'jsonrpc-error)
              (should (equal
                       (jsonrpc-request server :textDocument/documentSymbol
                                        (eglotx-symbol-test--params nil payload) :timeout 3)
                       payload))
              (should (jsonrpc-running-p server))))
          (should exited)
          (should (= (hash-table-count (eglotx--requests server)) 0)))))))

(ert-deftest eglotx-symbol-response-keeps-configured-order-and-payload-identity ()
  (let ((eglotx--method-policy-table (copy-hash-table eglotx--method-policy-table))
        (eglotx-symbol-chunk-size 2)
        (record (symbol-function 'eglotx--record-response))
        wire-result)
    (puthash :textDocument/documentSymbol
             '(:capability :documentSymbolProvider :route collect :merge first)
             eglotx--method-policy-table)
    (cl-letf (((symbol-function 'eglotx--record-response)
               (lambda (server id backend success payload)
                 (when (and (equal (eglotx--backend-name backend) "bad-symbols")
                            (vectorp payload))
                   (setq wire-result payload))
                 (funcall record server id backend success payload))))
      (eglotx-test--with-server
          (server (list (eglotx-symbol-test--spec "bad-symbols")
                        (eglotx-symbol-test--spec "good-symbols")))
        (eglotx-test--initialize server)
        (let* ((preferred (make-vector 30 (eglotx-symbol-test--symbol "preferred")))
               (other (vector (eglotx-symbol-test--symbol "other")))
               (result (jsonrpc-request server :textDocument/documentSymbol
                                        (eglotx-symbol-test--params preferred other) :timeout 3)))
          (should (equal result preferred))
          (should (eq result wire-result)))))))

(provide 'eglotx-symbol-test)
;;; eglotx-symbol-test.el ends here
