#!/usr/bin/env python3
"""Enforce the repository rules that a compiler cannot.

Run from the repository root:

    python3 Scripts/lint.py            # check everything, exit non-zero on any violation
    python3 Scripts/lint.py --summary  # counts only

Every rule here exists because it was violated, or would silently break a build, in this project.
See docs/BUILD-VERIFICATION.md for the defects that motivated them and .vigil/IMPL_RULES.md for the
rules as written for implementers.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections import defaultdict

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Targets that must compile on Linux and therefore may import Foundation and nothing else.
PURE_TARGETS = {
    "VigilProtocols",
    "VigilBitstream",
    "VigilRTSP",
    "VigilRTP",
    "VigilISAPI",
    "VigilDiscovery",
    "VigilTestKit",
}

# Targets whose every file must be wrapped in `#if os(macOS)`, because `swift test` compiles all
# targets even when filtered, so an unguarded AppKit import breaks the Linux run for everyone.
MACOS_TARGETS = {"VigilTransport", "VigilVideo", "VigilRender", "VigilCore", "VigilUI", "Vigil"}

FORBIDDEN_IN_PURE = [
    "AppKit", "SwiftUI", "CoreMedia", "CoreVideo", "CoreImage", "AVFoundation", "VideoToolbox",
    "AudioToolbox", "Metal", "MetalKit", "Network", "Security", "OSLog", "CryptoKit",
    "CommonCrypto", "Accelerate", "UserNotifications", "AppIntents", "Observation",
    "UniformTypeIdentifiers", "Darwin",
]

MAX_LINE = 110

Violation = tuple[str, int, str, str]  # path, line number, rule, message


def swift_files(subdir: str) -> list[pathlib.Path]:
    base = ROOT / subdir
    if not base.exists():
        return []
    return sorted(p for p in base.rglob("*.swift") if p.name != "Placeholder.swift")


def target_of(path: pathlib.Path) -> str:
    rel = path.relative_to(ROOT).parts
    return rel[1] if len(rel) > 1 else ""


def strip_comments_and_strings(line: str) -> str:
    """Crude but adequate: drop // comments and "..." literals so we do not match inside them."""
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    idx = line.find("//")
    return line[:idx] if idx >= 0 else line


