# Eglotx

Eglotx is an in-process Language Server Protocol multiplexer for
[Eglot](https://www.gnu.org/software/emacs/manual/html_mono/eglot.html). It
lets one Eglot session use several language servers without putting another
executable, socket, or JSON encode/decode hop between Eglot and Emacs Lisp.

The facade is an ordinary `eglot-lsp-server` subclass. Each configured backend
is an independent `jsonrpc-process-connection`, so backend I/O still uses the
framing and validation supplied by Emacs's `jsonrpc.el`.

## Requirements

- GNU Emacs 29.1 or newer
- Eglot 1.24 or newer and jsonrpc.el 1.0.29 or newer (available from GNU ELPA
  when an older Emacs bundles earlier versions)
- the server set required by the selected preset, or two or more backend
  descriptors for a manual multiplexer contact

The multiplexer itself has no external runtime; selected language servers
remain normal project/toolchain dependencies.  Eglotx never invokes a backend
through a shell.

## Installation

### `use-package` with `:vc`

Install the current stable release with `package-vc` and enable the preset
catalog:

```elisp
(use-package eglotx
  :vc (:url "https://github.com/cxa/eglotx.git"
       :rev :last-release)
  :demand t
  :config
  (require 'eglotx-presets)
  (eglotx-presets-mode 1))
```

The declaration uses `eglotx`, whose main file carries the package metadata;
`eglotx-presets` is a secondary feature in the same checkout.  `:last-release`
selects the latest revision that changed the main file's `Version:` header.
Use `:newest` to follow the development branch, or an explicit tag string to
pin one immutable release.  This README describes `main`; features listed under
[Unreleased](CHANGELOG.md) require `:newest` until the next release.

The built-in `use-package` supports `:vc` on Emacs 30.1 and newer.  Emacs 29's
built-in version does not; either update `use-package` from GNU ELPA or install
the VC package once before using an ordinary declaration:

```elisp
(require 'package-vc)
(unless (package-installed-p 'eglotx)
  (package-vc-install
   '(eglotx :url "https://github.com/cxa/eglotx.git")
   :last-release))
```

### Source checkout

On Emacs 29, update Eglot and jsonrpc from GNU ELPA first if the bundled
versions are older than the declared minimums.  Then put the checkout on
`load-path` and enable the optional presets layer:

```elisp
(add-to-list 'load-path "/path/to/eglotx")
(require 'eglotx-presets)
(eglotx-presets-mode 1)
```

## Preset behavior

The global mode covers Svelte, Astro, Vue, JavaScript/TypeScript (including
React JSX and TSX), HTML, CSS/SCSS/Less, JSON/JSONC, GraphQL, Python, Go
source/module/workspace files, and Ruby.  A recipe normally selects one
structural primary and adds only intent-backed complementary servers such as
Ruff, GolangCI, Sorbet, ESLint, Tailwind CSS, Biome, GraphQL, or Angular.
Embedded component recipes avoid duplicating services already supplied by
their framework server; Vue keeps its required VLS/TLS/plugin stack because
that is an upstream protocol requirement.

Discovery prefers the nearest executable in the ecosystem's project directory
(`node_modules/.bin`, a Python virtual environment, a Ruby binstub directory,
or a bounded Go project bin directory) before falling back to PATH.  Astro also
requires a validated project TypeScript SDK.  Exact modes, language IDs,
commands, intent gates, priorities, and formatter ownership live only in the
authoritative [preset catalog](docs/presets.md).

Start the session normally with `M-x eglot` or `eglot-ensure`.  A bundled preset
contact that resolves to one backend returns an ordinary Eglot contact, so
single-server projects skip the multiplexer overhead; required static
initialization options such as Astro's TypeScript SDK are retained on that
fast path.  Optional add-ons are not enabled just because a matching executable
happens to be on PATH: they also need a strong project signal such as a
supported config, manifest declaration, or project-local executable.
Recipe-specific exceptions are documented in the preset catalog.

Enabling the mode snapshots the matching contacts that already precede the
bundled catalog.  If a recipe cannot resolve a required component or project
configuration, it delegates to that earlier static or functional Eglot contact
instead of shadowing it.  Disabling the mode removes only its owned entries and
clears the fallback snapshot.

The presets and their bounded discovery engine are deliberately separate from
the protocol core: requiring `eglotx` alone never installs language contacts
or reads project files.  See [`docs/presets.md`](docs/presets.md) for exact
detection, fallback, remote, and trust behavior.

The preset engine automatically loads the small `eglotx-eglot` client adapter.
It extends Eglot's advertised completion-resolve properties with `textEdit`,
which Eglot already consumes, without replacing Eglot's CAPF or depending on
Corfu or another completion UI. Manual core users can require the adapter
explicitly; core-only clients retain the eager compatibility path.

## Core/manual configuration

For other languages or explicit server policy, require the core and install the
contact returned by `eglotx-contact` in `eglot-server-programs`:

```elisp
(add-to-list 'load-path "/path/to/eglotx")
(require 'eglotx-eglot)

(add-to-list
 'eglot-server-programs
 `(python-mode
   . ,(eglotx-contact
       '(:name "basedpyright"
         :command ("basedpyright-langserver" "--stdio")
         :priority 100
         :required t)
       '(:name "ruff"
         :command ("ruff" "server")
         :priority 120
         :required nil
         :only (:textDocument/didOpen
                :textDocument/didChange
                :textDocument/didClose
                :textDocument/didSave
                :workspace/didChangeConfiguration
                :workspace/didChangeWatchedFiles
                :workspace/configuration
                :textDocument/codeAction
                :codeAction/resolve
                :workspace/executeCommand
                :textDocument/formatting
                :textDocument/rangeFormatting
                :textDocument/diagnostic)))))
