"""Select the latest supported Emacs release per major from nix-emacs-ci."""

import json
from pathlib import Path
import re
import sys


def minimum_emacs(source):
    """Read the minimum Emacs version from the package's dependency header."""
    match = re.search(r'^;; Package-Requires:.*\(emacs "(\d+)\.(\d+)"\)', source, re.M)
    if match is None:
        raise ValueError("Missing Emacs minimum in Package-Requires")
    return tuple(map(int, match.groups()))


def select_versions(lock, minimum):
    """Return one latest stable release per supported major, plus snapshot."""
    inputs = lock["nodes"][lock["root"]]["inputs"]
    releases = {}
    for name in inputs:
        match = re.fullmatch(r"emacs-(\d+)-(\d+)", name)
        if match is not None:
            version = tuple(map(int, match.groups()))
            if version >= minimum:
                major, patch = version
                releases[major] = max(patch, releases.get(major, patch))
    if not releases:
        raise ValueError("No supported stable Emacs releases in upstream manifest")
    if "emacs-snapshot" not in inputs:
        raise ValueError("Missing Emacs snapshot in upstream manifest")
    return [f"{major}.{releases[major]}" for major in sorted(releases)] + ["snapshot"]


def main():
    source = (Path(__file__).resolve().parent.parent / "eglotx.el").read_text()
    versions = select_versions(json.load(sys.stdin), minimum_emacs(source))
    print(json.dumps({"emacs-version": versions}, separators=(",", ":")))


if __name__ == "__main__":
    main()
