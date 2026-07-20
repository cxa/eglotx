# Eglotx implementation specification

## Goal

Provide Eglot with one language-server facade that supervises and consumes
multiple Language Server Protocol backends.  The implementation runs inside
Emacs Lisp and has no external multiplexer runtime.

An optional module provides deterministic project-aware contacts without
putting language, manifest, executable-discovery, or global contact policy in
the facade core.

Performance and predictable protocol behavior take precedence over broad but
ambiguous merging.

This file is the normative behavioral contract.  Public Elisp argument and
customization details live in [`api.md`](api.md); implementation mechanisms
live in [`architecture.md`](architecture.md); dated research is non-normative.

## Public behavior

- A caller can construct an Eglot server program from two or more ordinary LSP
  command lists or custom process factories, with optional per-backend name,
  priority, activation, initialization options, settings, timeout, method
  filter, accepted LSP language IDs, explicit notification handlers,
  environment, and required/optional status.
- The returned value is accepted directly by `eglot-server-programs` and uses a
  subclass of `eglot-lsp-server`.
- Eglot sees one deterministic set of capabilities and one server lifecycle.
- Client notifications are broadcast or capability-routed as required by LSP.
  Document synchronization is adapted per backend when synchronization kinds
  differ. A backend language restriction filters document requests,
  notifications, and diagnostics whose document language is known.
- Client requests are sent concurrently. Results are combined in descending
  backend priority, with declaration order breaking ties, using method-specific
  rules. A single target uses the same observable contract without waiting for
  unrelated backends.
- Resolve requests and commands return to the backend that produced the item.
  Opaque `data` and progress tokens cannot collide between backends. Every
  backend command exposed through the facade
  uses an opaque, session-scoped identifier, even when its raw name is unique.
  This includes inline-completion and code-action documentation commands.
- Cancellation reaches every child request already created for the facade
  request. Late replies cannot revive a cancelled or completed request.
  Server-to-client child requests retain their raw envelope and connection-local
  ID until completion; child `$/cancelRequest` targets only that exact active
  handler and returns `RequestCancelled`, without crossing nested, sibling, or
  facade request scopes.
- A required backend start/initialize failure or unexpected process exit aborts
  startup or closes the facade and all siblings. An optional lifecycle failure
  degrades the running session after withdrawing that backend's capabilities,
  registrations, diagnostics, progress mappings, ownership, and pending request
  legs. An ordinary request error follows the method's partial-success policy
  and does not by itself retire the backend.
- `shutdown` and `exit` reach every live backend.  Forced facade shutdown closes
  every backend and the internal anchor process.
- An explicitly declared notification handler runs outside process filters and
  may issue bounded asynchronous requests through `eglotx-backend-request`;
  each request targets one named sibling and the facade-wide in-flight count is
  capped. Its private
  pending state is independent from facade fan-out and is released on every
  success, error, timeout, process-exit, and shutdown path.

### Optional presets

- Requiring the core does not inspect projects or mutate
  `eglot-server-programs`.
- `eglotx-presets-mode` reversibly prepends its bundled contacts; disabling
  it removes only the exact entries that it installed.
- Enabling the mode snapshots preceding Eglot contacts. If a bundled recipe
  cannot resolve its supported required primary or required configuration, it
  returns the matching saved static contact or calls the saved functional
  contact with its supported arity. Disabling clears the fallback state.
- The contacts cover Svelte and Astro components, Vue SFCs, one Angular-aware
  JavaScript/TypeScript cohort, HTML, CSS/SCSS/Less, JSON/JSONC, GraphQL,
  Python, the complete Go
  source/module/workspace cohort, and Ruby. JSONC is ordered before its JSON
  parent modes so Eglot retains the exact language ID.
- The Svelte entry assigns language ID `svelte` to `svelte-ts-mode` and
  `svelte-mode`. `svelteserver --stdio` is its sole required structural primary
  because that process embeds Svelte, HTML, CSS, and JS/TS plugins.  The contact
  must not start TypeScript, HTML, or CSS Language Server for a `.svelte` URI.
  SvelteKit adds no separate server; `.svelte.ts` and `.svelte.js` remain in the
  ordinary JS/TS cohort.
