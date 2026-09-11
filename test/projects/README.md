# Preset fixture projects

These deliberately small projects isolate representative complementary
backends for hermetic contact tests and opt-in real-server E2E tests:

- `react_ts_tailwind_eslint` activates TypeScript, Tailwind CSS v4, and ESLint.
- `react_ts_tailwind_biome` activates TypeScript, Tailwind CSS v4, and Biome.
- `nested_ts_eslint/frontend` covers a TypeScript/ESLint application below a
  Git repository root, matching the layout reported in discussion #3.
- `angular_ts` activates TypeScript Language Server and Angular Language
  Service for a standalone component with an inline template.
- `vue_ts_tailwind_eslint` activates the Vue/TypeScript hybrid stack, Tailwind
  CSS v4, and ESLint.
- `vue_ts_tailwind_biome` activates the Vue/TypeScript hybrid stack, Tailwind
  CSS v4, and Biome's explicitly enabled full Vue support.
- `svelte_ts_tailwind_eslint` activates Svelte Language Server, Tailwind CSS v4,
  and ESLint without a duplicate TypeScript/HTML/CSS server.
- `svelte_ts_tailwind_biome` activates Svelte Language Server, Tailwind CSS v4,
  and Biome's explicitly enabled full Svelte support.
- `astro_ts_tailwind_eslint` activates Astro Language Server, Tailwind CSS v4,
  and ESLint without duplicate TypeScript/HTML/CSS/Vue/Svelte servers.
- `astro_ts_tailwind_biome` activates Astro Language Server, Tailwind CSS v4,
  and Biome's explicitly enabled full Astro support.
- `python_ruff` activates one Python primary plus Ruff.
- `go_golangci` activates gopls plus golangci-lint-langserver.
- `ruby_sorbet` activates Ruby LSP plus Sorbet.

The repository ignores fixture lockfiles and generated installations; a local
E2E setup may create both.  Python, Go, and Ruby currently provide hermetic
fixture coverage only.  The React E2E targets accept project-local
executables or servers on `PATH`.  The Vue E2E target deliberately requires
project-local `vue-language-server`,
`typescript-language-server`, `vscode-eslint-language-server`, and
`tailwindcss-language-server` so it can verify local precedence and the exact
Vue package/plugin relationship.  The Svelte E2E targets likewise require
project-local `svelteserver`, `tailwindcss-language-server`, and their selected
ESLint or Biome backend.  The Astro E2E targets require project-local
`astro-ls`, TypeScript, `tailwindcss-language-server`, and their selected
ESLint or Biome backend; the fixtures also include Prettier and its Astro
plugin so the Astro formatter path is testable.  The Angular E2E target
requires project-local `typescript-language-server` and `ngserver`.  Run
`npm install` under `angular_ts` before invoking it; the test checks local
precedence, Angular probe locations, and both TypeScript and inline-template
diagnostics.  The remaining fixtures keep intent, command, and cohort tests
reproducible without making the default suite depend on external toolchains.

```sh
make check
make test-presets-e2e
```

### Nested TypeScript/ESLint regression

```sh
npm install --prefix test/projects/nested_ts_eslint/frontend
make test-nested-eslint-e2e
```

The source deliberately contains an ESLint `no-var` violation and a TypeScript
error.  The test copies the installed fixture to a temporary directory and
runs `git init` there, producing this layout:

```text
repo/
├── .git/
└── frontend/
    ├── package.json
    ├── eslint.config.js
    ├── tsconfig.json
    ├── node_modules/
    └── src/main.ts
```

The test relocates only the copied TypeScript server launcher outside `repo/`
and PATH, then registers its absolute path before enabling presets.  This
exercises the nvm-style contact fallback without requiring nvm.  It opens the
source in the real `typescript-ts-mode` and uses normal `project.el` discovery;
no project finder or preset contact is substituted.  A grammar is optional
because the assertions exercise LSP behavior, not syntax highlighting.

Two fresh repositories test the default Git root and
`project-vc-extra-root-markers '("package.json")`, which selects `frontend/`.
Both must start TypeScript plus ESLint, publish both diagnostics, and apply
ESLint fix-all to replace `var` with `let`.  The test also checks that a user
contact prepended after presets still overrides them.  The checked-in source
and its installed dependencies are left intact.

The aggregate E2E target includes the nested, React, Angular, Vue, Svelte, and
Astro scenarios.  See the preset
[verification matrix](../../docs/presets.md#verification-matrix) for individual
targets and their assertions.
