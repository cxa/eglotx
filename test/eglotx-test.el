;;; eglotx-test.el --- Integration tests for Eglotx  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian-an

;; This file is not part of GNU Emacs.

;;; Commentary:

;; These tests exercise the in-process facade against independent Emacs
;; subprocesses running `eglotx-fake-server.el'.  Assertions use the fake
;; server's protocol-visible state endpoint; they do not inspect its process
;; buffers or depend on message arrival order.

;;; Code:

(require 'ert)
(require 'seq)
(require 'eglotx)
(require 'eglotx-presets)

(defconst eglotx-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute repository root used by the integration tests.")

(defconst eglotx-test--fake-server
  (expand-file-name "test/eglotx-fake-server.el" eglotx-test--root)
  "Absolute path to the deterministic fake language server.")

(defvar eglotx-test--server-counter 0)

(defun eglotx-test--emacs-program ()
  "Return the absolute Emacs executable used for child servers."
  (expand-file-name invocation-name invocation-directory))

(defun eglotx-test--command (name)
  "Return an argv list starting a fake language server named NAME."
  (list (eglotx-test--emacs-program)
        "-Q" "--batch" "-l" eglotx-test--fake-server "--" name))

(defun eglotx-test--formatting-command (name)
  "Return fake server argv for NAME advertising document formatting."
  (list
   (eglotx-test--emacs-program) "-Q" "--batch"
   "--eval" "(setq noninteractive nil)"
   "-l" eglotx-test--fake-server
   "--eval"
   (concat
    "(progn (setq noninteractive t) "
    "(advice-add 'eglotx-test--capabilities :filter-return "
    "(lambda (caps) (append caps '(:documentFormattingProvider t)))) "
    "(advice-add 'eglotx-test--handle-request-now :around "
    "(lambda (old id method params) "
    "(if (string= method \"textDocument/formatting\") "
    "(eglotx-test--send-result id []) "
    "(funcall old id method params)))) "
    "(kill-emacs (eglotx-test--main)))")
   "--" name))

(defun eglotx-test--spec (name &rest properties)
  "Return a fake backend descriptor named NAME with PROPERTIES."
  (append (list :name name :command (eglotx-test--command name)) properties))

(defun eglotx-test--make-executable (root relative)
  "Create executable RELATIVE under ROOT and return its path."
  (let ((path (expand-file-name relative root)))
    (make-directory (file-name-directory path) t)
    (write-region "#!/bin/sh\nexit 0\n" nil path nil 'silent)
    (set-file-modes path #o755)
    path))

(defun eglotx-test--contact-backend-specs (contact command-function)
  "Copy CONTACT specs, replacing commands through COMMAND-FUNCTION."
  (mapcar
   (lambda (spec)
     (let ((copy (copy-tree spec)))
       (plist-put copy :command
                  (funcall command-function (plist-get copy :name)))))
   (plist-get (cdr contact) :backend-specs)))

(defun eglotx-test--unique-name ()
  "Return a process-unique facade name."
  (format "eglotx-test-%d-%d"
          (emacs-pid) (cl-incf eglotx-test--server-counter)))

(defun eglotx-test--events-initargs ()
  "Return quiet JSON-RPC event initargs."
  '(:events-buffer-config (:size 0 :format short)))

(defun eglotx-test--make-server
    (specs &optional notification-dispatcher name request-dispatcher)
  "Construct an Eglotx facade for SPECS.
NOTIFICATION-DISPATCHER receives the normal connection, method, and params
arguments.  NAME, when non-nil, becomes the JSON-RPC connection name.
REQUEST-DISPATCHER handles child-to-client requests when supplied."
  (apply #'make-instance 'eglotx-server
         :name (or name (eglotx-test--unique-name))
         :notification-dispatcher (or notification-dispatcher #'ignore)
         :request-dispatcher (or request-dispatcher #'ignore)
         :on-shutdown #'ignore
         :backend-specs specs
         (eglotx-test--events-initargs)))

(defun eglotx-test--initialize-params
    (&optional streaming-p completion-text-edit-p)
  "Return deterministic initialize params.
When STREAMING-P is non-nil, advertise Eglot's streaming diagnostics
extension.  When COMPLETION-TEXT-EDIT-P is non-nil, allow completion resolve
responses to populate `textEdit'."
  (list :processId nil
        :clientInfo (list :name "eglotx-test" :version "1")
        :rootUri "file:///eglotx-test"
        :capabilities
        (list :general (list :positionEncodings ["utf-8" "utf-16"])
              :textDocument
              (append
               (list :publishDiagnostics (list :versionSupport t))
               (when completion-text-edit-p
                 (list :completion
                       (list :completionItem
                             (list :resolveSupport
                                   (list :properties ["textEdit"])))))
               (when streaming-p (list :$streamingDiagnostics t))))
        :initializationOptions (list :shared "base")
        :workspaceFolders []))

(defun eglotx-test--initialize
    (server &optional streaming-p completion-text-edit-p)
  "Initialize SERVER and return its merged result."
  (let ((result
         (jsonrpc-request server :initialize
                          (eglotx-test--initialize-params
                           streaming-p completion-text-edit-p)
                          :timeout 5)))
    (jsonrpc-notify server :initialized nil)
    result))

(defun eglotx-test--backend (server name)
  "Return SERVER's backend named NAME, failing the test if absent."
  (or (seq-find (lambda (backend)
                  (equal name (eglotx--backend-name backend)))
                (eglotx--backends server))
      (ert-fail (format "No backend named %s" name))))

(defun eglotx-test--backend-state (server name)
  "Query protocol-visible state from SERVER backend NAME."
  (let* ((backend (eglotx-test--backend server name))
         (connection (eglotx--backend-connection backend)))
    (jsonrpc-request connection :eglotx.test/state nil :timeout 3)))

(defun eglotx-test--request-client
    (server name method params &optional count)
  "Make SERVER backend NAME issue METHOD request with PARAMS to the facade."
  (let* ((backend (eglotx-test--backend server name))
         (connection (eglotx--backend-connection backend)))
    (jsonrpc-request
     connection :eglotx.test/requestClient
     (list :method method :params params :count (or count 1))
     :timeout 3)))

(defun eglotx-test--notify-client
    (server name method params &optional count)
  "Make SERVER backend NAME issue METHOD notification with PARAMS."
  (let* ((backend (eglotx-test--backend server name))
         (connection (eglotx--backend-connection backend)))
    (jsonrpc-request
     connection :eglotx.test/notifyClient
     (list :method method :params params :count (or count 1))
     :timeout 3)))

(defun eglotx-test--publish-from-backend
    (server name uri &optional version clean)
  "Make SERVER backend NAME publish diagnostics for URI.
VERSION is the optional document version.  When CLEAN is non-nil, publish an
empty snapshot."
  (let* ((backend (eglotx-test--backend server name))
         (connection (eglotx--backend-connection backend)))
    (jsonrpc-request
     connection :eglotx.test/publishDiagnostics
     (append (list :uri uri :clean (if clean t :json-false))
             (when version (list :version version)))
     :timeout 3)))

