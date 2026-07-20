# Eglotx presets

The presets package is Eglotx's optional zero-configuration policy layer.  It
selects one full language server for a document and adds only complementary
servers for which the project shows strong intent.  Language and toolchain
policy lives here; `eglotx.el` remains a protocol multiplexer with no knowledge
of manifests, project markers, or particular servers.

This file is the authoritative catalog of current preset behavior.  Public
function signatures and customization variables live in [`api.md`](api.md);
the dated files under [`research/`](research/) explain design inputs rather
than defining the supported preset matrix.

Discovery is implemented in the separate `eglotx-preset-engine.el` module.
The engine owns a bounded, contact-lifetime context for filesystem reads,
directory listings, executable probes, and their negative results.  The
language recipes consume that context; requiring the core alone neither loads
the recipes nor examines a project.

## Setup and installed contacts

```elisp
(require 'eglotx-presets)
(eglotx-presets-mode 1)
```

The global mode prepends the following entries to
`eglot-server-programs`, in this order:

| Entry | Buffer cohort | Contact |
| --- | --- | --- |
| Svelte | Svelte single-file components | `eglotx-presets-svelte-contact` |
| Astro | Astro components | `eglotx-presets-astro-contact` |
| Vue | Vue single-file components | `eglotx-presets-vue-contact` |
| JavaScript/TypeScript (Angular-aware) | JavaScript, JSX, TypeScript, and TSX | `eglotx-presets-angular-contact` |
| HTML | HTML | `eglotx-presets-html-contact` |
| CSS | CSS, SCSS, and Less | `eglotx-presets-css-contact` |
| JSON | JSON and JSON-with-comments | `eglotx-presets-json-contact` |
| GraphQL | standalone GraphQL | `eglotx-presets-graphql-contact` |
| Python | Python source | `eglotx-presets-python-contact` |
| Go | Go source, `go.mod`, and `go.work` | `eglotx-presets-go-contact` |
| Ruby | Ruby source | `eglotx-presets-ruby-contact` |

The Svelte entry maps `svelte-ts-mode` and `svelte-mode` to the exact `svelte`
language ID.  Astro maps `astro-ts-mode` and legacy `astro-mode` to `astro`,
and its entry precedes HTML so neither Astro mode can fall through to the HTML
contact.  The Vue entry similarly maps `vue-ts-mode`, `vue-mode`, and
`vue-html-mode` to `vue`.  None claims generic `web-mode`, HTML, or Markdown
buffers, where the actual embedded language cannot be inferred safely.  The
single JavaScript/TypeScript entry always resolves the ordinary JS/TS stack and
adds Angular only when Angular intent is present.  The Angular
backend declares `:languages ("typescript")`, so JavaScript, JSX, and TSX stay
in the same Eglot cohort without being sent to `ngserver`.  The Go entry keeps
source, module, and workspace buffers in gopls's complete cohort, while the
GolangCI add-on declares `:languages ("go")` and never receives `go.mod` or
`go.work` traffic.  Similarly, the CSS entry groups CSS, SCSS, and Less, but
its Biome add-on accepts only `css`; the structural CSS primary and Tailwind
remain available to the whole cohort.

Each mapping supplies an exact LSP language ID, including `javascriptreact`,
`typescriptreact`, `css`, `scss`, `less`, `go`, `go.mod`, `go.work`, and
`jsonc`.  `jsonc-mode` is deliberately listed before its JSON parent modes so
Eglot preserves the `jsonc` ID.  Enabling the mode repeatedly is idempotent.
Disabling it removes only the exact cons cells installed by the mode, so an
equal-looking entry owned by the user remains in place.

Bundled Eglot on Emacs 29 stores only the startup mode's language ID for a
multi-mode session.  Eglotx reconstructs and caches the exact per-mode cohort
from the legacy contact lookup, then corrects each detached outgoing `didOpen`
copy from the visiting buffer before tracking and routing it.  Newer Eglot
provides that mode/ID mapping directly.

Installation snapshots the `eglot-server-programs` contacts that preceded the
catalog.  If a bundled recipe cannot find its supported required primary or,
for GraphQL, required project configuration, it resolves the matching earlier
contact instead of shadowing it.  Static contacts are returned unchanged;
functional contacts are called with their normal supported one- or two-argument
arity.  Disabling the mode removes the owned entries, leaves the preceding
list visible again, and clears the fallback resolver and snapshot.

