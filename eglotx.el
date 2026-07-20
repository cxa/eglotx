;;; eglotx.el --- Native LSP multiplexer for Eglot  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 CHEN Xian'an

;; Author: CHEN Xian'an <xianan.chen@gmail.com>
;; Maintainer: CHEN Xian'an <xianan.chen@gmail.com>
;; Version: 0.1.2
;; Package-Requires: ((emacs "29.1") (eglot "1.24") (jsonrpc "1.0.29"))
;; Keywords: tools, languages
;; URL: https://github.com/cxa/eglotx

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Eglotx presents one instance of the `eglot-lsp-server' class to Eglot
;; while routing directly
;; to multiple `jsonrpc-process-connection' backends.  The facade never
;; serializes JSON: only real language-server process boundaries do.
;;
;; The normal entry point is `eglotx-contact'.  See the README for setup.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'eglot)
(require 'jsonrpc)
(require 'ring)
(require 'seq)
(require 'subr-x)
(require 'url-util)

(defconst eglotx--uri-path-allowed-chars
  (let ((table (make-vector 256 nil)))
    (dolist (range '((?A . ?Z) (?a . ?z) (?0 . ?9)))
      (cl-loop for character from (car range) to (cdr range)
               do (aset table character t)))
    (dolist (character
             '(?- ?. ?_ ?~ ?! ?$ ?& ?' ?\( ?\) ?* ?+ ?, ?\; ?= ?: ?@ ?/))
      (aset table character t))
    table)
  "Characters left unescaped in a canonical LSP file-URI path.")

(defgroup eglotx nil
  "Run multiple language servers behind one Eglot connection."
  :group 'eglot
  :prefix "eglotx-")

(defcustom eglotx-request-timeout 30
  "Maximum seconds a facade request may wait for backends.

The deadline begins before fan-out.  A backend descriptor can override this
with `:request-timeout'.  `shutdown' always uses a shorter deadline so Eglot's
own shutdown deadline remains authoritative."
  :type '(choice number (const :tag "No facade deadline" nil))
  :safe (lambda (value) (or (null value) (and (numberp value) (> value 0))))
  :group 'eglotx)