- Svelte may add intent-gated ESLint, Tailwind CSS, GraphQL, and Biome >= 2.3,
  each restricted to language ID `svelte` and its complementary method role.
  Embedded ESLint requires a structural config or manifest dependency; a local
  `vscode-eslint-language-server` executable alone is not intent because it can
  be incidental to a shared extracted-language-server package.
  GraphQL still requires structural GraphQL Config.  ESLint and Tailwind do not
  own formatting.  Biome without an explicit project
  `html.experimentalFullSupportEnabled: true` flag omits formatting and runs
  below Svelte priority; with the flag it is the single higher-priority
  formatter.  Completion/code-action resolve and diagnostics retain their
  producing backend through the generic core ownership model.
- The Astro entry is ordered before HTML and assigns language ID `astro` to
  `astro-ts-mode` and legacy `astro-mode`; it does not claim generic
  `web-mode`.  `astro-ls --stdio` is its sole required structural primary and
  owns the Astro, TypeScript/JavaScript, HTML, and CSS regions of an `.astro`
  document.  The contact must not start TypeScript, HTML, CSS, Vue, or Svelte
  Language Server for that URI.
- Astro Language Server additionally requires the nearest project
  `node_modules/typescript/lib/` directory containing `typescript.js` or
  `tsserverlibrary.js`.  The contact passes that directory through
  `initializationOptions.typescript.tsdk`; a missing validated SDK delegates
  to the preceding Eglot contact instead of starting a server that cannot
  initialize.
- Astro may add intent-gated ESLint, Tailwind CSS, GraphQL, and Biome >= 2.3,
  each restricted to language ID `astro` and the same complementary embedded
  method roles as the shared embedded-Web policy.  Embedded ESLint still
  requires a structural config or manifest dependency, and GraphQL still
  requires structural GraphQL Config.  Without an explicit project
  `html.experimentalFullSupportEnabled: true` flag, Biome omits formatting and
  runs below Astro priority; with the flag it is the higher-priority
  formatter.  ESLint, Tailwind, and GraphQL never own Astro formatting.
- The TypeScript contact prefers the nearest executable under an ancestor
  `node_modules/.bin`, bounded by the project root, before the correct local or
  remote PATH.
- TypeScript Language Server is required. Biome, ESLint, Tailwind CSS, and
  embedded GraphQL are optional and activate only under their recipe's strong
  project intent. Depending on the add-on, that is a structurally matched
  marker, an exact dependency, required GraphQL configuration, or a
  project-local executable. Marker matching uses punctuation-delimited filename
  segments rather than relying on an exhaustive filename list.
- Vue SFCs require Vue Language Server, TypeScript Language Server, a validated
  `@vue/language-server` package directory, and the private TypeScript bridge.
  Both children accept `vue`; TLS loads `@vue/typescript-plugin` from the
  selected VLS package. The nearest TypeScript SDK is passed to TLS and, for a
  compatible VLS version, through `--tsdk`. Missing any required component
  delegates to the preceding Eglot contact instead of starting a partial stack.
- Vue reuses the ESLint, Tailwind, and GraphQL intent gates. Biome joins Vue
  only for a selected package version >= 2.3. Without the project's explicit
  experimental full-HTML flag it is restricted to diagnostics/code actions
  below VLS priority; with that flag it may own whole-SFC formatting.
- Biome runs through `biome lsp-proxy`. Its priority places an advertised Biome
  formatter ahead of TypeScript formatting after explicit project intent;
  standard capabilities that Biome does not advertise continue to use
  TypeScript. The same priority makes Biome the highest-priority eligible
  backend for unknown extension methods while active. The preset supplies an
  empty settings object without replacing user-provided `biome` workspace
  settings.
- The ESLint recipe validates after project intent is established, lets the
  server infer the working directory per document, and does not override the
  ESLint generation's legacy/flat-config selection.
- Angular is an optional member of the single JS/TS cohort and accepts only
  the `typescript` language ID. The CSS cohort includes CSS, SCSS, and Less,
  while its Biome add-on accepts only `css`. The Go cohort includes `go`,
  `go.mod`, and `go.work`, while GolangCI accepts only `go`.
- Python chooses one full primary and may add `ruff server` at priority 120.
  Ruff's method filter lets it win formatting without claiming structural
  requests from the primary. Ruby checks every local primary alternative
  before falling back to PATH.
