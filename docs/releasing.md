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
- Both stable installation examples in `README.md` pin the same release tag.
  Development-branch instructions use `:newest` explicitly.
- Keep future user-visible work under `Unreleased` until it is moved into a
  dated release section.

## Preflight

1. Choose the release version and date, then update the package header,
   Changelog heading, both README stable-install tags, and release notes
   together.
   Verify the synchronized values in the same shell session:

   ```sh
   EGLOTX_RELEASE_VERSION=X.Y.Z
   EGLOTX_RELEASE_DATE=YYYY-MM-DD
   make release-check \
     RELEASE_VERSION="$EGLOTX_RELEASE_VERSION" \
     RELEASE_DATE="$EGLOTX_RELEASE_DATE"
   ```

2. Confirm `.elpaignore` excludes development-only Elisp from package
   byte-compilation.
3. Run `make check` and verify a clean worktree.
4. Push the release commit to `main` and wait for the Emacs 29.4, 30.2, and
   snapshot CI jobs to pass.

## Tag and GitHub Release

Create a signed annotated tag for the release commit after CI passes, then
publish it:

```sh
EGLOTX_RELEASE_VERSION=X.Y.Z
EGLOTX_RELEASE_TAG="v$EGLOTX_RELEASE_VERSION"
git tag -s "$EGLOTX_RELEASE_TAG" -m "Eglotx $EGLOTX_RELEASE_VERSION"
git push origin "$EGLOTX_RELEASE_TAG"
```

Create the GitHub Release from the matching Changelog body:

```sh
EGLOTX_RELEASE_VERSION=X.Y.Z
EGLOTX_RELEASE_TAG="v$EGLOTX_RELEASE_VERSION"
awk -v version="$EGLOTX_RELEASE_VERSION" '
  $0 ~ "^## \\[" version "\\] - " { emit = 1; next }
  emit && /^## \[/ { exit }
  emit && /^\[/ { exit }
  emit
' CHANGELOG.md |
  gh release create "$EGLOTX_RELEASE_TAG" \
    --verify-tag \
    --title "Eglotx $EGLOTX_RELEASE_VERSION" \
    --notes-file -
```

GitHub supplies source `.zip` and `.tar.gz` archives automatically; Eglotx has
no separate binary release artifact.

## Published-install smoke test

Use a fresh `package-user-dir` and install the pushed release tag through
`package-vc`.  Verify that `eglotx`, `eglotx-presets`, and
`eglotx-presets-mode` load, and that development-only Elisp under `test`,
`benchmark`, and `ci` was not byte-compiled.  This test must use the pushed tag
rather than the maintainer checkout.

Primary references:

- [Emacs multi-file packages](https://www.gnu.org/software/emacs/manual/html_node/elisp/Multi_002dfile-Packages.html)
- [Fetching package sources with package-vc](https://www.gnu.org/software/emacs/manual/html_node/emacs/Fetching-Package-Sources.html)
- [GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)
- [`gh release create`](https://cli.github.com/manual/gh_release_create)
