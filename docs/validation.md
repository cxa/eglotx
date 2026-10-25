# Reliability checks

Use this checklist before you accept a server change or report a test pass.
For configuration details, see [presets](presets.md). For fixture setup, see
[test projects](../test/projects/README.md).

## Prepare the environment

1. Use an isolated checkout and a fresh output directory.
2. Record the commit and the source hashes.
3. Record the Emacs, Eglot, jsonrpc, runtime, and server versions.
4. Record the loaded library paths and the actual server executable.
5. Install the fixture dependencies described in the test-project guide.

The reference cloud checks used Emacs 30.1 and original Eglot 1.24.
CI checks Emacs 29.4, 30.2, and snapshot. The package requires Eglot 1.24
and jsonrpc 1.0.29 or newer. A version reported by a wrapper does not prove
which executable served the LSP connection. Check its PID, arguments, and
executable hash. A file extension does not prove which backend ran.

## Select the root and runtime

- Check the initialization root before you test a nested package.
  Use `project-vc-extra-root-markers` with `package.json` when the package
  must be the project root. A Git root can change ignore and format policy.
- Use the Biome version that accepts the repository configuration.
  Do not use a global upgrade as proof that an older pinned version works.
- Keep intentional capability refusals visible. Legacy Biome can request
  unnegotiated registrations. A rejected batch is not watch coverage.
- Enable `html.formatter.enabled` in Vue, Svelte, and Astro Biome fixtures.
  Full-document support alone does not enable that formatter.
- Keep stdout for protocol frames. Send launcher diagnostics to stderr.
- Do not execute unfamiliar project scripts or executable configuration
  during a static LSP probe. Record the excluded features.

## Run the checks

```sh
make deps
make check
make test-presets-e2e
make deps-corfu-e2e
make test-corfu-e2e
git diff --check
```

`make check` compiles with fatal warnings and runs the ERT suites. It loads
the core test helpers first. CI runs this target only. Real-server targets
need their own dependencies. Keep the default Corfu gate at 150 ms when
comparing with the reference result. Record a different budget explicitly.

## Verify the result

- Distinguish protocol success from useful feature output. Count empty
  completion, hover, definition, and symbol results separately.
- Require an effective format edit. Synchronize the buffer. Require an
  unchanged second pass. An ignored source is a negative control.
- Wait for the backend diagnostic publication. UI absence alone does not
  prove that a backend cleared its diagnostics.
- Verify each backend before and after reconnect. Preserve the original
  source, backend set, and configuration when comparing runs.
- Check process exit and residual children. A completion marker alone is
  insufficient. Eglotx gives all backends one shared 1.5-second exit grace.
  It reports and terminates overdue owned processes. It does not guarantee
  cleanup of arbitrary detached descendants or bound every cleanup callback.
- Preserve failed attempts. Return nonzero for a failed or incomplete run.
  Do not overwrite an accepted result with a rerun.

## Keep limits explicit

Cloud socket restrictions can block real Biome tests. Use an authorized
environment; do not bypass the restriction. Report lifecycle and feature
results separately. A partial feature result is not a full pass.

Local Eglot timeout, Svelte generated-symbol, and legacy Biome exit
workarounds are not upstream fixes. They are not installed by Eglotx.
Record each overlay and runtime override. Project-only Python watches can
require a server restart after an external library changes.

LSP checks do not establish that an application builds or its tests pass.
Historical corpus results do not replace checks on a new commit.