- GraphQL requires structural GraphQL Config and passes its directory through
  `--configDir`. Config presence is intentionally a conservative project-level
  intent signal; GraphQL Language Service remains responsible for matching
  individual documents and may ignore a cohort document.
- Two or more resolved backends produce an `eglotx-contact`; one resolved
  backend produces an ordinary Eglot contact and retains its static
  initialization options. A missing required primary
  or required config first delegates to the pre-preset contact; only without a
  resolved fallback does it return nil for interactive selection or signal a
  configuration error for noninteractive startup.

## LSP semantics

### Initialization and capabilities

- `initialize` and `shutdown` target every live backend.
- All backends negotiate UTF-16 positions so one Eglot document representation
  is valid for every child.
- Capabilities are combined with a documented rule per capability.  Boolean
  providers use logical union where requests can be routed or combined.
  Trigger-character and command arrays use stable union.  Singleton providers
  such as semantic tokens come from the highest-priority capable backend.
- Static document capabilities are exposed only when their providers cover
  every language in the facade cohort. Static `documentSelector` values are
  intersected with backend language restrictions, merged only when their union
  covers the facade, and enforced during routing. Semantic tokens require one
  provider that covers the complete cohort. Semantic-token, notebook-sync, and
  workspace-file-operation owners are sticky: provider loss withdraws the
  capability instead of selecting an incompatible sibling.
- `textDocumentSync` advertises one facade mode and translates changes for
  full-sync backends when necessary.
- Workspace-folder support is a logical union. Each client-supported static
  file operation copies one highest-priority provider's filters and remains
  pinned to that provider; unsupported dynamic file operations fail explicitly
  rather than being cross-routed.
- Server information reports all successfully initialized backends in stable
  order.
- Backend settings are applied when proxying `workspace/configuration` replies
  and `workspace/didChangeConfiguration` notifications; initialization does
  not synthesize an extra settings notification.

### Request policies

- Location links are normalized to locations before stable concatenation and
  exact de-duplication.
- Highlight, code-action, code-lens, document-link, color, folding-range,
  hierarchy-prepare, inlay-hint, inline-value, moniker, and workspace-symbol
  collections are stably concatenated and exactly de-duplicated. Follow-up
  hierarchy and resolve requests return to the producing backend.
- Document symbols use the highest-priority capable backend so the facade
  cannot mix the alternative `DocumentSymbol[]` and `SymbolInformation[]`
  result shapes.
- Completion preserves every item without cross-backend de-duplication, ORs
  `isIncomplete`, and negotiates only the `data` and `editRange` item defaults
  the facade can retain compactly. Shared defaults live once per backend
  segment; the selected item is materialized only for resolve or client
  compatibility. Completion and signature-help requests with a trigger
  character target only children that advertised that trigger.
- Inline completion uses only the highest-priority capable backend, preserves
  either legal array/list shape, and namespaces every item command.
- Hover contents are combined into one Markdown hover in backend order.
- Signature help, selection ranges, linked editing, all formatting variants,
  rename/prepare, will-save edits, and semantic tokens use the highest-priority
  eligible capable backend. Semantic-token full/delta/range share one pinned
  provider and legend.
- Diagnostics combine full and unchanged reports without exposing child
  `resultId` values. A facade provider identifier is advertised only when at
  least one child supplied a string identifier; each request leg receives its
  own child identifier when one exists, otherwise the field is omitted. Facade
  cursors restore only the corresponding backend's incremental state.
- Execute-command uses the backend encoded by the opaque command identifier;
  static workspace file operations use the provider selected with their
  advertised filters.
- If at least one backend succeeds, failed backend responses do not discard the
  successful result.  If all fail, the highest-priority error is returned.
- Unknown dynamically registered methods return to their registration owner.
  Other unknown methods go to the highest-priority eligible live backend after
  liveness, `:only`, and known-language filtering. Unknown static capabilities
  remain more conservative: they are exposed only from the actual primary when
  it covers the complete language cohort.
- Child partial-result tokens are omitted because raw chunks would bypass the
  method-specific merge and ownership pipeline. Work-done progress is
  namespaced for a single-target request and omitted for fan-out; cancellation,
  timeout, or failure synthesizes `end` only for a lifecycle that began.

