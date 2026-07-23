# Changelog

All notable changes to Eglotx are documented in this file. The project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) and follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- The manual core example now covers both Python major modes and explicitly
  distinguishes static contacts from preset discovery, fallback, optional
  backend gating, and the native single-server fast path.
- The project history now identifies Eglotx as the maintained successor to the
  archived `cxa/lspx` and `eglot-lspx` stack, and records the performance
  lessons carried forward from `cape-tailwindcss` without implying code or API
  compatibility.
- The installed JavaScript/TypeScript/React entry now uses the accurately named
  `eglotx-presets-javascript-typescript-react-contact`; Angular is documented
  as an optional backend activated only by Angular project signals and
  restricted to TypeScript documents.

## [0.1.2] - 2026-07-20

### Added

- Expand the bundled JavaScript/TypeScript cohort to common React modes from
  `rjsx-mode`, `js2-mode`, `jtsx`, and `tsx-mode`, with exact
  `javascriptreact` or `typescriptreact` language IDs.

### Changed

- Stable `use-package :vc` and direct `package-vc-install` examples now use
  `:last-release` instead of embedding a version tag.

## [0.1.1] - 2026-07-20

### Added

- A zero-configuration Astro contact for `astro-ts-mode` and legacy
  `astro-mode`.  It runs `astro-ls --stdio` as the sole structural primary,
  supplies its required nearest project TypeScript SDK, and adds only
  intent-gated ESLint, Tailwind CSS, Biome 2.3+, and GraphQL backends with
  Astro-specific language and method boundaries.
- Separate minimal Astro ESLint and Biome fixtures plus real-server E2E targets
  for type/lint diagnostics, formatter ownership, and Astro/Tailwind
  completion/resolve.
- A zero-configuration Svelte contact for `svelte-mode` and `svelte-ts-mode`.
  It uses project-local-or-PATH `svelteserver` as the sole structural primary
  and adds only intent-gated ESLint, Tailwind CSS, Biome 2.3+, and GraphQL
  backends with Svelte-specific language and method boundaries.
- Separate minimal Svelte ESLint and Biome fixtures plus real-server E2E targets
  for diagnostics, formatter ownership, and Tailwind completion/resolve.

### Fixed

- Preserve static backend initialization options on the presets' ordinary
  one-server Eglot fast path.

## [0.1.0] - 2026-07-19

### Added

#### Core

- A pure-Emacs-Lisp `eglot-lsp-server` facade and `eglotx-contact` descriptors
  for argv/process transports, priority, required/optional lifecycle, language
  and method restrictions, per-child settings, and notification adapters.
- Concurrent method-specific routing with deterministic aggregation,
  capability negotiation, exact document synchronization, UTF-16 adaptation,
  cancellation, optional-backend degradation, and bounded shutdown cleanup.
- Backend provenance for diagnostics, progress, dynamic registrations,
  commands, incremental cursors, and opaque resolve follow-ups, including
  canonical unopened-document ownership and generation-safe open documents.
- Push, pull, and Eglot streaming diagnostic projection with independent
  backend snapshots, related-document handling, bounded/coalesced publication,
  source attribution, and retirement retractions.
- One-pass completion aggregation that preserves every child item and
  `CompletionList.itemDefaults`.  Common data/ranges use one batch plus
  O(backends) segment handles; explicit item data uses compact indexed handles.
  Live open-document candidates retain GC-managed ownership for delayed Corfu
  resolution without allocating a common-case owner per item.
- Singleton routing for stateful providers, bounded document-selector and
  watcher unions, provider-pinned refresh/file operations, stable collection
  merging, and conservative routing for unknown methods/capabilities.
- Bounded O(1) ownership ledgers, deferred work batches, stderr/event retention,
  request deadlines, non-local-exit-safe startup/retirement, and read-only
  `eglotx-status` snapshots.
- Public bounded `eglotx-backend-request` for asynchronous requests from an
  explicit child-notification adapter to one named sibling.
- A small `eglotx-eglot` adapter advertising resolve-time completion `textEdit`
  support already consumed by Eglot; the core retains a compatible eager path.

#### Presets

- A separate bounded discovery engine with contact-lifetime positive/negative
  caches, local-first executable resolution, remote-safe PATH behavior, and no
  recursive scan, shell, package manager, config evaluation, or installation.
- `eglotx-presets-mode` with nine owned contacts for Vue, Angular-aware JS/TS,
  HTML, CSS/SCSS/Less, JSON/JSONC, GraphQL, Python, Go, and Ruby.  One resolved
  server returns an ordinary Eglot contact; missing required tools delegate to
  the contact that the mode shadowed.
- Strong-intent add-ons and an opt-out for ESLint, Tailwind CSS, Biome,
  GraphQL, Angular, Ruff, GolangCI-Lint, and Sorbet; PATH alone does not opt an
  unrelated project into an add-on.
- A Vue SFC stack requiring VLS, TLS, and `@vue/typescript-plugin`, with the
  current private tsserver request/response bridge, local SDK/version handling,
  and intent-gated ESLint, Tailwind, GraphQL, and Biome 2.3+.
- Structural Web recipes and method/language boundaries for TypeScript,
  Angular, HTML, CSS, JSON, GraphQL, ESLint, Tailwind, and Biome.
- Alternative primary selection for Python, Go, and Ruby, paired respectively
  with intent-gated Ruff, GolangCI-Lint, and Sorbet add-ons.

#### Development

- Versioned `package-vc`/`use-package :vc` installation, synchronized release
  metadata validation, and development-only Elisp excluded from package
  byte-compilation.
- Hermetic byte-compilation and ERT checks, allocation/throughput benchmarks,
  minimal fixture projects, and opt-in real-server ESLint, Biome, Vue, and
  Tailwind-to-Corfu E2E targets.
- CI checks on Emacs 29.4, 30.2, and the current snapshot build.

[Unreleased]: https://github.com/cxa/eglotx/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/cxa/eglotx/releases/tag/v0.1.2
[0.1.1]: https://github.com/cxa/eglotx/releases/tag/v0.1.1
[0.1.0]: https://github.com/cxa/eglotx/releases/tag/v0.1.0