```

The comma is significant: `eglotx-contact` constructs the native
`(eglotx-server ...)` contact that Eglot consumes. Once configured, start the
session normally with `M-x eglot` or `eglot-ensure`.

Manual contacts should pair complementary servers and declare conflicts with
priority, `:only`, or `:languages`; starting several interchangeable full
servers duplicates indexing and produces ambiguous ownership.  Argv shorthand
is supported for backends that truly need no policy, but production contacts
usually benefit from explicit names and roles.

The complete descriptor contract, overlay semantics, status schema, bridge
API, and customization variables are in [`docs/api.md`](docs/api.md).

## Behavioral model

- Capable backends run concurrently.  Method-specific policies combine results
  in descending priority and declaration order; callback timing is invisible.
- Follow-up data, commands, progress, registrations, diagnostics, cancellation,
  and incremental cursors retain their producing backend identity across the
  facade.  Unknown registered methods return to their owner; other unknown
  methods use the highest-priority eligible live backend rather than an
  invented generic merge.
- Completion keeps whole response batches and shared `itemDefaults` compact.
  Live Eglot/Corfu candidates retain resolve affinity across replacement
  requests and document changes without an unbounded global cache.
- Diagnostics are replaceable backend-owned snapshots.  One backend's empty
  publication cannot clear a sibling; open push-only cohorts may use Eglot's
  streaming extension, while unopened and mixed pull/push views are aggregated.
- Required backend failure ends the facade.  Optional backend failure withdraws
  only its owned state and leaves healthy siblings running.  Backends are not
  automatically restarted and workspace state is not replayed.
- Requiring the core installs no language policy and performs no project
  discovery.  Preset policy remains in optional modules.

[`docs/spec.md`](docs/spec.md) is the normative behavioral contract;
[`docs/architecture.md`](docs/architecture.md) explains the implementation and
performance invariants.

## Status and troubleshooting

Run `M-x eglotx-status` from a managed buffer to inspect the facade and its
children. The status view is read-only: displaying it does not send protocol
messages, restart processes, or mutate routing state.

For a manual contact, verify PATH fallback with `executable-find`, then inspect
`:when`, `:only`, and `:languages`.  For a preset, also check the ecosystem's
project-local executable directory and the recipe's intent signal in
[`docs/presets.md`](docs/presets.md); PATH availability alone never activates
an add-on.  After changing dependencies, config, or preset options, run
`eglot-shutdown` and start a new session.  `eglot-reconnect` intentionally
reuses the already resolved contact.

Backend payload logging is disabled by default, stderr retention is capped at
64 KiB, and Eglot's settings still control facade event logging.  Use
`M-x customize-group RET eglotx` for diagnostics, messages, memory bounds,
deferred work, and bridge limits, or consult the complete table in
[`docs/api.md`](docs/api.md).  Use `M-x customize-group RET eglotx-presets` for
local-executable preference and add-on opt-outs.

Eglotx targets the current upstream Eglot language-cohort and jsonrpc
continuation APIs on every supported Emacs. This keeps version shims out of the
hot path; `make deps` installs the minimum GNU ELPA packages when necessary.

## Development

```sh
make deps       # install minimum Eglot/jsonrpc versions when needed
make deps-corfu-e2e # install optional Corfu/Orderless E2E dependencies
make compile    # byte-compile with warnings promoted to errors
make test       # run the ERT integration suite
make check      # clean, compile, and test
make test-presets-e2e # opt-in real ESLint/Biome/Vue/Svelte/Astro smoke tests
make test-corfu-e2e # real Tailwind -> Eglot -> Orderless -> Corfu insertion
make benchmark  # run repeatable protocol hot-path microbenchmarks
```

`test-corfu-e2e` reports three warm end-to-end samples and allocations.  It
retains one old candidate across replacement CAPF calls and GC, then verifies
delayed docs resolve and final insertion.  Its default local gate is 150 ms;
set `CORFU_E2E_MAX_SECONDS=0` to report without a gate, or override it with a
same-machine baseline.

`make benchmark` measures route selection, UTF-16 change application,
capability combination, completion merge/ownership, diagnostic attribution,
and a large Tailwind shared-default path.  CI runs `make check` on
Emacs 29.4, 30.2, and `snapshot`; it does not run real-server E2E targets,
benchmarks, or machine-specific latency gates.

The documentation map in [`docs/README.md`](docs/README.md) distinguishes the
public API, normative behavior, current preset policy, implementation details,
and dated research.  Read [`CODING_STANDARDS.md`](CODING_STANDARDS.md) before
changing a hot path.  Maintainers cut versions using
[`docs/releasing.md`](docs/releasing.md).

## Scope and prior art

Eglotx is specifically an Eglot facade, not a general stdio proxy. The design
builds on ideas explored by
[rassumfrassum](https://github.com/joaotavora/rassumfrassum),
[lspx](https://github.com/thefrontside/lspx), and
[cxa/lspx](https://github.com/cxa/lspx), while removing the external runtime
and extra transport required by an executable multiplexer. The earlier
[eglot-lspx](https://github.com/cxa/eglot-lspx) integration informed the Eglot
contact API. The state model also follows the useful boundary in
[lsp-mode](https://github.com/emacs-lsp/lsp-mode): each server connection owns
its diagnostics and follow-up state, and the UI-facing view is aggregated only
after those source states have been updated. Eglotx makes that implicit
workspace dimension explicit inside its single facade connection.

## License

Eglotx is free software licensed under
[GNU GPL version 3 or later](LICENSE).