For manual registration, use a public contact directly:

```elisp
(add-to-list
 'eglot-server-programs
 '((python-mode python-ts-mode) . eglotx-presets-python-contact))
```

Eglot chooses a language ID from the matched `eglot-server-programs` entry,
not from the visited file's extension.  A custom mode must therefore declare
its exact ID ahead of the bundled entry while reusing the contact:

```elisp
(add-to-list
 'eglot-server-programs
 '(((my-typescript-mode :language-id "typescript")
    (my-tsx-mode :language-id "typescriptreact"))
   . eglotx-presets-typescript-contact))
```

The presets do not guess the language of arbitrary derived modes.

## Selection model

Every recipe distinguishes two roles:

- A **primary** is a structural, full-featured language server.  A recipe
  chooses exactly one primary from any alternatives it supports.
- An **add-on** contributes lint, format, framework, schema, or embedded
  language behavior.  It must be executable and have strong project intent.

Executable availability is sufficient for ordinary structural-primary
candidates, but never opts every project into an add-on.  Standalone GraphQL
also requires project configuration, and Vue requires its complete companion
chain.  Depending on the recipe, strong add-on intent is an official config or
manifest section, an exact dependency, or a project-local add-on executable.
A local `vscode-eslint-language-server` is not sufficient for embedded
Svelte/Astro/Vue: `vscode-langservers-extracted` can install that binary for an
unrelated HTML/CSS toolchain, so those contacts still require an ESLint config
or dependency.
A malformed marker and a directory whose name merely resembles a config do not
count.

Backend priority determines stable merge order, singleton ownership, and the
fallback for an unknown method.  A recipe also uses `:only` when an add-on
must not claim all capabilities that its process advertises.  Lifecycle and
document-synchronization methods remain available so a restricted child sees
the same open-document state as its cohort.

Some cohorts also use the core `:languages` restriction.  It filters
document-scoped requests, notifications, and diagnostics by the LSP
`languageId`, intersects initialize-time document selectors with the same set, and
prevents a partial-cohort backend from advertising a static document
capability for the whole facade.  Semantic tokens require one provider that
covers every language in the cohort.

If discovery resolves exactly one backend, the recipe returns an ordinary
Eglot contact instead of constructing an `eglotx-server` facade.  Static
backend initialization options are mapped to Eglot's
`:initializationOptions` contact keyword, so Astro retains its required
TypeScript SDK on this fast path.  A missing optional server is omitted.  Vue
is the intentional exception to the one-primary model:
its current upstream protocol requires both Vue and TypeScript language servers
plus the Vue TypeScript plugin. A missing required primary, Vue companion,
Astro TypeScript SDK, or required GraphQL config first
delegates to the matching contact captured before preset installation.  Only
when no fallback contact resolves does interactive lookup return nil or
noninteractive startup raise an actionable `eglotx-configuration-error`.

## Executable precedence and trust

Starting at the current buffer directory, discovery walks toward the Eglot
project root.  With the default
`eglotx-presets-prefer-project-local-servers` value, the nearest executable in
the recipe's fixed ecosystem directories wins, then PATH is consulted:

| Ecosystem | Project-local directories |
| --- | --- |
| Node/Web | `node_modules/.bin/` at each retained ancestor |
| Python | `.venv/bin/`, `venv/bin/`, `.venv/Scripts/`, and `venv/Scripts/` |
| Go | `bin/` and `.bin/` |
| Ruby | `bin/` binstubs |

The returned local argv uses an absolute path.  Set
`eglotx-presets-prefer-project-local-servers` to nil to require PATH resolution
instead.  A project-local executable is code installed by that project, so
enabling this global mode for a workspace is a trust decision.

Python executable discovery limits virtual-environment probes to the nearest
eight ancestors plus the project root.  Metadata intent still uses the shared
32-ancestor contact budget described below.

No recipe invokes a shell, `npx`, npm, pnpm, Yarn, Bun, Poetry, uv, Bundler, or
another package manager.  Yarn Plug'n'Play projects without
`node_modules/.bin` need servers on PATH or a manual core contact.  Ruby LSP is
launched directly rather than through `bundle exec`, in accordance with its
toolchain bootstrap model.

## Web and Node recipes

The Web catalog uses these commands and priorities:

