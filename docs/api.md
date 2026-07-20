# Eglotx public API

This page describes the supported Emacs Lisp integration surface.  Symbols
containing `eglotx--` are private.  Construct `eglotx-server` instances through
`eglotx-contact`; class slots and internal records are not stable API.

## Loading

Manual Eglot configuration should normally load the small client adapter:

```elisp
(require 'eglotx-eglot)
```

This also loads the core.  The adapter only adds `textEdit` to Eglot's
advertised completion resolve properties, a field Eglot already consumes.  It
does not replace Eglot's CAPF or depend on Corfu.  Requiring `eglotx` directly
keeps the core-only compatibility path, which eagerly materializes shared
completion edit ranges.  `eglotx-presets` loads the adapter automatically.

## `eglotx-contact`

```elisp
(eglotx-contact BACKEND-A BACKEND-B ...)
```

Return a native `(eglotx-server ...)` contact for
`eglot-server-programs`.  The function requires at least two backend
descriptors.  A descriptor is either a non-empty argv list or a plist with a
`:command` argv and/or a `:process` factory.  If both are present, the process
factory is used.

The core always constructs a facade from this function.  The one-server argv
fast path belongs to the preset resolver, which counts resolved backends before
calling `eglotx-contact`; filtering a manual contact down to one active backend
does not remove the facade.

### Backend descriptor

| Key | Default | Contract |
| --- | --- | --- |
| `:name` | basename of argv executable | Non-empty name, unique across every declared descriptor, including inactive ones. Required when a process factory has no command from which to derive it. Names identify status rows and directed bridge targets; ownership itself uses backend identity, not this string. |
| `:command` | none | Non-empty list of strings passed directly to `make-process`; no shell expansion occurs. Required unless `:process` is a function. |
| `:process` | `nil` | Zero-argument function returning a live Emacs process. It takes precedence over `:command` and can implement a custom or remote transport. |
| `:priority` | `0` | Numeric rank. Higher ranks come first; declaration order breaks ties. The resulting order controls collection order, singleton selection, and all-error selection. |
| `:required` | `t` | A truthy value makes startup/initialization failure fatal and a later exit terminate the facade. A false value permits degraded operation after backend-owned state is withdrawn. |
| `:when` | `t` | Boolean or function called once with the facade project directory before processes start. A false result omits this backend. |
| `:initialization-options` | `nil` | JSON-shaped overlay or transformation function applied to the client's `initialize.initializationOptions` for this backend only. |
| `:settings` | `nil` | JSON-shaped overlay or transformation function applied to every `workspace/configuration` result item and to `didChangeConfiguration.params.settings` for this backend. |
| `:environment` | `nil` | Alist of string variable names to string values, scoped to this backend's process creation. |
| `:only` | `nil` | List/vector of allowed LSP method names. `nil` allows negotiated methods; an explicit empty vector allows lifecycle methods only. Lifecycle methods are never filtered. |
| `:languages` | `nil` | List of accepted LSP language ID strings. Known document traffic and open-document diagnostics are restricted to this set; `nil` accepts the facade cohort. An unopened URI remains eligible because its language is unknown. |
| `:notification-handlers` | `nil` | Alist from method names to `(lambda (facade source-backend params) ...)`. A non-nil return consumes the notification; otherwise normal forwarding continues. Handlers run on deferred work, outside process filters. |
| `:request-timeout` | `eglotx-request-timeout` | Positive seconds or `nil`. One unbounded target makes the aggregate deadline unbounded; otherwise the largest target timeout permits every concurrent leg to finish. |

Static JSON overlays recursively merge keyword-plist objects without mutating
either input; a non-object value replaces the base.  A transformation function
receives a recursively detached base value and its return value becomes the
backend value, including a deliberate nil return.  A nil descriptor value
leaves the client value unchanged.

## `eglotx-status`

```elisp
(eglotx-status &optional SERVER)
```

Interactively, display a read-only status buffer for the current Eglotx
server.  Lisp callers receive a read-only plist snapshot and must not mutate
its values:

- `:state`, `:pendingRequests`, `:pendingBridgeRequests`, `:bridgeRequests`,
  and `:documents` describe the facade;
- `:backends` is a vector whose entries contain `:name`, `:state`, `:priority`,
  `:languages`, `:required`, `:running`, `:serverInfo`, and `:lastError`.

Reading status sends no protocol messages and does not mutate routing state.

## `eglotx-backend-request`