### Diagnostics

- Diagnostics are replace-by-key snapshots keyed by canonical document
  identity, backend, and source modality (push or pull), not
  append-only lists.
  Open-document snapshots also track the document generation. An empty
  publication clears only its source backend and modality.
- `file:` URI identity is canonicalized lexically without filesystem or TRAMP
  I/O: scheme/host case, percent encoding of unreserved characters, dot
  segments, and Windows drive spelling are normalized and cached. Non-file
  URIs are opaque and compare exactly.
- A language-scoped backend contributes diagnostics for an open document only
  when it accepts that document's language ID. Diagnostics for unopened URIs
  remain eligible because their language is unknown to the facade.
- An open document accepts a versioned push publication only when its version
  exactly equals the current document version, including version zero; both
  older and future versions are dropped.  For an unopened URI, a version below
  that source's numeric high-water mark is dropped. Versionless diagnostics are
  accepted without erasing that watermark.
- When Eglot advertises streaming-diagnostics support and the successfully
  initialized cohort is entirely push-only, each backend is exposed with a
  stable namespaced token for open managed documents. This choice is fixed for
  the session; losing an optional pull backend does not switch projections
  mid-session. Unopened URIs always receive one deterministic
  ordinary aggregate because Eglot's list-only path does not retain streaming
  token state. A cohort containing any pull provider uses ordinary aggregate
  publications for push-only backends, allowing Eglot to combine that map with
  pulled reports. Older Eglot versions also receive aggregate publications.
  Streaming is an Eglot-facing projection, not a child protocol: the private
  capability is removed from every child initialize request and an unsolicited
  child `$/streamDiagnostics` notification is ignored.
- Unopened diagnostic state across push and pull modalities is held
  in one O(1) exact LRU bounded by `eglotx-unopened-diagnostic-uri-limit` (4096
  by default); open
  documents are lifecycle-managed and exempt. Eviction releases every source,
  owner, cursor, snapshot, and version watermark for that canonical URI, then
  retracts a visible aggregate. Initial empty reports are not projected for an
  unseen URI. Empty clears and `didOpen` remove Eglot's exact server-owned
  list-only alist cell so the client-side view is bounded too.
- A merged pull provider advertises one opaque facade `identifier` only when at
  least one child supplied a string identifier. Each child request receives its
  original identifier when present and otherwise omits the field. Facade
  document `resultId` cursors map to per-backend child cursors, are bounded, and
  are valid only for the canonical URI and exact open-document generation.
  Unknown or evicted
  cursors force a full request. Related documents use the same identity and
  cursor rules; partial child failure does not mint a reusable aggregate cursor. A
  primary document mutation during an in-flight request returns
  `ContentModified`; related documents whose mutation epoch changes are omitted.
  If primary/related ingestion evicts an unopened URI before merge finalization,
  no facade cursor is minted for it and the next request is necessarily full.
- Diagnostic `data` remains inside Eglotx behind a small ownership token and is
  restored only for its source backend. Visible diagnostic `source` is prefixed
  as `backend/source`, or set to `backend` when the child omitted it. A backend
  that negotiated pull diagnostics does not also contribute its ordinary push
  snapshot to the aggregate, avoiding duplicate display.
- Non-streaming diagnostic bursts are coalesced and processed in bounded queue
  continuations. Each complete diagnostic array is validated before replacing
  ownership or snapshot state; one malformed child report is dropped without
  discarding valid reports in the same batch.

### Dynamic watched files

- Eglot advertises dynamic registration only for
  `workspace/didChangeWatchedFiles`. Every other child dynamic registration is
  rejected instead of being projected through a private capability model.
- Initialize-time `StaticRegistrationOptions.id` values are child-local and are
  stripped from aggregate provider options. Static workspace-folder
  `changeNotifications` strings are normalized to boolean support. Diagnostic
  provider `identifier` remains a separate incremental cursor namespace.
- A language-scoped backend's initialize-time document selectors are
  intersected with its accepted language IDs. Selector input and expansion are
  capped by `eglotx-document-selector-limit` (256 by default).
