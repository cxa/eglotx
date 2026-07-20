# Preset E2E projects

These deliberately small projects isolate representative complementary
backends:

- `react_ts_tailwind_eslint` activates TypeScript, Tailwind CSS v4, and ESLint.
- `react_ts_tailwind_biome` activates TypeScript, Tailwind CSS v4, and Biome.
- `vue_ts_tailwind_eslint` activates the Vue/TypeScript hybrid stack, Tailwind
  CSS v4, and ESLint.
- `vue_ts_tailwind_biome` activates the Vue/TypeScript hybrid stack, Tailwind
  CSS v4, and Biome's explicitly enabled full Vue support.
- `svelte_ts_tailwind_eslint` activates Svelte Language Server, Tailwind CSS v4,
  and ESLint without a duplicate TypeScript/HTML/CSS server.
- `svelte_ts_tailwind_biome` activates Svelte Language Server, Tailwind CSS v4,
  and Biome's explicitly enabled full Svelte support.
- `python_ruff` activates one Python primary plus Ruff.
- `go_golangci` activates gopls plus golangci-lint-langserver.
- `ruby_sorbet` activates Ruby LSP plus Sorbet.

The repository ignores fixture lockfiles and generated installations; a local
E2E setup may create both.  The React E2E targets accept project-local
executables or servers on `PATH`.  The Vue E2E target deliberately requires
project-local `vue-language-server`,
`typescript-language-server`, `vscode-eslint-language-server`, and
`tailwindcss-language-server` so it can verify local precedence and the exact
Vue package/plugin relationship.  The Svelte E2E targets likewise require
project-local `svelteserver`, `tailwindcss-language-server`, and their selected
ESLint or Biome backend.  The remaining fixtures keep intent, command, and
cohort tests reproducible without making the default suite depend on external
toolchains.

```sh
make test-presets-e2e
```
