#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Find and rewrite live NCS version references in tracked files."""

import pathlib
import re
import subprocess
import sys


# A reference can wrap once, including between words in the product name.
SPACE = r"(?:[ \t]+|[ \t]*\n[ \t]*)"
VERSION = r"v?\d+[._]\d+[._]\d+"
PREFIX = (
    rf"sdk-nrf-toolchain:|nrf{SPACE}connect{SPACE}sdk{SPACE}|"
    rf"ncs{SPACE}|sdk-nrf[ \t]*@{SPACE}|"
    r"ncs[-_]ws[-_]|ncs[-_]venv[-_]|ncs_version(?:[_=:]|[ \t]|\n)+"
)
REFERENCE = re.compile(rf"(?i)(?:{PREFIX})(?P<version>{VERSION})")
BOOT_BANNER = re.compile(r"(?m)^.*\*{3} Booting nRF Connect SDK .*$")
WEST_REVISION = re.compile(
    r"(?m)^([ \t]*-[ \t]+name:[ \t]+nrf[ \t]*\n"
    r"(?:(?![ \t]*-[ \t]+name:).*(?:\n|$))*?"
    r"[ \t]*revision:[ \t]*)(v\d+\.\d+\.\d+)",
)


def tracked_files(root):
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
    for raw in names:
        if not raw:
            continue
        name = raw.decode()
        if (
            name == "west.yml"
            or name == "CHANGELOG.md"
            or name.startswith((".github/release-notes/", "docs/adr/", "scripts/tests/"))
        ):
            continue
        path = root / name
        if path.is_file():
            yield name, path


def references(content):
    banners = [m.span() for m in BOOT_BANNER.finditer(content)]
    for match in REFERENCE.finditer(content):
        if any(start <= match.start() < end for start, end in banners):
            continue
        value = match.group("version")
        normalized = "v" + value.lstrip("vV").replace("_", ".")
        yield match, normalized


def rewrite(content, matches, target):
    for match, _ in reversed(matches):
        original = match.group("version")
        separator = "_" if "_" in original else "."
        version = target[1:].replace(".", separator)
        if original[0].lower() == "v":
            version = original[0] + version
        content = content[: match.start("version")] + version + content[match.end("version") :]
    return content


def main():
    mode = sys.argv[1]
    if mode == "version":
        match = WEST_REVISION.search(pathlib.Path(sys.argv[2]).read_text())
        if not match:
            raise SystemExit(1)
        print(match.group(2))
        return
    root = pathlib.Path(sys.argv[2])
    target = sys.argv[3] if mode == "rewrite" else None
    for name, path in tracked_files(root):
        try:
            content = path.read_text()
        except (UnicodeError, OSError):
            continue
        matches = list(references(content))
        if mode == "scan":
            for match, version in matches:
                line = content.count("\n", 0, match.start()) + 1
                print(f"{name}:{line}:{version}")
        elif matches:
            updated = rewrite(content, matches, target)
            if updated != content:
                path.write_text(updated)
                print(name)
    if mode == "rewrite":
        west = root / "west.yml"
        content = west.read_text()
        updated, count = WEST_REVISION.subn(lambda m: m.group(1) + target, content, count=1)
        if count != 1:
            raise SystemExit("Error: could not rewrite nrf revision in west.yml")
        if updated != content:
            west.write_text(updated)
            print("west.yml")


if __name__ == "__main__":
    main()