- Dynamic `workspace/didChangeWatchedFiles` registrations expose the stable
  union of child watcher patterns. A file-change notification is routed only
  to backends whose live registrations match at least one change. Registration
  arrays and the total retained pattern set are capped by
  `eglotx-file-watcher-limit` (4096 by default). Physical reconciliation runs
  on the facade FIFO after the child request has been acknowledged. Duplicate
  rebuilds coalesce; an upstream Eglot failure retries with bounded exponential
  backoff, while a newer logical state cancels the delay and reconciles now.
  Physical watchers retain only defined LSP fields and use a stable sort order.
- Removing a registration or losing an optional backend removes its watcher
  contribution without disturbing registrations owned by other backends.

### Refresh invalidations

- `workspace/semanticTokens/refresh` from the pinned semantic-token provider is
  acknowledged immediately and forwarded to Eglot's upstream handler on the
  facade FIFO. A pending bit coalesces duplicate refreshes until that handler
  returns. The same request from an inactive sibling is acknowledged and
  dropped.
- The facade does not recognize or coalesce refresh methods that Eglot does not
  advertise.

## Performance requirements

- There is no JSON encode/decode, socket hop, or subprocess between Eglot and
  the facade.  Only actual backend process boundaries use LSP framing.
- Backend requests are concurrent and share one idempotent finalizer. A facade
  deadline is optional: when bounded, it starts before fan-out and is the
  largest target timeout; one unbounded target makes the aggregate unbounded.
  Graceful `shutdown` is the exception and uses a fixed one-second facade
  deadline so Eglot's own shutdown remains authoritative.
- Backend event payload logging is disabled by default and backend stderr
  retention is bounded. Facade logging follows Eglot's own event-buffer
  configuration.
- Method policies and namespace indexes use hash tables on hot paths; target
  selection traverses only the bounded configured backend list and current
  registration records. Backend language membership is hash-indexed rather
  than scanned. Result order may not depend on process scheduling.
- Notification handlers are method-hash lookups. Their directed targets use a
  per-facade backend-name hash; at most
  `eglotx-cross-backend-request-limit` requests are live and each has a finite
  `eglotx-cross-backend-request-timeout` deadline.
- Completed requests release timers, continuations, and request-owned tokens.
  Open-document and workspace ownership are bounded independently. For an open
  managed document, a completion candidate retained by an active CAPF session
  remains resolvable across fallback-cache eviction, GC, and `didChange`;
  closing/reopening the document or retiring its backend invalidates it. A
  document mutation while completion or resolve is in flight still returns
  `ContentModified`. Abandoned completion state is GC-reclaimable, shared
  defaults do not become per-item owner records, and a client without lazy
  resolve-time `textEdit` support retains the eager compatibility behavior.
- Deferred work and diagnostic bursts have independent per-turn/per-job bounds.
  Initialize-time selectors accept and produce at most
  `eglotx-document-selector-limit` filters. Watched-file registration arrays,
  retained patterns, and reconciliation work are bounded by
  `eglotx-file-watcher-limit`; only the retained watcher path is copied.
  File-watch projection failures use one coalesced, bounded-backoff retry.
  Semantic refresh is acknowledged before its upstream handler runs on the
  deferred facade FIFO, and a request burst retains only one queued refresh.
- Optional-backend retirement is incremental, bounded per event-loop turn, and
  safe across errors, quits, and other non-local exits. A persistent client
  projection failure is rate-limited and cannot starve unrelated facade work.
- Unopened diagnostics retain at most
  `eglotx-unopened-diagnostic-uri-limit` canonical identities across push,
  pull, and cursor metadata. Open document state is released by
  generation/lifecycle instead of this LRU.
- The repository includes repeatable microbenchmarks for route selection,
  UTF-16 change application, capability combination, completion
  merge/ownership, diagnostic attribution, and the 11,509-item Tailwind
  shared-default path. Integration tests use real Emacs processes speaking LSP
  framing. An opt-in real Tailwind fixture also exercises Eglot CAPF, Orderless,
  Corfu candidate computation, delayed resolve, and final buffer insertion.
- Preset discovery is a new-session cold path. It retains at most 32 nearest
  ancestors plus the project root, reads at most 1 MiB from one metadata file
  and 4 MiB per contact context, and caches positive and negative probes. Local
  fallback detection performs bounded non-recursive marker listings and
  retains at most 64 keyword-bearing candidates per listing; remote projects
  skip listings. Discovery never recursively scans a project or invokes a
  package manager. Python virtual-environment executable probes use only the
  nearest eight ancestors plus the project root.