(defun eglotx-test--eglot-notification-dispatcher (server method params)
  "Dispatch SERVER notification METHOD and PARAMS through real Eglot code."
  (apply #'eglot-handle-notification server method params))

(defun eglotx-test--list-only-diagnostics-for-uri (uri)
  "Return Eglot/Flymake list-only diagnostics currently visible for URI."
  (let ((path (expand-file-name (eglot-uri-to-path uri))))
    (cdr
     (seq-find
      (lambda (entry)
        (equal (substring-no-properties (car entry)) path))
      flymake-list-only-diagnostics))))

(defun eglotx-test--wait-until (predicate &optional timeout)
  "Wait up to TIMEOUT seconds for PREDICATE and return its value."
  (let ((deadline (+ (float-time) (or timeout 3.0)))
        value)
    (while (and (not (setq value (funcall predicate)))
                (< (float-time) deadline))
      (accept-process-output nil 0.01))
    value))

(defun eglotx-test--child-processes (server)
  "Return the child process objects currently owned by SERVER."
  (delq nil
        (mapcar
         (lambda (backend)
           (when-let* ((connection (eglotx--backend-connection backend)))
             (jsonrpc--process connection)))
         (eglotx--backends server))))

(defun eglotx-test--stop-server (server)
  "Gracefully stop SERVER, then force-release any remaining test process."
  (when (and server (object-of-class-p server 'eglotx-server))
    (when (and (not (eq (eglotx--state server) 'dead))
               (process-live-p (jsonrpc--process server)))
      (when (seq-some #'process-live-p (eglotx-test--child-processes server))
        (ignore-errors (jsonrpc-request server :shutdown nil :timeout 2))
        (ignore-errors (jsonrpc-notify server :exit nil)))
      ;; Enter `stopping' before accepting the expected child exits, so a
      ;; required backend's successful exit is not classified as a crash.
      (ignore-errors (jsonrpc-shutdown server t)))
    (dolist (process (cons (ignore-errors (jsonrpc--process server))
                           (eglotx-test--child-processes server)))
      (when (process-live-p process)
        (set-process-sentinel process #'ignore)
        (delete-process process)))))

(cl-defmacro eglotx-test--with-server
    ((variable specs &optional dispatcher request-dispatcher)
                                       &body body)
  "Bind VARIABLE to an Eglotx server for SPECS while evaluating BODY.
DISPATCHER, when supplied, handles facade notifications.
REQUEST-DISPATCHER handles child-to-client requests when supplied."
  (declare (indent 1) (debug (sexp body)))
  `(let ((,variable nil))
     (unwind-protect
         (progn
           (setq ,variable
                 (eglotx-test--make-server
                  ,specs ,dispatcher nil ,request-dispatcher))
           ,@body)
       (eglotx-test--stop-server ,variable))))

(defun eglotx-test--method-seen-p (state method)
  "Return non-nil when protocol STATE records METHOD."
  (seq-contains-p (plist-get state :methods) method #'equal))

(defun eglotx-test--notification-params (notifications method)
  "Return params from NOTIFICATIONS whose method is METHOD."
  (cl-loop for (seen-method . params) in notifications
           when (eq seen-method method)
           collect params))

(ert-deftest eglotx-contact-and-configuration-validation ()
  (should-error (eglotx-contact '("one"))
                :type 'eglotx-configuration-error)
  (should
   (equal (car (eglotx-contact '("one") '("two"))) 'eglotx-server))
  (should-error
   (eglotx--normalize-backends
    '((:name "same" :command ("one"))
      (:name "same" :command ("two")))
    default-directory)
   :type 'eglotx-configuration-error)
  (should-error
   (eglotx--normalize-backends
    '((:name "broken" :command ("one" 2))) default-directory)
   :type 'eglotx-configuration-error)
  (should-error
   (eglotx--normalize-backends
    '((:name "broken" :command ("one") :environment (("A" . 1))))
    default-directory)
   :type 'eglotx-configuration-error)
  (dolist (languages '("typescript" ["typescript"] ("typescript" 1)
                       ("")))
    (should-error
     (eglotx--normalize-backends
      `((:name "broken" :command ("one") :languages ,languages)
        (:name "other" :command ("two")))
      default-directory)
     :type 'eglotx-configuration-error))
  (let* ((directory default-directory)
         (backends
          (eglotx--normalize-backends
           `((:name "low" :command ("low") :priority -1)
             (:name "off" :command ("off") :when nil)
             (:name "first" :command ("first") :priority 10)
             (:name "second" :command ("second") :priority 10
              :required nil :only ["textDocument/hover"]
              :languages ("typescript" "typescriptreact" "typescript")
              :notification-handlers (("custom/event" . ignore))
              :when ,(lambda (project) (equal project directory))))
           directory)))
    (should (equal (mapcar #'eglotx--backend-name backends)
                   '("first" "second" "low")))
    (should-not (eglotx--backend-required (nth 1 backends)))
    (should (equal (eglotx--backend-only (nth 1 backends))
                   '(:textDocument/hover)))
    (should (equal (eglotx--backend-languages (nth 1 backends))
                   '("typescript" "typescriptreact")))
    (should
     (gethash "typescriptreact"
              (eglotx--backend-language-table (nth 1 backends))))
    (should-not
     (gethash "javascript"
              (eglotx--backend-language-table (nth 1 backends))))
    (should
     (eq (gethash :custom/event
                  (eglotx--backend-notification-handlers (nth 1 backends)))
         'ignore)))
  (dolist (handlers
           '(("not-an-alist")
             (("event" . not-a-defined-function))
             (("event" . ignore) (:event . ignore))))
    (should-error
     (eglotx--normalize-backends
      `((:name "broken" :command ("one")
         :notification-handlers ,handlers)
        (:name "other" :command ("two")))
      default-directory)
     :type 'eglotx-configuration-error)))

(ert-deftest eglotx-private-notification-handler-bridges-vue-to-typescript ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "vue" :priority 110 :languages '("vue")
           :notification-handlers
           '(("tsserver/request" . eglotx-presets-vue--tsserver-request)))
          (eglotx-test--spec
           "typescript" :priority 100 :languages '("vue")))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((vue (eglotx-test--backend server "vue"))
             (connection (eglotx--backend-connection vue))
             (payload (list :file "/eglotx-test/src/App.vue"))
             (response
              (jsonrpc-request
               connection :eglotx.test/vueTsserverBridge
               (list :id 41 :command "_vue:projectInfo" :payload payload)
               :timeout 3))
             (tuple (aref response 0))
             (body (aref tuple 1))
             (typescript-state
              (eglotx-test--backend-state server "typescript"))
             (execute-params
              (plist-get (plist-get typescript-state :lastParamsByMethod)
                         :workspace/executeCommand)))
        (should (= (length response) 1))
        (should (equal (aref tuple 0) 41))
        (should (equal (plist-get body :servedBy) "typescript"))
        (should (equal (plist-get body :command) "_vue:projectInfo"))
        (should (equal (plist-get body :payload) payload))
        (should
         (equal (plist-get execute-params :command)
                "typescript.tsserverRequest"))
        (should
         (equal (plist-get execute-params :arguments)
                (vector "_vue:projectInfo" payload)))
        (should-not (assq 'tsserver/request notifications))
        (should (= (plist-get (eglotx--status-snapshot server)
                              :bridgeRequests)
                   1))
        (should (= (plist-get (eglotx--status-snapshot server)
                              :pendingBridgeRequests)
                   0))))))

(ert-deftest eglotx-private-notification-handler-settles-backend-errors ()
  (let ((warning-minimum-level :error))
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "vue" :priority 110
           :notification-handlers
           '(("tsserver/request" . eglotx-presets-vue--tsserver-request)))
          (list :name "typescript"
                :command (eglotx-test--command "bridge-error-typescript")
                :priority 100)))
      (eglotx-test--initialize server)
      (let* ((vue (eglotx-test--backend server "vue"))
             (response
              (jsonrpc-request
               (eglotx--backend-connection vue)
               :eglotx.test/vueTsserverBridge
               (list :id 42 :command "_vue:projectInfo"
                     :payload (list :file "/eglotx-test/src/App.vue"))
               :timeout 3))
             (tuple (aref response 0)))
        (should (= (aref tuple 0) 42))
        (should (null (aref tuple 1)))
        (should (= (plist-get (eglotx--status-snapshot server)
                              :pendingBridgeRequests)
                   0))))))

(ert-deftest eglotx-private-notification-handler-cancels-timeouts ()
  (let ((warning-minimum-level :error))
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "vue" :priority 110
           :notification-handlers
           '(("tsserver/request" . eglotx-presets-vue--tsserver-request)))
          (list :name "typescript"
                :command (eglotx-test--command "slow-bridge-typescript")
                :priority 100)))
      (eglotx-test--initialize server)
      (setf (eglotx--backend-request-timeout
             (eglotx-test--backend server "typescript"))
            0.05)
      (let* ((vue (eglotx-test--backend server "vue"))
             (started (float-time))
             (response
              (jsonrpc-request
               (eglotx--backend-connection vue)
               :eglotx.test/vueTsserverBridge
               (list :id 43 :command "_vue:projectInfo" :payload nil)
               :timeout 2))
             (tuple (aref response 0))
             (typescript-state
              (eglotx-test--backend-state server "typescript")))
        (should (< (- (float-time) started) 1.0))
        (should (= (aref tuple 0) 43))
        (should (null (aref tuple 1)))
        (should (= (length (plist-get typescript-state :cancelledIds)) 1))
        (should (= (plist-get (eglotx--status-snapshot server)
                              :pendingBridgeRequests)
                   0))))))

(ert-deftest eglotx-private-notification-handler-settles-target-crash ()
  (let ((warning-minimum-level :error)
        response)
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "vue" :priority 110
           :notification-handlers
           '(("tsserver/request" . eglotx-presets-vue--tsserver-request)))
          (list :name "typescript"
                :command (eglotx-test--command "slow-bridge-typescript")
                :priority 100 :required nil)))
      (eglotx-test--initialize server)
      (let* ((vue (eglotx-test--backend server "vue"))
             (typescript (eglotx-test--backend server "typescript"))
             (typescript-connection
              (eglotx--backend-connection typescript)))
        (jsonrpc-async-request
         (eglotx--backend-connection vue)
         :eglotx.test/vueTsserverBridge
         (list :id 44 :command "_vue:projectInfo" :payload nil)
         :timeout 2 :success-fn (lambda (value) (setq response value))
         :error-fn #'ignore)
        (should
         (eglotx-test--wait-until
          (lambda ()
            (= (plist-get (eglotx--status-snapshot server)
                          :pendingBridgeRequests)
               1))))
        (jsonrpc-async-request
         typescript-connection :eglotx.test/crash nil
         :timeout 1 :success-fn #'ignore :error-fn #'ignore
         :timeout-fn #'ignore)
        (should (eglotx-test--wait-until (lambda () response) 2.0))
        (let ((tuple (aref response 0)))
          (should (= (aref tuple 0) 44))
          (should (null (aref tuple 1))))
        (should (= (plist-get (eglotx--status-snapshot server)
                              :pendingBridgeRequests)
                   0))
        (should (eq (eglotx--state server) 'running))
        (should (eq (eglotx--backend-state typescript) 'failed))))))

(ert-deftest eglotx-private-notification-handler-cancels-source-crash ()
  (let ((warning-minimum-level :error))
    (eglotx-test--with-server
        (server
         (list
          (list :name "vue" :command (eglotx-test--command "vue")
                :priority 110 :required nil
                :notification-handlers
                '(("tsserver/request" . eglotx-presets-vue--tsserver-request)))
          (list :name "typescript"
                :command (eglotx-test--command "slow-bridge-typescript")
                :priority 100)))
      (eglotx-test--initialize server)
      (let* ((vue (eglotx-test--backend server "vue"))
             (typescript (eglotx-test--backend server "typescript")))
        (jsonrpc-async-request
         (eglotx--backend-connection vue)
         :eglotx.test/vueTsserverBridge
         (list :id 45 :command "_vue:projectInfo" :payload nil)
         :timeout 2 :success-fn #'ignore :error-fn #'ignore
         :timeout-fn #'ignore)
        (should
         (eglotx-test--wait-until
          (lambda ()
            (= (plist-get (eglotx--status-snapshot server)
                          :pendingBridgeRequests)
               1))))
        (jsonrpc-async-request
         (eglotx--backend-connection vue) :eglotx.test/crash nil
         :timeout 1 :success-fn #'ignore :error-fn #'ignore
         :timeout-fn #'ignore)
        (should
         (eglotx-test--wait-until
          (lambda ()
            (zerop (plist-get (eglotx--status-snapshot server)
                              :pendingBridgeRequests)))
          2.0))
        (let ((state (eglotx-test--backend-state server "typescript")))
          (should (= (length (plist-get state :cancelledIds)) 1)))
        (should (eq (eglotx--state server) 'running))
        (should (eq (eglotx--backend-state vue) 'failed))
        (should (eq (eglotx--backend-state typescript) 'ready))))))

(ert-deftest eglotx-copies-eglot-language-cohort ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "primary" :priority 100)
             (eglotx-test--spec "secondary" :priority 10)))
    (let ((languages '((js-mode . "javascript")
                       (tsx-ts-mode . "typescriptreact"))))
      (setf (eglot--languages server) languages)
      (let ((copy (eglotx--compute-language-cohort server)))
        (should (equal copy languages))
        (should-not (eq copy languages))
        (should-not (eq (cdar copy) (cdar languages)))))))

(ert-deftest eglotx-did-open-preserves-eglot-language-id ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "primary" :priority 100)
             (eglotx-test--spec "secondary" :priority 10)))
    (let* ((buffer (generate-new-buffer " *eglotx legacy language*"))
           (uri "file:///eglotx-test/example.tsx")
           (wire-document
            (list :uri uri :languageId "javascript" :version 0 :text ""))
           (params (list :textDocument wire-document)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (setq major-mode 'tsx-ts-mode))
            (cl-letf (((symbol-function 'eglotx--visiting-buffer)
                       (lambda (_server _uri) buffer)))
              (eglotx--did-open server :textDocument/didOpen params))
            (should
             (equal
              (eglotx--document-language-id
               (gethash uri (eglotx--documents server)))
              "javascript"))
            (should (equal (plist-get wire-document :languageId) "javascript")))
        (kill-buffer buffer)))))

(ert-deftest eglotx-document-selector-intersection-is-bounded ()
  (let* ((eglotx-document-selector-limit 2)
         (backend
          (car
           (eglotx--normalize-backends
            '((:name "restricted" :command ("one")
               :languages ("typescript" "typescriptreact"))
              (:name "other" :command ("two")))
            default-directory)))
         (raw
          '(:documentSelector
            [( :scheme "file") ( :pattern "**/*.generated.ts")])))
    (should-error
     (eglotx--restrict-document-selector
      backend :textDocument/completion raw)
     :type 'jsonrpc-error)
    (should
     (equal raw
            '(:documentSelector
              [( :scheme "file") ( :pattern "**/*.generated.ts")]))))
  (let ((eglotx-document-selector-limit 2))
    (should-error
     (eglotx--compile-document-selector
      [( :language "one") ( :language "two") ( :language "three")])
     :type 'jsonrpc-error)))

(ert-deftest eglotx-eslint-preset-settings-reach-the-backend-wire ()
  (let ((root (file-name-as-directory
               (make-temp-file "eglotx eslint settings-" t)))
        server)
    (unwind-protect
        (let* ((items [( :section "eslint") ( :section "eslint")])
               (base
                [( :experimental (:useFlatConfig t)
                   :clientOnly "preserved")
                 ( :clientOnly "default-experimental")]))
          (setq server
                (eglotx-test--make-server
                 (list
                  (eglotx-test--spec
                   "eslint"
                   :priority 100
                   :settings (eglotx-presets--eslint-settings root))
                  (eglotx-test--spec "typescript" :priority 0))
                 nil nil
                 (lambda (_connection method params)
                   (should (eq method 'workspace/configuration))
                   (should (equal (plist-get params :items) items))
                   base)))
          (eglotx-test--initialize server)
          (let* ((wire
                  (jsonrpc-request
                   server :eglotx.test/workspaceConfigurationWire
                   (list :items items) :timeout 3))
                 (message
                  (json-parse-string
                   wire :object-type 'hash-table :array-type 'array
                   :null-object :json-null :false-object :json-false))
                 (result (gethash "result" message))
                 (configured (aref result 0))
                 (defaults (aref result 1))
                 (configured-experimental
                  (gethash "experimental" configured))
                 (default-experimental (gethash "experimental" defaults)))
            (should (= (length result) 2))
            (should (equal (gethash "validate" configured) "on"))
            (should
             (equal (gethash "mode" (gethash "workingDirectory" configured))
                    "auto"))
            (should (eq (gethash "nodePath" configured) :json-null))
            (should (= (hash-table-count (gethash "options" configured)) 0))
            (should (eq (gethash "useFlatConfig" configured-experimental) t))
            (should (equal (gethash "clientOnly" configured) "preserved"))
            (should (hash-table-p default-experimental))
            (should (= (hash-table-count default-experimental) 0))))
      (eglotx-test--stop-server server)
      (delete-directory root t))))

(ert-deftest eglotx-biome-preset-settings-reach-the-backend-wire ()
  (let (server)
    (unwind-protect
        (let* ((items [( :section "biome") ( :section "biome")])
               (base
                [( :requireConfiguration t
                   :configurationPath "config/biome.jsonc")
                 nil]))
          (setq server
                (eglotx-test--make-server
                 (list
                  (eglotx-test--spec
                   "biome" :priority 120
                   :settings (eglotx-presets--biome-settings))
                  (eglotx-test--spec "typescript" :priority 0))
                 nil nil
                 (lambda (_connection method params)
                   (should (eq method 'workspace/configuration))
                   (should (equal (plist-get params :items) items))
                   base)))
          (eglotx-test--initialize server)
          (let* ((wire
                  (jsonrpc-request
                   server :eglotx.test/workspaceConfigurationWire
                   (list :items items) :timeout 3))
                 (message
                  (json-parse-string
                   wire :object-type 'hash-table :array-type 'array
                   :null-object :json-null :false-object :json-false))
                 (result (gethash "result" message))
                 (configured (aref result 0))
                 (defaults (aref result 1)))
            (should (eq (gethash "requireConfiguration" configured) t))
            (should
             (equal (gethash "configurationPath" configured)
                    "config/biome.jsonc"))
            (should (hash-table-p defaults))
            (should (= (hash-table-count defaults) 0))))
      (eglotx-test--stop-server server))))

(ert-deftest eglotx-python-preset-keeps-ruff-out-of-primary-requests ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "python-primary" :priority 100)
        (eglotx-test--spec
         "ruff" :priority 120 :required nil
         :only eglotx-presets-python--ruff-only)))
    (eglotx-test--initialize server)
    (let ((params
           (list :textDocument (list :uri "file:///eglotx-test/main.py"))))
      (jsonrpc-request server :textDocument/hover params :timeout 3)
      (jsonrpc-request server :textDocument/codeAction params :timeout 3))
    (let ((primary (eglotx-test--backend-state server "python-primary"))
          (ruff (eglotx-test--backend-state server "ruff")))
      (should (eglotx-test--method-seen-p primary "textDocument/hover"))
      (should-not (eglotx-test--method-seen-p ruff "textDocument/hover"))
      (should
       (eglotx-test--method-seen-p primary "textDocument/codeAction"))
      (should (eglotx-test--method-seen-p ruff "textDocument/codeAction")))))

(ert-deftest eglotx-python-preset-makes-ruff-the-only-format-owner ()
  (let ((root (file-name-as-directory
               (make-temp-file "eglotx python formatting-" t)))
        server)
    (unwind-protect
        (progn
          (eglotx-test--make-executable
           root ".venv/bin/pyright-langserver")
          (eglotx-test--make-executable root ".venv/bin/ruff")
          (let* ((default-directory root)
                 (exec-path nil)
                 (project (cons 'transient root))
                 (contact (eglotx-presets-python-contact nil project))
                 (specs
                  (eglotx-test--contact-backend-specs
                   contact #'eglotx-test--formatting-command))
                 (primary-spec
                  (seq-find
                   (lambda (spec)
                     (equal (plist-get spec :name) "pyright"))
                   specs))
                 (ruff-spec
                  (seq-find
                   (lambda (spec)
                     (equal (plist-get spec :name) "ruff"))
                   specs)))
            (should primary-spec)
            (should ruff-spec)
            (should (> (plist-get ruff-spec :priority)
                       (plist-get primary-spec :priority)))
            (should (equal (plist-get ruff-spec :only)
                           eglotx-presets-python--ruff-only))
            (setq server (eglotx-test--make-server specs))
            (let ((capabilities
                   (plist-get (eglotx-test--initialize server)
                              :capabilities)))
              (should
               (eq (plist-get capabilities :documentFormattingProvider) t)))
            (dolist (name '("pyright" "ruff"))
              (should
               (eq (plist-get
                    (eglotx--backend-capabilities
                     (eglotx-test--backend server name))
                    :documentFormattingProvider)
                   t)))
            (let ((edits
                   (jsonrpc-request
                    server :textDocument/formatting
                    '(:textDocument (:uri "file:///eglotx-test/main.py")
                      :options (:tabSize 4 :insertSpaces t))
                    :timeout 3)))
              (should (equal edits [])))
            (let ((primary
                   (eglotx-test--backend-state server "pyright"))
                  (ruff (eglotx-test--backend-state server "ruff")))
              (should-not
               (eglotx-test--method-seen-p
                primary "textDocument/formatting"))
              (should
               (eglotx-test--method-seen-p
                ruff "textDocument/formatting")))))
      (eglotx-test--stop-server server)
      (delete-directory root t))))

(ert-deftest eglotx-go-preset-options-and-method-filter-reach-the-wire ()
  (let ((root (file-name-as-directory
               (make-temp-file "eglotx go options-" t)))
        server)
    (unwind-protect
        (let* ((_gopls
                (eglotx-test--make-executable root "bin/gopls"))
               (_server
                (eglotx-test--make-executable
                 root "bin/golangci-lint-langserver"))
               (linter
                (eglotx-test--make-executable root "bin/golangci-lint"))
               (config (expand-file-name ".golangci.custom.yaml" root)))
          (write-region "version: \"2\"\nlinters:\n" nil config nil 'silent)
          (let* ((default-directory root)
                 (exec-path nil)
                 (project (cons 'transient root))
                 (contact (eglotx-presets-go-contact nil project))
                 (specs
                  (eglotx-test--contact-backend-specs
                   contact #'eglotx-test--command)))
            (setq server (eglotx-test--make-server specs))
            (setf (eglotx--language-cohort server) '((go-mode . "go")))
            (eglotx-test--initialize server)
            (let* ((uri "file:///eglotx-test/main.go")
                   (document
                    (list :uri uri :languageId "go" :version 0
                          :text "package main"))
                   (hover-params
                    (list :textDocument (list :uri uri)
                          :position (list :line 0 :character 0))))
              (jsonrpc-notify server :textDocument/didOpen
                              (list :textDocument document))
              (jsonrpc-request server :textDocument/hover
                               hover-params :timeout 3)
              (let* ((primary
                      (eglotx-test--backend-state server "gopls"))
                     (golangci
                      (eglotx-test--backend-state
                       server "golangci-lint"))
                     (initialize
                      (plist-get
                       (plist-get golangci :lastParamsByMethod)
                       :initialize))
                     (options (plist-get initialize
                                         :initializationOptions)))
                (should
                 (equal (plist-get options :command)
                        (vector linter "run" "--output.json.path" "stdout"
                                "--show-stats=false"
                                "--issues-exit-code=1"
                                "--config" config)))
                (should
                 (eglotx-test--method-seen-p
                  primary "textDocument/hover"))
                (should-not
                 (eglotx-test--method-seen-p
                  golangci "textDocument/hover"))))))
      (eglotx-test--stop-server server)
      (delete-directory root t))))

(ert-deftest eglotx-ruby-preset-keeps-formatting-on-ruby-lsp ()
  (let ((root (file-name-as-directory
               (make-temp-file "eglotx ruby formatting-" t)))
        server)
    (unwind-protect
        (progn
          (eglotx-test--make-executable root "bin/ruby-lsp")
          (eglotx-test--make-executable root "bin/srb")
          (make-directory (expand-file-name "sorbet/" root) t)
          (write-region ".\n" nil
                        (expand-file-name "sorbet/config" root) nil 'silent)
          (let* ((default-directory root)
                 (exec-path nil)
                 (project (cons 'transient root))
                 (contact (eglotx-presets-ruby-contact nil project))
                 (specs
                  (eglotx-test--contact-backend-specs
                   contact #'eglotx-test--formatting-command)))
            (setq server (eglotx-test--make-server specs))
            (eglotx-test--initialize server)
            (should
             (equal
              (jsonrpc-request
               server :textDocument/formatting
               '(:textDocument (:uri "file:///eglotx-test/example.rb")
                 :options (:tabSize 2 :insertSpaces t))
               :timeout 3)
              []))
            (let ((ruby-lsp
                   (eglotx-test--backend-state server "ruby-lsp"))
                  (sorbet
                   (eglotx-test--backend-state server "sorbet")))
              (should
               (eglotx-test--method-seen-p
                ruby-lsp "textDocument/formatting"))
              (should-not
               (eglotx-test--method-seen-p
                sorbet "textDocument/formatting")))))
      (eglotx-test--stop-server server)
      (delete-directory root t))))

(ert-deftest eglotx-language-restrictions-route-one-facade-cohort ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec
              "beta-full" :priority 10
              :languages '("typescript"))))
    (setf (eglotx--language-cohort server)
          '((typescript-mode . "typescript")
            (tsx-ts-mode . "typescriptreact")))
    (eglotx-test--initialize server)
    (setf (eglotx--backend-text-sync
           (eglotx-test--backend server "alpha"))
          '(:openClose t :change 2 :save t)
          (eglotx--backend-text-sync
           (eglotx-test--backend server "beta-full"))
          '(:openClose t :change 1 :save t))
    (let* ((uri "file:///eglotx-test/component.tsx")
           (document (list :uri uri :languageId "typescriptreact"
                           :version 0 :text "export const View = 1"))
           (position-params
            (list :textDocument (list :uri uri)
                  :position (list :line 0 :character 0))))
      (jsonrpc-notify server :textDocument/didOpen
                      (list :textDocument document))
      (jsonrpc-notify
       server :textDocument/didChange
       (list :textDocument (list :uri uri :version 1)
             :contentChanges [( :text "export const View = 2")]))
      (jsonrpc-notify server :textDocument/didSave
                      (list :textDocument (list :uri uri)))
      (jsonrpc-request server :textDocument/hover position-params :timeout 3)
      (jsonrpc-notify
       server :workspace/didChangeConfiguration '(:settings (:shared t)))
      (jsonrpc-notify server :textDocument/didClose
                      (list :textDocument (list :uri uri)))
      (let ((primary (eglotx-test--backend-state server "alpha"))
            (restricted (eglotx-test--backend-state server "beta-full")))
        (dolist (method '("textDocument/didOpen" "textDocument/didChange"
                          "textDocument/didSave" "textDocument/hover"
                          "textDocument/didClose"))
          (should (eglotx-test--method-seen-p primary method))
          (should-not (eglotx-test--method-seen-p restricted method)))
        (dolist (method '("initialize" "initialized"
                          "workspace/didChangeConfiguration"))
          (should (eglotx-test--method-seen-p restricted method)))))
    (let* ((uri "file:///eglotx-test/component.ts")
           (params (list :textDocument (list :uri uri)
                         :position (list :line 0 :character 0))))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "typescript"
                   :version 0 :text "export const value = 1")))
      (jsonrpc-request server :textDocument/hover params :timeout 3)
      (let ((restricted (eglotx-test--backend-state server "beta-full")))
        (should (eglotx-test--method-seen-p
                 restricted "textDocument/didOpen"))
        (should (eglotx-test--method-seen-p
                 restricted "textDocument/hover"))))))

(ert-deftest eglotx-static-settings-overlay-copies-only-modified-paths ()
  (let* ((untouched (list :items [1 2 3]))
         (changed (list :existing t))
         (base (list :untouched untouched :changed changed))
         (overlay (list :changed (list :added t)))
         (result (eglotx--json-merge base overlay)))
    (should-not (eq result base))
    (should (eq (plist-get result :untouched) untouched))
    (should-not (eq (plist-get result :changed) changed))
    (should (equal (plist-get result :changed)
                   '(:existing t :added t)))
    (should (equal base
                   (list :untouched untouched
                         :changed (list :existing t))))))

(ert-deftest eglotx-function-settings-overlay-detaches-mutable-json-values ()
  (let* ((key (copy-sequence "key"))
         (text (copy-sequence "value"))
         (item (copy-sequence "item"))
         (table (make-hash-table :test #'equal))
         (base (list :text text :table table))
         copied-key copied-text copied-item copied-table)
    (puthash key item table)
    (eglotx--backend-overlay
     (lambda (copy)
       (setq copied-text (plist-get copy :text)
             copied-table (plist-get copy :table))
       (maphash (lambda (candidate value)
                  (setq copied-key candidate
                        copied-item value))
                copied-table)
       ;; A function overlay is allowed to transform its private argument
       ;; destructively, including mutable strings used as hash keys.
       (aset copied-text 0 ?V)
       (aset copied-key 0 ?K)
       (aset copied-item 0 ?I)
       copy)
     base)
    (should-not (eq copied-text text))
    (should-not (eq copied-table table))
    (should-not (eq copied-key key))
    (should-not (eq copied-item item))
    (should (equal text "value"))
    (should (equal key "key"))
    (should (equal item "item"))
    (should (equal (gethash "key" table) "item"))))

(ert-deftest eglotx-initialize-merges-capabilities-in-priority-order ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec
         "beta-full" :priority 10
         :initialization-options (list :beta 2))
        (eglotx-test--spec
         "alpha" :priority 100
         :initialization-options (list :alpha t))))
    (let* ((result (eglotx-test--initialize server t))
           (capabilities (plist-get result :capabilities))
           (completion (plist-get capabilities :completionProvider))
           (commands
            (plist-get (plist-get capabilities :executeCommandProvider)
                       :commands))
           (alpha-state (eglotx-test--backend-state server "alpha"))
           (beta-state (eglotx-test--backend-state server "beta-full"))
           (alpha-init
            (plist-get (plist-get alpha-state :lastParamsByMethod)
                       :initialize))
           (beta-init
            (plist-get (plist-get beta-state :lastParamsByMethod)
                       :initialize)))
      (should (equal (plist-get capabilities :positionEncoding) "utf-16"))
      (should (equal (plist-get (plist-get capabilities :textDocumentSync)
                                :change)
                     2))
      (should (equal (plist-get completion :triggerCharacters) ["." ":"]))
      (should (eq (plist-get completion :resolveProvider) t))
      (should (= (length commands) 2))
      (seq-doseq (command commands)
        (should (string-prefix-p "eglotx:" command)))
      (should
       (equal
        (mapcar
         (lambda (command)
           (eglotx--owner-command
            (gethash command (eglotx--command-owners server))))
         (append commands nil))
        '("eglotx.alpha.apply" "eglotx.beta-full.apply")))
      ;; Eglot 31 keeps pull and streaming reports in disjoint maps.  Since
      ;; these fakes advertise pull diagnostics, the facade intentionally
      ;; uses ordinary publishDiagnostics for push siblings instead.
      (should-not
       (plist-member capabilities :$streamingDiagnosticsProvider))
      (should (equal (plist-get (plist-get result :serverInfo) :name)
                     "alpha+beta-full"))
      (should (equal
               (plist-get
                (plist-get (plist-get alpha-init :capabilities) :general)
                :positionEncodings)
               ["utf-16"]))
      (should
       (equal
        (plist-get
         (plist-get
          (plist-get
           (plist-get (plist-get alpha-init :capabilities) :textDocument)
           :completion)
          :completionList)
         :itemDefaults)
        ["data" "editRange"]))
      (should-not
       (plist-member
        (plist-get (plist-get alpha-init :capabilities) :textDocument)
        :$streamingDiagnostics))
      (should (equal (plist-get (plist-get alpha-init :initializationOptions)
                                :shared)
                     "base"))
      (should (eq (plist-get (plist-get alpha-init :initializationOptions)
                             :alpha)
                  t))
      (should (equal (plist-get (plist-get beta-init :initializationOptions)
                                :beta)
                     2)))))

(ert-deftest eglotx-language-capabilities-are-cohort-complete-and-state-safe ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "diagnostic-only" :priority 100 :languages '("css"))
             (eglotx-test--spec
              "no-diagnostic-alpha" :priority 10)))
    (setf (eglotx--language-cohort server)
          '((css-mode . "css") (scss-mode . "scss")))
    (let ((capabilities
           (plist-get (eglotx-test--initialize server) :capabilities)))
      ;; Static capabilities apply to the whole facade.  A CSS-only pull
      ;; provider must not make Eglot pull diagnostics from SCSS buffers.
      (should-not (plist-member capabilities :diagnosticProvider)))
    (let* ((restricted (eglotx-test--backend server "diagnostic-only"))
           (primary (eglotx-test--backend server "no-diagnostic-alpha"))
           (restricted-provider
            '(:legend (:tokenTypes ["restricted"] :tokenModifiers [])
              :full t :range :json-false))
           (primary-provider
            '(:legend (:tokenTypes ["primary"] :tokenModifiers [])
              :full t :range :json-false)))
      (setf (eglotx--backend-capabilities restricted)
            '(:positionEncoding "utf-16"
              :diagnosticProvider
              (:interFileDependencies :json-false
               :workspaceDiagnostics :json-false))
            (eglotx--backend-capabilities primary)
            '(:positionEncoding "utf-16" :diagnosticProvider :json-false))
      (should-not
       (plist-member
        (eglotx--combine-capabilities server (eglotx--backends server))
        :diagnosticProvider))
      (setf (eglotx--backend-capabilities restricted)
            (list :positionEncoding "utf-16"
                  :semanticTokensProvider restricted-provider)
            (eglotx--backend-capabilities primary)
            (list :positionEncoding "utf-16"
                  :semanticTokensProvider primary-provider))
      (let* ((capabilities
              (eglotx--combine-capabilities
               server (eglotx--backends server)))
             (semantic (plist-get capabilities :semanticTokensProvider)))
        (should
         (equal
          (plist-get (plist-get semantic :legend) :tokenTypes)
          ["primary"]))
        (should
         (eq (gethash :textDocument/semanticTokens/full
                      (eglotx--singleton-providers server))
             primary))))))

(ert-deftest eglotx-unknown-capability-must-belong-to-the-primary-backend ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "primary" :priority 100)
             (eglotx-test--spec "secondary" :priority 10)))
    (eglotx-test--initialize server)
    (let ((primary (eglotx-test--backend server "primary"))
          (secondary (eglotx-test--backend server "secondary")))
      (setf (eglotx--backend-capabilities primary)
            '(:positionEncoding "utf-16")
            (eglotx--backend-capabilities secondary)
            '(:positionEncoding "utf-16"
              :experimental (:secondaryOnly t)))
      (should-not
       (plist-member
        (eglotx--combine-capabilities server (eglotx--backends server))
        :experimental))
      (setf (eglotx--backend-capabilities primary)
            '(:positionEncoding "utf-16"
              :experimental (:primary t)))
      (should
       (equal
        (plist-get
         (eglotx--combine-capabilities server (eglotx--backends server))
         :experimental)
        '(:primary t))))))

(ert-deftest eglotx-strips-child-static-registration-identities ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "static-type-alpha" :priority 100)
             (eglotx-test--spec "static-type-beta" :priority 10)))
    (setf (eglotx--language-cohort server)
          '((emacs-lisp-mode . "elisp")))
    (let* ((result (eglotx-test--initialize server))
           (provider
            (plist-get (plist-get result :capabilities)
                       :typeDefinitionProvider))
           (alpha (eglotx-test--backend server "static-type-alpha"))
           (child-provider
            (plist-get (eglotx--backend-capabilities alpha)
                       :typeDefinitionProvider)))
      (should (equal (plist-get child-provider :id) "shared-static-id"))
      (should-not (plist-member provider :id))
      (should (equal (plist-get provider :documentSelector)
                     [(:language "elisp")])))))

(ert-deftest eglotx-normalizes-static-workspace-folder-identities ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "static-workspace-folders-alpha" :priority 100)
        (eglotx-test--spec "static-workspace-folders-beta" :priority 10)))
    (let* ((result (eglotx-test--initialize server))
           (folders
            (plist-get
             (plist-get (plist-get result :capabilities) :workspace)
             :workspaceFolders))
           (changes (plist-get folders :changeNotifications)))
      (should (eq (plist-get folders :supported) t))
      (should (eq changes t))
      (should-not (equal changes "shared-workspace-folders-id")))))

(ert-deftest eglotx-static-selectors-cover-the-facade-with-routable-unions ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (setf (eglotx--language-cohort server)
          '((typescript-mode . "typescript")
            (js-mode . "javascript")))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (typescript-selector [( :language "typescript")])
           (javascript-selector [( :language "javascript")])
           (typescript-uri "file:///eglotx-test/selector.ts")
           (javascript-uri "file:///eglotx-test/selector.js"))
      (cl-labels
          ((install
            (capability alpha-provider beta-provider)
            (setf (eglotx--backend-capabilities alpha)
                  (list :positionEncoding "utf-16"
                        capability alpha-provider)
                  (eglotx--backend-capabilities beta)
                  (list :positionEncoding "utf-16"
                        capability beta-provider)
                  (eglotx--backend-static-capability-selectors alpha)
                  (eglotx--compile-static-selectors
                   (eglotx--backend-capabilities alpha))
                  (eglotx--backend-static-capability-selectors beta)
                  (eglotx--compile-static-selectors
                   (eglotx--backend-capabilities beta)))))
        (funcall
         #'install :typeDefinitionProvider
         (list :id "alpha-type" :documentSelector typescript-selector)
         (list :id "beta-type" :documentSelector javascript-selector))
        (let* ((capabilities
                (eglotx--combine-capabilities
                 server (eglotx--backends server)))
               (provider (plist-get capabilities :typeDefinitionProvider))
               (selector (plist-get provider :documentSelector)))
          (should (= (length selector) 2))
          (should (member '(:language "typescript") (append selector nil)))
          (should (member '(:language "javascript") (append selector nil))))
        (dolist (entry `((,typescript-uri . "typescript")
                         (,javascript-uri . "javascript")))
          (eglotx--did-open
           server :textDocument/didOpen
           (list :textDocument
                 (list :uri (car entry) :languageId (cdr entry)
                       :version 0 :text ""))))
        (should
         (equal
          (eglotx--select-request-targets
           server :textDocument/typeDefinition
           (list :textDocument (list :uri typescript-uri))
           (eglotx--policy :textDocument/typeDefinition))
          (list alpha)))
        (should
         (equal
          (eglotx--select-request-targets
           server :textDocument/typeDefinition
           (list :textDocument (list :uri javascript-uri))
           (eglotx--policy :textDocument/typeDefinition))
          (list beta)))
        ;; Explicit JSON null is universal and dominates a narrowed sibling.
        (funcall
         #'install :typeDefinitionProvider
         '(:id "alpha-type" :documentSelector nil)
         (list :id "beta-type" :documentSelector javascript-selector))
        (should-not
         (plist-member
          (plist-get
           (eglotx--combine-capabilities server (eglotx--backends server))
           :typeDefinitionProvider)
          :documentSelector))
        ;; A pattern-only contributor cannot justify a static facade-wide
        ;; advertisement because Eglot does not enforce static selectors.
        (funcall
         #'install :typeDefinitionProvider
         '(:id "alpha-type"
           :documentSelector [(:language "typescript" :pattern "**/*.ts")])
         (list :id "beta-type" :documentSelector javascript-selector))
        (should-not
         (plist-member
          (eglotx--combine-capabilities server (eglotx--backends server))
          :typeDefinitionProvider))
        ;; Semantic legends are stateful: two narrowed providers cannot be
        ;; represented as one legend/selector union.
        (let ((alpha-semantic
               (list :id "alpha-semantic"
                     :documentSelector typescript-selector
                     :legend '(:tokenTypes ["alpha"] :tokenModifiers [])
                     :full t :range :json-false))
              (beta-semantic
               (list :id "beta-semantic"
                     :documentSelector javascript-selector
                     :legend '(:tokenTypes ["beta"] :tokenModifiers [])
                     :full t :range :json-false)))
          (clrhash (eglotx--singleton-providers server))
          (funcall #'install :semanticTokensProvider
                   alpha-semantic beta-semantic)
          (should-not
           (plist-member
            (eglotx--combine-capabilities server (eglotx--backends server))
            :semanticTokensProvider)))
        ;; Moniker options carry a text-document selector, but unlike the
        ;; capabilities above they do not own a StaticRegistrationOptions ID.
        (funcall
         #'install :monikerProvider
         (list :documentSelector typescript-selector)
         (list :documentSelector javascript-selector))
        (let* ((capabilities
                (eglotx--combine-capabilities
                 server (eglotx--backends server)))
               (provider (plist-get capabilities :monikerProvider))
               (selector (plist-get provider :documentSelector)))
          (should (= (length selector) 2)))
        (should
         (equal
          (eglotx--select-request-targets
           server :textDocument/moniker
           (list :textDocument (list :uri javascript-uri))
           (eglotx--policy :textDocument/moniker))
          (list beta)))
        ;; Inline completion has an explicit selector-aware request policy;
        ;; each language routes to the provider whose static contribution was
        ;; included in the aggregate union.
        (funcall
         #'install :inlineCompletionProvider
         (list :id "alpha-inline" :documentSelector typescript-selector)
         (list :id "beta-inline" :documentSelector javascript-selector))
        (let ((capabilities
               (eglotx--combine-capabilities server (eglotx--backends server))))
          (should (plist-member capabilities :inlineCompletionProvider)))
        (should
         (equal
          (eglotx--select-request-targets
           server :textDocument/inlineCompletion
           (list :textDocument (list :uri javascript-uri))
           (eglotx--policy :textDocument/inlineCompletion))
          (list beta)))))))

(ert-deftest eglotx-completion-resolve-and-command-preserve-affinity ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "beta-full" :priority 10)
             (eglotx-test--spec "alpha" :priority 100)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/completion.el")
           (params (list :textDocument (list :uri uri)
                         :position (list :line 0 :character 0)))
           (_open
            (jsonrpc-notify
             server :textDocument/didOpen
             (list :textDocument
                   (list :uri uri :languageId "elisp" :version 0
                         :text "before"))))
           (completion
            (jsonrpc-request server :textDocument/completion params :timeout 3))
           (items (plist-get completion :items))
           (alpha-item (aref items 0))
           (beta-item (aref items 1)))
      (should (equal (mapcar (lambda (item) (plist-get item :label))
                             (append items nil))
                     '("alpha-item" "beta-full-item")))
      (dolist (item (append items nil))
        (should (equal (plist-get item :commitCharacters) [";"]))
        (should (equal (plist-get item :insertTextFormat) 1))
        (should (string-prefix-p "eglotx:" (plist-get item :data))))
      (should-not (equal (plist-get alpha-item :data)
                         (plist-get beta-item :data)))
      (should-not (plist-member completion :itemDefaults))
      (let* ((resolved
              (jsonrpc-request server :completionItem/resolve alpha-item
                               :timeout 3))
             (resolved-token (plist-get resolved :data))
             (alpha-state (eglotx-test--backend-state server "alpha"))
             (beta-state (eglotx-test--backend-state server "beta-full"))
             (backend-data (plist-get (plist-get alpha-state :lastParams)
                                      :data)))
        (should (equal (plist-get resolved :resolvedBy) "alpha"))
        (should (string-prefix-p "eglotx:" resolved-token))
        (should (equal (plist-get backend-data :server) "alpha"))
        (should (equal (plist-get backend-data :token)
                       "alpha-completion-data"))
        (should (eglotx-test--method-seen-p
                 alpha-state "completionItem/resolve"))
        (should-not (eglotx-test--method-seen-p
                     beta-state "completionItem/resolve")))
      (let* ((actions
              (jsonrpc-request
               server :textDocument/codeAction
               (list :textDocument (list :uri uri)
                     :range (list :start (list :line 0 :character 0)
                                  :end (list :line 0 :character 0))
                     :context (list :diagnostics []))
               :timeout 3))
             (command (plist-get (aref actions 0) :command))
             (command-token (plist-get command :command)))
        ;; Document generations invalidate item/diagnostic ownership, but a
        ;; command advertised by a backend remains executable for the whole
        ;; server session.
        (jsonrpc-notify
         server :textDocument/didChange
         (list :textDocument (list :uri uri :version 1)
               :contentChanges (vector (list :text "after"))))
        (let ((executed
               (jsonrpc-request
                server :workspace/executeCommand
                (list :command command-token
                      :arguments (plist-get command :arguments))
                :timeout 3)))
          (should (string-prefix-p "eglotx:" command-token))
          (should (equal (plist-get executed :executedBy) "alpha"))
          (should (equal (plist-get executed :command)
                         "eglotx.alpha.apply")))))))

(ert-deftest eglotx-high-volume-completion-preserves-every-owner ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "tailwind-volume" :priority 100)
             (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server nil t)
    (let* ((uri "file:///eglotx-test/tailwind-volume.tsx")
           (_open
            (jsonrpc-notify
             server :textDocument/didOpen
             (list :textDocument
                   (list :uri uri :languageId "typescriptreact"
                         :version 0 :text "<div className=\"\" />"))))
           (original-materializer
            (symbol-function 'eglotx--completion-with-edit-range))
           (edit-range-materializations 0)
           completion)
      (cl-letf (((symbol-function 'eglotx--completion-with-edit-range)
                 (lambda (&rest arguments)
                   (cl-incf edit-range-materializations)
                   (apply original-materializer arguments))))
        (setq completion
              (jsonrpc-request
               server :textDocument/completion
               (list :textDocument (list :uri uri)
                     :position (list :line 0 :character 16))
               :timeout 10)))
      (let* ((items (plist-get completion :items))
             (first (aref items 0))
             (last (aref items 9999))
             (shared-token (plist-get first :data)))
        (should (= edit-range-materializations 0))
        (should (= (length items) 10000))
        (should
         (seq-every-p
          (lambda (item) (eq (plist-get item :data) shared-token)) items))
        (should-not
         (seq-some (lambda (item) (plist-member item :textEdit)) items))
        (dolist (pair (list (cons first "tw-00000")
                            (cons last "tw-09999")))
          (let* ((resolved
                  (jsonrpc-request
                   server :completionItem/resolve (car pair) :timeout 3))
                 (child-data
                  (plist-get
                   (plist-get
                    (eglotx-test--backend-state server "tailwind-volume")
                    :lastParams)
                   :data)))
            (should
             (equal
              (plist-get (plist-get resolved :textEdit) :newText)
              (cdr pair)))
            (should
             (equal
              (plist-get (plist-get resolved :textEdit) :range)
              (list :start (list :line 0 :character 16)
                    :end (list :line 0 :character 16))))
            (should (equal (plist-get resolved :resolvedBy)
                           "tailwind-volume"))
            (should (equal (plist-get resolved :label) (cdr pair)))
            (should (equal (plist-get child-data :profile)
                           "tailwind-volume"))))))))

(ert-deftest eglotx-live-completion-items-survive-facade-cache-eviction ()
  (let ((eglotx-completion-batch-limit 1)
        (eglotx-document-owner-limit 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((uri "file:///eglotx-test/completion-batch.el")
             (params (list :textDocument (list :uri uri)
                           :position (list :line 0 :character 0))))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0 :text "")))
        ;; A child state request is a protocol barrier for the preceding open.
        (eglotx-test--backend-state server "alpha")
        (let* ((first
                (jsonrpc-request
                 server :textDocument/completion params :timeout 3))
               (first-items (plist-get first :items))
               (first-alpha (aref first-items 0))
               (first-beta (aref first-items 1)))
          ;; A client which copies a JSON string without Lisp properties still
          ;; resolves through the bounded batch table while it is retained.
          (let ((copied-beta (copy-sequence first-beta)))
            (setq copied-beta
                  (plist-put
                   copied-beta :data
                   (substring-no-properties (plist-get copied-beta :data))))
            (should (equal
                     (plist-get
                      (jsonrpc-request server :completionItem/resolve
                                       copied-beta :timeout 3)
                      :resolvedBy)
                     "beta-full")))
          (let* ((second
                  (jsonrpc-request
                   server :textDocument/completion params :timeout 3))
                 (second-item (aref (plist-get second :items) 0)))
            ;; Completion UIs may retain candidates from an older response
            ;; while another CAPF consumer (for example completion-preview)
            ;; issues replacement requests.  Evicting the facade's lookup
            ;; cache must not invalidate those still-live candidate objects.
            (should (equal
                     (plist-get
                      (jsonrpc-request server :completionItem/resolve
                                       first-alpha :timeout 3)
                      :resolvedBy)
                     "alpha"))
            (should (equal
                     (plist-get
                      (jsonrpc-request server :completionItem/resolve
                                       first-beta :timeout 3)
                      :resolvedBy)
                     "beta-full"))
            (should (equal
                     (plist-get
                      (jsonrpc-request server :completionItem/resolve
                                       second-item :timeout 3)
                      :resolvedBy)
                     "alpha"))
            (jsonrpc-notify
             server :textDocument/didChange
             (list :textDocument (list :uri uri :version 1)
                   :contentChanges [(:text "changed")]))
            ;; Eglot deliberately keeps a CAPF response while the user types
            ;; more of its prefix.  Its exit function restores the request
            ;; snapshot before applying textEdit, so didChange must evict only
            ;; the facade cache, not ownership leased by the live item.
            (should (equal
                     (plist-get
                      (jsonrpc-request server :completionItem/resolve
                                       second-item :timeout 3)
                      :resolvedBy)
                     "alpha"))
            (jsonrpc-notify
             server :textDocument/didClose
             (list :textDocument (list :uri uri)))
            (jsonrpc-notify
             server :textDocument/didOpen
             (list :textDocument
                   (list :uri uri :languageId "elisp"
                         :version 0 :text "reopened")))
            (eglotx-test--backend-state server "alpha")
            ;; Reopening the same URI creates a new document incarnation; a
            ;; lease from the closed buffer must not cross that ABA boundary.
            (should-error
             (jsonrpc-request server :completionItem/resolve second-item
                              :timeout 3)
             :type 'jsonrpc-error)))))))

(ert-deftest eglotx-rejects-completion-after-in-flight-change ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-completion-alpha" :priority 100)
             (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let ((uri "file:///eglotx-test/stale-completion.el"))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "a")))
      (eglotx-test--backend-state server "slow-completion-alpha")
      (let ((timer
             (run-at-time
              0.05 nil
              (lambda ()
                (jsonrpc-notify
                 server :textDocument/didChange
                 (list :textDocument (list :uri uri :version 1)
                       :contentChanges [(:text "ab")]))))))
        (unwind-protect
            (should-error
             (jsonrpc-request
              server :textDocument/completion
              (list :textDocument (list :uri uri)
                    :position (list :line 0 :character 1))
             :timeout 3)
             :type 'jsonrpc-error)
          (when (timerp timer) (cancel-timer timer)))))))

(ert-deftest eglotx-rejects-completion-resolve-after-in-flight-change ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-resolve-alpha" :priority 100)
             (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/stale-resolve.el")
           (_open
            (jsonrpc-notify
             server :textDocument/didOpen
             (list :textDocument
                   (list :uri uri :languageId "elisp"
                         :version 0 :text "a"))))
           (_sync (eglotx-test--backend-state server "slow-resolve-alpha"))
           (completion
            (jsonrpc-request
             server :textDocument/completion
             (list :textDocument (list :uri uri)
                   :position (list :line 0 :character 1))
             :timeout 3))
           (item (aref (plist-get completion :items) 0))
           (timer
            (run-at-time
             0.05 nil
             (lambda ()
               (jsonrpc-notify
                server :textDocument/didChange
                (list :textDocument (list :uri uri :version 1)
                      :contentChanges [(:text "ab")]))))))
      (unwind-protect
          (should-error
           (jsonrpc-request server :completionItem/resolve item :timeout 3)
           :type 'jsonrpc-error)
        (when (timerp timer) (cancel-timer timer))))))

(ert-deftest eglotx-in-flight-resolve-survives-batch-eviction-until-change ()
  (let ((eglotx-completion-batch-limit 1))
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "slow-resolve-completion-batch-profile-alpha" :priority 100)
          (eglotx-test--spec "no-completion-beta" :priority 10)))
      (eglotx-test--initialize server nil t)
      (let* ((uri "file:///eglotx-test/in-flight-resolve-eviction.el")
             (params (list :textDocument (list :uri uri)
                           :position (list :line 0 :character 0))))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0 :text "")))
        (eglotx-test--backend-state
         server "slow-resolve-completion-batch-profile-alpha")
        (let* ((first-completion
                (jsonrpc-request
                 server :textDocument/completion params :timeout 3))
               (first-items (plist-get first-completion :items))
               (selected (aref first-items 0))
               (sibling (aref first-items 1))
               (shared-token (plist-get selected :data))
               resolved resolve-error)
          (should (equal shared-token (plist-get sibling :data)))
          (should-not (plist-member selected :textEdit))
          (jsonrpc-async-request
           server :completionItem/resolve selected
           :timeout 3
           :success-fn (lambda (value) (setq resolved value))
           :error-fn (lambda (failure) (setq resolve-error failure)))
          (should
           (eglotx-test--wait-until
            (lambda ()
              (eglotx-test--method-seen-p
               (eglotx-test--backend-state
                server "slow-resolve-completion-batch-profile-alpha")
               "completionItem/resolve"))))
          ;; With a one-batch limit this request evicts the batch that owned
          ;; SELECTED while its resolve is still running in the child.
          (jsonrpc-request server :textDocument/completion params :timeout 3)
          (should
           (eglotx-test--wait-until
            (lambda () (or resolved resolve-error)) 3.0))
          (should-not resolve-error)
          (should (equal (plist-get resolved :resolvedBy)
                         "slow-resolve-completion-batch-profile-alpha"))
          (should
           (equal
            (plist-get (plist-get resolved :textEdit) :newText)
            "default-a"))
          (should
           (equal
            (plist-get (plist-get resolved :textEdit) :range)
            (list :start (list :line 0 :character 0)
                  :end (list :line 0 :character 3))))
          (should
           (equal
            (plist-get
             (plist-get
              (plist-get
               (eglotx-test--backend-state
                server "slow-resolve-completion-batch-profile-alpha")
               :lastParamsByMethod)
              :completionItem/resolve)
             :data)
            (list :server "slow-resolve-completion-batch-profile-alpha"
                  :shape "default")))
          (should
           (equal
            (plist-get
             (plist-get
              (plist-get
               (eglotx-test--backend-state
                server "slow-resolve-completion-batch-profile-alpha")
               :lastParamsByMethod)
              :completionItem/resolve)
             :textEdit)
            (plist-get resolved :textEdit)))
          ;; Resolving one item that formerly shared a segment token rotates
          ;; only that returned item.  The sibling still leases the evicted
          ;; source batch through its own live completion object.
          (should-not (equal (plist-get resolved :data) shared-token))
          (should
           (equal
            (plist-get
             (jsonrpc-request server :completionItem/resolve sibling
                              :timeout 3)
             :resolvedBy)
            "slow-resolve-completion-batch-profile-alpha"))
          ;; The returned item has ownership independent of the now-evicted
          ;; response batch, but it still belongs to the original document.
          (should
           (equal
            (plist-get
             (jsonrpc-request server :completionItem/resolve resolved
                              :timeout 3)
             :resolvedBy)
            "slow-resolve-completion-batch-profile-alpha"))
          (jsonrpc-notify
           server :textDocument/didChange
           (list :textDocument (list :uri uri :version 1)
                 :contentChanges [(:text "changed")]))
          (should-error
           (jsonrpc-request server :completionItem/resolve resolved :timeout 3)
           :type 'jsonrpc-error))))))

(ert-deftest eglotx-completion-batch-updates-data-after-resolve ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "rotating-resolve-alpha" :priority 100)
             (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/rotating-resolve.el")
           (_open
            (jsonrpc-notify
             server :textDocument/didOpen
             (list :textDocument
                   (list :uri uri :languageId "elisp"
                         :version 0 :text "a"))))
           (completion
            (jsonrpc-request
             server :textDocument/completion
             (list :textDocument (list :uri uri)
                   :position (list :line 0 :character 1))
             :timeout 3))
           (item (aref (plist-get completion :items) 0))
           (token (plist-get item :data))
           (first
            (jsonrpc-request server :completionItem/resolve item :timeout 3))
           (second
            (jsonrpc-request server :completionItem/resolve first :timeout 3))
           (state
            (eglotx-test--backend-state server "rotating-resolve-alpha"))
           (child-data
            (plist-get
             (plist-get (plist-get state :lastParamsByMethod)
                        :completionItem/resolve)
             :data)))
      (should (equal (plist-get first :data) token))
      (should (equal (plist-get second :data) token))
      (should (= (plist-get child-data :revision) 1)))))

(ert-deftest eglotx-inline-completion-commands-preserve-producer-affinity ()
  (dolist (shape '("array" "list"))
    (let ((backend-name (format "beta-inline-%s" shape)))
      (eglotx-test--with-server
          (server
           (list (eglotx-test--spec "alpha" :priority 100)
                 (eglotx-test--spec backend-name :priority 10)))
        (eglotx-test--initialize server)
        (let* ((uri "file:///eglotx-test/inline.el")
               (result
                (jsonrpc-request
                 server :textDocument/inlineCompletion
                 (list :textDocument (list :uri uri)
                       :position (list :line 0 :character 0)
                       :context (list :triggerKind 1))
                 :timeout 3))
               (items (if (vectorp result)
                          result
                        (plist-get result :items)))
               (command (plist-get (aref items 0) :command))
               (token (plist-get command :command))
               (owner (gethash token (eglotx--command-owners server)))
               (backend (eglotx-test--backend server backend-name)))
          (should (= (length items) 1))
          (should (string-prefix-p "eglotx:" token))
          (should (eq (eglotx--owner-backend owner) backend))
          (let ((executed
                 (jsonrpc-request
                  server :workspace/executeCommand
                  (list :command token
                        :arguments (plist-get command :arguments))
                  :timeout 3)))
            (should (equal (plist-get executed :executedBy) backend-name))
            (should (equal (plist-get executed :command)
                           (format "eglotx.%s.inline" backend-name)))))))))

(ert-deftest eglotx-static-code-action-documentation-commands-are-owned ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "alpha" :priority 100)
        (eglotx-test--spec "beta-code-action-doc" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (capabilities (plist-get initialize :capabilities))
           (provider (plist-get capabilities :codeActionProvider))
           (documentation (plist-get provider :documentation))
           (command (plist-get (aref documentation 0) :command))
           (token (plist-get command :command))
           (backend
            (eglotx-test--backend server "beta-code-action-doc"))
           (owner (gethash token (eglotx--command-owners server))))
      ;; The primary provider has no documentation.  The lower-priority
      ;; provider's contribution must still be projected with its affinity.
      (should (= (length documentation) 1))
      (should (string-prefix-p "eglotx:" token))
      (should (eq (eglotx--owner-backend owner) backend))
      (let ((executed
             (jsonrpc-request
              server :workspace/executeCommand
              (list :command token
                    :arguments (plist-get command :arguments))
              :timeout 3)))
        (should (equal (plist-get executed :executedBy)
                       "beta-code-action-doc"))
        (should (equal (plist-get executed :command)
                       "eglotx.beta-code-action-doc.document"))))))

(ert-deftest eglotx-adapts-incremental-changes-to-full-sync-with-utf16 ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/unicode.el")
           (initial-text (concat "A" (string #x1f600) "B\n"))
           (expected-text (concat "A" (string #x1f600) "C\n"))
           (open (list :textDocument
                       (list :uri uri :languageId "elisp" :version 0
                             :text initial-text)))
           (change
            (list :textDocument (list :uri uri :version 1)
                  :contentChanges
                  (vector
                   (list :range
                         (list :start (list :line 0 :character 3)
                               :end (list :line 0 :character 4))
                         :rangeLength 1 :text "C")))))
      (jsonrpc-notify server :textDocument/didOpen open)
      (jsonrpc-notify server :textDocument/didChange change)
      (let* ((alpha-state (eglotx-test--backend-state server "alpha"))
             (beta-state (eglotx-test--backend-state server "beta-full"))
             (alpha-change (plist-get alpha-state :lastDidChange))
             (beta-change (plist-get beta-state :lastDidChange))
             (alpha-content (plist-get alpha-change :contentChanges))
             (beta-content (plist-get beta-change :contentChanges)))
        (should (plist-member (aref alpha-content 0) :range))
        (should (equal (plist-get
                        (plist-get (aref alpha-content 0) :range) :start)
                       (list :line 0 :character 3)))
        (should (= (length beta-content) 1))
        (should-not (plist-member (aref beta-content 0) :range))
        (should (equal (plist-get (aref beta-content 0) :text)
                       expected-text))))))

(ert-deftest eglotx-aggregates-and-clears-push-diagnostics-by-backend ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta-full" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let ((uri "file:///eglotx-test/diagnostics.el"))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0 :text "bad")))
        ;; State requests are FIFO fences on each independent connection.
        (eglotx-test--backend-state server "no-diagnostic-alpha")
        (eglotx-test--backend-state server "no-diagnostic-beta-full")
        (should
         (eglotx-test--wait-until
          (lambda ()
            (seq-find
             (lambda (params)
               (= (length (plist-get params :diagnostics)) 2))
             (eglotx-test--notification-params
              notifications 'textDocument/publishDiagnostics)))))
        (let* ((snapshot
                (seq-find
                 (lambda (params)
                   (= (length (plist-get params :diagnostics)) 2))
                 (eglotx-test--notification-params
                  notifications 'textDocument/publishDiagnostics)))
               (diagnostics (plist-get snapshot :diagnostics)))
          (should (equal (mapcar (lambda (item) (plist-get item :source))
                                 (append diagnostics nil))
                         '("no-diagnostic-alpha/no-diagnostic-alpha"
                           "no-diagnostic-beta-full/no-diagnostic-beta-full")))
          (dolist (diagnostic (append diagnostics nil))
            (should (string-prefix-p "eglotx:"
                                     (plist-get diagnostic :data)))))
        (setq notifications nil)
        (jsonrpc-notify
         server :textDocument/didChange
         (list :textDocument (list :uri uri :version 1)
               :contentChanges (vector (list :text "clean"))))
        (eglotx-test--backend-state server "no-diagnostic-alpha")
        (eglotx-test--backend-state server "no-diagnostic-beta-full")
        (should
         (eglotx-test--wait-until
          (lambda ()
            (seq-find
             (lambda (params)
               (= (length (plist-get params :diagnostics)) 0))
             (eglotx-test--notification-params
             notifications 'textDocument/publishDiagnostics)))))))))

(ert-deftest eglotx-streaming-session-aggregates-unopened-diagnostics-for-eglot ()
  (let ((saved-list-only-diagnostics flymake-list-only-diagnostics)
        (uri "file:///eglotx-test/unopened-diagnostics.el"))
    (unwind-protect
        (progn
          (setq flymake-list-only-diagnostics nil)
          (eglotx-test--with-server
              (server
               (list
                (eglotx-test--spec
                 "no-diagnostic-alpha" :priority 100)
                (eglotx-test--spec
                 "no-diagnostic-beta" :priority 10))
               #'eglotx-test--eglot-notification-dispatcher)
            (eglotx-test--initialize server t)
            (should (eglotx--stream-diagnostics-p server))
            (eglotx-test--publish-from-backend
             server "no-diagnostic-alpha" uri)
            (eglotx-test--publish-from-backend
             server "no-diagnostic-beta" uri)
            (should
             (eglotx-test--wait-until
              (lambda ()
                (= (length
                    (eglotx-test--list-only-diagnostics-for-uri uri))
                   2))))
            (eglotx-test--publish-from-backend
             server "no-diagnostic-beta" uri nil t)
            (should
             (eglotx-test--wait-until
              (lambda ()
                (let ((diagnostics
                       (eglotx-test--list-only-diagnostics-for-uri uri)))
                  (and (= (length diagnostics) 1)
                       (string-match-p
                        "no-diagnostic-alpha"
                        (flymake-diagnostic-text (car diagnostics))))))))))
      (setq flymake-list-only-diagnostics saved-list-only-diagnostics))))

(ert-deftest eglotx-coalesces-equivalent-diagnostic-uris-for-eglot ()
  (let ((saved-list-only-diagnostics flymake-list-only-diagnostics)
        (encoded-uri "file:///eglotx-test/uri-alias%2Eel")
        (canonical-uri "file:///eglotx-test/uri-alias.el"))
    (unwind-protect
        (progn
          (setq flymake-list-only-diagnostics nil)
          (eglotx-test--with-server
              (server
               (list
                (eglotx-test--spec
                 "no-diagnostic-alpha" :priority 100)
                (eglotx-test--spec
                 "no-diagnostic-beta" :priority 10))
               #'eglotx-test--eglot-notification-dispatcher)
            (eglotx-test--initialize server)
            (eglotx-test--publish-from-backend
             server "no-diagnostic-alpha" encoded-uri)
            (eglotx-test--publish-from-backend
             server "no-diagnostic-beta" canonical-uri)
            (should
             (eglotx-test--wait-until
              (lambda ()
                (= (length
                    (eglotx-test--list-only-diagnostics-for-uri
                     canonical-uri))
                   2))))
            (eglotx-test--publish-from-backend
             server "no-diagnostic-beta" canonical-uri nil t)
            (should
             (eglotx-test--wait-until
              (lambda ()
                (let ((diagnostics
                       (eglotx-test--list-only-diagnostics-for-uri
                        canonical-uri)))
                  (and (= (length diagnostics) 1)
                       (string-match-p
                        "no-diagnostic-alpha"
                        (flymake-diagnostic-text (car diagnostics))))))))))
      (setq flymake-list-only-diagnostics saved-list-only-diagnostics))))

(ert-deftest eglotx-canonical-file-uri-normalization-is-purely-lexical ()
  (should
   (equal
    (eglotx--canonical-file-uri
     "FILE:///c%3A/project/./src/old/../main%2Ets")
    "file:///C:/project/src/main.ts"))
  ;; RFC 8089 treats an absent authority and localhost as the local machine.
  (should
   (equal (eglotx--canonical-file-uri "file:/project/main.ts")
          "file:///project/main.ts"))
  (should
   (equal (eglotx--canonical-file-uri "file://LOCALHOST/project/main.ts")
          "file:///project/main.ts"))
  ;; Reserved encodings are not URI aliases.  In particular, decoding %2F
  ;; would merge one path segment with a real path separator.
  (should
   (equal (eglotx--canonical-file-uri "file:///project/a%2fb.ts")
          "file:///project/a%2Fb.ts"))
  (should-not
   (equal (eglotx--canonical-file-uri "file:///project/a%2Fb.ts")
          (eglotx--canonical-file-uri "file:///project/a/b.ts")))
  ;; The file normalizer is never allowed to reinterpret opaque virtual URIs.
  (should
   (equal (eglotx--canonical-file-uri "untitled:project/main%2Ets")
          "untitled:project/main%2Ets")))

(ert-deftest eglotx-backend-retirement-preserves-unopened-eglot-diagnostics ()
  (let ((saved-list-only-diagnostics flymake-list-only-diagnostics)
        (warning-minimum-level :error)
        (uri "file:///eglotx-test/retired-backend.el"))
    (unwind-protect
        (progn
          (setq flymake-list-only-diagnostics nil)
          (eglotx-test--with-server
              (server
               (list
                (eglotx-test--spec
                 "no-diagnostic-alpha" :priority 100)
                (list :name "no-diagnostic-beta"
                      :command
                      (eglotx-test--command "no-diagnostic-beta")
                      :priority 10 :required nil))
               #'eglotx-test--eglot-notification-dispatcher)
            (eglotx-test--initialize server t)
            (eglotx-test--publish-from-backend
             server "no-diagnostic-alpha" uri)
            (eglotx-test--publish-from-backend
             server "no-diagnostic-beta" uri)
            (should
             (eglotx-test--wait-until
              (lambda ()
                (= (length
                    (eglotx-test--list-only-diagnostics-for-uri uri))
                   2))))
            (let* ((backend
                    (eglotx-test--backend server "no-diagnostic-beta"))
                   (connection (eglotx--backend-connection backend)))
              (jsonrpc-async-request
               connection :eglotx.test/crash nil
               :timeout 1 :success-fn #'ignore :error-fn #'ignore
               :timeout-fn #'ignore)
              (should
               (eglotx-test--wait-until
                (lambda ()
                  (let ((diagnostics
                         (eglotx-test--list-only-diagnostics-for-uri uri)))
                    (and (eq (eglotx--backend-state backend) 'failed)
                         (= (length diagnostics) 1)
                         (string-match-p
                          "no-diagnostic-alpha"
                          (flymake-diagnostic-text
                           (car diagnostics))))))
                3.0)))))
      (setq flymake-list-only-diagnostics saved-list-only-diagnostics))))

(ert-deftest eglotx-virtualizes-pull-diagnostic-identifiers-and-cursors ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "no-push-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (provider
            (plist-get (plist-get initialize :capabilities)
                       :diagnosticProvider))
           (identifier (plist-get provider :identifier))
           (uri "file:///eglotx-test/pull-cursor.el"))
      (should (string-prefix-p "eglotx:" identifier))
      (should-not (member identifier '("no-push-alpha" "no-push-beta")))
      (let* ((first
              (jsonrpc-request
               server :textDocument/diagnostic
               (list :textDocument (list :uri uri)
                     :identifier identifier)
               :timeout 3))
             (facade-result-id (plist-get first :resultId)))
        (should (= (length (plist-get first :items)) 2))
        (should (string-prefix-p "eglotx:" facade-result-id))
        (let ((second
               (jsonrpc-request
                server :textDocument/diagnostic
                (list :textDocument (list :uri uri)
                      :identifier identifier
                      :previousResultId facade-result-id)
                :timeout 3)))
          ;; Each child returned `unchanged'; the facade materializes its
          ;; cached aggregate for Eglot and signs a fresh facade cursor.
          (should (= (length (plist-get second :items)) 2))
          (should (string-prefix-p "eglotx:"
                                   (plist-get second :resultId))))
        (dolist (name '("no-push-alpha" "no-push-beta"))
          (let* ((state (eglotx-test--backend-state server name))
                 (params
                  (plist-get (plist-get state :lastParamsByMethod)
                             :textDocument/diagnostic)))
            (should (equal (plist-get params :identifier) name))
            (should
             (equal (plist-get params :previousResultId)
                    (format "%s-result:%s" name uri)))))
        ;; A newer full aggregate retires the older facade cursor.  Reusing
        ;; the old token must force fresh child reports, never reinterpret it
        ;; against the newest global snapshot.
        (let ((newer
               (jsonrpc-request
                server :textDocument/diagnostic
                (list :textDocument (list :uri uri)
                      :identifier identifier)
                :timeout 3)))
          (should (string-prefix-p "eglotx:" (plist-get newer :resultId))))
        (let ((from-retired
               (jsonrpc-request
                server :textDocument/diagnostic
                (list :textDocument (list :uri uri)
                      :identifier identifier
                      :previousResultId facade-result-id)
                :timeout 3)))
          (should (= (length (plist-get from-retired :items)) 2)))
        (dolist (name '("no-push-alpha" "no-push-beta"))
          (let* ((state (eglotx-test--backend-state server name))
                 (params
                  (plist-get (plist-get state :lastParamsByMethod)
                             :textDocument/diagnostic)))
            (should-not (plist-member params :previousResultId))))))))

(ert-deftest eglotx-invalidates-diagnostic-cursor-across-document-reopen ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "no-push-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (uri "file:///eglotx-test/reopened-cursor.el")
           (open
            (lambda ()
              (jsonrpc-notify
               server :textDocument/didOpen
               (list :textDocument
                     (list :uri uri :languageId "elisp"
                           :version 0 :text "clean"))))))
      (funcall open)
      (eglotx-test--backend-state server "no-push-alpha")
      (eglotx-test--backend-state server "no-push-beta")
      (let* ((first
              (jsonrpc-request
               server :textDocument/diagnostic
               (list :textDocument (list :uri uri)
                     :identifier identifier)
               :timeout 3))
             (old-result-id (plist-get first :resultId)))
        (jsonrpc-notify
         server :textDocument/didClose
         (list :textDocument (list :uri uri)))
        (funcall open)
        (eglotx-test--backend-state server "no-push-alpha")
        (eglotx-test--backend-state server "no-push-beta")
        (let ((second
               (jsonrpc-request
                server :textDocument/diagnostic
                (list :textDocument (list :uri uri)
                      :identifier identifier
                      :previousResultId old-result-id)
                :timeout 3)))
          (should (= (length (plist-get second :items)) 2)))
        (dolist (name '("no-push-alpha" "no-push-beta"))
          (let* ((state (eglotx-test--backend-state server name))
                 (params
                  (plist-get (plist-get state :lastParamsByMethod)
                             :textDocument/diagnostic)))
            (should-not (plist-member params :previousResultId))))))))

(ert-deftest eglotx-invalidates-unopened-cursor-across-open-close-aba ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "no-push-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (uri "file:///eglotx-test/unopened-aba-cursor.el")
           (first
            (jsonrpc-request
             server :textDocument/diagnostic
             (list :textDocument (list :uri uri)
                   :identifier identifier)
             :timeout 3))
           (old-result-id (plist-get first :resultId)))
      ;; The document object is nil before and after this lifecycle.  Explicit
      ;; URI invalidation is therefore required; object identity alone cannot
      ;; detect this unopened -> open -> unopened ABA transition.
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp"
                   :version 0 :text "bad")))
      (jsonrpc-notify
       server :textDocument/didClose
       (list :textDocument (list :uri uri)))
      (eglotx-test--backend-state server "no-push-alpha")
      (eglotx-test--backend-state server "no-push-beta")
      (let ((second
             (jsonrpc-request
              server :textDocument/diagnostic
              (list :textDocument (list :uri uri)
                    :identifier identifier
                    :previousResultId old-result-id)
              :timeout 3)))
        (should (= (length (plist-get second :items)) 2)))
      (dolist (name '("no-push-alpha" "no-push-beta"))
        (let* ((state (eglotx-test--backend-state server name))
               (params
                (plist-get (plist-get state :lastParamsByMethod)
                           :textDocument/diagnostic)))
          (should-not (plist-member params :previousResultId)))))))

(ert-deftest eglotx-invalidates-diagnostic-cursor-across-document-change ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "no-push-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (uri "file:///eglotx-test/changed-cursor.el"))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp"
                   :version 0 :text "bad")))
      (eglotx-test--backend-state server "no-push-alpha")
      (eglotx-test--backend-state server "no-push-beta")
      (let* ((first
              (jsonrpc-request
               server :textDocument/diagnostic
               (list :textDocument (list :uri uri)
                     :identifier identifier)
               :timeout 3))
             (old-result-id (plist-get first :resultId)))
        (jsonrpc-notify
         server :textDocument/didChange
         (list :textDocument (list :uri uri :version 1)
               :contentChanges [( :text "still bad")]))
        (eglotx-test--backend-state server "no-push-alpha")
        (eglotx-test--backend-state server "no-push-beta")
        (let ((second
               (jsonrpc-request
                server :textDocument/diagnostic
                (list :textDocument (list :uri uri)
                      :identifier identifier
                      :previousResultId old-result-id)
                :timeout 3)))
          (should (= (length (plist-get second :items)) 2)))
        (dolist (name '("no-push-alpha" "no-push-beta"))
          (let* ((state (eglotx-test--backend-state server name))
                 (params
                  (plist-get (plist-get state :lastParamsByMethod)
                             :textDocument/diagnostic)))
            (should-not (plist-member params :previousResultId))))))))

(ert-deftest eglotx-rejects-primary-pull-result-after-in-flight-change ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec "no-push-slow-diagnostic-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (uri "file:///eglotx-test/in-flight-primary.el"))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "bad")))
      (eglotx-test--backend-state server "no-push-slow-diagnostic-alpha")
      (let ((timer
             (run-at-time
              0.05 nil
              (lambda ()
                (jsonrpc-notify
                 server :textDocument/didChange
                 (list :textDocument (list :uri uri :version 1)
                       :contentChanges [( :text "changed")]))))))
        (unwind-protect
            (should-error
             (jsonrpc-request
              server :textDocument/diagnostic
              (list :textDocument (list :uri uri) :identifier identifier)
              :timeout 3)
             :type 'jsonrpc-error)
          (when (timerp timer) (cancel-timer timer)))))))

(ert-deftest eglotx-omits-related-pull-result-changed-in-flight ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec
         "no-push-related-slow-diagnostic-alpha" :priority 100)
        (eglotx-test--spec "no-push-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (primary "file:///eglotx-test/in-flight-related-primary.el")
           (related "file:///eglotx-test/related-in-flight.el"))
      (dolist (uri (list primary related))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0 :text "bad"))))
      (eglotx-test--backend-state
       server "no-push-related-slow-diagnostic-alpha")
      (let ((timer
             (run-at-time
              0.05 nil
              (lambda ()
                (jsonrpc-notify
                 server :textDocument/didChange
                 (list :textDocument (list :uri related :version 1)
                       :contentChanges [( :text "changed")]))))))
        (unwind-protect
            (let ((result
                   (jsonrpc-request
                    server :textDocument/diagnostic
                    (list :textDocument (list :uri primary)
                          :identifier identifier)
                    :timeout 3)))
              (should-not (plist-member result :relatedDocuments))
              (should-not
               (gethash
                (eglotx--diagnostic-token-key
                 (eglotx-test--backend
                  server "no-push-related-slow-diagnostic-alpha")
                 related 'pull)
                (eglotx--diagnostic-snapshots server))))
          (when (timerp timer) (cancel-timer timer)))))))

(ert-deftest eglotx-forwards-only-the-selected-semantic-refresh ()
  (let (server refreshes)
    (unwind-protect
        (progn
          (setq server
                (eglotx-test--make-server
                 (list
                  (eglotx-test--spec "alpha" :priority 100)
                  (eglotx-test--spec "beta-full" :priority 10))
                 nil nil
                 (lambda (_server method params)
                   (push (cons method params) refreshes)
                   nil)))
          (eglotx-test--initialize server)
          (let ((alpha (eglotx-test--backend server "alpha"))
                (beta (eglotx-test--backend server "beta-full")))
            (let ((provider
                   '(:legend (:tokenTypes ["type"] :tokenModifiers [])
                     :full t :range :json-false)))
              (setf (eglotx--backend-capabilities alpha)
                    (list :positionEncoding "utf-16"
                          :semanticTokensProvider provider)
                    (eglotx--backend-capabilities beta)
                    (list :positionEncoding "utf-16"
                          :semanticTokensProvider provider)
                    (eglotx--client-capabilities server)
                    '(:workspace (:semanticTokens (:refreshSupport t))))
              (setf (eglotx--facade-capabilities server)
                    (eglotx--combine-capabilities
                     server (eglotx--backends server)))
              (should
               (eq (gethash :textDocument/semanticTokens/full
                            (eglotx--singleton-providers server))
                   alpha))
              ;; Only the provider whose legend was advertised may invalidate
              ;; semantic-token state.  The inactive child is acknowledged but
              ;; never reaches Eglot's upstream refresh handler.
              (eglotx-test--request-client
               server "beta-full" "workspace/semanticTokens/refresh" nil)
              (should-not refreshes)
              ;; Hold deferred work so a child-originated request burst is
              ;; deterministically coalesced before the upstream handler runs.
              (setf (eglotx--work-timer server) 'paused)
              (eglotx-test--request-client
               server "alpha" "workspace/semanticTokens/refresh" nil 64)
              (should (eglotx--semantic-refresh-pending-p server))
              (should (= (length (eglotx--work-head server)) 1))
              (should-not refreshes)
              (setf (eglotx--work-timer server) nil)
              (eglotx--drain-work server)
              (should-not (eglotx--semantic-refresh-pending-p server))
              (should (equal refreshes
                             '((workspace/semanticTokens/refresh)))))))
      (eglotx-test--stop-server server))))

(ert-deftest eglotx-isolates-malformed-pull-diagnostic-providers ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "no-push-alpha" :priority 100)
             (eglotx-test--spec "malformed-pull-beta" :priority 10)))
    (let* ((initialize (eglotx-test--initialize server))
           (identifier
            (plist-get
             (plist-get (plist-get initialize :capabilities)
                        :diagnosticProvider)
             :identifier))
           (result
            (jsonrpc-request
             server :textDocument/diagnostic
             (list :textDocument
                   (list :uri "file:///eglotx-test/malformed-pull.el")
                   :identifier identifier)
             :timeout 3)))
      (should (= (length (plist-get result :items)) 1))
      (should-not (plist-member result :resultId)))))

(ert-deftest eglotx-language-restrictions-drop-mismatched-diagnostics ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-push-alpha" :priority 100)
               (eglotx-test--spec
                "no-push-beta" :priority 10
                :languages '("typescript")))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (setf (eglotx--language-cohort server)
            '((typescript-mode . "typescript")
              (tsx-ts-mode . "typescriptreact")))
      (eglotx-test--initialize server)
      (let* ((uri "file:///eglotx-test/diagnostic.tsx")
             (restricted (eglotx-test--backend server "no-push-beta"))
             (key (eglotx--diagnostic-token-key restricted uri)))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "typescriptreact"
                     :version 0 :text "bad")))
        (eglotx-test--backend-state server "no-push-alpha")
        (let ((params
               (list
                :uri uri :version 0
                :diagnostics
                [( :range (:start (:line 0 :character 0)
                          :end (:line 0 :character 1))
                   :message "must be dropped")])))
          (eglotx--queue-diagnostics server restricted params)
          (should-not (eglotx--pending-diagnostics server))
          (eglotx--publish-diagnostics server restricted params))
        (should-not (gethash key (eglotx--diagnostic-snapshots server)))
        (should-not
         (eglotx-test--notification-params
          notifications 'textDocument/publishDiagnostics))))))

(ert-deftest eglotx-drops-stale-versioned-diagnostics-at-version-zero ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec
                "no-diagnostic-stale-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri "file:///eglotx-test/stale.el"
                   :languageId "elisp" :version 0 :text "bad")))
      (eglotx-test--backend-state server "no-diagnostic-alpha")
      (eglotx-test--backend-state server "no-diagnostic-stale-beta")
      (should
       (eglotx-test--wait-until
        (lambda ()
          (eglotx-test--notification-params
           notifications 'textDocument/publishDiagnostics))))
      (let (saw-current)
        (dolist (params
                 (eglotx-test--notification-params
                  notifications 'textDocument/publishDiagnostics))
          (dolist (diagnostic (append (plist-get params :diagnostics) nil))
            (when (string-prefix-p "no-diagnostic-alpha/"
                                   (plist-get diagnostic :source))
              (setq saw-current t))
            (should-not
             (string-prefix-p "no-diagnostic-stale-beta/"
                              (plist-get diagnostic :source)))))
        (should saw-current)))))

(ert-deftest eglotx-unopened-push-diagnostics-keep-source-version-watermarks ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-push-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((uri "file:///eglotx-test/unopened-version-watermark.el")
             (backend (eglotx-test--backend server "no-diagnostic-alpha"))
             (key (eglotx--diagnostic-token-key backend uri)))
        (eglotx-test--publish-from-backend
         server "no-diagnostic-alpha" uri 10 nil)
        (should
         (eglotx-test--wait-until
          (lambda ()
            (= (length
                (or (gethash key (eglotx--diagnostic-snapshots server)) []))
               1))))
        (eglotx-test--publish-from-backend
         server "no-diagnostic-alpha" uri 9 t)
        (should (eglotx-test--wait-until
                 (lambda () (null (eglotx--work-head server)))))
        (should (= (length (gethash key
                                    (eglotx--diagnostic-snapshots server)))
                   1))
        ;; A legal versionless clear becomes current but retains the numeric
        ;; high-water mark, so a delayed v9 cannot resurrect diagnostics.
        (eglotx-test--publish-from-backend
         server "no-diagnostic-alpha" uri nil t)
        (should (eglotx-test--wait-until
                 (lambda () (null (eglotx--work-head server)))))
        (should-not (gethash key (eglotx--diagnostic-snapshots server)))
        (should (= (gethash key (eglotx--diagnostic-version-watermarks server))
                   10))
        (eglotx-test--publish-from-backend
         server "no-diagnostic-alpha" uri 9 nil)
        (should (eglotx-test--wait-until
                 (lambda () (null (eglotx--work-head server)))))
        (should-not (gethash key (eglotx--diagnostic-snapshots server)))
        (should
         (seq-find
          (lambda (params)
            (and (equal (plist-get params :uri) uri)
                 (= (length (plist-get params :diagnostics)) 0)))
          (eglotx-test--notification-params
           notifications 'textDocument/publishDiagnostics)))))))

(ert-deftest eglotx-cancellation-reaches-every-child-request ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-alpha" :priority 100)
             (eglotx-test--spec "slow-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let (success error)
      (let ((id
             (eglotx--async-request
              server :textDocument/hover
              (list :textDocument (list :uri "file:///eglotx-test/slow.el")
                    :position (list :line 0 :character 0))
              :timeout 2
              :success-fn (lambda (result) (setq success result))
              :error-fn (lambda (failure) (setq error failure)))))
        (should (numberp id))
        (should (gethash id (eglotx--requests server)))
        (jsonrpc-notify server :$/cancelRequest (list :id id))
        (should (eglotx-test--wait-until (lambda () error)))
        (should-not success)
        (should (equal (plist-get error :code) -32800))
        (should (= (hash-table-count (eglotx--requests server)) 0)))
      (let* ((alpha-state (eglotx-test--backend-state server "slow-alpha"))
             (beta-state (eglotx-test--backend-state server "slow-beta"))
             (alpha-ids (plist-get alpha-state :cancelledIds))
             (beta-ids (plist-get beta-state :cancelledIds)))
        (should (= (length alpha-ids) 1))
        (should (= (length beta-ids) 1))
        ;; Child connections legitimately use the same local request ID;
        ;; routing remains isolated by connection.
        (should (equal (aref alpha-ids 0) (aref beta-ids 0)))))))

(ert-deftest eglotx-timeout-cancels-pending-children-and-releases-request ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-alpha" :priority 100)
             (eglotx-test--spec "slow-beta" :priority 10)))
    (eglotx-test--initialize server)
    ;; Keep process startup out of this method-level timeout assertion.
    (dolist (backend (eglotx--backends server))
      (setf (eglotx--backend-request-timeout backend) 0.08))
    (let ((started (float-time)))
      (should-error
       (jsonrpc-request
        server :textDocument/hover
        (list :textDocument (list :uri "file:///eglotx-test/timeout.el")
              :position (list :line 0 :character 0))
        :timeout 2)
       :type 'jsonrpc-error)
      (should (< (- (float-time) started) 1.0)))
    (should (= (hash-table-count (eglotx--requests server)) 0))
    (let ((alpha-state (eglotx-test--backend-state server "slow-alpha"))
          (beta-state (eglotx-test--backend-state server "slow-beta")))
      (should (= (length (plist-get alpha-state :cancelledIds)) 1))
      (should (= (length (plist-get beta-state :cancelledIds)) 1)))))

(ert-deftest eglotx-optional-start-failure-degrades-required-failure-aborts ()
  (let ((missing "/definitely/not/an/eglotx-language-server")
        (processes-before (process-list)))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (list :name "optional-missing" :command (list missing)
                     :required nil :languages '("typescript"))))
      (let* ((snapshot (eglotx--status-snapshot server))
             (backends (plist-get snapshot :backends))
             (optional (aref backends 1)))
        (should (eq (plist-get snapshot :state) 'running))
        (should (equal (plist-get optional :name) "optional-missing"))
        (should (equal (plist-get optional :languages) '("typescript")))
        (should (eq (plist-get optional :state) 'failed))
        (should (stringp (plist-get optional :lastError))))
      (should (plist-get (eglotx-test--initialize server) :capabilities)))
    (let* ((name (eglotx-test--unique-name))
           (alpha-process-name (format "%s/alpha" name)))
      (should-error
       (eglotx-test--make-server
        (list (eglotx-test--spec "alpha" :priority 100)
              (list :name "required-missing" :command (list missing)))
        nil name))
      (should
       (eglotx-test--wait-until
        (lambda ()
          (let ((process (get-process alpha-process-name)))
            (or (null process) (not (process-live-p process))))))))
    (should
     (eglotx-test--wait-until
      (lambda ()
        (not (seq-some
              (lambda (process)
                (and (not (memq process processes-before))
                     (process-live-p process)))
              (process-list))))))))

(ert-deftest eglotx-clean-shutdown-reaches-all-children ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let ((children (eglotx-test--child-processes server))
          (anchor (jsonrpc--process server)))
      (should-not (jsonrpc-request server :shutdown nil :timeout 3))
      (dolist (name '("alpha" "beta-full"))
        (should (eq (plist-get (eglotx-test--backend-state server name)
                               :shutdown)
                    t)))
      (jsonrpc-notify server :exit nil)
      ;; Mark the facade as stopping before processing the expected child
      ;; exits, matching Eglot's shutdown lifecycle.
      (jsonrpc-shutdown server t)
      (should
       (eglotx-test--wait-until
        (lambda () (not (seq-some #'process-live-p children))) 2.0))
      (should-not (process-live-p anchor))
      (should (eq (eglotx--state server) 'dead))
      (should (= (hash-table-count (eglotx--requests server)) 0)))))

(ert-deftest eglotx-unopened-push-diagnostics-round-trip-by-owner ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((uri "file:///eglotx-test/not-open.el")
             (alpha (eglotx-test--backend server "no-diagnostic-alpha"))
             (beta (eglotx-test--backend server "no-diagnostic-beta"))
             (range-a (list :start (list :line 0 :character 0)
                            :end (list :line 0 :character 1)))
             (range-b (list :start (list :line 1 :character 0)
                            :end (list :line 1 :character 1))))
        (should-not (gethash uri (eglotx--documents server)))
        ;; These deliberately have neither `data' nor `source'.  The facade
        ;; must still own them, then restore that exact absence for each child.
        (eglotx--publish-diagnostics
         server alpha
         (list :uri uri :diagnostics
               (vector (list :range range-a :message "from alpha"))))
        (eglotx--publish-diagnostics
         server beta
         (list :uri uri :diagnostics
               (vector (list :range range-b :message "from beta"))))
        (let* ((published
                (car (eglotx-test--notification-params
                      notifications 'textDocument/publishDiagnostics)))
               (diagnostics (plist-get published :diagnostics)))
          (should (= (length diagnostics) 2))
          (should (equal (mapcar (lambda (diagnostic)
                                   (plist-get diagnostic :source))
                                 (append diagnostics nil))
                         '("no-diagnostic-alpha" "no-diagnostic-beta")))
          (seq-doseq (diagnostic diagnostics)
            (let ((token (plist-get diagnostic :data)))
              (should (string-prefix-p "eglotx:" token))
              (should (gethash token (eglotx--owners server)))))
          (jsonrpc-request
           server :textDocument/codeAction
           (list :textDocument (list :uri uri)
                 :range (list :start (list :line 0 :character 0)
                              :end (list :line 0 :character 0))
                 :context (list :diagnostics diagnostics))
           :timeout 3)
          (dolist (entry `(("no-diagnostic-alpha" . "from alpha")
                           ("no-diagnostic-beta" . "from beta")))
            (let* ((state (eglotx-test--backend-state server (car entry)))
                   (params
                    (plist-get (plist-get state :lastParamsByMethod)
                               :textDocument/codeAction))
                   (child-diagnostics
                    (plist-get (plist-get params :context) :diagnostics))
                   (diagnostic (aref child-diagnostics 0)))
              (should (= (length child-diagnostics) 1))
              (should (equal (plist-get diagnostic :message) (cdr entry)))
              (should-not (plist-member diagnostic :data))
              (should-not (plist-member diagnostic :source))))
          (setq notifications nil)
          (eglotx--publish-diagnostics
           server beta (list :uri uri :diagnostics []))
          (let* ((cleared
                  (car (eglotx-test--notification-params
                        notifications 'textDocument/publishDiagnostics)))
                 (remaining (plist-get cleared :diagnostics)))
            (should (= (length remaining) 1))
            (should (equal (plist-get (aref remaining 0) :source)
                           "no-diagnostic-alpha"))))))))

(ert-deftest eglotx-empty-diagnostic-snapshots-do-not-accumulate ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "no-push-no-diagnostic-alpha" :priority 100)
             (eglotx-test--spec
              "no-push-no-diagnostic-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/empty-snapshot.el")
           (backend
            (eglotx-test--backend server "no-push-no-diagnostic-alpha"))
           (key (eglotx--diagnostic-token-key backend uri))
           (missing (make-symbol "missing")))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "one")))
      (eglotx--publish-diagnostics
       server backend (list :uri uri :version 0 :diagnostics []))
      (should (eq (gethash key (eglotx--diagnostic-snapshots server) missing)
                  missing))
      (jsonrpc-notify
       server :textDocument/didChange
       (list :textDocument (list :uri uri :version 1)
             :contentChanges (vector (list :text "two"))))
      (should (eq (gethash key (eglotx--diagnostic-snapshots server) missing)
                  missing))
      (eglotx--publish-diagnostics
       server backend (list :uri uri :version 1 :diagnostics []))
      (should (eq (gethash key (eglotx--diagnostic-snapshots server) missing)
                  missing))
      (jsonrpc-notify
       server :textDocument/didClose
       (list :textDocument (list :uri uri)))
      (should (eq (gethash key (eglotx--diagnostic-snapshots server) missing)
                  missing))
      (should-not (gethash uri (eglotx--documents server))))))

(ert-deftest eglotx-required-backend-crash-closes-the-whole-facade ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-alpha" :priority 100)
             (eglotx-test--spec "slow-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let ((children (eglotx-test--child-processes server))
          (anchor (jsonrpc--process server)))
      ;; Keep one facade request live while the required child exits so the
      ;; teardown assertion also covers pending continuation cleanup.
      (eglotx--async-request
       server :textDocument/hover
       (list :textDocument (list :uri "file:///eglotx-test/crash.el")
             :position (list :line 0 :character 0))
       :timeout 2 :success-fn #'ignore :error-fn #'ignore)
      (should (= (hash-table-count (eglotx--requests server)) 1))
      (let* ((backend (eglotx-test--backend server "slow-alpha"))
             (connection (eglotx--backend-connection backend)))
        (jsonrpc-async-request
         connection :eglotx.test/crash nil
         :timeout 1 :success-fn #'ignore :error-fn #'ignore
         :timeout-fn #'ignore))
      (should
       (eglotx-test--wait-until
        (lambda () (eq (eglotx--state server) 'dead)) 5.0))
      (should
       (eglotx-test--wait-until
        (lambda () (not (seq-some #'process-live-p children))) 2.0))
      (should-not (process-live-p anchor))
      (should (= (hash-table-count (eglotx--requests server)) 0)))))

(ert-deftest eglotx-required-initialize-failure-closes-successful-siblings ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "bad-encoding-beta" :priority 10)))
    (let ((children (eglotx-test--child-processes server))
          (anchor (jsonrpc--process server)))
      (should-error (eglotx-test--initialize server) :type 'jsonrpc-error)
      (should
       (eglotx-test--wait-until
        (lambda () (eq (eglotx--state server) 'dead)) 2.0))
      (should
       (eglotx-test--wait-until
        (lambda () (not (seq-some #'process-live-p children))) 2.0))
      (should-not (process-live-p anchor))
      (should (= (hash-table-count (eglotx--requests server)) 0)))))

(ert-deftest eglotx-optional-initialize-failure-degrades-the-session ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec
              "bad-encoding-beta" :priority 10 :required nil)))
    (let* ((result (eglotx-test--initialize server))
           (failed (eglotx-test--backend server "bad-encoding-beta")))
      (should (equal (plist-get (plist-get result :serverInfo) :name)
                     "alpha"))
      (should (eq (eglotx--state server) 'running))
      (should (eq (eglotx--backend-state failed) 'failed))
      (should
       (eglotx-test--wait-until
        (lambda ()
          (not (process-live-p
                (jsonrpc--process (eglotx--backend-connection failed)))))
        2.0)))))

(ert-deftest eglotx-malformed-static-selector-degrades-optional-backend ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec
              "malformed-static-selector-beta"
              :priority 10 :required nil)))
    (let* ((result (eglotx-test--initialize server))
           (failed
            (eglotx-test--backend server
                                  "malformed-static-selector-beta")))
      (should (equal (plist-get (plist-get result :serverInfo) :name)
                     "alpha"))
      (should (eq (eglotx--state server) 'running))
      (should (eq (eglotx--backend-state failed) 'failed))
      (should (= (hash-table-count (eglotx--requests server)) 0)))))

(ert-deftest eglotx-advertises-streaming-for-a-push-only-cohort ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
             (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
    (let* ((result (eglotx-test--initialize server t))
           (capabilities (plist-get result :capabilities)))
      (should (eq (plist-get capabilities :$streamingDiagnosticsProvider)
                  t))
      (should (eglotx--stream-diagnostics-p server)))))

(ert-deftest eglotx-semantic-only-and-progress-tokens-are-exact ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "alpha" :priority 100
              :only ["textDocument/semanticTokens/full"])
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (provider
            (list :legend (list :tokenTypes ["type"] :tokenModifiers [])
                  :full (list :delta t) :range t)))
      (setf (eglotx--backend-capabilities alpha)
            (list :positionEncoding "utf-16"
                  :semanticTokensProvider provider)
            (eglotx--backend-capabilities beta)
            (list :positionEncoding "utf-16"))
      (let* ((capabilities
              (eglotx--combine-capabilities server (eglotx--backends server)))
             (semantic (plist-get capabilities :semanticTokensProvider))
             (full (plist-get semantic :full)))
        (should (listp full))
        (should (eq (plist-get full :delta) :json-false))
        (should (eq (plist-get semantic :range) :json-false)))
      (eglotx--pin-singleton-providers server (eglotx--backends server))
      (should (eq (gethash :textDocument/semanticTokens/full
                           (eglotx--singleton-providers server))
                  alpha))
      (should-not
       (gethash :textDocument/semanticTokens/full/delta
                (eglotx--singleton-providers server)))
      (let* ((params (list :workDoneToken 1 :partialResultToken "1"))
             (fanout (eglotx--request-create :targets (list alpha beta)))
             (stripped
              (eglotx--transform-client-progress-tokens
               server alpha fanout params)))
        (should-not (plist-member stripped :workDoneToken))
        (should-not (plist-member stripped :partialResultToken))
        (should (plist-member params :workDoneToken))
        (should-not (eglotx--request-progress-mappings fanout)))
      (let* ((single (eglotx--request-create :targets (list alpha)))
             (mapped
              (eglotx--transform-client-progress-tokens
               server alpha single
               (list :workDoneToken 1 :partialResultToken "1")))
             (work (plist-get mapped :workDoneToken))
             (partial (plist-get mapped :partialResultToken)))
        (should work)
        (should-not partial)
        (should (equal (gethash work
                                (eglotx--backend-progress-forward alpha))
                       1))
        (eglotx--release-request-progress server single)
        (should (= (hash-table-count
                    (eglotx--backend-progress-forward alpha))
                   0))))))

(ert-deftest eglotx-stateful-semantic-provider-never-fails-over ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (setf (eglotx--language-cohort server)
          '((emacs-lisp-mode . "elisp")))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (alpha-provider
            '(:legend (:tokenTypes ["alpha"] :tokenModifiers [])
              :full (:delta t) :range :json-false))
           (beta-provider
            '(:legend (:tokenTypes ["beta"] :tokenModifiers [])
              :full (:delta t) :range :json-false)))
      (setf (eglotx--backend-capabilities alpha)
            (list :positionEncoding "utf-16"
                  :semanticTokensProvider alpha-provider)
            (eglotx--backend-capabilities beta)
            (list :positionEncoding "utf-16"
                  :semanticTokensProvider beta-provider))
      (clrhash (eglotx--singleton-providers server))
      (let ((capabilities
             (eglotx--combine-capabilities server (eglotx--backends server))))
        (setf (eglotx--facade-capabilities server) capabilities)
        (should
         (eq (gethash :textDocument/semanticTokens/full
                      (eglotx--singleton-providers server))
             alpha)))
      ;; Eglot may retain Alpha's resultId and legend.  Withdrawing Alpha's
      ;; contribution must hide semantic tokens, not reinterpret state on Beta.
      (setf (eglotx--backend-capabilities alpha)
            '(:positionEncoding "utf-16"))
      (let ((capabilities (eglotx--recompute-facade-capabilities server)))
        (should-not (plist-member capabilities :semanticTokensProvider))
        (should
         (eq (gethash :textDocument/semanticTokens/full
                      (eglotx--singleton-providers server))
             alpha))))))

(ert-deftest eglotx-workspace-capability-pins-file-operation-providers ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (alpha-create
            (list :filters
                  (vector
                   (list :scheme "file"
                         :pattern (list :glob "**/*.el")))))
           (beta-create
            (list :filters
                  (vector
                   (list :scheme "file"
                         :pattern (list :glob "**/*.py")))))
           (alpha-workspace
            (list :workspaceFolders
                  (list :supported :json-false
                        :changeNotifications :json-false)
                  :fileOperations
                  (list :willCreate alpha-create :didCreate alpha-create)))
           (beta-workspace
            (list :workspaceFolders
                  (list :supported t :changeNotifications t)
                  :fileOperations
                  (list :willCreate beta-create :didCreate beta-create))))
      (setf (eglotx--backend-capabilities alpha)
            (list :workspace alpha-workspace)
            (eglotx--backend-capabilities beta)
            (list :workspace beta-workspace))
      ;; Eglot 29--31 do not advertise file-operation support.  In that
      ;; normal client shape, never claim operations that Eglot cannot emit.
      (setf (eglotx--client-capabilities server)
            (list :workspace (list :workspaceFolders t)))
      (clrhash (eglotx--singleton-providers server))
      (let* ((capabilities
              (eglotx--combine-capabilities server (eglotx--backends server)))
             (workspace (plist-get capabilities :workspace)))
        (should (eq (plist-get (plist-get workspace :workspaceFolders)
                               :supported)
                    t))
        (should (eq (plist-get (plist-get workspace :workspaceFolders)
                               :changeNotifications)
                    t))
        (should-not (plist-member workspace :fileOperations)))
      ;; A synthetic supporting client gets exactly the highest-priority
      ;; provider's filters for each method, and that provider is pinned.
      (setf (eglotx--client-capabilities server)
            (list :workspace
                  (list :fileOperations
                        (list :willCreate t :didCreate t))))
      (clrhash (eglotx--singleton-providers server))
      (let* ((capabilities
              (eglotx--combine-capabilities server (eglotx--backends server)))
             (workspace (plist-get capabilities :workspace))
             (operations (plist-get workspace :fileOperations)))
        (should (equal (plist-get operations :willCreate) alpha-create))
        (should (equal (plist-get operations :didCreate) alpha-create)))
      (should (eq (gethash :workspace/willCreateFiles
                           (eglotx--singleton-providers server))
                  alpha))
      (should (eq (gethash :workspace/didCreateFiles
                           (eglotx--singleton-providers server))
                  alpha))
      (should-error
       (eglotx--handle-registration-request
        server beta
        (list :registrations
              (vector
               (list :id "dynamic-create"
                     :method "workspace/didCreateFiles"
                     :registerOptions beta-create)))
       t)
       :type 'jsonrpc-error)
      (let ((files (list :files
                         (vector
                          (list :uri "file:///eglotx-test/created.el")))))
        (should (equal
                 (eglotx--select-request-targets
                  server :workspace/willCreateFiles files
                  (eglotx--policy :workspace/willCreateFiles))
                 (list alpha)))
        (jsonrpc-notify server :workspace/didCreateFiles files)
        (let ((alpha-state (eglotx-test--backend-state server "alpha"))
              (beta-state (eglotx-test--backend-state server "beta-full")))
          (should (eglotx-test--method-seen-p
                   alpha-state "workspace/didCreateFiles"))
          (should-not (eglotx-test--method-seen-p
                       beta-state "workspace/didCreateFiles")))
        ;; Stateful singleton ownership is intentionally sticky.  A dead
        ;; selected provider must not cause cross-server failover.
        (setf (eglotx--backend-state alpha) 'failed)
        (let* ((capabilities (eglotx--recompute-facade-capabilities server))
               (workspace (plist-get capabilities :workspace)))
          (should-not (plist-member workspace :fileOperations))
          (should (eq (gethash :workspace/willCreateFiles
                               (eglotx--singleton-providers server))
                      alpha)))
        (should-not
         (eglotx--select-request-targets
          server :workspace/willCreateFiles files
          (eglotx--policy :workspace/willCreateFiles)))
        (jsonrpc-notify server :workspace/didCreateFiles files)
        (should-not
         (eglotx-test--method-seen-p
          (eglotx-test--backend-state server "beta-full")
          "workspace/didCreateFiles"))
        (setf (eglotx--backend-state alpha) 'ready)))))

(ert-deftest eglotx-notebook-sync-notifications-stay-with-advertised-provider ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (alpha-sync (list :notebookSelector [] :save t))
           (beta-sync (list :notebookSelector [] :save :json-false))
           (params (list :notebookDocument
                         (list :uri "file:///eglotx-test/notebook.ipynb"))))
      (setf (eglotx--backend-capabilities alpha)
            (list :notebookDocumentSync alpha-sync)
            (eglotx--backend-capabilities beta)
            (list :notebookDocumentSync beta-sync))
      (clrhash (eglotx--singleton-providers server))
      (should
       (equal (plist-get
               (eglotx--combine-capabilities
                server (eglotx--backends server))
               :notebookDocumentSync)
              alpha-sync))
      (dolist (method '(:notebookDocument/didOpen
                        :notebookDocument/didChange
                        :notebookDocument/didSave
                        :notebookDocument/didClose))
        (should (eq (gethash method (eglotx--singleton-providers server))
                    alpha)))
      (jsonrpc-notify server :notebookDocument/didOpen params)
      (jsonrpc-notify server :notebookDocument/didSave params)
      (let ((alpha-state (eglotx-test--backend-state server "alpha"))
            (beta-state (eglotx-test--backend-state server "beta-full")))
        (should (eglotx-test--method-seen-p
                 alpha-state "notebookDocument/didOpen"))
        (should (eglotx-test--method-seen-p
                 alpha-state "notebookDocument/didSave"))
        (should-not (eglotx-test--method-seen-p
                     beta-state "notebookDocument/didOpen")))
      (setf (eglotx--backend-capabilities alpha) nil)
      (let ((capabilities (eglotx--recompute-facade-capabilities server)))
        (should-not (plist-member capabilities :notebookDocumentSync))
        (should (eq (gethash :notebookDocument/didClose
                             (eglotx--singleton-providers server))
                    alpha)))
      (jsonrpc-notify server :notebookDocument/didClose params)
      (should-not
       (eglotx-test--method-seen-p
        (eglotx-test--backend-state server "beta-full")
        "notebookDocument/didClose")))))

(ert-deftest eglotx-file-watchers-union-and-route-to-logical-owners ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (watcher
            (list :globPattern
                  (list :baseUri "file:///eglotx-test/" :pattern "*.el")
                  :kind 7))
           (options (list :watchers (vector watcher)))
           register-calls unregister-calls)
      (setf (eglotx--project-directory server) "/eglotx-test/")
      (cl-letf (((symbol-function 'eglot-register-capability)
                 (lambda (_server method id &rest registration-options)
                   (push (list method id registration-options)
                         register-calls)))
                ((symbol-function 'eglot-unregister-capability)
                 (lambda (_server method id)
                   (push (list method id) unregister-calls))))
        (eglotx--handle-registration-request
         server alpha
         (list :registrations
               (vector
                (list :id "alpha-watch"
                      :method "workspace/didChangeWatchedFiles"
                      :registerOptions options)))
         t)
        ;; The same logical watcher from another child updates ownership but
        ;; does not churn the single physical Eglot registration.
        (eglotx--handle-registration-request
         server beta
         (list :registrations
               (vector
                (list :id "beta-watch"
                      :method "workspace/didChangeWatchedFiles"
                      :registerOptions options)))
         t)
        (pcase-let ((`(,watchers . ,selectors)
                     (eglotx--collect-file-watch-state server)))
          (should (= (length watchers) 1))
          (should (= (hash-table-count selectors) 2)))
        (should
         (eglotx-test--wait-until
          (lambda ()
            (and (= (length register-calls) 1)
                 (null (eglotx--work-head server))))
          1.0))
        (should (= (length register-calls) 1))
        (should-not unregister-calls)
        (jsonrpc-notify
         server :workspace/didChangeWatchedFiles
         (list :changes
               (vector
                (list :uri "file:///eglotx-test/match.el" :type 1)
                (list :uri "file:///eglotx-test/ignore.txt" :type 1))))
        (dolist (name '("alpha" "beta-full"))
          (let* ((state (eglotx-test--backend-state server name))
                 (methods (plist-get state :methods))
                 (params
                  (plist-get (plist-get state :lastParamsByMethod)
                             :workspace/didChangeWatchedFiles))
                 (changes (plist-get params :changes)))
            (should (= (seq-count
                        (lambda (method)
                          (equal method "workspace/didChangeWatchedFiles"))
                        methods)
                       1))
            (should (= (length changes) 1))
            (should (equal (plist-get (aref changes 0) :uri)
                           "file:///eglotx-test/match.el"))))
        (eglotx--remove-file-watches server)
        (should (= (length unregister-calls) 1))))))

(ert-deftest eglotx-file-watch-reconciliation-retries-upstream-failure ()
  (let ((eglotx--file-watch-retry-base-delay 0.01)
        (eglotx--file-watch-retry-max-delay 0.02))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let ((backend (eglotx-test--backend server "alpha"))
            (register-calls 0)
            (unregister-calls 0))
        (setf (eglotx--project-directory server) "/eglotx-test/")
        (cl-letf (((symbol-function 'eglot-register-capability)
                   (lambda (&rest _arguments)
                     (cl-incf register-calls)
                     (when (= register-calls 1)
                       (error "Synthetic watcher registration failure"))))
                  ((symbol-function 'eglot-unregister-capability)
                   (lambda (&rest _arguments)
                     (cl-incf unregister-calls))))
          (eglotx-test--request-client
           server "alpha" "client/registerCapability"
           '(:registrations
             [( :id "retry-watch"
                :method "workspace/didChangeWatchedFiles"
                :registerOptions
                (:watchers [( :globPattern "**/*.el")]))]))
          (should
           (eglotx-test--wait-until
            (lambda ()
              (and (= register-calls 2)
                   (eglotx--watch-registration-active-p server)
                   (not (eglotx--watch-rebuild-queued-p server))
                   (null (eglotx--watch-rebuild-retry-timer server))
                   (null (eglotx--work-head server))))
            1.0))
          ;; The child-visible logical registration remains committed while
          ;; the independently owned physical projection converges.
          (should (= (hash-table-count
                      (eglotx--backend-registration-methods backend))
                     1))
          (eglotx--remove-file-watches server)
          (should (= unregister-calls 1)))))))

(ert-deftest eglotx-file-watch-physical-union-has-stable-order ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let (registered-watchers)
      (setf (eglotx--project-directory server) "/eglotx-test/")
      (cl-letf (((symbol-function 'eglot-register-capability)
                 (lambda (_server _method _id &rest options)
                   (setq registered-watchers (plist-get options :watchers))))
                ((symbol-function 'eglot-unregister-capability)
                 (lambda (&rest _arguments) nil)))
        (eglotx-test--request-client
         server "alpha" "client/registerCapability"
         '(:registrations
           [( :id "z-watch" :method "workspace/didChangeWatchedFiles"
              :registerOptions (:watchers [( :globPattern "z/**")]))
            ( :id "a-watch" :method "workspace/didChangeWatchedFiles"
              :registerOptions (:watchers [( :globPattern "a/**")]))
            ( :id "m-watch" :method "workspace/didChangeWatchedFiles"
              :registerOptions (:watchers [( :globPattern "m/**")]))]))
        (should
         (eglotx-test--wait-until
          (lambda ()
            (and registered-watchers
                 (null (eglotx--work-head server))))
          1.0))
        (should
         (equal (mapcar (lambda (watcher)
                          (plist-get watcher :globPattern))
                        (append registered-watchers nil))
                '("a/**" "m/**" "z/**")))
        (eglotx--remove-file-watches server)))))

(ert-deftest eglotx-registration-protocol-rejects-non-watcher-methods ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let ((backend (eglotx-test--backend server "alpha")))
      (dolist (method '("textDocument/hover"
                        "textDocument/didChange"
                        "workspace/executeCommand"
                        "workspace/diagnostic"))
        (should-error
         (eglotx-test--request-client
          server "alpha" "client/registerCapability"
          (list :registrations
                (vector
                 (list :id (concat "rejected-" method)
                       :method method :registerOptions nil))))
         :type 'jsonrpc-error))
      (should-error
       (eglotx-test--request-client
        server "alpha" "client/unregisterCapability"
        '(:unregisterations
          [( :id "unknown-watch"
             :method "workspace/didChangeWatchedFiles")]))
       :type 'jsonrpc-error)
      (should (= (hash-table-count
                  (eglotx--backend-registration-methods backend))
                 0))
      (should-not (eglotx--watch-registration-active-p server)))))

(ert-deftest eglotx-registration-protocol-bounds-watcher-work ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let ((eglotx-file-watcher-limit 2)
          (backend (eglotx-test--backend server "alpha")))
      (should-error
       (eglotx-test--request-client
        server "alpha" "client/registerCapability"
        '(:registrations
          [( :id "watch-1" :method "workspace/didChangeWatchedFiles"
             :registerOptions (:watchers [( :globPattern "**/*.el")]))
           ( :id "watch-2" :method "workspace/didChangeWatchedFiles"
             :registerOptions (:watchers [( :globPattern "**/*.md")]))
           ( :id "watch-3" :method "workspace/didChangeWatchedFiles"
             :registerOptions (:watchers [( :globPattern "**/*.org")]))]))
       :type 'jsonrpc-error)
      (should-error
       (eglotx-test--request-client
        server "alpha" "client/registerCapability"
        '(:registrations
          [( :id "watch-many" :method "workspace/didChangeWatchedFiles"
             :registerOptions
             (:watchers [( :globPattern "**/*.el")
                          ( :globPattern "**/*.md")
                          ( :globPattern "**/*.org")]))]))
       :type 'jsonrpc-error)
      (should (= (hash-table-count
                  (eglotx--backend-registration-methods backend))
                 0))
      ;; The facade-wide cap is enforced before normalizing watcher objects in
      ;; the entry that crosses it, not only after staging the full request.
      (let ((eglotx-file-watcher-limit 3)
            (normalize-count 0)
            (normalize-function
             (symbol-function 'eglotx--normalize-file-watcher)))
        (cl-letf (((symbol-function 'eglotx--normalize-file-watcher)
                   (lambda (watcher)
                     (cl-incf normalize-count)
                     (funcall normalize-function watcher))))
          (should-error
           (eglotx--handle-registration-request
            server backend
            '(:registrations
              [( :id "watch-pair-1"
                 :method "workspace/didChangeWatchedFiles"
                 :registerOptions
                 (:watchers [( :globPattern "**/*.el")
                              ( :globPattern "**/*.md")]))
               ( :id "watch-pair-2"
                 :method "workspace/didChangeWatchedFiles"
                 :registerOptions
                 (:watchers [( :globPattern "**/*.org")
                              ( :globPattern "**/*.txt")]))])
            t)
           :type 'jsonrpc-error))
        (should (= normalize-count 2)))
      (should (= (hash-table-count
                  (eglotx--backend-registration-methods backend))
                 0)))))

(ert-deftest eglotx-registration-bounds-before-cross-backend-copy ()
  (let ((eglotx-file-watcher-limit 3))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let ((alpha (eglotx-test--backend server "alpha"))
            (beta (eglotx-test--backend server "beta-full"))
            (normalize-count 0)
            (normalize-function
             (symbol-function 'eglotx--normalize-file-watcher)))
        (setf (eglotx--project-directory server) "/eglotx-test/")
        (cl-letf (((symbol-function 'eglot-register-capability)
                   (lambda (&rest _arguments) nil))
                  ((symbol-function 'eglot-unregister-capability)
                   (lambda (&rest _arguments) nil)))
          (eglotx-test--request-client
           server "alpha" "client/registerCapability"
           '(:registrations
             [( :id "alpha-pair"
                :method "workspace/didChangeWatchedFiles"
                :registerOptions
                (:watchers [( :globPattern "**/*.el")
                             ( :globPattern "**/*.md")]))]))
          (should
           (eglotx-test--wait-until
            (lambda ()
              (and (eglotx--watch-registration-active-p server)
                   (null (eglotx--work-head server))))
            1.0))
          (cl-letf (((symbol-function 'eglotx--normalize-file-watcher)
                     (lambda (watcher)
                       (cl-incf normalize-count)
                       (funcall normalize-function watcher))))
            (should-error
             (eglotx--handle-registration-request
              server beta
              '(:registrations
                [( :id "beta-pair"
                   :method "workspace/didChangeWatchedFiles"
                   :registerOptions
                   (:watchers [( :globPattern "**/*.org")
                                ( :globPattern "**/*.txt")]))])
              t)
             :type 'jsonrpc-error))
          (should (= normalize-count 0))
          (should (= (hash-table-count
                      (eglotx--backend-registration-methods alpha))
                     1))
          (should (= (hash-table-count
                      (eglotx--backend-registration-methods beta))
                     0))
          (eglotx--remove-file-watches server))))))

(ert-deftest eglotx-hardening-preserves-empty-provider-and-save-options ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend (eglotx-test--backend server "alpha"))
           (secondary (eglotx-test--backend server "beta-full"))
           (sync (list :openClose t :change 2 :save nil))
           (uri "file:///eglotx-test/empty-options.el"))
      ;; jsonrpc.el decodes both an empty JSON object and JSON null as nil.
      ;; Presence in the containing plist is what distinguishes `{}` here.
      (setf (eglotx--backend-capabilities backend)
            (list :positionEncoding "utf-16"
                  :hoverProvider nil
                  :textDocumentSync sync)
            (eglotx--backend-text-sync backend) sync
            (eglotx--backend-capabilities secondary)
            (list :positionEncoding "utf-16"))
      (let* ((capabilities
              (eglotx--combine-capabilities server (list backend)))
             (merged-sync (plist-get capabilities :textDocumentSync))
             (hover-params
              (list :textDocument (list :uri uri)
                    :position (list :line 0 :character 0))))
        (should (plist-member capabilities :hoverProvider))
        (should-not (plist-get capabilities :hoverProvider))
        (should (eq (plist-get merged-sync :save) t))
        (should
         (equal
          (eglotx--select-request-targets
           server :textDocument/hover hover-params
           (eglotx--policy :textDocument/hover))
          (list backend))))
      (jsonrpc-notify
       server :textDocument/didSave
       (list :textDocument (list :uri uri) :text "private buffer text"))
      (let* ((state (eglotx-test--backend-state server "alpha"))
             (params
              (plist-get (plist-get state :lastParamsByMethod)
                         :textDocument/didSave)))
        (should (eglotx-test--method-seen-p
                 state "textDocument/didSave"))
        (should-not (plist-member params :text))))))

(ert-deftest eglotx-hardening-inlay-label-commands-round-trip ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend (eglotx-test--backend server "alpha"))
           (uri "file:///eglotx-test/inlay.el")
           (raw
            (list :position (list :line 0 :character 1)
                  :label
                  (vector
                   (list :value "hint"
                         :command
                         (list :title "Apply hint"
                               :command "eglotx.inlay.apply"
                               :arguments [1 "two"])))))
           (request
            (eglotx--request-create
             :method :textDocument/inlayHint
             :params (list :textDocument (list :uri uri))
             :policy (eglotx--policy :textDocument/inlayHint)))
           (merged
            (eglotx--merge-responses
             server request (list (cons backend (vector raw)))))
           (tagged (aref merged 0))
           (tagged-command
            (plist-get (aref (plist-get tagged :label) 0) :command))
           (command-token (plist-get tagged-command :command)))
      (should (string-prefix-p "eglotx:" (plist-get tagged :data)))
      (should (string-prefix-p "eglotx:" command-token))
      (should (gethash command-token (eglotx--command-owners server)))
      (should (equal
               (eglotx--owner-command
                (gethash command-token (eglotx--command-owners server)))
               "eglotx.inlay.apply"))
      (should (equal (plist-get
                      (plist-get (aref (plist-get raw :label) 0) :command)
                      :command)
                     "eglotx.inlay.apply"))
      (let ((restored
             (eglotx--transform-client-params
              server backend :inlayHint/resolve tagged)))
        (should (equal restored raw))))))

(ert-deftest eglotx-hardening-related-diagnostic-snapshots-survive-unchanged ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "no-push-alpha" :priority 100)
             (eglotx-test--spec "no-push-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend (eglotx-test--backend server "no-push-alpha"))
           (uri "file:///eglotx-test/document-diagnostic.el")
           (related-uri "file:///eglotx-test/related.el")
           (related-key (intern (concat ":" related-uri)))
           (range (list :start (list :line 0 :character 0)
                        :end (list :line 0 :character 1)))
           (request
            (eglotx--request-create
             :method :textDocument/diagnostic
             :params (list :textDocument (list :uri uri))
             :policy (eglotx--policy :textDocument/diagnostic)))
           (full
            (eglotx--merge-diagnostic-results
             server request
             (list
              (cons backend
                    (list
                     :kind "full" :items []
                     :relatedDocuments
                     (list
                      related-key
                      (list :kind "full"
                            :items
                            (vector
                             (list :range range
                                   :message "related")))))))))
           (related (plist-get full :relatedDocuments))
           (related-report (plist-get related related-key))
           (related-token
            (plist-get (aref (plist-get related-report :items) 0) :data))
           (unchanged
            (eglotx--merge-diagnostic-results
             server request
             (list
              (cons backend
                    (list
                     :kind "unchanged" :resultId "primary-fresh"
                     :relatedDocuments
                     (list related-key
                           (list :kind "unchanged"
                                 :resultId "related-fresh")))))))
           (cached
            (aref
             (plist-get
              (plist-get (plist-get unchanged :relatedDocuments)
                         related-key)
              :items)
             0)))
      (should (string-prefix-p "eglotx:" related-token))
      (should (equal (plist-get cached :message) "related"))
      (should (equal (plist-get cached :data) related-token)))))
(ert-deftest eglotx-hardening-bounds-per-document-ownership ()
  (let ((eglotx-document-owner-limit 2))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-push-alpha" :priority 100)
               (eglotx-test--spec "no-push-beta" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "no-push-alpha"))
             (uri "file:///eglotx-test/bounded-owners.el"))
        (eglotx--did-open
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0
                     :text "clean")))
        (let* ((first
                (plist-get
                 (eglotx--tag-owned-object
                  server backend (list :label "first") 'completion uri nil)
                 :data))
               (second
                (plist-get
                 (eglotx--tag-owned-object
                  server backend (list :label "second") 'completion uri nil)
                 :data))
               (third
                (plist-get
                 (eglotx--tag-owned-object
                  server backend (list :label "third") 'completion uri nil)
                 :data))
               (document (gethash uri (eglotx--documents server))))
          (should-not (gethash first (eglotx--owners server)))
          (should (gethash second (eglotx--owners server)))
          (should (gethash third (eglotx--owners server)))
          (should (= (eglotx--owner-cache-count
                      (eglotx--document-owner-ring document))
                     2))
          (should (= (hash-table-count (eglotx--owners server)) 2)))))))

(ert-deftest eglotx-hardening-registers-string-only-physical-watch-globs ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((watcher
            (list :globPattern
                  (list :baseUri "file:///eglotx-test/" :pattern "*.el")
                  :kind 7))
           registered-watchers)
      (setf (eglotx--project-directory server) "/eglotx-test/")
      (cl-letf (((symbol-function 'eglot-register-capability)
                 (lambda (_server _method _id &rest options)
                   (setq registered-watchers (plist-get options :watchers))))
                ((symbol-function 'eglot-unregister-capability)
                 (lambda (&rest _args) nil)))
        (eglotx-test--request-client
         server "alpha" "client/registerCapability"
         (list :registrations
               (vector
                (list :id "relative-watch"
                      :method "workspace/didChangeWatchedFiles"
                      :registerOptions
                      (list :watchers (vector watcher))))))
        (should
         (eglotx-test--wait-until
          (lambda ()
            (and registered-watchers
                 (null (eglotx--work-head server))))
          1.0))
        (should (= (length registered-watchers) 1))
        (should (stringp
                 (plist-get (aref registered-watchers 0) :globPattern)))
        (should (equal (plist-get (aref registered-watchers 0) :globPattern)
                       "*.el"))
        (eglotx--remove-file-watches server)))))

(ert-deftest eglotx-hardening-strips-single-target-partial-results ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend (eglotx-test--backend server "alpha"))
           (params (list :workDoneToken "work"
                         :partialResultToken "partial"))
           (request (eglotx--request-create :targets (list backend)))
           (mapped
            (eglotx--transform-client-progress-tokens
             server backend request params)))
      (should (plist-member params :partialResultToken))
      (should-not (plist-member mapped :partialResultToken))
      (should (string-prefix-p "eglotx:"
                               (plist-get mapped :workDoneToken)))
      (should (= (length (eglotx--request-progress-mappings request)) 1))
      (eglotx--release-request-progress server request)
      (should-not (eglotx--request-progress-mappings request)))))

(ert-deftest eglotx-edge-mixed-timeouts-keep-facade-unbounded ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "slow-alpha" :priority 100)
             (eglotx-test--spec "slow-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "slow-alpha"))
           (beta (eglotx-test--backend server "slow-beta"))
           (params
            (list :textDocument
                  (list :uri "file:///eglotx-test/mixed-timeout.el")
                  :position (list :line 0 :character 0))))
      (setf (eglotx--backend-request-timeout alpha) nil
            (eglotx--backend-request-timeout beta) 0.08)
      (should-not
       (eglotx--request-timeout :textDocument/hover (list alpha beta)))
      ;; The bounded beta leg times out and is cancelled, while the unbounded
      ;; alpha leg is still allowed to produce the successful facade result.
      (let* ((hover
              (jsonrpc-request server :textDocument/hover params :timeout 2))
             (value (plist-get (plist-get hover :contents) :value)))
        (should (string-match-p "hover from slow-alpha" value))
        (should-not (string-match-p "hover from slow-beta" value)))
      (let ((alpha-state (eglotx-test--backend-state server "slow-alpha"))
            (beta-state (eglotx-test--backend-state server "slow-beta")))
        (should (= (length (plist-get alpha-state :cancelledIds)) 0))
        (should (= (length (plist-get beta-state :cancelledIds)) 1))))))

(ert-deftest eglotx-edge-trigger-characters-filter-completion-and-signature ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (base
            (list :textDocument
                  (list :uri "file:///eglotx-test/triggers.el")
                  :position (list :line 0 :character 0)))
           (completion
            (append base
                    (list :context
                          (list :triggerKind 2 :triggerCharacter ":"))))
           (signature
            (append base
                    (list :context
                          (list :triggerKind 2 :triggerCharacter ",")))))
      (setf (eglotx--backend-capabilities alpha)
            (list :completionProvider (list :triggerCharacters ["."])
                  :signatureHelpProvider (list :triggerCharacters ["("]))
            (eglotx--backend-capabilities beta)
            (list :completionProvider (list :triggerCharacters [":"])
                  :signatureHelpProvider (list :triggerCharacters [","])))
      (should
       (equal
        (eglotx--select-request-targets
         server :textDocument/completion completion
         (eglotx--policy :textDocument/completion))
        (list beta)))
      (should
       (equal
        (eglotx--select-request-targets
         server :textDocument/signatureHelp signature
         (eglotx--policy :textDocument/signatureHelp))
        (list beta)))
      (should
       (equal
        (eglotx--select-request-targets
         server :textDocument/signatureHelp
         (append base
                 (list :context
                       (list :triggerKind 2 :triggerCharacter "(")))
         (eglotx--policy :textDocument/signatureHelp))
        (list alpha)))
      (should-not
       (eglotx--select-request-targets
        server :textDocument/completion
        (append base
                (list :context
                      (list :triggerKind 2 :triggerCharacter "#")))
        (eglotx--policy :textDocument/completion)))
      (let* ((result
              (jsonrpc-request
               server :textDocument/completion completion :timeout 3))
             (items (plist-get result :items)))
        (should (= (length items) 1))
        (should (equal (plist-get (aref items 0) :label)
                       "beta-full-item"))))))

(ert-deftest eglotx-edge-progress-cleanup-synthesizes-end-on-cancel-and-error ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "alpha"))
             (cancel-pending (make-hash-table :test #'eq))
             (cancel-results (make-hash-table :test #'eq))
             (cancel-request
              (eglotx--request-create
               :id 700 :method :textDocument/hover
               :policy (eglotx--policy :textDocument/hover)
               :targets (list backend) :pending cancel-pending
               :results cancel-results))
             cancel-child-token error-child-token)
        (puthash backend t cancel-pending)
        (puthash 700 cancel-request (eglotx--requests server))
        (let ((mapped
               (eglotx--transform-client-progress-tokens
                server backend cancel-request
                (list :workDoneToken "cancel-progress"))))
          (setq cancel-child-token (plist-get mapped :workDoneToken)))
        (should
         (equal
          (plist-get
           (eglotx--transform-progress-notification
            server backend
            (list :token cancel-child-token
                  :value (list :kind "begin" :title "Cancelling")))
           :token)
          "cancel-progress"))
        (eglotx--cancel-request server 700 nil)
        (let* ((error-results (make-hash-table :test #'eq))
               (error-request
                (eglotx--request-create
                 :id 701 :method :textDocument/hover
                 :policy (eglotx--policy :textDocument/hover)
                 :targets (list backend)
                 :pending (make-hash-table :test #'eq)
                 :results error-results)))
          (puthash backend
                   (cons nil (list :code -32000 :message "synthetic failure"))
                   error-results)
          (puthash 701 error-request (eglotx--requests server))
          (let ((mapped
                 (eglotx--transform-client-progress-tokens
                  server backend error-request
                  (list :workDoneToken "error-progress"))))
            (setq error-child-token (plist-get mapped :workDoneToken)))
          (eglotx--transform-progress-notification
           server backend
           (list :token error-child-token
                 :value (list :kind "begin" :title "Failing")))
          (eglotx--finish-request server error-request))
        (let* ((progress
                (eglotx-test--notification-params notifications '$/progress))
               (ends
                (seq-filter
                 (lambda (params)
                   (equal (plist-get (plist-get params :value) :kind) "end"))
                 progress)))
          (should (= (length ends) 2))
          (should
           (equal
            (sort (mapcar (lambda (params) (plist-get params :token)) ends)
                  #'string<)
            '("cancel-progress" "error-progress"))))
        (let ((next-token (eglotx--next-token server)))
          (should-not
           (eglotx--transform-progress-notification
            server backend
            (list :token cancel-child-token
                  :value (list :kind "end"))))
          (should-not
           (eglotx--transform-progress-notification
            server backend
            (list :token error-child-token
                  :value (list :kind "end"))))
          (should (= (eglotx--next-token server) next-token)))
        (should (= (hash-table-count
                    (eglotx--backend-progress-forward backend))
                   0))
        (should (= (hash-table-count
                    (eglotx--backend-progress-reverse backend))
                   0))
        (should (= (hash-table-count
                   (eglotx--backend-progress-active backend))
                   0))))))

(ert-deftest eglotx-unnegotiated-child-stream-diagnostics-are-dropped ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server t)
      (let ((uri "file:///eglotx-test/unnegotiated-stream.el"))
        ;; The facade strips this private capability from every child
        ;; initialize request.  A child that sends it anyway must not create
        ;; diagnostic state or leak the unnegotiated method to Eglot.
        (eglotx-test--notify-client
         server "no-diagnostic-alpha" "$/streamDiagnostics"
         (list
          :token "lint" :uri uri :version 0
          :diagnostics
          [( :range
              (:start (:line 0 :character 0)
               :end (:line 0 :character 1))
              :message "must be ignored")]))
        (eglotx-test--backend-state server "no-diagnostic-alpha")
        (should-not
         (eglotx-test--notification-params
          notifications '$/streamDiagnostics))
        (should-not
         (eglotx-test--notification-params
          notifications 'textDocument/publishDiagnostics))
        (should (= (hash-table-count
                    (eglotx--diagnostic-snapshots server))
                   0))
        (should (= (hash-table-count (eglotx--owners server)) 0))))))

(ert-deftest eglotx-failed-backend-diagnostic-retractions-are-chunked ()
  (let ((eglotx-diagnostic-chunk-size 2)
        notifications continuations batch-sizes)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server t)
      (let ((backend
             (eglotx-test--backend server "no-diagnostic-alpha"))
            tasks)
        (dotimes (index 5)
          (let* ((uri (format "file:///eglotx-test/retire-%d.el" index))
                 (document
                  (eglotx--document-create
                   :uri uri :version 0 :generation 0 :language-id "elisp"
                   :owner-ring
                   (eglotx--owner-cache-create
                    :limit eglotx-document-owner-limit
                    :nodes (make-hash-table :test #'equal)))))
            (puthash uri document (eglotx--documents server))
            (puthash uri document (eglotx--document-identities server))
            (push
             (list 'project backend
                   (list :uri uri :version 0 :diagnostics []))
             tasks)))
        (setq tasks (nreverse tasks))
        (cl-letf (((symbol-function 'eglotx--enqueue-urgent-work)
                   (lambda (_server function &rest arguments)
                     (setq continuations
                           (nconc continuations
                                  (list (cons function arguments)))))))
          (let ((before (length notifications)))
            (eglotx--dispatch-failed-diagnostic-retractions server tasks)
            (push (- (length notifications) before) batch-sizes))
          (while continuations
            (let* ((job (pop continuations))
                   (before (length notifications)))
              (apply (car job) (cdr job))
              (push (- (length notifications) before) batch-sizes))))
        (should (equal (nreverse batch-sizes) '(2 2 1)))
        (should (= (length
                    (eglotx-test--notification-params
                     notifications '$/streamDiagnostics))
                   5))))))

(ert-deftest eglotx-diagnostic-continuation-yields-to-next-event-turn ()
  (let ((eglotx-work-batch-size 32) events)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server t)
      ;; Build a queue without letting its zero timer race this assertion.
      (setf (eglotx--work-timer server) 'paused)
      (eglotx--enqueue-work
       server
       (lambda ()
         (push 'first events)
         (eglotx--enqueue-yielding-urgent-work
          server (lambda () (push 'continuation events)))))
      (eglotx--enqueue-work server (lambda () (push 'ordinary events)))
      (setf (eglotx--work-timer server) nil)
      (eglotx--drain-work server)
      ;; The urgent continuation remains ahead of ordinary FIFO work, but a
      ;; tracked yield prevents the current drain's remaining 31 job slots
      ;; from consuming either one.
      (should (equal events '(first)))
      (should (eglotx--work-head server))
      (when-let* ((timer (eglotx--work-timer server))
                  ((timerp timer)))
        (cancel-timer timer))
      (setf (eglotx--work-timer server) nil)
      (eglotx--drain-work server)
      (should (equal (nreverse events) '(first continuation ordinary)))
      (when-let* ((timer (eglotx--work-timer server))
                  ((timerp timer)))
        (cancel-timer timer))
      (setf (eglotx--work-timer server) nil))))

(ert-deftest eglotx-failed-backend-invalidates-cursor-without-snapshot ()
  (let ((eglotx-diagnostic-chunk-size 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server t)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/cursor-only-retirement.el")
             (values (make-hash-table :test #'eq)))
        (eglotx--touch-unopened-diagnostic-uri server uri)
        (puthash
         backend
         (eglotx--diagnostic-child-cursor-create
          :result-id "empty-result" :uri uri)
         values)
        (let ((token
               (eglotx--remember-diagnostic-cursor
                server uri values)))
          (should token)
          ;; This models an empty full report: it has incremental state but no
          ;; snapshot, version, watermark, diagnostic token, or source key.
          (should (= (eglotx--ledger-count
                      (eglotx--backend-ledger backend 'diagnostic))
                     0))
          (setf (eglotx--backend-state backend) 'failed)
          (eglotx--cleanup-failed-backend server backend)
          (should
           (eglotx-test--wait-until
            (lambda ()
              (and (null (eglotx--work-head server))
                   (null (eglotx--work-timer server))))))
          (should-not (gethash token (eglotx--diagnostic-cursors server)))
          (should-not
           (gethash uri
                    (eglotx--diagnostic-cursor-subjects server))))))))

(ert-deftest eglotx-failed-backend-cannot-repopulate-diagnostic-index ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "no-diagnostic-alpha" :priority 100 :required nil)
             (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
    (eglotx-test--initialize server t)
    (let ((backend
           (eglotx-test--backend server "no-diagnostic-alpha")))
      (setf (eglotx--backend-state backend) 'failed)
      (eglotx--queue-diagnostics
       server backend
       (list :uri "file:///eglotx-test/late-after-failure.el"
             :diagnostics []))
      (should-not (eglotx--pending-diagnostics server))
      (should (= (eglotx--ledger-count
                  (eglotx--backend-ledger backend 'diagnostic))
                 0)))))

(ert-deftest eglotx-failed-backend-cleanup-throw-still-retires-diagnostics ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "no-diagnostic-alpha" :priority 100 :required nil)
             (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend
            (eglotx-test--backend server "no-diagnostic-alpha"))
           (key
            (eglotx--diagnostic-token-key
             backend "file:///eglotx-test/cleanup-throw.el")))
      (eglotx--store-diagnostic-snapshot
       server key (vector (list :message "must retire")))
      (puthash "child-progress" "facade-progress"
               (eglotx--backend-progress-active backend))
      (setf (eglotx--backend-state backend) 'failed
            (eglotx--work-timer server) 'paused)
      ;; A JSON-RPC dispatcher is allowed to leave non-locally (for example,
      ;; through a client hook).  Diagnostic retirement is an unwind cleanup,
      ;; not a best-effort statement at the end of the outward cleanup body.
      (should
       (eq
        (catch 'eglotx-test-cleanup-exit
          (cl-letf (((symbol-function 'eglotx--end-progress)
                     (lambda (&rest _arguments)
                       (throw 'eglotx-test-cleanup-exit 'interrupted))))
            (eglotx--cleanup-failed-backend server backend))
          'fell-through)
        'interrupted))
      (should (eglotx--work-head server))
      (while (eglotx--work-head server)
        (setf (eglotx--work-timer server) nil)
        (eglotx--drain-work server)
        (when-let* ((timer (eglotx--work-timer server))
                    ((timerp timer)))
          (cancel-timer timer)))
      (setf (eglotx--work-timer server) nil)
      (should-not (gethash key (eglotx--diagnostic-snapshots server)))
      (should (= (eglotx--ledger-count
                  (eglotx--backend-ledger backend 'diagnostic))
                 0))
      (should-not
       (eglotx--ledger-peek
        (eglotx--backend-ledger backend 'diagnostic))))))

(ert-deftest eglotx-failed-backend-retraction-throw-retries-same-task ()
  (let ((throw-once t)
        (attempts 0)
        (eglotx--retirement-retry-base-delay 60.0)
        (eglotx--retirement-retry-max-delay 60.0)
        notifications
        retirement)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (when (eq method 'textDocument/publishDiagnostics)
             (cl-incf attempts)
             (when throw-once
               (setq throw-once nil)
               (throw 'eglotx-test-retraction-exit 'interrupted)))
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/retraction-throw.el")
             (key (eglotx--diagnostic-token-key backend uri))
             (real-start
              (symbol-function
               'eglotx--start-backend-diagnostic-retirement)))
        (eglotx--store-diagnostic-snapshot
         server key (vector (list :message "must retract")))
        ;; The URI must have been projected previously; otherwise an empty
        ;; aggregate is correctly suppressed as an invisible no-op.
        (setf (eglotx--diagnostic-uri-node-projected-p
               (eglotx--touch-unopened-diagnostic-uri server uri))
              t)
        (setf (eglotx--backend-state backend) 'failed
              (eglotx--work-timer server) 'paused)
        (cl-letf (((symbol-function
                    'eglotx--start-backend-diagnostic-retirement)
                   (lambda (facade state)
                     (setq retirement state)
                     (funcall real-start facade state))))
          (eglotx--cleanup-failed-backend server backend))
        (should retirement)
        ;; Ownership and bounded-ring phases precede source removal.  Advance
        ;; one real turn at a time until the empty aggregate is ready.
        (let ((turns-left 10))
          (while (and (not
                       (eglotx--backend-retirement-retraction-head retirement))
                      (> turns-left 0))
            (setf (eglotx--work-timer server) nil)
            (eglotx--drain-work server)
            (when-let* ((timer (eglotx--work-timer server))
                        ((timerp timer)))
              (cancel-timer timer))
            (setf (eglotx--work-timer server) nil)
            (cl-decf turns-left)))
        (should
         (eglotx--backend-retirement-retraction-head retirement))
        ;; The second turn leaves through the client dispatcher.  The queue
        ;; head must remain committed until a later successful return.
        (should
         (eq
          (catch 'eglotx-test-retraction-exit
            (eglotx--drain-work server)
            'fell-through)
          'interrupted))
        (should
         (eglotx--backend-retirement-retraction-head retirement))
        (should-not
         (seq-some
          (lambda (job)
            (and (eq (car job)
                     'eglotx--advance-backend-diagnostic-retirement)
                 (eq (nth 2 job) retirement)))
          (eglotx--work-head server)))
        (should (= (eglotx--backend-retirement-retry-count retirement) 1))
        (let ((timer (eglotx--backend-retirement-retry-timer retirement)))
          (should (timerp timer))
          (cancel-timer timer))
        ;; Fire the delayed callback deterministically.  Pausing the facade
        ;; timer lets this test inspect and drain the FIFO job synchronously.
        (setf (eglotx--work-timer server) 'paused)
        (eglotx--backend-retirement-retry-fired server retirement)
        (setf (eglotx--work-timer server) nil)
        (while (eglotx--work-head server)
          (eglotx--drain-work server)
          (when-let* ((timer (eglotx--work-timer server))
                      ((timerp timer)))
            (cancel-timer timer))
          (setf (eglotx--work-timer server) nil))
        (should (= attempts 2))
        (should (= (eglotx--backend-retirement-retry-count retirement) 0))
        (should-not
         (eglotx--backend-retirement-retraction-head retirement))
        (should (eq (eglotx--backend-retirement-phase retirement) 'done))
        (should
         (= (length
             (eglotx-test--notification-params
              notifications 'textDocument/publishDiagnostics))
            1))))))

(ert-deftest eglotx-failed-backend-retraction-error-retries-same-task ()
  (let ((error-once t)
        (attempts 0)
        (ordinary-ran nil)
        (eglotx--retirement-retry-base-delay 60.0)
        (eglotx--retirement-retry-max-delay 60.0)
        notifications warning-messages)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (when (eq method 'textDocument/publishDiagnostics)
             (cl-incf attempts)
             (when error-once
               (setq error-once nil)
               (error "injected client dispatcher failure")))
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/retraction-error.el")
             (task (list 'aggregate uri))
             (cell (list task))
             (retirement
              (eglotx--backend-retirement-create
               :backend backend :phase 'retract
               :retraction-head cell :retraction-tail cell)))
        (setf (eglotx--diagnostic-uri-node-projected-p
               (eglotx--touch-unopened-diagnostic-uri server uri))
              t
              (eglotx--work-timer server) 'paused)
        (eglotx--start-backend-diagnostic-retirement server retirement)
        (eglotx--enqueue-work server (lambda () (setq ordinary-ran t)))
        (setf (eglotx--work-timer server) nil)
        ;; Deferred work catches ordinary errors.  The failed retraction stays
        ;; committed and moves to a delayed retry, so ordinary FIFO work can
        ;; run in this same drain instead of starving behind an urgent loop.
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (_type message &rest _arguments)
                     (push message warning-messages))))
          (eglotx--drain-work server))
        (should ordinary-ran)
        (should (= (length warning-messages) 1))
        (should (string-match-p
                 "Diagnostic retirement" (car warning-messages)))
        (should-not
         (seq-some
          (lambda (message)
            (string-match-p "Deferred facade work failed" message))
          warning-messages))
        (should (eq (eglotx--backend-retirement-retraction-head retirement)
                    cell))
        (should-not (eglotx--work-head server))
        (should (= (eglotx--backend-retirement-retry-count retirement) 1))
        (let ((timer (eglotx--backend-retirement-retry-timer retirement)))
          (should (timerp timer))
          (cancel-timer timer))
        (setf (eglotx--work-timer server) 'paused)
        (eglotx--backend-retirement-retry-fired server retirement)
        (setf (eglotx--work-timer server) nil)
        (eglotx--drain-work server)
        (should-not
         (eglotx--backend-retirement-retraction-head retirement))
        (should (= (eglotx--backend-retirement-retry-count retirement) 0))
        (when-let* ((timer (eglotx--work-timer server))
                    ((timerp timer)))
          (cancel-timer timer))
        (setf (eglotx--work-timer server) nil)
        (while (eglotx--work-head server)
          (eglotx--drain-work server)
          (when-let* ((timer (eglotx--work-timer server))
                      ((timerp timer)))
            (cancel-timer timer))
          (setf (eglotx--work-timer server) nil))
        (should (= attempts 2))
        (should (eq (eglotx--backend-retirement-phase retirement) 'done))
        (should (= (length notifications) 1))))))

(ert-deftest eglotx-failed-backend-retirement-retry-backoff-is-bounded ()
  (let ((eglotx--retirement-retry-base-delay 0.05)
        (eglotx--retirement-retry-max-delay 1.0)
        delays warning-attempts)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (let ((retirement (eglotx--backend-retirement-create)))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (delay _repeat _function &rest _arguments)
                     (push delay delays)
                     'eglotx-test-pending-timer))
                  ((symbol-function 'display-warning)
                   (lambda (&rest _arguments)
                     (push
                      (eglotx--backend-retirement-retry-count retirement)
                      warning-attempts))))
          (eglotx--schedule-backend-diagnostic-retirement-retry
           server retirement)
          (eglotx--warn-backend-diagnostic-retirement-error
           retirement '(error "persistent synthetic failure"))
          ;; One retirement owns at most one delayed callback.
          (eglotx--schedule-backend-diagnostic-retirement-retry
           server retirement)
          (should (= (length delays) 1))
          (setf (eglotx--backend-retirement-retry-timer retirement) nil)
          ;; Exercise saturation well beyond the point where the configured
          ;; maximum delay takes over.
          (dotimes (_index 30)
            (eglotx--schedule-backend-diagnostic-retirement-retry
             server retirement)
            (eglotx--warn-backend-diagnostic-retirement-error
             retirement '(error "persistent synthetic failure"))
            (setf (eglotx--backend-retirement-retry-timer retirement) nil)))
        (setq delays (nreverse delays))
        (setq warning-attempts (nreverse warning-attempts))
        (should (= (length delays) 31))
        (should (= (nth 0 delays) 0.05))
        (should (= (nth 1 delays) 0.1))
        (should (= (nth 2 delays) 0.2))
        (should (= (nth 3 delays) 0.4))
        (should (= (nth 4 delays) 0.8))
        (should (cl-every (lambda (delay) (<= delay 1.0)) delays))
        (should (= (car (last delays)) 1.0))
        (should (= (eglotx--backend-retirement-retry-count retirement) 21))
        (should (equal warning-attempts '(1 2 4 8 16)))))))

(ert-deftest eglotx-failed-backend-normal-retirement-drops-token-bucket-o1 ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec
              "no-diagnostic-alpha" :priority 100 :required nil)
             (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((backend
            (eglotx-test--backend server "no-diagnostic-alpha"))
           (key
            (eglotx--diagnostic-token-key
             backend "file:///eglotx-test/large-source.el")))
      (eglotx--store-diagnostic-snapshot
       server key (vector (list :message "large source")))
      ;; The contents model a source with many projected diagnostics.  Once
      ;; backend ownership and document rings were filtered as a batch, the
      ;; retirement state must remove this bucket without walking it again.
      (puthash key (number-sequence 1 4096)
               (eglotx--diagnostic-tokens server))
      (setf (eglotx--backend-state backend) 'failed
            (eglotx--work-timer server) 'paused)
      (eglotx--cleanup-failed-backend server backend)
      (cl-letf (((symbol-function 'eglotx--forget-diagnostic-token-key)
                 (lambda (&rest _arguments)
                   (ert-fail "normal retirement rescanned token bucket"))))
        (while (eglotx--work-head server)
          (setf (eglotx--work-timer server) nil)
          (eglotx--drain-work server)
          (when-let* ((timer (eglotx--work-timer server))
                      ((timerp timer)))
            (cancel-timer timer))))
      (setf (eglotx--work-timer server) nil)
      (should-not (gethash key (eglotx--diagnostic-tokens server))))))

(ert-deftest eglotx-failed-backend-owner-and-command-retirement-is-chunked ()
  (let ((eglotx-diagnostic-chunk-size 2)
        owner-removals command-removals)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((failed
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (survivor
              (eglotx-test--backend server "no-diagnostic-beta"))
             (batch-uri "file:///eglotx-test/retired-batch.el")
             (completion-params
              (list :textDocument (list :uri batch-uri)
                    :position (list :line 0 :character 0)))
             (batch-result
              (jsonrpc-request
               server :textDocument/completion completion-params :timeout 3))
             (failed-batch-item
              (aref (plist-get batch-result :items) 0))
             (survivor-batch-item
              (aref (plist-get batch-result :items) 1))
             (survivor-token
              (plist-get
               (eglotx--tag-owned-object
                server survivor (list :label "survives") 'completion
                "file:///eglotx-test/survivor.el" nil)
               :data)))
        ;; Evict the batch from the bounded facade cache before retirement.
        ;; Its still-live items retain leases, but must not revive FAILED once
        ;; that backend is no longer represented in its ledger.
        (dotimes (_ 2)
          (jsonrpc-request
           server :textDocument/completion completion-params :timeout 3))
        (should-not
         (eglotx--completion-batch-location
          server
          (substring-no-properties (plist-get failed-batch-item :data))))
        (dotimes (index 5)
          (eglotx--tag-owned-object
           server failed (list :label (format "owned-%d" index)) 'completion
           (format "file:///eglotx-test/failed-owner-%d.el" index) nil)
          (eglotx--command-token
           server failed (format "failed.command.%d" index)))
        (should (>= (eglotx--ledger-count
                     (eglotx--backend-ledger failed 'owner))
                    5))
        (should (>= (eglotx--ledger-count
                     (eglotx--backend-ledger failed 'command))
                    5))
        (setf (eglotx--backend-state failed) 'failed
              (eglotx--work-timer server) 'paused)
        (eglotx--cleanup-failed-backend server failed)
        (while (eglotx--work-head server)
          (let ((owners-before
                 (eglotx--ledger-count
                  (eglotx--backend-ledger failed 'owner)))
                (commands-before
                 (eglotx--ledger-count
                  (eglotx--backend-ledger failed 'command))))
            (setf (eglotx--work-timer server) nil)
            (eglotx--drain-work server)
            (push (- owners-before
                     (eglotx--ledger-count
                      (eglotx--backend-ledger failed 'owner)))
                  owner-removals)
            (push (- commands-before
                     (eglotx--ledger-count
                      (eglotx--backend-ledger failed 'command)))
                  command-removals))
          (when-let* ((timer (eglotx--work-timer server))
                      ((timerp timer)))
            (cancel-timer timer)))
        (setf (eglotx--work-timer server) nil)
        (should (cl-every (lambda (count) (<= count 2)) owner-removals))
        (should (cl-every (lambda (count) (<= count 2)) command-removals))
        (should-not
         (eglotx--ledger-peek (eglotx--backend-ledger failed 'owner)))
        (should-not
         (eglotx--ledger-peek (eglotx--backend-ledger failed 'command)))
        (should (gethash survivor-token (eglotx--owners server)))
        (should
         (gethash survivor-token
                  (eglotx--owner-cache-nodes
                   (eglotx--orphan-owner-ring server))))
        (should-error
         (jsonrpc-request server :completionItem/resolve failed-batch-item
                          :timeout 3)
         :type 'jsonrpc-error)
        (let ((resolved
               (jsonrpc-request server :completionItem/resolve
                                survivor-batch-item :timeout 3)))
          (should (equal (plist-get resolved :resolvedBy)
                         "no-diagnostic-beta")))))))

(ert-deftest eglotx-failed-backend-retirement-yields-between-phases ()
  (let ((eglotx-diagnostic-chunk-size 2)
        dispatch-key-counts reset-counts drain-counts)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec
                "no-diagnostic-alpha" :priority 100 :required nil)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server t)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (real-dispatch
              (symbol-function
               'eglotx--dispatch-failed-diagnostic-retractions)))
        (dotimes (index 5)
          (let ((key
                 (eglotx--diagnostic-token-key
                  backend
                  (format "file:///eglotx-test/retirement-%d.el" index))))
            (eglotx--store-diagnostic-snapshot
             server key (vector (list :message (format "d-%d" index))))))
        ;; Include pull state so the reset phase must also walk buffers in
        ;; bounded continuations after every source has been removed.
        (let ((key
               (eglotx--diagnostic-token-key
                backend "file:///eglotx-test/retirement-pull.el" 'pull)))
          (eglotx--store-diagnostic-snapshot
           server key (vector (list :message "pull"))))
        (should (= (eglotx--ledger-count
                    (eglotx--backend-ledger backend 'diagnostic))
                   6))
        (setf (eglotx--backend-state backend) 'failed
              (eglotx--work-timer server) 'paused)
        (cl-letf (((symbol-function 'eglot--managed-buffers)
                   (lambda (_server) '(buffer-0 buffer-1 buffer-2
                                       buffer-3 buffer-4)))
                  ((symbol-function
                    'eglotx--reset-eglot-pull-diagnostic-buffer)
                   (lambda (_server buffer _surviving-p)
                     (push buffer reset-counts)))
                  ((symbol-function
                    'eglotx--dispatch-failed-diagnostic-retractions)
                   (lambda (facade tasks &optional propagate-errors-p)
                     (push
                      (eglotx--ledger-count
                       (eglotx--backend-ledger backend 'diagnostic))
                      dispatch-key-counts)
                     (funcall real-dispatch facade tasks propagate-errors-p))))
          (eglotx--cleanup-failed-backend server backend)
          (while (eglotx--work-head server)
            (setf (eglotx--work-timer server) nil)
            (let ((before (length reset-counts)))
              (eglotx--drain-work server)
              (push
               (list
                (eglotx--ledger-count
                 (eglotx--backend-ledger backend 'diagnostic))
                (- (length reset-counts) before))
               drain-counts))
            (when-let* ((timer (eglotx--work-timer server))
                        ((timerp timer)))
              (cancel-timer timer)))
          (setf (eglotx--work-timer server) nil))
        ;; Ownership/ring setup keeps the source count at six; then removal is
        ;; two keys per real event turn.  No retraction runs until the index
        ;; reaches zero, and pull resets are likewise at most two.
        (setq drain-counts (nreverse drain-counts))
        (should (equal (delete-dups (mapcar #'car drain-counts))
                       '(6 4 2 0)))
        (should dispatch-key-counts)
        (should (cl-every #'zerop dispatch-key-counts))
        (should (= (length reset-counts) 5))
        (should
         (cl-every (lambda (entry) (<= (cadr entry) 2)) drain-counts))
        (should (= (eglotx--ledger-count
                    (eglotx--backend-ledger backend 'diagnostic))
                   0))
        (should-not
         (eglotx--ledger-peek
          (eglotx--backend-ledger backend 'diagnostic)))))))

(ert-deftest eglotx-unopened-diagnostic-uri-ledger-is-bounded-and-retracts ()
  (let ((eglotx-unopened-diagnostic-uri-limit 2)
        notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uris
              (mapcar
               (lambda (suffix)
                 (format "file:///eglotx-test/unopened-lru-%s.el" suffix))
               '(a b c)))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1))))
        (cl-loop for uri in uris
                 for message in '("a" "b" "c")
                 do
          (eglotx--publish-diagnostics
           server backend
           (list :uri uri :version 1
                 :diagnostics
                 (vector (list :range range :message message)))))
        (should (= (hash-table-count
                    (eglotx--diagnostic-uri-nodes server))
                   2))
        (let ((evicted-key
               (eglotx--diagnostic-token-key backend (car uris))))
          (should-not
           (gethash evicted-key
                    (eglotx--diagnostic-version-watermarks server))))
        ;; The outward retraction is exact and an evicted watermark no longer
        ;; rejects a newly observed (even numerically older) source history.
        (should
         (= (cl-count
             (car uris)
             (eglotx-test--notification-params
              notifications 'textDocument/publishDiagnostics)
             :key (lambda (params) (plist-get params :uri))
             :test #'equal)
            2))
        (eglotx--publish-diagnostics
         server backend
         (list :uri (car uris) :version 0
               :diagnostics
               (vector (list :range range :message "new history"))))
        (let ((snapshot
               (gethash
                (eglotx--diagnostic-token-key backend (car uris))
                (eglotx--diagnostic-snapshots server))))
          (should (= (length snapshot) 1))
          (should (equal (plist-get (aref snapshot 0) :message)
                         "new history")))
        (should (= (hash-table-count
                    (eglotx--diagnostic-uri-nodes server))
                   2))))))

(ert-deftest eglotx-unopened-diagnostic-eviction-clears-supported-modalities ()
  (let ((eglotx-unopened-diagnostic-uri-limit 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/all-modalities-victim.el")
             (replacement "file:///eglotx-test/all-modalities-new.el")
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
             (item (list :range range :message "owned"))
             (modalities '(push pull))
             (cursor-values (make-hash-table :test #'eq)))
        (eglotx--publish-diagnostics
         server backend (list :uri uri :version 1
                              :diagnostics (vector item)))
        (eglotx--pull-diagnostic-snapshot
         server backend uri (list :kind "full" :items (vector item)))
        (puthash
         backend
         (eglotx--diagnostic-child-cursor-create :result-id "child-result")
         cursor-values)
        (let ((cursor
               (eglotx--remember-diagnostic-cursor
                server uri cursor-values)))
          (should cursor)
          (eglotx--publish-diagnostics
           server backend
           (list :uri replacement :version 1
                 :diagnostics (vector item)))
          (dolist (modality modalities)
            (let ((key
                   (eglotx--diagnostic-token-key backend uri modality)))
              (should-not
               (gethash key (eglotx--diagnostic-tokens server)))
              (should-not
               (gethash key (eglotx--diagnostic-snapshots server)))
              (should-not
               (gethash key
                        (eglotx--diagnostic-version-watermarks server)))))
          (should-not (gethash cursor (eglotx--diagnostic-cursors server)))
          (should
           (cl-every
            (lambda (owner)
              (not (equal (eglotx--owner-uri owner) uri)))
            (hash-table-values (eglotx--owners server)))))))))

(ert-deftest eglotx-unopened-diagnostic-uri-ledger-exempts-open-documents ()
  (let ((eglotx-unopened-diagnostic-uri-limit 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (open-uri "file:///eglotx-test/open-diagnostic.el")
             (unopened-a "file:///eglotx-test/unopened-a.el")
             (unopened-b "file:///eglotx-test/unopened-b.el")
             (open-key (eglotx--diagnostic-token-key backend open-uri)))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri open-uri :languageId "elisp"
                     :version 0 :text "bad")))
        (should
         (eglotx-test--wait-until
          (lambda () (eglotx--document-for-uri server open-uri))))
        (eglotx--publish-diagnostics
         server backend (list :uri open-uri :version 0 :diagnostics []))
        (eglotx--publish-diagnostics
         server backend (list :uri unopened-a :version 1 :diagnostics []))
        (eglotx--publish-diagnostics
         server backend (list :uri unopened-b :version 1 :diagnostics []))
        (should (= (hash-table-count
                    (eglotx--diagnostic-uri-nodes server))
                   1))
        (should (= (gethash open-key
                            (eglotx--diagnostic-version-watermarks server))
                   0))))))

(ert-deftest eglotx-unopened-diagnostic-clear-prunes-real-eglot-state ()
  (let ((flymake-list-only-diagnostics nil))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         #'eglotx-test--eglot-notification-dispatcher)
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/real-eglot-unopened.el")
             (path (expand-file-name (eglot-uri-to-path uri)))
             (opened-uri "file:///eglotx-test/real-eglot-opened.el")
             (opened-path
              (expand-file-name (eglot-uri-to-path opened-uri)))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1))))
        (eglotx--publish-diagnostics
         server backend
         (list :uri uri
               :diagnostics
               (vector (list :range range :message "visible"))))
        (should
         (seq-find
          (lambda (entry)
            (equal (substring-no-properties (car entry)) path))
          flymake-list-only-diagnostics))
        (eglotx--publish-diagnostics
         server backend (list :uri uri :diagnostics []))
        ;; Eglot itself retains (PATH . nil) after a standard clear.  Since the
        ;; facade and Eglot share a process, remove that exact server-owned cell
        ;; so cycling through unopened files is bounded end to end.
        (should-not
         (seq-find
          (lambda (entry)
            (let ((key (car entry)))
              (and (equal (substring-no-properties key) path)
                   (eq (get-text-property 0 'eglot--server key) server))))
          flymake-list-only-diagnostics))
        (eglotx--publish-diagnostics
         server backend
         (list :uri opened-uri
               :diagnostics
               (vector (list :range range :message "open me"))))
        (cl-letf (((symbol-function 'eglotx--notify-backend) #'ignore))
          (eglotx--did-open
           server :textDocument/didOpen
           (list :textDocument
                 (list :uri opened-uri :languageId "elisp"
                       :version 0 :text "bad"))))
        (should (eglotx--document-for-uri server opened-uri))
        (should-not
         (seq-find
          (lambda (entry)
            (let ((key (car entry)))
              (and (equal (substring-no-properties key) opened-path)
                   (eq (get-text-property 0 'eglot--server key) server))))
          flymake-list-only-diagnostics))))))

(ert-deftest eglotx-unopened-diagnostic-eviction-does-not-mint-stale-cursor ()
  (let ((eglotx-unopened-diagnostic-uri-limit 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-push-alpha" :priority 100)
               (eglotx-test--spec "no-push-beta" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "no-push-alpha"))
             (primary-uri "file:///eglotx-test/cursor-primary.el")
             (related-uri "file:///eglotx-test/cursor-related.el")
             (related-key (intern (concat ":" related-uri)))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
             (request
              (eglotx--request-create
               :method :textDocument/diagnostic
               :params (list :textDocument (list :uri primary-uri))
               :policy (eglotx--policy :textDocument/diagnostic)
               :targets (list backend)))
             (merged
              (eglotx--merge-diagnostic-results
               server request
               (list
                (cons
                 backend
                 (list
                  :kind "full" :resultId "primary-result"
                  :items
                  (vector (list :range range :message "primary"))
                  :relatedDocuments
                  (list
                   related-key
                   (list
                    :kind "full" :resultId "related-result"
                    :items
                    (vector
                     (list :range range :message "related"))))))))))
        ;; Related is touched after primary and evicts it at limit=1.  Exposing
        ;; primary-result here would let the next child answer `unchanged'
        ;; even though the facade no longer owns the corresponding snapshot.
        (should-not (plist-member merged :resultId))
        (should
         (string-prefix-p
          "eglotx:"
          (plist-get
           (plist-get (plist-get merged :relatedDocuments) related-key)
           :resultId)))
        (should-not
         (gethash
          (eglotx--canonical-document-uri server primary-uri)
          (eglotx--diagnostic-cursor-subjects server)))))))

(ert-deftest eglotx-edge-fast-progress-precedes-request-finalization ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "fast-progress-alpha" :priority 100)
               (eglotx-test--spec "no-hover-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let ((result
             (jsonrpc-request
              server :textDocument/hover
              (list :textDocument
                    (list :uri "file:///eglotx-test/fast-progress.el")
                    :position (list :line 0 :character 0)
                    :workDoneToken "facade-fast-progress")
              :timeout 3)))
        (should (plist-member result :contents)))
      (let* ((progress
              (eglotx-test--notification-params notifications '$/progress))
             (kinds
              (mapcar (lambda (params)
                        (plist-get (plist-get params :value) :kind))
                      progress)))
        (should (= (length progress) 2))
        (should (member "begin" kinds))
        (should (member "end" kinds))
        (dolist (params progress)
          (should (equal (plist-get params :token)
                         "facade-fast-progress"))))
      (let ((backend (eglotx-test--backend server "fast-progress-alpha")))
        (should (= (hash-table-count
                    (eglotx--backend-progress-forward backend))
                   0))
        (should (= (hash-table-count
                    (eglotx--backend-progress-active backend))
                   0))))))

(ert-deftest eglotx-edge-active-child-request-cancels-with-lsp-error ()
  (let (entered completed caught)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         nil
         (lambda (_connection method _params)
           (when (eq method 'eglotx.test/cancellable)
             (setq entered t)
             ;; Yield long enough for the child cancellation frame to run.
             ;; Without connection-scoped cancellation the handler completes
             ;; normally, keeping this red test bounded rather than hanging.
             (let ((deadline (+ (float-time) 0.25)))
               (while (< (float-time) deadline)
                 (accept-process-output nil 0.01)))
             (setq completed t)
             "uncancelled")))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "alpha"))
             (connection (eglotx--backend-connection backend)))
        (dolist (request-id '("string-child-id" 0))
          (setq entered nil completed nil caught nil)
          (condition-case error-data
              (jsonrpc-request
               connection :eglotx.test/requestClient
               (list :method "eglotx.test/cancellable" :params nil
                     :requestId request-id :cancel t)
               :timeout 3)
            (jsonrpc-error (setq caught error-data)))
          (should entered)
          (should-not completed)
          (should caught)
          (should
           (= (alist-get 'jsonrpc-error-code (cddr caught)) -32800)))))))

(ert-deftest eglotx-edge-child-cancellation-is-scoped-by-backend-and-id ()
  (let (alpha-caught alpha-completed beta-completed)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         nil
         (lambda (_connection method params)
           (when (eq method 'eglotx.test/scoped-cancellation)
             (pcase (plist-get params :role)
               ("alpha"
                (let ((deadline (+ (float-time) 0.25)))
                  (while (< (float-time) deadline)
                    (accept-process-output nil 0.01)))
                (setq alpha-completed t)
                "alpha-uncancelled")
               ("beta"
                ;; Both children deliberately use the same raw JSON-RPC ID.
                ;; Cancelling alpha must not unwind beta's outer handler.
                (let* ((alpha (eglotx-test--backend server "alpha"))
                       (connection (eglotx--backend-connection alpha)))
                  (condition-case error-data
                      (jsonrpc-request
                       connection :eglotx.test/requestClient
                       '(:method "eglotx.test/scoped-cancellation"
                         :params (:role "alpha")
                         :requestId "same-id" :cancel t)
                       :timeout 3)
                    (jsonrpc-error (setq alpha-caught error-data))))
                (setq beta-completed t)
                "beta-survived")))))
      (eglotx-test--initialize server)
      (let* ((beta (eglotx-test--backend server "beta-full"))
             (connection (eglotx--backend-connection beta))
             (responses
              (jsonrpc-request
               connection :eglotx.test/requestClient
               '(:method "eglotx.test/scoped-cancellation"
                 :params (:role "beta") :requestId "same-id")
               :timeout 3))
             (response
              (json-parse-string (aref responses 0) :object-type 'plist)))
        (should (equal (plist-get response :result) "beta-survived")))
      (should alpha-caught)
      (should (= (alist-get 'jsonrpc-error-code (cddr alpha-caught)) -32800))
      (should-not alpha-completed)
      (should beta-completed))))

(ert-deftest eglotx-edge-outer-cancel-preserves-nested-same-child-request ()
  (let (connection outer-returned inner-returned sent)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         nil
         (lambda (_connection method params)
           (when (eq method 'eglotx.test/nested-cancellation)
             (pcase (plist-get params :role)
               ("outer"
                (jsonrpc-connection-receive
                 connection
                 '(:jsonrpc "2.0" :id "inner-request"
                   :method "eglotx.test/nested-cancellation"
                   :params (:role "inner")))
                ;; Cancellation of this outer request was received while the
                ;; inner handler was deepest.  The inner reply must return us
                ;; here; only this eventual result is converted to -32800.
                (setq outer-returned t)
                "outer-result")
               ("inner"
                (jsonrpc-connection-receive
                 connection
                 '(:jsonrpc "2.0" :method "$/cancelRequest"
                   :params (:id "outer-request")))
                (setq inner-returned t)
                "inner-result")))))
      (eglotx-test--initialize server)
      (setq connection
            (eglotx--backend-connection
             (eglotx-test--backend server "alpha")))
      (let ((original-send (symbol-function 'jsonrpc-connection-send)))
        (cl-letf (((symbol-function 'jsonrpc-connection-send)
                   (lambda (target &rest arguments)
                     (if (eq target connection)
                         (push (copy-tree arguments) sent)
                       (apply original-send target arguments)))))
          (jsonrpc-connection-receive
           connection
           '(:jsonrpc "2.0" :id "outer-request"
             :method "eglotx.test/nested-cancellation"
             :params (:role "outer")))))
      (should inner-returned)
      (should outer-returned)
      (let ((inner (seq-find
                    (lambda (reply)
                      (equal (plist-get reply :id) "inner-request"))
                    sent))
            (outer (seq-find
                    (lambda (reply)
                      (equal (plist-get reply :id) "outer-request"))
                    sent)))
        (should (equal (plist-get inner :result) "inner-result"))
        (should (= (plist-get (plist-get outer :error) :code) -32800))))))

(ert-deftest eglotx-edge-child-cancel-request-cannot-cross-cancel-facade-id ()
  (let (notifications)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((id 4242)
             (request
              (eglotx--request-create
               :id id :method :textDocument/hover
               :policy (eglotx--policy :textDocument/hover)
               :targets nil :pending (make-hash-table :test #'eq)
               :results (make-hash-table :test #'eq))))
        (puthash id request (eglotx--requests server))
        (eglotx-test--notify-client
         server "alpha" "$/cancelRequest" (list :id id))
        (should
         (eglotx-test--wait-until
          (lambda ()
            (and (null (eglotx--work-head server))
                 (null (eglotx--work-timer server))))))
        (should (eq (gethash id (eglotx--requests server)) request))
        (should-not
         (eglotx-test--notification-params notifications '$/cancelRequest))
        (remhash id (eglotx--requests server))))))

(ert-deftest eglotx-edge-plaintext-hover-and-exact-append-deduplication ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (plaintext "**not bold**\n```")
           (markdown
            (eglotx--hover-markdown
             (list :kind "plaintext" :value plaintext)))
           (range-a (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
           (range-b (list :start (list :line 1 :character 0)
                          :end (list :line 1 :character 1)))
           (duplicate (list :range range-a :kind 1))
           (alpha-only (list :range range-b :kind 1))
           (near-duplicate (list :range range-a :kind 2))
           (request
            (eglotx--request-create
             :method :textDocument/documentHighlight
             :params
             (list :textDocument
                   (list :uri "file:///eglotx-test/deduplicate.el"))
             :policy (eglotx--policy :textDocument/documentHighlight)))
           (merged
            (eglotx--merge-responses
             server request
             (list (cons alpha (vector duplicate alpha-only))
                   (cons beta (vector (copy-tree duplicate)
                                      near-duplicate))))))
      (should-not (equal markdown plaintext))
      (should (string-prefix-p "````\n" markdown))
      (should (string-suffix-p "\n````" markdown))
      (should (string-match-p (regexp-quote plaintext) markdown))
      (should (= (length merged) 3))
      (should (equal (append merged nil)
                     (list duplicate alpha-only near-duplicate))))))

(ert-deftest eglotx-completion-default-and-override-survive-data-less-resolve ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec
         "completion-batch-profile-alpha" :priority 100)
        (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server nil t)
    (let* ((uri "file:///eglotx-test/default-and-override.el")
           (params (list :textDocument (list :uri uri)
                         :position (list :line 0 :character 0))))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "")))
      (let* ((completion
              (jsonrpc-request
               server :textDocument/completion params :timeout 3))
             (items (plist-get completion :items))
             (first-default (aref items 0))
             (second-default (aref items 1))
             (override (aref items 2))
             (expected-default
              (list :server "completion-batch-profile-alpha"
                    :shape "default"))
             (expected-override (list :shape "override" :value 9))
             (expected-range
              (list :start (list :line 0 :character 0)
                    :end (list :line 0 :character 3))))
        (should
         (equal (mapcar (lambda (item) (plist-get item :label))
                        (append items nil))
                '("default-a" "default-b" "override")))
        (should-not
         (seq-some (lambda (item) (plist-member item :textEdit)) items))
        (should (equal (plist-get override :textEditText) "replacement"))
        (cl-loop
         for item in (list first-default second-default)
         for expected-text in '("default-a" "default-b")
         do
         (let* ((resolved
                 (jsonrpc-request server :completionItem/resolve item
                                  :timeout 3))
                (child-params
                 (plist-get
                  (eglotx-test--backend-state
                   server "completion-batch-profile-alpha")
                  :lastParams)))
           (should (equal (plist-get resolved :resolvedBy)
                          "completion-batch-profile-alpha"))
           (should (equal (plist-get child-params :data)
                          expected-default))
           (when (equal expected-text "default-b")
             ;; LSP uses the label, not insertText, with a default editRange.
             (should (equal (plist-get child-params :insertText)
                            "inserted-b")))
           (dolist (candidate (list child-params resolved))
             (let ((edit (plist-get candidate :textEdit)))
               (should (equal (plist-get edit :newText) expected-text))
               (should (equal (plist-get edit :range) expected-range)))
             (should-not (plist-member candidate :textEditText)))))
        (let* ((token (plist-get override :data))
               (first-resolve
                (jsonrpc-request server :completionItem/resolve override
                                 :timeout 3))
               (first-child-params
                (plist-get
                 (eglotx-test--backend-state
                  server "completion-batch-profile-alpha")
                 :lastParams))
               (first-child-data (plist-get first-child-params :data))
               (second-resolve
                (jsonrpc-request server :completionItem/resolve first-resolve
                                 :timeout 3))
               (second-child-data
                (plist-get
                 (plist-get
                  (eglotx-test--backend-state
                   server "completion-batch-profile-alpha")
                  :lastParams)
                 :data)))
          ;; The child deliberately omits data in both resolve responses.
          ;; Eglotx must keep its handle and restore the original override on
          ;; every later child request.
          (should (equal (plist-get first-resolve :data) token))
          (should (equal (plist-get second-resolve :data) token))
          (should (equal first-child-data expected-override))
          (should (equal second-child-data expected-override))
          (dolist (candidate (list first-child-params first-resolve
                                   second-resolve))
            (let ((edit (plist-get candidate :textEdit)))
              (should (equal (plist-get edit :newText) "replacement"))
              (should (equal (plist-get edit :range) expected-range)))
            (should-not (plist-member candidate :textEditText))))))))

(ert-deftest eglotx-completion-batch-preserves-every-data-shape ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec
         "completion-batch-profile-alpha" :priority 100)
        (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((uri "file:///eglotx-test/completion-data-shapes.el")
           (params (list :textDocument (list :uri uri)
                         :position (list :line 0 :character 1))))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "")))
      (let* ((completion
              (jsonrpc-request
               server :textDocument/completion params :timeout 3))
             (items (plist-get completion :items))
             (expected
              '(("absent" nil nil)
                ("null" t nil)
                ("false" t :json-false)
                ("object" t (:shape "object" :value 7)))))
        (cl-loop
         for item across items
         for (label present-p value) in expected
         do
         (jsonrpc-request server :completionItem/resolve item :timeout 3)
         (let* ((state
                 (eglotx-test--backend-state
                  server "completion-batch-profile-alpha"))
                (child-params (plist-get state :lastParams)))
           (should (equal (plist-get item :label) label))
           (should
            (eq (and (plist-member child-params :data) t) present-p))
           (when present-p
             (should (equal (plist-get child-params :data) value)))))))))

(ert-deftest eglotx-completion-local-resolve-materializes-insert-replace ()
  (let ((eglotx-completion-batch-limit 1))
    (eglotx-test--with-server
        (server
         (list
          (eglotx-test--spec
           "no-resolve-insert-replace-completion-batch-profile-alpha"
           :priority 100)
          (eglotx-test--spec "no-completion-beta" :priority 10)))
      (let* ((initialize (eglotx-test--initialize server nil t))
             (provider
              (plist-get (plist-get initialize :capabilities)
                         :completionProvider))
             (uri "file:///eglotx-test/local-resolve.el")
             (params (list :textDocument (list :uri uri)
                           :position (list :line 0 :character 0))))
        (should (eq (plist-get provider :resolveProvider) t))
        (jsonrpc-notify
         server :textDocument/didOpen
         (list :textDocument
               (list :uri uri :languageId "elisp" :version 0 :text "old")))
        (let* ((completion
                (jsonrpc-request
                 server :textDocument/completion params :timeout 3))
               (item (aref (plist-get completion :items) 2))
               (batch-token (plist-get item :data))
               (resolved
                (jsonrpc-request server :completionItem/resolve item
                                 :timeout 3))
               (resolved-token (plist-get resolved :data))
               (edit (plist-get resolved :textEdit))
               (owner (eglotx--owner-for-params server resolved))
               (state
                (eglotx-test--backend-state
                 server
                 "no-resolve-insert-replace-completion-batch-profile-alpha")))
          (should-not (plist-member item :textEdit))
          (should-not (equal resolved-token batch-token))
          (should (equal (eglotx--owner-data owner)
                         '(:shape "override" :value 9)))
          (should (equal (plist-get edit :newText) "replacement"))
          (should (plist-member edit :insert))
          (should (plist-member edit :replace))
          (should-not (plist-member edit :range))
          ;; A second result evicts the compact source batch.  The selected
          ;; item has become an ordinary bounded owner and remains resolvable.
          ;; Strip the live token's private lease to observe only the bounded
          ;; facade lookup cache.
          (jsonrpc-request server :textDocument/completion params :timeout 3)
          (should-not
           (eglotx--completion-batch-location
            server (substring-no-properties batch-token)))
          (let* ((resolved-again
                  (jsonrpc-request server :completionItem/resolve resolved
                                   :timeout 3))
                 (edit-again (plist-get resolved-again :textEdit)))
            (should (equal (plist-get resolved-again :data) resolved-token))
            (should (equal edit-again edit)))
          (should-not
           (eglotx-test--method-seen-p state "completionItem/resolve")))))))

(ert-deftest eglotx-completion-eager-default-fallback-without-client-support ()
  (eglotx-test--with-server
      (server
       (list
        (eglotx-test--spec
         "completion-batch-profile-alpha" :priority 100)
        (eglotx-test--spec "no-completion-beta" :priority 10)))
    (eglotx-test--initialize server)
    (let ((uri "file:///eglotx-test/eager-completion-default.el"))
      (jsonrpc-notify
       server :textDocument/didOpen
       (list :textDocument
             (list :uri uri :languageId "elisp" :version 0 :text "old")))
      (let* ((completion
              (jsonrpc-request
               server :textDocument/completion
               (list :textDocument (list :uri uri)
                     :position (list :line 0 :character 0))
               :timeout 3))
             (items (plist-get completion :items)))
        (should
         (seq-every-p (lambda (item) (plist-member item :textEdit)) items))
        (should
         (equal
          (mapcar (lambda (item)
                    (plist-get (plist-get item :textEdit) :newText))
                  (append items nil))
          '("default-a" "default-b" "replacement")))
        (should-not
         (seq-some (lambda (item) (plist-member item :textEditText))
                   items))))))

(ert-deftest eglotx-edge-result-shapes-and-wire-hygiene ()
  (eglotx-test--with-server
      (server
       (list (eglotx-test--spec "alpha" :priority 100)
             (eglotx-test--spec "beta-full" :priority 10)))
    (eglotx-test--initialize server)
    (let* ((alpha (eglotx-test--backend server "alpha"))
           (beta (eglotx-test--backend server "beta-full"))
           (uri "file:///eglotx-test/result-shapes.el")
           (command-request
            (eglotx--request-create
             :method :textDocument/codeAction
             :params (list :textDocument (list :uri uri))
             :policy (eglotx--policy :textDocument/codeAction)))
           (raw-command
            (list :title "Run alpha" :command "eglotx.alpha.apply"
                  :arguments [(1 2 3)]))
           (merged-command
            (aref
             (eglotx--merge-responses
              server command-request (list (cons alpha (vector raw-command))))
             0))
           (command-token (plist-get merged-command :command)))
      (should-not (plist-member merged-command :data))
      (should (string-prefix-p "eglotx:" command-token))
      (let ((restored
             (eglotx--transform-client-params
              server alpha :workspace/executeCommand
              (list :command command-token
                    :arguments (plist-get merged-command :arguments)))))
        (should (equal (plist-get restored :command) "eglotx.alpha.apply"))
        (should-not (plist-member restored :data)))
      (setf (eglotx--backend-capabilities alpha)
            (plist-put (copy-sequence (eglotx--backend-capabilities alpha))
                       :documentSymbolProvider t)
            (eglotx--backend-capabilities beta)
            (plist-put (copy-sequence (eglotx--backend-capabilities beta))
                       :documentSymbolProvider t))
      (should
       (equal
        (eglotx--select-request-targets
         server :textDocument/documentSymbol
         (list :textDocument (list :uri uri))
         (eglotx--policy :textDocument/documentSymbol))
        (list alpha)))
      (let* ((range-a (list :start (list :line 1 :character 2)
                            :end (list :line 1 :character 3)))
             (range-b (list :start (list :line 4 :character 5)
                            :end (list :line 4 :character 6)))
             (locations
              (eglotx--merge-locations
               (list
                (cons alpha
                      (vector
                       (list :targetUri "file:///eglotx-test/a.el"
                             :targetRange range-a
                             :targetSelectionRange range-a)))
                (cons beta
                      (vector
                       (list :uri "file:///eglotx-test/b.el"
                             :range range-b)))))))
        (should (= (length locations) 2))
        (seq-doseq (location locations)
          (should (plist-member location :uri))
          (should (plist-member location :range))
          (should-not (plist-member location :targetUri))))
      (let* ((edit-range (list :start (list :line 0 :character 0)
                               :end (list :line 0 :character 3)))
             (completion
              (eglotx--completion-with-edit-range
               (list :label "item" :textEditText "replacement")
               edit-range)))
        (should-not (plist-member completion :textEditText))
        (should (equal (plist-get (plist-get completion :textEdit) :newText)
                       "replacement")))
      (let ((safe (eglotx--hover-markdown
                   (list :language "elisp" :value "value ``` here")))
            (unsafe (eglotx--hover-markdown
                     (list :language "elisp\n```bad"
                           :value "value ``` here"))))
        (should (string-prefix-p "````elisp\n" safe))
        (should (string-suffix-p "\n````" safe))
        (should (string-prefix-p "````\n" unsafe))
        (should-not (string-match-p "```bad" unsafe))))))

(ert-deftest eglotx-edge-diagnostic-caps-cover-document-and-related-reports ()
  (let ((eglotx-max-diagnostics 1))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((alpha (eglotx-test--backend server "alpha"))
             (uri "file:///eglotx-test/main-diagnostic.el")
             (related-uri "file:///eglotx-test/related-diagnostic.el")
             (related-key (intern (concat ":" related-uri)))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
             (diagnostics
              (vector (list :range range :message "first")
                      (list :range range :message "second")))
             (request
              (eglotx--request-create
               :method :textDocument/diagnostic
               :params (list :textDocument (list :uri uri))
               :policy (eglotx--policy :textDocument/diagnostic)))
             (pulled
              (eglotx--merge-diagnostic-results
               server request
               (list
                (cons alpha
                      (list :kind "full" :items diagnostics
                            :relatedDocuments
                            (list related-key
                                  (list :kind "full"
                                        :items diagnostics)))))))
             (related-report
              (plist-get (plist-get pulled :relatedDocuments) related-key)))
        (should (= (length (plist-get pulled :items)) 1))
        (should (= (length (plist-get related-report :items)) 1))))))

(ert-deftest eglotx-edge-orphan-owner-exact-unlink-and-migration ()
  (let ((eglotx-orphan-owner-limit 2))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "alpha"))
             (live-uri "file:///eglotx-test/orphan-live.el")
             (diagnostic-uri "file:///eglotx-test/orphan-diagnostic.el")
             (live-token
              (plist-get
               (eglotx--tag-owned-object
                server backend (list :label "live") 'completion live-uri nil)
               :data))
             (diagnostics
              (eglotx--tag-diagnostics
               server backend
               [( :range (:start (:line 0 :character 0)
                          :end (:line 0 :character 1))
                  :message "temporary")]
               diagnostic-uri)))
        (eglotx--remember-diagnostic-tokens
         server backend diagnostic-uri diagnostics 'pull)
        (eglotx--forget-diagnostic-tokens
         server backend diagnostic-uri nil 'pull)
        (should (= (eglotx--owner-cache-count
                    (eglotx--orphan-owner-ring server))
                   1))
        (let ((new-token
               (plist-get
                (eglotx--tag-owned-object
                 server backend (list :label "new") 'completion
                 "file:///eglotx-test/orphan-new.el" nil)
                :data)))
          (should (gethash live-token (eglotx--owners server)))
          (should (gethash new-token (eglotx--owners server)))
          (jsonrpc-notify
           server :textDocument/didOpen
           (list :textDocument
                 (list :uri live-uri :languageId "elisp"
                       :version 0 :text "open")))
          (eglotx--tag-owned-object
           server backend (list :label "resolved") 'completion
           live-uri nil live-token)
          (eglotx--tag-owned-object
           server backend (list :label "third") 'completion
           "file:///eglotx-test/orphan-third.el" nil)
          (eglotx--tag-owned-object
           server backend (list :label "fourth") 'completion
           "file:///eglotx-test/orphan-fourth.el" nil)
          (should (gethash live-token (eglotx--owners server)))
          (should
           (gethash
            live-token
            (eglotx--owner-cache-nodes
             (eglotx--document-owner-ring
              (gethash live-uri (eglotx--documents server))))))
          (should-not
           (gethash live-token
                    (eglotx--owner-cache-nodes
                     (eglotx--orphan-owner-ring server)))))))))

(ert-deftest eglotx-edge-progress-rollback-full-text-and-cleanup-escalation ()
  (let ((server nil))
    (unwind-protect
        (progn
          (setq server
                (eglotx-test--make-server
                 (list (eglotx-test--spec "alpha" :priority 100)
                       (eglotx-test--spec "beta-full" :priority 10))
                 nil nil
                 (lambda (&rest _arguments) (signal 'quit nil))))
          (eglotx-test--initialize server)
          (let ((backend (eglotx-test--backend server "alpha")))
            (let (caught-quit)
              (condition-case nil
                  (eglotx--handle-backend-request
                   server backend 'window/workDoneProgress/create
                   (list :token "quit-create"))
                (quit (setq caught-quit t)))
              (should caught-quit))
            (should (= (hash-table-count
                        (eglotx--backend-progress-forward backend))
                       0))
            (should (= (hash-table-count
                        (eglotx--backend-progress-reverse backend))
                       0)))
          (let* ((path "/eglotx-test/narrowed.el")
                 (uri "file:///eglotx-test/narrowed.el")
                 (buffer (generate-new-buffer " *eglotx narrowed test*")))
            (unwind-protect
                (with-current-buffer buffer
                  (setq buffer-file-name path)
                  (insert "AAA\nBBBX\nCCC\n")
                  (narrow-to-region 5 9)
                  (cl-letf (((symbol-function 'eglotx--uri-to-path)
                             (lambda (_server _uri) path)))
                    (eglotx--did-open
                     server :textDocument/didOpen
                     (list :textDocument
                           (list :uri uri :languageId "elisp" :version 0
                                 :text "AAA\nBBBX\nCCC\n")))
                    (should-not
                     (eglotx--document-text
                      (gethash uri (eglotx--documents server))))
                    (should
                     (equal (eglotx--visiting-buffer-text server uri)
                            "AAA\nBBBX\nCCC\n"))))
              (kill-buffer buffer)))
          (let ((transport-buffers
                 (mapcar
                  (lambda (process) (process-buffer process))
                  (eglotx-test--child-processes server))))
            (jsonrpc-shutdown server nil)
            (should (eq (eglotx--state server) 'dead))
            (jsonrpc-shutdown server t)
            (dolist (buffer transport-buffers)
              (should-not (buffer-live-p buffer)))))
      (eglotx-test--stop-server server))))

(ert-deftest eglotx-edge-diagnostic-batches-are-bounded-and-fault-isolated ()
  (let ((eglotx-diagnostic-chunk-size 2)
        notifications warnings continuations)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10))
         (lambda (_connection method params)
           (if (equal (plist-get params :uri)
                      "file:///eglotx-test/batch-1.el")
               (error "injected client diagnostic failure")
             (push (cons method (copy-tree params)) notifications))))
      (eglotx-test--initialize server)
      (let* ((backend
              (eglotx-test--backend server "no-diagnostic-alpha"))
             (table (make-hash-table :test #'equal))
             (batch (eglotx--diagnostic-batch-create :table table))
             (malformed-uri "file:///eglotx-test/batch-2.el")
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
             (_old
              (eglotx--publish-diagnostics
               server backend
               (list :uri malformed-uri
                     :diagnostics
                     (vector (list :range range :message "old-valid")))
               t))
             (snapshot-key
              (eglotx--diagnostic-token-key backend malformed-uri))
             (old-token
              (plist-get
               (aref (gethash snapshot-key
                              (eglotx--diagnostic-snapshots server))
                     0)
               :data)))
        ;; Missing/null required fields and invalid scalar types are protocol
        ;; errors, not an empty publication.  None may clear the last valid
        ;; snapshot or release its owner before the whole payload validates.
        (dolist (invalid
                 (list (list :uri malformed-uri)
                       (list :uri malformed-uri :diagnostics nil)
                       (list :diagnostics [])
                       (list :uri 7 :diagnostics [])
                       (list :uri malformed-uri :version "zero"
                             :diagnostics [])))
          (should-error
           (eglotx--publish-diagnostics server backend invalid t)
           :type 'eglotx-error)
          (should (gethash old-token (eglotx--owners server)))
          (should
           (equal
            (plist-get
             (aref (gethash snapshot-key
                            (eglotx--diagnostic-snapshots server))
                   0)
             :data)
            old-token)))
        (should (= (hash-table-count (eglotx--owners server)) 1))
        (dotimes (index 5)
          (let* ((uri (format "file:///eglotx-test/batch-%d.el" index))
                 (key (cons (eglotx--backend-id backend) uri))
                 (diagnostics
                  (if (= index 2)
                      ;; Validation must finish before the old snapshot is
                      ;; mutated or the valid prefix receives owner tokens.
                      (vector
                       (list :range (list :start nil :end nil)
                             :message "invalid-range"))
                    (vector (list :range
                                  range
                                  :message (format "valid-%d" index))))))
            (push key (eglotx--diagnostic-batch-order batch))
            (puthash key
                     (eglotx--diagnostic-publication-create
                      :backend backend
                      :params (list :uri uri :diagnostics diagnostics))
                     table)))
        (setf (eglotx--pending-diagnostics server) batch)
        (cl-letf (((symbol-function 'eglotx--enqueue-urgent-work)
                   (lambda (_server function &rest arguments)
                     (setq continuations
                           (nconc continuations
                                  (list (cons function arguments))))))
                  ((symbol-function 'display-warning)
                   (lambda (&rest warning) (push warning warnings))))
          (eglotx--flush-pending-diagnostics server batch)
          (should (= (hash-table-count table) 3))
          (should (= (length continuations) 1))
          (while continuations
            (let ((job (pop continuations)))
              (apply (car job) (cdr job)))))
        (should (eq (eglotx--diagnostic-batch-phase batch) 'done))
        (should (= (length warnings) 2))
        (should (gethash old-token (eglotx--owners server)))
        (should
         (equal
          (plist-get
           (aref (gethash snapshot-key
                          (eglotx--diagnostic-snapshots server))
                 0)
           :data)
          old-token))
        (should (= (hash-table-count (eglotx--owners server)) 5))
        (should
         (= (length
             (eglotx-test--notification-params
             notifications 'textDocument/publishDiagnostics))
            3))))))

(ert-deftest eglotx-edge-diagnostic-queue-preserves-valid-before-malformed ()
  (let (notifications warnings)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (push (cons method (copy-tree params)) notifications)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend
                       server "no-diagnostic-alpha"))
             (uri "file:///eglotx-test/valid-then-malformed.el")
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1)))
             (key (eglotx--diagnostic-token-key backend uri)))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest warning) (push warning warnings))))
          (eglotx--queue-diagnostics
           server backend
           (list :uri uri :version 10
                 :diagnostics
                 (vector (list :range range :message "valid-first"))))
          ;; Both entries share one source and URI.  Deferred coalescing must
          ;; not let this malformed successor erase the valid publication.
          (eglotx--queue-diagnostics
           server backend (list :uri uri :version 10 :diagnostics nil))
          (eglotx--queue-diagnostics server backend 7)
          (should
           (eglotx-test--wait-until
            (lambda ()
              (and (null (eglotx--pending-diagnostics server))
                   (null (eglotx--work-head server))
                   (null (eglotx--work-timer server)))))))
        (should (>= (length warnings) 2))
        (let ((snapshot (gethash key (eglotx--diagnostic-snapshots server))))
          (should (= (length snapshot) 1))
          (should (equal (plist-get (aref snapshot 0) :message)
                         "valid-first")))
        (let ((published
               (eglotx-test--notification-params
                notifications 'textDocument/publishDiagnostics)))
          (should (= (length published) 1))
          (should (= (length (plist-get (car published) :diagnostics)) 1)))))))

(ert-deftest eglotx-edge-diagnostic-collect-reschedules-after-nonlocal-exit ()
  (let ((eglotx-diagnostic-chunk-size 2)
        (throw-once t)
        notifications continuations)
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "no-diagnostic-alpha" :priority 100)
               (eglotx-test--spec "no-diagnostic-beta" :priority 10))
         (lambda (_connection method params)
           (if (and throw-once (eq method '$/streamDiagnostics))
               (progn
                 (setq throw-once nil)
                 (throw 'eglotx-test-diagnostic-exit 'interrupted))
             (push (cons method (copy-tree params)) notifications))))
      (eglotx-test--initialize server t)
      (should (eglotx--stream-diagnostics-p server))
      (let* ((backend (eglotx-test--backend server "no-diagnostic-alpha"))
             (table (make-hash-table :test #'equal))
             (batch (eglotx--diagnostic-batch-create :table table))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1))))
        (dotimes (index 3)
          (let* ((uri (format "file:///eglotx-test/throw-%d.el" index))
                 (key (cons (eglotx--backend-id backend) uri))
                 (document
                  (eglotx--document-create
                   :uri uri :version 0 :generation 0 :language-id "elisp"
                   :owner-ring
                   (eglotx--owner-cache-create
                    :limit eglotx-document-owner-limit
                    :nodes (make-hash-table :test #'equal)))))
            ;; This edge case exercises a non-local exit from the streaming
            ;; projection, which is only valid for managed/open documents.
            (puthash uri document (eglotx--documents server))
            (puthash uri document (eglotx--document-identities server))
            (push key (eglotx--diagnostic-batch-order batch))
            (puthash
             key
             (eglotx--diagnostic-publication-create
              :backend backend
              :params
              (list :uri uri
                    :diagnostics
                    (vector (list :range range :message "valid")))
              :document document :generation 0)
             table)))
        (setf (eglotx--pending-diagnostics server) batch)
        (cl-letf (((symbol-function 'eglotx--enqueue-urgent-work)
                   (lambda (_server function &rest arguments)
                     (setq continuations
                           (nconc continuations
                                  (list (cons function arguments)))))))
          (should
           (eq (catch 'eglotx-test-diagnostic-exit
                 (eglotx--flush-pending-diagnostics server batch)
                 'fell-through)
               'interrupted))
          (should (= (length continuations) 1))
          (should (= (length (eglotx--diagnostic-batch-order batch)) 2))
          (while continuations
            (let ((job (pop continuations)))
              (apply (car job) (cdr job)))))
        (should (eq (eglotx--diagnostic-batch-phase batch) 'done))
        (should
         (= (length
             (eglotx-test--notification-params
              notifications '$/streamDiagnostics))
            2))))))

(ert-deftest eglotx-edge-constructor-failure-releases-facade-buffers ()
  (let* ((name (eglotx-test--unique-name))
         (matching-buffers
          (lambda ()
            (seq-filter
             (lambda (buffer)
               (string-match-p (regexp-quote name) (buffer-name buffer)))
             (buffer-list))))
         (matching-processes
          (lambda ()
            (seq-filter
             (lambda (process)
               (string-match-p (regexp-quote name) (process-name process)))
             (process-list)))))
    (should-not (funcall matching-buffers))
    (should-error
     (eglotx-test--make-server
      (list (list :name "invalid-factory"
                  :process (lambda () nil))
            (eglotx-test--spec "alpha" :priority 10))
      nil name))
    (should-not (funcall matching-buffers))
    (should-not (funcall matching-processes))
    (let ((caught-quit nil))
      (condition-case nil
          (eglotx-test--make-server
           (list (eglotx-test--spec "alpha" :priority 100)
                 (list :name "quit-factory" :priority 10
                       :process (lambda () (signal 'quit nil))))
           nil name)
        (quit (setq caught-quit t)))
      (should caught-quit))
    (should-not (funcall matching-buffers))
    (should-not (funcall matching-processes))
    (let ((original-anchor
           (symbol-function 'eglotx--make-anchor-process))
          (original-rename (symbol-function 'rename-buffer))
          captured injected caught-quit)
      (cl-letf (((symbol-function 'eglotx--make-anchor-process)
                 (lambda ()
                   (setq captured (funcall original-anchor))))
                ((symbol-function 'rename-buffer)
                 (lambda (&rest arguments)
                   (prog1 (apply original-rename arguments)
                     (when (and captured (not injected))
                       (setq injected t)
                       (signal 'quit nil))))))
        (condition-case nil
            (eglotx-test--make-server
             (list (eglotx-test--spec "alpha" :priority 100)
                   (eglotx-test--spec "beta-full" :priority 10))
             nil name)
          (quit (setq caught-quit t))))
      (should caught-quit)
      (should (processp captured))
      (should-not (process-live-p captured)))
    (should-not (funcall matching-buffers))
    (let ((original-filter (symbol-function 'set-process-filter))
          child injected caught-quit)
      (cl-letf (((symbol-function 'set-process-filter)
                 (lambda (process filter)
                   (prog1 (funcall original-filter process filter)
                     (when (and (eq process child) (not injected))
                       (setq injected t)
                       (signal 'quit nil))))))
        (condition-case nil
            (eglotx-test--make-server
             (list
              (list :name "handoff" :priority 100
                    :process
                    (lambda ()
                      (setq child
                            (make-pipe-process
                             :name "eglotx-test-raw-child" :buffer nil
                             :noquery t :coding 'binary))))
              (eglotx-test--spec "alpha" :priority 10))
             nil name)
          (quit (setq caught-quit t))))
      (should caught-quit)
      (should (processp child))
      (should-not (process-live-p child)))
    (should-not (funcall matching-buffers))
    (should-not (funcall matching-processes))
    ;; Exact cleanup ownership matters when one backend name prefixes another.
    ;; Failure of optional `alpha' must not delete `alpha-long's buffers and
    ;; thereby terminate the healthy required process.
    (let (server warnings)
      (unwind-protect
          (progn
            (cl-letf (((symbol-function 'display-warning)
                       (lambda (&rest warning) (push warning warnings))))
              (setq server
                    (eglotx-test--make-server
                     (list
                      (eglotx-test--spec "alpha-long" :priority 100)
                      (list :name "alpha" :priority 10 :required nil
                            :process (lambda () nil)))
                     nil name)))
            (let ((healthy (eglotx-test--backend server "alpha-long"))
                  (failed (eglotx-test--backend server "alpha")))
              (should (eq (eglotx--backend-state healthy) 'running))
              (should (process-live-p
                       (jsonrpc--process
                        (eglotx--backend-connection healthy))))
              (should (eq (eglotx--backend-state failed) 'failed))
              (should-not (eglotx--backend-connection failed)))
            (eglotx-test--initialize server)
            (should
             (equal (plist-get
                     (eglotx-test--backend-state server "alpha-long") :name)
                    "alpha-long"))
            (should (= (length warnings) 1)))
        (eglotx-test--stop-server server)))
    (should-not (funcall matching-buffers))
    (should-not (funcall matching-processes))))

(ert-deftest eglotx-edge-orphan-owner-removal-never-scans-cache ()
  (let ((eglotx-orphan-owner-limit 16))
    (eglotx-test--with-server
        (server
         (list (eglotx-test--spec "alpha" :priority 100)
               (eglotx-test--spec "beta-full" :priority 10)))
      (eglotx-test--initialize server)
      (let* ((backend (eglotx-test--backend server "alpha"))
             (range (list :start (list :line 0 :character 0)
                          :end (list :line 0 :character 1))))
        (dotimes (index 15)
          (eglotx--tag-owned-object
           server backend (list :label (format "live-%d" index))
           'completion (format "file:///eglotx-test/live-%d.el" index) nil))
        (cl-labels
            ((add-and-forget-diagnostic
              (suffix)
              (let* ((uri (format "file:///eglotx-test/dead-%s.el" suffix))
                     (items
                      (eglotx--tag-diagnostics
                       server backend
                       (vector (list :range range :message "temporary"))
                       uri)))
                (eglotx--remember-diagnostic-tokens
                 server backend uri items 'pull)
                (eglotx--forget-diagnostic-tokens
                 server backend uri nil 'pull))))
          (add-and-forget-diagnostic "one")
          ;; Exact membership unlinks the dead slot immediately.  New inserts
          ;; neither scan nor inherit a tombstone-degraded effective capacity.
          (eglotx--tag-owned-object
           server backend (list :label "after-one") 'completion
           "file:///eglotx-test/after-one.el" nil)
          (should (= (eglotx--owner-cache-count
                      (eglotx--orphan-owner-ring server))
                     16))
          (add-and-forget-diagnostic "two")
          (should (= (eglotx--owner-cache-count
                      (eglotx--orphan-owner-ring server))
                     15))
          (eglotx--tag-owned-object
           server backend (list :label "after-two") 'completion
           "file:///eglotx-test/after-two.el" nil)
          (should (= (eglotx--owner-cache-count
                      (eglotx--orphan-owner-ring server))
                     16)))))))

(provide 'eglotx-test)

;;; eglotx-test.el ends here