| Backend | Command | Priority | Role and contacts |
| --- | --- | ---: | --- |
| Biome | `biome lsp-proxy` | 120; 70 for partial Svelte/Astro/Vue support | JS/TS add-on with advertised capabilities; restricted lint/format add-on for Svelte, Astro, Vue, CSS, JSON/JSONC, and GraphQL |
| Angular Language Service | `ngserver --stdio --tsProbeLocations DIR --ngProbeLocations DIR` | 120 | TypeScript-only framework add-on |
| Vue Language Server | `vue-language-server --stdio [--tsdk=DIR]` | 110 | required Vue SFC primary and private-notification source |
| Svelte Language Server | `svelteserver --stdio` | 100 | required Svelte SFC primary; embeds Svelte, HTML, CSS, and JS/TS support |
| Astro Language Server | `astro-ls --stdio` | 100 | required Astro primary; embeds Astro, HTML, CSS, and JS/TS support and requires `initializationOptions.typescript.tsdk` |
| TypeScript Language Server | `typescript-language-server --stdio` | 100 | required JS/TS primary; required Vue semantic companion with `@vue/typescript-plugin`; never an Astro- or Svelte-document backend |
| HTML Language Server | `vscode-html-language-server --stdio`, then `html-languageserver --stdio` | 100 | alternative HTML primaries |
| CSS Language Server | `vscode-css-language-server --stdio`, then `css-languageserver --stdio` | 100 | alternative CSS/SCSS/Less primaries |
| JSON Language Server | `vscode-json-language-server --stdio`, `vscode-json-languageserver --stdio`, then `json-languageserver --stdio` | 100 | alternative JSON primaries |
| GraphQL Language Service | `graphql-lsp server -m stream --configDir DIR` | 100 standalone; 50 embedded | GraphQL primary or Svelte/Astro/Vue/JS/TS embedded-language add-on |
| vscode-eslint | `vscode-eslint-language-server --stdio` | 80 | Svelte, Astro, Vue, or JS/TS lint and code-action add-on |
| Tailwind CSS Language Server | `tailwindcss-language-server --stdio` | 60 | Svelte, Astro, Vue, JS/TS, HTML, or CSS/SCSS/Less utility-language add-on |

### Svelte SFCs

The Svelte contact requires only `svelteserver` from the
`svelte-language-server` package.  The upstream process registers Svelte,
HTML, CSS, and TypeScript/JavaScript plugins internally, so the preset never
sends a `.svelte` URI to TypeScript, HTML, or CSS Language Server.  Doing so
would duplicate parsing, diagnostics, completion, and formatting without
adding a missing structural capability.  When no complementary backend is
selected, the contact returns the ordinary project-local-or-PATH
`("svelteserver" "--stdio")` argv fast path.

ESLint, Tailwind CSS, Biome, and GraphQL reuse the catalog's local-first
executable rules, then join only the `svelte` language cohort.  ESLint also
requires a config or manifest dependency even when its server is local; the
binary can be incidental to `vscode-langservers-extracted`.  The embedded
ESLint method filter admits document synchronization,
configuration, diagnostics, code actions, and commands, with formatting
disabled.  Tailwind is limited to synchronization, configuration,
completion/resolve, hover, colors, links, code lens, code actions, and
diagnostics.  GraphQL still requires structural GraphQL Config and never owns
formatting.  Completion items and resolvable code actions retain backend
provenance, so a Tailwind item returns to Tailwind rather than falling through
to Svelte.

Biome is selected only when its installed package version is at least 2.3.
Without a project `biome.json` or `biome.jsonc` that explicitly sets
`html.experimentalFullSupportEnabled` to true, Biome runs at priority 70 with
diagnostics and code actions but no whole-document formatting.  With that flag,
its priority-120 profile owns formatting ahead of Svelte.  The preset reads but
never writes or enables this experimental project setting.

SvelteKit has no separate official language-server process.  Its component
semantics remain inside Svelte Language Server, while `.svelte.ts` and
`.svelte.js` rune modules are ordinary TypeScript/JavaScript documents and keep
using the existing JS/TS contact.  The optional `typescript-svelte-plugin`
improves cross-file behavior from ordinary TS/JS buffers; it is not another
backend for a `.svelte` document and is outside this contact.  See the
[commit-pinned Svelte research](research/svelte-multi-lsp-2026-07-20.md) for
the upstream capability and method evidence.

### Astro components