## Compatibility and security

- Support GNU Emacs 29.1 and newer with Eglot 1.24+ and jsonrpc.el 1.0.29+;
  older Emacs releases obtain these upstream versions from GNU ELPA.
- Backend commands are argv lists and are never evaluated by a shell.
- Remote projects may supply a custom process factory returning a live Emacs
  process; local commands inherit the project `default-directory`.
- Malformed backend messages are handled by `jsonrpc.el`; malformed diagnostic
  payloads and initialize-time selectors are additionally rejected
  transactionally before mutation. One backend cannot corrupt another
  backend's request namespace.

## Current non-goals

- Automatically restarting a crashed backend and replaying complete workspace
  state.
- Acting as a general stdio LSP executable for non-Eglot clients.
- Guessing project-specific server sets inside the facade core. Bundled policy
  belongs to the optional presets module; manual core contacts remain supported.
- Defaulting to Terraform plus TFLint while TFLint performs a complete,
  non-debounced inspection on every document change.
- Sending Angular external HTML templates through the JS/TS facade before one
  child process can be shared safely across separate Eglot cohorts.
- Inferring or implementing server-specific private protocols in the core.
  Only an explicitly configured adapter may use the generic bounded directed
  request seam; Vue's payload policy lives entirely in the presets layer.
- Multiplexing `workspace/diagnostic`. The facade advertises
  `workspaceDiagnostics: false` and implements document pull diagnostics only.

## Acceptance checks

1. Two fake servers initialize concurrently and expose a stable merged facade.
2. Completion, locations, hover, code action, resolve, and execute-command
   routing return correct deterministic results.
3. Full and incremental document-sync backends receive valid changes.
4. Duplicate child request IDs, progress tokens, and opaque data never
   cross-route.
5. Cancellation and timeout release every child leg. A required-child crash
   closes the facade and all siblings; an optional-child crash leaves healthy
   siblings usable and releases only failed-backend state. Shutdown and exit
   leave no live child process or pending facade request.
6. Push diagnostics from two servers remain independently clearable for open
   and unopened documents; equivalent file URIs coalesce, and stale
   publications do not replace current diagnostics.
7. The package byte-compiles without warnings and all ERT tests pass on the
   supported Emacs matrix.
8. Multiple dynamic watched-file registrations expose their stable union and
   each change reaches only its matching registration owners.
9. Workspace-folder notifications fan out only to requesting backends, while
   file-operation filters and their pinned request/notification owner agree.
10. Backend language restrictions filter document traffic and open-document
    diagnostics, intersect static selectors, and never expose a partial-cohort
    static document or semantic-token capability as facade-wide support.
11. Vue VLS `tsserver/request` double-array params become one directed TLS
    execute-command and return as `tsserver/response`; success, error, timeout,
    source exit, and target exit all leave zero private pending records.
12. Pull-diagnostic provider identifiers and document/related cursors retain
    per-backend affinity, expire safely across close/reopen, and never send one
    child's `resultId` to a sibling.
13. Only the pinned semantic-token provider can forward a semantic refresh;
    child static registration IDs never escape the facade.
14. An open-document completion candidate held by Corfu/Eglot remains
    resolvable after newer CAPF batches evict its fallback entry, after GC, and
    after `didChange`; close/reopen and backend retirement reject the stale
    candidate, while in-flight mutation returns `ContentModified`.
15. The Svelte ESLint and Biome fixtures each start exactly one Svelte
    structural primary plus the intended add-ons; both deliver independent
    type/lint diagnostics, reject stale Svelte 5 rune diagnostics, and preserve
    both Svelte and Tailwind completion/resolve ownership, while formatter
    ownership changes from Svelte to Biome only under the explicit full-support
    project flag.
16. The Astro ESLint and Biome fixtures each start exactly one Astro
    structural primary plus the intended add-ons; both deliver independent
    Astro type and lint diagnostics and preserve Astro and Tailwind
    completion/resolve ownership.  The ESLint fixture leaves formatting with
    Astro, while the explicit full-support Biome fixture gives formatting to
    Biome.  No TypeScript, HTML, CSS, Vue, or Svelte child starts for the
    `.astro` document.
