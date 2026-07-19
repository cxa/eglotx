;;; eglotx-fake-server.el --- Deterministic LSP test server  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A small, deterministic LSP server used by Eglotx integration tests.  Start
;; it as follows, where NAME identifies the simulated backend:
;;
;;   emacs -Q --batch -l test/eglotx-fake-server.el -- NAME
;;
;; GNU Emacs does not expose its own standard input as an asynchronous process.
;; In batch mode we therefore use a short-lived POSIX `tee' relay to copy stdin
;; into a private temporary file.  All framing, UTF-8 decoding, JSON handling,
;; request dispatch, timers, and responses remain in this Emacs process.
;; stdout is reserved for LSP frames; diagnostic logging goes to stderr.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defconst eglotx-test--maximum-header-bytes (* 16 1024))
(defconst eglotx-test--maximum-content-bytes (* 16 1024 1024))
(defconst eglotx-test--read-chunk-bytes (* 64 1024))

(defvar eglotx-test--name "default")
(defvar eglotx-test--running t)
(defvar eglotx-test--shutdown nil)
(defvar eglotx-test--exit-code 0)
(defvar eglotx-test--input (encode-coding-string "" 'binary t))
(defvar eglotx-test--methods nil)
(defvar eglotx-test--last-params nil)
(defvar eglotx-test--last-params-by-method nil)
(defvar eglotx-test--last-did-open nil)
(defvar eglotx-test--last-did-change nil)
(defvar eglotx-test--cancelled-ids nil)
(defvar eglotx-test--pending nil)
(defvar eglotx-test--documents nil)
(defvar eglotx-test--outgoing-requests nil)
(defvar eglotx-test--outgoing-batches nil)
(defvar eglotx-test--next-outgoing-id 0)
(defvar eglotx-test--current-raw-message nil)
(defvar eglotx-test--vue-bridge-requests nil)
(defvar eglotx-test--vue-bridge-responses nil)

(defvar eglotx-test--relay-directory nil)
(defvar eglotx-test--relay-input-file nil)
(defvar eglotx-test--relay-pid-file nil)
(defvar eglotx-test--relay-pid nil)
(defvar eglotx-test--relay-start nil)
(defvar eglotx-test--relay-offset 0)

(defun eglotx-test--log (format-string &rest arguments)
  "Write a server log message described by FORMAT-STRING and ARGUMENTS.
Logging never writes to the protocol stream."
  (let ((standard-output 'external-debugging-output)
        (coding-system-for-write 'utf-8-unix))
    (princ (format "[eglotx-fake:%s] %s\n"
                   eglotx-test--name
                   (apply #'format format-string arguments)))
    (flush-standard-output)))

(defun eglotx-test--command-line-name ()
  "Return the backend name following the command-line `--' marker."
  (let ((arguments command-line-args-left))
    (when (equal (car arguments) "--")
      (setq arguments (cdr arguments)))
    (if (and (car arguments) (not (string-empty-p (car arguments))))
        (car arguments)
      "default")))