def check_imports(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    out: list[Violation] = []
    target = target_of(path)
    if target not in PURE_TARGETS:
        return out
    for n, raw in enumerate(lines, 1):
        m = re.match(r"\s*(?:@\w+\s+)?import\s+(\w+)", raw)
        if m and m.group(1) in FORBIDDEN_IN_PURE:
            out.append((str(path.relative_to(ROOT)), n, "purity",
                        f"pure target {target} imports {m.group(1)}; it must build on Linux inside "
                        f"the VigilPure product"))
    return out


def check_macos_guard(path: pathlib.Path, text: str) -> list[Violation]:
    target = target_of(path)
    if target not in MACOS_TARGETS:
        return []
    if "#if os(macOS)" in text:
        return []
    return [(str(path.relative_to(ROOT)), 1, "guard",
             f"{target} is macOS-only, so the whole file must be wrapped in #if os(macOS) — "
             f"swift test compiles every target even when filtered")]


BANNED = [
    (re.compile(r"\btry!\s"), "try!"),
    (re.compile(r"\bas!\s"), "as!"),
    (re.compile(r"\bfatalError\s*\("), "fatalError"),
    (re.compile(r"(?<![\w.])print\s*\("), "print"),
    (re.compile(r"\bTODO\b|\bFIXME\b"), "TODO/FIXME"),
]

# A force-unwrap: an identifier or ) or ] followed by ! that is not !=, and not a prefix ! negation.
FORCE_UNWRAP = re.compile(r"[\w\)\]]\!(?!=)")


def check_banned(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    for n, raw in enumerate(lines, 1):
        code = strip_comments_and_strings(raw)
        for pattern, name in BANNED:
            if pattern.search(code):
                out.append((rel, n, "banned", f"{name} is not allowed in Sources/"))
        if FORCE_UNWRAP.search(code):
            # `foo!` in a type position (`String!`) is equally unwanted, so no exemption.
            out.append((rel, n, "banned", "force-unwrap is not allowed in Sources/"))
    return out


def check_line_length(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    rel = str(path.relative_to(ROOT))
    return [(rel, n, "width", f"line is {len(raw.rstrip())} columns, limit is {MAX_LINE}")
            for n, raw in enumerate(lines, 1) if len(raw.rstrip()) > MAX_LINE]


def check_trailing_whitespace(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    rel = str(path.relative_to(ROOT))
    return [(rel, n, "whitespace", "trailing whitespace")
            for n, raw in enumerate(lines, 1) if raw.rstrip("\n") != raw.rstrip()]


def check_duplicate_test_names() -> list[Violation]:
    """Defect 4: two agents choosing the same obvious @Test name break the whole target.

    swift-testing attaches @Test to free functions, which share one namespace per module. A name
    declared inside a `@Suite struct` is scoped to that suite and does not collide, so only
    top-level (unindented) declarations are checked.
    """
    out: list[Violation] = []
    by_target: dict[str, dict[str, list[tuple[str, int]]]] = defaultdict(lambda: defaultdict(list))
    for path in swift_files("Tests"):
        target = target_of(path)
        for n, raw in enumerate(path.read_text().splitlines(), 1):
            m = re.match(r"@Test(?:\([^)]*\))?\s+func\s+(\w+)", raw)  # no leading whitespace == top level
            if m:
                by_target[target][m.group(1)].append((str(path.relative_to(ROOT)), n))
    for target, names in by_target.items():
        for name, sites in names.items():
            if len(sites) > 1:
                where = ", ".join(f"{p}:{n}" for p, n in sites)
                out.append((sites[0][0], sites[0][1], "test-name",
                            f"@Test func {name}() is declared {len(sites)} times at top level in "
                            f"{target} ({where}); free functions share one namespace, so this fails "
                            f"the whole target — prefix each with the type under test"))
    return out


def check_file_header(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    if not lines or not lines[0].startswith("//"):
        return [(str(path.relative_to(ROOT)), 1, "header",
                 "file must open with a // header block naming the file, its module and its purpose")]
    return []


def check_plists() -> list[Violation]:
    """Property lists and entitlements must be well-formed XML, or the app cannot be built.

    The failure this catches in practice: XML forbids a double hyphen *anywhere* inside a comment,
    so documenting a command-line flag as `--version` in a plist comment produces a file that
    plutil, codesign and Xcode all reject. It looks completely fine to a human reader.
    """
    import plistlib

    out: list[Violation] = []
    for directory in ("Resources", "Sources"):
        base = ROOT / directory
        if not base.exists():
            continue
        for path in sorted(list(base.rglob("*.plist")) + list(base.rglob("*.entitlements"))):
            rel = str(path.relative_to(ROOT))
            raw = path.read_bytes()
            try:
                plistlib.loads(raw)
            except Exception as error:  # plistlib raises several unrelated types
                hint = ""
                text = raw.decode("utf-8", "replace")
                for n, line in enumerate(text.splitlines(), 1):
                    stripped = line.strip()
                    if "--" in stripped.replace("<!--", "").replace("-->", ""):
                        hint = (f" — line {n} has a double hyphen inside a comment, which XML "
                                f"forbids; reword the flag name")
                        break
                out.append((rel, 1, "plist", f"not valid XML: {error}{hint}"))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", action="store_true", help="print counts only")
    args = parser.parse_args()

    violations: list[Violation] = []

    for path in swift_files("Sources"):
        text = path.read_text()
        lines = text.splitlines()
        violations += check_imports(path, lines)
        violations += check_macos_guard(path, text)
        violations += check_banned(path, lines)
        violations += check_line_length(path, lines)
        violations += check_trailing_whitespace(path, lines)
        violations += check_file_header(path, lines)

    for path in swift_files("Tests"):
        lines = path.read_text().splitlines()
        violations += check_line_length(path, lines)
        violations += check_trailing_whitespace(path, lines)

    violations += check_duplicate_test_names()
    violations += check_plists()

    if not violations:
        n_src = len(swift_files("Sources"))
        n_test = len(swift_files("Tests"))
        print(f"lint: clean — {n_src} source files, {n_test} test files")
        return 0

    by_rule: dict[str, int] = defaultdict(int)
    for _, _, rule, _ in violations:
        by_rule[rule] += 1

    if not args.summary:
        for rel, line, rule, message in sorted(violations):
            print(f"{rel}:{line}: {rule}: {message}")
        print()

    print(f"lint: {len(violations)} violation(s): "
          + ", ".join(f"{rule} {count}" for rule, count in sorted(by_rule.items())))
    return 1


if __name__ == "__main__":
    sys.exit(main())