The Astro contact requires `astro-ls --stdio` from
`@astrojs/language-server` as its sole structural primary.  The server's Volar
language plugin owns Astro syntax and the embedded TypeScript/JavaScript, HTML,
and CSS regions, so the preset never sends a complete `.astro` URI to
TypeScript, HTML, CSS, Vue, or Svelte Language Server.  Framework components
imported by an Astro page keep using their own preset when their source file is
opened; they are not sibling servers for the `.astro` document.

Astro Language Server refuses initialization without a TypeScript SDK.  The
preset walks the retained nearest ancestors for
`node_modules/typescript/lib/` and accepts the directory only when it contains
`typescript.js` or `tsserverlibrary.js`.  That exact nearest directory is
passed as:

```elisp
(:typescript (:tsdk "/project/node_modules/typescript/lib/"))
```

With no complementary backend, the ordinary Eglot contact carries this value
under `:initializationOptions`; with multiple backends the Astro descriptor
carries it under `:initialization-options`.  Both forms produce the same
`initialize.initializationOptions.typescript.tsdk` wire value.  A missing
`astro-ls` or validated project SDK delegates to the preceding Eglot contact
instead of starting a server that cannot initialize.  Server and SDK lookup
are project-local and nearest-first; the server alone may fall back to the
correct local or remote PATH.

ESLint, Tailwind CSS, Biome, and GraphQL reuse the shared embedded-Web resolver
and join only the `astro` language cohort.  ESLint requires a structural config
or manifest dependency even if its server executable is project-local, and it
is limited to synchronization, configuration, diagnostics, code actions, and
commands.  Tailwind retains its embedded completion/resolve, hover, color,
link, code-action, and diagnostic role.  GraphQL still requires structural
GraphQL Config and never owns formatting.  None of these add-ons causes a
TypeScript, HTML, or CSS child to start.

Biome is admitted only when the selected installed package version is at least
2.3.  Without an explicit project
`html.experimentalFullSupportEnabled: true` setting, it runs at priority 70
with diagnostics and code actions but no whole-document formatting.  With the
flag, its priority-120 profile owns formatting; otherwise the priority-100
Astro primary remains the selected formatter.  The Astro Language Server's
upstream formatting service still requires project `prettier` and
`prettier-plugin-astro`; the preset does not install or infer them.

The entry covers exactly `astro-ts-mode` and legacy `astro-mode`, both with
language ID `astro`, and deliberately does not claim generic `web-mode`.  See
the [commit-pinned Astro research](research/astro-multi-lsp-2026-07-20.md) for
the upstream initialization, embedded-language, and add-on evidence.

### Vue SFCs

Current Vue Language Tools 3.x is not a standalone replacement for the
TypeScript server. The Vue contact therefore requires all three of these
components before it starts:

1. `vue-language-server` from `@vue/language-server`;
2. `typescript-language-server`; and
3. a validated `@vue/language-server` package directory from which TypeScript
   Language Server can resolve an installed `@vue/typescript-plugin` package.

Each path follows the same nearest `node_modules/.bin` then PATH policy as the
other Node recipes. Package ownership is verified from bounded `package.json`
reads; the plugin `location` is the package directory, never the `.bin`
wrapper. A PATH executable is accepted only when its resolved executable path
can be traced to that validated package. The plugin itself is resolved through
a bounded Node-style ancestor walk over both the package's real path (for pnpm
virtual stores) and its lexical path (for hoisted dependencies); an incomplete
install delegates to the preceding Eglot contact. The TypeScript child receives:

```elisp
(:plugins [(:name "@vue/typescript-plugin"
            :location "/project/node_modules/@vue/language-server/"
            :languages ["vue"])]
 :tsserver (:path "/project/node_modules/typescript/lib/"))
```

When a nearest project TypeScript SDK is present, VLS 3.0.9 and newer also
receive `--tsdk=/project/node_modules/typescript/lib/`. Older or unparseable
VLS versions use the compatible `--stdio` command only. This preserves Vue 2
projects that intentionally pin a project-local `@vue/language-server@~3.0.0`
instead of replacing it with a newer PATH installation.

Both required children receive document synchronization for language ID
`vue`. VLS private notifications are handled by an explicit preset adapter:

```text
VLS  tsserver/request  [[id, command, args]]
  -> TLS workspace/executeCommand
         {command: "typescript.tsserverRequest", arguments: [command, args]}
  -> VLS tsserver/response [[id, result.body]]
```