(defun eglotx-test--send (message)
  "Serialize and send JSON-RPC MESSAGE as one LSP frame."
  (let* ((json (json-serialize message
                               :null-object nil
                               :false-object :json-false))
         (payload (encode-coding-string json 'utf-8-unix t))
         (header (format "Content-Length: %d\r\n\r\n" (length payload)))
         (wire-text (decode-coding-string payload 'utf-8-unix))
         (coding-system-for-write 'utf-8-unix))
    ;; `princ' treats bytes in a unibyte string as raw Emacs characters and
    ;; would re-encode them (for example e4 as c1-a4).  Decode the already
    ;; measured UTF-8 payload before writing so stdout receives exactly the
    ;; bytes counted in Content-Length.
    (princ header)
    (princ wire-text)
    (flush-standard-output)))

(defun eglotx-test--send-result (id result)
  "Send RESULT for JSON-RPC request ID."
  (eglotx-test--send (list :jsonrpc "2.0" :id id :result result)))

(defun eglotx-test--send-error (id code message)
  "Send a JSON-RPC error for ID with CODE and MESSAGE."
  (eglotx-test--send
   (list :jsonrpc "2.0"
         :id id
         :error (list :code code :message message))))

(defun eglotx-test--send-notification (method params)
  "Send notification METHOD with PARAMS."
  (eglotx-test--send
   (list :jsonrpc "2.0" :method method :params params)))

(defun eglotx-test--request-workspace-configuration (outer-id params)
  "Ask the client for configuration on behalf of request OUTER-ID.
PARAMS become the `workspace/configuration' request parameters.  The exact
JSON response observed on the fake server's wire completes OUTER-ID."
  (let ((id (format "eglotx-test-outgoing-%d"
                    (cl-incf eglotx-test--next-outgoing-id))))
    (puthash id outer-id eglotx-test--outgoing-requests)
    (eglotx-test--send
     (list :jsonrpc "2.0" :id id
           :method "workspace/configuration" :params params))))

(defun eglotx-test--request-client-batch (outer-id params)
  "Issue client requests described by PARAMS for fake request OUTER-ID."
  (let ((method (plist-get params :method))
        (client-params (plist-get params :params))
        (count (or (plist-get params :count) 1))
        (request-id (plist-get params :requestId))
        (cancel-p (eq (plist-get params :cancel) t)))
    (unless (and (stringp method) (integerp count) (> count 0)
                 (or (null request-id)
                     (stringp request-id)
                     (integerp request-id))
                 (or (null request-id) (= count 1)))
      (error "eglotx.test/requestClient requires a method and positive count"))
    (puthash outer-id (list :remaining count :responses nil :error nil)
             eglotx-test--outgoing-batches)
    (dotimes (_ count)
      (let ((id (or request-id
                    (format "eglotx-test-outgoing-%d"
                            (cl-incf eglotx-test--next-outgoing-id)))))
        (puthash id outer-id eglotx-test--outgoing-requests)
        (eglotx-test--send
         (list :jsonrpc "2.0" :id id :method method
               :params client-params))
        (when cancel-p
          (eglotx-test--send-notification
           "$/cancelRequest" (list :id id)))))))

(defun eglotx-test--notify-client-batch (outer-id params)
  "Issue client notifications described by PARAMS, then complete OUTER-ID."
  (let ((method (plist-get params :method))
        (client-params (plist-get params :params))
        (count (or (plist-get params :count) 1)))
    (unless (and (stringp method) (integerp count) (> count 0))
      (error "eglotx.test/notifyClient requires a method and positive count"))
    (dotimes (_ count)
      (eglotx-test--send-notification method client-params))
    (eglotx-test--send-result outer-id nil)))

(defun eglotx-test--handle-response (message)
  "Complete a fake-server request from JSON-RPC response MESSAGE."
  (let* ((id (plist-get message :id))
         (missing (make-symbol "missing"))
         (outer-id (gethash id eglotx-test--outgoing-requests missing)))
    (if (eq outer-id missing)
        (eglotx-test--log "ignored response for unknown id %S" id)
      (remhash id eglotx-test--outgoing-requests)
      (if-let* ((batch (gethash outer-id eglotx-test--outgoing-batches)))
          (let* ((error-object (plist-get message :error))
                 (remaining (1- (plist-get batch :remaining)))
                 (responses
                  (cons eglotx-test--current-raw-message
                        (plist-get batch :responses))))
            (setq batch (plist-put batch :remaining remaining)
                  batch (plist-put batch :responses responses))
            (when (and error-object (not (plist-get batch :error)))
              (setq batch (plist-put batch :error error-object)))
            (if (> remaining 0)
                (puthash outer-id batch eglotx-test--outgoing-batches)
              (remhash outer-id eglotx-test--outgoing-batches)
              (if-let* ((first-error (plist-get batch :error)))
                  (eglotx-test--send-error
                   outer-id
                   (or (plist-get first-error :code) -32603)
                   (or (plist-get first-error :message)
                       "Client request failed"))
                (eglotx-test--send-result
                 outer-id (vconcat (nreverse responses))))))
        (if-let* ((error-object (plist-get message :error)))
            (eglotx-test--send-error
             outer-id
             (or (plist-get error-object :code) -32603)
             (or (plist-get error-object :message) "Client request failed"))
          ;; Returning the raw message lets integration tests distinguish `{}`
          ;; from `null', which both decode to nil with plist JSON objects.
          (eglotx-test--send-result
           outer-id eglotx-test--current-raw-message))))))

(defun eglotx-test--sync-kind ()
  "Return the deterministic text synchronization kind for this backend."
  (cond
   ((string= eglotx-test--name "alpha") 2)
   ((string= eglotx-test--name "beta-full") 1)
   ((string-match-p "none-sync" eglotx-test--name) 0)
   ((string-match-p "full" eglotx-test--name) 1)
   (t 2)))

(defun eglotx-test--only-profile ()
  "Return a capability name when NAME requests an `*-only' profile."
  (and (string-match
        "\\`\\(completion\\|hover\\|definition\\|code-action\\|diagnostic\\)-only\\'"
        eglotx-test--name)
       (match-string 1 eglotx-test--name)))

(defun eglotx-test--capability-enabled-p (capability)
  "Return non-nil when CAPABILITY is enabled by this backend's NAME."
  (let ((only (eglotx-test--only-profile)))
    (and (not (string-match-p
               (concat "no-" (regexp-quote capability))
               eglotx-test--name))
         (or (null only) (string= only capability)))))

(defun eglotx-test--inline-completion-profile-p ()
  "Return non-nil when NAME requests an inline-completion result shape."
  (or (string-match-p "inline-array" eglotx-test--name)
      (string-match-p "inline-list" eglotx-test--name)))

(defun eglotx-test--code-action-documentation-p ()
  "Return non-nil when NAME advertises CodeActionKindDocumentation."
  (string-match-p "code-action-doc" eglotx-test--name))

(defun eglotx-test--capabilities ()
  "Build this backend's deterministic LSP capabilities plist."
  (let ((capabilities
         (list :positionEncoding
               (if (string-match-p "bad-encoding" eglotx-test--name)
                   "utf-8"
                 "utf-16")
               :textDocumentSync (eglotx-test--sync-kind))))
    (when (eglotx-test--capability-enabled-p "completion")
      (setq capabilities
            (append capabilities
                    (list :completionProvider
                          (list :resolveProvider
                                (if (string-match-p
                                     "no-resolve" eglotx-test--name)
                                    :json-false
                                  t)
                                :triggerCharacters ["." ":"])))))
    (when (eglotx-test--capability-enabled-p "hover")
      (setq capabilities (append capabilities (list :hoverProvider t))))
    (when (eglotx-test--capability-enabled-p "definition")
      (setq capabilities (append capabilities (list :definitionProvider t))))
    (when (string-match-p "static-type" eglotx-test--name)
      (setq capabilities
            (append
             capabilities
             (list :typeDefinitionProvider
                   (list :id "shared-static-id"
                         :documentSelector [(:language "elisp")]
                         :workDoneProgress t)))))
    (when (string-match-p "malformed-static-selector" eglotx-test--name)
      (setq capabilities
            (append capabilities
                    '(:typeDefinitionProvider
                      (:documentSelector [(:language 42)])))))
    (when (string-match-p "static-workspace-folders" eglotx-test--name)
      (setq capabilities
            (append
             capabilities
             (list
              :workspace
              (list :workspaceFolders
                    (list :supported t
                          :changeNotifications
                          "shared-workspace-folders-id"))))))
    (when (eglotx-test--capability-enabled-p "code-action")
      (let ((provider
             (list :resolveProvider :json-false
                   :codeActionKinds ["quickfix"])))
        (when (eglotx-test--code-action-documentation-p)
          (setq provider
                (plist-put
                 provider :documentation
                 (vector
                  (list
                   :kind "quickfix"
                   :command
                   (list
                    :title (format "Explain %s fixes" eglotx-test--name)
                    :command (format "eglotx.%s.document"
                                     eglotx-test--name)
                    :arguments
                    (vector (list :server eglotx-test--name))))))))
        (setq capabilities
              (append capabilities (list :codeActionProvider provider)))))
    (when (eglotx-test--inline-completion-profile-p)
      (setq capabilities
            (append capabilities (list :inlineCompletionProvider t))))
    (when (eglotx-test--capability-enabled-p "diagnostic")
      (setq capabilities
            (append capabilities
                    (list :diagnosticProvider
                          (list :identifier eglotx-test--name
                                :interFileDependencies :json-false
                                :workspaceDiagnostics :json-false)))))
    ;; Execute-command is kept with code actions so command routing can be
    ;; tested from the action returned by this same backend.
    (when (eglotx-test--capability-enabled-p "code-action")
      (let ((commands (list (format "eglotx.%s.apply"
                                    eglotx-test--name))))
        (when (eglotx-test--inline-completion-profile-p)
          (setq commands
                (nconc commands
                       (list (format "eglotx.%s.inline"
                                     eglotx-test--name)))))
        (when (eglotx-test--code-action-documentation-p)
          (setq commands
                (nconc commands
                       (list (format "eglotx.%s.document"
                                     eglotx-test--name)))))
        (setq capabilities
              (append capabilities
                      (list :executeCommandProvider
                            (list :commands (vconcat commands)))))))
    capabilities))

(defun eglotx-test--initialize-result ()
  "Return this backend's initialize result."
  (list :capabilities (eglotx-test--capabilities)
        :serverInfo (list :name eglotx-test--name :version "1.0.0")))

(defun eglotx-test--completion-result (params)
  "Return a deterministic completion list for this backend and PARAMS."
  (cond
   ((string-match-p "tailwind-volume" eglotx-test--name)
      (list
       :isIncomplete :json-false
       :itemDefaults
       (list :data (list :server eglotx-test--name
                         :profile "tailwind-volume")
             :editRange
             (list :start (list :line 0 :character 16)
                   :end (list :line 0 :character 16)))
       :items
       (vconcat
        (cl-loop for index below 10000
                 collect
                 (list :label (format "tw-%05d" index)
                       :kind 12
                       :insertText (format "tw-%05d" index)
                       :sortText (format "%05d" index))))))
   ((string-match-p "completion-batch-profile" eglotx-test--name)
      (let ((character
             (or (plist-get (plist-get params :position) :character) 0)))
        (if (= character 1)
            (list
             :isIncomplete :json-false
             :items
             [(:label "absent")
              (:label "null" :data nil)
              (:label "false" :data :json-false)
              (:label "object" :data (:shape "object" :value 7))])
          (list
           :isIncomplete :json-false
           :itemDefaults
           (list :data (list :server eglotx-test--name
                             :shape "default")
                 :editRange
                 (if (string-match-p
                      "insert-replace" eglotx-test--name)
                     (list
                      :insert
                      (list :start (list :line 0 :character 0)
                            :end (list :line 0 :character 0))
                      :replace
                      (list :start (list :line 0 :character 0)
                            :end (list :line 0 :character 3)))
                   (list :start (list :line 0 :character 0)
                         :end (list :line 0 :character 3))))
           :items
           [(:label "default-a")
            (:label "default-b" :insertText "inserted-b")
            (:label "override"
             :textEditText "replacement"
             :data (:shape "override" :value 9))]))))
   (t
      (list
       :isIncomplete (if (string-match-p "incomplete" eglotx-test--name)
                         t
                       :json-false)
       :items
       (vector
        (list :label (format "%s-item" eglotx-test--name)
              :kind 3
              :commitCharacters [";"]
              :insertTextFormat 1
              :detail (format "completion from %s" eglotx-test--name)
              :insertText (format "%s_completion" eglotx-test--name)
              :sortText (format "10-%s" eglotx-test--name)
              :data (list :server eglotx-test--name
                          :token (format "%s-completion-data"
                                         eglotx-test--name))))))))

(defun eglotx-test--completion-resolve-result (item)
  "Return a resolved copy of completion ITEM."
  (let ((resolved (if (listp item) (copy-sequence item) nil)))
    (when (string-match-p "rotating-resolve" eglotx-test--name)
      (let* ((data (copy-sequence (or (plist-get item :data) nil)))
             (revision (1+ (or (plist-get data :revision) 0))))
        (setq resolved
              (plist-put resolved :data
                         (plist-put data :revision revision)))))
    (setq resolved
          (plist-put resolved :detail
                     (format "resolved by %s" eglotx-test--name)))
    (setq resolved
          (plist-put resolved :documentation
                     (list :kind "markdown"
                           :value (format "Resolved documentation from **%s**."
                                          eglotx-test--name))))
    (setq resolved (plist-put resolved :resolvedBy eglotx-test--name))
    (when (string-match-p "completion-batch-profile" eglotx-test--name)
      ;; A resolve response may legally omit unchanged data.  The facade must
      ;; retain the data captured from the original completion response.
      (cl-remf resolved :data))
    resolved))

(defun eglotx-test--position (params)
  "Return a copied LSP position from PARAMS, or the origin."
  (let ((position (plist-get params :position)))
    (if (listp position)
        (copy-sequence position)
      (list :line 0 :character 0))))

(defun eglotx-test--hover-result (params)
  "Return deterministic hover information for PARAMS."
  (let ((position (eglotx-test--position params)))
    (list :contents
          (list :kind "markdown"
                :value (format "**hover from %s** — UTF-8: 你好"
                               eglotx-test--name))
          :range (list :start position :end (copy-sequence position)))))

(defun eglotx-test--safe-name ()
  "Return NAME made safe for use in a synthetic file URI."
  (replace-regexp-in-string "[^[:alnum:]_.-]" "_" eglotx-test--name))

(defun eglotx-test--definition-result ()
  "Return one deterministic definition location."
  (let ((line (length eglotx-test--name)))
    (vector
     (list :uri (format "file:///eglotx-test/%s.el"
                        (eglotx-test--safe-name))
           :range (list :start (list :line line :character 0)
                        :end (list :line line :character 1))))))

(defun eglotx-test--code-action-result ()
  "Return one deterministic command-bearing code action."
  (let ((command (format "eglotx.%s.apply" eglotx-test--name)))
    (vector
     (list :title (format "Fix from %s" eglotx-test--name)
           :kind "quickfix"
           :diagnostics []
           :isPreferred t
           :command
           (list :title (format "Apply %s fix" eglotx-test--name)
                 :command command
                 :arguments
                 (vector (list :server eglotx-test--name
                               :token (format "%s-command-data"
                                              eglotx-test--name))))
           :data (list :server eglotx-test--name
                       :token (format "%s-action-data"
                                      eglotx-test--name))))))

(defun eglotx-test--inline-completion-result ()
  "Return a deterministic command-bearing inline completion result."
  (let ((items
         (vector
          (list
           :insertText (format "%s_inline" eglotx-test--name)
           :command
           (list :title (format "Accept %s inline completion"
                                eglotx-test--name)
                 :command (format "eglotx.%s.inline" eglotx-test--name)
                 :arguments (vector (list :server eglotx-test--name)))))))
    (if (string-match-p "inline-list" eglotx-test--name)
        (list :items items)
      items)))

(defun eglotx-test--execute-command-result (params)
  "Return a deterministic acknowledgement for execute-command PARAMS."
  (if (equal (plist-get params :command) "typescript.tsserverRequest")
      (let ((arguments (plist-get params :arguments)))
        (list :body
              (list :servedBy eglotx-test--name
                    :command (and (vectorp arguments) (aref arguments 0))
                    :payload (and (vectorp arguments) (aref arguments 1)))))
    (list :executedBy eglotx-test--name
          :server eglotx-test--name
          :command (plist-get params :command)
          :arguments (or (plist-get params :arguments) []))))

(defun eglotx-test--request-vue-tsserver-bridge (outer-id params)
  "Send a Vue tsserver notification and complete OUTER-ID on its response."
  (let ((id (plist-get params :id))
        (command (plist-get params :command))
        (payload (plist-get params :payload)))
    (puthash id outer-id eglotx-test--vue-bridge-requests)
    (eglotx-test--send-notification
     "tsserver/request" (vector (vector id command payload)))))

(defun eglotx-test--vue-tsserver-response (params)
  "Record Vue bridge response PARAMS and settle its test request."
  (push params eglotx-test--vue-bridge-responses)
  (let* ((outer (and (vectorp params) (= (length params) 1)
                     (aref params 0)))
         (id (and (vectorp outer) (> (length outer) 0) (aref outer 0)))
         (missing (make-symbol "missing"))
         (outer-id (gethash id eglotx-test--vue-bridge-requests missing)))
    (unless (eq outer-id missing)
      (remhash id eglotx-test--vue-bridge-requests)
      (eglotx-test--send-result outer-id params))))

(defun eglotx-test--document-clean-p (document)
  "Return non-nil when DOCUMENT requests an empty diagnostic snapshot."
  (eq (plist-get document :clean) t))

(defun eglotx-test--diagnostics (document version)
  "Return diagnostics for DOCUMENT at VERSION."
  (if (or (string-match-p "clear" eglotx-test--name)
          (eglotx-test--document-clean-p document))
      []
    (vector
     (list :range (list :start (list :line 0 :character 0)
                        :end (list :line 0 :character 1))
           :severity 2
           :code (format "%s-warning" eglotx-test--name)
           :source eglotx-test--name
           :message (format "diagnostic from %s" eglotx-test--name)
           :data (list :server eglotx-test--name :version version)))))

(defun eglotx-test--publish-diagnostics (uri version document)
  "Publish a diagnostic snapshot for URI, VERSION, and DOCUMENT."
  (unless (string-match-p "no-push" eglotx-test--name)
    (let* ((published-version
            (if (and (numberp version)
                     (string-match-p "stale" eglotx-test--name))
                (1- version)
              version))
           (params
            (list :uri uri
                  :diagnostics
                  (eglotx-test--diagnostics document published-version))))
      (unless (string-match-p "versionless" eglotx-test--name)
        (when (numberp published-version)
          (setq params (append params (list :version published-version)))))
      (eglotx-test--send-notification
       "textDocument/publishDiagnostics" params))))

(defun eglotx-test--text-requests-clean-p (changes)
  "Return non-nil when any content CHANGES request clean diagnostics."
  (let ((index 0)
        clean)
    (while (and (vectorp changes)
                (< index (length changes))
                (not clean))
      (let ((text (plist-get (aref changes index) :text)))
        (when (and (stringp text) (string-match-p "clean" text))
          (setq clean t)))
      (setq index (1+ index)))
    clean))

(defun eglotx-test--did-open (params)
  "Record didOpen PARAMS and publish diagnostics."
  (let* ((text-document (plist-get params :textDocument))
         (uri (plist-get text-document :uri))
         (version (plist-get text-document :version))
         (text (plist-get text-document :text))
         (document
          (list :version version
                :text text
                :clean (and (stringp text) (string-match-p "clean" text)))))
    (setq eglotx-test--last-did-open params)
    (when (stringp uri)
      (puthash uri document eglotx-test--documents)
      (eglotx-test--publish-diagnostics uri version document))))

(defun eglotx-test--did-change (params)
  "Record didChange PARAMS and publish diagnostics."
  (let* ((text-document (plist-get params :textDocument))
         (uri (plist-get text-document :uri))
         (version (plist-get text-document :version))
         (changes (plist-get params :contentChanges))
         (document
          (list :version version
                :changes changes
                ;; Each publication is a fresh snapshot.  In particular, a
                ;; clean change clears this backend, but a later non-clean
                ;; change must be able to publish diagnostics again.
                :clean (eglotx-test--text-requests-clean-p changes))))
    (setq eglotx-test--last-did-change params)
    (when (stringp uri)
      (puthash uri document eglotx-test--documents)
      (eglotx-test--publish-diagnostics uri version document))))

(defun eglotx-test--did-close (params)
  "Forget the document named by didClose PARAMS and clear diagnostics."
  (let* ((text-document (plist-get params :textDocument))
         (uri (plist-get text-document :uri)))
    (when (stringp uri)
      (remhash uri eglotx-test--documents)
      (eglotx-test--send-notification
       "textDocument/publishDiagnostics"
       (list :uri uri :diagnostics [])))))

(defun eglotx-test--diagnostic-result (params)
  "Return a full document diagnostic report for PARAMS."
  (let* ((text-document (plist-get params :textDocument))
         (uri (plist-get text-document :uri))
         (document (and (stringp uri)
                        (gethash uri eglotx-test--documents)))
         (version (plist-get document :version))
         (result-id (format "%s-result:%s" eglotx-test--name uri)))
    (unless (equal (plist-get params :identifier) eglotx-test--name)
      (error "Wrong diagnostic identifier for %s" eglotx-test--name))
    (cond
     ((string-match-p "malformed-pull" eglotx-test--name)
      (list :kind "full" :resultId result-id :items nil))
     ((equal (plist-get params :previousResultId) result-id)
      (list :kind "unchanged" :resultId result-id))
     (t
      (let ((report
             (list :kind "full" :resultId result-id
                   :items (eglotx-test--diagnostics document version))))
        (if (not (string-match-p "related" eglotx-test--name))
            report
          (let* ((related-uri
                  "file:///eglotx-test/related-in-flight.el")
                 (related-key (intern (concat ":" related-uri))))
            (plist-put
             report :relatedDocuments
             (list
              related-key
              (list :kind "full"
                    :resultId
                    (format "%s-related-result" eglotx-test--name)
                    :items (eglotx-test--diagnostics nil nil)))))))))))

(defun eglotx-test--state ()
  "Return observable protocol state for integration assertions."
  (list :name eglotx-test--name
        :methods (vconcat (reverse eglotx-test--methods))
        :lastParams eglotx-test--last-params
        :lastParamsByMethod eglotx-test--last-params-by-method
        :lastDidOpen eglotx-test--last-did-open
        :lastDidChange eglotx-test--last-did-change
        :vueBridgeResponses (vconcat (reverse eglotx-test--vue-bridge-responses))
        :cancelledIds (vconcat (reverse eglotx-test--cancelled-ids))
        :shutdown (if eglotx-test--shutdown t :json-false)))

(defun eglotx-test--record-message (method params)
  "Record receipt of METHOD and PARAMS."
  (push method eglotx-test--methods)
  (puthash method params eglotx-test--last-params-by-method)
  ;; A state query should observe, rather than replace, the preceding params.
  (unless (string= method "eglotx.test/state")
    (setq eglotx-test--last-params params)))

(defun eglotx-test--request-delay-ms (method params)
  "Return a requested artificial delay for METHOD and PARAMS."
  (let ((explicit (and (listp params) (plist-get params :delayMs))))
    (cond
     ((and (numberp explicit) (> explicit 0)) explicit)
     ((and (string-match-p "slow" eglotx-test--name)
           (string= method "textDocument/hover"))
      300)
     ((and (string-match-p "slow-completion" eglotx-test--name)
           (string= method "textDocument/completion"))
      300)
     ((and (string-match-p "slow-resolve" eglotx-test--name)
           (string= method "completionItem/resolve"))
      300)
     ((and (string-match-p "slow-diagnostic" eglotx-test--name)
           (string= method "textDocument/diagnostic"))
      300)
     ((and (string-match-p "slow-bridge" eglotx-test--name)
           (string= method "workspace/executeCommand")
           (equal (plist-get params :command)
                  "typescript.tsserverRequest"))
      300)
     (t nil))))

(defun eglotx-test--handle-request-now (id method params)
  "Handle request ID, METHOD, and PARAMS without an artificial delay."
  (cond
   ((string= method "initialize")
    (eglotx-test--send-result id (eglotx-test--initialize-result)))
   ((string= method "shutdown")
    (setq eglotx-test--shutdown t)
    (eglotx-test--send-result id nil))
   ((string= method "textDocument/completion")
    (eglotx-test--send-result id (eglotx-test--completion-result params)))
   ((string= method "completionItem/resolve")
    (eglotx-test--send-result
     id (eglotx-test--completion-resolve-result params)))
   ((string= method "textDocument/hover")
    (when (and (string-match-p "fast-progress" eglotx-test--name)
               (plist-member params :workDoneToken))
      (let ((token (plist-get params :workDoneToken)))
        (eglotx-test--send-notification
         "$/progress"
         (list :token token
               :value (list :kind "begin" :title "Fast work")))
        (eglotx-test--send-notification
         "$/progress" (list :token token :value (list :kind "end")))))
    (eglotx-test--send-result id (eglotx-test--hover-result params)))
   ((string= method "textDocument/definition")
    (eglotx-test--send-result id (eglotx-test--definition-result)))
   ((string= method "textDocument/typeDefinition")
    (eglotx-test--send-result id (eglotx-test--definition-result)))
   ((string= method "textDocument/codeAction")
    (eglotx-test--send-result id (eglotx-test--code-action-result)))
   ((string= method "textDocument/inlineCompletion")
    (eglotx-test--send-result id (eglotx-test--inline-completion-result)))
   ((string= method "workspace/executeCommand")
    (if (and (string-match-p "bridge-error" eglotx-test--name)
             (equal (plist-get params :command)
                    "typescript.tsserverRequest"))
        (eglotx-test--send-error id -32001 "Synthetic bridge failure")
      (eglotx-test--send-result
       id (eglotx-test--execute-command-result params))))
   ((string= method "textDocument/diagnostic")
    (eglotx-test--send-result id (eglotx-test--diagnostic-result params)))
   ((string= method "eglotx.test/publishDiagnostics")
    (let ((uri (plist-get params :uri))
          (version (plist-get params :version)))
      (unless (stringp uri)
        (error "eglotx.test/publishDiagnostics requires a URI"))
      (eglotx-test--publish-diagnostics
       uri version
       (list :version version
             :clean (eq (plist-get params :clean) t)))
      (eglotx-test--send-result id nil)))
   ((string= method "eglotx.test/workspaceConfigurationWire")
    (eglotx-test--request-workspace-configuration id params))
   ((string= method "eglotx.test/requestClient")
    (eglotx-test--request-client-batch id params))
   ((string= method "eglotx.test/notifyClient")
    (eglotx-test--notify-client-batch id params))
   ((string= method "eglotx.test/vueTsserverBridge")
    (eglotx-test--request-vue-tsserver-bridge id params))
   ((string= method "eglotx.test/state")
    (eglotx-test--send-result id (eglotx-test--state)))
   ((string= method "eglotx.test/crash")
    (setq eglotx-test--exit-code 17
          eglotx-test--running nil))
   (t
    (eglotx-test--send-error
     id -32601 (format "Method not found: %s" method)))))

(defun eglotx-test--complete-delayed (id method params)
  "Complete the pending delayed request ID for METHOD and PARAMS."
  (when (gethash id eglotx-test--pending)
    (remhash id eglotx-test--pending)
    (condition-case error-data
        (eglotx-test--handle-request-now id method params)
      (error
       (eglotx-test--log "delayed request %S failed: %S" id error-data)
       (eglotx-test--send-error id -32603 "Internal error")))))

(defun eglotx-test--handle-request (id method params)
  "Handle request ID, METHOD, and PARAMS, scheduling delay if requested."
  (let ((delay-ms (eglotx-test--request-delay-ms method params)))
    (if delay-ms
        (let ((old-timer (gethash id eglotx-test--pending)))
          (when (timerp old-timer)
            (cancel-timer old-timer))
          (puthash id
                   (run-at-time (/ delay-ms 1000.0) nil
                                #'eglotx-test--complete-delayed
                                id method params)
                   eglotx-test--pending))
      (eglotx-test--handle-request-now id method params))))

(defun eglotx-test--cancel-request (params)
  "Cancel the request identified by cancellation PARAMS."
  (let* ((id (plist-get params :id))
         (timer (gethash id eglotx-test--pending)))
    (push id eglotx-test--cancelled-ids)
    (when (timerp timer)
      (cancel-timer timer)
      (remhash id eglotx-test--pending)
      (eglotx-test--send-error id -32800 "Request cancelled"))))

(defun eglotx-test--handle-notification (method params)
  "Handle notification METHOD with PARAMS."
  (cond
   ((string= method "$/cancelRequest")
    (eglotx-test--cancel-request params))
   ((string= method "textDocument/didOpen")
    (eglotx-test--did-open params))
   ((string= method "textDocument/didChange")
    (eglotx-test--did-change params))
   ((string= method "textDocument/didClose")
    (eglotx-test--did-close params))
   ((string= method "tsserver/response")
    (eglotx-test--vue-tsserver-response params))
   ((string= method "exit")
    (setq eglotx-test--exit-code (if eglotx-test--shutdown 0 1)
          eglotx-test--running nil))))

(defun eglotx-test--dispatch (message)
  "Dispatch one parsed JSON-RPC MESSAGE."
  (if (not (listp message))
      (eglotx-test--send-error nil -32600 "Invalid Request")
    (let* ((method (plist-get message :method))
           (params (plist-get message :params))
           (has-id (plist-member message :id))
           (id (plist-get message :id)))
      (if (not (stringp method))
          (when has-id
            (if (or (plist-member message :result)
                    (plist-member message :error))
                (eglotx-test--handle-response message)
              (eglotx-test--send-error id -32600 "Invalid Request")))
        (eglotx-test--record-message method params)
        (eglotx-test--log "received %s%s"
                          method (if has-id " (request)" ""))
        (if has-id
            (eglotx-test--handle-request id method params)
          (eglotx-test--handle-notification method params))))))

(defun eglotx-test--parse-content-length (header)
  "Return the unique Content-Length declared by HEADER.
Signal an error for a missing, malformed, or conflicting declaration."
  (let ((case-fold-search t)
        length)
    (dolist (line (split-string header "\r?\n"))
      (when (string-match
             "\\`[ \t]*Content-Length:[ \t]*\\([0-9]+\\)[ \t]*\\'"
             line)
        (let ((candidate (string-to-number (match-string 1 line))))
          (when (and length (/= length candidate))
            (error "Conflicting Content-Length headers"))
          (setq length candidate))))
    (unless length
      (error "Missing Content-Length header"))
    (when (> length eglotx-test--maximum-content-bytes)
      (error "Content-Length %d exceeds test-server limit" length))
    length))

(defun eglotx-test--decode-message (body)
  "Decode and parse UTF-8 JSON-RPC BODY."
  (let* ((decoded (decode-coding-string body 'utf-8-unix))
         (round-trip (encode-coding-string decoded 'utf-8-unix t))
         (index 0))
    (unless (equal body round-trip)
      (error "Message body is not valid canonical UTF-8"))
    ;; Emacs preserves malformed input as characters in the `eight-bit'
    ;; charset, so a byte-for-byte round trip alone is not a validity check.
    (while (< index (length decoded))
      (when (eq (char-charset (aref decoded index)) 'eight-bit)
        (error "Message body contains malformed UTF-8"))
      (setq index (1+ index)))
    (setq eglotx-test--current-raw-message decoded)
    (json-parse-string decoded
                       :object-type 'plist
                       :array-type 'array
                       :null-object nil
                       :false-object :json-false)))

(defun eglotx-test--parse-input ()
  "Consume all complete LSP frames currently buffered in INPUT."
  (let (continue)
    (setq continue t)
    (while (and continue eglotx-test--running)
      (let* ((crlf-separator
              (string-match "\r\n\r\n" eglotx-test--input))
             (lf-separator
              (string-match "\n\n" eglotx-test--input))
             (use-crlf
              (and crlf-separator
                   (or (null lf-separator)
                       (< crlf-separator lf-separator))))
             (separator (if use-crlf crlf-separator lf-separator))
             (separator-end
              (and separator (+ separator (if use-crlf 4 2)))))
        (if (null separator)
            (progn
              (when (> (length eglotx-test--input)
                       eglotx-test--maximum-header-bytes)
                (error "LSP header exceeds test-server limit"))
              (setq continue nil))
          (when (> separator eglotx-test--maximum-header-bytes)
            (error "LSP header exceeds test-server limit"))
          (let* ((header (substring eglotx-test--input 0 separator))
                 (content-length (eglotx-test--parse-content-length header))
                 (frame-end (+ separator-end content-length)))
            (if (> frame-end (length eglotx-test--input))
                (setq continue nil)
              (let ((body (substring eglotx-test--input
                                     separator-end frame-end)))
                (setq eglotx-test--input
                      (substring eglotx-test--input frame-end))
                (condition-case error-data
                    (eglotx-test--dispatch
                     (eglotx-test--decode-message body))
                  (error
                   (eglotx-test--log "invalid JSON-RPC body: %S" error-data)
                   (eglotx-test--send-error nil -32700 "Parse error")))))))))))

(defun eglotx-test--read-file-range (file start end)
  "Return bytes in FILE between byte offsets START and END."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil start end)
    (buffer-string)))

(defun eglotx-test--pump-relay ()
  "Read one bounded chunk from the stdin relay and parse complete frames."
  (when (file-exists-p eglotx-test--relay-input-file)
    (let ((size (file-attribute-size
                 (file-attributes eglotx-test--relay-input-file))))
      (when (< size eglotx-test--relay-offset)
        (error "stdin relay was unexpectedly truncated"))
      (when (> size eglotx-test--relay-offset)
        (let* ((end (min size
                         (+ eglotx-test--relay-offset
                            eglotx-test--read-chunk-bytes)))
               (chunk (eglotx-test--read-file-range
                       eglotx-test--relay-input-file
                       eglotx-test--relay-offset end)))
          (setq eglotx-test--relay-offset end
                eglotx-test--input (concat eglotx-test--input chunk))
          (eglotx-test--parse-input))))))

(defun eglotx-test--read-relay-pid ()
  "Read and remember the owned stdin relay PID when available."
  (when (and (null eglotx-test--relay-pid)
             (file-exists-p eglotx-test--relay-pid-file))
    (let ((contents (eglotx-test--read-file-range
                     eglotx-test--relay-pid-file
                     0
                     (file-attribute-size
                      (file-attributes eglotx-test--relay-pid-file)))))
      (when (string-match "\\`[ \t\r\n]*\\([0-9]+\\)" contents)
        (let ((pid (string-to-number (match-string 1 contents))))
          (when (> pid 1)
            (setq eglotx-test--relay-pid pid
                  eglotx-test--relay-start
                  (plist-get (process-attributes pid) :start))))))))

(defun eglotx-test--relay-attributes ()
  "Return process attributes for the owned relay, or nil."
  (and eglotx-test--relay-pid
       (condition-case nil
           (process-attributes eglotx-test--relay-pid)
         (error nil))))

(defun eglotx-test--same-relay-p (attributes)
  "Return non-nil when ATTRIBUTES still describe the owned relay process."
  (and attributes
       (or (null eglotx-test--relay-start)
           (equal eglotx-test--relay-start
                  (plist-get attributes :start)))))

(defun eglotx-test--start-relay ()
  "Start the private background bridge from stdin to a temporary file."
  (let ((shell (executable-find "sh"))
        (tee (executable-find "tee")))
    (unless (and shell tee (file-readable-p "/dev/stdin"))
      (error "The fake server requires POSIX sh, tee, and /dev/stdin"))
    (setq eglotx-test--relay-directory
          (make-temp-file "eglotx-fake-server-" t)
          eglotx-test--relay-input-file
          (expand-file-name "stdin.bin" eglotx-test--relay-directory)
          eglotx-test--relay-pid-file
          (expand-file-name "relay.pid" eglotx-test--relay-directory))
    ;; Destination 0 makes `call-process' return immediately.  Opening
    ;; /dev/stdin happens before the child replaces fd 0, so the relay owns a
    ;; duplicate of this Emacs process's real protocol input.  Positional shell
    ;; arguments avoid interpolating any file name into the command string.
    (call-process
     shell "/dev/stdin" 0 nil
     "-c"
     "printf '%s\\n' \"$$\" > \"$1\"; exec \"$3\" \"$2\" >/dev/null"
     "eglotx-fake-stdio"
     eglotx-test--relay-pid-file
     eglotx-test--relay-input-file
     tee)))

(defun eglotx-test--signal-owned-relay (signal)
  "Send SIGNAL to the relay if its recorded PID is still the owned process."
  (let ((attributes (eglotx-test--relay-attributes)))
    (when (eglotx-test--same-relay-p attributes)
      (condition-case nil
          (signal-process eglotx-test--relay-pid signal)
        (error nil)))))

(defun eglotx-test--cancel-pending ()
  "Cancel every request timer still owned by this server."
  (maphash (lambda (_id timer)
             (when (timerp timer)
               (cancel-timer timer)))
           eglotx-test--pending)
  (clrhash eglotx-test--pending))

(defun eglotx-test--cleanup ()
  "Release timers, relay process, and temporary files owned by this server."
  (eglotx-test--cancel-pending)
  (eglotx-test--read-relay-pid)
  (eglotx-test--signal-owned-relay 15)
  (sleep-for 0.02)
  (eglotx-test--signal-owned-relay 9)
  (when (and eglotx-test--relay-directory
             (file-directory-p eglotx-test--relay-directory))
    (condition-case error-data
        (delete-directory eglotx-test--relay-directory t)
      (error
       (eglotx-test--log "could not remove relay directory: %S" error-data)))))

(defun eglotx-test--reset-state ()
  "Initialize all mutable server state for one process run."
  (setq eglotx-test--running t
        eglotx-test--shutdown nil
        eglotx-test--exit-code 0
        eglotx-test--input (encode-coding-string "" 'binary t)
        eglotx-test--methods nil
        eglotx-test--last-params nil
        eglotx-test--last-params-by-method (make-hash-table :test #'equal)
        eglotx-test--last-did-open nil
        eglotx-test--last-did-change nil
        eglotx-test--cancelled-ids nil
        eglotx-test--pending (make-hash-table :test #'equal)
        eglotx-test--documents (make-hash-table :test #'equal)
        eglotx-test--outgoing-requests (make-hash-table :test #'equal)
        eglotx-test--outgoing-batches (make-hash-table :test #'equal)
        eglotx-test--next-outgoing-id 0
        eglotx-test--current-raw-message nil
        eglotx-test--vue-bridge-requests (make-hash-table :test #'equal)
        eglotx-test--vue-bridge-responses nil
        eglotx-test--relay-directory nil
        eglotx-test--relay-input-file nil
        eglotx-test--relay-pid-file nil
        eglotx-test--relay-pid nil
        eglotx-test--relay-start nil
        eglotx-test--relay-offset 0))

(defun eglotx-test--main ()
  "Run the fake LSP server until exit, EOF, or a fatal framing error."
  (setq eglotx-test--name (eglotx-test--command-line-name)
        command-line-args-left nil)
  (eglotx-test--reset-state)
  (eglotx-test--log "starting")
  (unwind-protect
      (progn
        (eglotx-test--start-relay)
        (while eglotx-test--running
          (eglotx-test--read-relay-pid)
          (eglotx-test--pump-relay)
          ;; A dead relay means stdin reached EOF.  Pumping happens first, so
          ;; all bytes written before the relay exited have already been seen.
          (when (and eglotx-test--relay-pid
                     (null (eglotx-test--relay-attributes)))
            ;; The relay can exit after writing more than one bounded read
            ;; chunk.  Drain its now-stable file before deciding that EOF left
            ;; an incomplete frame.
            (while (and (file-exists-p eglotx-test--relay-input-file)
                        (< eglotx-test--relay-offset
                           (file-attribute-size
                            (file-attributes
                             eglotx-test--relay-input-file))))
              (eglotx-test--pump-relay))
            (when (> (length eglotx-test--input) 0)
              (eglotx-test--log "stdin ended with an incomplete frame"))
            (setq eglotx-test--running nil))
          (when eglotx-test--running
            (sleep-for 0.001))))
    (eglotx-test--cleanup))
  eglotx-test--exit-code)

(when noninteractive
  (let ((debug-on-error nil)
        (inhibit-message t)
        (message-log-max nil)
        status)
    (condition-case error-data
        (setq status (eglotx-test--main))
      (error
       (setq status 70)
       (eglotx-test--log "fatal error: %S" error-data)
       (condition-case nil
           (eglotx-test--cleanup)
         (error nil))))
    (kill-emacs status)))

(provide 'eglotx-fake-server)

;;; eglotx-fake-server.el ends here