(defcustom eglotx-backend-events-buffer-size 0
  "Maximum size of each backend JSON-RPC events buffer.

Zero disables payload logging on backend hot paths.  The facade events buffer
continues to obey `eglot-events-buffer-config'."
  :type '(choice (const :tag "Disabled" 0)
                 (const :tag "Unlimited" nil)
                 (integer :tag "Maximum bytes"))
  :group 'eglotx)

(defcustom eglotx-backend-stderr-buffer-size 65536
  "Maximum characters retained from each backend's stderr stream.

Nil keeps stderr without truncation.  This limit is independent from JSON-RPC
event logging because language servers can write stderr continuously even when
event logging is disabled."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Maximum characters"))
  :safe (lambda (value) (or (null value)
                            (and (integerp value) (>= value 0))))
  :group 'eglotx)

(defcustom eglotx-stream-diagnostics t
  "Use Eglot's streaming-diagnostics extension when it is advertised.

Streaming keeps one diagnostic snapshot per backend inside Eglot and avoids
rebuilding a combined vector after every publication."
  :type 'boolean
  :group 'eglotx)

(defcustom eglotx-max-diagnostics nil
  "Optional maximum number of aggregate diagnostics per document.

Nil means no limit.  This only affects clients without streaming diagnostics."
  :type '(choice (const :tag "Unlimited" nil) positive-integer)
  :group 'eglotx)

(defcustom eglotx-unopened-diagnostic-uri-limit 4096
  "Maximum unopened document identities retained by the Diagnostics Hub.

Open documents are governed by their Eglot lifecycle and are exempt.  For
unopened documents, the newest identities win across push and pull sources;
evicting a visible identity retracts its client projection before releasing
all ownership and version metadata."
  :type 'positive-integer
  :safe (lambda (value) (and (integerp value) (> value 0)))
  :group 'eglotx)

(defcustom eglotx-orphan-owner-limit 65536
  "Maximum ownership records retained outside an open document.

Workspace symbols and diagnostics for unopened files cannot be tied to an
Eglot document generation.  Eglotx retains their opaque data in a bounded
newest-first exact cache so long-running sessions cannot grow without limit."
  :type 'positive-integer
  :group 'eglotx)

(defcustom eglotx-document-owner-limit 8192
  "Maximum non-diagnostic ownership records retained per open document.

The newest records win.  This bounds code-action and other resolve-adjacent
queries within one document generation while leaving active
diagnostic ownership under the diagnostic snapshot lifecycle.  Whole
completion responses use `eglotx-completion-batch-limit' instead."
  :type 'positive-integer
  :group 'eglotx)

(defcustom eglotx-completion-batch-limit 2
  "Maximum whole completion responses retained in each fallback cache.

Completion responses are atomic.  The newest responses win, and the small
overlap permits an older request to finish while Eglot starts a replacement.
Candidates retained as direct Lisp objects by Eglot carry GC-managed leases,
so cache eviction does not invalidate a live completion menu even when a
language server returns tens of thousands of items."
  :type 'positive-integer
  :safe (lambda (value) (and (integerp value) (> value 0)))
  :group 'eglotx)

(defcustom eglotx-work-batch-size 32
  "Maximum deferred facade jobs handled in one event-loop turn.

Batching lets the queue drain faster than a notification burst without
allowing an unbounded callback to monopolize Emacs."
  :type 'positive-integer
  :group 'eglotx)

(defcustom eglotx-diagnostic-chunk-size 64
  "Maximum diagnostic or retirement entries processed per work item.

Large workspace-wide bursts and optional-backend cleanup are split into
continuations at the head of the facade queue.  This preserves notification
barriers while bounding the work performed before Emacs can return to its
event loop."
  :type 'positive-integer
  :group 'eglotx)

(defconst eglotx--retirement-retry-base-delay 0.05
  "Initial seconds before retrying interrupted backend retirement work.")

(defconst eglotx--retirement-retry-max-delay 1.0
  "Maximum seconds between interrupted backend retirement retries.")

(defconst eglotx--file-watch-retry-base-delay 0.1
  "Initial seconds before retrying Eglot file-watch reconciliation.")

(defconst eglotx--file-watch-retry-max-delay 5.0
  "Maximum seconds between Eglot file-watch reconciliation retries.")

(defcustom eglotx-document-selector-limit 256
  "Maximum filters accepted in one LSP document selector.

Language restrictions may expand one filter into several language-specific
filters.  The same bound applies after that intersection, preventing a child
registration from doing unbounded synchronous work in Emacs."
  :type 'positive-integer
  :safe (lambda (value) (and (integerp value) (> value 0)))
  :group 'eglotx)

(defcustom eglotx-file-watcher-limit 4096
  "Maximum logical watched-file patterns retained by one facade.

The bound is applied before compiling or projecting child registrations, so a
server-controlled watcher burst cannot monopolize a JSON-RPC callback."
  :type 'positive-integer
  :safe (lambda (value) (and (integerp value) (> value 0)))
  :group 'eglotx)

(defcustom eglotx-prefix-server-messages t
  "Whether to prefix server log/show messages with the backend name."
  :type 'boolean
  :group 'eglotx)

(defcustom eglotx-cross-backend-request-limit 64
  "Maximum private requests in flight between child backends.

Explicit notification adapters can use bounded, asynchronous child-to-child
requests for protocols that layer one language server over another.  The
limit is per facade and independent from ordinary Eglot requests."
  :type 'positive-integer
  :safe (lambda (value) (and (integerp value) (> value 0)))
  :group 'eglotx)

(defcustom eglotx-cross-backend-request-timeout 30
  "Maximum seconds one private child-to-child request may remain pending."
  :type 'number
  :safe (lambda (value) (and (numberp value) (> value 0)))
  :group 'eglotx)

(define-error 'eglotx-error "Eglotx error")
(define-error 'eglotx-content-modified "Document changed during request"
  'eglotx-error)
(define-error 'eglotx-configuration-error "Invalid Eglotx configuration"
  'eglotx-error)

(cl-defstruct (eglotx--ledger-node
               (:constructor eglotx--ledger-node-create))
  "One key in an exact, insertion-ordered ledger."
  key
  previous
  next)

(cl-defstruct (eglotx--ledger
               (:constructor eglotx--ledger-create))
  "An O(1) keyed ledger with deterministic FIFO retirement order."
  nodes
  head
  tail)

(defun eglotx--make-ledger ()
  "Return an empty exact ledger."
  (eglotx--ledger-create :nodes (make-hash-table :test #'equal)))

(defun eglotx--ledger-add (ledger key)
  "Append absent KEY to LEDGER without reordering an existing entry."
  (let ((nodes (eglotx--ledger-nodes ledger)))
    (unless (gethash key nodes)
      (let* ((tail (eglotx--ledger-tail ledger))
             (node (eglotx--ledger-node-create :key key :previous tail)))
        (if tail
            (setf (eglotx--ledger-node-next tail) node)
          (setf (eglotx--ledger-head ledger) node))
        (setf (eglotx--ledger-tail ledger) node)
        (puthash key node nodes)))
    key))

(defun eglotx--ledger-remove (ledger key)
  "Remove KEY from LEDGER in O(1), returning non-nil when present."
  (let* ((nodes (eglotx--ledger-nodes ledger))
         (node (gethash key nodes)))
    (when node
      (let ((previous (eglotx--ledger-node-previous node))
            (next (eglotx--ledger-node-next node)))
        (if previous
            (setf (eglotx--ledger-node-next previous) next)
          (setf (eglotx--ledger-head ledger) next))
        (if next
            (setf (eglotx--ledger-node-previous next) previous)
          (setf (eglotx--ledger-tail ledger) previous))
        (remhash key nodes)
        t))))

(defun eglotx--ledger-peek (ledger)
  "Return the oldest live key in LEDGER, or nil."
  (when-let* ((head (eglotx--ledger-head ledger)))
    (eglotx--ledger-node-key head)))

(defun eglotx--ledger-count (ledger)
  "Return the number of live keys in LEDGER."
  (hash-table-count (eglotx--ledger-nodes ledger)))

(defun eglotx--ledger-clear (ledger)
  "Discard every key in LEDGER."
  (clrhash (eglotx--ledger-nodes ledger))
  (setf (eglotx--ledger-head ledger) nil
        (eglotx--ledger-tail ledger) nil))

(cl-defstruct (eglotx--owner-cache-node
               (:constructor eglotx--owner-cache-node-create))
  "One token in an exact, bounded owner cache."
  token
  previous
  next)

(cl-defstruct (eglotx--owner-cache
               (:constructor eglotx--owner-cache-create))
  "An intrusive newest-first owner cache with O(1) unlink and eviction."
  limit
  nodes
  head
  tail
  (count 0))

(cl-defstruct (eglotx--backend
               (:constructor eglotx--backend-create))
  id
  name
  command
  process-factory
  priority
  order
  required
  predicate
  initialization-options
  settings
  environment
  only
  languages
  language-table
  notification-handlers
  request-timeout
  connection
  state
  capabilities
  server-info
  text-sync
  registration-methods
  static-capability-selectors
  progress-forward
  progress-reverse
  progress-active
  (ledgers (vector (eglotx--make-ledger)
                   (eglotx--make-ledger)
                   (eglotx--make-ledger)))
  last-error)

(defun eglotx--backend-ledger (backend kind)
  "Return BACKEND's ordered ledger for KIND."
  (aref (eglotx--backend-ledgers backend)
        (pcase kind
          ('owner 0)
          ('command 1)
          ('diagnostic 2)
          (_ (error "Unknown backend ledger kind: %S" kind)))))

(cl-defstruct (eglotx--watcher
               (:constructor eglotx--watcher-create))
  "A compiled dynamic file-watcher selector."
  predicate
  base-path
  kind)

(cl-defstruct (eglotx--document-filter
               (:constructor eglotx--document-filter-create))
  "A compiled LSP document selector filter."
  language
  scheme
  predicate)

(cl-defstruct (eglotx--diagnostic-batch
               (:constructor eglotx--diagnostic-batch-create))
  "A contiguous, generation-aware batch of diagnostic notifications."
  table
  order
  (next-entry 0)
  phase
  latest-by-uri
  uri-order)

(cl-defstruct (eglotx--backend-retirement
               (:constructor eglotx--backend-retirement-create))
  "Incremental diagnostic retirement for one failed optional backend."
  backend
  (phase 'owners)
  push-seen
  aggregate-seen
  retraction-head
  retraction-tail
  refresh-p
  ownership-cleaned-p
  (retry-count 0)
  retry-timer
  reset-buffers
  surviving-pull-p)

(cl-defstruct (eglotx--diagnostic-publication
               (:constructor eglotx--diagnostic-publication-create))
  "One deferred diagnostic publication with its ingress lifecycle identity."
  backend
  params
  document
  generation
  mutation-epoch
  validated-p)

(cl-defstruct (eglotx--diagnostic-uri-node
               (:constructor eglotx--diagnostic-uri-node-create))
  "One unopened URI in the Diagnostics Hub's exact LRU ledger."
  uri
  previous
  next
  projected-p)

(cl-defstruct (eglotx--diagnostic-cursor
               (:constructor eglotx--diagnostic-cursor-create))
  "One facade pull-diagnostic cursor with per-backend child values."
  uri
  document
  generation
  values)

(cl-defstruct (eglotx--diagnostic-child-cursor
               (:constructor eglotx--diagnostic-child-cursor-create))
  "One child diagnostic result ID and its backend-local document spelling."
  result-id
  uri)

(defconst eglotx--diagnostic-cursor-limit 4096
  "Maximum live pull-diagnostic cursors retained by one facade session.")

(defconst eglotx--uri-identity-limit 4096
  "Maximum wire-to-canonical URI identities cached by one facade session.")

(defconst eglotx--missing-value (make-symbol "eglotx-missing-value")
  "Uninterned sentinel shared by allocation-sensitive hash-table lookups.")

(cl-defstruct (eglotx--request
               (:constructor eglotx--request-create))
  id
  method
  params
  document-uri
  document
  document-generation
  document-mutation-epoch
  owner
  owner-token-shared-p
  policy
  targets
  pending
  results
  child-ids
  progress-mappings
  timer
  cancelled
  completed)

(cl-defstruct (eglotx--direct-request
               (:constructor eglotx--direct-request-create))
  "One bounded request owned by an explicit backend notification adapter."
  token
  source
  target
  child-id
  success-function
  error-function)

(cl-defstruct (eglotx--inbound-request
               (:constructor eglotx--inbound-request-create))
  "One active server-to-client request on a child connection."
  id
  tag
  cancelled-p)

(defconst eglotx--inbound-request-cancelled
  (make-symbol "eglotx-inbound-request-cancelled")
  "Private non-local outcome for an active child request cancellation.")

(defvar eglotx--child-request-envelope nil
  "Dynamically bound raw child request envelope.
The value is (CONNECTION ID METHOD).  `jsonrpc.el' does not pass ID to its
request dispatcher, so Eglotx captures it at the receive boundary.")

(defvar eglotx--current-inbound-request nil
  "Dynamically bound deepest child request handler on the current stack.")

(cl-defstruct (eglotx--document
               (:constructor eglotx--document-create))
  uri
  version
  generation
  language-id
  text
  tokens
  owner-ring
  completion-ring)

(cl-defstruct (eglotx--owner
               (:constructor eglotx--owner-create))
  backend
  kind
  data
  data-present-p
  source
  source-present-p
  uri
  generation
  command
  container)

(cl-defstruct (eglotx--completion-segment
               (:constructor eglotx--completion-segment-create))
  "One backend's contiguous range in a merged completion response."
  backend
  start
  end
  default-data
  default-edit-range
  data
  token)

(cl-defstruct (eglotx--completion-batch
               (:constructor eglotx--completion-batch-create))
  "Compact resolve ownership for one whole completion response."
  prefix
  uri
  generation
  document
  size
  segments
  ring)

(defconst eglotx--method-policies
  '((:initialize
     :route all :merge initialize)
    (:shutdown
     :route all :merge shutdown)
    (:textDocument/completion
     :capability :completionProvider :route collect :merge completion
     :affinity t :commands t)
    (:completionItem/resolve
     :capability :completionProvider :route owner :merge first
     :affinity t :commands t :resolve t)
    (:textDocument/hover
     :capability :hoverProvider :route collect :merge hover)
    (:textDocument/signatureHelp
     :capability :signatureHelpProvider :route exclusive :merge first)
    (:textDocument/declaration
     :capability :declarationProvider :route collect :merge locations)
    (:textDocument/definition
     :capability :definitionProvider :route collect :merge locations)
    (:textDocument/typeDefinition
     :capability :typeDefinitionProvider :route collect :merge locations)
    (:textDocument/implementation
     :capability :implementationProvider :route collect :merge locations)
    (:textDocument/references
     :capability :referencesProvider :route collect :merge locations)
    (:textDocument/documentHighlight
     :capability :documentHighlightProvider :route collect :merge append)
    (:textDocument/documentSymbol
     ;; LSP permits either DocumentSymbol[] or SymbolInformation[] here.  Two
     ;; independently valid children can choose different shapes, so never
     ;; concatenate their arrays into an invalid heterogeneous result.
     :capability :documentSymbolProvider :route exclusive :merge first)
    (:textDocument/codeAction
     :capability :codeActionProvider :route collect :merge append
     :affinity t :commands t)
    (:codeAction/resolve
     :capability :codeActionProvider :route owner :merge first
     :affinity t :commands t :resolve t)
    (:textDocument/codeLens
     :capability :codeLensProvider :route collect :merge append
     :affinity t :commands t)
    (:codeLens/resolve
     :capability :codeLensProvider :route owner :merge first
     :affinity t :commands t :resolve t)
    (:textDocument/documentLink
     :capability :documentLinkProvider :route collect :merge append
     :affinity t)
    (:documentLink/resolve
     :capability :documentLinkProvider :route owner :merge first
     :affinity t :resolve t)
    (:textDocument/documentColor
     :capability :colorProvider :route collect :merge append)
    (:textDocument/colorPresentation
     :capability :colorProvider :route collect :merge append)
    (:textDocument/foldingRange
     :capability :foldingRangeProvider :route collect :merge append)
    (:textDocument/selectionRange
     :capability :selectionRangeProvider :route exclusive :merge first)
    (:textDocument/linkedEditingRange
     :capability :linkedEditingRangeProvider :route exclusive :merge first)
    (:textDocument/prepareCallHierarchy
     :capability :callHierarchyProvider :route collect :merge append :affinity t)
    (:callHierarchy/incomingCalls
     :capability :callHierarchyProvider :route owner :merge hierarchy-calls
     :item-key :from)
    (:callHierarchy/outgoingCalls
     :capability :callHierarchyProvider :route owner :merge hierarchy-calls
     :item-key :to)
    (:textDocument/prepareTypeHierarchy
     :capability :typeHierarchyProvider :route collect :merge append :affinity t)
    (:typeHierarchy/supertypes
     :capability :typeHierarchyProvider :route owner :merge append :affinity t)
    (:typeHierarchy/subtypes
     :capability :typeHierarchyProvider :route owner :merge append :affinity t)
    (:textDocument/inlayHint
     :capability :inlayHintProvider :route collect :merge append
     :affinity t :commands t)
    (:inlayHint/resolve
     :capability :inlayHintProvider :route owner :merge first
     :affinity t :commands t :resolve t)
    (:textDocument/inlineValue
     :capability :inlineValueProvider :route collect :merge append)
    (:textDocument/inlineCompletion
     :capability :inlineCompletionProvider :route exclusive :merge first
     :commands t)
    (:textDocument/moniker
     :capability :monikerProvider :route collect :merge append)
    (:textDocument/diagnostic
     :capability :diagnosticProvider :route collect :merge diagnostic)
    (:workspace/symbol
     :capability :workspaceSymbolProvider :route collect :merge append
     :affinity t)
    (:workspaceSymbol/resolve
     :capability :workspaceSymbolProvider :route owner :merge first
     :affinity t :resolve t)
    (:workspace/executeCommand
     :capability :executeCommandProvider :route command :merge first)
    (:workspace/willCreateFiles
     :capability :workspace :route exclusive :merge first)
    (:workspace/willRenameFiles
     :capability :workspace :route exclusive :merge first)
    (:workspace/willDeleteFiles
     :capability :workspace :route exclusive :merge first)
    (:textDocument/formatting
     :capability :documentFormattingProvider :route exclusive :merge first)
    (:textDocument/rangeFormatting
     :capability :documentRangeFormattingProvider :route exclusive :merge first)
    (:textDocument/onTypeFormatting
     :capability :documentOnTypeFormattingProvider :route exclusive :merge first)
    (:textDocument/rename
     :capability :renameProvider :route exclusive :merge first)
    (:textDocument/prepareRename
     :capability :renameProvider :route exclusive :merge first)
    (:textDocument/willSaveWaitUntil
     :capability :textDocumentSync :route exclusive :merge first)
    (:textDocument/semanticTokens/full
     :capability :semanticTokensProvider :route exclusive :merge first)
    (:textDocument/semanticTokens/full/delta
     :capability :semanticTokensProvider :route exclusive :merge first)
    (:textDocument/semanticTokens/range
     :capability :semanticTokensProvider :route exclusive :merge first))
  "Built-in request routing and combination policies.")

(defconst eglotx--method-policy-table
  (let ((table (make-hash-table :test #'eq)))
    (dolist (entry eglotx--method-policies table)
      (puthash (car entry) (cdr entry) table)))
  "Constant-time lookup table derived from `eglotx--method-policies'.")

(defconst eglotx--lifecycle-methods
  '(:initialize :initialized :shutdown :exit :$/cancelRequest)
  "Methods that backend `:only' restrictions never exclude.")

(defconst eglotx--workspace-file-operation-methods
  '((:workspace/willCreateFiles . :willCreate)
    (:workspace/didCreateFiles . :didCreate)
    (:workspace/willRenameFiles . :willRename)
    (:workspace/didRenameFiles . :didRename)
    (:workspace/willDeleteFiles . :willDelete)
    (:workspace/didDeleteFiles . :didDelete))
  "Mapping from LSP file-operation methods to workspace capability keys.")

(defconst eglotx--notebook-sync-methods
  '(:notebookDocument/didOpen :notebookDocument/didChange
    :notebookDocument/didSave :notebookDocument/didClose)
  "Notebook notifications owned by a singleton sync provider.")

(defconst eglotx--semantic-token-methods
  '(:textDocument/semanticTokens/full
    :textDocument/semanticTokens/full/delta
    :textDocument/semanticTokens/range)
  "Semantic-token methods that must share one provider and legend.")

(defconst eglotx--static-registration-capabilities
  '(:declarationProvider :typeDefinitionProvider :implementationProvider
    :colorProvider :foldingRangeProvider :selectionRangeProvider
    :callHierarchyProvider :linkedEditingRangeProvider
    :semanticTokensProvider :typeHierarchyProvider :inlineValueProvider
    :inlayHintProvider :diagnosticProvider :notebookDocumentSync
    :inlineCompletionProvider)
  "Server capabilities whose option object may contain a child-local `:id'.

Static registration IDs are scoped to one client/server connection.  Eglotx
negotiates one aggregate capability instead of registering each initialize
result, so a raw child ID can never be a valid facade registration identity.")

(defconst eglotx--static-registration-method-map
  '((:declarationProvider . :textDocument/declaration)
    (:typeDefinitionProvider . :textDocument/typeDefinition)
    (:implementationProvider . :textDocument/implementation)
    (:colorProvider . :textDocument/documentColor)
    (:foldingRangeProvider . :textDocument/foldingRange)
    (:selectionRangeProvider . :textDocument/selectionRange)
    (:callHierarchyProvider . :textDocument/prepareCallHierarchy)
    (:linkedEditingRangeProvider . :textDocument/linkedEditingRange)
    (:semanticTokensProvider . :textDocument/semanticTokens)
    (:typeHierarchyProvider . :textDocument/prepareTypeHierarchy)
    (:inlineValueProvider . :textDocument/inlineValue)
    (:inlayHintProvider . :textDocument/inlayHint)
    (:diagnosticProvider . :textDocument/diagnostic)
    (:notebookDocumentSync . :notebookDocument/sync)
    (:inlineCompletionProvider . :textDocument/inlineCompletion))
  "Static server capability to LSP registration-method mapping.")

(defconst eglotx--document-selector-method-map
  (append
   (seq-remove
    (lambda (entry) (eq (car entry) :notebookDocumentSync))
    eglotx--static-registration-method-map)
   '((:monikerProvider . :textDocument/moniker)))
  "Static server capabilities whose options may select text documents.

This is deliberately distinct from `eglotx--static-registration-method-map'.
For example, MonikerOptions extends TextDocumentRegistrationOptions and thus
has `:documentSelector', but it does not extend StaticRegistrationOptions and
cannot carry a connection-local `:id'.")

(defconst eglotx--empty-provider 'eglotx--empty-provider
  "Internal marker for a present capability whose JSON object was empty.")

(defconst eglotx--empty-method-filter 'eglotx--empty-method-filter
  "Internal marker for an explicitly empty vector-valued `:only' filter.")

(defconst eglotx--unknown-document-language
  'eglotx--unknown-document-language
  "Internal marker for document traffic without a known language ID.")

(defclass eglotx-server (eglot-lsp-server)
  ((backend-specs
    :initarg :backend-specs
    :initform nil
    :documentation "Backend descriptors supplied by `eglotx-contact'.")
   (servers
    :initarg :servers
    :initform nil
    :documentation "Raw class-contact alias for `backend-specs'.")
   (backends
    :initform nil
    :accessor eglotx--backends)
   (backend-table
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--backend-table)
   (backend-id-table
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--backend-id-table)
   (state
    :initform 'new
    :accessor eglotx--state)
   (requests
    :initform (make-hash-table :test #'eql)
    :accessor eglotx--requests)
   (direct-requests
    :initform (make-hash-table :test #'eql)
    :accessor eglotx--direct-requests)
   (next-direct-token
    :initform 0
    :accessor eglotx--next-direct-token)
   (direct-request-total
    :initform 0
    :accessor eglotx--direct-request-total)
   (work-head
    :initform nil
    :accessor eglotx--work-head)
   (work-tail
    :initform nil
    :accessor eglotx--work-tail)
   (work-timer
    :initform nil
    :accessor eglotx--work-timer)
   (documents
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--documents)
   (document-identities
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--document-identities)
   (document-mutation-epochs
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--document-mutation-epochs)
   (document-mutation-epoch
    :initform 0
    :accessor eglotx--document-mutation-epoch)
   (uri-identities
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--uri-identities)
   (uri-identity-ring
    :initform (make-ring eglotx--uri-identity-limit)
    :accessor eglotx--uri-identity-ring)
   (owners
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--owners)
   (completion-batches
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--completion-batches)
   (command-owners
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--command-owners)
   (command-tokens
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--command-tokens)
   (command-providers
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--command-providers)
   (diagnostic-tokens
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-tokens)
   (diagnostic-snapshots
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-snapshots)
   (diagnostic-version-watermarks
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-version-watermarks)
   (diagnostic-uri-nodes
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-uri-nodes)
   (diagnostic-uri-head
    :initform nil
    :accessor eglotx--diagnostic-uri-head)
   (diagnostic-uri-tail
    :initform nil
    :accessor eglotx--diagnostic-uri-tail)
   (diagnostic-cursors
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-cursors)
   (diagnostic-cursor-subjects
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--diagnostic-cursor-subjects)
   (diagnostic-cursor-ring
    :initform (make-ring eglotx--diagnostic-cursor-limit)
    :accessor eglotx--diagnostic-cursor-ring)
   (diagnostic-provider-id
    :initform nil
    :accessor eglotx--diagnostic-provider-id)
   (pending-diagnostics
    :initform nil
    :accessor eglotx--pending-diagnostics)
   (orphan-owner-ring
    :initform nil
    :accessor eglotx--orphan-owner-ring)
   (orphan-completion-ring
    :initform nil
    :accessor eglotx--orphan-completion-ring)
   (singleton-providers
    :initform (make-hash-table :test #'eq)
    :accessor eglotx--singleton-providers)
   (next-token
    :initform 0
    :accessor eglotx--next-token)
   (session-id
    :initform nil
    :accessor eglotx--session-id)
   (stream-diagnostics-p
    :initform nil
    :accessor eglotx--stream-diagnostics-p)
   (client-capabilities
    :initform nil
    :accessor eglotx--client-capabilities)
   (facade-capabilities
    :initform nil
    :accessor eglotx--facade-capabilities)
   (watch-selectors
    :initform (make-hash-table :test #'eq)
    :accessor eglotx--watch-selectors)
   (watch-registration-id
    :initform nil
    :accessor eglotx--watch-registration-id)
   (watch-registration-active-p
    :initform nil
    :accessor eglotx--watch-registration-active-p)
   (watch-registration-watchers
    :initform nil
    :accessor eglotx--watch-registration-watchers)
   (watch-rebuild-queued-p
    :initform nil
    :accessor eglotx--watch-rebuild-queued-p)
   (watch-rebuild-retry-timer
    :initform nil
   :accessor eglotx--watch-rebuild-retry-timer)
  (watch-rebuild-retry-delay
    :initform 0.1
    :accessor eglotx--watch-rebuild-retry-delay)
   (semantic-refresh-pending-p
    :initform nil
    :accessor eglotx--semantic-refresh-pending-p)
   (project-directory
    :initform nil
    :accessor eglotx--project-directory)
   (language-cohort
    :initform nil
    :accessor eglotx--language-cohort
    :documentation "Stable MODE to LSP language-ID mapping for this facade."))
  :documentation
  "An Eglot facade backed by multiple language-server connections.")

(defclass eglotx--child-connection (jsonrpc-process-connection)
  ((active-inbound-requests
    :initform (make-hash-table :test #'equal)
    :accessor eglotx--child-active-inbound-requests))
  :documentation "A child connection whose late replies are safely ignored.")

;;;###autoload
(defun eglotx-contact (&rest backends)
  "Return an Eglot contact that multiplexes BACKENDS.

At least two descriptors are required.  Each descriptor is either an argv list
such as (\"ruff\" \"server\"), or a plist containing `:command' and/or a
zero-argument `:process' factory.  Supported optional keys are `:name',
`:priority', `:required', `:when', `:initialization-options', `:settings',
`:environment', `:only', `:languages', `:notification-handlers', and
`:request-timeout'.  Initialization options and settings accept either a
JSON-shaped overlay or a transformation function.

Remaining descriptor validation and `:when' filtering occur when Eglot
constructs the server.  A manual contact remains a facade even if only one
descriptor is then active; the single-server fast path is preset policy.
Higher priority wins and declaration order breaks ties.  See `docs/api.md' for
the complete contract.  The result can be used directly in
`eglot-server-programs'."
  (when (< (length backends) 2)
    (signal 'eglotx-configuration-error
            '("At least two backends are required")))
  (list 'eglotx-server :backend-specs (copy-tree backends)))

(defun eglotx--make-anchor-process ()
  "Create the inert process required by Eglot's LSP server class."
  (make-pipe-process :name "eglotx-anchor" :buffer nil
                     :noquery t :coding 'binary))

(cl-defmethod initialize-instance :around
  ((server eglotx-server) &optional slots)
  "Supply SERVER with an inert process before Eglot initializes it."
  (let* ((connection-name (plist-get slots :name))
         (preexisting-buffers
          (and connection-name
               (eglotx--existing-connection-buffers connection-name)))
         (process-factory
          (if (plist-member slots :process)
              (plist-get slots :process)
            #'eglotx--make-anchor-process))
         raw-process committed result)
    ;; Capture the raw process before jsonrpc renames buffers and commits it to
    ;; its slot; those constructor steps can themselves exit non-locally.
    (setq slots
          (plist-put
           (copy-sequence slots) :process
           (lambda ()
             (setq raw-process
                   (if (functionp process-factory)
                       (funcall process-factory)
                     process-factory)))))
    (unwind-protect
        (progn
          (setq result (cl-call-next-method server slots)
                committed t)
          result)
      ;; The superclass creates its transport before the Eglotx :after method
      ;; runs.  Own that handoff gap so a non-local exit cannot strand it.
      (unless committed
        (let ((inhibit-quit t))
          (when (processp raw-process)
            (ignore-errors (set-process-sentinel raw-process #'ignore))
            (ignore-errors (delete-process raw-process))
            (eglotx--discard-process-buffer (process-buffer raw-process)))
          (when-let* ((process (ignore-errors (jsonrpc--process server))))
            (when (processp process)
              (ignore-errors (set-process-sentinel process #'ignore))
              (ignore-errors (delete-process process))))
          (ignore-errors (eglotx--cleanup-child-buffers server))
          ;; The superclass can rename its stderr buffer before installing
          ;; PROCESS in SERVER.  Release only exact buffers created by this
          ;; constructor; prefix matching can kill a healthy sibling.
          (when connection-name
            (eglotx--cleanup-new-connection-buffers
             connection-name preexisting-buffers)))))))

(cl-defmethod initialize-instance :after
  ((server eglotx-server) &optional _slots)
  "Validate and start all configured backends for SERVER."
  (setf (eglotx--session-id server)
        (format "%x-%x" (emacs-pid) (random most-positive-fixnum))
        (eglotx--orphan-owner-ring server)
        (eglotx--owner-cache-create
         :limit eglotx-orphan-owner-limit
         :nodes (make-hash-table :test #'equal))
        (eglotx--orphan-completion-ring server)
        (make-ring eglotx-completion-batch-limit)
        (eglotx--project-directory server) default-directory
        (eglotx--state server) 'starting)
  (let (committed)
    (unwind-protect
        (let* ((raw (or (oref server backend-specs) (oref server servers)))
               (normalized
                (eglotx--normalize-backends raw default-directory)))
          (unless normalized
            (signal 'eglotx-configuration-error
                    '("No backend is active for this project")))
          (setf (eglotx--backends server) normalized)
          (dolist (backend normalized)
            (puthash (eglotx--backend-name backend) backend
                     (eglotx--backend-table server))
            (puthash (eglotx--backend-id backend) backend
                     (eglotx--backend-id-table server)))
          (dolist (backend normalized)
            (eglotx--start-backend server backend))
          (setf (eglotx--state server) 'running
                committed t))
      ;; Constructor cleanup is transactional for every non-local exit,
      ;; including `quit' and `throw', not only ordinary `error' conditions.
      (unless committed
        (let ((inhibit-quit t))
          (setf (eglotx--state server) 'failed)
          (eglotx--close-backends server t t)
          (when (process-live-p (jsonrpc--process server))
            ;; Eglot has not populated its own slots yet, so its normal
            ;; shutdown callback cannot safely run on this failure path.
            (set-process-sentinel (jsonrpc--process server) #'ignore)
            (delete-process (jsonrpc--process server)))
          ;; `jsonrpc-process-connection' allocates facade output/stderr
          ;; buffers before this :after method runs.
          (eglotx--cleanup-child-buffers server))))))

(defun eglotx--method-key (method)
  "Return canonical keyword form of METHOD."
  (cond
   ((keywordp method) method)
   ((symbolp method) (intern (concat ":" (symbol-name method))))
   ((stringp method) (intern (concat ":" method)))
   (t (signal 'wrong-type-argument (list '(or symbol string) method)))))

(defun eglotx--normalize-only (value)
  "Normalize backend method restriction VALUE."
  (cond
   ((null value) nil)
   ((vectorp value)
    (let ((methods (mapcar #'eglotx--method-key (append value nil))))
      (or methods eglotx--empty-method-filter)))
   ((proper-list-p value)
    (mapcar #'eglotx--method-key value))
   (t
    (signal 'eglotx-configuration-error
            '("`:only' must be a list or vector of LSP method names")))))

(defun eglotx--normalize-languages (value)
  "Normalize backend LSP language restriction VALUE."
  (cond
   ((null value) nil)
   ((not (proper-list-p value))
    (signal 'eglotx-configuration-error
            '("`:languages' must be a list of LSP language ID strings")))
   (t
    (let ((seen (make-hash-table :test #'equal))
          normalized)
      (dolist (language value normalized)
        (unless (and (stringp language) (not (string-empty-p language)))
          (signal 'eglotx-configuration-error
                  '("`:languages' entries must be non-empty strings")))
        (unless (gethash language seen)
          (let ((copy (copy-sequence language)))
            (puthash copy t seen)
            (setq normalized (nconc normalized (list copy))))))))))

(defun eglotx--make-language-table (languages)
  "Return an immutable-by-convention membership table for LANGUAGES."
  (when languages
    (let ((table (make-hash-table :test #'equal :size (length languages))))
      (dolist (language languages table)
        (puthash language t table)))))

(defun eglotx--normalize-notification-handlers (value backend-name)
  "Compile notification handler alist VALUE for BACKEND-NAME.
Return nil when VALUE is nil and an equal-free method hash otherwise."
  (cond
   ((null value) nil)
   ((not (proper-list-p value))
    (signal 'eglotx-configuration-error
            (list (format
                   "Backend %s has an invalid `:notification-handlers' alist"
                   backend-name))))
   (t
    (let ((table (make-hash-table :test #'eq :size (length value))))
      (dolist (entry value table)
        (unless (and (consp entry)
                     (or (stringp (car entry)) (symbolp (car entry)))
                     (functionp (cdr entry)))
          (signal 'eglotx-configuration-error
                  (list
                   (format "Backend %s has an invalid notification handler"
                           backend-name))))
        (let ((method (eglotx--method-key (car entry))))
          (when (gethash method table)
            (signal 'eglotx-configuration-error
                    (list
                     (format "Backend %s has duplicate handler for %s"
                             backend-name method))))
          (puthash method (cdr entry) table)))))))

(defun eglotx--normalize-backends (specs project-directory)
  "Validate SPECS and return active backends for PROJECT-DIRECTORY."
  (unless (and (proper-list-p specs) (>= (length specs) 2))
    (signal 'eglotx-configuration-error
            '("`:backend-specs' or `:servers' must contain two backends")))
  (let ((seen (make-hash-table :test #'equal))
        active)
    (cl-loop
     for spec in specs
     for order from 0
     for plist = (and (consp spec) (keywordp (car spec)) spec)
     for command = (if plist (plist-get plist :command) spec)
     for factory = (and plist (plist-get plist :process))
     for priority = (if (and plist (plist-member plist :priority))
                        (plist-get plist :priority)
                      0)
     for request-timeout =
     (if (and plist (plist-member plist :request-timeout))
         (plist-get plist :request-timeout)
       eglotx-request-timeout)
     for raw-name = (or (and plist (plist-get plist :name))
                        (and (consp command) (car command)))
     for name = (cond ((stringp raw-name)
                       (file-name-nondirectory raw-name))
                      ((symbolp raw-name) (symbol-name raw-name))
                      (t nil))
     do
     (unless (or (and (consp command) (cl-every #'stringp command))
                 (functionp factory))
       (signal 'eglotx-configuration-error
               (list (format "Backend %d needs a string argv `:command'" order))))
     (unless (and name (not (string-empty-p name)))
       (signal 'eglotx-configuration-error
               (list (format "Backend %d needs a non-empty name" order))))
     (unless (numberp priority)
       (signal 'eglotx-configuration-error
               (list (format "Backend %s has a non-numeric priority" name))))
     (unless (or (null request-timeout)
                 (and (numberp request-timeout) (> request-timeout 0)))
       (signal 'eglotx-configuration-error
               (list (format "Backend %s has an invalid request timeout"
                             name))))
     (when (gethash name seen)
       (signal 'eglotx-configuration-error
               (list (format "Duplicate backend name: %s" name))))
     (puthash name t seen)
     (let ((predicate (if (and plist (plist-member plist :when))
                          (plist-get plist :when)
                        t)))
       (unless (or (null predicate) (eq predicate t) (functionp predicate))
         (signal 'eglotx-configuration-error
                 (list (format "Invalid `:when' for backend %s" name))))
       (when (or (eq predicate t)
                 (and (functionp predicate)
                      (funcall predicate project-directory)))
         (let* ((environment (and plist (plist-get plist :environment)))
                (languages
                 (eglotx--normalize-languages
                  (and plist (plist-get plist :languages)))))
           (unless (or (null environment)
                       (cl-every (lambda (entry)
                                   (and (consp entry)
                                        (stringp (car entry))
                                        (stringp (cdr entry))))
                                 environment))
             (signal 'eglotx-configuration-error
                     (list (format "Invalid environment for backend %s" name))))
           (push
            (eglotx--backend-create
             :id (format "%s#%d" name order)
             :name name
             :command command
             :process-factory factory
             :priority priority
             :order order
             :required (if (and plist (plist-member plist :required))
                           (plist-get plist :required)
                         t)
             :predicate predicate
             :initialization-options
             (and plist (plist-get plist :initialization-options))
             :settings (and plist (plist-get plist :settings))
             :environment environment
             :only (eglotx--normalize-only (and plist (plist-get plist :only)))
             :languages languages
             :language-table (eglotx--make-language-table languages)
             :notification-handlers
             (eglotx--normalize-notification-handlers
              (and plist (plist-get plist :notification-handlers)) name)
             :request-timeout request-timeout
             :state 'new
             :registration-methods (make-hash-table :test #'equal)
             :static-capability-selectors (make-hash-table :test #'eq)
             :progress-forward (make-hash-table :test #'equal)
             :progress-reverse (make-hash-table :test #'equal)
             :progress-active (make-hash-table :test #'equal))
            active)))))
    (sort active
          (lambda (left right)
            (let ((lp (eglotx--backend-priority left))
                  (rp (eglotx--backend-priority right)))
              (if (= lp rp)
                  (< (eglotx--backend-order left)
                     (eglotx--backend-order right))
                (> lp rp)))))))

(defun eglotx--trim-stderr-buffer (&rest _change)
  "Keep the current backend stderr buffer within its configured bound."
  (when (and eglotx-backend-stderr-buffer-size
             (> (buffer-size) eglotx-backend-stderr-buffer-size))
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region
       (point-min)
       (- (point-max) eglotx-backend-stderr-buffer-size)))))

(defun eglotx--discard-process-buffer (buffer)
  "Delete BUFFER's live process and then kill BUFFER."
  (when (buffer-live-p buffer)
    (when-let* ((process (get-buffer-process buffer)))
      (ignore-errors (delete-process process)))
    (kill-buffer buffer)))

(defun eglotx--connection-buffer-names (connection-name)
  "Return exact JSON-RPC buffer names for CONNECTION-NAME."
  (list (format "*%s stderr*" connection-name)
        (format " *%s stderr*" connection-name)
        (format " *%s output*" connection-name)
        (format "*%s events*" connection-name)))

(defun eglotx--existing-connection-buffers (connection-name)
  "Return buffers already using CONNECTION-NAME's exact JSON-RPC names."
  (delq nil
        (mapcar #'get-buffer
                (eglotx--connection-buffer-names connection-name))))

(defun eglotx--cleanup-new-connection-buffers
    (connection-name preexisting-buffers)
  "Release CONNECTION-NAME buffers absent from PREEXISTING-BUFFERS.

JSON-RPC creates and renames transport buffers in several constructor steps.
Object identity and exact names keep cleanup local when backend names share a
prefix, such as `typescript' and `typescript-eslint'."
  (dolist (name (eglotx--connection-buffer-names connection-name))
    (when-let* ((buffer (get-buffer name))
                ((not (memq buffer preexisting-buffers))))
      (eglotx--discard-process-buffer buffer))))

(defun eglotx--backend-process (server backend connection-name)
  "Create BACKEND's process for SERVER named CONNECTION-NAME."
  ;; `jsonrpc-process-connection' pre-creates this exact forwarding buffer
  ;; before invoking its process factory.  Reuse and bound it on every path.
  (let ((default-directory (eglotx--project-directory server))
        (process-environment (copy-sequence process-environment))
        (stderr-buffer
         (get-buffer-create (format "*%s stderr*" connection-name))))
    (with-current-buffer stderr-buffer
      (add-hook 'after-change-functions #'eglotx--trim-stderr-buffer nil t))
    (dolist (entry (eglotx--backend-environment backend))
      (setenv (car entry) (cdr entry)))
    (let (process committed)
      (unwind-protect
          (progn
            (setq process
                  (if-let* ((factory
                             (eglotx--backend-process-factory backend)))
                      (funcall factory)
                    (make-process
                     :name connection-name
                     :command (eglotx--backend-command backend)
                     :connection-type 'pipe
                     :coding 'utf-8-emacs-unix
                     :noquery t
                     :stderr stderr-buffer
                     :file-handler t)))
            (unless (and (processp process) (process-live-p process))
              (signal
               'eglotx-configuration-error
               (list
                (format
                 "Backend %s process factory returned no live process: %S"
                 (eglotx--backend-name backend) process))))
            (setq committed t)
            process)
        ;; Both exec and custom-factory failures happen before BACKEND owns a
        ;; connection.  Cover every non-local exit so startup cannot strand a
        ;; process or forwarding buffer before constructor cleanup can see it.
        (unless committed
          (let ((inhibit-quit t))
            (when (processp process)
              ;; jsonrpc has not taken ownership yet, and PROCESS may have no
              ;; buffer, so delete it directly before releasing any buffer.
              (ignore-errors (set-process-sentinel process #'ignore))
              (ignore-errors (delete-process process))
              (eglotx--discard-process-buffer (process-buffer process)))
            (eglotx--discard-process-buffer stderr-buffer)))))))

(defun eglotx--backend-event-initargs ()
  "Return disabled backend logging initargs."
  (list :events-buffer-config
        (list :size eglotx-backend-events-buffer-size :format 'short)))

(defvar eglotx--in-deferred-work nil
  "Non-nil while draining one facade deferred-work item.")

(defvar eglotx--deferred-work-yield-p nil
  "Dynamically non-nil when the current facade drain must end after its job.")

(defun eglotx--drain-work (server)
  "Run a bounded batch of deferred SERVER work in FIFO order."
  (setf (eglotx--work-timer server) 'running)
  ;; Each job is atomic: losing a finalizer halfway through could strand its
  ;; parent continuation.  A pending C-g stops before the next job, and is
  ;; delivered after the unwind cleanup has rescheduled the remaining queue.
  (let ((inhibit-quit t))
    (unwind-protect
        (let ((remaining eglotx-work-batch-size)
              (eglotx--deferred-work-yield-p nil))
          (while (and (> remaining 0)
                      (not quit-flag)
                      (not eglotx--deferred-work-yield-p)
                      (eglotx--work-head server))
            (let* ((cell (eglotx--work-head server))
                   (job (car cell)))
              (setf (eglotx--work-head server) (cdr cell))
              (unless (eglotx--work-head server)
                (setf (eglotx--work-tail server) nil))
              (let ((eglotx--in-deferred-work t))
                (condition-case err
                    (apply (car job) (cdr job))
                  (error
                   (display-warning
                    'eglotx
                    (format "Deferred facade work failed: %s"
                            (error-message-string err))
                    :error))))
              (cl-decf remaining))))
      (setf (eglotx--work-timer server)
            (and (eglotx--work-head server)
                 (run-at-time 0 nil #'eglotx--drain-work server))))))

(defun eglotx--enqueue-work (server function &rest arguments)
  "Append FUNCTION and ARGUMENTS to SERVER's constant-time work queue."
  (let ((cell (list (cons function arguments))))
    (if-let* ((tail (eglotx--work-tail server)))
        (setcdr tail cell)
      (setf (eglotx--work-head server) cell))
    (setf (eglotx--work-tail server) cell)
    (unless (eglotx--work-timer server)
      (setf (eglotx--work-timer server)
            (run-at-time 0 nil #'eglotx--drain-work server)))))

(defun eglotx--enqueue-urgent-work (server function &rest arguments)
  "Prepend urgent FUNCTION and ARGUMENTS to SERVER's work queue."
  (let ((cell (list (cons function arguments))))
    (setcdr cell (eglotx--work-head server))
    (setf (eglotx--work-head server) cell)
    (unless (eglotx--work-tail server)
      (setf (eglotx--work-tail server) cell))
    (unless (eglotx--work-timer server)
      (setf (eglotx--work-timer server)
            (run-at-time 0 nil #'eglotx--drain-work server)))))

(defun eglotx--enqueue-yielding-urgent-work (server function &rest arguments)
  "Prepend urgent work and yield SERVER's current drain before running it.
Outside deferred work this behaves like `eglotx--enqueue-urgent-work'."
  (apply #'eglotx--enqueue-urgent-work server function arguments)
  (when eglotx--in-deferred-work
    (setq eglotx--deferred-work-yield-p t)))

(defun eglotx--cleanup-uncommitted-backend
    (connection process connection-name preexisting-buffers)
  "Release an uncommitted backend CONNECTION or raw PROCESS.
CONNECTION-NAME and PREEXISTING-BUFFERS identify resources allocated during
this constructor without matching buffers owned by similarly named siblings."
  (when connection
    (condition-case nil
        (jsonrpc-shutdown connection t)
      (error nil)
      (quit nil))
    (ignore-errors (eglotx--cleanup-child-buffers connection)))
  (when (processp process)
    (ignore-errors (set-process-sentinel process #'ignore))
    (ignore-errors (delete-process process))
    (eglotx--discard-process-buffer (process-buffer process)))
  ;; A jsonrpc constructor can allocate its hidden buffers and then exit
  ;; before returning a connection object.  Clean the exact, newly created
  ;; objects rather than scanning by a shared connection-name prefix.
  (eglotx--cleanup-new-connection-buffers
   connection-name preexisting-buffers))

(defun eglotx--start-backend (server backend)
  "Start BACKEND and attach it to SERVER."
  (let ((name (format "%s/%s" (jsonrpc-name server)
                      (eglotx--backend-name backend)))
        process connection committed preexisting-buffers)
    (setq preexisting-buffers
          (eglotx--existing-connection-buffers name))
    (setf (eglotx--backend-state backend) 'starting)
    (unwind-protect
        (condition-case err
            (progn
              (setq connection
                    (apply
                     #'make-instance 'eglotx--child-connection
                     :name name
                     :process
                     (lambda ()
                       ;; Retain ownership while jsonrpc installs filters,
                       ;; sentinels, buffers, and its connection wrapper.
                       (setq process
                             (eglotx--backend-process server backend name)))
                     :request-dispatcher
                     (lambda (child method params)
                       (eglotx--dispatch-backend-request
                        server backend child method params))
                     :notification-dispatcher
                     (lambda (child method params)
                       (eglotx--handle-backend-notification
                        server backend child method params))
                     :on-shutdown
                     (lambda (child)
                       (clrhash
                        (eglotx--child-active-inbound-requests child))
                       (jsonrpc-forget-pending-continuations child)
                       (eglotx--backend-stopped server backend))
                     (eglotx--backend-event-initargs)))
              (setf (eglotx--backend-connection backend) connection
                    (eglotx--backend-state backend) 'running
                    committed t))
          (error
           (setf (eglotx--backend-state backend) 'failed
                 (eglotx--backend-last-error backend)
                 (error-message-string err))
           (if (eglotx--backend-required backend)
               (signal (car err) (cdr err))
             (display-warning
              'eglotx
              (format "Optional backend %s failed to start: %s"
                      (eglotx--backend-name backend)
                      (error-message-string err))
              :warning))))
      (unless committed
        (let ((inhibit-quit t))
          (setf (eglotx--backend-connection backend) nil)
          (eglotx--cleanup-uncommitted-backend
           connection process name preexisting-buffers))))))

(defun eglotx--backend-running-p (backend)
  "Return non-nil when BACKEND can receive messages."
  (and (memq (eglotx--backend-state backend) '(running ready))
       (let ((connection (eglotx--backend-connection backend)))
         (and connection (jsonrpc-running-p connection)))))

(defun eglotx--fail-backend-request-legs (server backend message)
  "Complete every pending SERVER request leg for BACKEND with MESSAGE."
  (dolist (request (hash-table-values (eglotx--requests server)))
    (when (gethash backend (eglotx--request-pending request))
      (eglotx--record-response
       server (eglotx--request-id request) backend nil
       (list :code -32097 :message message)))))

(defun eglotx--backend-stopped (server backend)
  "Record that BACKEND stopped and update SERVER health."
  (let ((unexpected-p
         (not (memq (eglotx--backend-state backend) '(stopped failed)))))
    (when unexpected-p
      (setf (eglotx--backend-state backend)
            (if (memq (eglotx--state server) '(stopping dead))
                'stopped
              'failed)
            (eglotx--backend-last-error backend)
            (unless (memq (eglotx--state server) '(stopping dead))
              "Backend process exited")))
    (eglotx--backend-stopped-direct-requests server backend)
    ;; Initialization rejection pre-marks the backend failed.  Its request
    ;; finalizer must deliver the parent error before shutting down siblings;
    ;; only an otherwise unexpected process exit enters this crash path.
    (when (and unexpected-p
               (eglotx--backend-required backend)
               (not (memq (eglotx--state server) '(stopping dead failed))))
      (setf (eglotx--state server) 'failed)
      (display-warning
       'eglotx
       (format "Required backend %s exited; closing facade"
               (eglotx--backend-name backend))
       :error)
      (eglotx--enqueue-urgent-work
       server
       (lambda (facade)
         (unless (eq (eglotx--state facade) 'dead)
           (jsonrpc-shutdown facade t)))
       server))
    (when (and (not (eglotx--backend-required backend))
               (eq (eglotx--backend-state backend) 'failed)
               (not (memq (eglotx--state server) '(stopping dead failed))))
      (eglotx--fail-backend-request-legs
       server backend
       (format "Optional backend %s exited"
               (eglotx--backend-name backend)))
      (eglotx--enqueue-work
       server #'eglotx--cleanup-failed-backend server backend))))

(defun eglotx--cleanup-child-buffers (connection)
  "Release hidden transport, event, and stderr buffers owned by CONNECTION."
  (let ((events (ignore-errors (jsonrpc--events-buffer connection)))
        (stderr (ignore-errors (jsonrpc-stderr-buffer connection)))
        (transport
         (ignore-errors (process-buffer (jsonrpc--process connection)))))
    (dolist (buffer
             (delete-dups (delq nil (list transport events stderr))))
      (eglotx--discard-process-buffer buffer))))

(defun eglotx--cleanup-failed-backend (server backend)
  "Withdraw BACKEND registrations and release its state from SERVER."
  (let* ((cursor-retired-p
          (eglotx--invalidate-backend-diagnostic-cursors server backend))
         (retirement
         (eglotx--backend-retirement-create
           :backend backend
           :push-seen (make-hash-table :test #'equal)
           :aggregate-seen (make-hash-table :test #'equal)
           :refresh-p
           (or cursor-retired-p
               (eglotx--backend-pull-diagnostics-p backend)))))
    (unwind-protect
        (progn
          ;; Outward cleanup is best effort.  Every internal ledger release and
          ;; diagnostic retirement below is protected from dispatcher failure.
          (maphash
           (lambda (child-token facade-token)
             (condition-case err
                 (eglotx--end-progress
                  server backend child-token facade-token)
               (error
                (display-warning
                 'eglotx
                 (format "Could not end progress for %s: %s"
                         (eglotx--backend-name backend)
                         (error-message-string err))
                 :warning))))
           (copy-hash-table (eglotx--backend-progress-active backend))))
      ;; No outward dispatcher can prevent source ownership from retiring.
      (unwind-protect
          (progn
            (dolist (table
                     (list
                      (eglotx--backend-registration-methods backend)
                      (eglotx--backend-static-capability-selectors backend)
                      (eglotx--backend-progress-forward backend)
                      (eglotx--backend-progress-reverse backend)
                      (eglotx--backend-progress-active backend)))
              (clrhash table))
            (eglotx--schedule-file-watch-rebuild server)
            (unless (memq (eglotx--state server) '(stopping dead failed))
              (condition-case err
                  (eglotx--recompute-facade-capabilities server)
                (error
                 (display-warning
                  'eglotx
                  (format "Could not recompute capabilities after %s failed: %s"
                          (eglotx--backend-name backend)
                          (error-message-string err))
                  :warning))))
            (when-let* ((connection (eglotx--backend-connection backend)))
              (eglotx--cleanup-child-buffers connection)))
        (eglotx--start-backend-diagnostic-retirement server retirement)))))

(defun eglotx--surviving-pull-backend-p (server)
  "Return non-nil when SERVER still has a running pull-diagnostic backend."
  (seq-some (lambda (candidate)
              (and (eglotx--backend-running-p candidate)
                   (eglotx--backend-pull-diagnostics-p candidate)))
            (eglotx--backends server)))

(defun eglotx--reset-eglot-pull-diagnostic-buffer
    (_server buffer surviving-pull-p)
  "Clear stale pull state in BUFFER and repull when SURVIVING-PULL-P."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq eglot--pulled-diagnostics nil)
      (ignore-errors
        (eglot--flymake-report-push+pulled :force t))
      (when (and surviving-pull-p
                 (bound-and-true-p flymake-mode))
        (ignore-errors (flymake-start nil t))))))

(defun eglotx--dispatch-failed-diagnostic-retractions
    (server tasks &optional propagate-errors-p)
  "Dispatch a bounded prefix of failed-backend diagnostic retraction TASKS.
When PROPAGATE-ERRORS-P, re-signal the first dispatcher error so the retirement
state can retain its uncommitted queue head and apply centralized retry and
warning policy."
  (when (not (memq (eglotx--state server) '(stopping dead)))
    (let ((remaining tasks)
          (count 0))
      (while (and remaining (< count eglotx-diagnostic-chunk-size))
        (let ((task (pop remaining)))
          (condition-case err
              (pcase task
                (`(project ,backend ,params)
                 (eglotx--project-diagnostic-snapshot
                  server backend params))
                (`(aggregate ,uri)
                 (eglotx--dispatch-aggregate-diagnostics
                  server (list :uri uri :diagnostics []))))
            (error
             (if propagate-errors-p
                 ;; The retirement state owns retry policy and warning
                 ;; throttling.  Re-signal without logging here so one failed
                 ;; attempt cannot produce both a helper and queue warning.
                 (signal (car err) (cdr err))
               (display-warning
                'eglotx
                (format "Could not retire %s diagnostics: %s"
                        (car-safe task) (error-message-string err))
                :warning)))))
        (cl-incf count))
      (when remaining
        (eglotx--enqueue-yielding-urgent-work
         server #'eglotx--dispatch-failed-diagnostic-retractions
         server remaining propagate-errors-p)))))

(defun eglotx--backend-retirement-enqueue-retraction (retirement task)
  "Append TASK to RETIREMENT's constant-time retraction queue."
  (let ((cell (list task)))
    (if-let* ((tail (eglotx--backend-retirement-retraction-tail retirement)))
        (setcdr tail cell)
      (setf (eglotx--backend-retirement-retraction-head retirement) cell))
    (setf (eglotx--backend-retirement-retraction-tail retirement) cell)))

(defun eglotx--backend-retirement-enqueue-aggregate
    (retirement uri)
  "Append one aggregate retraction for URI to RETIREMENT."
  (let ((seen (eglotx--backend-retirement-aggregate-seen retirement)))
    (unless (gethash uri seen)
      (puthash uri t seen)
      (eglotx--backend-retirement-enqueue-retraction
       retirement (list 'aggregate uri)))))

(defun eglotx--retire-failed-backend-owner (server retirement token)
  "Remove failed-backend owner TOKEN through its exact container indexes."
  (let* ((backend (eglotx--backend-retirement-backend retirement))
         (owner (gethash token (eglotx--owners server)))
         (batch (gethash token (eglotx--completion-batches server))))
    (cond
     ((and owner (eq backend (eglotx--owner-backend owner)))
      (eglotx--forget-owner-token server token))
     (batch
      (eglotx--retire-completion-batch-backend server batch backend))
     (t
      ;; A prior eviction can leave only the private index node.  Never remove
      ;; another backend's owner if an invariant was violated; just heal this
      ;; failed backend's exact ledger.
      (eglotx--ledger-remove
       (eglotx--backend-ledger backend 'owner) token)))))

(defun eglotx--retire-failed-backend-command (server retirement token)
  "Remove failed-backend command TOKEN through its exact indexes."
  (let* ((backend (eglotx--backend-retirement-backend retirement))
         (owner (gethash token (eglotx--command-owners server))))
    (if (and owner (eq backend (eglotx--owner-backend owner)))
        (eglotx--forget-command-owner-token server token)
      (eglotx--ledger-remove
       (eglotx--backend-ledger backend 'command) token))))

(defun eglotx--retire-failed-backend-diagnostic-key
    (server retirement key)
  "Remove KEY from SERVER and record RETIREMENT's later client retraction."
  (let* ((backend (eglotx--backend-retirement-backend retirement))
         (uri (cadr key))
         (modality (nth 2 key)))
    (condition-case err
        (cond
         ((eq modality 'push)
          (let ((seen (eglotx--backend-retirement-push-seen retirement)))
            (unless (gethash uri seen)
              (puthash uri t seen)
              (let* ((document (eglotx--document-for-uri server uri))
                     (params
                      (append
                       (list :uri uri :diagnostics [])
                       (when document
                         (list :version
                               (eglotx--document-version document))))))
                (if (eglotx--stream-diagnostics-for-uri-p server uri)
                    (eglotx--backend-retirement-enqueue-retraction
                     retirement (list 'project backend params))
                  (eglotx--backend-retirement-enqueue-aggregate
                   retirement uri))))))
         (t
          (setf (eglotx--backend-retirement-refresh-p retirement) t)
          (eglotx--invalidate-diagnostic-cursor server uri)))
      (error
       (display-warning
        'eglotx
        (format "Could not plan diagnostic retirement for %s: %s"
                uri (error-message-string err))
        :warning)))
    ;; Source storage is removed only after its outward effect was captured.
    ;; Retractions run in a later phase, when no failed-backend slot remains,
    ;; so an aggregate can never expose a half-retired source set.
    (if (eglotx--backend-retirement-ownership-cleaned-p retirement)
        ;; The owner phase already unlinked every token from its exact
        ;; document/orphan container.  Re-scanning a single source's
        ;; potentially huge token vector would make a nominal 64-key chunk
        ;; unbounded in wall time.
        (remhash key (eglotx--diagnostic-tokens server))
      ;; Exceptional fallback: ownership cleanup itself exited non-locally,
      ;; so release every still-live token before discarding the source.
      (eglotx--forget-diagnostic-token-key server key nil))
    (remhash key (eglotx--diagnostic-snapshots server))
    (remhash key (eglotx--diagnostic-version-watermarks server))
    (eglotx--ledger-remove
     (eglotx--backend-ledger backend 'diagnostic) key)))

(defun eglotx--reset-backend-diagnostic-retirement-retry (retirement)
  "Cancel and reset RETIREMENT's interrupted-work retry state."
  (when-let* ((timer (eglotx--backend-retirement-retry-timer retirement))
              ((timerp timer)))
    (cancel-timer timer))
  (setf (eglotx--backend-retirement-retry-timer retirement) nil
        (eglotx--backend-retirement-retry-count retirement) 0))

(defun eglotx--finalize-failed-backend-diagnostic-retirement
    (retirement)
  "Release RETIREMENT's remaining backend-local diagnostic indexes."
  (eglotx--reset-backend-diagnostic-retirement-retry retirement)
  (let ((backend (eglotx--backend-retirement-backend retirement)))
    (dolist (kind '(owner command diagnostic))
      (eglotx--ledger-clear (eglotx--backend-ledger backend kind)))
    (setf (eglotx--backend-retirement-phase retirement) 'done)))

(defun eglotx--schedule-backend-diagnostic-retirement (server retirement)
  "Continue RETIREMENT at the head of SERVER's next event-loop turn."
  (unless (memq (eglotx--state server) '(stopping dead))
    (eglotx--enqueue-yielding-urgent-work
     server #'eglotx--advance-backend-diagnostic-retirement
     server retirement)))

(defun eglotx--backend-retirement-retry-fired (server retirement)
  "Append a delayed RETIREMENT retry to SERVER's ordinary work queue."
  (setf (eglotx--backend-retirement-retry-timer retirement) nil)
  (unless (memq (eglotx--state server) '(stopping dead))
    ;; A failing client dispatcher must not monopolize the urgent queue.
    ;; Retractions are idempotent, so retaining the queue head while retrying
    ;; behind already-enqueued facade work preserves correctness and fairness.
    (eglotx--enqueue-work
     server #'eglotx--advance-backend-diagnostic-retirement
     server retirement)))

(defun eglotx--schedule-backend-diagnostic-retirement-retry
    (server retirement)
  "Retry interrupted RETIREMENT for SERVER with bounded exponential backoff."
  (unless (or (memq (eglotx--state server) '(stopping dead))
              (eglotx--backend-retirement-retry-timer retirement))
    (let* (;; Saturate the counter before exponentiation.  A permanently
            ;; broken dispatcher must have constant retry bookkeeping even
            ;; after running for an arbitrarily long session.
           (attempt
            (min 21
                 (1+ (eglotx--backend-retirement-retry-count retirement))))
           (delay
            (min eglotx--retirement-retry-max-delay
                 (* eglotx--retirement-retry-base-delay
                    (expt 2 (1- attempt))))))
      (setf (eglotx--backend-retirement-retry-count retirement) attempt
            (eglotx--backend-retirement-retry-timer retirement)
            (run-at-time
             delay nil #'eglotx--backend-retirement-retry-fired
             server retirement)))))

(defun eglotx--warn-backend-diagnostic-retirement-error (retirement err)
  "Report RETIREMENT failure ERR at exponentially sparse retry milestones."
  (let ((attempt (eglotx--backend-retirement-retry-count retirement)))
    ;; Persistent deterministic errors must remain visible without growing
    ;; `*Warnings*' once per second forever.  Since the retry counter itself
    ;; saturates, this emits at most five warnings between successful chunks.
    (when (and (> attempt 0)
               (= (logand attempt (1- attempt)) 0))
      (let ((backend (eglotx--backend-retirement-backend retirement)))
        (display-warning
         'eglotx
         (format "Diagnostic retirement for %s failed on attempt %d: %s"
                 (if backend (eglotx--backend-name backend) "unknown backend")
                 attempt (error-message-string err))
         :warning)))))

(defun eglotx--retire-backend-ledger-chunk
    (server retirement kind releaser)
  "Retire one bounded KIND ledger chunk with RELEASER.
Return non-nil when the ledger is empty."
  (let* ((backend (eglotx--backend-retirement-backend retirement))
         (ledger (eglotx--backend-ledger backend kind))
         (remaining eglotx-diagnostic-chunk-size)
         key)
    (while (and (> remaining 0) (setq key (eglotx--ledger-peek ledger)))
      (funcall releaser server retirement key)
      (cl-decf remaining))
    (null (eglotx--ledger-peek ledger))))

(defun eglotx--advance-backend-diagnostic-retirement (server retirement)
  "Advance one bounded phase chunk of failed-backend RETIREMENT."
  (unless (memq (eglotx--state server) '(stopping dead))
    (let ((completed nil) reschedule-p)
      (condition-case err
          (unwind-protect
              (progn
                (pcase (eglotx--backend-retirement-phase retirement)
                  ('owners
                   (when (eglotx--retire-backend-ledger-chunk
                          server retirement 'owner
                          #'eglotx--retire-failed-backend-owner)
                     (setf
                      (eglotx--backend-retirement-ownership-cleaned-p retirement)
                      t
                      (eglotx--backend-retirement-phase retirement) 'commands))
                   (setq reschedule-p t))
                  ('commands
                   (when (eglotx--retire-backend-ledger-chunk
                          server retirement 'command
                          #'eglotx--retire-failed-backend-command)
                     (setf (eglotx--backend-retirement-phase retirement)
                           'remove))
                   (setq reschedule-p t))
                  ('remove
                   (when (eglotx--retire-backend-ledger-chunk
                          server retirement 'diagnostic
                          #'eglotx--retire-failed-backend-diagnostic-key)
                     (setf (eglotx--backend-retirement-phase retirement)
                           'retract))
                   (setq reschedule-p t))
                  ('retract
                   (let ((remaining eglotx-diagnostic-chunk-size))
                     (while (and (> remaining 0)
                                 (eglotx--backend-retirement-retraction-head
                                  retirement))
                       (let* ((head
                               (eglotx--backend-retirement-retraction-head
                                retirement))
                              (task (car head)))
                         (eglotx--dispatch-failed-diagnostic-retractions
                          server (list task) t)
                         ;; Commit only after the dispatcher returns.  A non-local
                         ;; exit retries an idempotent empty retraction next turn
                         ;; instead of losing it and leaving stale client state.
                         (setf
                          (eglotx--backend-retirement-retraction-head retirement)
                          (cdr head))
                         (unless
                             (eglotx--backend-retirement-retraction-head retirement)
                           (setf
                            (eglotx--backend-retirement-retraction-tail retirement)
                            nil)))
                       (cl-decf remaining))
                     (unless
                         (eglotx--backend-retirement-retraction-head retirement)
                       (if (eglotx--backend-retirement-refresh-p retirement)
                           (setf
                            (eglotx--backend-retirement-reset-buffers retirement)
                            (ignore-errors (eglot--managed-buffers server))
                            (eglotx--backend-retirement-surviving-pull-p retirement)
                            (eglotx--surviving-pull-backend-p server)
                            (eglotx--backend-retirement-phase retirement) 'reset)
                         (setf (eglotx--backend-retirement-phase retirement)
                               'finalize)))
                     (setq reschedule-p t)))
                  ('reset
                   (let ((remaining eglotx-diagnostic-chunk-size))
                     (while (and
                             (> remaining 0)
                             (eglotx--backend-retirement-reset-buffers retirement))
                       (let ((buffer
                              (car
                               (eglotx--backend-retirement-reset-buffers
                                retirement))))
                         (eglotx--reset-eglot-pull-diagnostic-buffer
                          server buffer
                          (eglotx--backend-retirement-surviving-pull-p retirement))
                         (setf
                          (eglotx--backend-retirement-reset-buffers retirement)
                          (cdr
                           (eglotx--backend-retirement-reset-buffers retirement))))
                       (cl-decf remaining))
                     (unless
                         (eglotx--backend-retirement-reset-buffers retirement)
                       (setf (eglotx--backend-retirement-phase retirement)
                             'finalize))
                     (setq reschedule-p t)))
                  ('finalize
                   (let* ((backend
                           (eglotx--backend-retirement-backend retirement))
                          (owner
                           (eglotx--ledger-peek
                            (eglotx--backend-ledger backend 'owner)))
                          (command
                           (eglotx--ledger-peek
                            (eglotx--backend-ledger backend 'command)))
                          (diagnostic
                           (eglotx--ledger-peek
                            (eglotx--backend-ledger backend 'diagnostic))))
                     (if (or owner command diagnostic)
                         (progn
                           ;; A reentrant/internal late writer is drained
                           ;; instead of being silently orphaned.
                           (setf
                            (eglotx--backend-retirement-ownership-cleaned-p
                             retirement)
                            (null owner)
                            (eglotx--backend-retirement-phase retirement)
                            (cond (owner 'owners)
                                  (command 'commands)
                                  (t 'remove)))
                           (setq reschedule-p t))
                       (eglotx--finalize-failed-backend-diagnostic-retirement
                        retirement))))
                  ('done))
                ;; Any completed chunk is forward progress.  A later failure gets
                ;; a fresh short retry instead of inheriting an obsolete penalty.
                (eglotx--reset-backend-diagnostic-retirement-retry retirement)
                (setq completed t))
            ;; A client dispatcher can throw non-locally.  Retraction/reset
            ;; tasks are only unlinked after return, so the same idempotent
            ;; action is retried and later sources are never stranded.
            (unless completed
              (eglotx--schedule-backend-diagnostic-retirement-retry
               server retirement)))
        (error
         ;; Swallow after scheduling: `eglotx--drain-work' must not emit a
         ;; duplicate warning, and can immediately continue ordinary FIFO
         ;; work.  Non-error throws still cross this boundary after the unwind.
         (eglotx--warn-backend-diagnostic-retirement-error retirement err)))
      (when (and completed reschedule-p)
        (eglotx--schedule-backend-diagnostic-retirement server retirement)))))

(defun eglotx--start-backend-diagnostic-retirement (server retirement)
  "Start failed-backend diagnostic RETIREMENT for SERVER."
  (eglotx--schedule-backend-diagnostic-retirement server retirement))

(defun eglotx--close-backends (server cleanup &optional force)
  "Close every backend owned by SERVER.
When CLEANUP is non-nil, also remove their JSON-RPC buffers.  FORCE deletes
live processes before waiting and is reserved for unrecoverable failures."
  (dolist (backend (eglotx--backends server))
    (when-let* ((connection (eglotx--backend-connection backend)))
      (when (and force
                 (process-live-p (jsonrpc--process connection)))
        (delete-process (jsonrpc--process connection)))
      (ignore-errors (jsonrpc-shutdown connection cleanup))
      (when cleanup
        (eglotx--cleanup-child-buffers connection)))
    (setf (eglotx--backend-state backend) 'stopped)))

(defun eglotx--status-snapshot (server)
  "Return a read-only status snapshot for SERVER."
  (list
   :state (eglotx--state server)
   :pendingRequests (hash-table-count (eglotx--requests server))
   :pendingBridgeRequests (hash-table-count (eglotx--direct-requests server))
   :bridgeRequests (eglotx--direct-request-total server)
   :documents (hash-table-count (eglotx--documents server))
   :backends
   (vconcat
    (mapcar
     (lambda (backend)
       (list :name (eglotx--backend-name backend)
             :state (eglotx--backend-state backend)
             :priority (eglotx--backend-priority backend)
             :languages (mapcar #'copy-sequence
                                (eglotx--backend-languages backend))
             :required (if (eglotx--backend-required backend) t :json-false)
             :running (if (eglotx--backend-running-p backend) t :json-false)
             :serverInfo (copy-tree (eglotx--backend-server-info backend))
             :lastError (eglotx--backend-last-error backend)))
     (eglotx--backends server)))))

;;;###autoload
(defun eglotx-status (&optional server)
  "Return or display the health of Eglotx SERVER.

When called interactively, use the current Eglot server and display a compact
status buffer.  Lisp callers receive a read-only plist snapshot with facade
`:state', request and document counters, and a `:backends' vector.  Each backend
entry contains its name, state, priority, languages, required/running flags,
server information, and last error.  Reading status sends no protocol
messages."
  (interactive)
  (setq server (or server (eglot-current-server)))
  (unless (and server (object-of-class-p server 'eglotx-server))
    (user-error "Current Eglot server is not managed by Eglotx"))
  (let ((snapshot (eglotx--status-snapshot server)))
    (if (called-interactively-p 'interactive)
        (with-current-buffer (get-buffer-create "*eglotx status*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Eglotx: %s\n\n" (plist-get snapshot :state)))
            (insert
             (format
              "Pending requests: %d\nBridge requests: %d pending, %d total\nOpen documents: %d\n\n"
              (plist-get snapshot :pendingRequests)
              (plist-get snapshot :pendingBridgeRequests)
              (plist-get snapshot :bridgeRequests)
              (plist-get snapshot :documents)))
            (seq-doseq (backend (plist-get snapshot :backends))
              (insert (format "%-24s %-10s priority=%s required=%s languages=%s%s\n"
                              (plist-get backend :name)
                              (plist-get backend :state)
                              (plist-get backend :priority)
                              (eq (plist-get backend :required) t)
                              (if-let* ((languages
                                         (plist-get backend :languages)))
                                  (string-join languages ",")
                                "*")
                              (if-let* ((error (plist-get backend :lastError)))
                                  (format "  %s" error)
                                ""))))
            (special-mode))
          (display-buffer (current-buffer)))
      snapshot)))

;; Runtime.

(defun eglotx--policy (method)
  "Return the built-in policy for METHOD."
  (or (gethash (eglotx--method-key method) eglotx--method-policy-table)
      '(:route primary :merge first)))

(defun eglotx--json-false-p (value)
  "Return non-nil when VALUE is a JSON false-like provider value."
  (or (null value) (eq value :json-false)))

(defun eglotx--semantic-option-enabled-p (provider option)
  "Return whether semantic PROVIDER explicitly enables OPTION.
Nil is enabled when the field is present because jsonrpc.el represents a
legal empty SemanticTokensOptions object as nil."
  (and (listp provider)
       (plist-member provider option)
       (not (eq (plist-get provider option) :json-false))))

(defun eglotx--backend-allows-p (backend method)
  "Return non-nil if BACKEND's explicit method filter permits METHOD."
  (let ((only (eglotx--backend-only backend))
        (key (eglotx--method-key method)))
    (or (null only)
        (memq key eglotx--lifecycle-methods)
        (and (listp only) (memq key only)))))

(defun eglotx--document-method-p (method)
  "Return non-nil when METHOD carries or owns one text document."
  (let* ((key (eglotx--method-key method))
         (name (symbol-name key)))
    (or (string-prefix-p ":textDocument/" name)
        (memq key
              '(:completionItem/resolve :codeAction/resolve
                :codeLens/resolve :documentLink/resolve
                :inlayHint/resolve :workspaceSymbol/resolve
                :callHierarchy/incomingCalls
                :callHierarchy/outgoingCalls
                :typeHierarchy/supertypes :typeHierarchy/subtypes)))))

(defun eglotx--document-language (server method params)
  "Return the language ID for document METHOD and PARAMS on SERVER.
Return `eglotx--unknown-document-language' when METHOD is document-scoped but
the document has not supplied a language ID, and nil for non-document traffic."
  (when (eglotx--document-method-p method)
    (let* ((text-document (and (listp params)
                               (plist-get params :textDocument)))
           (wire-language (and (listp text-document)
                               (plist-get text-document :languageId)))
           (uri (and (listp params)
                     (or (eglotx--params-uri params)
                         (when-let* ((owner
                                      (eglotx--owner-for-params server params)))
                           (eglotx--owner-uri owner)))))
           (document (and uri (eglotx--document-for-uri server uri)))
           (language (or wire-language
                         (and document
                              (eglotx--document-language-id document)))))
      (if (stringp language)
          language
        eglotx--unknown-document-language))))

(defun eglotx--backend-accepts-params-p (server backend method params)
  "Return non-nil when BACKEND accepts METHOD PARAMS through SERVER."
  (let ((languages (eglotx--backend-languages backend)))
    (or (null languages)
        (let ((language (eglotx--document-language server method params)))
          (cond
           ((null language) t)
           ((stringp language)
            (gethash language (eglotx--backend-language-table backend)))
           (t
            ;; An owned resolve item can name an unopened workspace document.
            ;; Its originating backend remains the only safe target even
            ;; though the facade has no language ID for that URI.
            (when-let* ((owner (and (listp params)
                                    (eglotx--owner-for-params server params))))
              (eq backend (eglotx--owner-backend owner)))))))))

(defun eglotx--backend-accepts-language-p (backend language)
  "Return non-nil when BACKEND accepts LSP LANGUAGE."
  (let ((languages (eglotx--backend-languages backend)))
    (or (null languages)
        (and (stringp language)
             (gethash language
                      (eglotx--backend-language-table backend))))))

(defun eglotx--workspace-method-option (workspace method)
  "Return WORKSPACE's valid static option for METHOD, or nil."
  (let ((key (eglotx--method-key method)))
    (cond
     ((eq key :workspace/didChangeWorkspaceFolders)
      (let ((folders (and (listp workspace)
                          (plist-get workspace :workspaceFolders))))
        (and (listp folders)
             (not (eglotx--json-false-p (plist-get folders :supported)))
             (not (eglotx--json-false-p
                   (plist-get folders :changeNotifications)))
             t)))
     ((alist-get key eglotx--workspace-file-operation-methods)
      (let* ((operations (and (listp workspace)
                              (plist-get workspace :fileOperations)))
             (operation
              (and (listp operations)
                   (plist-get
                    operations
                    (alist-get key eglotx--workspace-file-operation-methods)))))
        (and (eglotx--json-object-p operation)
             (let ((filters (plist-get operation :filters)))
               (and (or (vectorp filters) (proper-list-p filters))
                    (> (length filters) 0)))
             operation)))
     (t (and (not (eglotx--json-false-p workspace)) workspace)))))

(defun eglotx--backend-static-selector-matches-p
    (server backend capability params)
  "Return whether BACKEND static CAPABILITY selector admits PARAMS on SERVER."
  (let ((selector
         (gethash capability
                  (eglotx--backend-static-capability-selectors backend)
                  eglotx--missing-value)))
    (or (eq selector eglotx--missing-value)
        (null server)
        ;; Global refresh and workspace requests legitimately omit one URI;
        ;; their provider contribution remains active for its selected domain.
        (null (eglotx--params-uri params))
        (eglotx--document-selector-matches-p server selector params))))

(defun eglotx--backend-capable-p
    (backend method capability &optional server params)
  "Return non-nil when BACKEND handles METHOD through CAPABILITY.
SERVER and PARAMS enable initialize-time document-selector filtering."
  (let ((key (eglotx--method-key method)))
    (or (null capability)
      (let* ((capabilities (eglotx--backend-capabilities backend))
             (present (plist-member capabilities capability))
             (value (plist-get capabilities capability)))
        (and
         present
         (not (eq value :json-false))
         (eglotx--backend-static-selector-matches-p
          server backend capability params)
         (pcase key
           ((or :workspace/didChangeWorkspaceFolders
                :workspace/willCreateFiles :workspace/didCreateFiles
                :workspace/willRenameFiles :workspace/didRenameFiles
                :workspace/willDeleteFiles :workspace/didDeleteFiles)
            (eglotx--workspace-method-option value method))
           (:textDocument/willSaveWaitUntil
            (and (listp value)
                 (not (eglotx--json-false-p
                       (plist-get value :willSaveWaitUntil)))))
           (:textDocument/semanticTokens/full
            (eglotx--semantic-option-enabled-p value :full))
           (:textDocument/semanticTokens/full/delta
            (let ((full (and (listp value) (plist-get value :full))))
              (and (listp full)
                   (plist-member full :delta)
                   (not (eq (plist-get full :delta) :json-false)))))
           (:textDocument/semanticTokens/range
            (eglotx--semantic-option-enabled-p value :range))
           (_
            (if (plist-get (eglotx--policy method) :resolve)
                (and (listp value)
                     (not (eglotx--json-false-p
                           (plist-get value :resolveProvider))))
              t))))))))

(defun eglotx--trigger-character-request-p (params)
  "Return non-nil when PARAMS represents a trigger-character request."
  (let ((context (and (listp params) (plist-get params :context))))
    (and (listp context)
         (equal (plist-get context :triggerKind) 2)
         (stringp (plist-get context :triggerCharacter)))))

(defun eglotx--backend-handles-trigger-p
    (_server backend _method capability params)
  "Return whether BACKEND on SERVER handles PARAMS for METHOD/CAPABILITY."
  (if (not (eglotx--trigger-character-request-p params))
      t
    (let* ((character (plist-get (plist-get params :context)
                                 :triggerCharacter))
           (static (plist-get (eglotx--backend-capabilities backend)
                              capability)))
      (and (listp static)
           (member character
                   (eglotx--sequence-list
                    (plist-get static :triggerCharacters)))))))

(defun eglotx--available-backends
    (server method &optional capability params)
  "Return SERVER backends available for METHOD, CAPABILITY, and PARAMS."
  (cl-loop for backend in (eglotx--backends server)
           when (and (eglotx--backend-running-p backend)
                     (eglotx--backend-allows-p backend method)
                     (eglotx--backend-accepts-params-p
                      server backend method params)
                     (eglotx--backend-capable-p
                      backend method capability server params)
                     (or (not (memq (eglotx--method-key method)
                                    '(:textDocument/completion
                                      :textDocument/signatureHelp)))
                         (eglotx--backend-handles-trigger-p
                          server backend method capability params)))
           collect backend))

(defun eglotx--owner-token-in (value)
  "Find an Eglotx ownership token in JSON VALUE's request shape."
  (when (listp value)
    (or (plist-get value :data)
        (when-let* ((item (plist-get value :item)))
          (eglotx--owner-token-in item))
        (when-let* ((callee (plist-get value :callee)))
          (eglotx--owner-token-in callee))
        (when-let* ((caller (plist-get value :caller)))
          (eglotx--owner-token-in caller)))))

(defun eglotx--owner-for-params (server params)
  "Return the ownership record for PARAMS in SERVER, if any."
  (when-let* ((token (eglotx--owner-token-in params)))
    (when-let* ((owner (eglotx--owner-for-token server token))
                ((eglotx--owner-current-p server owner)))
      owner)))

(defun eglotx--decimal-suffix-p (string start)
  "Return non-nil when STRING from START is a non-empty decimal integer."
  (let ((index start)
        (length (length string))
        (valid (< start (length string))))
    (while (and valid (< index length))
      (let ((character (aref string index)))
        (unless (and (>= character ?0) (<= character ?9))
          (setq valid nil)))
      (cl-incf index))
    valid))

(defun eglotx--completion-token (prefix batch index)
  "Return an opaque PREFIX token leasing BATCH location INDEX.

The facade and Eglot exchange decoded Lisp objects directly.  A private text
property can therefore keep the compact batch reachable while a completion UI
retains the token; after the last lease disappears, a later GC can reclaim the
cycle.  The token remains an ordinary JSON string on every child transport.
The bounded batch table remains the fallback for clients which copy strings
without their properties."
  (let ((token (concat prefix (number-to-string index))))
    (put-text-property
     0 (length token) 'eglotx--completion-lease batch token)
    token))

(defun eglotx--completion-batch-location (server token)
  "Return (BATCH . INDEX) encoded by TOKEN in SERVER, or nil.
Parsing happens only on later resolve requests, never while merging a result."
  (when (and (stringp token) (<= (length token) 256))
    (let* ((namespace (format "eglotx:%s:batch:"
                              (eglotx--session-id server)))
           (start (length namespace)))
      (when (string-prefix-p namespace token)
        (when-let* ((separator (string-search ":" token start))
                    (index-start (1+ separator))
                    ((not (string-search ":" token index-start)))
                    ((eglotx--decimal-suffix-p token index-start))
                    (prefix (substring token 0 index-start))
                    (index (string-to-number
                            (substring token index-start))))
          (let* ((lease (get-text-property
                         0 'eglotx--completion-lease token))
                 (leased-batch
                  (and (eglotx--completion-batch-p lease)
                       (equal prefix
                              (eglotx--completion-batch-prefix lease))
                       lease))
                 (batch (or leased-batch
                            (gethash
                             prefix
                             (eglotx--completion-batches server))))
                 (source-document
                  (and batch (eglotx--completion-batch-document batch))))
            (when (and batch
                       (eq source-document
                           (eglotx--document-for-uri
                            server (eglotx--completion-batch-uri batch)))
                       (< index
                          (+ (eglotx--completion-batch-size batch)
                             (length
                              (eglotx--completion-batch-segments batch)))))
              (cons batch index))))))))

(defun eglotx--completion-segment-at (batch index)
  "Return BATCH's live backend segment containing item INDEX."
  (seq-find
   (lambda (candidate)
     (and (eglotx--completion-segment-backend candidate)
          (<= (eglotx--completion-segment-start candidate) index)
          (< index (eglotx--completion-segment-end candidate))))
   (eglotx--completion-batch-segments batch)))

(defun eglotx--completion-shared-index-p (batch index)
  "Return non-nil when BATCH INDEX identifies a shared segment handle."
  (>= index (eglotx--completion-batch-size batch)))

(defun eglotx--completion-segment-for-location (batch index)
  "Return BATCH segment represented by completion token INDEX."
  (if (eglotx--completion-shared-index-p batch index)
      (nth (- index (eglotx--completion-batch-size batch))
           (eglotx--completion-batch-segments batch))
    (eglotx--completion-segment-at batch index)))

(defun eglotx--completion-owner-at (batch index)
  "Return BATCH ownership materialized for item INDEX, or nil."
  (let* ((shared-p (eglotx--completion-shared-index-p batch index))
         (segment (eglotx--completion-segment-for-location batch index)))
    (when-let* ((segment segment)
                (backend (eglotx--completion-segment-backend segment))
                ((memq (eglotx--backend-state backend) '(running ready))))
      (let* ((overrides (and (not shared-p)
                             (eglotx--completion-segment-data segment)))
             (override (and overrides
                            (aref overrides
                                  (- index
                                     (eglotx--completion-segment-start
                                      segment)))))
             (data (if (and overrides
                            (not (eq override eglotx--missing-value)))
                       override
                     (eglotx--completion-segment-default-data segment))))
        (eglotx--owner-create
         :backend backend
         :kind 'completion
         :data (unless (eq data eglotx--missing-value) data)
         :data-present-p (not (eq data eglotx--missing-value))
         :uri (eglotx--completion-batch-uri batch)
         :generation (eglotx--completion-batch-generation batch))))))

(defun eglotx--owner-for-token (server token)
  "Return TOKEN's ordinary or compact completion owner in SERVER."
  (or (gethash token (eglotx--owners server))
      (when-let* ((location
                   (eglotx--completion-batch-location server token)))
        (eglotx--completion-owner-at (car location) (cdr location)))))

(defun eglotx--owner-current-p (server owner)
  "Return non-nil when OWNER is usable in SERVER's current document state.

Completion items are intentionally reusable across document generations: LSP
does not version them, and Eglot keeps one CAPF response while the user extends
its prefix.  The resolve request itself still snapshots the current generation
and rejects a document change that occurs while that request is in flight."
  (when owner
    (let ((generation (eglotx--owner-generation owner)))
      (or (eq (eglotx--owner-kind owner) 'completion)
          (null generation)
          (when-let* ((uri (eglotx--owner-uri owner))
                      (document (eglotx--document-for-uri server uri)))
            (= generation (eglotx--document-generation document)))))))

(defun eglotx--completion-with-edit-range
    (item edit-range &optional fallback copy)
  "Materialize EDIT-RANGE into completion ITEM.

FALLBACK is the selected item sent in the resolve request.  It keeps the
single materialized edit available if the compact completion batch is evicted
while resolve is in flight.  Use optional shallow COPY as the destination."
  (let* ((copy (or copy (copy-sequence item)))
         (fallback-edit (and (listp fallback)
                             (plist-get fallback :textEdit)))
         (new-text
          (or (plist-get item :textEditText)
              (and fallback-edit (plist-get fallback-edit :newText))
              (and (listp fallback)
                   (plist-get fallback :textEditText))
              ;; CompletionList editRange defaults use textEditText or label;
              ;; CompletionItem.insertText is a separate insertion mechanism.
              (plist-get item :label)
              (and (listp fallback) (plist-get fallback :label))))
         (edit
          (cond
           ((plist-member item :textEdit) (plist-get item :textEdit))
           (fallback-edit
            (let ((fallback-copy (copy-sequence fallback-edit)))
              (if new-text
                  (plist-put fallback-copy :newText new-text)
                fallback-copy)))
           ((and edit-range (plist-member edit-range :insert))
            (list :newText new-text
                  :insert (plist-get edit-range :insert)
                  :replace (plist-get edit-range :replace)))
           (edit-range (list :newText new-text :range edit-range)))))
    (when edit
      (setq copy (plist-put copy :textEdit edit)))
    (when (plist-member copy :textEditText)
      ;; `textEditText' is scoped to CompletionList itemDefaults and becomes
      ;; redundant once the selected item carries its concrete edit.
      (cl-remf copy :textEditText))
    copy))

(defun eglotx--materialize-completion-item (server item &optional fallback)
  "Materialize SERVER defaults for one selected completion ITEM.

FALLBACK is normally the already-materialized resolve request.  It makes
resolve completion independent from bounded batch retention without retaining
another copy of every completion item."
  (if (not (listp item))
      item
    (let* ((token (or (eglotx--owner-token-in item)
                      (and (listp fallback)
                           (eglotx--owner-token-in fallback))))
           (location (and token
                          (eglotx--completion-batch-location server token)))
           (batch (car-safe location))
           (index (cdr-safe location))
           (segment (and batch
                         (eglotx--completion-segment-for-location
                          batch index)))
           (owner (and batch (eglotx--completion-owner-at batch index)))
           (range (and segment
                       (eglotx--completion-segment-default-edit-range
                        segment))))
      (if (or (and fallback (plist-member fallback :textEdit))
              (and owner
                   (eglotx--owner-current-p server owner)
                   (not (eq range eglotx--missing-value))))
          (eglotx--completion-with-edit-range
           item
           (unless (eq range eglotx--missing-value) range)
           fallback)
        item))))

(defun eglotx--session-token-p (server value)
  "Return non-nil when VALUE belongs to SERVER's private namespace."
  (and (stringp value)
       (string-prefix-p (format "eglotx:%s:" (eglotx--session-id server))
                        value)))

(defun eglotx--command-target (server params)
  "Return command owner for PARAMS in SERVER, if known."
  (when-let* ((command (plist-get params :command)))
    (or (when-let* ((owner (gethash command (eglotx--command-owners server))))
          (eglotx--owner-backend owner))
        (car (gethash command (eglotx--command-providers server))))))

(defun eglotx--select-request-targets (server method params policy)
  "Select SERVER targets for METHOD, PARAMS, and POLICY."
  (let* ((route (plist-get policy :route))
         (capability (plist-get policy :capability))
         (available
          (eglotx--available-backends server method capability params)))
    (pcase route
      ('all (eglotx--available-backends server method nil params))
      ('collect available)
      ('exclusive
       (if (not (eglotx--stateful-singleton-method-p method))
           (and available (list (car available)))
         (let* ((table (eglotx--singleton-providers server))
                (missing 'eglotx--missing)
                (pinned (gethash method table missing)))
           (cond
            ((eq pinned missing)
             (when (and available
                        (not (alist-get
                              (eglotx--method-key method)
                              eglotx--workspace-file-operation-methods)))
               (puthash method (car available) table)
               (list (car available))))
            ((memq pinned available) (list pinned))))))
      ('owner
       (let* ((token (and (listp params) (eglotx--owner-token-in params)))
              (owner (and token (eglotx--owner-for-params server params)))
              (backend (and owner (eglotx--owner-backend owner))))
         (cond ((and backend (memq backend available)) (list backend))
               ((eglotx--session-token-p server token) nil)
               (available (list (car available))))))
      ('command
       (let* ((command (and (listp params) (plist-get params :command)))
              (backend (and command
                            (eglotx--command-target server params))))
         (cond ((and backend (memq backend available)) (list backend))
               ((eglotx--session-token-p server command) nil)
               (available (list (car available))))))
      (_ (and available (list (car available)))))))

(defun eglotx--request-timeout (method targets)
  "Return facade timeout for METHOD over TARGETS."
  (if (eq (eglotx--method-key method) :shutdown)
      1.0
    (let ((timeouts (mapcar #'eglotx--backend-request-timeout targets)))
      ;; One unbounded child makes the aggregate deadline unbounded too;
      ;; otherwise the facade could cancel that leg before its own contract.
      (and (not (memq nil timeouts))
           (if timeouts (apply #'max timeouts) eglotx-request-timeout)))))

(defun eglotx--async-request (connection method params &rest args)
  "Send METHOD with PARAMS through CONNECTION and return its numeric ID.

Pass ARGS to `jsonrpc-async-request'."
  (car (apply #'jsonrpc-async-request connection method params args)))

(defun eglotx--backend-by-name (server name)
  "Return SERVER backend named NAME in constant time, or nil."
  (and (stringp name) (gethash name (eglotx--backend-table server))))

(defun eglotx--backend-by-id (server id)
  "Return SERVER backend with internal ID in constant time, or nil."
  (and (stringp id) (gethash id (eglotx--backend-id-table server))))

(defun eglotx--direct-request-timeout (backend)
  "Return the bounded private-request timeout for BACKEND."
  (let ((backend-timeout (eglotx--backend-request-timeout backend)))
    (if backend-timeout
        (min eglotx-cross-backend-request-timeout backend-timeout)
      eglotx-cross-backend-request-timeout)))

(defun eglotx--invoke-direct-callback
    (server source function payload &optional context)
  "Invoke FUNCTION with PAYLOAD while SOURCE remains usable in SERVER.
CONTEXT describes the adapter operation in diagnostics."
  (when (and (functionp function)
             (not (memq (eglotx--state server) '(stopping dead failed)))
             (eglotx--backend-running-p source))
    (condition-case err
        (funcall function payload)
      (error
       (display-warning
        'eglotx
        (format "Cross-backend callback%s failed: %s"
                (if context (format " for %s" context) "")
                (error-message-string err))
        :error)))))

(defun eglotx--cancel-direct-child (request)
  "Cancel REQUEST on its target connection when it has been dispatched."
  (when-let* ((child-id (eglotx--direct-request-child-id request))
              (target (eglotx--direct-request-target request))
              (connection (eglotx--backend-connection target))
              ((jsonrpc-running-p connection)))
    (eglotx--remove-child-continuation connection child-id)
    (ignore-errors
      (jsonrpc-notify connection :$/cancelRequest (list :id child-id)))))

(defun eglotx--finalize-direct-request
    (server token outcome payload &optional cancel-child-p urgent-p)
  "Idempotently release SERVER private request TOKEN.

OUTCOME is `success', `error', or `cancel'.  PAYLOAD is delivered only for
the first two outcomes, outside process filters.  CANCEL-CHILD-P also releases
the target continuation and notifies it of cancellation.  URGENT-P places the
callback at the front of the bounded work queue."
  (when-let* ((request (gethash token (eglotx--direct-requests server))))
    ;; The table owns the request.  Release it before touching the child or
    ;; scheduling user-configured adapter code so every racing path becomes a
    ;; harmless no-op after the first finalizer.
    (remhash token (eglotx--direct-requests server))
    (when cancel-child-p
      (eglotx--cancel-direct-child request))
    (when (memq outcome '(success error))
      (let ((enqueue (if urgent-p
                         #'eglotx--enqueue-urgent-work
                       #'eglotx--enqueue-work)))
        (funcall
         enqueue server #'eglotx--invoke-direct-callback
         server
         (eglotx--direct-request-source request)
         (if (eq outcome 'success)
             (eglotx--direct-request-success-function request)
           (eglotx--direct-request-error-function request))
         payload
         (format "%s -> %s"
                 (eglotx--backend-name
                  (eglotx--direct-request-source request))
                 (eglotx--backend-name
                  (eglotx--direct-request-target request))))))
    t))

(defun eglotx--direct-request-timeout-fired (server token)
  "Cancel and fail SERVER private request TOKEN after its deadline."
  (eglotx--finalize-direct-request
   server token 'error
   (list :code -32002 :message "Cross-backend request timed out") t))

(defun eglotx--reject-direct-request (server source error-function error-data)
  "Report ERROR-DATA for a private request rejected before dispatch."
  (eglotx--enqueue-work
   server #'eglotx--invoke-direct-callback
   server source error-function error-data "request dispatch"))

(defun eglotx-backend-request
    (server source target-name method params success-function error-function)
  "Asynchronously send METHOD with PARAMS to TARGET-NAME in SERVER.

SOURCE owns the explicit notification adapter that requested this operation.
SUCCESS-FUNCTION and ERROR-FUNCTION each receive one payload on a safe deferred
work turn.  An accepted request uses the smaller of the target timeout and
`eglotx-cross-backend-request-timeout', has one idempotent finalizer, and
returns its child request ID.  SOURCE is the opaque backend value passed to a
configured notification handler.

An unavailable target, disallowed method, or exhausted in-flight budget
returns nil and defers ERROR-FUNCTION.  An inactive source or stopping facade
returns nil without invoking either callback."
  (let* ((target (eglotx--backend-by-name server target-name))
         (key (eglotx--method-key method))
         (pending (eglotx--direct-requests server)))
    (cond
     ((or (not (eglotx--backend-running-p source))
          (memq (eglotx--state server) '(stopping dead failed)))
      nil)
     ((or (null target) (eq source target)
          (not (eglotx--backend-running-p target)))
      (eglotx--reject-direct-request
       server source error-function
       (list :code -32097
             :message (format "Cross-backend target %s is unavailable"
                              target-name)))
      nil)
     ((not (eglotx--backend-allows-p target key))
      (eglotx--reject-direct-request
       server source error-function
       (list :code -32601
             :message (format "Backend %s does not allow %s"
                              target-name key)))
      nil)
     ((>= (hash-table-count pending) eglotx-cross-backend-request-limit)
      (eglotx--reject-direct-request
       server source error-function
       (list :code -32098 :message "Cross-backend request limit reached"))
      nil)
     (t
      (let* ((token (cl-incf (eglotx--next-direct-token server)))
             (request
              (eglotx--direct-request-create
               :token token :source source :target target
               :success-function success-function
               :error-function error-function)))
        (puthash token request pending)
        (cl-incf (eglotx--direct-request-total server))
        (condition-case err
            (let ((child-id
                   (eglotx--async-request
                    (eglotx--backend-connection target) key params
                    :timeout (eglotx--direct-request-timeout target)
                    :success-fn
                    (lambda (result)
                      (eglotx--finalize-direct-request
                       server token 'success result))
                    :error-fn
                    (lambda (error-data)
                      (eglotx--finalize-direct-request
                       server token 'error error-data))
                    :timeout-fn
                    (lambda ()
                      (eglotx--direct-request-timeout-fired server token)))))
              (setf (eglotx--direct-request-child-id request) child-id)
              child-id)
          (error
           (eglotx--finalize-direct-request
            server token 'error
            (list :code -32603 :message (error-message-string err)))
           nil)))))))

(defun eglotx--cancel-all-direct-requests (server)
  "Cancel and release every private request owned by SERVER."
  (dolist (request (hash-table-values (eglotx--direct-requests server)))
    (eglotx--finalize-direct-request
     server (eglotx--direct-request-token request) 'cancel nil t)))

(defun eglotx--backend-stopped-direct-requests (server backend)
  "Release private SERVER requests whose SOURCE or target is BACKEND."
  (dolist (request (hash-table-values (eglotx--direct-requests server)))
    (cond
     ((eq backend (eglotx--direct-request-source request))
      (eglotx--finalize-direct-request
       server (eglotx--direct-request-token request) 'cancel nil t))
     ((eq backend (eglotx--direct-request-target request))
      (if (memq (eglotx--state server) '(stopping dead failed))
          (eglotx--finalize-direct-request
           server (eglotx--direct-request-token request) 'cancel nil)
        (eglotx--finalize-direct-request
         server (eglotx--direct-request-token request) 'error
         (list :code -32097
               :message
               (format "Cross-backend target %s exited"
                       (eglotx--backend-name backend)))
         nil t))))))

(defun eglotx--dispatch-request (server id method params params-present-p)
  "Dispatch facade request ID with METHOD and PARAMS from SERVER."
  (let* ((key (eglotx--method-key method))
         (policy (eglotx--policy key))
         (_ (when (eq key :initialize)
              (setf (eglotx--client-capabilities server)
                    (copy-tree (plist-get params :capabilities)))
              (setf (eglotx--stream-diagnostics-p server)
                    (and eglotx-stream-diagnostics
                         (not
                          (eglotx--json-false-p
                           (plist-get
                            (plist-get
                             (plist-get params :capabilities)
                             :textDocument)
                            :$streamingDiagnostics)))))))
         (owner-token (and (eq (plist-get policy :route) 'owner)
                           (eglotx--owner-token-in params)))
         (owner (and owner-token
                     (eglotx--owner-for-params server params)))
         (owner-location
          (and owner-token
               (eglotx--completion-batch-location server owner-token)))
         (owner-token-shared-p
          (and owner-location
               (eglotx--completion-shared-index-p
                (car owner-location) (cdr owner-location))))
         ;; Capture the one selected edit in the request itself.  The compact
         ;; source batch may be evicted while a child resolve is in flight;
         ;; request.params and its owner/generation snapshot outlive that
         ;; bounded cache entry.
         (request-params
          (if (and (eq key :completionItem/resolve) owner)
              (eglotx--materialize-completion-item server params)
            params))
         (targets
          (eglotx--select-request-targets
           server key request-params policy)))
    (if (null targets)
        (cond
         ((eq key :shutdown)
          (eglotx--deliver-result server id nil))
         ((and (plist-get policy :resolve) owner)
          ;; The facade can advertise resolve when only some aggregated
          ;; providers support it.  Items owned by a non-resolving provider
          ;; are completed by the facade without a child round trip.  Promote
          ;; a selected compact completion into the ordinary bounded owner
          ;; cache, so a later resolve does not depend on its source batch.
          (eglotx--deliver-result
           server id
           (if (and (eq key :completionItem/resolve) owner-location)
               (eglotx--tag-owned-object
                server (eglotx--owner-backend owner)
                (eglotx--plist-delete request-params :data)
                key (eglotx--owner-uri owner) nil nil owner)
             request-params)))
         (t
          (eglotx--deliver-error
           server id
           (list :code -32601
                 :message (format "No Eglotx backend handles %s" key)))))
      (let* ((pending (make-hash-table :test #'eq))
             (document-uri
              (and (memq key '(:textDocument/diagnostic
                                :textDocument/completion
                                :completionItem/resolve))
                   (eglotx--canonical-document-uri
                    server
                    (or (eglotx--params-uri request-params)
                        (and owner (eglotx--owner-uri owner))))))
             (document (and document-uri
                            (eglotx--document-for-uri server document-uri)))
             (request
              (eglotx--request-create
               :id id :method key :params request-params :policy policy
               :document-uri document-uri :document document
               :document-generation
               (and document (eglotx--document-generation document))
               :document-mutation-epoch
               (and (eq key :textDocument/diagnostic)
                    (eglotx--document-mutation-epoch server))
               :owner owner
               :owner-token-shared-p owner-token-shared-p
               :targets targets :pending pending
               :results (make-hash-table :test #'eq))))
        (dolist (backend targets) (puthash backend t pending))
        (puthash id request (eglotx--requests server))
        (when-let* ((timeout (eglotx--request-timeout key targets)))
          (setf (eglotx--request-timer request)
                (run-with-timer timeout nil #'eglotx--request-deadline
                                server id)))
        (dolist (backend targets)
          (unless (eglotx--request-completed request)
            (condition-case err
                (let* ((connection (eglotx--backend-connection backend))
                     (child-params
                      (if params-present-p
                          (eglotx--transform-client-progress-tokens
                           server backend request
                           (eglotx--transform-client-params
                            server backend key request-params))
                        :jsonrpc-omit))
                     (timeout (eglotx--backend-request-timeout backend))
                     (child-id
                      (eglotx--async-request
                       connection key child-params
                       :timeout timeout
                       :success-fn
                       (lambda (result)
                         (eglotx--record-response
                          server id backend t result))
                       :error-fn
                       (lambda (error)
                         (eglotx--record-response
                          server id backend nil error))
                       :timeout-fn
                       (lambda ()
                         ;; jsonrpc.el releases its timer/continuation before
                         ;; calling us, but it does not notify the peer.
                         (eglotx--cancel-child-leg request backend)
                         (eglotx--record-response
                          server id backend nil
                          (list :code -32002
                                :message
                                (format "Backend %s timed out"
                                        (eglotx--backend-name backend))))))))
                  (push (cons backend child-id)
                        (eglotx--request-child-ids request)))
              (error
               (eglotx--record-response
                server id backend nil
                (list :code -32603
                      :message (error-message-string err)))))))))))

(defun eglotx--finish-request-by-id (server id)
  "Finish ready request ID in SERVER if it is still live."
  (when-let* ((request (gethash id (eglotx--requests server)))
              ((zerop (hash-table-count
                       (eglotx--request-pending request)))))
    (eglotx--finish-request server request)))

(defun eglotx--finish-ready-request (server request &optional urgent-p)
  "Finish SERVER REQUEST after earlier child wire events.
URGENT-P puts a terminal lifecycle result ahead of ordinary notifications.
Responses and notifications can be delivered through different jsonrpc.el
turns even when they arrived in one child process read.  Always using the
facade FIFO preserves their wire order and prevents request cleanup from
releasing work-done tokens before queued begin/end notifications run."
  (funcall (if urgent-p
               #'eglotx--enqueue-urgent-work
             #'eglotx--enqueue-work)
           server #'eglotx--finish-request-by-id
           server (eglotx--request-id request)))

(defun eglotx--abort-required-initialize-legs (_server request failed-backend)
  "Cancel REQUEST legs after required FAILED-BACKEND initialization failed."
  (dolist (backend (eglotx--request-targets request))
    (when (and (not (eq backend failed-backend))
               (gethash backend (eglotx--request-pending request)))
      (eglotx--cancel-child-leg request backend)
      (remhash backend (eglotx--request-pending request)))))

(defun eglotx--record-response (server id backend success-p payload)
  "Record BACKEND response PAYLOAD for facade request ID on SERVER."
  (when-let* ((request (gethash id (eglotx--requests server)))
              ((not (eglotx--request-completed request)))
              ((gethash backend (eglotx--request-pending request))))
    (let (static-selectors)
      (eglotx--seal-pending-diagnostics server)
      (when (and success-p (eq (eglotx--request-method request) :initialize))
        (let* ((capabilities (plist-get payload :capabilities))
               (encoding (plist-get capabilities :positionEncoding)))
          (when (and (plist-member capabilities :positionEncoding)
                     (not (equal encoding "utf-16")))
            (setq success-p nil
                  payload
                  (list
                   :code -32602
                   :message
                   (format
                    "Backend %s negotiated unsupported position encoding %S"
                    (eglotx--backend-name backend) encoding))))
          ;; Compile externally controlled selectors before committing either
          ;; backend or request state.  A malformed optional backend then
          ;; follows the ordinary initialize-failure finalizer.
          (when success-p
            (condition-case err
                (setq static-selectors
                      (eglotx--compile-static-selectors capabilities))
              (error
               (setq success-p nil
                     payload
                     (list :code -32602
                           :message (error-message-string err))))))))
      (remhash backend (eglotx--request-pending request))
      (puthash backend (cons success-p payload)
               (eglotx--request-results request))
      (when (and success-p (eq (eglotx--request-method request) :initialize))
        (setf (eglotx--backend-capabilities backend)
              (copy-tree (plist-get payload :capabilities))
              (eglotx--backend-server-info backend)
              (copy-tree (plist-get payload :serverInfo))
              (eglotx--backend-text-sync backend)
              (copy-tree (plist-get (plist-get payload :capabilities)
                                    :textDocumentSync))
              (eglotx--backend-static-capability-selectors backend)
              static-selectors))
      (let ((required-initialize-failure-p
             (and (not success-p)
                  (eq (eglotx--request-method request) :initialize)
                  (eglotx--backend-required backend))))
        (when required-initialize-failure-p
          (eglotx--abort-required-initialize-legs server request backend))
        (when (zerop (hash-table-count (eglotx--request-pending request)))
          (eglotx--finish-ready-request
           server request required-initialize-failure-p))))))

(defun eglotx--remove-child-continuation (connection child-id)
  "Forget CHILD-ID and its timer on CONNECTION."
  (jsonrpc--remove connection child-id))

(defun eglotx--cancel-child-leg (request backend)
  "Cancel REQUEST's child leg for BACKEND."
  (when-let* ((child-id (alist-get backend (eglotx--request-child-ids request)
                                  nil nil #'eq))
              (connection (eglotx--backend-connection backend))
              ((jsonrpc-running-p connection)))
    (eglotx--remove-child-continuation connection child-id)
    (ignore-errors
      (jsonrpc-notify connection :$/cancelRequest (list :id child-id)))))

(defun eglotx--cancel-request (server id &optional reply-to-parent-p)
  "Cancel facade request ID on SERVER and all of its child legs."
  (when-let* ((request (gethash id (eglotx--requests server))))
    (setf (eglotx--request-cancelled request) t
          (eglotx--request-completed request) t)
    (remhash id (eglotx--requests server))
    (when-let* ((timer (eglotx--request-timer request)))
      (cancel-timer timer))
    (dolist (backend (eglotx--request-targets request))
      (eglotx--cancel-child-leg request backend))
    (eglotx--release-request-progress server request)
    (when reply-to-parent-p
      (eglotx--deliver-error
       server id (list :code -32800 :message "Request cancelled")))))

(defun eglotx--request-deadline (server id)
  "Finish facade request ID on SERVER at its deadline."
  (when-let* ((request (gethash id (eglotx--requests server))))
    (dolist (backend (eglotx--request-targets request))
      (when (gethash backend (eglotx--request-pending request))
        (eglotx--cancel-child-leg request backend)
        (remhash backend (eglotx--request-pending request))
        (puthash backend
                 (cons nil
                       (list :code -32002
                             :message
                             (format "Backend %s timed out"
                                     (eglotx--backend-name backend))))
                 (eglotx--request-results request))))
    (eglotx--finish-request server request t)))

(defun eglotx--request-outcomes (request success-p)
  "Return REQUEST outcomes whose success flag is SUCCESS-P, in target order."
  (cl-loop for backend in (eglotx--request-targets request)
           for probe = (gethash backend (eglotx--request-results request)
                                'eglotx--missing)
           unless (eq probe 'eglotx--missing)
           when (eq (car probe) success-p)
           collect (cons backend (cdr probe))))

(defun eglotx--required-initialize-error (request)
  "Return a required backend initialization error from REQUEST."
  (when (eq (eglotx--request-method request) :initialize)
    (cl-loop for backend in (eglotx--request-targets request)
             for probe = (gethash backend (eglotx--request-results request))
             when (and probe
                       (not (car probe))
                       (eglotx--backend-required backend))
             return (cdr probe))))

(defun eglotx--finish-request (server request &optional timed-out-p)
  "Finalize REQUEST exactly once and reply through SERVER.
TIMED-OUT-P means the facade deadline fired with pending legs."
  (unless (eglotx--request-completed request)
    (setf (eglotx--request-completed request) t)
    (remhash (eglotx--request-id request) (eglotx--requests server))
    (when-let* ((timer (eglotx--request-timer request)))
      (cancel-timer timer))
    (eglotx--release-request-progress server request)
    (unless (eglotx--request-cancelled request)
      (let ((required-error (eglotx--required-initialize-error request))
            (successes (eglotx--request-outcomes request t))
            (errors (eglotx--request-outcomes request nil)))
        (when (eq (eglotx--request-method request) :initialize)
          (dolist (outcome errors)
            (let ((backend (car outcome))
                  (error (cdr outcome)))
              (setf (eglotx--backend-state backend) 'failed
                    (eglotx--backend-last-error backend)
                    (or (plist-get error :message) (format "%S" error)))
              (when-let* ((connection (eglotx--backend-connection backend))
                          (process (jsonrpc--process connection))
                          ((process-live-p process)))
                ;; Never synchronously wait for process shutdown from a child
                ;; response callback.  Deleting the rejected backend is
                ;; immediate; jsonrpc.el's sentinel performs continuation
                ;; cleanup on the next event-loop turn.
                (delete-process process))
              (unless (eglotx--backend-required backend)
                (display-warning
                 'eglotx
                 (format "Optional backend %s failed to initialize: %s"
                         (eglotx--backend-name backend)
                         (eglotx--backend-last-error backend))
                 :warning)))))
        (cond
         ((eq (eglotx--request-method request) :shutdown)
          ;; LSP shutdown is best-effort at the facade boundary.  Returning an
          ;; error makes Eglot skip the mandatory subsequent `exit'
          ;; notification, so record child failures in status but always let
          ;; the client advance the lifecycle.
          (dolist (outcome errors)
            (setf (eglotx--backend-last-error (car outcome))
                  (or (plist-get (cdr outcome) :message)
                      (format "%S" (cdr outcome)))))
          (eglotx--deliver-result server (eglotx--request-id request) nil))
         (required-error
          (setf (eglotx--state server) 'failed)
          (eglotx--deliver-error server (eglotx--request-id request)
                                 required-error t))
         (successes
          (condition-case err
              (eglotx--deliver-result
               server (eglotx--request-id request)
               (eglotx--merge-responses server request successes))
            (eglotx-content-modified
             (eglotx--deliver-error
              server (eglotx--request-id request)
              (list :code -32801 :message (error-message-string err))))
            (error
             (eglotx--deliver-error
              server (eglotx--request-id request)
              (list :code -32603 :message (error-message-string err))))))
         (errors
          (eglotx--deliver-error server (eglotx--request-id request)
                                 (cdar errors)))
         (timed-out-p
          (eglotx--deliver-error
           server (eglotx--request-id request)
           (list :code -32002 :message "Eglotx request timed out")))
         (t
          (eglotx--deliver-error
           server (eglotx--request-id request)
           (list :code -32603 :message "Eglotx request produced no result"))))))))

(defun eglotx--delivery-message (id key payload)
  "Build a JSON-RPC response for ID with KEY and PAYLOAD."
  (list :jsonrpc "2.0" :id id key payload))

(defun eglotx--deliver-message-now (server message shutdown-p)
  "Inject MESSAGE into SERVER now and then honor SHUTDOWN-P."
  (when (object-of-class-p server 'eglotx-server)
    (unwind-protect
        (when (and (not (eq (eglotx--state server) 'dead))
                   (process-live-p (jsonrpc--process server))
                   (eglotx--parent-continuation-live-p
                    server (plist-get message :id)))
          (jsonrpc-connection-receive server message))
      ;; A required initialization failure must reach the parent continuation
      ;; before its successful siblings are torn down.
      (when (and shutdown-p (not (eq (eglotx--state server) 'dead)))
        (jsonrpc-shutdown server t)))))

(defun eglotx--deliver-message (server message &optional shutdown-p)
  "Inject MESSAGE into SERVER on a safe event-loop turn.
When SHUTDOWN-P is non-nil, close SERVER after attempting the delivery."
  (if eglotx--in-deferred-work
      (eglotx--deliver-message-now server message shutdown-p)
    (run-at-time 0 nil #'eglotx--deliver-message-now
                 server message shutdown-p)))

(defun eglotx--parent-continuation-live-p (server id)
  "Return non-nil when SERVER still awaits facade response ID."
  (and (assq id (jsonrpc--continuations server)) t))

(defun eglotx--deliver-result (server id result)
  "Deliver RESULT for facade request ID on SERVER."
  (eglotx--deliver-message server
                           (eglotx--delivery-message id :result result)))

(defun eglotx--deliver-error (server id error &optional shutdown-p)
  "Deliver JSON-RPC ERROR for facade request ID on SERVER.
When SHUTDOWN-P is non-nil, close SERVER after attempting the delivery."
  (eglotx--deliver-message server
                           (eglotx--delivery-message id :error error)
                           shutdown-p))

(defun eglotx--events-config (connection)
  "Return CONNECTION's event configuration."
  (slot-value connection '-events-buffer-config))

(defun eglotx--log-facade-send (server args kind)
  "Log SERVER facade metadata for outbound ARGS of KIND without serialization."
  (when-let* ((config (eglotx--events-config server)))
    (let ((size (plist-get config :size)))
      (when (or (null size) (> size 0))
        (jsonrpc--event server 'client :kind kind :message args
                        :log-text
                        "[eglotx facade payload kept in-process]")))))

(defvar eglotx--capturing-sync-request nil)
(defvar eglotx--captured-sync-request-id nil)

(cl-defmethod jsonrpc-connection-send
  ((server eglotx-server) &rest args
   &key id method _params
   (_result nil result-supplied-p) error _partial
   &allow-other-keys)
  "Route SERVER facade JSON-RPC message in ARGS without serializing it.
Use ID and METHOD to distinguish requests from notifications.  Accept ERROR
as part of the JSON-RPC connection method interface."
  (ignore result-supplied-p error)
  (let ((kind (cond ((or (plist-member args :result)
                         (plist-member args :error))
                     'reply)
                    (id 'request)
                    (method 'notification))))
    (eglotx--log-facade-send server args kind)
    (cond
     ((eq kind 'reply)
      (display-warning 'eglotx
                       "Unexpected facade reply with no backend request owner"
                       :warning))
     ((eq kind 'request)
      (when eglotx--capturing-sync-request
        (setq eglotx--captured-sync-request-id id))
      (eglotx--dispatch-request server id method (plist-get args :params)
                                (plist-member args :params)))
     ((eq kind 'notification)
      (eglotx--dispatch-notification server method (plist-get args :params)
                                     (plist-member args :params))))))

(cl-defmethod jsonrpc-running-p ((server eglotx-server))
  "Return non-nil while SERVER's facade anchor is live."
  (and (not (eq (eglotx--state server) 'dead))
       (cl-call-next-method)))

(cl-defmethod jsonrpc-shutdown ((server eglotx-server) &optional cleanup)
  "Shut down SERVER, its pending requests, and every backend.
Pass CLEANUP through to each backend and the superclass implementation."
  (if (eq (eglotx--state server) 'dead)
      ;; Permit a second shutdown to escalate a prior graceful close into
      ;; buffer cleanup.  jsonrpc.el guards dead child connections itself, so
      ;; explicitly release their transport buffers here.
      (when cleanup
        (dolist (backend (eglotx--backends server))
          (when-let* ((connection (eglotx--backend-connection backend)))
            (eglotx--cleanup-child-buffers connection))))
    (let ((force (eq (eglotx--state server) 'failed)))
      (setf (eglotx--state server) 'stopping)
      (when-let* ((timer (eglotx--work-timer server))
                  ((timerp timer)))
        (cancel-timer timer))
      (setf (eglotx--work-head server) nil
            (eglotx--work-tail server) nil
            (eglotx--work-timer server) nil
            (eglotx--pending-diagnostics server) nil
            (eglotx--semantic-refresh-pending-p server) nil
            (eglotx--facade-capabilities server) nil)
      (ignore-errors (eglotx--remove-file-watches server))
      (mapc (lambda (request)
              (eglotx--cancel-request server (eglotx--request-id request)))
            (hash-table-values (eglotx--requests server)))
      (eglotx--cancel-all-direct-requests server)
      ;; A required-child crash is already an unrecoverable protocol failure;
      ;; terminate siblings before jsonrpc.el's grace-period wait.
      (eglotx--close-backends server cleanup force)
      (maphash (lambda (_uri document)
                 (eglotx--forget-document-tokens server document))
               (eglotx--documents server))
      (clrhash (eglotx--documents server))
      (clrhash (eglotx--document-identities server))
      (clrhash (eglotx--document-mutation-epochs server))
      (clrhash (eglotx--uri-identities server))
      (clrhash (eglotx--owners server))
      (clrhash (eglotx--completion-batches server))
      (clrhash (eglotx--command-owners server))
      (clrhash (eglotx--command-tokens server))
      (clrhash (eglotx--diagnostic-tokens server))
      (clrhash (eglotx--diagnostic-snapshots server))
      (clrhash (eglotx--diagnostic-version-watermarks server))
      (clrhash (eglotx--diagnostic-uri-nodes server))
      (clrhash (eglotx--diagnostic-cursors server))
      (clrhash (eglotx--diagnostic-cursor-subjects server))
      (dolist (backend (eglotx--backends server))
        (dolist (kind '(owner command diagnostic))
          (eglotx--ledger-clear (eglotx--backend-ledger backend kind))))
      (clrhash (eglotx--backend-id-table server))
      (setf (eglotx--diagnostic-uri-head server) nil
            (eglotx--diagnostic-uri-tail server) nil
            (eglotx--state server) 'dead)
      ;; The facade has no peer process that can close this inert transport.
      ;; End it explicitly so jsonrpc.el observes its sentinel instead of
      ;; waiting for the normal process-shutdown grace period and warning.
      (when-let* ((process (jsonrpc--process server))
                  ((process-live-p process)))
        (delete-process process))))
  (unwind-protect
      (cl-call-next-method)
    ;; jsonrpc.el's CLEANUP contract releases transport and stderr buffers,
    ;; but its sentinel may also have created an events buffer while shutting
    ;; down.  Finish facade ownership only after the superclass is done using
    ;; those buffers.
    (when cleanup
      (eglotx--cleanup-child-buffers server))))

;; LSP data ownership and parameter transformation.

(defun eglotx--plist-delete (plist property)
  "Return a shallow copy of PLIST without PROPERTY."
  (let (result)
    (while plist
      (let ((key (pop plist))
            (value (pop plist)))
        (unless (eq key property)
          (setq result (nconc result (list key value))))))
    result))

(defun eglotx--json-object-p (value)
  "Return non-nil when VALUE looks like a keyword-keyed JSON object."
  (and (consp value)
       (proper-list-p value)
       (cl-evenp (length value))
       (cl-loop for (key _value) on value by #'cddr
                always (keywordp key))))

(defun eglotx--json-empty-object-p (value)
  "Return non-nil when VALUE is an explicitly represented empty JSON object."
  (and (hash-table-p value) (= (hash-table-count value) 0)))

(defun eglotx--json-detach (value)
  "Return a recursively detached copy of JSON-shaped VALUE.

This is reserved for user functions that may destructively transform their
argument.  Static overlays use path copying in `eglotx--json-merge' instead."
  (cond
   ((hash-table-p value)
    (let ((copy (copy-hash-table value)))
      ;; Rebuild rather than overwrite entries in the shallow copy: with an
      ;; `equal' table, `puthash' may retain the original mutable string key.
      (clrhash copy)
      (maphash (lambda (key item)
                 (puthash (eglotx--json-detach key)
                          (eglotx--json-detach item)
                          copy))
               value)
      copy))
   ((stringp value) (copy-sequence value))
   ((consp value)
    (cons (eglotx--json-detach (car value))
          (eglotx--json-detach (cdr value))))
   ((vectorp value)
    (vconcat (mapcar #'eglotx--json-detach (append value nil))))
   (t value)))

(defun eglotx--json-merge (base overlay)
  "Merge JSON object OVERLAY over BASE using copy-on-write paths.

Neither input is mutated.  Unchanged subtrees retain their identity."
  (cond
   ((null overlay) base)
   ;; `{}` contributes no keys to an existing JSON object.  Keep the explicit
   ;; hash representation only when BASE is null, so callers can guarantee an
   ;; object on the wire without erasing client-provided settings.
   ((and (eglotx--json-empty-object-p overlay)
         (or (eglotx--json-object-p base) (hash-table-p base)))
    base)
   ((and (eglotx--json-object-p base) (eglotx--json-object-p overlay))
    ;; Copy this plist spine once.  Recursive merges copy only the nested
    ;; spines that receive overlay keys; untouched JSON subtrees stay shared.
    (let ((result (copy-sequence base)))
      (cl-loop for (key value) on overlay by #'cddr
               for old = (plist-get result key)
               do (setq result
                        (plist-put result key
                                   (cond
                                    ((and (eglotx--json-object-p old)
                                          (eglotx--json-object-p value))
                                     (eglotx--json-merge old value))
                                    ;; Empty hash tables are the unambiguous
                                    ;; Emacs representation of `{}`.  In a
                                    ;; deep merge they ensure object shape but
                                    ;; must not erase an existing object.
                                    ((and (eglotx--json-empty-object-p value)
                                          (or (eglotx--json-object-p old)
                                              (hash-table-p old)))
                                     old)
                                    (t value)))))
      result))
   (t overlay)))

(defun eglotx--backend-overlay (value base)
  "Apply backend configuration VALUE to JSON BASE."
  (cond ((null value) base)
        ((functionp value) (funcall value (eglotx--json-detach base)))
        (t (eglotx--json-merge base value))))

(defun eglotx--params-uri (params)
  "Extract a document URI from PARAMS when present."
  (or (plist-get (plist-get params :textDocument) :uri)
      (plist-get params :uri)
      (plist-get (plist-get params :item) :uri)
      (plist-get (plist-get params :item) :targetUri)))

(defun eglotx--normalize-file-uri-path (path)
  "Return a lexical normal form for decoded file-URI PATH.
This removes dot segments without consulting the filesystem.  A leading
double slash is kept opaque because it may carry platform-specific UNC
semantics."
  (let ((normalized path))
    (when (and (string-prefix-p "/" path)
               (not (string-prefix-p "//" path)))
      (let ((trailing-p
             (or (string-suffix-p "/" path)
                 (string-suffix-p "/." path)
                 (string-suffix-p "/.." path)))
            segments)
        (dolist (segment (split-string path "/" t))
          (cond
           ((equal segment "."))
           ((equal segment "..") (when segments (pop segments)))
           (t (push segment segments))))
        (setq normalized
              (concat "/" (string-join (nreverse segments) "/")))
        (when (and trailing-p (> (length normalized) 1))
          (setq normalized (concat normalized "/")))))
    ;; RFC 8089 notes that Windows drive letters are case-insensitive.  LSP
    ;; additionally calls out differing drive-letter case and encoded colons.
    (when (string-match "\\`/\\([[:alpha:]]\\):\\(?:/\\|\\'\\)" normalized)
      (aset normalized 1 (upcase (aref normalized 1))))
    normalized))

(defun eglotx--uri-unreserved-byte-p (byte)
  "Return non-nil when BYTE is an RFC 3986 unreserved ASCII byte."
  (or (and (>= byte ?A) (<= byte ?Z))
      (and (>= byte ?a) (<= byte ?z))
      (and (>= byte ?0) (<= byte ?9))
      (memq byte '(?- ?. ?_ ?~))))

(defun eglotx--percent-encoded-byte (byte)
  "Return BYTE as one uppercase URI percent triplet."
  (format "%%%02X" byte))

(defun eglotx--canonical-file-uri-path-encoding (path)
  "Canonicalize percent encoding in file-URI PATH without decoding reserved bytes.
Return nil for malformed percent encoding.  Literal non-ASCII characters are
encoded as UTF-8, while percent-encoded unreserved bytes become their literal
form so equivalent URI spellings share an identity."
  (let ((index 0) pieces valid)
    (setq valid t)
    (while (and valid (< index (length path)))
      (let ((character (aref path index)))
        (cond
         ((eq character ?%)
          (if (and (< (+ index 2) (length path))
                   (string-match-p
                    "\\`[[:xdigit:]][[:xdigit:]]\\'"
                    (substring path (1+ index) (+ index 3))))
              (let ((byte
                     (string-to-number
                      (substring path (1+ index) (+ index 3)) 16)))
                (push (if (eglotx--uri-unreserved-byte-p byte)
                          (char-to-string byte)
                        (eglotx--percent-encoded-byte byte))
                      pieces)
                (cl-incf index 3))
            (setq valid nil)))
         ((and (< character 256)
               (aref eglotx--uri-path-allowed-chars character))
          (push (char-to-string character) pieces)
          (cl-incf index))
         (t
          (let ((bytes
                 (encode-coding-string
                  (char-to-string character) 'utf-8 t)))
            (dotimes (byte-index (length bytes))
              (push (eglotx--percent-encoded-byte
                     (aref bytes byte-index))
                    pieces)))
          (cl-incf index)))))
    (when valid
      (let ((encoded (apply #'concat (nreverse pieces))))
        ;; LSP explicitly permits an encoded Windows drive colon.  Decode only
        ;; this syntactic colon; every other percent-encoded reserved byte
        ;; remains distinct from its literal form.
        (when (string-match
               "\\`/[[:alpha:]]\\(%3A\\)\\(?:/\\|\\'\\)" encoded)
          (setq encoded
                (concat (substring encoded 0 (match-beginning 1))
                        ":"
                        (substring encoded (match-end 1)))))
        encoded))))

(defun eglotx--canonical-file-uri (uri)
  "Return a safe lexical canonical form for file URI, or URI unchanged."
  (condition-case nil
      (let ((case-fold-search t))
        (if (and (string-match
                  "\\`file:\\(?://\\([^/?#]*\\)\\)?\\([^?#]*\\)\\'" uri)
                 (string-prefix-p "/" (match-string 2 uri)))
            (let* ((wire-host (or (match-string 1 uri) ""))
                   (downcased-host (downcase wire-host))
                   (host (if (equal downcased-host "localhost")
                             ""
                           downcased-host))
                   (path
                    (eglotx--canonical-file-uri-path-encoding
                     (match-string 2 uri))))
              (if path
                  (concat "file://" host
                          (eglotx--normalize-file-uri-path path))
                uri))
          uri))
    (error uri)))

(defun eglotx--canonical-document-uri (server uri)
  "Return SERVER's cached canonical identity for document URI."
  (when uri
    (let* ((cache (eglotx--uri-identities server))
           (cached (gethash uri cache eglotx--missing-value)))
      (if (not (eq cached eglotx--missing-value))
          cached
        (let* ((canonical
                (if (and (stringp uri)
                         (string-prefix-p "file:" (downcase uri)))
                    (eglotx--canonical-file-uri uri)
                  uri))
               (ring (eglotx--uri-identity-ring server)))
          (when (= (ring-length ring) (ring-size ring))
            (let ((oldest (ring-ref ring (1- (ring-length ring)))))
              (remhash oldest cache)))
          (puthash uri canonical cache)
          (ring-insert ring uri)
          canonical)))))

(defun eglotx--document-for-uri (server uri)
  "Return SERVER document state for URI."
  (and uri
       (or (gethash uri (eglotx--documents server))
           (gethash (eglotx--canonical-document-uri server uri)
                    (eglotx--document-identities server)))))

(defun eglotx--normalize-diagnostic-params (server params)
  "Return diagnostic PARAMS using SERVER's canonical document URI."
  (let* ((uri (plist-get params :uri))
         (canonical (eglotx--canonical-document-uri server uri)))
    (if (equal canonical uri)
        params
      (plist-put (copy-sequence params) :uri canonical))))

(defun eglotx--drop-diagnostic-cursor (server token)
  "Forget facade diagnostic cursor TOKEN and its latest-subject index."
  (let* ((cursors (eglotx--diagnostic-cursors server))
         (cursor (gethash token cursors)))
    (when cursor
      (let ((subject (eglotx--diagnostic-cursor-uri cursor))
            (subjects (eglotx--diagnostic-cursor-subjects server)))
        (when (equal (gethash subject subjects) token)
          (remhash subject subjects)))
      (remhash token cursors))))

(defun eglotx--invalidate-diagnostic-cursor (server uri)
  "Invalidate SERVER's latest facade pull cursor for URI."
  (let* ((subject (eglotx--canonical-document-uri server uri))
         (token (gethash subject
                         (eglotx--diagnostic-cursor-subjects server))))
    (when token
      (eglotx--drop-diagnostic-cursor server token))))

(defun eglotx--invalidate-backend-diagnostic-cursors (server backend)
  "Invalidate bounded SERVER cursors containing a value owned by BACKEND.
Return non-nil when at least one cursor was retired."
  (let (tokens)
    ;; The facade cursor ledger has a hard 4096-entry cap.  Scanning it once on
    ;; an optional-process crash avoids retaining an incremental handle whose
    ;; source connection no longer exists, including empty full reports that
    ;; have no diagnostic snapshot key.
    (maphash
     (lambda (token cursor)
       (unless
           (eq (gethash backend (eglotx--diagnostic-cursor-values cursor)
                        eglotx--missing-value)
               eglotx--missing-value)
         (push token tokens)))
     (eglotx--diagnostic-cursors server))
    (dolist (token tokens)
      (eglotx--drop-diagnostic-cursor server token))
    (not (null tokens))))

(defun eglotx--remember-diagnostic-cursor (server uri values)
  "Store backend pull-diagnostic cursor VALUES for SERVER URI.
Return a new opaque facade result ID, or nil when VALUES is empty."
  (let* ((canonical (eglotx--canonical-document-uri server uri))
         (document (eglotx--document-for-uri server canonical)))
    (when (and (hash-table-p values)
               (> (hash-table-count values) 0)
               ;; A large primary+related response can evict an earlier
               ;; unopened URI before cursors are minted at merge finalization.
               ;; Never expose a previousResultId for state the hub no longer
               ;; owns; the next request must force a fresh full child report.
               (or document
                   (gethash canonical
                            (eglotx--diagnostic-uri-nodes server))))
      (let ((ring (eglotx--diagnostic-cursor-ring server))
            (cursors (eglotx--diagnostic-cursors server))
            (subjects (eglotx--diagnostic-cursor-subjects server)))
        (when (= (ring-length ring) (ring-size ring))
          (let ((oldest (ring-ref ring (1- (ring-length ring)))))
            (eglotx--drop-diagnostic-cursor server oldest)))
        (let* ((token (eglotx--new-token server "diagnostic-cursor"))
               (cursor
                (eglotx--diagnostic-cursor-create
                 :uri canonical
                 :document document
                 :generation
                 (and document (eglotx--document-generation document))
                 :values values)))
          ;; A pull cursor is a versioned snapshot handle, not an alias for the
          ;; newest diagnostics.  Once a newer response exists for the same
          ;; subject, accepting the older token could materialize new data behind
          ;; an old result ID.
          (eglotx--invalidate-diagnostic-cursor server canonical)
          (puthash token cursor cursors)
          (puthash canonical token subjects)
          (ring-insert ring token)
          token)))))

(defun eglotx--diagnostic-cursor-value (server token backend uri)
  "Return BACKEND child cursor behind SERVER facade TOKEN.
URI and the open document identity must still match."
  (when-let* ((cursor (and (stringp token)
                           (gethash token
                                    (eglotx--diagnostic-cursors server))))
              (canonical (eglotx--canonical-document-uri server uri))
              ((equal canonical (eglotx--diagnostic-cursor-uri cursor)))
              ((eq (eglotx--document-for-uri server canonical)
                   (eglotx--diagnostic-cursor-document cursor))))
    (let ((document (eglotx--diagnostic-cursor-document cursor)))
      (when (or (null document)
                (= (eglotx--document-generation document)
                   (eglotx--diagnostic-cursor-generation cursor)))
        (gethash backend (eglotx--diagnostic-cursor-values cursor))))))

(defun eglotx--backend-diagnostic-identifier (server backend params)
  "Return BACKEND pull-diagnostic identifier matching SERVER PARAMS."
  (ignore server params)
  (let ((provider
         (plist-get (eglotx--backend-capabilities backend)
                    :diagnosticProvider)))
    (and (listp provider)
         (stringp (plist-get provider :identifier))
         (plist-get provider :identifier))))

(defun eglotx--set-backend-diagnostic-identifier
    (server backend params)
  "Return PARAMS with BACKEND's diagnostic identifier for SERVER."
  (let ((identifier
         (eglotx--backend-diagnostic-identifier server backend params)))
    (if identifier
        (plist-put (copy-sequence params) :identifier identifier)
      (eglotx--plist-delete params :identifier))))

(defun eglotx--transform-document-diagnostic-params
    (server backend params)
  "Expand facade document-diagnostic PARAMS for BACKEND through SERVER."
  (let* ((copy (eglotx--set-backend-diagnostic-identifier
                server backend params))
         (uri (eglotx--params-uri params))
         (previous (plist-get params :previousResultId))
         (child-cursor
          (eglotx--diagnostic-cursor-value server previous backend uri)))
    (if (not child-cursor)
        (eglotx--plist-delete copy :previousResultId)
      (setq copy
            (plist-put
             copy :previousResultId
             (eglotx--diagnostic-child-cursor-result-id child-cursor)))
      (when-let* ((child-uri
                   (eglotx--diagnostic-child-cursor-uri child-cursor))
                  (text-document (plist-get copy :textDocument)))
        (setq copy
              (plist-put
               copy :textDocument
               (plist-put (copy-sequence text-document) :uri child-uri))))
      copy)))

(defun eglotx--stream-diagnostics-for-uri-p (server uri)
  "Return non-nil when SERVER may stream independent snapshots for URI.
Eglot keeps its streaming token map in a managed document buffer.  For an
unopened URI it stores only the last ordinary Flymake list, so the facade must
project its backend snapshots as one standard aggregate instead."
  (and (eglotx--stream-diagnostics-p server)
       (eglotx--document-for-uri server uri)))

(defun eglotx--new-token (server kind)
  "Return a new opaque ownership token for KIND in SERVER."
  (format "eglotx:%s:%s:%d"
          (eglotx--session-id server) kind
          (cl-incf (eglotx--next-token server))))

(defun eglotx--completion-batch-backends (batch)
  "Return live BACKEND objects represented by BATCH in stable order."
  (let (backends)
    (dolist (segment (eglotx--completion-batch-segments batch))
      (when-let* ((backend (eglotx--completion-segment-backend segment))
                  ((not (memq backend backends))))
        (setq backends (nconc backends (list backend)))))
    backends))

(defun eglotx--forget-completion-batch (server prefix)
  "Release compact completion ownership under PREFIX from SERVER."
  (when-let* ((batch (gethash prefix (eglotx--completion-batches server))))
    (remhash prefix (eglotx--completion-batches server))
    (when-let* ((ring (eglotx--completion-batch-ring batch))
                (index (ring-member ring prefix)))
      (ring-remove ring index))
    (setf (eglotx--completion-batch-ring batch) nil)
    (dolist (backend (eglotx--completion-batch-backends batch))
      (eglotx--ledger-remove
       (eglotx--backend-ledger backend 'owner) prefix))
    batch))

(defun eglotx--forget-completion-ring (server ring)
  "Release every completion batch named by RING from SERVER."
  (while (not (ring-empty-p ring))
    (eglotx--forget-completion-batch server (ring-remove ring))))

(defun eglotx--completion-ring-for-uri (server uri)
  "Return SERVER's bounded whole-response completion ring for URI."
  (if-let* ((document (eglotx--document-for-uri server uri)))
      (or (eglotx--document-completion-ring document)
          (setf (eglotx--document-completion-ring document)
                (make-ring eglotx-completion-batch-limit)))
    (or (eglotx--orphan-completion-ring server)
        (setf (eglotx--orphan-completion-ring server)
              (make-ring eglotx-completion-batch-limit)))))

(defun eglotx--remember-completion-batch (server batch)
  "Retain whole completion BATCH atomically in SERVER."
  (let* ((prefix (eglotx--completion-batch-prefix batch))
         (ring (eglotx--completion-ring-for-uri
                server (eglotx--completion-batch-uri batch))))
    (when (= (ring-length ring) (ring-size ring))
      (eglotx--forget-completion-batch server (ring-remove ring)))
    (setf (eglotx--completion-batch-ring batch) ring)
    (puthash prefix batch (eglotx--completion-batches server))
    (dolist (backend (eglotx--completion-batch-backends batch))
      (eglotx--ledger-add
       (eglotx--backend-ledger backend 'owner) prefix))
    (ring-insert ring prefix)
    prefix))

(defun eglotx--retire-completion-batch-backend (server batch backend)
  "Withdraw BACKEND's segments from completion BATCH in SERVER."
  (dolist (segment (eglotx--completion-batch-segments batch))
    (when (eq backend (eglotx--completion-segment-backend segment))
      (setf (eglotx--completion-segment-backend segment) nil
            (eglotx--completion-segment-default-data segment)
            eglotx--missing-value
            (eglotx--completion-segment-default-edit-range segment)
            eglotx--missing-value
            (eglotx--completion-segment-data segment) nil)))
  (eglotx--ledger-remove
   (eglotx--backend-ledger backend 'owner)
   (eglotx--completion-batch-prefix batch))
  (unless (eglotx--completion-batch-backends batch)
    (eglotx--forget-completion-batch
     server (eglotx--completion-batch-prefix batch))))

(defun eglotx--store-owner-token (server token owner)
  "Store TOKEN's OWNER in SERVER and maintain its backend index."
  (when-let* ((previous (gethash token (eglotx--owners server))))
    ;; A resolve result may migrate from unopened/orphan ownership into a
    ;; document.  Remove its exact old location before publishing the new one.
    (when-let* ((container (eglotx--owner-container previous)))
      (eglotx--owner-cache-remove container token))
    (unless (eq (eglotx--owner-backend previous)
                (eglotx--owner-backend owner))
      (eglotx--ledger-remove
       (eglotx--backend-ledger (eglotx--owner-backend previous) 'owner)
       token)))
  (puthash token owner (eglotx--owners server))
  (eglotx--ledger-add
   (eglotx--backend-ledger (eglotx--owner-backend owner) 'owner) token))

(defun eglotx--forget-owner-token (server token)
  "Release TOKEN from SERVER and its owning backend index.
Return the former owner, or nil when TOKEN was already absent."
  (when-let* ((owner (gethash token (eglotx--owners server))))
    (when-let* ((container (eglotx--owner-container owner)))
      (eglotx--owner-cache-remove container token))
    (remhash token (eglotx--owners server))
    (eglotx--ledger-remove
     (eglotx--backend-ledger (eglotx--owner-backend owner) 'owner) token)
    owner))

(defun eglotx--store-command-owner-token (server token owner)
  "Store facade command TOKEN's OWNER and index it under its backend."
  (puthash token owner (eglotx--command-owners server))
  (eglotx--ledger-add
   (eglotx--backend-ledger (eglotx--owner-backend owner) 'command) token))

(defun eglotx--forget-command-owner-token (server token)
  "Release facade command TOKEN and its reverse/backend indexes."
  (when-let* ((owner (gethash token (eglotx--command-owners server))))
    (let* ((backend (eglotx--owner-backend owner))
           (key (cons (eglotx--backend-id backend)
                      (eglotx--owner-command owner))))
      (remhash token (eglotx--command-owners server))
      (when (equal token (gethash key (eglotx--command-tokens server)))
        (remhash key (eglotx--command-tokens server)))
      (eglotx--ledger-remove
       (eglotx--backend-ledger backend 'command) token)
      owner)))

(defun eglotx--owner-cache-remove (cache token)
  "Unlink TOKEN from exact owner CACHE in O(1)."
  (when-let* ((node (gethash token (eglotx--owner-cache-nodes cache))))
    (let ((previous (eglotx--owner-cache-node-previous node))
          (next (eglotx--owner-cache-node-next node)))
      (if previous
          (setf (eglotx--owner-cache-node-next previous) next)
        (setf (eglotx--owner-cache-head cache) next))
      (if next
          (setf (eglotx--owner-cache-node-previous next) previous)
        (setf (eglotx--owner-cache-tail cache) previous))
      (setf (eglotx--owner-cache-node-previous node) nil
            (eglotx--owner-cache-node-next node) nil)
      (remhash token (eglotx--owner-cache-nodes cache))
      (cl-decf (eglotx--owner-cache-count cache))
      t)))

(defun eglotx--owner-cache-insert (server cache token)
  "Remember TOKEN as newest in CACHE, evicting its exact oldest owner."
  (eglotx--owner-cache-remove cache token)
  (when (and (eglotx--owner-cache-limit cache)
             (>= (eglotx--owner-cache-count cache)
                 (eglotx--owner-cache-limit cache)))
    (let ((evicted
           (eglotx--owner-cache-node-token
            (eglotx--owner-cache-tail cache))))
      (eglotx--owner-cache-remove cache evicted)
      (eglotx--forget-owner-token server evicted)))
  (let* ((head (eglotx--owner-cache-head cache))
         (node (eglotx--owner-cache-node-create :token token :next head)))
    (when head
      (setf (eglotx--owner-cache-node-previous head) node))
    (setf (eglotx--owner-cache-head cache) node)
    (unless (eglotx--owner-cache-tail cache)
      (setf (eglotx--owner-cache-tail cache) node))
    (puthash token node (eglotx--owner-cache-nodes cache))
    (cl-incf (eglotx--owner-cache-count cache))
    (when-let* ((owner (gethash token (eglotx--owners server))))
      (setf (eglotx--owner-container owner) cache)))
  token)

(defun eglotx--owner-cache-tokens (cache)
  "Return CACHE tokens from newest to oldest."
  (let ((node (eglotx--owner-cache-head cache)) tokens)
    (while node
      (push (eglotx--owner-cache-node-token node) tokens)
      (setq node (eglotx--owner-cache-node-next node)))
    (nreverse tokens)))

(defun eglotx--document-token-cache (document)
  "Return DOCUMENT's exact, unbounded diagnostic owner cache."
  (or (eglotx--document-tokens document)
      (setf (eglotx--document-tokens document)
            (eglotx--owner-cache-create
             :limit nil :nodes (make-hash-table :test #'equal)))))

(defun eglotx--remember-token (server token owner uri)
  "Store TOKEN and OWNER in SERVER, associating it with URI when possible."
  (eglotx--store-owner-token server token owner)
  (if-let* ((document (eglotx--document-for-uri server uri)))
      (if (eq (eglotx--owner-kind owner) 'diagnostic)
          (eglotx--owner-cache-insert
           server (eglotx--document-token-cache document) token)
        (let ((ring (eglotx--document-owner-ring document)))
          (eglotx--owner-cache-insert server ring token)))
    (let ((ring (eglotx--orphan-owner-ring server)))
      (eglotx--owner-cache-insert server ring token)))
  token)

(defun eglotx--forget-document-tokens (server document &optional preserved)
  "Forget ownership tokens belonging to DOCUMENT in SERVER.
PRESERVED is an optional token set retained across a document mutation."
  (let ((cache (eglotx--document-token-cache document))
        node)
    (setq node (eglotx--owner-cache-head cache))
    (while node
      (let ((next (eglotx--owner-cache-node-next node))
            (token (eglotx--owner-cache-node-token node)))
        (unless (and preserved (gethash token preserved))
          (eglotx--forget-owner-token server token))
        (setq node next))))
  (dolist (token
           (eglotx--owner-cache-tokens
            (eglotx--document-owner-ring document)))
    (eglotx--forget-owner-token server token))
  (when-let* ((ring (eglotx--document-completion-ring document)))
    (eglotx--forget-completion-ring server ring))
  (setf (eglotx--document-owner-ring document)
        (eglotx--owner-cache-create
         :limit eglotx-document-owner-limit
         :nodes (make-hash-table :test #'equal))
        (eglotx--document-completion-ring document)
        (make-ring eglotx-completion-batch-limit)))

(defun eglotx--command-token (server backend command)
  "Return SERVER's stable opaque token for BACKEND COMMAND."
  (let* ((key (cons (eglotx--backend-id backend) command))
         (tokens (eglotx--command-tokens server))
         (token (or (gethash key tokens)
                    (let ((created (eglotx--new-token server "command")))
                      (puthash key created tokens)
                      created))))
    (unless (gethash token (eglotx--command-owners server))
      (eglotx--store-command-owner-token
       server token
       (eglotx--owner-create
        :backend backend :kind 'command :command command)))
    token))

(defun eglotx--tag-command-object (server backend object uri)
  "Namespace command in OBJECT for BACKEND within SERVER and associate URI."
  (if (not (listp object))
      object
    (let ((copy (copy-sequence object))
          (command (plist-get object :command))
          (label (plist-get object :label)))
      (cond
       ((stringp command)
        (setq copy
              (plist-put copy :command
                         (eglotx--command-token server backend command))))
       ((consp command)
        (setq copy
              (plist-put copy :command
                         (eglotx--tag-command-object
                          server backend command uri)))))
      ;; InlayHintLabelPart carries its own nested Command.  Preserve the JSON
      ;; sequence representation while recursively namespacing each part.
      (when (and (plist-member object :label)
                 (or (vectorp label)
                     (and (listp label)
                          (not (eglotx--json-object-p label)))))
        (setq copy
              (plist-put
               copy :label
               (if (vectorp label)
                   (vconcat
                    (mapcar (lambda (part)
                              (eglotx--tag-command-object
                               server backend part uri))
                            (append label nil)))
                 (mapcar (lambda (part)
                           (eglotx--tag-command-object
                            server backend part uri))
                         label)))))
      copy)))

(defun eglotx--tag-inline-completion-result (server backend value uri)
  "Namespace commands in BACKEND inline-completion VALUE through SERVER.
URI is the source document associated with every returned item.  Preserve the
protocol's InlineCompletionItem array and InlineCompletionList object shapes."
  (cond
   ((vectorp value)
    (vconcat
     (mapcar (lambda (item)
               (eglotx--tag-command-object server backend item uri))
             (append value nil))))
   ((eglotx--json-object-p value)
    (if (not (plist-member value :items))
        value
      (let ((copy (copy-sequence value))
            (items (plist-get value :items)))
        (plist-put
         copy :items
         (cond
          ((vectorp items)
           (vconcat
            (mapcar (lambda (item)
                      (eglotx--tag-command-object
                       server backend item uri))
                    (append items nil))))
          ((and (listp items) (not (eglotx--json-object-p items)))
           (mapcar (lambda (item)
                     (eglotx--tag-command-object server backend item uri))
                   items))
          (t items))))))
   ((listp value)
    (mapcar (lambda (item)
              (eglotx--tag-command-object server backend item uri))
            value))
   (t value)))

(defun eglotx--code-action-documentation-commands (options)
  "Return raw command IDs in CodeAction OPTIONS documentation."
  (when (and (listp options) (plist-member options :documentation))
    (cl-loop
     for item in (eglotx--sequence-list (plist-get options :documentation))
     for object = (and (listp item) (plist-get item :command))
     for command = (and (listp object) (plist-get object :command))
     when (stringp command)
     collect command)))

(defun eglotx--tag-code-action-documentation
    (server backend documentation)
  "Namespace BACKEND commands in CodeAction DOCUMENTATION through SERVER."
  (let (result)
    (dolist (item (eglotx--sequence-list documentation))
      (unless (eglotx--json-object-p item)
        (jsonrpc-error "CodeAction documentation entries must be objects"))
      (let* ((command-object (plist-get item :command))
             (command (and (eglotx--json-object-p command-object)
                           (plist-get command-object :command))))
        (unless (stringp command)
          (jsonrpc-error
           "CodeAction documentation commands must contain string IDs"))
        (setq result
              (nconc
               result
               (list
                (eglotx--tag-command-object
                 server backend item nil))))))
    (vconcat result)))

(defun eglotx--restore-command-object (server backend object)
  "Restore command identifiers in OBJECT owned by BACKEND within SERVER."
  (if (not (listp object))
      object
    (let ((copy (copy-sequence object))
          (command (plist-get object :command))
          (label (plist-get object :label)))
      (cond
       ((stringp command)
        (when-let* ((owner (gethash command (eglotx--command-owners server)))
                    ((eq backend (eglotx--owner-backend owner))))
          (setq copy (plist-put copy :command
                                (eglotx--owner-command owner)))))
       ((consp command)
        (setq copy
              (plist-put copy :command
                         (eglotx--restore-command-object
                          server backend command)))))
      (when (and (plist-member object :label)
                 (or (vectorp label)
                     (and (listp label)
                          (not (eglotx--json-object-p label)))))
        (setq copy
              (plist-put
               copy :label
               (if (vectorp label)
                   (vconcat
                    (mapcar (lambda (part)
                              (eglotx--restore-command-object
                               server backend part))
                            (append label nil)))
                 (mapcar (lambda (part)
                           (eglotx--restore-command-object
                            server backend part))
                         label)))))
      copy)))

(defun eglotx--retag-completion-batch-item
    (server backend object uri commands-p token)
  "Update compact completion TOKEN from resolved OBJECT, or return nil."
  (when-let* ((location (eglotx--completion-batch-location server token))
              (batch (car location))
              (index (cdr location))
              (segment (eglotx--completion-segment-at batch index))
              ((eq backend (eglotx--completion-segment-backend segment))))
    (let ((copy (copy-sequence object)))
      ;; CompletionItem.data is the child routing cookie preserved across
      ;; completion and resolve.  A resolve response may omit unchanged
      ;; fields, so only an explicit value (including JSON null) replaces it.
      (when (plist-member object :data)
        (let ((overrides
               (or (eglotx--completion-segment-data segment)
                   (setf (eglotx--completion-segment-data segment)
                         (make-vector
                          (- (eglotx--completion-segment-end segment)
                             (eglotx--completion-segment-start segment))
                          eglotx--missing-value)))))
          (aset overrides (- index (eglotx--completion-segment-start segment))
                (plist-get object :data))))
      (setq copy (plist-put copy :data token))
      (if commands-p
          (eglotx--tag-completion-command server backend copy object uri)
        copy))))

(defun eglotx--tag-owned-object
    (server backend object kind uri commands-p
            &optional existing-token existing-owner)
  "Attach BACKEND ownership in SERVER to OBJECT for KIND and URI.
When COMMANDS-P is non-nil, namespace any command nested in the object.
EXISTING-TOKEN rotates a resolve result in place without growing ownership.
EXISTING-OWNER preserves child data when a resolve response omits it after its
original compact batch has already left the retention ring."
  (if (not (listp object))
      object
    (or (and existing-token
             (eglotx--retag-completion-batch-item
              server backend object uri commands-p existing-token))
        (let* ((copy (copy-sequence object))
               (object-data-p (plist-member object :data))
               (present (or object-data-p
                            (and existing-owner
                                 (eglotx--owner-data-present-p
                                  existing-owner))))
               (data (if object-data-p
                         (plist-get object :data)
                       (and existing-owner
                            (eglotx--owner-data existing-owner))))
               (token (or existing-token (eglotx--new-token server "data")))
               (document (eglotx--document-for-uri server uri))
               (owner (eglotx--owner-create
                       :backend backend :kind kind
                       :data (and present data)
                       :data-present-p (and present t)
                       :source (and (eq kind 'diagnostic)
                                    (plist-get object :source))
                       :source-present-p
                       (and (eq kind 'diagnostic)
                            (plist-member object :source)
                            t)
                       :uri uri
                       :generation (and document
                                        (eglotx--document-generation
                                         document)))))
          (if existing-token
              (progn
                (eglotx--store-owner-token server token owner)
                (if document
                    (if (eq kind 'diagnostic)
                        (eglotx--owner-cache-insert
                         server (eglotx--document-token-cache document) token)
                      (eglotx--owner-cache-insert
                       server (eglotx--document-owner-ring document) token))
                  (eglotx--owner-cache-insert
                   server (eglotx--orphan-owner-ring server) token))
                (setq copy (plist-put copy :data token)))
            (setq copy (plist-put copy :data
                                  (eglotx--remember-token
                                   server token owner uri))))
          (if commands-p
              (eglotx--tag-command-object server backend copy uri)
            copy)))))

(defun eglotx--restore-owned-object (server backend object)
  "Restore OBJECT's opaque data when it belongs to BACKEND in SERVER."
  (if-let* ((token (and (listp object) (plist-get object :data)))
            (owner (eglotx--owner-for-token server token))
            ((eglotx--owner-current-p server owner))
            ((eq backend (eglotx--owner-backend owner))))
      (let ((copy
             (if (eglotx--owner-data-present-p owner)
                 (plist-put (copy-sequence object) :data
                            (copy-tree (eglotx--owner-data owner)))
               (eglotx--plist-delete object :data))))
        (if (eq (eglotx--owner-kind owner) 'diagnostic)
            (if (eglotx--owner-source-present-p owner)
                (plist-put copy :source
                           (copy-tree (eglotx--owner-source owner)))
              (eglotx--plist-delete copy :source))
          copy))
    object))

(defun eglotx--restore-owned-params (server backend params)
  "Restore ownership tokens from SERVER in PARAMS for BACKEND."
  (let ((result (if (listp params) (copy-sequence params) params)))
    (when (listp result)
      (setq result (eglotx--restore-owned-object server backend result))
      (dolist (key '(:item :callee :caller))
        (when-let* ((item (plist-get result key)))
          (setq result
                (plist-put result key
                           (eglotx--restore-owned-object
                            server backend item))))))
    result))

(defun eglotx--filter-code-action-diagnostics (server backend params)
  "Keep and restore BACKEND diagnostics from SERVER in code-action PARAMS."
  (if-let* ((context (plist-get params :context))
            (diagnostics (plist-get context :diagnostics)))
      (let ((kept
             (cl-loop for diagnostic across diagnostics
                      for token = (and (listp diagnostic)
                                       (plist-get diagnostic :data))
                      for candidate = (and token
                                           (eglotx--owner-for-token
                                            server token))
                      for owner = (and candidate
                                       (eglotx--owner-current-p
                                        server candidate)
                                       candidate)
                      when (or (and owner
                                    (eq backend
                                        (eglotx--owner-backend owner)))
                               (and (null owner)
                                    (not (eglotx--session-token-p
                                          server token))))
                      collect (eglotx--restore-owned-object
                               server backend diagnostic)))
            (copy (copy-sequence params))
            (context-copy (copy-sequence context)))
        (setq context-copy (plist-put context-copy :diagnostics (vconcat kept)))
        (plist-put copy :context context-copy))
    params))

(defun eglotx--force-utf16-initialize (server params)
  "Return initialize PARAMS for SERVER restricted to UTF-16 positions."
  (let* ((copy (copy-tree params))
         (capabilities (copy-sequence (or (plist-get copy :capabilities) nil)))
         (general (copy-sequence (or (plist-get capabilities :general) nil)))
         (text-document
          (copy-sequence (or (plist-get capabilities :textDocument) nil)))
         (completion
          (copy-sequence (or (plist-get text-document :completion) nil)))
         (completion-list
          (copy-sequence (or (plist-get completion :completionList) nil))))
    (when (and (eglotx--stream-diagnostics-p server)
               (listp (plist-get text-document :diagnostic)))
      (setq text-document
            (plist-put
             text-document :diagnostic
             (plist-put
              (copy-sequence (plist-get text-document :diagnostic))
              :dynamicRegistration :json-false))))
    ;; The facade implements the two defaults needed for Tailwind's compact
    ;; wire path.  Data stays behind a shared ownership handle.  Edit ranges
    ;; also stay shared when the client accepts resolve-time `textEdit', with
    ;; eager per-item materialization retained as the compatibility fallback.
    (setq completion-list
          (plist-put completion-list :itemDefaults
                     ["data" "editRange"])
          completion
          (plist-put completion :completionList completion-list)
          text-document (plist-put text-document :completion completion)
          general (plist-put general :positionEncodings ["utf-16"])
          text-document
          (eglotx--plist-delete text-document :$streamingDiagnostics)
          capabilities (plist-put capabilities :general general)
          capabilities (plist-put capabilities :textDocument text-document)
          copy (plist-put copy :capabilities capabilities))
    copy))

(defun eglotx--transform-initialize (server backend params)
  "Tailor initialize PARAMS for BACKEND through SERVER."
  (let* ((copy (eglotx--force-utf16-initialize server params))
         (base (plist-get copy :initializationOptions))
         (options (eglotx--backend-overlay
                   (eglotx--backend-initialization-options backend) base)))
    (if (or options (plist-member copy :initializationOptions))
        (plist-put copy :initializationOptions options)
      copy)))

(defun eglotx--transform-command-params (server backend params)
  "Restore namespaced execute-command PARAMS for BACKEND using SERVER."
  (if-let* ((command (plist-get params :command))
            (owner (gethash command (eglotx--command-owners server)))
            ((eq backend (eglotx--owner-backend owner))))
      (plist-put (copy-sequence params) :command
                 (eglotx--owner-command owner))
    params))

(defun eglotx--transform-client-params (server backend method params)
  "Use SERVER to transform client PARAMS for BACKEND and METHOD."
  (pcase method
    (:initialize (eglotx--transform-initialize server backend params))
    (:textDocument/diagnostic
     (eglotx--transform-document-diagnostic-params server backend params))
    (:workspace/executeCommand
     (eglotx--transform-command-params server backend params))
    (:textDocument/codeAction
     (eglotx--filter-code-action-diagnostics server backend params))
    ((or :completionItem/resolve :codeAction/resolve :codeLens/resolve
         :documentLink/resolve :inlayHint/resolve :workspaceSymbol/resolve
         :callHierarchy/incomingCalls :callHierarchy/outgoingCalls
         :typeHierarchy/supertypes :typeHierarchy/subtypes)
     (let ((restored (eglotx--restore-owned-params server backend params)))
       (if (plist-get (eglotx--policy method) :commands)
           (eglotx--restore-command-object server backend restored)
         restored)))
    (_ params)))

(defun eglotx--transform-client-progress-tokens
    (server backend request params)
  "Map SERVER progress tokens in PARAMS for BACKEND and own them by REQUEST."
  ;; Partial values bypass method-specific merge, ownership, and command
  ;; transformation even with one target, so request complete results only.
  (if (not (listp params))
      params
    (let ((copy (eglotx--plist-delete params :partialResultToken)))
      (if (> (length (eglotx--request-targets request)) 1)
          ;; Multiple work-done lifecycles cannot share one client token.
          (eglotx--plist-delete copy :workDoneToken)
        (when (and (plist-member params :workDoneToken)
                   (plist-get params :workDoneToken))
          (let* ((facade-token (plist-get params :workDoneToken))
                 (forward (eglotx--backend-progress-forward backend))
                 (reverse (eglotx--backend-progress-reverse backend))
                 child-token)
            (unless (or (stringp facade-token) (integerp facade-token))
              (jsonrpc-error "workDoneToken must be a string or integer"))
            (when (gethash facade-token reverse)
              (jsonrpc-error "workDoneToken %S is already active"
                             facade-token))
            (while (or (null child-token) (gethash child-token forward))
              (setq child-token
                    (eglotx--new-token server "child-progress")))
            (puthash child-token facade-token forward)
            (puthash facade-token child-token reverse)
            (push (list backend child-token facade-token)
                  (eglotx--request-progress-mappings request))
            (setq copy (plist-put copy :workDoneToken child-token))))
        copy))))

(defun eglotx--end-progress (server backend child-token facade-token)
  "End active CHILD-TOKEN progress from BACKEND on SERVER at FACADE-TOKEN."
  (when (gethash child-token (eglotx--backend-progress-active backend))
    (remhash child-token (eglotx--backend-progress-active backend))
    (unless (memq (eglotx--state server) '(stopping dead))
      (funcall
       (jsonrpc--notification-dispatcher server)
       server '$/progress
       (list :token facade-token :value
             (list :kind "end" :message "Language server request ended"))))))

(defun eglotx--release-request-progress (server request)
  "End and release every progress mapping owned by REQUEST in SERVER."
  (dolist (mapping (eglotx--request-progress-mappings request))
    (pcase-let ((`(,backend ,child-token ,facade-token) mapping))
      (let ((forward (eglotx--backend-progress-forward backend))
            (reverse (eglotx--backend-progress-reverse backend)))
        (eglotx--end-progress server backend child-token facade-token)
        (when (equal (gethash child-token forward) facade-token)
          (remhash child-token forward))
        (when (equal (gethash facade-token reverse) child-token)
          (remhash facade-token reverse)))))
  (setf (eglotx--request-progress-mappings request) nil))

(defun eglotx--compile-static-selectors (capabilities)
  "Compile initialize-time document selectors from CAPABILITIES."
  (let ((selectors (make-hash-table :test #'eq)))
    (dolist (entry eglotx--document-selector-method-map)
      (let* ((capability (car entry))
             (provider (plist-get capabilities capability)))
        (when (and (listp provider)
                   (plist-member provider :documentSelector))
          (puthash capability
                   (eglotx--compile-document-selector
                    (plist-get provider :documentSelector))
                   selectors))))
    selectors))

(defun eglotx--namespace-progress (server backend token)
  "Create an opaque SERVER work-done token for BACKEND TOKEN.
TOKEN must be unique on the child connection."
  (let ((forward (eglotx--backend-progress-forward backend))
        (reverse (eglotx--backend-progress-reverse backend)))
    (unless (or (stringp token) (integerp token))
      (jsonrpc-error "ProgressToken must be a string or integer"))
    (when (gethash token forward)
      (jsonrpc-error "ProgressToken %S is already active" token))
    (let ((value (eglotx--new-token server "progress")))
      ;; Never stringify TOKEN here: integer 1 and string "1" are distinct
      ;; legal LSP ProgressTokens and must remain independently routable.
      (puthash token value forward)
      (puthash value token reverse)
      value)))

(defun eglotx--bounded-sequence-list (value limit label)
  "Return JSON sequence VALUE as a proper list bounded by LIMIT.
Use LABEL in protocol errors."
  (cond
   ((vectorp value)
    (when (> (length value) limit)
      (jsonrpc-error "%s exceeds the %d-entry limit" label limit))
    (append value nil))
   ((and (listp value) (not (eglotx--json-object-p value)))
    (let ((tail value)
          (count 0)
          entries)
      ;; Walk only one element past the bound.  Do not call `length' on a child
      ;; list whose size is controlled by an external server.
      (while (and (consp tail) (<= count limit))
        (push (car tail) entries)
        (setq tail (cdr tail))
        (cl-incf count))
      (when (> count limit)
        (jsonrpc-error "%s exceeds the %d-entry limit" label limit))
      (when tail
        (jsonrpc-error "%s must be a proper array" label))
      (nreverse entries)))
   (t
    (jsonrpc-error "%s must be an array" label))))

(defun eglotx--bounded-document-selector (selector)
  "Return SELECTOR filters as a bounded proper list."
  (eglotx--bounded-sequence-list
   selector eglotx-document-selector-limit "DocumentSelector"))

(defun eglotx--restrict-document-selector
    (backend method options)
  "Intersect BACKEND's language restriction with METHOD OPTIONS."
  (let ((languages (eglotx--backend-languages backend))
        (key (eglotx--method-key method)))
    (if (or (null languages)
            (not (string-prefix-p ":textDocument/" (symbol-name key))))
        options
      (let* ((selector (and (listp options)
                            (plist-get options :documentSelector)))
             (sequence-p
              (or (null selector)
                  (vectorp selector)
                  (and (listp selector)
                       (not (eglotx--json-object-p selector)))))
             (count 0)
             restricted)
        (cl-labels
            ((add-filter
              (filter)
              (when (>= count eglotx-document-selector-limit)
                (jsonrpc-error
                 "Restricted DocumentSelector exceeds the %d-filter limit"
                 eglotx-document-selector-limit))
              (push filter restricted)
              (cl-incf count)))
          (cond
           ((null selector)
            (dolist (language languages)
              (add-filter (list :language language))))
           ((or (vectorp selector)
                (and (listp selector)
                     (not (eglotx--json-object-p selector))))
            (dolist (filter (eglotx--bounded-document-selector selector))
              (if (not (eglotx--json-object-p filter))
                  ;; Preserve malformed input so the normal selector compiler
                  ;; reports the protocol error below this transformation.
                  (add-filter filter)
                (let ((language (plist-get filter :language)))
                  (cond
                   ((null language)
                    (dolist (accepted languages)
                      (add-filter
                       (plist-put (copy-sequence filter)
                                  :language accepted))))
                   ((and (stringp language)
                         (gethash language
                                  (eglotx--backend-language-table backend)))
                    (add-filter (copy-sequence filter)))
                   ((not (stringp language))
                    (add-filter filter)))))))
           (t
            ;; Leave a malformed non-sequence selector intact for validation.
            (setq restricted selector)))
          (plist-put options :documentSelector
                     (if sequence-p
                         (vconcat (nreverse restricted))
                       restricted)))))))

(defun eglotx--uri-to-path (server uri)
  "Convert URI for SERVER to a local or remote path."
  ;; Eglot consults this dynamic binding to recover a TRAMP prefix when called
  ;; outside a managed source buffer.
  (let ((eglot--cached-server server))
    (or
     (condition-case nil
         (eglot-uri-to-path uri)
       (error nil))
     ;; Raw test facades and constructor-time registrations do not yet have
     ;; Eglot's project slot.  Decode file URIs directly and recover any TRAMP
     ;; prefix from the project directory we captured at construction.
     (when (and (stringp uri)
                (string-match "\\`file://\\([^/]*\\)\\(.*\\)\\'" uri))
       (let* ((host (match-string 1 uri))
              (path (url-unhex-string (match-string 2 uri)))
              (local (if (string-empty-p host)
                         path
                       (concat "//" host path)))
              (remote (file-remote-p (eglotx--project-directory server))))
         (concat remote local)))
     (error "Cannot convert LSP URI %S" uri))))

(defun eglotx--compile-document-selector (selector)
  "Compile an LSP document SELECTOR into a vector of filters.
Nil means the protocol's universal null selector."
  (if (null selector)
      'eglotx--universal-selector
    (unless (or (vectorp selector)
                (and (listp selector)
                     (not (eglotx--json-object-p selector))))
      (jsonrpc-error "The documentSelector must be an array or null"))
    (vconcat
     (mapcar
      (lambda (filter)
        (unless (eglotx--json-object-p filter)
          (jsonrpc-error "DocumentSelector entries must be objects"))
        (when (plist-member filter :notebook)
          (jsonrpc-error "Notebook document filters are not multiplexed"))
        (let ((language (plist-get filter :language))
              (scheme (plist-get filter :scheme))
              (pattern (plist-get filter :pattern)))
          (unless (or (null language) (stringp language))
            (jsonrpc-error "Invalid documentSelector language"))
          (unless (or (null scheme) (stringp scheme))
            (jsonrpc-error "Invalid documentSelector scheme"))
          (unless (or (null pattern) (stringp pattern))
            (jsonrpc-error "Invalid documentSelector pattern"))
          (eglotx--document-filter-create
           :language language :scheme scheme
           :predicate (and pattern (eglot--glob-compile pattern t t)))))
      (eglotx--bounded-document-selector selector)))))

(defun eglotx--uri-scheme (uri)
  "Return URI's lowercase scheme, or nil."
  (when (and (stringp uri) (string-match "\\`\\([^:/]+\\):" uri))
    (downcase (match-string 1 uri))))

(defun eglotx--document-filter-matches-p (server filter uri language-id)
  "Return non-nil when FILTER matches URI and LANGUAGE-ID for SERVER."
  (and (or (null (eglotx--document-filter-language filter))
           (equal (eglotx--document-filter-language filter) language-id))
       (or (null (eglotx--document-filter-scheme filter))
           (equal (downcase (eglotx--document-filter-scheme filter))
                  (eglotx--uri-scheme uri)))
       (or (null (eglotx--document-filter-predicate filter))
           (condition-case nil
               (let* ((path (eglotx--uri-to-path server uri))
                      (relative
                       (eglotx--relative-candidate
                        path (eglotx--project-directory server))))
                 (or (funcall (eglotx--document-filter-predicate filter) path)
                     (and relative
                          (funcall
                           (eglotx--document-filter-predicate filter)
                           relative))))
             (error nil)))))

(defun eglotx--document-selector-matches-p (server selector params)
  "Return non-nil when compiled SELECTOR matches request PARAMS in SERVER."
  (if (eq selector 'eglotx--universal-selector)
      t
    (let* ((uri (or (and (listp params) (eglotx--params-uri params))
                    (when-let* ((owner
                                 (eglotx--owner-for-params server params)))
                      (eglotx--owner-uri owner))))
           (document (and uri (eglotx--document-for-uri server uri)))
           (language-id (and document
                             (eglotx--document-language-id document))))
      (and uri
           (seq-some
            (lambda (filter)
              (eglotx--document-filter-matches-p
               server filter uri language-id))
            selector)))))

(defun eglotx--normalize-file-watcher (watcher)
  "Return WATCHER detached and reduced to its defined LSP fields."
  (unless (eglotx--json-object-p watcher)
    (jsonrpc-error "Invalid workspace/didChangeWatchedFiles watcher"))
  (let* ((glob (plist-get watcher :globPattern))
         (relative-p (and (eglotx--json-object-p glob)
                          (plist-member glob :pattern)))
         (pattern (if relative-p (plist-get glob :pattern) glob))
         (base-uri (and relative-p (plist-get glob :baseUri)))
         (uri (if (eglotx--json-object-p base-uri)
                  (plist-get base-uri :uri)
                base-uri))
         (kind (or (plist-get watcher :kind) 7)))
    (unless (and (stringp pattern)
                 (integerp kind)
                 (>= kind 0)
                 (or (not relative-p) (stringp uri)))
      (jsonrpc-error "Invalid workspace/didChangeWatchedFiles watcher"))
    (list :globPattern
          (if relative-p
              (list :baseUri (copy-sequence uri)
                    :pattern (copy-sequence pattern))
            (copy-sequence pattern))
          :kind kind)))

(defun eglotx--compile-file-watcher (server watcher)
  "Compile one LSP file WATCHER for SERVER into an `eglotx--watcher'."
  (let* ((glob (plist-get watcher :globPattern))
         (relative-p (and (listp glob) (plist-member glob :pattern)))
         (pattern (if relative-p (plist-get glob :pattern) glob))
         (base-uri (and relative-p (plist-get glob :baseUri)))
         (uri (if (listp base-uri) (plist-get base-uri :uri) base-uri))
         (kind (or (plist-get watcher :kind) 7)))
    (unless (and (stringp pattern) (integerp kind) (>= kind 0))
      (jsonrpc-error "Invalid workspace/didChangeWatchedFiles watcher"))
    (eglotx--watcher-create
     :predicate (eglot--glob-compile pattern t t)
     :base-path (and uri
                     (file-name-as-directory
                      (eglotx--uri-to-path server uri)))
     :kind kind)))

(defun eglotx--physical-file-watcher (server watcher)
  "Return a string-glob watcher equivalent to WATCHER for SERVER.
Eglot 29 and 30 cannot compile LSP RelativePattern objects directly."
  (let* ((glob (plist-get watcher :globPattern))
         (relative-p (and (listp glob) (plist-member glob :pattern))))
    (list
     :globPattern
     (if (not relative-p)
         glob
       (let* ((base-uri (plist-get glob :baseUri))
              (uri (if (listp base-uri) (plist-get base-uri :uri) base-uri))
              (base (and uri (file-name-as-directory
                              (eglotx--uri-to-path server uri))))
              (project (file-name-as-directory
                        (eglotx--project-directory server)))
              (pattern (plist-get glob :pattern))
              (relative (and base
                             (eglotx--relative-candidate base project))))
         (unless (and relative (stringp pattern))
           (jsonrpc-error
            "Relative watched-file pattern must be inside the project"))
         (if (member relative '("." "./"))
             pattern
           (concat (file-name-as-directory relative) pattern))))
     :kind (or (plist-get watcher :kind) 7))))

(defun eglotx--file-watcher-less-p (left right)
  "Return non-nil when physical watcher LEFT sorts before RIGHT."
  (let ((left-glob (plist-get left :globPattern))
        (right-glob (plist-get right :globPattern)))
    (if (equal left-glob right-glob)
        (< (plist-get left :kind) (plist-get right :kind))
      (string< left-glob right-glob))))

(defun eglotx--collect-file-watch-state
    (server &optional staged-backend staged-registrations)
  "Return (WATCHERS . SELECTORS) for SERVER logical registrations.
When STAGED-BACKEND is non-nil, use STAGED-REGISTRATIONS for that backend."
  (let ((selectors (make-hash-table :test #'eq))
        (physical-seen (make-hash-table :test #'equal))
        (watcher-count 0)
        watchers)
    (dolist (backend (eglotx--backends server))
      (when (and (eglotx--backend-running-p backend)
                 (eglotx--backend-allows-p
                  backend :workspace/didChangeWatchedFiles))
        (let (backend-selectors)
          (maphash
           (lambda (_id registration)
             (when (eq (car registration)
                       :workspace/didChangeWatchedFiles)
               (seq-doseq (watcher (plist-get (cdr registration) :watchers))
                 (when (>= watcher-count eglotx-file-watcher-limit)
                   (jsonrpc-error
                    "Watched-file registrations exceed the %d-pattern limit"
                    eglotx-file-watcher-limit))
                 (cl-incf watcher-count)
                 (push (eglotx--compile-file-watcher server watcher)
                       backend-selectors)
                 (let ((physical
                        (eglotx--physical-file-watcher server watcher)))
                   (unless (gethash physical physical-seen)
                     (puthash physical t physical-seen)
                     (push physical watchers))))))
           (if (eq backend staged-backend)
               staged-registrations
             (eglotx--backend-registration-methods backend)))
          (when backend-selectors
            (puthash backend (nreverse backend-selectors) selectors)))))
    (cons (vconcat (sort watchers #'eglotx--file-watcher-less-p))
          selectors)))

(defun eglotx--rebuild-file-watches (server)
  "Reconcile SERVER's logical watchers with one physical Eglot watcher."
  (pcase-let* ((`(,watchers . ,selectors)
                (eglotx--collect-file-watch-state server))
               (old (eglotx--watch-registration-watchers server)))
    (if (and (eglotx--watch-registration-active-p server)
             (equal watchers old))
        (setf (eglotx--watch-selectors server) selectors)
      (when (eglotx--watch-registration-active-p server)
        (eglot-unregister-capability
         server 'workspace/didChangeWatchedFiles
         (eglotx--watch-registration-id server))
        (setf (eglotx--watch-registration-active-p server) nil
              (eglotx--watch-registration-watchers server) nil))
      (when (> (length watchers) 0)
        (unless (eglotx--watch-registration-id server)
          (setf (eglotx--watch-registration-id server)
                (eglotx--new-token server "file-watchers")))
        (let ((eglot--cached-server server))
          (eglot-register-capability
           server 'workspace/didChangeWatchedFiles
           (eglotx--watch-registration-id server) :watchers watchers))
        (setf (eglotx--watch-registration-active-p server) t
              (eglotx--watch-registration-watchers server)
              (copy-tree watchers)))
      (setf (eglotx--watch-selectors server) selectors))))

(defun eglotx--run-file-watch-rebuild (server)
  "Reconcile SERVER file watches and retry a failed upstream projection."
  (setf (eglotx--watch-rebuild-queued-p server) nil)
  (unless (memq (eglotx--state server) '(stopping dead failed))
    (condition-case err
        (progn
          (eglotx--rebuild-file-watches server)
          (setf (eglotx--watch-rebuild-retry-delay server)
                eglotx--file-watch-retry-base-delay))
      (error
       (let ((delay (eglotx--watch-rebuild-retry-delay server)))
         (setf (eglotx--watch-rebuild-retry-delay server)
               (min eglotx--file-watch-retry-max-delay (* 2 delay))
               (eglotx--watch-rebuild-retry-timer server)
               (run-with-timer
                delay nil #'eglotx--retry-file-watch-rebuild server))
         (display-warning
          'eglotx
          (format "File-watch reconciliation failed; retrying in %.2fs: %s"
                  delay (error-message-string err))
          :warning))))))

(defun eglotx--retry-file-watch-rebuild (server)
  "Requeue a failed file-watch reconciliation for SERVER."
  (setf (eglotx--watch-rebuild-retry-timer server) nil)
  (eglotx--schedule-file-watch-rebuild server t))

(defun eglotx--schedule-file-watch-rebuild (server &optional retry-p)
  "Schedule one coalesced file-watch reconciliation for SERVER.
RETRY-P preserves the current retry delay; new desired state retries now."
  (unless (memq (eglotx--state server) '(stopping dead failed))
    (unless retry-p
      (when-let* ((timer (eglotx--watch-rebuild-retry-timer server))
                  ((timerp timer)))
        (cancel-timer timer))
      (setf (eglotx--watch-rebuild-retry-timer server) nil
            (eglotx--watch-rebuild-retry-delay server)
            eglotx--file-watch-retry-base-delay))
    (unless (eglotx--watch-rebuild-queued-p server)
      (setf (eglotx--watch-rebuild-queued-p server) t)
      (eglotx--enqueue-work server #'eglotx--run-file-watch-rebuild server))))

(defun eglotx--remove-file-watches (server)
  "Remove SERVER's physical Eglot watcher registration."
  (when-let* ((timer (eglotx--watch-rebuild-retry-timer server))
              ((timerp timer)))
    (cancel-timer timer))
  (when (eglotx--watch-registration-active-p server)
    (eglot-unregister-capability
     server 'workspace/didChangeWatchedFiles
     (eglotx--watch-registration-id server)))
  (setf (eglotx--watch-registration-active-p server) nil
        (eglotx--watch-registration-watchers server) nil
        (eglotx--watch-rebuild-queued-p server) nil
        (eglotx--watch-rebuild-retry-timer server) nil
        (eglotx--watch-rebuild-retry-delay server)
        eglotx--file-watch-retry-base-delay)
  (clrhash (eglotx--watch-selectors server)))

(defun eglotx--registration-entries (params register-p)
  "Return PARAMS entries for a registration request.
REGISTER-P selects registration rather than unregistration, including the
historical LSP misspelling accepted by Eglot."
  (let ((key (if register-p
                 :registrations
               (if (plist-member params :unregisterations)
                   :unregisterations
                 :unregistrations))))
    (eglotx--bounded-sequence-list
     (plist-get params key) eglotx-file-watcher-limit
     (if register-p "Registrations" "Unregistrations"))))

(defun eglotx--handle-registration-request
    (server backend params register-p)
  "Apply BACKEND's watched-files registration PARAMS through SERVER.
Eglot advertises dynamic registration only for watched files.  Reject every
other method instead of maintaining state the consuming client cannot use."
  (let* ((staged
          (copy-hash-table (eglotx--backend-registration-methods backend)))
         (seen (make-hash-table :test #'equal))
         (watcher-count 0))
    ;; Existing live registrations already satisfy the facade-wide invariant.
    ;; Count every backend, substituting this transaction's staged table, so
    ;; each incoming registration is rejected before normalizing child-owned
    ;; watcher objects that would exceed the retained cap.
    (when register-p
      (dolist (candidate (eglotx--backends server))
        (when (and (eglotx--backend-running-p candidate)
                   (eglotx--backend-allows-p
                    candidate :workspace/didChangeWatchedFiles))
          (maphash
           (lambda (_id registration)
             (when (eq (car registration)
                       :workspace/didChangeWatchedFiles)
               (cl-incf watcher-count
                        (length
                         (plist-get (cdr registration) :watchers)))))
           (if (eq candidate backend)
               staged
             (eglotx--backend-registration-methods candidate)))))
      (when (> watcher-count eglotx-file-watcher-limit)
        (jsonrpc-error
         "Watched-file registrations exceed the %d-pattern limit"
         eglotx-file-watcher-limit)))
    (dolist (entry (eglotx--registration-entries params register-p))
      (let* ((id (plist-get entry :id))
             (raw-method (plist-get entry :method))
             (method (and raw-method (eglotx--method-key raw-method)))
             (active (and (stringp id) (gethash id staged))))
        (unless (stringp id)
          (jsonrpc-error "Registration IDs must be strings"))
        (unless (eq method :workspace/didChangeWatchedFiles)
          (jsonrpc-error
           "Eglot did not negotiate dynamic registration for %s"
           (or method raw-method)))
        (when (gethash id seen)
          (jsonrpc-error "Duplicate registration ID %s" id))
        (puthash id t seen)
        (if register-p
            (progn
              (when active
                (jsonrpc-error "Registration ID %s is already active" id))
              (unless (eglotx--backend-allows-p backend method)
                (jsonrpc-error "Backend method %s is excluded by :only"
                               method))
              (let ((options (plist-get entry :registerOptions)))
                (unless (eglotx--json-object-p options)
                  (jsonrpc-error
                   "Watched-files registration needs registerOptions"))
                (let ((watchers
                       (eglotx--bounded-sequence-list
                        (plist-get options :watchers)
                        eglotx-file-watcher-limit "Watchers")))
                  (unless watchers
                    (jsonrpc-error
                     "Watched-files registration needs at least one watcher"))
                  (when (> (+ watcher-count (length watchers))
                           eglotx-file-watcher-limit)
                    (jsonrpc-error
                     "Watched-file registrations exceed the %d-pattern limit"
                     eglotx-file-watcher-limit))
                  (cl-incf watcher-count (length watchers))
                  ;; Retain only the option path used by routing and copy that
                  ;; bounded path so no child-owned JSON is retained later.
                  (puthash id
                           (cons method
                                 (list :watchers
                                       (vconcat
                                        (mapcar
                                         #'eglotx--normalize-file-watcher
                                         watchers))))
                           staged))))
          (unless active
            (jsonrpc-error "Unknown watched-files registration ID %s" id))
          (remhash id staged))))
    ;; Compile every staged logical watcher before committing.  Physical Eglot
    ;; registration can enumerate a whole project, so run that upstream work
    ;; after the child receives its response rather than in this callback.
    (let ((state
           (eglotx--collect-file-watch-state server backend staged)))
      (setf (eglotx--backend-registration-methods backend) staged
            (eglotx--watch-selectors server) (cdr state))
      (eglotx--schedule-file-watch-rebuild server)
      nil)))


(defun eglotx--semantic-refresh-owner-p (server backend)
  "Return non-nil when BACKEND owns SERVER's semantic-token refresh."
  (and (eglotx--backend-running-p backend)
       (seq-some
        (lambda (method)
          (eq (gethash method (eglotx--singleton-providers server)) backend))
        eglotx--semantic-token-methods)))

(defun eglotx--forward-semantic-refresh (server backend)
  "Forward a selected BACKEND semantic-token refresh through SERVER."
  (unwind-protect
      (when (and (not (memq (eglotx--state server)
                            '(stopping dead failed)))
                 (eglotx--semantic-refresh-owner-p server backend))
        (condition-case err
            (funcall (jsonrpc--request-dispatcher server)
                     server 'workspace/semanticTokens/refresh nil)
          (error
           (display-warning
            'eglotx
            (format "Could not forward semantic-token refresh: %s"
                    (error-message-string err))
            :warning))))
    (setf (eglotx--semantic-refresh-pending-p server) nil)))

(defun eglotx--handle-semantic-refresh-request (server backend)
  "Schedule BACKEND's semantic-token refresh through SERVER when selected."
  (when (and (eglotx--semantic-refresh-owner-p server backend)
             (not (eglotx--semantic-refresh-pending-p server)))
    ;; Eglot may walk every managed buffer while handling this request.  The
    ;; child receives its void response immediately; upstream work runs on the
    ;; bounded facade FIFO instead of inside the JSON-RPC callback.  A single
    ;; pending bit collapses a burst because refresh invalidates all prior
    ;; semantic-token state regardless of how many children requested it.
    (setf (eglotx--semantic-refresh-pending-p server) t)
    (condition-case err
        (eglotx--enqueue-work
         server #'eglotx--forward-semantic-refresh server backend)
      (error
       (setf (eglotx--semantic-refresh-pending-p server) nil)
       (signal (car err) (cdr err)))))
  nil)

(defun eglotx--transform-backend-request (server backend method params)
  "Namespace request PARAMS from BACKEND for SERVER facade METHOD."
  (pcase (eglotx--method-key method)
    (:window/workDoneProgress/create
     (plist-put (copy-sequence params) :token
                (eglotx--namespace-progress
                 server backend (plist-get params :token))))
    (_ params)))

(defun eglotx--transform-configuration-response (backend response)
  "Apply BACKEND settings overlay to workspace/configuration RESPONSE."
  (let ((settings (eglotx--backend-settings backend)))
    (if (and settings (vectorp response))
        (vconcat
         (mapcar (lambda (item)
                   (eglotx--backend-overlay settings item))
                 (append response nil)))
      response)))

(defun eglotx--dispatch-backend-request
    (server backend connection method params)
  "Dispatch one child request while preserving its connection-scoped ID.
SERVER and BACKEND own CONNECTION.  METHOD and PARAMS are the values decoded
by jsonrpc.el.  A matching `$/cancelRequest' marks only this active handler
and becomes LSP's RequestCancelled response.  The deepest handler can unwind
immediately; a nested outer handler converts its result at this boundary."
  (let* ((envelope eglotx--child-request-envelope)
         (child-id (and (eq (car-safe envelope) connection)
                        (cadr envelope))))
    ;; Calls made directly through the dispatcher on older/custom jsonrpc.el
    ;; builds have no raw envelope.  Preserve their historical behavior.
    (if (null child-id)
        (eglotx--handle-backend-request server backend method params)
      (unless (or (integerp child-id) (stringp child-id))
        (jsonrpc-error :code -32600 :message "Invalid JSON-RPC request ID"))
      (let* ((active (eglotx--child-active-inbound-requests connection))
             (tag (make-symbol "eglotx-inbound-request"))
             (request (eglotx--inbound-request-create
                       :id child-id :tag tag))
             outcome)
        ;; A remote endpoint must not reuse an ID until its request completes.
        ;; Refuse a nested duplicate instead of replacing the cancellation
        ;; target of the request already running on this connection.
        (when (gethash child-id active)
          (jsonrpc-error :code -32600
                         :message "Duplicate active JSON-RPC request ID"))
        (puthash child-id request active)
        (unwind-protect
            (setq outcome
                  (catch tag
                    (list
                     :completed
                     (let ((eglotx--current-inbound-request request))
                       (eglotx--handle-backend-request
                        server backend method params)))))
          (when (eq (gethash child-id active) request)
            (remhash child-id active)))
        (if (or (eq outcome eglotx--inbound-request-cancelled)
                (eglotx--inbound-request-cancelled-p request))
            (jsonrpc-error :code -32800 :message "Request cancelled")
          (cadr outcome))))))

(defun eglotx--cancel-active-backend-request (connection params)
  "Cancel the exact active child request named by PARAMS on CONNECTION.
Unknown, completed, malformed, and sibling-scoped IDs are consumed without
affecting any facade request or other child connection."
  (when (and (listp params) (plist-member params :id))
    (let ((child-id (plist-get params :id)))
      (when (or (integerp child-id) (stringp child-id))
        (when-let* ((request
                     (gethash
                      child-id
                      (eglotx--child-active-inbound-requests connection))))
          (setf (eglotx--inbound-request-cancelled-p request) t)
          ;; Throwing an outer request's tag through a nested request would
          ;; destroy the nested response.  Only the deepest handler may be
          ;; unwound immediately; an outer request observes its cancellation
          ;; flag when control eventually returns to its own boundary.
          (when (eq request eglotx--current-inbound-request)
            (throw (eglotx--inbound-request-tag request)
                   eglotx--inbound-request-cancelled))))))
  nil)

(defun eglotx--handle-backend-request (server backend method params)
  "Handle METHOD request with PARAMS from BACKEND through SERVER."
  (eglotx--seal-pending-diagnostics server)
  (let* ((key (eglotx--method-key method))
         (facade-method (intern (substring (symbol-name key) 1))))
    (cond
      ((eq key :client/registerCapability)
       (eglotx--handle-registration-request server backend params t))
      ((eq key :client/unregisterCapability)
       (eglotx--handle-registration-request server backend params nil))
      ((eq key :workspace/semanticTokens/refresh)
       (eglotx--handle-semantic-refresh-request server backend))
      (t
       (let* ((progress-create-p
               (eq key :window/workDoneProgress/create))
              (original-token (and progress-create-p
                                   (plist-get params :token)))
              (forward (and progress-create-p
                            (eglotx--backend-progress-forward backend)))
              (missing (make-symbol "missing"))
              (old (and forward (gethash original-token forward missing)))
              (transformed
               (eglotx--transform-backend-request server backend key params))
              (facade-token (and progress-create-p
                                 (plist-get transformed :token))))
         (let (committed result)
           (unwind-protect
               (progn
                 (setq result
                       (let ((response
                              (funcall
                               (jsonrpc--request-dispatcher server)
                               server facade-method transformed)))
                         (if (eq key :workspace/configuration)
                             (eglotx--transform-configuration-response
                              backend response)
                           response)))
                 (setq committed t)
                 result)
             ;; Roll back only mappings created by this request.  An existing
             ;; progress token belongs to an earlier accepted create request.
             ;; `unwind-protect' covers quit/throw as well as ordinary errors.
             (when (and (not committed) progress-create-p (eq old missing)
                        (equal (gethash original-token forward) facade-token))
               (remhash original-token forward)
               (when (equal
                      (gethash facade-token
                               (eglotx--backend-progress-reverse backend))
                      original-token)
                 (remhash facade-token
                          (eglotx--backend-progress-reverse backend)))))))))))

;; Document synchronization and notifications.

(defun eglotx--utf16-width (character)
  "Return the UTF-16 code-unit width of CHARACTER."
  (if (> character #xffff) 2 1))

(defun eglotx--position-index (text position)
  "Translate UTF-16 LSP POSITION into a character index in TEXT."
  (let ((line (or (plist-get position :line) 0))
        (column (or (plist-get position :character) 0))
        (index 0)
        (length (length text)))
    (dotimes (_ line)
      (let ((newline (string-search "\n" text index)))
        (unless newline
          (signal 'eglotx-error '("LSP position is beyond document end")))
        (setq index (1+ newline))))
    (let ((units 0))
      (while (< units column)
        (when (or (>= index length) (eq (aref text index) ?\n))
          (signal 'eglotx-error '("LSP character is beyond line end")))
        (cl-incf units (eglotx--utf16-width (aref text index)))
        (cl-incf index))
      (unless (= units column)
        (signal 'eglotx-error '("LSP position splits a UTF-16 surrogate pair"))))
    index))

(defun eglotx--apply-content-change (text change)
  "Apply one LSP content CHANGE to TEXT and return the result."
  (if-let* ((range (plist-get change :range)))
      (let ((start (eglotx--position-index text (plist-get range :start)))
            (end (eglotx--position-index text (plist-get range :end))))
        (concat (substring text 0 start)
                (or (plist-get change :text) "")
                (substring text end)))
    (or (plist-get change :text) "")))

(defun eglotx--apply-content-changes (text changes)
  "Apply LSP content CHANGES sequentially to TEXT."
  (seq-reduce #'eglotx--apply-content-change (append changes nil) text))

(defun eglotx--sync-kind (backend &optional server params)
  "Return BACKEND's initialize-time TextDocumentSyncKind."
  (if (and server
           (not (eglotx--backend-accepts-params-p
                 server backend :textDocument/didChange params)))
      0
    (let ((sync (eglotx--backend-text-sync backend)))
      (cond ((integerp sync) sync)
            ((listp sync) (or (plist-get sync :change) 0))
            (t 0)))))

(defun eglotx--sync-open-close-p (backend method &optional server params)
  "Return non-nil when BACKEND wants METHOD for optional SERVER PARAMS."
  (and (or (null server)
           (eglotx--backend-accepts-params-p server backend method params))
       (let ((sync (eglotx--backend-text-sync backend)))
         (cond ((integerp sync) (> sync 0))
               ((listp sync)
                (not (eglotx--json-false-p
                      (plist-get sync :openClose))))))))

(defun eglotx--sync-save (backend &optional server params)
  "Return BACKEND's initialize-time save option for SERVER PARAMS."
  (when (or (null server)
            (eglotx--backend-accepts-params-p
             server backend :textDocument/didSave params))
    (let ((sync (eglotx--backend-text-sync backend)))
      (when (and (listp sync) (plist-member sync :save))
        (let ((save (plist-get sync :save)))
          (cond ((eq save :json-false) nil)
                ((null save) t)
                (t save)))))))

(defun eglotx--sync-will-save-p (backend method &optional server params)
  "Return non-nil when BACKEND wants METHOD for optional SERVER PARAMS."
  (and (or (null server)
           (eglotx--backend-accepts-params-p server backend method params))
       (let ((sync (eglotx--backend-text-sync backend)))
         (and (listp sync)
              (not (eglotx--json-false-p
                    (plist-get sync :willSave)))))))

(defun eglotx--notify-backend
    (server backend method params params-present-p)
  "Notify running BACKEND of METHOD through SERVER.
Send PARAMS when PARAMS-PRESENT-P is non-nil; otherwise omit them."
  (when (and (eglotx--backend-running-p backend)
             (eglotx--backend-allows-p backend method)
             (eglotx--backend-accepts-params-p
              server backend method params))
    (jsonrpc-notify (eglotx--backend-connection backend) method
                    (if params-present-p
                        params
                      :jsonrpc-omit))))

(defun eglotx--broadcast-notification (server method params params-present-p)
  "Broadcast METHOD and PARAMS to every running SERVER backend."
  (dolist (backend (eglotx--backends server))
    (eglotx--notify-backend
     server backend method params params-present-p)))

(defun eglotx--relative-candidate (path directory)
  "Return PATH relative to DIRECTORY, or nil when PATH is outside it."
  (let ((relative (file-relative-name path directory)))
    (unless (or (file-name-absolute-p relative)
                (equal relative "..")
                (string-prefix-p "../" relative))
      relative)))

(defun eglotx--watcher-matches-change-p (server watcher change)
  "Return non-nil when SERVER WATCHER selects one file CHANGE."
  (condition-case nil
      (let* ((type (plist-get change :type))
             (bit (and (integerp type) (<= 1 type) (<= type 3)
                       (ash 1 (1- type))))
             (path (and bit
                        (eglotx--uri-to-path
                         server (plist-get change :uri))))
             (base (eglotx--watcher-base-path watcher))
             (predicate (eglotx--watcher-predicate watcher)))
        (and path
             (> (logand (eglotx--watcher-kind watcher) bit) 0)
             (if base
                 (when-let* ((candidate
                              (eglotx--relative-candidate path base)))
                   (funcall predicate candidate))
               (or (funcall predicate path)
                   (when-let* ((candidate
                                (eglotx--relative-candidate
                                 path (eglotx--project-directory server))))
                     (funcall predicate candidate))))))
    (error nil)))

(defun eglotx--route-watched-files (server method params)
  "Route watched-file METHOD and PARAMS only to matching SERVER owners."
  (let ((changes (or (plist-get params :changes) [])))
    (dolist (backend (eglotx--backends server))
      (when-let* ((selectors (gethash backend (eglotx--watch-selectors server))))
        (let (matching)
          (seq-doseq (change changes)
            (when (seq-some
                   (lambda (watcher)
                     (eglotx--watcher-matches-change-p
                      server watcher change))
                   selectors)
              (push change matching)))
          (when matching
            (eglotx--notify-backend
             server backend method
             (plist-put (copy-sequence params) :changes
                        (vconcat (nreverse matching)))
             t)))))))

(defun eglotx--route-workspace-notification
    (server method params singleton-p)
  "Route workspace METHOD with PARAMS to capable SERVER backends.
When SINGLETON-P is non-nil, notify only the negotiated highest-priority
provider for that operation."
  (let* ((backends
          (eglotx--available-backends server method :workspace params))
         (pinned (and singleton-p
                      (gethash (eglotx--method-key method)
                               (eglotx--singleton-providers server))))
         (targets (if singleton-p
                      (and (memq pinned backends) (list pinned))
                    backends)))
    (dolist (backend targets)
      (eglotx--notify-backend server backend method params t))))

(defun eglotx--route-pinned-notification (server method params)
  "Route METHOD with PARAMS to its negotiated singleton in SERVER."
  (when-let* ((backend
               (gethash (eglotx--method-key method)
                        (eglotx--singleton-providers server)))
              ((eglotx--backend-running-p backend))
              ((eglotx--backend-allows-p backend method))
              (provider
               (plist-get (eglotx--backend-capabilities backend)
                          :notebookDocumentSync))
              ((eglotx--truthy-p provider))
              ((or (not (eq (eglotx--method-key method)
                            :notebookDocument/didSave))
                   (and (listp provider)
                        (eglotx--truthy-p (plist-get provider :save))))))
    (eglotx--notify-backend server backend method params t)))

(defun eglotx--visiting-buffer (server uri)
  "Return the live buffer visiting URI for SERVER, or nil."
  (condition-case nil
      (when-let* ((path (eglotx--uri-to-path server uri))
                  (buffer (find-buffer-visiting path))
                  ((buffer-live-p buffer)))
        buffer)
    (error nil)))

(defun eglotx--visiting-buffer-text (server uri)
  "Return current text of the buffer visiting URI for SERVER, or nil."
  (when-let* ((buffer (eglotx--visiting-buffer server uri)))
    (condition-case nil
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (buffer-substring-no-properties (point-min) (point-max))))
    (error nil))))

(defun eglotx--note-document-mutation (server uri)
  "Record one document-lifecycle mutation for SERVER URI and return its epoch."
  (let* ((identity (eglotx--canonical-document-uri server uri))
         (epoch (cl-incf (eglotx--document-mutation-epoch server))))
    (puthash identity epoch (eglotx--document-mutation-epochs server))
    epoch))


(defun eglotx--did-open (server method params)
  "Track and forward didOpen METHOD with PARAMS through SERVER."
  (let* ((wire-document (plist-get params :textDocument))
         (uri (plist-get wire-document :uri))
         (identity (eglotx--canonical-document-uri server uri))
         (old (eglotx--document-for-uri server uri))
         (generation (if old (1+ (eglotx--document-generation old)) 0))
         (document
          (eglotx--document-create
           :uri uri :version (plist-get wire-document :version)
           :generation generation
           :language-id (plist-get wire-document :languageId)
           ;; Eglot's live visiting buffer is authoritative.  Keeping the
           ;; didOpen payload as well would double resident text for every
           ;; managed file, especially costly for large full-sync documents.
           :text (and (not (eglotx--visiting-buffer server uri))
                      (or (plist-get wire-document :text) ""))
           :owner-ring
           (eglotx--owner-cache-create
            :limit eglotx-document-owner-limit
            :nodes (make-hash-table :test #'equal))
           :completion-ring
           (make-ring eglotx-completion-batch-limit))))
    (eglotx--note-document-mutation server identity)
    (when-let* ((removed-node
                 (eglotx--forget-uri-diagnostic-tokens
                  server identity old))
                ((eglotx--diagnostic-uri-node-projected-p removed-node)))
      ;; Eglot copies list-only diagnostics into the newly visiting buffer but
      ;; otherwise retains the old unopened alist cell until server shutdown.
      (eglotx--prune-eglot-list-only-diagnostic server identity t))
    (when old
      (eglotx--forget-document-tokens server old)
      (remhash (eglotx--document-uri old) (eglotx--documents server))
      (let ((old-identity
             (eglotx--canonical-document-uri
              server (eglotx--document-uri old))))
        (when (eq (gethash old-identity
                           (eglotx--document-identities server))
                  old)
          (remhash old-identity (eglotx--document-identities server)))))
    (puthash uri document (eglotx--documents server))
    (puthash identity document (eglotx--document-identities server))
    (dolist (backend (eglotx--backends server))
      (when (eglotx--sync-open-close-p backend method server params)
        (eglotx--notify-backend server backend method params t)))))

(defun eglotx--did-change (server method params)
  "Track and adapt didChange METHOD and PARAMS for SERVER backends."
  (let* ((text-document (plist-get params :textDocument))
         (uri (plist-get text-document :uri))
         (identity (eglotx--canonical-document-uri server uri))
         (document (eglotx--document-for-uri server uri))
         (changes (plist-get params :contentChanges))
         (routes
          (cl-loop for backend in (eglotx--backends server)
                   when (and (eglotx--backend-running-p backend)
                             (eglotx--backend-allows-p backend method)
                             (eglotx--backend-accepts-params-p
                              server backend method params))
                   collect
                   (cons backend (eglotx--sync-kind backend server params))))
         (full-p (seq-some (lambda (route) (= (cdr route) 1)) routes))
         (buffer-text (and full-p
                           (eglotx--visiting-buffer-text server uri)))
         (full-text
          (and full-p document
               (or buffer-text
                   (and (eglotx--document-text document)
                        (eglotx--apply-content-changes
                         (eglotx--document-text document) changes))))))
    (eglotx--note-document-mutation server identity)
    (when document
      (eglotx--forget-uri-diagnostic-tokens server identity document)
      (eglotx--forget-document-tokens server document)
      (setf (eglotx--document-text document)
            ;; A visiting Eglot buffer is authoritative and can be read again
            ;; on demand.  Retain a private string only for headless clients.
            (and (null buffer-text) full-text)
            (eglotx--document-version document)
            (plist-get text-document :version)
            (eglotx--document-generation document)
            (1+ (eglotx--document-generation document))))
    (dolist (route routes)
      (let ((backend (car route)))
        (pcase (cdr route)
          (1
           (when full-text
             (let ((copy (copy-sequence params)))
               (setq copy
                     (plist-put copy :contentChanges
                                (vector
                                 (list :text full-text))))
               (eglotx--notify-backend server backend method copy t))))
          (2 (eglotx--notify-backend
              server backend method params t)))))))

(defun eglotx--did-close (server method params)
  "Forward didClose METHOD with PARAMS and release SERVER document state."
  (let* ((uri (eglotx--params-uri params))
         (identity (eglotx--canonical-document-uri server uri)))
    (eglotx--note-document-mutation server identity)
    (dolist (backend (eglotx--backends server))
      (when (eglotx--sync-open-close-p backend method server params)
        (eglotx--notify-backend server backend method params t)))
    (when-let* ((document (eglotx--document-for-uri server uri)))
      (eglotx--forget-uri-diagnostic-tokens server identity document)
      (eglotx--forget-document-tokens server document)
      (remhash (eglotx--document-uri document) (eglotx--documents server))
      (when (eq (gethash identity (eglotx--document-identities server))
                document)
        (remhash identity (eglotx--document-identities server))))))

(defun eglotx--did-save (server method params)
  "Forward didSave METHOD and PARAMS per SERVER backend sync options."
  (dolist (backend (eglotx--backends server))
    (let ((save (eglotx--sync-save backend server params)))
      (unless (eglotx--json-false-p save)
        (eglotx--notify-backend
         server backend method
         (if (and (listp save)
                  (not (eglotx--json-false-p
                        (plist-get save :includeText))))
             params
           (eglotx--plist-delete params :text))
         t)))))

(defun eglotx--will-save (server method params)
  "Forward will-save METHOD and PARAMS to requesting SERVER backends."
  (dolist (backend (eglotx--backends server))
    (when (eglotx--sync-will-save-p backend method server params)
      (eglotx--notify-backend server backend method params t))))

(defun eglotx--did-change-configuration (server method params)
  "Apply SERVER settings before forwarding configuration METHOD and PARAMS."
  (dolist (backend (eglotx--backends server))
    (let* ((copy (copy-sequence params))
           (settings
            (eglotx--backend-overlay
             (eglotx--backend-settings backend)
             (plist-get params :settings))))
      (eglotx--notify-backend server backend method
                              (plist-put copy :settings settings) t))))

(defun eglotx--cancel-progress (server method params)
  "Route namespaced progress cancellation METHOD and PARAMS through SERVER."
  (let ((token (plist-get params :token)))
    (dolist (backend (eglotx--backends server))
      (when-let* ((original
                   (gethash token (eglotx--backend-progress-reverse backend))))
        (eglotx--notify-backend
         server backend method
         (plist-put (copy-sequence params) :token original) t)))))

(defun eglotx--dispatch-notification
    (server method params params-present-p)
  "Dispatch client notification METHOD and PARAMS from SERVER."
  (let ((key (eglotx--method-key method)))
    (pcase key
      (:$/cancelRequest
       (when (and (listp params) (plist-member params :id))
         (eglotx--cancel-request server (plist-get params :id) t)))
      (:textDocument/didOpen (eglotx--did-open server key params))
      (:textDocument/didChange (eglotx--did-change server key params))
      (:textDocument/didClose (eglotx--did-close server key params))
      (:textDocument/didSave (eglotx--did-save server key params))
      (:textDocument/willSave (eglotx--will-save server key params))
      (:workspace/didChangeConfiguration
       (eglotx--did-change-configuration server key params))
      (:workspace/didChangeWatchedFiles
       (eglotx--route-watched-files server key params))
      (:workspace/didChangeWorkspaceFolders
       (eglotx--route-workspace-notification server key params nil))
      ((or :workspace/didCreateFiles :workspace/didRenameFiles
           :workspace/didDeleteFiles)
       (eglotx--route-workspace-notification server key params t))
      ((or :notebookDocument/didOpen :notebookDocument/didChange
           :notebookDocument/didSave :notebookDocument/didClose)
       (eglotx--route-pinned-notification server key params))
      (:window/workDoneProgress/cancel
       (eglotx--cancel-progress server key params))
      (:initialized
       (eglotx--broadcast-notification server key params params-present-p)
       (dolist (backend (eglotx--backends server))
         (when (eq (eglotx--backend-state backend) 'running)
           (setf (eglotx--backend-state backend) 'ready))))
      (_
       (eglotx--broadcast-notification
        server key params params-present-p)))))

(defun eglotx--prefix-message (backend params)
  "Prefix message in PARAMS with BACKEND's name."
  (if (and eglotx-prefix-server-messages
           (stringp (plist-get params :message)))
      (plist-put (copy-sequence params) :message
                 (format "[%s] %s" (eglotx--backend-name backend)
                         (plist-get params :message)))
    params))

(defun eglotx--transform-progress-notification (server backend params)
  "Translate a known work-done progress token in BACKEND PARAMS.
Unknown, malformed, late, and out-of-order notifications are consumed."
  (ignore server)
  (when (and (listp params) (plist-member params :token))
    (let* ((original (plist-get params :token))
           (forward (eglotx--backend-progress-forward backend))
           (reverse (eglotx--backend-progress-reverse backend))
           (active (eglotx--backend-progress-active backend))
           (facade-token
            (and (or (stringp original) (integerp original))
                 (gethash original forward)))
           (value (plist-get params :value))
           (kind (and (listp value) (plist-get value :kind))))
      (when (and facade-token
                 (eglotx--work-done-progress-value-p value kind))
        (pcase kind
          ("begin"
           (unless (gethash original active)
             (puthash original facade-token active)
             (plist-put (copy-sequence params) :token facade-token)))
          ("report"
           (when (gethash original active)
             (plist-put (copy-sequence params) :token facade-token)))
          ("end"
           (if (not (gethash original active))
               ;; An accepted create followed by an invalid terminal message
               ;; must not leak its connection-scoped mapping forever.
               (progn
                 (remhash original forward)
                 (when (equal (gethash facade-token reverse) original)
                   (remhash facade-token reverse))
                 nil)
             (remhash original active)
             (remhash original forward)
             (when (equal (gethash facade-token reverse) original)
               (remhash facade-token reverse))
             (plist-put (copy-sequence params) :token facade-token))))))))

(defun eglotx--work-done-progress-value-p (value kind)
  "Return whether VALUE is a valid WorkDoneProgress payload of KIND."
  (cl-labels
      ((optional-string-p
        (key)
        (or (not (plist-member value key))
            (stringp (plist-get value key))))
       (optional-boolean-p
        (key)
        (or (not (plist-member value key))
            (memq (plist-get value key) '(t :json-false))))
       (optional-percentage-p
        ()
        (or (not (plist-member value :percentage))
            (let ((percentage (plist-get value :percentage)))
              (and (integerp percentage)
                   (<= 0 percentage) (<= percentage 100))))))
    (and (eglotx--json-object-p value)
         (pcase kind
           ("begin"
            (and (stringp (plist-get value :title))
                 (optional-boolean-p :cancellable)
                 (optional-string-p :message)
                 (optional-percentage-p)))
           ("report"
            (and (optional-boolean-p :cancellable)
                 (optional-string-p :message)
                 (optional-percentage-p)))
           ("end" (optional-string-p :message))
           (_ nil)))))

(defun eglotx--diagnostic-source (backend diagnostic)
  "Return a copy of DIAGNOSTIC attributed to BACKEND."
  (let* ((copy (copy-sequence diagnostic))
         (source (plist-get copy :source))
         (name (eglotx--backend-name backend)))
    (plist-put copy :source (if (and source (not (string-empty-p source)))
                                (format "%s/%s" name source)
                              name))))

(defun eglotx--position-p (value)
  "Return non-nil when VALUE is a structurally valid LSP Position."
  (and (eglotx--json-object-p value)
       (plist-member value :line)
       (plist-member value :character)
       (integerp (plist-get value :line))
       (>= (plist-get value :line) 0)
       (integerp (plist-get value :character))
       (>= (plist-get value :character) 0)))

(defun eglotx--range-p (value)
  "Return non-nil when VALUE is a structurally valid LSP Range."
  (and (eglotx--json-object-p value)
       (eglotx--position-p (plist-get value :start))
       (eglotx--position-p (plist-get value :end))))

(defun eglotx--diagnostic-related-information-p (value)
  "Return non-nil when VALUE is valid DiagnosticRelatedInformation."
  (let ((location (and (eglotx--json-object-p value)
                       (plist-get value :location))))
    (and (eglotx--json-object-p location)
         (stringp (plist-get location :uri))
         (eglotx--range-p (plist-get location :range))
         (stringp (plist-get value :message)))))

(defun eglotx--validate-diagnostics (value)
  "Return VALUE as a safe LSP Diagnostic array, or signal a protocol error.
Validation happens before snapshot ownership is mutated, so a malformed child
cannot invalidate the preceding valid snapshot or leak partially tagged data."
  (let ((diagnostics value))
    ;; Both a missing field and JSON null decode to nil.  Neither is the
    ;; required empty JSON array, which is represented by `[]'.
    (unless (vectorp diagnostics)
      (signal 'eglotx-error '("LSP diagnostics must be a JSON array")))
    (seq-doseq (diagnostic diagnostics)
      (unless (and (eglotx--json-object-p diagnostic)
                   (eglotx--range-p (plist-get diagnostic :range))
                   (stringp (plist-get diagnostic :message))
                   (or (not (plist-member diagnostic :source))
                       (null (plist-get diagnostic :source))
                       (stringp (plist-get diagnostic :source)))
                   (or (not (plist-member diagnostic :severity))
                       (null (plist-get diagnostic :severity))
                       (and (integerp (plist-get diagnostic :severity))
                            (<= 1 (plist-get diagnostic :severity) 4)))
                   (or (not (plist-member diagnostic :tags))
                       (null (plist-get diagnostic :tags))
                       (and (vectorp (plist-get diagnostic :tags))
                            (seq-every-p
                             #'integerp (plist-get diagnostic :tags))))
                   (or (not (plist-member diagnostic :relatedInformation))
                       (null (plist-get diagnostic :relatedInformation))
                       (and
                        (vectorp (plist-get diagnostic :relatedInformation))
                        (seq-every-p
                         #'eglotx--diagnostic-related-information-p
                         (plist-get diagnostic :relatedInformation)))))
        (signal 'eglotx-error '("Malformed LSP Diagnostic object"))))
    diagnostics))

(defun eglotx--validate-publish-diagnostics-params (params)
  "Return PARAMS diagnostics after validating its required wire shape."
  (unless (and (eglotx--json-object-p params)
               (plist-member params :uri)
               (stringp (plist-get params :uri))
               (plist-member params :diagnostics)
               (vectorp (plist-get params :diagnostics))
               (or (not (plist-member params :version))
                   (integerp (plist-get params :version))))
    (signal 'eglotx-error '("Malformed PublishDiagnosticsParams object")))
  (plist-get params :diagnostics))

(defun eglotx--tag-diagnostics (server backend diagnostics uri)
  "Attribute and stash DIAGNOSTICS from BACKEND for URI in SERVER."
  (vconcat
   (cl-loop for diagnostic across diagnostics
            for owned = (eglotx--tag-owned-object
                         server backend diagnostic 'diagnostic uri nil)
            collect (eglotx--diagnostic-source backend owned))))

(defun eglotx--diagnostic-token-key (backend uri &optional modality)
  "Return snapshot key for BACKEND, URI, and diagnostic MODALITY."
  (list (eglotx--backend-id backend) uri (or modality 'push)))

(defun eglotx--note-diagnostic-key (server key)
  "Index SERVER diagnostic KEY under its owning backend."
  (when-let* ((backend (eglotx--backend-by-id server (car key))))
    (eglotx--ledger-add (eglotx--backend-ledger backend 'diagnostic) key)))

(defun eglotx--forget-diagnostic-token-keys (server keys _document)
  "Release SERVER diagnostic tokens under KEYS.
Every token has an exact owner-container node, so removing many independent
sources never rescans a document-wide list."
  (dolist (key keys)
    (when-let* ((tokens (gethash key (eglotx--diagnostic-tokens server))))
      (dolist (token tokens)
        (eglotx--forget-owner-token server token)))
    (remhash key (eglotx--diagnostic-tokens server))))

(defun eglotx--forget-diagnostic-token-key (server key document)
  "Release SERVER diagnostic tokens under KEY, updating DOCUMENT if present."
  (eglotx--forget-diagnostic-token-keys server (list key) document))

(defun eglotx--forget-diagnostic-tokens
    (server backend uri document &optional modality)
  "Release SERVER diagnostic tokens for BACKEND and URI.
Update DOCUMENT when present, selecting the snapshot by optional MODALITY."
  (eglotx--forget-diagnostic-token-key
   server (eglotx--diagnostic-token-key backend uri modality) document))

(defun eglotx--unlink-diagnostic-uri-node (server node &optional remove-p)
  "Detach NODE from SERVER's diagnostic URI LRU.
When REMOVE-P is non-nil, also remove its URI lookup entry."
  (let ((previous (eglotx--diagnostic-uri-node-previous node))
        (next (eglotx--diagnostic-uri-node-next node)))
    (if previous
        (setf (eglotx--diagnostic-uri-node-next previous) next)
      (setf (eglotx--diagnostic-uri-head server) next))
    (if next
        (setf (eglotx--diagnostic-uri-node-previous next) previous)
      (setf (eglotx--diagnostic-uri-tail server) previous))
    (setf (eglotx--diagnostic-uri-node-previous node) nil
          (eglotx--diagnostic-uri-node-next node) nil)
    (when remove-p
      (remhash (eglotx--diagnostic-uri-node-uri node)
               (eglotx--diagnostic-uri-nodes server)))))

(defun eglotx--remove-diagnostic-uri-node (server uri)
  "Remove URI from SERVER's unopened diagnostic LRU, if present."
  (let* ((canonical (eglotx--canonical-document-uri server uri))
         (node (gethash canonical (eglotx--diagnostic-uri-nodes server))))
    (when node
      (eglotx--unlink-diagnostic-uri-node server node t)
      node)))

(defun eglotx--prune-eglot-list-only-diagnostic (server uri &optional any-p)
  "Remove SERVER's exact unopened URI entry from Eglot/Flymake state.
Normally remove only an empty retraction cell.  ANY-P also removes a visible
cell after Eglot has transferred it into a newly opened buffer."
  (when (boundp 'flymake-list-only-diagnostics)
    (when-let* ((path
                 (ignore-errors
                   (expand-file-name (eglot-uri-to-path uri)))))
      ;; Eglot's unopened push handler uses `alist-get' with REMOVE=nil, so an
      ;; empty retraction otherwise leaves one permanent (PATH . nil) cell.
      (setq flymake-list-only-diagnostics
            (cl-delete-if
             (lambda (entry)
               (let ((key (car-safe entry)))
                 (and (or any-p (null (cdr-safe entry)))
                      (stringp key)
                      (equal path (substring-no-properties key))
                      (eq server
                          (get-text-property 0 'eglot--server key)))))
             flymake-list-only-diagnostics)))))

(defun eglotx--evict-unopened-diagnostic-uri (server node)
  "Evict NODE and retract its visible diagnostics from SERVER's client."
  (let ((uri (eglotx--diagnostic-uri-node-uri node))
        (projected-p (eglotx--diagnostic-uri-node-projected-p node)))
    (eglotx--unlink-diagnostic-uri-node server node t)
    ;; A lifecycle notification should already have detached an open URI.  If
    ;; one races with admission, never let the memory bound clear live state.
    (unless (eglotx--document-for-uri server uri)
      (eglotx--forget-uri-diagnostic-tokens server uri nil)
      (when (and projected-p
                 (not (memq (eglotx--state server) '(stopping dead))))
        (condition-case err
            (progn
              (funcall (jsonrpc--notification-dispatcher server)
                       server 'textDocument/publishDiagnostics
                       (list :uri uri :diagnostics []))
              (eglotx--prune-eglot-list-only-diagnostic server uri))
          (error
           (display-warning
            'eglotx
            (format "Could not retract evicted diagnostics for %s: %s"
                    uri (error-message-string err))
            :warning)))))))

(defun eglotx--touch-unopened-diagnostic-uri (server uri)
  "Mark URI as SERVER's newest unopened diagnostic identity.
Open documents are removed from this memory-bound ledger."
  (let ((canonical (eglotx--canonical-document-uri server uri)))
    (if (eglotx--document-for-uri server canonical)
        (eglotx--remove-diagnostic-uri-node server canonical)
      (let* ((nodes (eglotx--diagnostic-uri-nodes server))
             (node (gethash canonical nodes)))
        (if node
            (unless (eq node (eglotx--diagnostic-uri-head server))
              (eglotx--unlink-diagnostic-uri-node server node)
              (let ((head (eglotx--diagnostic-uri-head server)))
                (setf (eglotx--diagnostic-uri-node-next node) head)
                (when head
                  (setf (eglotx--diagnostic-uri-node-previous head) node))
                (setf (eglotx--diagnostic-uri-head server) node)
                (unless (eglotx--diagnostic-uri-tail server)
                  (setf (eglotx--diagnostic-uri-tail server) node))))
          (setq node (eglotx--diagnostic-uri-node-create :uri canonical))
          (let ((head (eglotx--diagnostic-uri-head server)))
            (setf (eglotx--diagnostic-uri-node-next node) head)
            (when head
              (setf (eglotx--diagnostic-uri-node-previous head) node))
            (setf (eglotx--diagnostic-uri-head server) node)
            (unless (eglotx--diagnostic-uri-tail server)
              (setf (eglotx--diagnostic-uri-tail server) node)))
          (puthash canonical node nodes))
        (while (> (hash-table-count nodes)
                  eglotx-unopened-diagnostic-uri-limit)
          (eglotx--evict-unopened-diagnostic-uri
           server (eglotx--diagnostic-uri-tail server)))
        node))))

(defun eglotx--forget-uri-diagnostic-tokens
    (server uri document)
  "Release diagnostic ownership and snapshots for SERVER URI.
Return the removed unopened-URI node, if any."
  (let ((removed-node (eglotx--remove-diagnostic-uri-node server uri)))
    ;; Closed-document cursors record a nil document identity.  Explicitly
    ;; retire them on every lifecycle boundary so an unopened -> open -> close
    ;; ABA transition cannot make a pre-open result ID valid again.
    (eglotx--invalidate-diagnostic-cursor server uri)
    ;; The fixed-modality key space is bounded by configured backends.
    (let (keys)
      (dolist (backend (eglotx--backends server))
        (dolist (modality '(push pull))
          (push (eglotx--diagnostic-token-key backend uri modality) keys)))
      (eglotx--forget-diagnostic-token-keys server keys document)
      (dolist (key keys)
        (remhash key (eglotx--diagnostic-snapshots server))
        (remhash key (eglotx--diagnostic-version-watermarks server))
        (when-let* ((backend (eglotx--backend-by-id server (car key))))
          (eglotx--ledger-remove
           (eglotx--backend-ledger backend 'diagnostic) key))))
    removed-node))

(defun eglotx--store-diagnostic-snapshot
    (server key diagnostics &optional version)
  "Store non-empty DIAGNOSTICS under KEY and remember numeric VERSION."
  (eglotx--note-diagnostic-key server key)
  (eglotx--touch-unopened-diagnostic-uri server (cadr key))
  (if (> (length diagnostics) 0)
      (puthash key diagnostics (eglotx--diagnostic-snapshots server))
    (remhash key (eglotx--diagnostic-snapshots server)))
  (when (integerp version)
    (let ((previous
           (gethash key (eglotx--diagnostic-version-watermarks server))))
      (when (or (not (integerp previous)) (> version previous))
        (puthash key version
                 (eglotx--diagnostic-version-watermarks server))))))

(defun eglotx--diagnostic-publication-stale-p (server key version)
  "Return whether KEY publication VERSION is older than SERVER's watermark."
  (let ((previous
         (gethash key (eglotx--diagnostic-version-watermarks server)
                  eglotx--missing-value)))
    (and (integerp version)
         (integerp previous)
         (< version previous))))

(defun eglotx--remember-diagnostic-tokens
    (server backend uri diagnostics &optional modality)
  "Store tokenized DIAGNOSTICS in SERVER for BACKEND and URI.
Use optional MODALITY to distinguish independent diagnostic snapshots."
  (let (tokens)
    (seq-doseq (diagnostic diagnostics)
      (when-let* ((token (and (listp diagnostic)
                              (plist-get diagnostic :data)))
                  (owner (gethash token (eglotx--owners server)))
                  ((eq (eglotx--owner-kind owner) 'diagnostic)))
        (push token tokens)))
    (when tokens
      (puthash (eglotx--diagnostic-token-key backend uri modality) tokens
               (eglotx--diagnostic-tokens server)))))

(defun eglotx--aggregate-uri-diagnostics (server uri)
  "Return SERVER push diagnostic snapshots for URI in stable order."
  (let ((remaining eglotx-max-diagnostics) result)
    (cl-labels
        ((append-snapshot
          (key)
          (when (or (null remaining) (> remaining 0))
            (when-let* ((items
                         (gethash key
                                  (eglotx--diagnostic-snapshots server))))
              (let ((part (if remaining (seq-take items remaining) items)))
                (setq result (nconc result (append part nil)))
                (when remaining
                  (cl-decf remaining (length part))))))))
      (dolist (backend (eglotx--backends server))
        ;; A backend negotiated for pull diagnostics does not contribute its
        ;; ordinary publishDiagnostics snapshot.
        (unless (eglotx--backend-pull-diagnostics-p
                 backend server (list :textDocument (list :uri uri)))
          (funcall #'append-snapshot
                   (eglotx--diagnostic-token-key backend uri))))
      (vconcat result))))

(defun eglotx--backend-pull-diagnostics-p (backend &optional server params)
  "Return whether BACKEND owns pull diagnostics for SERVER and PARAMS."
  (and
   (or (null server)
       (eglotx--backend-accepts-params-p
        server backend :textDocument/diagnostic params))
   (eglotx--backend-allows-p backend :textDocument/diagnostic)
   (let ((capabilities (eglotx--backend-capabilities backend)))
     (and (plist-member capabilities :diagnosticProvider)
          (not (eq (plist-get capabilities :diagnosticProvider)
                   :json-false))))))

(defun eglotx--dispatch-aggregate-diagnostics (server params)
  "Dispatch one non-streaming aggregate diagnostic PARAMS through SERVER."
  (let* ((uri (plist-get params :uri))
         (document (eglotx--document-for-uri server uri))
         (node
          (and (null document)
               (gethash uri (eglotx--diagnostic-uri-nodes server))))
         (copy
          (plist-put (copy-sequence params) :diagnostics
                     (eglotx--aggregate-uri-diagnostics server uri)))
         (diagnostics (plist-get copy :diagnostics)))
    (when document
      (setq copy
            (plist-put copy :version
                       (eglotx--document-version document))))
    (unless document
      ;; PublishDiagnosticsParams.version describes an open document version.
      ;; It has no deterministic aggregate meaning for unopened reports from
      ;; independent children, so never let the last child win by arrival.
      (setq copy (eglotx--plist-delete copy :version)))
    ;; Do not create permanent empty `flymake-list-only-diagnostics' entries
    ;; for an unopened URI the client has never seen.  Once visible, send one
    ;; exact clear and remove Eglot's nil alist cell after its handler returns.
    (when (or document
              (> (length diagnostics) 0)
              (and node (eglotx--diagnostic-uri-node-projected-p node)))
      (funcall (jsonrpc--notification-dispatcher server)
               server 'textDocument/publishDiagnostics copy)
      (when node
        (setf (eglotx--diagnostic-uri-node-projected-p node)
              (> (length diagnostics) 0)))
      (when (and (null document) (= (length diagnostics) 0))
        (eglotx--prune-eglot-list-only-diagnostic server uri)))))

(defun eglotx--project-diagnostic-snapshot
    (server backend params &optional defer-aggregate-p)
  "Project one stored BACKEND diagnostic snapshot through SERVER.
PARAMS already names the canonical document identity.  Open managed documents
may use Eglot's tokenized streaming extension; every other client view is a
derived ordinary aggregate.  When DEFER-AGGREGATE-P is non-nil, return PARAMS
instead of dispatching that aggregate so a caller can coalesce by URI."
  (let* ((uri (plist-get params :uri))
         (document (eglotx--document-for-uri server uri))
         (effective-version
          (if (plist-member params :version)
              (plist-get params :version)
            (and document (eglotx--document-version document)))))
    (cond
     ((eglotx--stream-diagnostics-for-uri-p server uri)
      (let ((copy
             (plist-put
              (copy-sequence params) :token
              (format "backend:%s" (eglotx--backend-id backend)))))
        (when effective-version
          (setq copy (plist-put copy :version effective-version)))
        (funcall (jsonrpc--notification-dispatcher server)
                 server '$/streamDiagnostics copy)))
     (defer-aggregate-p params)
     (t (eglotx--dispatch-aggregate-diagnostics server params)))))

(defun eglotx--backend-diagnostic-language-p (server backend params)
  "Return non-nil when BACKEND may publish diagnostic PARAMS on SERVER.
Diagnostics for unopened documents remain eligible because their LSP language
ID is not available to the facade."
  (let* ((uri (and (listp params) (plist-get params :uri)))
         (document (and uri (eglotx--document-for-uri server uri))))
    (or (null (eglotx--backend-languages backend))
        (null document)
        (eglotx--backend-accepts-language-p
         backend (eglotx--document-language-id document)))))

(defun eglotx--publish-diagnostics
    (server backend params &optional defer-aggregate-p validated-p)
  "Handle diagnostic PARAMS from BACKEND through SERVER.
DEFER-AGGREGATE-P updates state but lets a caller coalesce client dispatch.
VALIDATED-P means the queue already validated the complete wire payload."
  (setq params (eglotx--normalize-diagnostic-params server params))
  (when (eglotx--backend-diagnostic-language-p server backend params)
    (let* ((wire-diagnostics
            (if validated-p
                (plist-get params :diagnostics)
              (eglotx--validate-publish-diagnostics-params params)))
           (uri (plist-get params :uri))
           (document (eglotx--document-for-uri server uri))
           (version-present (plist-member params :version))
           (version (plist-get params :version))
           (key (eglotx--diagnostic-token-key backend uri)))
      (unless (or (and document version-present
                       (not (equal version
                                   (eglotx--document-version document))))
                  (and (null document)
                       (eglotx--diagnostic-publication-stale-p
                        server key version)))
        (let ((raw-diagnostics
               (if validated-p
                   wire-diagnostics
                 (eglotx--validate-diagnostics wire-diagnostics))))
          (eglotx--forget-diagnostic-tokens server backend uri document)
          (let* ((diagnostics (eglotx--tag-diagnostics
                               server backend raw-diagnostics uri))
                 (copy (plist-put (copy-sequence params)
                                  :diagnostics diagnostics)))
            (eglotx--remember-diagnostic-tokens
             server backend uri diagnostics)
            ;; Keep a numeric watermark even for an empty clearing
            ;; publication, so an older child message cannot resurrect it.
            (eglotx--store-diagnostic-snapshot
             server key diagnostics version)
            (eglotx--project-diagnostic-snapshot
             server backend copy defer-aggregate-p)))))))

(defun eglotx--seal-pending-diagnostics (server)
  "End SERVER's current contiguous diagnostic coalescing batch."
  (setf (eglotx--pending-diagnostics server) nil))

(defun eglotx--continue-diagnostic-collect (server batch)
  "Continue or finish the collection phase of diagnostic BATCH for SERVER."
  (cond
   ((eglotx--diagnostic-batch-order batch)
    (eglotx--enqueue-yielding-urgent-work
     server #'eglotx--flush-pending-diagnostics server batch))
   ((eglotx--diagnostic-batch-uri-order batch)
    (setf (eglotx--diagnostic-batch-order batch)
          (nreverse (eglotx--diagnostic-batch-uri-order batch))
          (eglotx--diagnostic-batch-uri-order batch) nil
          (eglotx--diagnostic-batch-phase batch) 'dispatch)
    (eglotx--enqueue-yielding-urgent-work
     server #'eglotx--flush-pending-diagnostics server batch))
   (t
    (setf (eglotx--diagnostic-batch-phase batch) 'done))))

(defun eglotx--flush-pending-diagnostics (server batch)
  "Flush one bounded continuation of diagnostic BATCH for SERVER."
  (when (eq batch (eglotx--pending-diagnostics server))
    (setf (eglotx--pending-diagnostics server) nil))
  (unless (eglotx--diagnostic-batch-phase batch)
    (setf (eglotx--diagnostic-batch-order batch)
          (nreverse (eglotx--diagnostic-batch-order batch))
          (eglotx--diagnostic-batch-phase batch) 'collect
          (eglotx--diagnostic-batch-latest-by-uri batch)
          (make-hash-table :test #'equal)))
  (pcase (eglotx--diagnostic-batch-phase batch)
    ('collect
     (let ((remaining eglotx-diagnostic-chunk-size)
           (pending (eglotx--diagnostic-batch-table batch))
           (latest-by-uri
            (eglotx--diagnostic-batch-latest-by-uri batch))
           completed)
       (unwind-protect
           (progn
             (while (and (> remaining 0)
                         (eglotx--diagnostic-batch-order batch))
               (let* ((key (pop (eglotx--diagnostic-batch-order batch)))
                 (entry (gethash key pending)))
                 (remhash key pending)
                 (when entry
                   (let* ((backend
                           (eglotx--diagnostic-publication-backend entry))
                          (params
                           (eglotx--diagnostic-publication-params entry))
                          (queued-document
                           (eglotx--diagnostic-publication-document entry))
                          (queued-generation
                           (eglotx--diagnostic-publication-generation entry))
                          (queued-epoch
                           (eglotx--diagnostic-publication-mutation-epoch
                            entry))
                          (validated-p
                           (eglotx--diagnostic-publication-validated-p entry))
                          (uri (plist-get params :uri))
                          (current-document
                           (eglotx--document-for-uri server uri))
                          (current-generation
                           (and current-document
                                (eglotx--document-generation
                                 current-document)))
                          (exact-lifecycle-p
                           (and
                            (eq queued-document current-document)
                            (equal
                             queued-epoch
                             (gethash
                              uri
                              (eglotx--document-mutation-epochs server)))
                            (or (null queued-document)
                                (= queued-generation current-generation)))))
                     ;; didOpen/didChange/didClose invalidate publications
                     ;; queued against an older document identity.
                     (when (and
                            (memq (eglotx--backend-state backend)
                                  '(running ready))
                            exact-lifecycle-p)
                       ;; Ordinary child faults are isolated per publication.
                       ;; The outer unwind below preserves the remaining queue
                       ;; across every other kind of non-local exit.
                       (condition-case err
                           (if (eglotx--stream-diagnostics-for-uri-p
                                server uri)
                               (eglotx--publish-diagnostics
                                server backend params nil validated-p)
                             (when-let* ((copy
                                          (eglotx--publish-diagnostics
                                           server backend params t
                                           validated-p)))
                               (unless (gethash uri latest-by-uri)
                                 (push
                                  uri
                                  (eglotx--diagnostic-batch-uri-order batch)))
                               (puthash uri copy latest-by-uri)))
                         (error
                          (display-warning
                           'eglotx
                           (format
                            "Ignoring malformed diagnostics from %s: %s"
                            (eglotx--backend-name backend)
                            (error-message-string err))
                           :warning))))))
                 (cl-decf remaining)))
             (setq completed t))
         (unless completed
           (eglotx--continue-diagnostic-collect server batch)))
       (when completed
         (eglotx--continue-diagnostic-collect server batch))))
    ('dispatch
     (let ((remaining eglotx-diagnostic-chunk-size)
           (latest-by-uri
            (eglotx--diagnostic-batch-latest-by-uri batch))
           completed)
       (unwind-protect
           (progn
             (while (and (> remaining 0)
                         (eglotx--diagnostic-batch-order batch))
               (let ((uri (pop (eglotx--diagnostic-batch-order batch))))
                 (when-let* ((params (gethash uri latest-by-uri)))
                   (remhash uri latest-by-uri)
                   (condition-case err
                       (eglotx--dispatch-aggregate-diagnostics server params)
                     (error
                      (display-warning
                       'eglotx
                       (format "Could not publish diagnostics for %s: %s"
                               uri (error-message-string err))
                       :warning)))))
               (cl-decf remaining))
             (setq completed t))
         ;; A quit/throw from client code must not strand later URIs behind
         ;; this notification barrier.
         (when (and (not completed)
                    (eglotx--diagnostic-batch-order batch))
           (eglotx--enqueue-yielding-urgent-work
            server #'eglotx--flush-pending-diagnostics server batch)))
       (when completed
         (if (eglotx--diagnostic-batch-order batch)
             (eglotx--enqueue-yielding-urgent-work
              server #'eglotx--flush-pending-diagnostics server batch)
           (setf (eglotx--diagnostic-batch-phase batch) 'done)))))))

(defun eglotx--queue-diagnostics (server backend params)
  "Queue BACKEND diagnostic PARAMS for one coalesced SERVER dispatch."
  (when (memq (eglotx--backend-state backend) '(running ready))
    (condition-case err
        (progn
          (setq params (eglotx--normalize-diagnostic-params server params))
          (when (eglotx--backend-diagnostic-language-p server backend params)
            (let* ((uri (plist-get params :uri))
                 (document (eglotx--document-for-uri server uri))
                 (batch (or (eglotx--pending-diagnostics server)
                            (let ((created
                                   (eglotx--diagnostic-batch-create
                                    :table
                                    (make-hash-table :test #'eql))))
                              (setf (eglotx--pending-diagnostics server)
                                    created)
                              (eglotx--enqueue-work
                               server #'eglotx--flush-pending-diagnostics
                               server created)
                              created)))
                 (pending (eglotx--diagnostic-batch-table batch))
                 (key (cl-incf (eglotx--diagnostic-batch-next-entry batch))))
            ;; Keep every source publication until deferred validation.  This
            ;; preserves FIFO when a malformed update follows a valid one,
            ;; while URI-level client projection is still coalesced later in
            ;; the bounded collect phase.  The parser-owned payload is not
            ;; copied or scanned inside the process filter.
            (push key (eglotx--diagnostic-batch-order batch))
            (puthash
             key
             (eglotx--diagnostic-publication-create
              :backend backend :params params :document document
              :generation
              (and document (eglotx--document-generation document))
              :mutation-epoch
              (gethash uri (eglotx--document-mutation-epochs server)))
             pending))))
      (error
       (display-warning
        'eglotx
        (format "Ignoring malformed diagnostics from %s: %s"
                (eglotx--backend-name backend)
                (error-message-string err))
        :warning)))))

(defun eglotx--forward-backend-notification-now (server backend method params)
  "Forward ordinary METHOD notification with PARAMS from BACKEND through SERVER."
  (let* ((key (eglotx--method-key method))
         (facade-method (intern (substring (symbol-name key) 1))))
    (pcase key
      (:$/cancelRequest
       ;; The receive path handles active child cancellations synchronously.
       ;; Keep this defensive sink for direct/internal forwarding calls: a raw
       ;; child ID must never reach the Eglot-facing connection.
       nil)
      (:textDocument/publishDiagnostics
       (eglotx--publish-diagnostics server backend params))
      (:$/streamDiagnostics
       ;; This extension was not advertised to child servers.  Keep a
       ;; defensive sink so a non-conforming child cannot leak its source
       ;; token into Eglot's facade connection.
       nil)
      (:$/progress
       (when-let* ((transformed
                    (eglotx--transform-progress-notification
                     server backend params)))
         (funcall (jsonrpc--notification-dispatcher server)
                  server facade-method transformed)))
      ((or :window/logMessage :window/showMessage)
       (funcall (jsonrpc--notification-dispatcher server)
                server facade-method (eglotx--prefix-message backend params)))
      (_
       (funcall (jsonrpc--notification-dispatcher server)
                server facade-method params)))))

(defun eglotx--handle-backend-notification-now (server backend method params)
  "Handle METHOD notification with PARAMS from BACKEND through SERVER."
  (let* ((key (eglotx--method-key method))
         (handlers (eglotx--backend-notification-handlers backend))
         (handler (and handlers (gethash key handlers))))
    (if (not handler)
        (eglotx--forward-backend-notification-now
         server backend key params)
      (condition-case err
          (unless (funcall handler server backend params)
            (eglotx--forward-backend-notification-now
             server backend key params))
        (error
         ;; A declared private protocol method belongs to its adapter even
         ;; when the adapter fails.  Leaking it to Eglot would merely turn a
         ;; local bridge fault into an unrelated client-method error.
         (display-warning
          'eglotx
          (format "Notification handler for %s/%s failed: %s"
                  (eglotx--backend-name backend) key
                  (error-message-string err))
          :error))))))

(defun eglotx--handle-backend-notification
    (server backend connection method params)
  "Handle BACKEND METHOD and PARAMS received through CONNECTION.
Cancellation is handled synchronously because its target is the currently
active child request handler.  Other notifications run on SERVER's bounded
event-loop queue."
  (let* ((key (eglotx--method-key method))
         (handlers (eglotx--backend-notification-handlers backend))
         (custom-p (and handlers (gethash key handlers))))
    (cond
     ((eq key :$/cancelRequest)
      (eglotx--cancel-active-backend-request connection params))
     ((and (not custom-p) (eq key :textDocument/publishDiagnostics))
      ;; Standard push diagnostics enter the lifecycle-aware batch.
      ;; Retain the parser-owned payload: copying or scanning its vector in a
      ;; process filter would double allocation on the hottest notification.
      (eglotx--queue-diagnostics server backend params))
     ((and (not custom-p) (eq key :$/streamDiagnostics))
      ;; The capability is stripped from child initialization.  Ignore
      ;; unsolicited child streams at ingress without allocating queue work.
      nil)
     (t
      (eglotx--seal-pending-diagnostics server)
      ;; Use the same FIFO as diagnostic batches.  This preserves each child
      ;; connection's notification order and keeps handlers and transformation
      ;; out of Emacs 29 process filters.
      (eglotx--enqueue-work
       server #'eglotx--handle-backend-notification-now
       server backend key (copy-tree params))))))

;; Response and capability combination.

(defun eglotx--sequence-list (value)
  "Normalize JSON sequence VALUE to a list."
  (cond ((null value) nil)
        ((vectorp value) (append value nil))
        ((and (listp value) (not (eglotx--json-object-p value))) value)
        (t (list value))))

(defun eglotx--client-completion-resolve-property-p (server property)
  "Return non-nil when SERVER's client resolves completion PROPERTY."
  (let* ((text-document
          (plist-get (eglotx--client-capabilities server) :textDocument))
         (completion (and (listp text-document)
                          (plist-get text-document :completion)))
         (item (and (listp completion)
                    (plist-get completion :completionItem)))
         (support (and (listp item) (plist-get item :resolveSupport)))
         (properties (and (listp support)
                          (plist-get support :properties))))
    (member property (eglotx--sequence-list properties))))

(defun eglotx--stable-union (&rest sequences)
  "Return an equal-tested stable union of SEQUENCES as a vector."
  (let (result)
    (dolist (sequence sequences)
      (dolist (item (eglotx--sequence-list sequence))
        (unless (member item result)
          (setq result (nconc result (list item))))))
    (vconcat result)))

(defun eglotx--truthy-p (value)
  "Return non-nil for a truthy LSP VALUE."
  (not (eglotx--json-false-p value)))

(defun eglotx--normalize-provider-value (value)
  "Preserve a present empty provider VALUE with an internal marker."
  (if (null value) eglotx--empty-provider value))

(defun eglotx--denormalize-provider-value (value)
  "Turn an internal empty provider VALUE back into its nil JSON object."
  (if (eq value eglotx--empty-provider) nil value))

(defun eglotx--first-truthy (values)
  "Return the first truthy member of VALUES."
  (cl-find-if #'eglotx--truthy-p values))

(defun eglotx--provider-object (pairs)
  "Return a copy of the first object-valued provider in PAIRS."
  (when-let* ((pair (cl-find-if (lambda (entry)
                                  (eglotx--json-object-p (cdr entry)))
                                pairs)))
    (copy-tree (cdr pair))))

(defun eglotx--merge-trigger-provider (pairs)
  "Merge completion or signature-help provider PAIRS."
  (let ((result (or (eglotx--provider-object pairs) nil))
        (values (mapcar #'cdr pairs)))
    (if (null result)
        (eglotx--first-truthy values)
      (dolist (field '(:triggerCharacters :retriggerCharacters
                       :allCommitCharacters))
        (let ((arrays
               (cl-loop for (_backend . value) in pairs
                        when (listp value)
                        collect (plist-get value field))))
          (when (seq-some #'identity arrays)
            (setq result
                  (plist-put result field
                             (apply #'eglotx--stable-union arrays))))))
      (when (seq-some (lambda (value)
                        (and (listp value)
                             (eglotx--truthy-p
                              (plist-get value :resolveProvider))))
                      values)
        (setq result (plist-put result :resolveProvider t)))
      result)))

(defun eglotx--merge-resolving-provider (pairs &optional union-field)
  "Merge resolving provider PAIRS, optionally combining UNION-FIELD."
  (let ((result (or (eglotx--provider-object pairs) nil))
        (values (mapcar #'cdr pairs)))
    (if (null result)
        (eglotx--first-truthy values)
      (when (seq-some (lambda (value)
                        (and (listp value)
                             (eglotx--truthy-p
                              (plist-get value :resolveProvider))))
                      values)
        (setq result (plist-put result :resolveProvider t)))
      (when union-field
        (let ((arrays (cl-loop for (_backend . value) in pairs
                               when (listp value)
                               collect (plist-get value union-field))))
          (when (seq-some #'identity arrays)
            (setq result
                  (plist-put result union-field
                             (apply #'eglotx--stable-union arrays))))))
      result)))

(defun eglotx--merge-code-action-provider (server pairs)
  "Merge CodeActionProvider PAIRS and namespace documentation via SERVER."
  (let ((result
         (eglotx--merge-resolving-provider pairs :codeActionKinds))
        documentation-present-p documentation)
    (dolist (pair pairs)
      (let ((backend (car pair))
            (provider (cdr pair)))
        (when (and (listp provider)
                   (plist-member provider :documentation))
          (setq documentation-present-p t)
          (dolist (item
                   (append
                    (eglotx--tag-code-action-documentation
                     server backend (plist-get provider :documentation))
                    nil))
            (unless (member item documentation)
              (setq documentation
                    (nconc documentation (list item))))))))
    (if (not (listp result))
        result
      ;; `eglotx--merge-resolving-provider' starts from the first provider
      ;; object, whose raw child command identities must never escape even
      ;; when every documentation contribution is empty.
      (setq result (eglotx--plist-delete result :documentation))
      (if documentation-present-p
          (plist-put result :documentation (vconcat documentation))
        result))))

(defun eglotx--merge-diagnostic-provider (server pairs)
  "Merge pull-diagnostic provider PAIRS through SERVER."
  (when (eglotx--first-truthy (mapcar #'cdr pairs))
    (append
     (when (seq-some
            (lambda (pair)
              (and (listp (cdr pair))
                   (stringp (plist-get (cdr pair) :identifier))))
            pairs)
       (unless (eglotx--diagnostic-provider-id server)
         (setf (eglotx--diagnostic-provider-id server)
               (eglotx--new-token server "diagnostic-provider")))
       (list :identifier (eglotx--diagnostic-provider-id server)))
     (list
      :interFileDependencies
      (if (seq-some
           (lambda (pair)
             (and (listp (cdr pair))
                  (eglotx--truthy-p
                   (plist-get (cdr pair) :interFileDependencies))))
           pairs)
          t :json-false)
      :workspaceDiagnostics :json-false))))

(defun eglotx--merge-execute-command-provider (server pairs)
  "Merge execute-command provider PAIRS and index owners in SERVER."
  (let (commands)
    (clrhash (eglotx--command-providers server))
    (dolist (pair pairs)
      (let ((backend (car pair))
            (provider (cdr pair)))
        (when (listp provider)
          (dolist (command
                   (eglotx--sequence-list (plist-get provider :commands)))
            (let ((facade-command
                   (eglotx--command-token server backend command)))
              (unless (member facade-command commands)
                (setq commands (nconc commands (list facade-command)))))))))
    (and commands (list :commands (vconcat commands)))))

(defun eglotx--merged-text-sync (backends)
  "Return one facade text synchronization option for BACKENDS."
  (let ((kinds (cl-loop for backend in backends
                        when (eglotx--backend-allows-p
                              backend :textDocument/didChange)
                        collect (eglotx--sync-kind backend)))
        open-close will-save will-save-wait save include-text)
    (dolist (backend backends)
      (let ((sync (eglotx--backend-text-sync backend)))
        (setq open-close
              (or open-close
                  (and (eglotx--backend-allows-p
                        backend :textDocument/didOpen)
                       (eglotx--sync-open-close-p
                        backend :textDocument/didOpen))))
        (when (listp sync)
          (setq will-save
                (or will-save
                    (and (eglotx--backend-allows-p
                          backend :textDocument/willSave)
                         (eglotx--truthy-p (plist-get sync :willSave))))
                will-save-wait
                (or will-save-wait
                    (and (eglotx--backend-allows-p
                          backend :textDocument/willSaveWaitUntil)
                         (eglotx--truthy-p
                          (plist-get sync :willSaveWaitUntil))))))
        (let ((backend-save (eglotx--sync-save backend)))
          (unless (or (not (eglotx--backend-allows-p
                            backend :textDocument/didSave))
                      (eglotx--json-false-p backend-save))
            (setq save t)
            (when (and (listp backend-save)
                       (eglotx--truthy-p
                        (plist-get backend-save :includeText)))
              (setq include-text t))))))
    (list :openClose (if open-close t :json-false)
          :change (cond ((memq 2 kinds) 2) ((memq 1 kinds) 1) (t 0))
          :willSave (if will-save t :json-false)
          :willSaveWaitUntil (if will-save-wait t :json-false)
          :save (if save (if include-text (list :includeText t) t)
                  :json-false))))

(defun eglotx--capability-keys (backends)
  "Return stable union of capability keys advertised by BACKENDS."
  (let (keys)
    (dolist (backend backends)
      (cl-loop for (key _value) on (eglotx--backend-capabilities backend)
               by #'cddr
               unless (memq key keys)
               do (setq keys (nconc keys (list key)))))
    keys))

(defun eglotx--capability-primary-method (capability)
  "Return the primary request method represented by CAPABILITY."
  (cl-loop for entry in eglotx--method-policies
           for policy = (cdr entry)
           when (and (eq (plist-get policy :capability) capability)
                     (not (plist-get policy :resolve)))
           return (car entry)))

(defun eglotx--sanitize-capability-value (backend capability value)
  "Adjust CAPABILITY VALUE for BACKEND's explicit method restrictions."
  (let ((copy (copy-tree value)))
    ;; StaticRegistrationOptions IDs name registrations on the child
    ;; connection.  Passing one through would let sibling IDs collide and
    ;; would invite a later unregister request for state the Eglot-facing
    ;; connection never registered.  Preserve all other provider options;
    ;; diagnostic `:identifier', for example, has separate cursor semantics.
    (when (and (memq capability eglotx--static-registration-capabilities)
               (listp copy)
               (plist-member copy :id))
      (setq copy (eglotx--plist-delete copy :id)))
    (when-let* (((listp copy))
                (method (alist-get
                         capability eglotx--document-selector-method-map)))
      ;; A static RegistrationOptions shape may carry a document selector.
      ;; Intersect it with the preset's
      ;; language scope before it participates in routing or facade union.
      (setq copy
            (eglotx--restrict-document-selector
             backend method copy)))
    (when (listp copy)
      (when-let* ((resolve-method
                   (cl-loop for entry in eglotx--method-policies
                            for policy = (cdr entry)
                            when (and (eq (plist-get policy :capability)
                                          capability)
                                      (plist-get policy :resolve))
                            return (car entry))))
        (unless (eglotx--backend-allows-p backend resolve-method)
          (setq copy (plist-put copy :resolveProvider :json-false))))
      (pcase capability
        (:workspace
         (when-let* ((folders (plist-get copy :workspaceFolders))
                     ((listp folders))
                     ((not (eglotx--backend-allows-p
                            backend :workspace/didChangeWorkspaceFolders))))
           (setq copy
                 (plist-put
                  copy :workspaceFolders
                  (plist-put (copy-sequence folders)
                             :changeNotifications :json-false))))
         (when-let* ((operations (plist-get copy :fileOperations))
                     ((listp operations)))
           (let ((filtered (copy-sequence operations)))
             (dolist (entry eglotx--workspace-file-operation-methods)
               (unless (eglotx--backend-allows-p backend (car entry))
                 (setq filtered (eglotx--plist-delete filtered (cdr entry)))))
             (setq copy
                   (if filtered
                       (plist-put copy :fileOperations filtered)
                     (eglotx--plist-delete copy :fileOperations))))))
        (:semanticTokensProvider
         (unless (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/full)
           (setq copy (plist-put copy :full :json-false)))
         (unless (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/full/delta)
           (when (and (plist-member copy :full)
                      (listp (plist-get copy :full)))
             (setq copy
                   (plist-put
                    copy :full
                    (plist-put (copy-sequence (plist-get copy :full))
                               :delta :json-false)))))
         (unless (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/range)
           (setq copy (plist-put copy :range :json-false))))
        (:renameProvider
         (unless (eglotx--backend-allows-p
                  backend :textDocument/prepareRename)
           (setq copy (plist-put copy :prepareProvider :json-false))))))
    (when (and (eq capability :colorProvider)
               (not (cl-every
                     (lambda (method)
                       (eglotx--backend-allows-p backend method))
                     '(:textDocument/documentColor
                       :textDocument/colorPresentation))))
      (setq copy :json-false))
    (when (and (eq capability :callHierarchyProvider)
               (not (cl-every
                     (lambda (method)
                       (eglotx--backend-allows-p backend method))
                     '(:textDocument/prepareCallHierarchy
                       :callHierarchy/incomingCalls
                       :callHierarchy/outgoingCalls))))
      (setq copy :json-false))
    (when (and (eq capability :typeHierarchyProvider)
               (not (cl-every
                     (lambda (method)
                       (eglotx--backend-allows-p backend method))
                     '(:textDocument/prepareTypeHierarchy
                       :typeHierarchy/supertypes
                       :typeHierarchy/subtypes))))
      (setq copy :json-false))
    (when (and (eq capability :diagnosticProvider)
               (listp copy))
      (setq copy (plist-put copy :workspaceDiagnostics :json-false)))
    copy))

(defun eglotx--compute-language-cohort (server)
  "Copy SERVER's MODE to LSP language-ID mapping from Eglot."
  (cl-loop for entry in (eglot--languages server)
           when (and (symbolp (car-safe entry))
                     (stringp (cdr-safe entry)))
           collect (cons (car entry) (copy-sequence (cdr entry)))))

(defun eglotx--facade-languages (server)
  "Return SERVER's cached MODE to LSP language-ID mapping."
  (or (eglotx--language-cohort server)
      (let ((computed (eglotx--compute-language-cohort server)))
        (when computed
          (setf (eglotx--language-cohort server) computed))
        computed)))

(defun eglotx--facade-language-ids (server)
  "Return SERVER's stable set of managed LSP language IDs."
  (let (languages)
    (dolist (entry (eglotx--facade-languages server) languages)
      (unless (member (cdr entry) languages)
        (setq languages (nconc languages (list (cdr entry))))))))

(defun eglotx--backend-covers-facade-p (server backend)
  "Return non-nil when BACKEND accepts every language managed by SERVER."
  (let ((languages (eglotx--facade-language-ids server)))
    (or (null (eglotx--backend-languages backend))
        (and languages
             (cl-every (lambda (language)
                         (eglotx--backend-accepts-language-p backend language))
                       languages)))))

(defun eglotx--document-capability-p (capability)
  "Return non-nil when CAPABILITY represents document requests."
  (when-let* ((method (eglotx--capability-primary-method capability)))
    (string-prefix-p ":textDocument/"
                     (symbol-name (eglotx--method-key method)))))

(defun eglotx--capability-covers-facade-p (server pairs)
  "Return non-nil when capability PAIRS cover every SERVER language."
  (cl-labels
      ((unrestricted-filter-p
        (filter language)
        (and (eglotx--json-object-p filter)
             (null (plist-get filter :scheme))
             (null (plist-get filter :pattern))
             (let ((selected (plist-get filter :language)))
               (if language
                   (or (null selected) (equal selected language))
                 (null selected)))))
       (selector-covers-p
        (value language)
        (if (and (listp value)
                 (plist-member value :documentSelector))
            (let ((selector (plist-get value :documentSelector)))
              ;; JSON null is the universal selector.  A scheme- or
              ;; pattern-restricted static selector cannot justify a facade-
              ;; wide advertisement: Eglot does not enforce
              ;; initialize-time selectors before issuing requests.
              (or (null selector)
                  (seq-some
                   (lambda (filter)
                     (unrestricted-filter-p filter language))
                   (eglotx--sequence-list selector))))
          t))
       (covers-language-p
        (pair language)
        (let ((backend (car pair))
              (value (cdr pair)))
          (and (eglotx--truthy-p value)
               (eglotx--backend-accepts-language-p backend language)
               (selector-covers-p value language)))))
   (let ((languages (eglotx--facade-language-ids server)))
     (if languages
         (cl-every
          (lambda (language)
            (seq-some (lambda (pair) (covers-language-p pair language))
                      pairs))
          languages)
       (seq-some
        (lambda (pair)
          (and (null (eglotx--backend-languages (car pair)))
               (eglotx--truthy-p (cdr pair))
               (selector-covers-p (cdr pair) nil)))
        pairs)))))

(defun eglotx--merge-static-document-selectors (capability pairs value)
  "Merge static document selectors for CAPABILITY PAIRS into VALUE."
  (if (or (not (listp value))
          (not (alist-get capability eglotx--document-selector-method-map)))
      value
    (let ((universal-p nil) selectors)
      (dolist (pair pairs)
        (let ((provider (cdr pair)))
          (when (eglotx--truthy-p provider)
            (if (and (listp provider)
                     (plist-member provider :documentSelector))
                (let ((selector (plist-get provider :documentSelector)))
                  (if (null selector)
                      (setq universal-p t)
                    (dolist (filter
                             (eglotx--bounded-document-selector selector))
                      (unless (member filter selectors)
                        (when (>= (length selectors)
                                  eglotx-document-selector-limit)
                          (jsonrpc-error
                           "Aggregate static DocumentSelector exceeds %d filters"
                           eglotx-document-selector-limit))
                        (setq selectors
                              (nconc selectors
                                     (list (copy-tree filter))))))))
              (setq universal-p t)))))
      (cond
       (universal-p (eglotx--plist-delete value :documentSelector))
       (selectors (plist-put value :documentSelector (vconcat selectors)))
       (t value)))))

(defun eglotx--capability-pairs (server backends capability)
  "Return allowed BACKEND . CAPABILITY pairs for SERVER BACKENDS."
  (let ((method (unless (memq capability
                              '(:textDocumentSync :workspace
                                :semanticTokensProvider))
                  (eglotx--capability-primary-method capability))))
    (let ((pairs
           (cl-loop for backend in backends
                    for caps = (eglotx--backend-capabilities backend)
                    when (and (plist-member caps capability)
                              (or (null method)
                                  (eglotx--backend-allows-p backend method)))
                    collect
                    (cons backend
                          (eglotx--sanitize-capability-value
                           backend capability
                           (eglotx--normalize-provider-value
                            (plist-get caps capability)))))))
      (if (and (eglotx--document-capability-p capability)
               (not (eglotx--capability-covers-facade-p server pairs)))
          nil
        pairs))))

(defun eglotx--client-supports-file-operation-p (server method)
  "Return non-nil when SERVER's client supports file-operation METHOD."
  (let* ((workspace (plist-get (eglotx--client-capabilities server) :workspace))
         (operations (and (listp workspace)
                          (plist-get workspace :fileOperations)))
         (key (alist-get (eglotx--method-key method)
                         eglotx--workspace-file-operation-methods)))
    (and key (listp operations)
         (not (eglotx--json-false-p (plist-get operations key))))))

(defun eglotx--merge-workspace-capability (server pairs)
  "Combine nested workspace capability PAIRS for SERVER deterministically."
  (let (folders-supported folders-changes operations result)
    (dolist (pair pairs)
      (let* ((workspace (cdr pair))
             (folders (and (listp workspace)
                           (plist-get workspace :workspaceFolders)))
             (supported
              (and (listp folders)
                   (not (eglotx--json-false-p
                         (plist-get folders :supported))))))
        (when supported
          (setq folders-supported t)
          (unless (eglotx--json-false-p
                   (plist-get folders :changeNotifications))
            (setq folders-changes t)))))
    (when folders-supported
      (setq result
            (plist-put
             result :workspaceFolders
             (append (list :supported t)
                     (when folders-changes
                       (list :changeNotifications t))))))
    ;; File operations are independently negotiated singletons.  The first
    ;; capable backend for each method supplies exactly the filters that make
    ;; Eglot emit that method, and routing selects that same backend.
    (dolist (entry eglotx--workspace-file-operation-methods)
      (when (eglotx--client-supports-file-operation-p server (car entry))
        (let* ((method (car entry))
               (pinned (gethash method
                                (eglotx--singleton-providers server)))
               (selected
                (if pinned
                    (let ((pair (assq pinned pairs)))
                      (and pair
                           (eglotx--workspace-method-option
                            (cdr pair) method)
                           pair))
                  (cl-find-if
                   (lambda (pair)
                     (eglotx--workspace-method-option (cdr pair) method))
                   pairs))))
          (when-let* ((selected selected)
                    (options
                     (eglotx--workspace-method-option
                      (cdr selected) method)))
            (setq operations
                  (plist-put operations (cdr entry) (copy-tree options)))
            (unless pinned
              (puthash method (car selected)
                       (eglotx--singleton-providers server)))))))
    (when operations
      (setq result (plist-put result :fileOperations operations)))
    result))

(defun eglotx--merge-notebook-sync-capability (server pairs)
  "Select and pin one notebook-sync provider from PAIRS for SERVER."
  (let* ((pinned
          (seq-some
           (lambda (method)
             (gethash method (eglotx--singleton-providers server)))
           eglotx--notebook-sync-methods))
         (eligible-p
          (lambda (pair)
            (let ((backend (car pair))
                  (value (cdr pair)))
              (and (eglotx--truthy-p value)
                   (cl-every
                    (lambda (method)
                      (eglotx--backend-allows-p backend method))
                    '(:notebookDocument/didOpen
                      :notebookDocument/didChange
                      :notebookDocument/didClose))))))
         (selected
          (if pinned
              (let ((pair (assq pinned pairs)))
                (and pair (funcall eligible-p pair) pair))
            (cl-find-if eligible-p pairs))))
    (when-let* ((selected selected)
              (backend (car selected))
              (value (cdr selected)))
      (unless pinned
        (dolist (method eglotx--notebook-sync-methods)
          (when (and (eglotx--backend-allows-p backend method)
                     (or (not (eq method :notebookDocument/didSave))
                         (and (listp value)
                              (eglotx--truthy-p (plist-get value :save)))))
            (puthash method backend
                     (eglotx--singleton-providers server)))))
      (let ((copy (copy-tree value)))
        (when (and (listp copy)
                   (not (eglotx--backend-allows-p
                         backend :notebookDocument/didSave)))
          (setq copy (plist-put copy :save :json-false)))
        copy))))

(defun eglotx--merge-semantic-capability (server pairs)
  "Select one semantic-token provider from PAIRS and pin it in SERVER."
  (let* ((pinned
          (seq-some
           (lambda (method)
             (gethash method (eglotx--singleton-providers server)))
           eglotx--semantic-token-methods))
         (eligible-p
          (lambda (pair)
            (let* ((backend (car pair))
                   (provider (cdr pair)))
              (and (eglotx--capability-covers-facade-p
                    server (list pair))
                   (listp provider)
                   (or (and (eglotx--backend-allows-p
                             backend :textDocument/semanticTokens/full)
                            (eglotx--semantic-option-enabled-p
                             provider :full))
                       (and (eglotx--backend-allows-p
                             backend :textDocument/semanticTokens/range)
                            (eglotx--semantic-option-enabled-p
                             provider :range)))))))
         (selected
          (if pinned
              (let ((pair (assq pinned pairs)))
                (and pair (funcall eligible-p pair) pair))
            (cl-find-if eligible-p pairs))))
    (when-let* ((selected selected)
              (backend (car selected))
              (provider (cdr selected)))
    (let ((full (plist-get provider :full)))
      (when (and (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/full)
                 (eglotx--semantic-option-enabled-p provider :full))
        (puthash :textDocument/semanticTokens/full backend
                 (eglotx--singleton-providers server)))
      (when (and (listp full)
                 (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/full/delta)
                 (eglotx--truthy-p (plist-get full :delta)))
        (puthash :textDocument/semanticTokens/full/delta backend
                 (eglotx--singleton-providers server)))
      (when (and (eglotx--backend-allows-p
                  backend :textDocument/semanticTokens/range)
                 (eglotx--semantic-option-enabled-p provider :range))
        (puthash :textDocument/semanticTokens/range backend
                 (eglotx--singleton-providers server))))
      (copy-tree provider))))

(defun eglotx--known-capability-p (capability)
  "Return non-nil when CAPABILITY has an explicit Eglotx policy."
  (or (memq capability
            '(:textDocumentSync :workspace :notebookDocumentSync
              :positionEncoding))
      (cl-some (lambda (entry)
                 (eq capability (plist-get (cdr entry) :capability)))
               eglotx--method-policies)))

(defun eglotx--combine-capability (server capability pairs)
  "Combine CAPABILITY PAIRS for SERVER using capability-specific semantics."
  (pcase capability
    (:textDocumentSync
     (eglotx--merged-text-sync (mapcar #'car pairs)))
    (:completionProvider
     (let ((provider (eglotx--merge-trigger-provider pairs)))
       ;; The facade itself can resolve compact CompletionList edit ranges,
       ;; even when the owning child cannot.  Advertise that local operation
       ;; only to clients which explicitly accept `textEdit' during resolve.
       (if (and provider
                (eglotx--truthy-p provider)
                (eglotx--client-completion-resolve-property-p
                 server "textEdit"))
           (if (listp provider)
               (plist-put provider :resolveProvider t)
             (list :resolveProvider t))
         provider)))
    (:signatureHelpProvider
     (eglotx--merge-trigger-provider pairs))
    (:codeActionProvider
     (eglotx--merge-code-action-provider server pairs))
    ((or :codeLensProvider :documentLinkProvider :inlayHintProvider
         :workspaceSymbolProvider)
     (eglotx--merge-resolving-provider pairs))
    (:executeCommandProvider
     (eglotx--merge-execute-command-provider server pairs))
    (:diagnosticProvider
     (eglotx--merge-diagnostic-provider server pairs))
    (:workspace
     (eglotx--merge-workspace-capability server pairs))
    (:notebookDocumentSync
     (eglotx--merge-notebook-sync-capability server pairs))
    ;; Semantic-token legends/state are not safely composable.  Routing uses
    ;; the same highest-priority provider selected here.
    (:semanticTokensProvider
     (eglotx--merge-semantic-capability server pairs))
    (:positionEncoding "utf-16")
    (_
     (if (eglotx--known-capability-p capability)
         (copy-tree (eglotx--first-truthy (mapcar #'cdr pairs)))
       ;; Unknown and experimental methods follow the primary backend, so do
       ;; not advertise a secondary-only capability that would cross-route.
       ;; Select the primary independently of PAIRS: that list contains only
       ;; backends which mentioned CAPABILITY, so taking its first element
       ;; could silently promote a lower-priority provider.
       (when-let* ((primary
                    (seq-find #'eglotx--backend-running-p
                              (eglotx--backends server)))
                   (pair (assq primary pairs))
                   ((eglotx--truthy-p (cdr pair)))
                   ((eglotx--backend-covers-facade-p server primary)))
         (copy-tree (cdr pair)))))))

(defun eglotx--combine-capabilities (server backends)
  "Combine BACKENDS capabilities into SERVER's deterministic facade."
  (let (result)
    (dolist (capability (eglotx--capability-keys backends))
      (unless (memq capability '(:positionEncoding :$streamingDiagnosticsProvider))
        (let* ((pairs
                (eglotx--capability-pairs server backends capability))
               (value
                (eglotx--combine-capability server capability pairs))
               (projection-pairs
                (if (not (eq capability :semanticTokensProvider))
                    pairs
                  (when-let* ((owner
                               (seq-some
                                (lambda (method)
                                  (gethash
                                   method
                                   (eglotx--singleton-providers server)))
                                eglotx--semantic-token-methods))
                              (pair (assq owner pairs)))
                    (list pair)))))
          (when value
            (setq value
                  (eglotx--merge-static-document-selectors
                   capability projection-pairs value))
            (setq result
                  (plist-put
                   result capability
                   (eglotx--denormalize-provider-value value)))))))
    (setq result (plist-put result :positionEncoding "utf-16"))
    (when (eglotx--stream-diagnostics-p server)
      (setq result (plist-put result :$streamingDiagnosticsProvider t)))
    result))

(defun eglotx--recompute-facade-capabilities (server)
  "Rebuild SERVER capability projection from its running child contributions."
  (let ((backends (seq-filter #'eglotx--backend-running-p
                              (eglotx--backends server))))
    (eglotx--pin-singleton-providers server backends)
    (let ((capabilities (eglotx--combine-capabilities server backends)))
      (setf (eglotx--facade-capabilities server) (copy-tree capabilities)
            (eglot--capabilities server) (copy-tree capabilities))
      capabilities)))

(defun eglotx--stateful-singleton-method-p (method)
  "Return non-nil when METHOD must not fail over between providers."
  (let ((key (eglotx--method-key method)))
    (or (memq key
              '(:textDocument/semanticTokens/full
                :textDocument/semanticTokens/full/delta
                :textDocument/semanticTokens/range))
        (memq key eglotx--notebook-sync-methods)
        (alist-get key eglotx--workspace-file-operation-methods))))

(defun eglotx--pin-singleton-providers (server backends)
  "Pin singleton request methods in SERVER to negotiated BACKENDS."
  (dolist (entry eglotx--method-policies)
    (let* ((method (car entry))
           (policy (cdr entry))
           (capability (plist-get policy :capability)))
      (when (and (eq (plist-get policy :route) 'exclusive)
                 (eglotx--stateful-singleton-method-p method)
                 (not (gethash method
                               (eglotx--singleton-providers server)))
                 (not (eq capability :semanticTokensProvider))
                 (not (alist-get
                       method eglotx--workspace-file-operation-methods)))
        (when-let* ((backend
                     (seq-find
                      (lambda (candidate)
                        (and (eglotx--backend-allows-p candidate method)
                             (eglotx--backend-capable-p
                              candidate method capability)))
                      backends)))
          (puthash method backend (eglotx--singleton-providers server)))))))

(defun eglotx--merge-initialize (server outcomes)
  "Combine successful initialize OUTCOMES for SERVER."
  (let ((backends (mapcar #'car outcomes)) names versions)
    ;; Eglot 31 keeps pull and streaming diagnostics in disjoint maps whose
    ;; updates clear one another.  If any child supports pull diagnostics, use
    ;; ordinary publishDiagnostics for push-only siblings; Eglot merges that
    ;; pushed map with pulled reports.  Streaming remains the fast path when
    ;; the whole cohort is push-only.
    (when (and (eglotx--stream-diagnostics-p server)
               (seq-some
                #'eglotx--backend-pull-diagnostics-p
                backends))
      (setf (eglotx--stream-diagnostics-p server) nil))
    (eglotx--pin-singleton-providers server backends)
    (dolist (pair outcomes)
      (let* ((backend (car pair))
             (info (plist-get (cdr pair) :serverInfo)))
        (setf (eglotx--backend-state backend) 'running)
        (push (or (plist-get info :name) (eglotx--backend-name backend)) names)
        (when-let* ((version (plist-get info :version)))
          (push version versions))))
    (let ((capabilities (eglotx--combine-capabilities server backends)))
      (setf (eglotx--facade-capabilities server) (copy-tree capabilities))
      (list :capabilities capabilities
            :serverInfo
            (append
             (list :name (string-join (nreverse names) "+"))
             (when versions
               (list :version (string-join (nreverse versions) ","))))))))

(defun eglotx--response-uri (request)
  "Return the document URI associated with REQUEST."
  (and (listp (eglotx--request-params request))
       (eglotx--params-uri (eglotx--request-params request))))

(defun eglotx--merge-completion-resolve-item (fallback resolved)
  "Overlay RESOLVED completion fields over materialized FALLBACK.

Language servers may omit fields which did not change during resolve.  The
facade first retags RESOLVED ownership, then calls this helper so a missing
child `data' can never replace its saved routing cookie with a facade token."
  (if (not (and (listp fallback) (listp resolved)))
      resolved
    (let* ((normalized
            (if (or (plist-member fallback :textEdit)
                    (plist-member resolved :textEdit)
                    (plist-member resolved :textEditText))
                (eglotx--completion-with-edit-range
                 resolved nil fallback)
              resolved))
           (result (copy-sequence fallback)))
      ;; This is intentionally shallow.  Every explicit response field,
      ;; including nil, replaces the corresponding unchanged request field.
      (cl-loop for (key value) on normalized by #'cddr
               do (setq result (plist-put result key value)))
      result)))

(defun eglotx--merge-first (server request outcomes)
  "Use SERVER to return REQUEST's highest-priority OUTCOMES result with ownership."
  (when (and (eq (eglotx--request-method request) :completionItem/resolve)
             (not (eglotx--request-document-current-p server request)))
    (signal 'eglotx-content-modified
            '("Document changed while completion resolve was in flight")))
  (let* ((pair (car outcomes))
         (backend (car pair))
         (value (cdr pair))
         (policy (eglotx--request-policy request))
         (old-token (and (eq (plist-get policy :route) 'owner)
                         (eglotx--owner-token-in
                          (eglotx--request-params request))))
         (old-owner (and old-token
                         (or (eglotx--request-owner request)
                             (eglotx--owner-for-params
                              server (eglotx--request-params request)))))
         (same-owner (and old-owner
                          (eq backend (eglotx--owner-backend old-owner))))
         (old-location
          (and same-owner old-token
               (eglotx--completion-batch-location server old-token)))
         (shared-batch-token-p
          (or (eglotx--request-owner-token-shared-p request)
              (and old-location
                   (eglotx--completion-shared-index-p
                    (car old-location) (cdr old-location))))))
    (let ((merged
           (cond
            ((and (eq (eglotx--request-method request)
                      :textDocument/inlineCompletion)
                  (plist-get policy :commands))
             (eglotx--tag-inline-completion-result
              server backend value (eglotx--response-uri request)))
            ((and (plist-get policy :affinity)
                  (eglotx--json-object-p value))
             (eglotx--tag-owned-object
              server backend value (eglotx--request-method request)
              (or (and old-owner (eglotx--owner-uri old-owner))
                  (eglotx--request-document-uri request)
                  (eglotx--response-uri request))
              (plist-get policy :commands)
              (and same-owner (not shared-batch-token-p) old-token)
              (and same-owner old-owner)))
            ((and (plist-get policy :commands)
                  (eglotx--json-object-p value))
             (eglotx--tag-command-object
              server backend value (eglotx--response-uri request)))
            (t value))))
      (if (eq (eglotx--request-method request) :completionItem/resolve)
          (eglotx--merge-completion-resolve-item
           (eglotx--request-params request) merged)
        merged))))

(defun eglotx--merge-append (server request outcomes)
  "Use SERVER to stably append and de-duplicate OUTCOMES for REQUEST.
Exact JSON equality is the only generic collection identity that is safe
across independent servers.  When duplicates exist, the first result in
backend-priority order owns the item."
  (let ((policy (eglotx--request-policy request))
        (uri (eglotx--response-uri request))
        (seen (make-hash-table :test #'equal))
        result)
    (dolist (pair outcomes)
      (let ((backend (car pair)))
        (dolist (item (eglotx--sequence-list (cdr pair)))
          (unless (gethash item seen)
            (puthash item t seen)
            (push
             (cond
              ;; A CodeAction result may legally contain a raw Command.  It
              ;; has no resolve data, so adding facade `:data' would both leak
              ;; onto executeCommand and waste an ownership-ring entry.
              ((and (eq (eglotx--request-method request)
                        :textDocument/codeAction)
                    (listp item)
                    (stringp (plist-get item :command)))
               (eglotx--tag-command-object server backend item uri))
              ((and (plist-get policy :affinity) (listp item))
               (eglotx--tag-owned-object
                server backend item (eglotx--request-method request)
                uri (plist-get policy :commands)))
              (t item))
             result)))))
    (vconcat (nreverse result))))

(defun eglotx--merge-hierarchy-calls (server request outcomes)
  "Use SERVER to tag nested items in REQUEST OUTCOMES with their owner."
  (let* ((policy (eglotx--request-policy request))
         (item-key (plist-get policy :item-key))
         (seen (make-hash-table :test #'equal))
         result)
    (dolist (pair outcomes)
      (let ((backend (car pair)))
        (dolist (call (eglotx--sequence-list (cdr pair)))
          (unless (gethash call seen)
            (puthash call t seen)
            (let ((item (and (listp call) (plist-get call item-key))))
              (push
               (if (listp item)
                   (plist-put
                    (copy-sequence call) item-key
                    (eglotx--tag-owned-object
                     server backend item
                     (eglotx--request-method request)
                     (plist-get item :uri) nil))
                 call)
               result))))))
    (vconcat (nreverse result))))

(defun eglotx--normalize-location (location)
  "Return LOCATION or LocationLink represented as a Location object."
  (if (and (listp location) (plist-member location :targetUri))
      (list :uri (plist-get location :targetUri)
            :range (or (plist-get location :targetSelectionRange)
                       (plist-get location :targetRange)))
    location))

(defun eglotx--location-key (location)
  "Return a de-duplication key for normalized LOCATION."
  (list (plist-get location :uri) (plist-get location :range)))

(defun eglotx--merge-locations (outcomes)
  "Combine and de-duplicate location OUTCOMES."
  (let ((seen (make-hash-table :test #'equal)) result)
    (dolist (pair outcomes)
      (dolist (location (eglotx--sequence-list (cdr pair)))
        (let* ((normalized (eglotx--normalize-location location))
               (key (eglotx--location-key normalized)))
          (unless (gethash key seen)
            (puthash key t seen)
            (setq result (nconc result (list normalized)))))))
    (vconcat result)))

(defun eglotx--completion-items-shape (items)
  "Classify ITEMS as an empty, vector, list, or singleton result."
  (cond
   ((null items) 'empty)
   ((vectorp items) 'vector)
   ((and (listp items) (not (eglotx--json-object-p items))) 'list)
   (t 'singleton)))

(defun eglotx--tag-completion-command
    (server backend copy original uri)
  "Namespace ORIGINAL's CompletionItem command in already-owned COPY."
  (if (not (plist-member original :command))
      copy
    (let ((command (plist-get original :command)))
      (cond
       ((stringp command)
        (plist-put copy :command
                   (eglotx--command-token server backend command)))
       ((consp command)
        (plist-put copy :command
                   (eglotx--tag-command-object
                    server backend command uri)))
       (t copy)))))

(defun eglotx--merge-completions (server request outcomes)
  "Combine completion OUTCOMES for REQUEST through SERVER."
  (unless (eglotx--request-document-current-p server request)
    (signal 'eglotx-content-modified
            '("Document changed while completion was in flight")))
  (let ((uri (eglotx--response-uri request))
        (defer-edit-range-p
         (eglotx--client-completion-resolve-property-p
          server "textEdit"))
        (total 0)
        incomplete
        prepared
        segments)
    ;; First pass is per backend, not per item.  It gives the hot loop one
    ;; final vector and one ownership batch to fill without list conversions.
    (dolist (pair outcomes)
      (let* ((backend (car pair))
             (payload (cdr pair))
             (completion-list-p (eglotx--json-object-p payload))
             (items (if completion-list-p
                        (plist-get payload :items)
                      payload))
             (defaults (and completion-list-p
                            (plist-get payload :itemDefaults)))
             (shape (eglotx--completion-items-shape items))
             (count (pcase shape
                      ((or 'vector 'list) (length items))
                      ('singleton 1)
                      (_ 0)))
             (segment
              (eglotx--completion-segment-create
               :backend backend :start total :end (+ total count)
               :default-data
               (if (and defaults (plist-member defaults :data))
                   (plist-get defaults :data)
                 eglotx--missing-value)
               :default-edit-range
               (if (and defer-edit-range-p defaults
                        (plist-member defaults :editRange))
                   (plist-get defaults :editRange)
                 eglotx--missing-value))))
        (when completion-list-p
          (setq incomplete
                (or incomplete
                    (eglotx--truthy-p
                     (plist-get payload :isIncomplete)))))
        (setq total (+ total count))
        (push segment segments)
        (push (list segment items defaults shape) prepared)))
    (setq prepared (nreverse prepared)
          segments (nreverse segments))
    (let* ((output (make-vector total nil))
           (prefix (and (> total 0)
                        (concat (eglotx--new-token server "batch") ":")))
           (document (eglotx--document-for-uri server uri))
           (batch
            (and prefix
                 (eglotx--completion-batch-create
                  :prefix prefix
                  :uri uri
                  :generation (and document
                                   (eglotx--document-generation document))
                  :document document
                  :size total
                  :segments segments))))
      ;; A segment token is shared by every item that inherits its backend's
      ;; default (including an absent default).  Only explicit per-item data
      ;; needs an indexed token, so Tailwind's itemDefaults fast path creates
      ;; O(backends) strings rather than O(items) strings.
      (when prefix
        (cl-loop for segment in segments
                 for segment-index from 0
                 do (setf (eglotx--completion-segment-token segment)
                          (eglotx--completion-token
                           prefix batch (+ total segment-index)))))
      (dolist (entry prepared)
        (let* ((segment (nth 0 entry))
               (items (nth 1 entry))
               (defaults (nth 2 entry))
               (shape (nth 3 entry))
               (backend (eglotx--completion-segment-backend segment))
               (index (eglotx--completion-segment-start segment)))
          (cl-labels
              ((emit
                (item)
                (if (not (listp item))
                    (aset output index item)
                  (let ((copy (copy-sequence item))
                        (item-data-p (plist-member item :data)))
                    (when item-data-p
                      (let ((overrides
                             (or
                              (eglotx--completion-segment-data segment)
                              (setf
                               (eglotx--completion-segment-data segment)
                               (make-vector
                                (- (eglotx--completion-segment-end segment)
                                   (eglotx--completion-segment-start segment))
                                eglotx--missing-value)))))
                        (aset overrides
                              (- index
                                 (eglotx--completion-segment-start segment))
                              (plist-get item :data))))
                    (when (and defaults
                               (not defer-edit-range-p)
                               (plist-member defaults :editRange))
                      (setq copy
                            (eglotx--completion-with-edit-range
                             item (plist-get defaults :editRange) nil copy)))
                    (setq copy
                          (plist-put
                           copy :data
                           (if item-data-p
                               (eglotx--completion-token prefix batch index)
                             (eglotx--completion-segment-token segment))))
                    (aset output index
                          (eglotx--tag-completion-command
                           server backend copy item uri))))
                (cl-incf index)))
            (pcase shape
             ('vector
              (dotimes (item-index (length items))
                (emit (aref items item-index))))
             ('list
              (dolist (item items) (emit item)))
             ('singleton (emit items))))))
      ;; Publish only after the complete result has been transformed.  A
      ;; malformed item or non-local exit therefore cannot expose a half-batch.
      (when batch
        (eglotx--remember-completion-batch server batch))
      (list :isIncomplete (if incomplete t :json-false)
            :items output))))

(defun eglotx--fenced-markdown (text &optional language)
  "Represent TEXT losslessly in a Markdown fence with safe LANGUAGE info."
  (let ((longest 0) (run 0))
    (dotimes (index (length text))
      (if (= (aref text index) ?`)
          (setq run (1+ run)
                longest (max longest run))
        (setq run 0)))
    (let ((fence (make-string (max 3 (1+ longest)) ?`))
          (info (and (stringp language)
                     (string-match-p "\\`[[:alnum:]_+.-]+\\'" language)
                     language)))
      (concat fence (or info "") "\n" text
              (unless (string-suffix-p "\n" text) "\n")
              fence))))

(defun eglotx--plaintext-markdown (text)
  "Represent plaintext TEXT losslessly inside a Markdown fenced block."
  (eglotx--fenced-markdown text))

(defun eglotx--hover-markdown (contents)
  "Convert Hover CONTENTS to a Markdown string."
  (cond
   ((stringp contents) contents)
   ((vectorp contents)
    (string-join (delq nil (mapcar #'eglotx--hover-markdown
                                   (append contents nil))) "\n\n"))
   ((and (listp contents) (plist-member contents :kind))
    (let ((value (or (plist-get contents :value) "")))
      (if (equal (plist-get contents :kind) "plaintext")
          (if (string-empty-p value) ""
            (eglotx--plaintext-markdown value))
        value)))
   ((and (listp contents) (plist-member contents :language))
    (eglotx--fenced-markdown (or (plist-get contents :value) "")
                             (plist-get contents :language)))
   ((listp contents)
    (string-join (delq nil (mapcar #'eglotx--hover-markdown contents))
                 "\n\n"))))

(defun eglotx--merge-hovers (outcomes)
  "Combine non-empty hover OUTCOMES into one Markdown hover."
  (let (parts range)
    (dolist (pair outcomes)
      (when-let* ((hover (cdr pair))
                  (text (eglotx--hover-markdown
                         (plist-get hover :contents)))
                  ((not (string-empty-p text))))
        (unless range (setq range (plist-get hover :range)))
        (setq parts (nconc parts (list text)))))
    (when parts
      (append (list :contents
                    (list :kind "markdown"
                          :value (string-join parts "\n\n---\n\n")))
              (when range (list :range range))))))

(defun eglotx--validate-diagnostic-report (report)
  "Validate one full or unchanged document diagnostic REPORT."
  (unless (eglotx--json-object-p report)
    (signal 'eglotx-error '("Malformed diagnostic report object")))
  (when (and (plist-member report :resultId)
             (not (stringp (plist-get report :resultId))))
    (signal 'eglotx-error '("Malformed diagnostic result ID")))
  (pcase (plist-get report :kind)
    ("full"
     (unless (vectorp (plist-get report :items))
       (signal 'eglotx-error '("Full diagnostic report requires items")))
     (eglotx--validate-diagnostics (plist-get report :items)))
    ("unchanged"
     (unless (stringp (plist-get report :resultId))
       (signal 'eglotx-error
               '("Unchanged diagnostic report requires a result ID"))))
    (_ (signal 'eglotx-error '("Unknown diagnostic report kind"))))
  report)

(defun eglotx--related-document-entries (server related)
  "Return canonical (URI KEY CHILD-URI REPORT) entries from RELATED on SERVER."
  (let (entries)
    (cond
     ((hash-table-p related)
      (maphash (lambda (key report)
                 (let* ((name (if (symbolp key)
                                  (symbol-name key)
                                (format "%s" key)))
                        (uri (if (string-prefix-p ":" name)
                                 (substring name 1)
                               name))
                        (canonical
                         (eglotx--canonical-document-uri server uri)))
                   (push (list canonical
                               (intern (concat ":" canonical)) uri report)
                         entries)))
               related))
     ((eglotx--json-object-p related)
      (cl-loop for (key report) on related by #'cddr
               for name = (symbol-name key)
               for uri = (if (string-prefix-p ":" name)
                             (substring name 1)
                           name)
               for canonical = (eglotx--canonical-document-uri server uri)
               do (push (list canonical
                              (if (equal canonical uri)
                                  key
                                (intern (concat ":" canonical)))
                              uri report)
                        entries))))
    (let ((ordered
           (sort entries
                 (lambda (left right)
                   (or (string< (car left) (car right))
                       (and (equal (car left) (car right))
                            (string< (nth 2 left) (nth 2 right)))))))
          (latest (make-hash-table :test #'equal))
          order)
      ;; JSON object order is not semantic, and a hash-table decoder may
      ;; enumerate aliases nondeterministically.  Raw URI is therefore the
      ;; stable tie-breaker; the last raw spelling replaces the earlier slot
      ;; for this backend/canonical identity.
      (dolist (entry ordered)
        (unless (gethash (car entry) latest)
          (push (car entry) order))
        (puthash (car entry) entry latest))
      (mapcar (lambda (uri) (gethash uri latest)) (nreverse order)))))

(defun eglotx--validate-document-diagnostic-payload (server payload)
  "Validate one child document-diagnostic PAYLOAD for SERVER transactionally."
  (eglotx--validate-diagnostic-report payload)
  (let ((related (plist-get payload :relatedDocuments)))
    (when related
      (unless (or (hash-table-p related)
                  (eglotx--json-object-p related))
        (signal 'eglotx-error '("Malformed relatedDocuments object")))
      (dolist (entry (eglotx--related-document-entries server related))
        (eglotx--validate-diagnostic-report (nth 3 entry)))))
  payload)

(defun eglotx--valid-diagnostic-outcomes (server outcomes)
  "Return semantically valid document-diagnostic OUTCOMES for SERVER."
  (let (valid)
    (dolist (pair outcomes (nreverse valid))
      (condition-case err
          (progn
            (eglotx--validate-document-diagnostic-payload server (cdr pair))
            (push pair valid))
        (error
         (display-warning
          'eglotx
          (format "Ignoring malformed pull diagnostics from %s: %s"
                  (eglotx--backend-name (car pair))
                  (error-message-string err))
          :warning))))))

(defun eglotx--pull-diagnostic-snapshot
    (server backend uri report &optional validated-p)
  "Return tokenized pull REPORT diagnostics on SERVER for BACKEND URI."
  (let* ((uri (eglotx--canonical-document-uri server uri))
         (document (eglotx--document-for-uri server uri))
         (key (eglotx--diagnostic-token-key backend uri 'pull)))
    (if (equal (plist-get report :kind) "unchanged")
        (progn
          (eglotx--touch-unopened-diagnostic-uri server uri)
          (or (gethash key (eglotx--diagnostic-snapshots server)) []))
      (let ((items
             (if validated-p
                 (plist-get report :items)
               (eglotx--validate-diagnostics (plist-get report :items)))))
        (eglotx--invalidate-diagnostic-cursor server uri)
        (eglotx--forget-diagnostic-tokens
         server backend uri document 'pull)
        (let ((tagged (eglotx--tag-diagnostics server backend items uri)))
          (eglotx--remember-diagnostic-tokens
           server backend uri tagged 'pull)
          (eglotx--store-diagnostic-snapshot server key tagged)
          tagged)))))

(defun eglotx--request-document-current-p (server request)
  "Return whether REQUEST still names the document generation it dispatched."
  (let* ((uri (eglotx--request-document-uri request))
         (captured (eglotx--request-document request))
         (current (and uri (eglotx--document-for-uri server uri))))
    (and (eq captured current)
         (or (null captured)
             (= (eglotx--request-document-generation request)
                (eglotx--document-generation captured))))))

(defun eglotx--related-diagnostic-current-p (server request uri)
  "Return whether URI stayed unchanged since diagnostic REQUEST was sent."
  (<= (gethash (eglotx--canonical-document-uri server uri)
               (eglotx--document-mutation-epochs server)
               0)
      (or (eglotx--request-document-mutation-epoch request)
          ;; Unit-level callers which construct a request directly have no
          ;; asynchronous dispatch boundary and therefore observe now.
          (eglotx--document-mutation-epoch server))))

(defun eglotx--merge-diagnostic-results (server request outcomes)
  "Combine pull-diagnostic OUTCOMES for REQUEST through SERVER."
  (unless (eglotx--request-document-current-p server request)
    (signal 'eglotx-content-modified
            '("Document changed while pull diagnostics were in flight")))
  (let* ((valid-outcomes
         (eglotx--valid-diagnostic-outcomes server outcomes))
         (_ (unless valid-outcomes
              (signal 'eglotx-error
                      '("Every child returned malformed diagnostics"))))
         (uri (eglotx--canonical-document-uri
               server (eglotx--response-uri request)))
         (related-reports (make-hash-table :test #'equal))
         (cursor-values (make-hash-table :test #'eq))
         (related-cursor-values (make-hash-table :test #'equal))
         (complete-p
          (and (eglotx--request-targets request)
               (= (length valid-outcomes)
                  (length (eglotx--request-targets request)))))
         related-order items)
    (dolist (pair valid-outcomes)
      (let ((backend (car pair))
            (payload (cdr pair)))
        (when (stringp (plist-get payload :resultId))
          (puthash
           backend
           (eglotx--diagnostic-child-cursor-create
            :result-id (plist-get payload :resultId))
           cursor-values))
        (setq items
              (nconc
               items
                (append
                 (eglotx--pull-diagnostic-snapshot
                 server backend uri payload t)
                nil)))
        (dolist (entry
                 (eglotx--related-document-entries
                  server (plist-get payload :relatedDocuments)))
          (pcase-let ((`(,related-uri ,wire-key ,child-uri ,report) entry))
            ;; Related reports have no version field.  Admit them only when
            ;; their URI has not crossed a didOpen/didChange/didClose boundary
            ;; since this request was dispatched; otherwise they would
            ;; repopulate the Diagnostics Hub with a pre-change snapshot.
            (when (eglotx--related-diagnostic-current-p
                   server request related-uri)
              (let* ((old (gethash related-uri related-reports))
                     (values
                      (or (gethash related-uri related-cursor-values)
                          (let ((created (make-hash-table :test #'eq)))
                            (puthash related-uri created
                                     related-cursor-values)
                            created)))
                     (diagnostics
                     (eglotx--pull-diagnostic-snapshot
                       server backend related-uri report t)))
                (when (stringp (plist-get report :resultId))
                  (puthash
                   backend
                   (eglotx--diagnostic-child-cursor-create
                    :result-id (plist-get report :resultId)
                    :uri child-uri)
                   values))
                (unless old
                  (push related-uri related-order))
                (puthash
                 related-uri
                 (cons (or (car-safe old) wire-key)
                       (nconc (cdr-safe old) (append diagnostics nil)))
                 related-reports)))))))
    (when (and eglotx-max-diagnostics
               (> (length items) eglotx-max-diagnostics))
      (setq items (seq-take items eglotx-max-diagnostics)))
    ;; Push-only siblings stay in Eglot's ordinary pushed-diagnostics map;
    ;; including them here would make Eglot 31 report each diagnostic twice.
    (let ((result-id
           (and complete-p
                (eglotx--remember-diagnostic-cursor
                 server uri cursor-values)))
          related)
      (dolist (related-uri (nreverse related-order))
        (let* ((entry (gethash related-uri related-reports))
               (wire-key (car entry))
               (diagnostics (cdr entry))
               (visible
                (if eglotx-max-diagnostics
                    (seq-take diagnostics eglotx-max-diagnostics)
                  diagnostics))
               (related-result-id
                (and complete-p
                     (eglotx--remember-diagnostic-cursor
                      server related-uri
                      (gethash related-uri related-cursor-values))))
               (report
                (append (list :kind "full" :items (vconcat visible))
                        (when related-result-id
                          (list :resultId related-result-id)))))
          ;; Push key then value so one final reversal restores plist order.
          (push wire-key related)
          (push report related)))
      (append (list :kind "full" :items (vconcat items))
              (when result-id (list :resultId result-id))
              (when related
                (list :relatedDocuments (nreverse related)))))))

(defun eglotx--merge-responses (server request outcomes)
  "Combine successful OUTCOMES for REQUEST through SERVER."
  (pcase (plist-get (eglotx--request-policy request) :merge)
    ('initialize (eglotx--merge-initialize server outcomes))
    ('shutdown nil)
    ('append (eglotx--merge-append server request outcomes))
    ('hierarchy-calls
     (eglotx--merge-hierarchy-calls server request outcomes))
    ('locations (eglotx--merge-locations outcomes))
    ('completion (eglotx--merge-completions server request outcomes))
    ('hover (eglotx--merge-hovers outcomes))
    ('diagnostic (eglotx--merge-diagnostic-results server request outcomes))
    (_ (eglotx--merge-first server request outcomes))))

;; JSON-RPC cancellation and child request-envelope capture.

(defun eglotx--jsonrpc-receive-around (original connection message)
  "Call ORIGINAL for CONNECTION and MESSAGE, preserving child request IDs.
Capture the request ID before jsonrpc.el calls its ID-less dispatcher."
  (if (and (object-of-class-p connection 'eglotx--child-connection)
           (listp message)
           (plist-get message :method)
           (plist-get message :id))
    (let ((eglotx--child-request-envelope
           (list connection
                 (plist-get message :id)
                 (plist-get message :method))))
      (funcall original connection message))
    (funcall original connection message)))

(defun eglotx--jsonrpc-request-around (original connection method params &rest args)
  "Call ORIGINAL on CONNECTION for METHOD, PARAMS, and ARGS.
Cancel child legs if a synchronous facade request unwinds early."
  (if (not (object-of-class-p connection 'eglotx-server))
      (apply original connection method params args)
    (let ((eglotx--capturing-sync-request t)
          (eglotx--captured-sync-request-id nil))
      (unwind-protect
          (apply original connection method params args)
        (when (and eglotx--captured-sync-request-id
                   (gethash eglotx--captured-sync-request-id
                            (eglotx--requests connection)))
          (eglotx--cancel-request
           connection eglotx--captured-sync-request-id t))))))

(unless (advice-member-p #'eglotx--jsonrpc-request-around 'jsonrpc-request)
  (advice-add 'jsonrpc-request :around #'eglotx--jsonrpc-request-around))

(unless (advice-member-p #'eglotx--jsonrpc-receive-around
                         'jsonrpc-connection-receive)
  (advice-add 'jsonrpc-connection-receive :around
              #'eglotx--jsonrpc-receive-around))

(defun eglotx-unload-function ()
  "Remove global compatibility hooks installed by Eglotx."
  (advice-remove 'jsonrpc-request #'eglotx--jsonrpc-request-around)
  (advice-remove 'jsonrpc-connection-receive
                 #'eglotx--jsonrpc-receive-around)
  nil)

(provide 'eglotx)
;;; eglotx.el ends here
