# Eglotx documentation

Each document has one job.  Keeping these boundaries explicit prevents the
public contract, implementation notes, and dated research from drifting into
competing descriptions of the project.

| Document | Authority and audience |
| --- | --- |
| [`../README.md`](../README.md) | Installation, first use, the product model, and operational troubleshooting. |
| [`api.md`](api.md) | Public Emacs Lisp functions, backend descriptors, customization variables, and the optional Eglot adapter. |
| [`presets.md`](presets.md) | The current bundled contact catalog, exact discovery policy, executable precedence, and deliberate exclusions. |
| [`spec.md`](spec.md) | Normative facade behavior, performance requirements, compatibility, non-goals, and acceptance checks. |
| [`architecture.md`](architecture.md) | How the current implementation satisfies the specification.  Private data structures and algorithms are descriptive, not public API. |
| [`releasing.md`](releasing.md) | Maintainer checklist for versioning, tagging, pushing, and creating a GitHub release. |
| [`../CHANGELOG.md`](../CHANGELOG.md) | User-visible changes by release; it is not a second feature specification. |
| [`research/`](research/) | Dated, commit-pinned decision inputs.  Recommendations and implementation snapshots there are historical unless promoted into the specification or preset catalog. |

When documents disagree, public Elisp docstrings and current code define what
the package accepts, while `spec.md` and its tests define intended observable
behavior.  A behavior change should update the code, tests, specification, and
API or preset reference in the same change.  Research files should retain their
historical claims and instead receive a status note pointing to the resulting
current behavior.

The package header and latest release entry must use the same version.  New
user-visible work is recorded under `Unreleased` until the next version is
tagged.
