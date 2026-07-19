# Releasing Eglotx

Eglotx is distributed directly from its Git repository as one multi-file Emacs
VC package whose main file is `eglotx.el`.  A signed tag and GitHub Release
identify an immutable source revision for users and explicit `:rev` recipes;
publishing to GNU ELPA, NonGNU ELPA, or MELPA is a separate submission process.

## Version invariants

- The `Version:` header in `eglotx.el` and the newest dated Changelog entry
  must agree.
- A release tag is `vVERSION` and points at that exact version-bump commit.
- Leave the package header at the latest released version during ordinary
  development.  Bump it only when cutting the next release: `package-vc`'s
  `:last-release` means the last commit that changed the main file's version
  header, not simply the newest Git tag.
- Keep future user-visible work under `Unreleased`.  A first release has no
  `Fixed` section because there is no earlier public behavior to compare with.

## Preflight

1. Update the package header, Changelog date, README installation example, and
   release notes together, then verify the synchronized values.  For 0.1.0:

   ```sh
   make release-check RELEASE_VERSION=0.1.0 RELEASE_DATE=2026-07-19
   ```

2. Confirm `.elpaignore` excludes development-only Elisp from package
   byte-compilation.
3. Run `make check` and verify a clean worktree.
4. Push the release commit to `main` and wait for the Emacs 29.4, 30.2, and
   snapshot CI jobs to pass.

For 0.1.0, the repository intentionally starts with one root commit.  Verify
that property before the first push:

```sh
git rev-list --count HEAD
git status --short
```

## Tag and GitHub Release

Create a signed annotated tag after CI passes, then publish it:

```sh
git tag -s v0.1.0 -m "Eglotx 0.1.0"
git push origin v0.1.0
```

Create the GitHub Release from the 0.1.0 Changelog body:

```sh
awk '
  /^## \[0\.1\.0\]/ { emit = 1; next }
  /^\[Unreleased\]:/ { emit = 0 }
  emit
' CHANGELOG.md |
  gh release create v0.1.0 \
    --verify-tag \
    --title "Eglotx 0.1.0" \
    --notes-file -
```

GitHub supplies source `.zip` and `.tar.gz` archives automatically; Eglotx has
no separate binary release artifact.

## Published-install smoke test

Use a fresh `package-user-dir` and install `v0.1.0` through `package-vc`.
Verify that `eglotx`, `eglotx-presets`, and `eglotx-presets-mode` load, and that
development-only Elisp under `test`, `benchmark`, and `ci` was not
byte-compiled.  This test must use the pushed tag rather than the maintainer
checkout.

Primary references:

- [Emacs multi-file packages](https://www.gnu.org/software/emacs/manual/html_node/elisp/Multi_002dfile-Packages.html)
- [Fetching package sources with package-vc](https://www.gnu.org/software/emacs/manual/html_node/emacs/Fetching-Package-Sources.html)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [`gh release create`](https://cli.github.com/manual/gh_release_create)