The adapter runs asynchronously on the core's deferred FIFO. It is capped at
64 in-flight requests by default and has a fixed deadline. Error, timeout, or
target exit settles VLS with `[[id, null]]`; source exit cancels the TypeScript
leg. The private methods never reach Eglot. Requiring `eglotx` alone still has
no Vue knowledge: the core only validates generic notification handlers and
bounded directed backend requests.

ESLint, Tailwind CSS, Biome, and GraphQL reuse their existing strong-intent
gates and join the Vue cohort with `:languages ("vue")`. GraphQL still needs
structural GraphQL Config. Biome is accepted only when the selected installed
package has a readable version at least 2.3. Without an explicit
`html.experimentalFullSupportEnabled: true`, Biome is restricted to diagnostics
and code actions at priority 70, leaving whole-SFC formatting to VLS. With the
flag enabled, its existing priority-120 lint/format profile applies. The preset
never writes or enables that experimental setting for the project. Both JSON
and JSONC Biome configurations are parsed structurally; comments, trailing
commas, and comment-looking text inside strings are handled without evaluating
the file.

Nuxt, Pinia, Vue Router, VueUse, and component libraries need no additional
process; their TypeScript behavior comes from this required stack. VitePress
Markdown and petite-vue HTML are not claimed implicitly because upstream
requires project-specific extension selectors, and taking every Markdown or
HTML buffer would violate the document-intent boundary. See the
[Vue ecosystem research](research/vue-ecosystem-presets.md) for the upstream
protocol and detection evidence.

### TypeScript, ESLint, Tailwind, and Biome

The generic JS/TS recipe always requires TypeScript Language Server.  ESLint,
Tailwind CSS, Biome, and GraphQL join it independently when both executable
resolution and their own intent gate succeed.

ESLint recognizes `eslintConfig`, dependencies named `eslint`, `eslint-*`,
`@eslint/*`, or `@typescript-eslint/*`, a project-local server, legacy
`.eslintrc`/`.eslintignore` forms, and structurally matched script config
names.  The marker matcher looks for punctuation-delimited `eslint` and
`config` segments rather than maintaining an exhaustive filename table.  It
therefore accepts a variant such as `my-eslint.config.experimental.mjs` but
rejects `eslint-report.json`.

The preset supplies vscode-eslint settings that enable validation and infer a
working directory per document.  It preserves user settings and does not
force the deprecated `experimental.useFlatConfig` switch, allowing the
installed ESLint generation to select its supported flat or legacy behavior.
Invalid ESLint configuration can still suppress rule diagnostics and should
be reproducible with the project's ESLint CLI.

In the generic JS/TS contact, ESLint and Tailwind use the capabilities they
actually negotiate; Eglotx merges collection results and uses the documented
priorities for singleton methods.  Embedded Svelte/Astro/Vue contacts
additionally apply role-specific `:only` lists so these add-ons cannot claim
unrelated component structure.  ESLint formatting is disabled in the supplied
workspace settings,
while Tailwind contributes class completion/resolve, hover, color, links, code
actions, and validation behavior.

Tailwind v4 has no required `tailwind.config.*` marker.  Its exact
`tailwindcss` manifest dependency is the bounded v4 signal; CSS entrypoint and
`@import "tailwindcss"` graph discovery remain the language server's job.  A
project-local language server is also intent.  For v3, the fallback matcher
accepts punctuation-delimited Tailwind script names whose stem is the direct
legacy name or also contains a `config` segment.  It handles variants such as
`config.tailwindcss.preview.mts` without mistaking `tailwind.css` or
`tailwind-plugin.js` for config.  An `@tailwindcss/*` plugin by itself is not
project intent.  The Tailwind backend receives class-composition helpers
`cn`, `clsx`, and `cva`.

Biome activates for the exact `@biomejs/biome` package, a project-local
`biome` executable, or a structurally matched visible or hidden
`biome.json`/`biome.jsonc`.  This structural check does not accept reports,
backups, or arbitrary `biome.config.*` files.  Biome receives an empty JSON
settings object by default while preserving a user's `biome` settings.

In the JS/TS cohort Biome keeps its advertised methods and priority
120, so a project that adopts Biome gives it precedence for supported
singleton operations such as formatting; diagnostics and collection methods
still combine according to core policy.  In CSS, JSON/JSONC, and GraphQL
contacts its `:only` policy is narrower: document lifecycle and configuration,
diagnostics, code actions, formatting, range formatting, and execute-command.
It cannot displace those primaries for completion, hover, or navigation.
Biome is deliberately not added to HTML, whose support still requires more
explicit language configuration than a generic project intent signal.

