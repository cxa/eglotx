# Coding standards

Eglotx is latency-sensitive infrastructure.  Changes must preserve the
following rules.

1. Public symbols use the `eglotx-` prefix.  Double-hyphen symbols are private.
2. Source files use lexical binding and must byte-compile without warnings on
   the oldest supported Emacs.
3. Process filters and JSON-RPC callbacks do bounded work.  Never synchronously
   wait for another language server from a callback.
4. Request completion, cancellation, timeout, and process failure share one
   idempotent cleanup path.  Every timer and table entry has an explicit owner.
5. Results are deterministic in configured backend order, never response order.
6. Do not mutate a JSON object owned by Eglot or by another backend.  Copy only
   the path that needs transformation; avoid whole-payload copies on hot paths.
7. Spawn commands directly with `make-process`; never interpolate backend
   commands through a shell.
8. Logging is off on backend hot paths by default.  Diagnostic or benchmark
   code must not change protocol timing when disabled.
9. LSP capability combination is method-specific.  Generic deep merge is not a
   substitute for a documented combination rule.
10. Observable behavior is tested through the Eglotx facade with fake LSP
    processes.  Pure helpers may have focused tests when the protocol seam would
    make an edge case impractical to construct.
11. `eglotx.el` is policy-free core.  Language names, package-manager and
    manifest detection, executable discovery, server-specific settings, and
    global Eglot contact registration belong in optional modules.