```elisp
(eglotx-backend-request
 FACADE SOURCE TARGET-NAME METHOD PARAMS SUCCESS-FUNCTION ERROR-FUNCTION)
```

This advanced seam is for an explicitly declared backend notification adapter
that must issue one asynchronous request to a named sibling.  `SOURCE` is the
opaque backend object supplied to that handler.  Accepted requests return the
child request ID and use the smaller of the target backend timeout and
`eglotx-cross-backend-request-timeout`.

Callbacks receive one payload and always run later on the facade work queue.
An unavailable target, excluded method, or exhausted in-flight budget returns
nil and schedules the error callback.  An inactive source or stopping facade
returns nil without scheduling either callback.  Success, error, timeout,
source/target exit, and shutdown share one idempotent cleanup path.

## Customization

Use `M-x customize-group RET eglotx` for the core and
`M-x customize-group RET eglotx-presets` for discovery policy.

| Variable | Default | Purpose |
| --- | ---: | --- |
| `eglotx-request-timeout` | `30` | Default facade/backend request deadline; `nil` disables it. |
| `eglotx-backend-events-buffer-size` | `0` | Per-child JSON-RPC event-buffer size; zero disables hot-path payload logging and `nil` is unlimited. |
| `eglotx-backend-stderr-buffer-size` | `65536` | Characters retained per child stderr buffer; `nil` is unlimited. |
| `eglotx-stream-diagnostics` | `t` | Use Eglot's private streaming projection for open documents when the client advertises it and every child is push-only. |
| `eglotx-max-diagnostics` | `nil` | Optional stable cap applied when Eglotx constructs aggregate push or pull diagnostic results; streaming snapshots are unaffected. |
| `eglotx-unopened-diagnostic-uri-limit` | `4096` | Canonical unopened document identities retained across diagnostic modalities. |
| `eglotx-orphan-owner-limit` | `65536` | Opaque ownership records not attached to an open document. |
| `eglotx-document-owner-limit` | `8192` | Non-diagnostic, non-completion ownership records retained per open document. |
| `eglotx-completion-batch-limit` | `2` | Whole completion batches in each fallback lookup cache. Live Lisp candidates from managed open documents carry GC-managed leases beyond fallback eviction and retain exact document-generation ownership. Orphan candidates use the bounded fallback cache. |
| `eglotx-work-batch-size` | `32` | Deferred facade jobs handled in one event-loop turn. |
| `eglotx-diagnostic-chunk-size` | `64` | Entries handled by one diagnostic or optional-backend retirement continuation. |
| `eglotx-document-selector-limit` | `256` | Input and post-language-intersection filters accepted in one selector. |
| `eglotx-file-watcher-limit` | `4096` | Logical watched-file patterns retained by one facade. |
| `eglotx-prefix-server-messages` | `t` | Prefix forwarded log/show messages with the backend name. |
| `eglotx-cross-backend-request-limit` | `64` | Directed adapter requests simultaneously in flight per facade. |
| `eglotx-cross-backend-request-timeout` | `30` | Maximum seconds for one directed adapter request. |
| `eglotx-presets-prefer-project-local-servers` | `t` | Probe each recipe's bounded project-local executable locations before PATH. |
| `eglotx-presets-disabled-backends` | `nil` | Optional preset add-on symbols to suppress; primary selection is unaffected. |

## Preset contacts

`eglotx-presets-mode` globally installs ten project-aware entries.  Their
autoloaded contacts are `eglotx-presets-svelte-contact`,
`eglotx-presets-vue-contact`,
`eglotx-presets-angular-contact`, `eglotx-presets-html-contact`,
`eglotx-presets-css-contact`, `eglotx-presets-json-contact`,
`eglotx-presets-graphql-contact`, `eglotx-presets-python-contact`,
`eglotx-presets-go-contact`, and `eglotx-presets-ruby-contact`.
`eglotx-presets-typescript-contact` is also public for a manual generic JS/TS
mapping without the Angular detector.

Each contact accepts optional `INTERACTIVE` and `PROJECT` arguments.  `PROJECT`
defaults to the current project.  Missing required components first delegate
to the matching contact captured by `eglotx-presets-mode`; without a fallback,
interactive resolution returns nil so Eglot can prompt, while noninteractive
resolution signals `eglotx-configuration-error`.  One resolved backend returns
an ordinary argv contact; two or more return an Eglotx facade.  Exact recipes,
intent gates, and trust boundaries are defined in [`presets.md`](presets.md).