### GraphQL and Angular

GraphQL requires structural GraphQL Config: `.graphqlrc`, a recognized
`.graphqlrc.*` or `graphql` + `config` filename, or a top-level `graphql` field
in `package.json`.  Merely depending on the `graphql` runtime package is not
intent.  The containing config directory is passed explicitly as
`--configDir DIR`.  In standalone GraphQL buffers, GraphQL Language Service is
the priority-100 required primary and an adopted Biome can supply restricted
lint and format methods at priority 120.  In Svelte, Astro, Vue, and JS/TS
buffers it is an optional priority-50 add-on restricted to completion, hover,
definitions, references, symbols, code actions, and diagnostics; it never
claims formatting.

GraphQL Config is a strong project-level intent signal, but contact discovery
does not parse its document globs or scan source text.  Document matching is
left to GraphQL Language Service.  Conservatively, a project whose config only
declares a schema can therefore start one GraphQL process for a JS/TS cohort;
the server may then ignore documents that do not match its own configuration.

Angular activates from `angular.json`, an exact `@angular/core` dependency, or
a project-local `ngserver`.  It is part of the single JS/TS contact but accepts
only the `typescript` language ID.  The add-on is restricted to Angular-aware
completion, hover, signature, navigation,
references, implementation, rename, code actions, diagnostics, and commands;
formatting and general workspace ownership stay with the base stack.  Probe
locations are derived from the resolved local Node installation when present.

This first preset catalog supports Angular inline templates in TypeScript but
does not send external `.html` templates to `ngserver`.  HTML remains a
separate Eglot cohort so ordinary HTML projects cannot accidentally join a
TypeScript session; adding Angular to both contacts would instead start a
duplicate Angular process for one project.  External-template multiplexing is
therefore deferred until Eglotx can share one child safely across two facade
cohorts.

### HTML, CSS, JSON, and GraphQL extensions

The standalone Web contacts ensure add-ons are available outside a TypeScript
session:

- HTML primary + Tailwind CSS;
- CSS/SCSS/Less primary + Tailwind CSS, with restricted Biome only for CSS;
- JSON/JSONC primary + restricted Biome;
- GraphQL primary + restricted Biome.

Every add-on retains its ordinary strong-intent rule.  No TypeScript process is
started for these native buffer types.

## Python: one primary plus Ruff

The Python recipe selects exactly one available full server.  Its stable
fallback order and commands are:

1. `basedpyright-langserver --stdio`;
2. `pyright-langserver --stdio`;
3. `pyrefly lsp`;
4. `ty server`;
5. `pylsp`; and
6. `jedi-language-server`.

A server-specific config at the nearest retained ancestor can select an
available alternative before this fallback order.  Recognized signals include
`ty.toml`, `pyrefly.toml`, `pyrightconfig.json`, and the corresponding
`[tool.ty]`, `[tool.pyrefly]`, `[tool.basedpyright]`, `[tool.pyright]`, or
`[tool.pylsp]` section in `pyproject.toml`.  Otherwise the nearest project
virtual environment wins, with the list above breaking ties.  basedpyright
also understands Pyright's config, so a shared Pyright-format signal can select
whichever compatible implementation is available.  ty and Pyrefly are treated
as primary alternatives, not as extra analyzers.

Native Ruff intent is established by `[tool.ruff]`, an exact `ruff` dependency
in a supported `pyproject.toml` dependency declaration, a structural
`ruff.toml`/`.ruff.toml`, or a project-local Ruff executable.  A global Ruff
plus a generic `pyproject.toml` does not activate it.  Ruff runs as `ruff
server`, priority 120, and is restricted to diagnostics, code actions,
formatting, range formatting, execute-command, configuration, and document
lifecycle.  That priority lets Ruff win formatting even when a primary such as
pylsp also advertises it; the narrow `:only` list prevents Ruff from taking
completion, hover, definition, references, rename, or other structural
requests from the priority-100 Python primary.  The deprecated `ruff-lsp`
process is never started.

## Go: one complete gopls cohort plus GolangCI

The Go recipe groups `go`, `go.mod`, and `go.work` buffers under required
`gopls` at priority 100.  It adds optional
`golangci-lint-langserver` at priority 40 only when both that server and the
`golangci-lint` CLI resolve, and a structural GolangCI config or project-local
tool executable establishes intent.  A global installation by itself does not
activate the add-on.

