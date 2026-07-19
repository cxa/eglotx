;;; eglotx-benchmark.el --- Repeatable Eglotx microbenchmarks  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian-an

;; This file is part of Eglotx.

;; Eglotx is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; Eglotx is distributed in the hope that it will be useful, but WITHOUT
;; ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
;; FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
;; for more details.

;; You should have received a copy of the GNU General Public License
;; along with Eglotx.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Run with `make benchmark'.  These benchmarks use deterministic fixtures,
;; warm each workload, take several samples, and assert the produced shape.
;; They intentionally report measurements without enforcing machine-specific
;; latency thresholds.

;;; Code:

(require 'benchmark)
(require 'cl-lib)
(require 'eglotx)
(require 'seq)

(defconst eglotx-benchmark--samples 3
  "Number of timed samples collected for each workload.")

(defconst eglotx-benchmark--warmups 3
  "Number of untimed iterations used to warm each workload.")

(defun eglotx-benchmark--median (numbers)
  "Return the median of non-empty list NUMBERS."
  (let* ((ordered (sort (copy-sequence numbers) #'<))
         (count (length ordered))
         (middle (/ count 2)))
    (if (cl-oddp count)
        (nth middle ordered)
      (/ (+ (nth (1- middle) ordered) (nth middle ordered)) 2.0))))

(cl-defun eglotx-benchmark--measure
    (label iterations operations-per-iteration unit thunk validate)
  "Measure THUNK and print one result line for LABEL.

Run ITERATIONS per sample.  OPERATIONS-PER-ITERATION is the number of logical
UNIT operations performed by one THUNK invocation.  VALIDATE is called after
warmup and after every timed sample."
  (dotimes (_ eglotx-benchmark--warmups)
    (funcall thunk))
  (funcall validate)
  (let (elapsed-samples gc-counts gc-times)
    (dotimes (_ eglotx-benchmark--samples)
      (garbage-collect)
      (pcase-let ((`(,elapsed ,gc-count ,gc-time)
                   (benchmark-run iterations (funcall thunk))))
        (push elapsed elapsed-samples)
        (push gc-count gc-counts)
        (push gc-time gc-times))
      (funcall validate))
    (let* ((elapsed (eglotx-benchmark--median elapsed-samples))
           (operation-count (* iterations operations-per-iteration))
           (safe-elapsed (max elapsed 1.0e-9))
           (operations-per-second (/ operation-count safe-elapsed))
           (microseconds-per-operation
            (/ (* safe-elapsed 1000000.0) operation-count)))
      (princ
       (format
        "%-28s %12.0f %s/s  %9.3f us/%s  samples=%s  gc=%d (%.3fs)\n"
        label operations-per-second unit microseconds-per-operation unit
        (mapconcat (lambda (sample) (format "%.4fs" sample))
                   (nreverse elapsed-samples) ",")
        (apply #'+ gc-counts) (apply #'+ gc-times))))))

(defun eglotx-benchmark--backend (index &optional only)
  "Return deterministic synthetic backend INDEX, restricted to ONLY."
  (let* ((name (format "backend-%d" index))
         (incremental (zerop (% index 2)))
         (capabilities
          (list
           :textDocumentSync
           (list :openClose t :change (if incremental 2 1)
                 :save (list :includeText (if incremental t :json-false)))
           :completionProvider
           (list :triggerCharacters (vector "." (format "%d" index))
                 :allCommitCharacters (vector ";" (format "!%d" index))
                 :resolveProvider (if incremental t :json-false))
           :codeActionProvider
           (list :codeActionKinds (vector "quickfix"
                                          (format "source.backend%d" index))
                 :resolveProvider t)
           :executeCommandProvider
           (list :commands (vector "common.apply"
                                   (format "backend%d.apply" index)))
           :hoverProvider t)))
    (eglotx--backend-create
     :id (format "%s#%d" name index)
     :name name
     :command (list name "--stdio")
     :priority (- 100 index)
     :order index
     :required t
     :only only
     :request-timeout 30
     :state 'running
     :capabilities capabilities
     :text-sync (plist-get capabilities :textDocumentSync)
     :registration-methods (make-hash-table :test #'equal)
     :static-capability-selectors (make-hash-table :test #'eq)
     :progress-forward (make-hash-table :test #'equal)
     :progress-reverse (make-hash-table :test #'equal)
     :progress-active (make-hash-table :test #'equal))))

(defun eglotx-benchmark--make-server ()
  "Return a process-isolated facade fixture without starting LSP children."
  (cl-letf (((symbol-function 'eglotx--start-backend)
             (lambda (_server _backend) nil)))
    (make-instance
     'eglotx-server
     :backend-specs
     '((:name "fixture-a" :command ("fixture-a"))
       (:name "fixture-b" :command ("fixture-b"))))))

(defun eglotx-benchmark--delete-server (server)
  "Delete SERVER's inert anchor process without JSON-RPC shutdown polling."
  (when-let* ((process (jsonrpc--process server)))
    (when (process-live-p process)
      (set-process-sentinel process #'ignore)
      (delete-process process))))

(defun eglotx-benchmark--reset-ownership (server)
  "Reset ownership state in benchmark SERVER."
  (clrhash (eglotx--owners server))
  (clrhash (eglotx--completion-batches server))
  (clrhash (eglotx--command-owners server))
  (clrhash (eglotx--command-tokens server))
  (dolist (backend (eglotx--backends server))
    (dolist (kind '(owner command))
      (eglotx--ledger-clear (eglotx--backend-ledger backend kind))))
  (setf (eglotx--next-token server) 0
        (eglotx--orphan-owner-ring server)
        (eglotx--owner-cache-create
         :limit eglotx-orphan-owner-limit
         :nodes (make-hash-table :test #'equal))
        (eglotx--orphan-completion-ring server)
        (make-ring eglotx-completion-batch-limit))
  (maphash
   (lambda (_uri document)
     (setf (eglotx--document-owner-ring document)
           (eglotx--owner-cache-create
            :limit eglotx-document-owner-limit
            :nodes (make-hash-table :test #'equal))
           (eglotx--document-completion-ring document)
           (make-ring eglotx-completion-batch-limit)))
   (eglotx--documents server)))

(defun eglotx-benchmark--open-document (server uri)
  "Install one open benchmark document under URI in SERVER."
  (let ((document
         (eglotx--document-create
          :uri uri :version 0 :generation 0
          :language-id "typescriptreact" :text ""
          :owner-ring
          (eglotx--owner-cache-create
           :limit eglotx-document-owner-limit
           :nodes (make-hash-table :test #'equal))
          :completion-ring (make-ring eglotx-completion-batch-limit))))
    (puthash uri document (eglotx--documents server))
    (puthash (eglotx--canonical-document-uri server uri) document
             (eglotx--document-identities server))
    document))

(defun eglotx-benchmark--route-case (backends)
  "Return route-policy benchmark case over BACKENDS."
  (let* ((methods
          [textDocument/didOpen
           textDocument/didChange
           textDocument/completion
           textDocument/hover
           textDocument/definition
           textDocument/codeAction
           textDocument/formatting
           workspace/executeCommand])
         (batch-size 512)
         (thunk
          (lambda ()
            (let ((eligible 0))
              (dotimes (index batch-size)
                (let* ((method (aref methods (% index (length methods))))
                       (policy (eglotx--policy method))
                       (capability (plist-get policy :capability)))
                  (dolist (backend backends)
                    (when (and (eglotx--backend-allows-p backend method)
                               (eglotx--backend-capable-p
                                backend method capability))
                      (cl-incf eligible)))))
              eligible)))
         (expected (funcall thunk)))
    (list
     "route/policy selection" 500 batch-size "decision" thunk
     (lambda ()
       (cl-assert (eq (eglotx--method-key "textDocument/completion")
                      :textDocument/completion))
       (cl-assert (eq (plist-get (eglotx--policy :textDocument/completion)
                                 :merge)
                      'completion))
       (cl-assert (> expected 0))
       (cl-assert (= (funcall thunk) expected))))))

(defun eglotx-benchmark--utf16-case ()
  "Return incremental UTF-16 document-change benchmark case."
  (let* ((line-count 256)
         (change-count 64)
         (text
          (concat
           (mapconcat
            (lambda (line)
              (format "line-%03d \U0001f600 abcdefghijklmnopqrstuvwxyz" line))
            (number-sequence 0 (1- line-count)) "\n")
           "\n"))
         (changes
          (vconcat
           (cl-loop
            for line below change-count
            collect
            (list :range
                  (list :start (list :line line :character 12)
                        :end (list :line line :character 13))
                  :text "A"))))
         (thunk (lambda () (eglotx--apply-content-changes text changes))))
    (list
     "UTF-16 incremental changes" 25 change-count "change" thunk
     (lambda ()
       (let ((result (funcall thunk)))
         (cl-assert (= (length result) (length text)))
         (cl-assert (string-prefix-p "line-000 \U0001f600 Abc" result))
         (cl-assert
          (string-match-p "line-063 \U0001f600 Abc" result))
         (cl-assert
          (string-match-p "line-064 \U0001f600 abc" result)))))))

(defun eglotx-benchmark--capability-case (server backends)
  "Return capability-combination benchmark case for SERVER and BACKENDS."
  (let ((thunk (lambda ()
                 (eglotx--combine-capabilities server backends))))
    (list
     "capability combination" 500 1 "merge" thunk
     (lambda ()
       (let* ((result (funcall thunk))
              (completion (plist-get result :completionProvider))
              (commands (plist-get
                         (plist-get result :executeCommandProvider)
                         :commands)))
         (cl-assert (equal (plist-get result :positionEncoding) "utf-16"))
         (cl-assert (= (plist-get (plist-get result :textDocumentSync)
                                  :change)
                       2))
         (cl-assert (= (length (plist-get completion :triggerCharacters)) 9))
         (cl-assert (plist-get completion :resolveProvider))
         ;; Backend 7 is restricted to completion/sync methods, so its two raw
         ;; commands must not leak into the merged capability.
         (cl-assert (= (length commands) 14))
         (cl-assert (string-prefix-p "eglotx:" (aref commands 0))))))))

(defun eglotx-benchmark--completion-case (server backends)
  "Return completion merge-and-ownership benchmark for SERVER and BACKENDS."
  (let* ((items-per-backend 96)
         (uri "file:///benchmark/completion.el")
         (outcomes
          (cl-loop
           for backend in backends
           for backend-index from 0
           collect
           (cons
            backend
            (list
             :isIncomplete (if (zerop (% backend-index 2)) t :json-false)
             :items
             (vconcat
              (cl-loop
               for item-index below items-per-backend
               collect
               (list
                :label (format "b%d-item-%03d" backend-index item-index)
                :kind 3
                :commitCharacters [";"]
                :insertTextFormat 1
                :data (list :backend backend-index :item item-index)
                :command
                (list :title "Apply"
                      :command (format "backend%d.apply" backend-index)
                      :arguments (vector item-index)))))))))
         (request
          (eglotx--request-create
           :id 1
           :method :textDocument/completion
           :params (list :textDocument (list :uri uri))
           :policy (eglotx--policy :textDocument/completion)))
         (item-count (* items-per-backend (length backends)))
         (thunk
          (lambda ()
            (eglotx-benchmark--reset-ownership server)
            (eglotx--merge-completions server request outcomes))))
    (list
     "completion merge+ownership" 20 item-count "item" thunk
     (lambda ()
       (let* ((result (funcall thunk))
              (items (plist-get result :items))
              (first (aref items 0))
              (last (aref items (1- (length items)))))
         (cl-assert (eq (plist-get result :isIncomplete) t))
         (cl-assert (= (length items) item-count))
         (cl-assert (equal (plist-get first :label) "b0-item-000"))
         (cl-assert (equal (plist-get last :label) "b7-item-095"))
         (cl-assert (equal (plist-get first :commitCharacters) [";"]))
         (cl-assert (string-prefix-p "eglotx:"
                                     (plist-get first :data)))
         (cl-assert
          (string-prefix-p
           "eglotx:"
           (plist-get (plist-get first :command) :command)))
         (cl-assert (= (hash-table-count (eglotx--owners server)) 0))
         (cl-assert (= (hash-table-count
                        (eglotx--completion-batches server))
                       1))
         (cl-assert (= (hash-table-count (eglotx--command-owners server))
                       (length backends))))))))

(defun eglotx-benchmark-tailwind-batch ()
  "Measure Tailwind's 11,509-item shared-itemDefaults completion path."
  (interactive)
  (let* ((server (eglotx-benchmark--make-server))
         (tailwind (eglotx-benchmark--backend 0))
         (typescript (eglotx-benchmark--backend 1))
         (backends (list tailwind typescript))
         (item-count 11509)
         (uri "file:///benchmark/tailwind.tsx")
         (default-data (list :_projectKey "0"))
         (edit-range
          (list :start (list :line 0 :character 16)
                :end (list :line 0 :character 16)))
         (items
          (vconcat
           (cl-loop
            for index below item-count
            collect
            (append
             (list
              :label (format "tw-%05d" index)
              :kind 12
              :sortText (format "%05d" index)
              :textEditText (format "tw-%05d" index))
             (when (zerop (% index 72))
               (list :command
                     (list :title "Trigger suggestions"
                           :command "editor.action.triggerSuggest")))))))
         (outcomes
          (list
           (cons tailwind
                 (list :isIncomplete :json-false
                       :itemDefaults
                       (list :data default-data :editRange edit-range)
                       :items items))
           (cons typescript [])))
         (request
          (eglotx--request-create
           :id 1 :method :textDocument/completion
           :params (list :textDocument (list :uri uri)
                         :position (list :line 0 :character 16))
           :policy (eglotx--policy :textDocument/completion)))
         result
         (thunk
          (lambda ()
            (eglotx-benchmark--reset-ownership server)
            (setq result
                  (eglotx--merge-completions server request outcomes)))))
    (unwind-protect
        (progn
          (setf (eglotx--backends server) backends)
          (eglotx-benchmark--open-document server uri)
          (setf (eglotx--client-capabilities server)
                '(:textDocument
                  (:completion
                   (:completionItem
                    (:resolveSupport (:properties ["textEdit"]))))))
          (cl-labels
              ((validate
                ()
                (let ((merged (plist-get result :items)))
                  (cl-assert (= (length merged) item-count))
                  (let ((shared-token (plist-get (aref merged 0) :data)))
                    (dolist (index '(0 8191 8192 11508))
                    (let* ((item (aref merged index))
                           (owner
                            (eglotx--owner-for-token
                             server (plist-get item :data)))
                           (restored
                            (eglotx--restore-owned-object
                             server tailwind item)))
                      (cl-assert (eq (plist-get item :data) shared-token))
                      (cl-assert (eq (eglotx--owner-backend owner) tailwind))
                      (cl-assert (equal (plist-get restored :data)
                                        default-data))
                      (cl-assert (not (plist-member item :textEdit)))
                      (let* ((materialized
                              (eglotx--materialize-completion-item server item))
                             (edit (plist-get materialized :textEdit)))
                        (cl-assert
                         (equal (plist-get edit :newText)
                                (plist-get item :label)))
                        (cl-assert
                         (equal (plist-get edit :range) edit-range)))))
                    (let* ((location
                            (eglotx--completion-batch-location
                             server shared-token))
                           (segment
                            (nth (- (cdr location) item-count)
                                 (eglotx--completion-batch-segments
                                  (car location)))))
                      (cl-assert location)
                      (cl-assert
                       (null (eglotx--completion-segment-data segment)))
                      (cl-assert
                       (eq
                        (eglotx--completion-segment-default-edit-range
                         segment)
                        edit-range))))
                  (cl-assert (= (hash-table-count
                                 (eglotx--completion-batches server))
                                1))
                  (cl-assert (= (hash-table-count (eglotx--owners server))
                                0)))))
            (dotimes (_ eglotx-benchmark--warmups) (funcall thunk))
            (validate)
            (let (elapsed-samples gc-counts gc-times)
              (dotimes (_ eglotx-benchmark--samples)
                (garbage-collect)
                (pcase-let ((`(,elapsed ,gc-count ,gc-time)
                             (benchmark-run 1 (funcall thunk))))
                  (push elapsed elapsed-samples)
                  (push gc-count gc-counts)
                  (push gc-time gc-times))
                (validate))
              (garbage-collect)
              (let ((before (memory-use-counts)) after)
                (funcall thunk)
                (setq after (memory-use-counts))
                (validate)
                (let* ((delta (cl-mapcar #'- after before))
                       (elapsed
                        (eglotx-benchmark--median elapsed-samples)))
                  (princ
                   (format
                    "Tailwind shared-default batch (Emacs %s, %d items)\n"
                    emacs-version item-count))
                  (princ
                   (format
                    "median=%.3f ms/response  throughput=%.0f items/s  samples=%s  gc=%d (%.3fs)\n"
                    (* elapsed 1000.0) (/ item-count (max elapsed 1.0e-9))
                    (mapconcat (lambda (sample) (format "%.4fs" sample))
                               (nreverse elapsed-samples) ",")
                    (apply #'+ gc-counts) (apply #'+ gc-times)))
                  (princ
                   (format
                    "allocation/item: cons=%.2f vector-cells=%.2f strings=%.2f string-chars=%.2f\n"
                    (/ (float (nth 0 delta)) item-count)
                    (/ (float (nth 2 delta)) item-count)
                    (/ (float (nth 6 delta)) item-count)
                    (/ (float (nth 4 delta)) item-count)))
                  (princ
                   "All Tailwind shared-batch semantic checks passed.\n"))))))
      (eglotx-benchmark--delete-server server))))

(defun eglotx-benchmark--diagnostic-case (server backend)
  "Return large diagnostic attribution benchmark for SERVER and BACKEND."
  (let* ((diagnostic-count 2048)
         (uri "file:///benchmark/diagnostics.el")
         (diagnostics
          (vconcat
           (cl-loop
            for index below diagnostic-count
            collect
            (list
             :range
             (list :start (list :line index :character 0)
                   :end (list :line index :character 1))
             :severity (1+ (% index 4))
             :source "compiler"
             :message (format "diagnostic-%04d" index)
             :data (list :code index :fixable (zerop (% index 2)))))))
         (thunk
          (lambda ()
            (eglotx-benchmark--reset-ownership server)
            (eglotx--tag-diagnostics server backend diagnostics uri))))
    (list
     "diagnostic tag+ownership" 15 diagnostic-count "item" thunk
     (lambda ()
       (let* ((result (funcall thunk))
              (first (aref result 0))
              (last (aref result (1- diagnostic-count))))
         (cl-assert (= (length result) diagnostic-count))
         (cl-assert (equal (plist-get first :source) "backend-0/compiler"))
         (cl-assert (equal (plist-get last :message) "diagnostic-2047"))
         (cl-assert (string-prefix-p "eglotx:"
                                     (plist-get first :data)))
         (cl-assert (= (hash-table-count (eglotx--owners server))
                       diagnostic-count)))))))

(defun eglotx-benchmark-batch ()
  "Run all repeatable Eglotx benchmarks and print their measurements."
  (interactive)
  (let* ((server (eglotx-benchmark--make-server))
         (backends
          (cl-loop
           for index below 8
           collect
           (eglotx-benchmark--backend
            index
            (and (= index 7)
                 '(:textDocument/didOpen
                   :textDocument/didChange
                   :textDocument/completion)))))
         (cases
          (list
           (eglotx-benchmark--route-case backends)
           (eglotx-benchmark--utf16-case)
           (eglotx-benchmark--capability-case server backends)
           (eglotx-benchmark--completion-case server backends)
           (eglotx-benchmark--diagnostic-case server (car backends)))))
    (unwind-protect
        (progn
          (setf (eglotx--backends server) backends)
          (princ (format "Eglotx benchmarks (Emacs %s, %d samples, %d warmups)\n"
                         emacs-version eglotx-benchmark--samples
                         eglotx-benchmark--warmups))
          (princ "No machine-specific pass/fail thresholds are applied.\n\n")
          (dolist (case cases)
            (apply #'eglotx-benchmark--measure case))
          (princ "\nAll benchmark semantic checks passed.\n"))
      (eglotx-benchmark--delete-server server))
    (princ "\n")
    (eglotx-benchmark-tailwind-batch)))

(provide 'eglotx-benchmark)
;;; eglotx-benchmark.el ends here