The add-on is diagnostic-only apart from document lifecycle and configuration
and declares `:languages ("go")`; module and workspace documents, hover,
completion, navigation, formatting, and symbols stay with gopls.  The language
server receives its linter command through initialization options:

- a config declaring `version: 2`, or a project-local toolchain with no config,
  uses `golangci-lint run --output.json.path stdout --show-stats=false
  --issues-exit-code=1`;
- a config without the v2 declaration uses the v1-compatible
  `golangci-lint run --out-format json --issues-exit-code=1`.

The preset reads bounded config text to choose the argument form and never
spawns a synchronous version probe.

## Ruby: one primary plus Sorbet

Ruby LSP and Solargraph are alternatives, not concurrent primaries.  The
nearest project `bin/` directory is checked for both alternatives before any
PATH executable is considered.  Within one local directory `ruby-lsp` wins a
tie; only when no local alternative exists does PATH fallback prefer
`ruby-lsp`, then `solargraph stdio`.  Either selected primary has priority 100.

When Ruby LSP is selected, `sorbet/config` exists, and `srb` resolves, Sorbet
joins as optional priority 120 using `srb tc --lsp`.  A local or global `srb`
without that config is not intent, and Sorbet is not layered on Solargraph.
Its restricted method set covers type-oriented diagnostics, hover,
completion, navigation, references, symbols, rename, code actions, and
commands.  It excludes formatting, leaving Ruby LSP in charge of the project's
RuboCop or Syntax Tree integration.

## Opting out and refreshing

`eglotx-presets-disabled-backends` disables optional add-ons by symbolic name:

```elisp
(setq eglotx-presets-disabled-backends
      '(angular biome eslint graphql golangci-lint ruff sorbet tailwindcss))
```

This option does not disable a recipe's primary.  For example, `graphql`
disables the embedded JS/TS add-on but not GraphQL Language Service when it is
the standalone GraphQL primary.  To select a different unsupported primary or
replace a whole recipe, install a user contact ahead of the bundled entry.

There is no process-wide discovery cache.  Eglot keeps a resolved contact for
the current session, including across `eglot-reconnect`.  After installing or
removing a server, editing intent configuration, or changing these options,
use `eglot-shutdown` and start Eglot again to perform fresh discovery.

## Performance and remote projects

Discovery runs only when Eglot resolves a contact for a new project session.
One context caches each attribute check, bounded read, parse, directory
listing, and executable lookup for that resolution.  The hard bounds are:

- at most 32 nearest ancestors, with the project root retained as one final
  probe even in a deeper tree;
- for Python executables, virtual environments under only the nearest eight
  ancestors plus the project root;
- at most 1 MiB from any one metadata file and 4 MiB across the context; and
- at most 64 keyword-prefiltered marker candidates retained from any one local
  directory listing.

Recipes use fixed manifest names, fixed executable candidates, and
non-recursive ancestor probes.  They never recursively scan the workspace,
evaluate a config, start a discovery subprocess, or perform discovery from a
process filter or JSON-RPC callback.  In particular, Tailwind v4 CSS/import
analysis remains asynchronous work for Tailwind Language Server rather than a
synchronous Emacs scan.

Remote projects do not enumerate directories for keyword marker discovery,
because TRAMP would need to transfer the complete listing before filtering.
Consequently filename-discovered ESLint, Biome, Tailwind v3, GraphQL,
GolangCI-Lint, and standalone Ruff configuration do not establish intent over
TRAMP.  Directly probed manifests and paths still work: `package.json`,
`pyproject.toml`, Python primary configuration, `sorbet/config`, project-local
executables, and the remote PATH all remain available within the same read
budgets.  PATH lookup is performed in the remote project context, and the
TRAMP prefix is removed only from the argv passed to the remote process.  A
remote contact never falls back to a local executable.

In a monorepo, the package containing the buffer that starts the Eglot session
determines nearest-local precedence.  Ancestors through the project root are
considered; intent present only in an unvisited sibling is deliberately not
found.  Start the session from the relevant package or use a manual contact
when one facade must cover heterogeneous siblings.

## Verification matrix

`make check` is hermetic.  Across the catalog, fake-process and fixture-based
ERT tests exercise positive and negative intent, command construction,
priority, language cohorts, fallback, and the single-server fast path; not
every dimension is asserted separately for every recipe.  Real-server targets
are opt-in:

| Target | Installed toolchain exercised |
| --- | --- |
| `make test-eslint-e2e` | Three resolved backends, TypeScript/ESLint diagnostics, Tailwind completion/resolve, and TypeScript formatter ownership |
| `make test-biome-e2e` | Three resolved backends, TypeScript/Biome diagnostics, Tailwind completion/resolve, and Biome formatter ownership |
| `make test-vue-e2e` | Project-local VLS, TLS, ESLint, and Tailwind; the VLS/TLS bridge; TypeScript and ESLint diagnostics |
| `make test-svelte-eslint-e2e` | Project-local Svelte, ESLint, and Tailwind; type/ESLint diagnostics, Svelte and Tailwind completion/resolve ownership, rune validity, and Svelte formatting |
| `make test-svelte-biome-e2e` | Project-local Svelte, Biome, and Tailwind; type/Biome diagnostics, Svelte and Tailwind completion/resolve ownership, rune validity, and explicit Biome formatting |
| `make test-svelte-e2e` | Both Svelte targets above |
| `make test-astro-eslint-e2e` | Project-local Astro, ESLint, TypeScript SDK, and Tailwind; Astro/ESLint diagnostics, Astro and Tailwind completion/resolve ownership, and Astro formatter ownership |
| `make test-astro-biome-e2e` | Project-local Astro, Biome, TypeScript SDK, and Tailwind; Astro/Biome diagnostics, Astro and Tailwind completion/resolve ownership, and explicit Biome formatting |
| `make test-astro-e2e` | Both Astro targets above |
| `make test-corfu-e2e` | A real Tailwind response through Eglot CAPF, Orderless, and Corfu, including an old candidate after replacement CAPFs and GC |
| `make test-presets-e2e` | The generic ESLint/Biome, Vue, Svelte, and Astro targets above |

Python/Ruff, Go/GolangCI-Lint, Ruby/Sorbet, and Vue/Biome currently have
fixture-based ERT coverage but no bundled real-toolchain target.  CI runs
`make check`; it does not install external language servers or run the opt-in
E2E and benchmark targets.

## Deliberate exclusions

The catalog includes combinations with a tested document cohort, stable
commands, strong intent, and an explicit method boundary.  Community use alone
is not enough to auto-start another process.  Notable exclusions are:

- **Terraform LS + TFLint** has a clean diagnostic-only capability split, but
  TFLint's language-server path currently rebuilds its runner and performs a
  complete `inspect()` immediately on every `textDocument/didChange`, without
  a save-only path or built-in debounce.  That conflicts with Eglotx's
  interactive-latency requirement, so it remains manual until a debounce,
  save-only guard, or explicit opt-in policy exists.
- **VitePress Markdown and petite-vue HTML** require explicit upstream
  extension selectors. The Vue SFC preset does not infer those selectors from
  a dependency and therefore does not claim every Markdown or HTML buffer.
- **TypeScript, HTML, and CSS Language Server for `.svelte` or `.astro`**
  duplicate plugins already inside their structural language server.  Vue and
  Svelte servers likewise do not receive `.astro` documents.  Stylelint,
  UnoCSS, and other possible embedded-Web add-ons remain manual until their URI
  mapping, strong intent, and method boundaries are verified independently.
- The old **Credo Language Server** is archived, while NextLS integrates Credo.
  ElixirLS, NextLS, and Lexical are full primary alternatives; starting an
  archived Credo add-on or several Elixir primaries would duplicate work.
- **YAML + Ansible** needs a document-level Ansible selector: an
  `ansible.cfg` elsewhere in a repository cannot classify every YAML buffer.
  **Java + Spring** and **PHP + Psalm** need additional initialization,
  conflict, and startup-cost policy before they can meet the zero-config bar.
- Copilot requires account and data-transfer consent.  Semgrep and Trunk may
  execute broad or remote-backed analysis.  Emmet and spelling servers lack a
  sufficiently specific adoption signal.  None is inferred from PATH alone.
- clangd/ccls, nil/nixd, Ruby LSP/Solargraph, ty/Pyright, and similar full
  servers are alternatives.  The applicable recipe selects one rather than
  manufacturing a multiplexer from every installed executable.

The primary-source survey behind these boundaries is in
[`research/community-multi-server-presets.md`](research/community-multi-server-presets.md).
