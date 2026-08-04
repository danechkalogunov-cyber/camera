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
import plistlib
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
MAX_FILE_LINES = 600

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


def blank_comments_and_strings(text: str) -> str:
    """`text` with every comment and string-literal body replaced by spaces, **same length**.

    ⛔ The length and the newlines are the point. Anything that scans by offset — the parenthesis
    walker below, and the line number it reports — has to be able to run on the blanked copy and
    still describe the original. Truncating, as ``strip_comments_and_strings`` does per line, would
    make every offset past the first comment wrong.

    Why it had to exist: ``check_argument_order`` split a call's parentheses on commas and matched
    each segment against ``ARG_LABEL``, which anchors at `^\\s*`. A call site written like

        onAddGroup: { … },
        // The gear in the sidebar footer drew itself and answered to nothing.
        onOpenSettings: { … },

    puts a comment at the head of the `onOpenSettings` segment, the anchor fails on `/`, and the
    label is dropped **in silence**. The remaining labels were still a subset of the declared order
    and still in order, so the call passed — and the argument-order error it was written to catch
    shipped and broke the Mac build for four commits. This project comments its call sites heavily,
    so the check was blind precisely where it was needed.

    Blanking string bodies fixes a second latent version of the same defect: a `(` or a `,` inside a
    literal moved the walker's depth and split segments in the wrong places.
    """
    out = list(text)
    index, count = 0, len(text)
    while index < count:
        char = text[index]
        pair = text[index:index + 2]
        if pair == "//":
            while index < count and text[index] != "\n":
                out[index] = " "
                index += 1
            continue
        if pair == "/*":
            # Swift nests block comments, so this counts rather than searching for the first `*/`.
            depth = 0
            while index < count:
                here = text[index:index + 2]
                if here == "/*":
                    depth += 1
                    out[index] = out[index + 1] = " "
                    index += 2
                    continue
                if here == "*/":
                    depth -= 1
                    out[index] = out[index + 1] = " "
                    index += 2
                    if depth == 0:
                        break
                    continue
                if text[index] != "\n":
                    out[index] = " "
                index += 1
            continue
        if text[index:index + 3] == '"""':
            index += 3
            while index < count and text[index:index + 3] != '"""':
                index = _blank_string_byte(text, out, index)
            index += 3
            continue
        if char == '"':
            index += 1
            while index < count and text[index] != '"':
                index = _blank_string_byte(text, out, index)
            index += 1
            continue
        index += 1
    return "".join(out)


def _blank_string_byte(text: str, out: list[str], index: int) -> int:
    """Blanks one byte of a string literal, and returns the next index to look at.

    ⛔ An interpolation is left **intact**, contents and delimiters both. `"\\(Self.prefix)v"` is a
    real use of `prefix`, and blanking it is what hid eleven of them from `check_split_file_access`
    the first time that rule was written. Keeping the parentheses also keeps them balanced, so the
    argument-order scanner's depth counting is unaffected — and a comma inside an interpolation sits
    at least one level deeper than the call's own arguments, so it cannot split a segment either.
    """
    if text[index] == "\\" and text[index + 1:index + 2] == "(":
        depth, i = 0, index + 1
        while i < len(text):
            depth += (text[i] == "(") - (text[i] == ")")
            i += 1
            if depth == 0:
                return i
        return i
    if text[index] == "\\":
        out[index] = " "
        if index + 1 < len(text) and text[index + 1] != "\n":
            out[index + 1] = " "
        return index + 2
    if text[index] != "\n":
        out[index] = " "
    return index + 1


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


def check_file_length(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    """API_CONTRACT.md §7.2: a source file is ≤ 600 lines, split at a `// MARK:` boundary.

    ⛔ Nothing checked this until now, and it had already drifted: `MainWindowView.swift` reached 630
    lines while every file in the tree carried a header citing the rule. A limit that only exists in
    prose is a limit that is enforced when somebody happens to notice, which is not enforcement — and
    this one matters because the whole `Type+Feature.swift` layout of `Sources/Vigil` exists to
    honour it.

    The ceiling applies to production and test sources alike. Keeping this as one enforced rule
    avoids a second, advisory-only standard drifting after oversized tests have been split.
    """
    rel = str(path.relative_to(ROOT))
    if len(lines) <= MAX_FILE_LINES:
        return []
    return [(rel, len(lines), "file-length",
             f"{len(lines)} lines, limit is {MAX_FILE_LINES} (API_CONTRACT.md §7.2). "
             "Split at a `// MARK:` boundary into Type+Feature.swift")]


GENERIC_DECL = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:public |package |internal |private |fileprivate |open )?"
    r"(?:final )?(?:struct|class|enum|actor)\s+(\w+)\s*<([^>]+)>")

STATIC_STORED = re.compile(
    r"^\s*(?:public |package |internal |private |fileprivate )?static\s+(let|var)\s+(\w+)")


TYPE_DECL = re.compile(
    r"^\s*(?:package |public |private |internal |fileprivate )?(?:final )?"
    r"(?:struct|enum|class|actor)\s+(\w+)")

def check_static_stored_in_generic(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    """Swift forbids static STORED properties in a generic type. Computed ones are fine.

    This is here because the compiler that would catch it does not run in this container. Every
    generic type in the macOS-only targets lives inside `#if os(macOS)`, so on Linux the declaration
    preprocesses away and `swift build` is perfectly happy. The first machine to see it is the
    customer's Mac, where it is a hard error:

        error: static stored properties not supported in generic types

    That is exactly what happened to `VTextField<FocusValue>`, whose three `static let`s stopped the
    very first real build. The fix is a separate non-generic namespace; the rule is here so the next
    one is caught on Linux instead.
    """
    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    stack: list[tuple[str, int]] = []      # (type name, brace depth at its opening line)
    depth = 0
    for n, raw in enumerate(lines, 1):
        code = strip_comments_and_strings(raw)
        m = GENERIC_DECL.match(raw)
        if m and "{" in code:
            stack.append((m.group(1), depth))
        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
        if not stack:
            continue
        s = STATIC_STORED.match(raw)
        if not s:
            continue
        kind, name = s.groups()
        # `static var x: T { ... }` with no `=` is computed, which is legal. Anything with an
        # initialiser is stored, and so is a `let` without a body.
        if "=" not in code:
            if kind == "var" and "{" in code:
                continue
            if kind == "let":
                continue
        out.append((rel, n, "generic-static",
                    f"static {kind} {name} is a stored property inside generic type "
                    f"{stack[-1][0]}<>; Swift rejects this on macOS with 'static stored properties "
                    f"not supported in generic types'. Move it to a non-generic namespace enum, or "
                    f"make it a computed 'static var {name}: T {{ ... }}'"))
    return out


def check_environment_key_isolation(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    """Defect 5: `@MainActor` on an `EnvironmentKey`'s `defaultValue` does not compile.

    `EnvironmentKey.defaultValue` is a `nonisolated` static requirement, so a main-actor-isolated
    property cannot witness it: Swift 6 rejects the conformance with `#ConformanceIsolation`. The
    mistake is easy to make because every *view* nearby is `@MainActor`, and it is invisible on
    Linux — `VigilUI` is never compiled here — so it costs a round trip to a Mac to find.
    """
    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    inside = False
    for n, raw in enumerate(lines, 1):
        code = strip_comments_and_strings(raw)
        if "EnvironmentKey" in code and ("struct" in code or "enum" in code):
            inside = True
            continue
        if not inside:
            continue
        if code.strip() == "}":
            inside = False
            continue
        if "defaultValue" in code and "@MainActor" in code:
            out.append((rel, n, "environment-isolation",
                        "@MainActor on an EnvironmentKey's defaultValue does not compile: the "
                        "protocol requirement is nonisolated, so a main-actor-isolated property "
                        "cannot witness it (#ConformanceIsolation). Drop the attribute; a computed "
                        "'static var defaultValue' needs no isolation and no Sendable conformance."))
    return out


ISOLATED_THEME = re.compile(r"@MainActor\s+public enum\s+(\w+)")


def isolated_theme_namespaces() -> set[str]:
    """The theme namespaces declared `@MainActor`, read from VTheme.swift rather than listed here.

    Listing them would rot the moment one is added or an isolation is dropped, and a rule that
    describes the code inaccurately is worse than no rule.
    """
    source = ROOT / "Sources/VigilUI/Theme/VTheme.swift"
    if not source.exists():
        return set()
    return set(ISOLATED_THEME.findall(source.read_text()))


def check_theme_isolation(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    """Defect 6: a nonisolated static that reads an @MainActor theme namespace does not compile.

    `VTheme.Space`, `VTheme.Metrics`, `VTheme.Color.Text` and most of their siblings are declared
    `@MainActor`. A `static let`/`static var` in a type that is *not* isolated cannot touch one:

        error: main actor-isolated static property 'tileChromeInset' can not be referenced
               from a nonisolated context

    Invisible on Linux, because `VigilUI` is never compiled here, so it costs a round trip to a Mac.
    Views are almost always `@MainActor` already; the trap is a plain `enum` of metrics beside one.

    ⚠️ Only a *member* access is flagged. Actor isolation does not propagate into a nested type, so
    `VTheme.Typography.Scale.standard` is legal from anywhere — `Scale` is its own, unisolated type —
    and a rule that flagged it would be telling the truth about the attribute and a lie about the
    language. The distinguishing test is the case of the segment after the isolated namespace.
    """
    namespaces = isolated_theme_namespaces()
    if not namespaces:
        return []
    reads = re.compile(r"VTheme(?:\.\w+)*?\.(" + "|".join(sorted(namespaces)) + r")\.([A-Za-z_]\w*)")
    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    stack: list[tuple[str, int, bool]] = []   # (name, depth, is main-actor isolated)
    depth = 0
    isolated_next = False
    for n, raw in enumerate(lines, 1):
        code = strip_comments_and_strings(raw)
        stripped = raw.strip()
        if stripped.startswith("@MainActor"):
            isolated_next = True
            if stripped == "@MainActor":
                continue
        decl = TYPE_DECL.match(raw)
        if decl and "{" in code:
            stack.append((decl.group(1), depth, isolated_next))
            isolated_next = False
        elif stripped and not stripped.startswith(("//", "@")):
            isolated_next = False
        depth += code.count("{") - code.count("}")
        while stack and depth <= stack[-1][1]:
            stack.pop()
        if not stack or stack[-1][2]:
            continue
        if not re.match(r"\s*(?:package |public |private |internal |fileprivate )?static ", raw):
            continue
        for _, member in reads.findall(code):
            if member[:1].isupper():
                continue          # a nested type, which carries no isolation of its own
            out.append((rel, n, "theme-isolation",
                        f"a nonisolated static in {stack[-1][0]} reads a @MainActor theme "
                        f"namespace ('{member}'). Swift rejects this on macOS with 'main "
                        "actor-isolated static property ... can not be referenced from a "
                        "nonisolated context'. Mark the enclosing type @MainActor."))
            break
    return out


INIT_DECL = re.compile(
    r"^\s*(?:package |public |private |internal |fileprivate )?"
    r"(?:convenience )?init\??\(")
CALL_START = re.compile(r"\b([A-Z]\w*)\(")
# A call-site label: `name:`, with no attributes and no second identifier.
ARG_LABEL = re.compile(r"^\s*([a-z_]\w*)\s*:")

# A declaration-site parameter: optional attributes, then an external label and possibly an
# internal one. `@ViewBuilder video: …` and `_ title: …` are both this shape, and missing
# either of them is not a harmless gap — a declared order short of one label stops being a
# superset of the call's labels, and the whole call is then skipped in silence. That is
# exactly how this check passed the argument-order error it was written for.
PARAM_LABEL = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(\w+)(?:\s+(\w+))?\s*:")


def _append_label(labels: list[str], segment: str, declaration: bool) -> None:
    """Adds one label from a parameter or argument segment, if it has one."""
    if declaration:
        m = PARAM_LABEL.match(segment)
        if m and m.group(1) != "_":
            labels.append(m.group(1))
        return
    m = ARG_LABEL.match(segment)
    if m:
        labels.append(m.group(1))


def _labels_in_parens(text: str, open_index: int,
                      declaration: bool = False) -> list[str] | None:
    """The argument labels at depth 1 of the parenthesis starting at `open_index`.

    With `declaration`, parses a parameter list instead: attributes are skipped and the *external*
    label is taken, so `@ViewBuilder video: …` reads as `video` and `_ title: …` is dropped, since a
    caller cannot name it.

    Answers `None` when the parenthesis does not close in `text` — a call split across a construct
    this scanner does not model, which must be skipped rather than guessed at.
    """
    depth, i, n = 0, open_index, len(text)
    labels: list[str] = []
    segment_start = open_index + 1
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
            if depth == 1:
                segment_start = i + 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                _append_label(labels, text[segment_start:i], declaration)
                return labels
        elif c == "," and depth == 1:
            _append_label(labels, text[segment_start:i], declaration)
            segment_start = i + 1
        i += 1
    return None


def declared_initialiser_labels() -> dict[str, list[list[str]]]:
    """Every type's initialiser label orders, keyed by type name.

    A type may declare several initialisers; a call is legal if it matches any one of them, so the
    value is a list of orders rather than a single one.
    """
    out: dict[str, list[list[str]]] = {}
    for path in swift_files("Sources"):
        # Blanked, not raw: a doc comment between two parameters would otherwise swallow the one
        # after it, and a declared order short of a label stops being a superset of the call's.
        text = blank_comments_and_strings(path.read_text())
        lines = text.split("\n")
        stack: list[tuple[str, int]] = []
        depth = 0
        for n, raw in enumerate(lines):
            code = strip_comments_and_strings(raw)
            decl = TYPE_DECL.match(raw)
            if decl and "{" in code:
                stack.append((decl.group(1), depth))
            if stack and INIT_DECL.match(raw):
                offset = sum(len(l) + 1 for l in lines[:n]) + raw.index("(")
                labels = _labels_in_parens(text, offset, declaration=True)
                if labels:
                    out.setdefault(stack[-1][0], []).append(labels)
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return out


def check_argument_order(path: pathlib.Path, text: str,
                         declared: dict[str, list[list[str]]]) -> list[Violation]:
    """Defect 7: Swift requires arguments in the initialiser's own declaration order.

    The single most frequent build-breaker in this project's history, and one no amount of care at
    the call site prevents: these initialisers take a dozen defaulted closures, and the order that
    *reads* best is rarely the order that was *declared*. On Linux the whole of `VigilUI` is
    preprocessed away, so the first machine to notice is a Mac:

        error: argument 'onToggleFullscreen' must precede argument 'onRetry'

    A call is checked only when every label it passes is known to one declared order — anything
    else is a type this scanner cannot resolve (a shadowed name, an overload in another module) and
    is skipped rather than guessed at.
    """
    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    # ⛔ Blanked before scanning. See ``blank_comments_and_strings`` — a comment line in front of an
    # argument used to make that argument invisible to this check, which is how the one build-breaker
    # it exists to catch got past it. Blanking preserves length, so `match.start()` still counts the
    # right number of newlines for the reported line number.
    text = blank_comments_and_strings(text)
    for match in CALL_START.finditer(text):
        name = match.group(1)
        orders = declared.get(name)
        if not orders:
            continue
        used = _labels_in_parens(text, match.end() - 1)
        if not used or len(used) < 2:
            continue
        for order in orders:
            if not set(used) <= set(order):
                continue
            ranks = [order.index(label) for label in used]
            if ranks == sorted(ranks):
                break
        else:
            # No declared order both covers these labels and accepts this sequence.
            candidates = [o for o in orders if set(used) <= set(o)]
            if not candidates:
                continue
            order = candidates[0]
            ranks = [order.index(label) for label in used]
            wrong = next(used[i] for i in range(1, len(ranks)) if ranks[i] < ranks[i - 1])
            line = text.count("\n", 0, match.start()) + 1
            out.append((rel, line, "argument-order",
                        f"{name}(…) passes '{wrong}' after an argument it is declared before. "
                        f"Swift requires the initialiser's own order: "
                        f"{', '.join(order)}"))
    return out


def check_mutating_in_expect() -> list[Violation]:
    """`#expect(x.mutate())` does not compile, and the error is unreadable.

    swift-testing's macro rewrites a function call into `__checkFunctionCall(x.self, calling: { $0.f() })`
    so it can print the receiver in a failure message — and `$0` in that closure is a **`let`**. A
    `mutating` method called there fails with

        macro expansion #expect:2:6: error: cannot use mutating member on immutable value:
        '$0' is immutable

    which names a line inside a generated macro rather than the test. Ten of these arrived at once
    from one file of otherwise-correct tests, and none of them was visible in this container: the
    macro is expanded by the compiler, so only a Mac sees it.

    The fix at the call site is to hoist — `let applied = form.absorbPastedURL()` and then
    `#expect(applied)` — which also reads better, because the assertion is then about a named
    outcome rather than about a side effect.

    Three conditions have to hold together, and each one was learned by watching a looser draft
    misfire:

    1. The name is declared `mutating func` somewhere in `Sources/`. Alone this is far too loose —
       the first draft matched on the name and reported **183** violations against files that have
       been compiling on macOS for weeks.
    2. The macro's whole argument is that one call, with nothing after it. See the comment below.
    3. The receiver is declared `var` in the same test file. This is what separates
       `#expect(form.absorbPastedURL())` — `var form` — from `#require(document.node("x"))`, where
       `node` happens to also name a `mutating` method on `MergeEngine` but `document` is a `let`
       `ISAPIDocument`. Without it the rule reported eight collisions out of seventeen hits, and a
       linter that is wrong half the time is a linter the next person turns off.

    A mutating method cannot be called on a `let` at all, so condition 3 costs nothing in coverage:
    any call this rule skips for want of a `var` would not have compiled in the first place.
    """
    mutating = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
                          r"(?:public\s+|package\s+|open\s+|internal\s+|private\s+|fileprivate\s+)*"
                          r"mutating\s+func\s+(\w+)")
    names: set[str] = set()
    for path in swift_files("Sources"):
        for raw in path.read_text().splitlines():
            match = mutating.match(raw)
            if match:
                names.add(match.group(1))
    if not names:
        return []

    macro = re.compile(r"#(?:expect|require)\s*\(")
    receiver = re.compile(r"^\s*([A-Za-z_]\w*)\.(\w+)\s*\(")
    declared_var = re.compile(r"\bvar\s+([A-Za-z_]\w*)\b")
    out: list[Violation] = []
    for path in swift_files("Tests"):
        rel = str(path.relative_to(ROOT))
        text = blank_comments_and_strings(path.read_text())
        variables = set(declared_var.findall(text))
        for match in macro.finditer(text):
            argument = _balanced(text, match.end() - 1)
            if argument is None:
                continue
            call = receiver.match(argument)
            if not call or call.group(2) not in names:
                continue
            if call.group(1) not in variables:
                continue
            # ⛔ ONLY A BARE CALL. `#expect(p.evaluate(…) == .stop(…))` compiles perfectly well:
            # swift-testing takes the `__checkBinaryOperation` path for an operator expression and
            # evaluates the left side normally. It is `#expect(p.mutate())` — the whole argument
            # being one call — that becomes `__checkFunctionCall(p.self, calling: { $0.mutate() })`
            # with its immutable `$0`. The first draft of this rule matched the name alone and
            # produced 183 false positives against code that has been compiling on macOS for weeks,
            # which is how the distinction was found.
            opening = argument.index("(", call.end(2))
            inner = _balanced(argument, opening)
            if inner is None:
                continue
            if argument[opening + len(inner) + 2:].strip():
                continue
            line = text.count("\n", 0, match.start()) + 1
            out.append((rel, line, "mutating-in-expect",
                        f"#expect/#require wraps a bare call in a closure whose `$0` is a `let`, "
                        f"so the mutating '{call.group(2)}' cannot be called there. Hoist it: "
                        f"`let outcome = {call.group(1)}.{call.group(2)}()`, then assert `outcome`"))
    return out


def _balanced(text: str, open_index: int) -> str | None:
    """The contents of the parenthesis at `open_index`, or `None` when it never closes."""
    depth = 0
    for index in range(open_index, len(text)):
        if text[index] in "([{":
            depth += 1
        elif text[index] in ")]}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
    return None


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


def check_split_file_access() -> list[Violation]:
    """`private` is FILE-scoped in Swift, so splitting a type across files breaks every private
    member the other half touches.

    This is the rule that cost the most to learn, three times. Extensions of one type live in
    `Foo.swift` + `Foo+Bar.swift`, and a member left `private` in one is simply invisible to the
    other — 40-odd errors on the first Mac build, 200-odd on the third, none of them visible here.

    Four shapes the compiler rejects, all of them checked:

      1. A `private` member of one file used by another. Attributes may precede the modifier, so
         `@State private var archive` has to match too — anchoring on `private` at the start of the
         line is how eleven properties got through the first version of this check.
      2. `public private(set) var x` mutated from the other file. The **`public` comes first**, so a
         pattern that expects the access modifier to lead misses every one of these; that is how
         `RTSPWireDecoder.statistics` and four of `RTPTrackReceiver`'s counters slipped through.
      3. A `private` nested type — `private enum Phase` — referenced by the other file, including
         through its cases alone (`phase = .atBoundary`).
      4. A `private` nested type used in the *signature* of a non-private member **in its own
         file**: "property must be declared private because its type uses a private type". No
         sibling is involved, and widening a member's access is what usually triggers it, so it is
         checked on every file rather than only on split ones.

    ⚠️ Still a text scan, not a type checker. The earlier version bought its accuracy by skipping
    any name the other file also bound — as a local, a parameter, or an argument label — and that
    single line is why the third Mac build failed: `request`, `plan`, `credential`, `terminate` and
    thirty more were all suppressed by a same-named local next door. The skip is now narrow: a name
    is only ignored when the sibling declares it **as a type-level member of its own**, which is
    the one case where the two cannot be the same entity. That keeps the three known false alarms
    quiet — `VTheme.Symbol.stop`, `Stroke.contrast`, and a doc comment mentioning `displayScale` —
    and reports everything else, which is the correct trade for a rule whose misses cost a build.
    """
    out: list[Violation] = []
    groups: dict[pathlib.Path, dict[str, list[pathlib.Path]]] = defaultdict(lambda: defaultdict(list))
    for path in swift_files("Sources"):
        groups[path.parent][path.stem.split("+")[0]].append(path)

    # ⛔ The filename is not the only way a type gets split, and assuming it was is how this rule
    # missed a real one. `sheetBody` moved from `MainWindowView.swift` into an
    # `extension MainWindowView` inside `WindowSheets.swift` — a perfectly ordinary place to put it,
    # and a different stem — so the two halves landed in different groups, `renameCamera` stayed
    # `private`, and the Mac build failed on a file this check had just declared clean.
    #
    # Every file that *extends* a type now joins that type's group as well, whatever it is called.
    # Grouping stays per-directory, matching the original: two same-named types in different
    # modules are different types, and merging them would invent cross-module violations.
    extension_decl = re.compile(r"^extension\s+([A-Z]\w*)")
    for path in swift_files("Sources"):
        extended = {m.group(1) for m in
                    (extension_decl.match(raw) for raw in path.read_text().splitlines())
                    if m is not None}
        for name in extended:
            bucket = groups[path.parent][name]
            if path not in bucket:
                bucket.append(path)

    # A type-level member: four spaces of indent, any attributes, any access level.
    ACCESS = r"(?:public\s+|package\s+|open\s+|internal\s+)?"
    MODIFIERS = (r"(?:static\s+|class\s+|final\s+|mutating\s+|nonmutating\s+|nonisolated\s+"
                 r"|lazy\s+|weak\s+|unowned\s+|indirect\s+|override\s+)*")
    KIND = r"(?:func|var|let|struct|enum|class|actor|typealias)"

    # Indent is `( {4})?` rather than `    `: a top-level `private let` is file-scoped in exactly
    # the same way, and `vigilFullFsyncCommand` is one the sibling half of LibraryStore calls.
    private_decl = re.compile(
        r"^(?: {4})?(?:@\w+(?:\([^)]*\))?\s+)*" + ACCESS
        + r"(?:@\w+(?:\([^)]*\))?\s+)*"
        + r"(private\(set\)|fileprivate\(set\)|private|fileprivate)\s+"
        + MODIFIERS + r"(" + KIND + r")\s+(\w+)")
    member_decl = re.compile(
        r"^\s{4,}(?:@\w+(?:\([^)]*\))?\s+)*"
        + r"(?:(?:public|package|open|internal|private|fileprivate)(?:\(set\))?\s+)*"
        + MODIFIERS + r"(?:(" + KIND + r")|case)\s+(\w+)")

    def stripped(path: pathlib.Path) -> str:
        """The file with comments gone and string literals blanked — interpolations kept.

        ⛔ This used to do it with one regex, `"(?:[^"\\\\]|\\\\.)*"`, and that regex cannot see a
        multi-line literal. On `\"\"\"`, it matches the first two quotes as an empty string and then
        opens a literal at the third that runs to the next quote **anywhere in the file** — which in
        `WindowSheets.swift` swallowed several hundred lines including every reference inside
        `sheetBody`. The rule then reported the file clean while the Mac build failed on
        `'renameCamera' is inaccessible due to 'private' protection level`, which is the exact error
        this check exists to prevent.

        It now shares `blank_comments_and_strings` with the argument-order scanner, which handles
        `//`, nested `/* */`, `\"\"\"` and `"` properly and preserves length — the same defect class,
        found twice in one day in two rules that each rolled their own parser.
        """
        return blank_comments_and_strings(path.read_text())

    def key_of(kind: str, name: str, rest: str) -> str:
        """A member's identity for shadowing purposes.

        Functions are keyed by name **and first argument label**, because overloads coexist: the
        third Mac build failed on `handle(serverRequest:)` precisely because the sibling's own
        `handle(_ command:)` made a name-only comparison call it "already declared next door".
        """
        if kind != "func":
            return name
        label = re.match(r"\s*\(\s*(\w+)", rest)
        return f"{name}({label.group(1) if label else ''}"

    def members(path: pathlib.Path) -> set[str]:
        """Keys the file declares as members of a type — the one binding that cannot coexist with
        the sibling's declaration of the same one. `case a, b, c` binds all three, and a nested
        type indents its members further, so the indent floor is four spaces, not exactly four."""
        names: set[str] = set()
        for raw in path.read_text().splitlines():
            m = member_decl.match(raw)
            if m:
                names.add(key_of(m.group(1) or "", m.group(2), raw[m.end(2):]))
            if re.match(r"^\s{4,}case\s", raw):
                names |= set(re.findall(r"(\w+)", raw.split("case", 1)[1].split(":")[0]))
        return names

    def shadows(body: str, name: str, at: int) -> bool:
        """Whether `name` at line `at` is bound by the enclosing member rather than by the type.

        A parameter or a local of the same name is the one thing a text scan genuinely cannot tell
        apart from a member reference, and both are common: `hairline(_ displayScale:)` uses its
        parameter, `let tracks = myTracks` its local. Rather than skipping the name everywhere —
        the mistake that cost a whole build — only the occurrences actually inside such a scope are
        discounted, by walking back to the enclosing type-level declaration.
        """
        lines = body.splitlines()
        head = None
        for i in range(min(at, len(lines)) - 1, -1, -1):
            if re.match(r"^    (?:@|\w)", lines[i]):
                head = i
                break
        if head is None:
            return False
        # The signature may wrap over several lines; take everything up to the opening brace.
        signature = []
        for i in range(head, min(at, len(lines))):
            signature.append(lines[i])
            if "{" in lines[i]:
                break
        joined = " ".join(signature)
        if re.search(r"[(,]\s*(?:\w+\s+)?" + re.escape(name) + r"\s*:", joined):
            return True
        scope = "\n".join(lines[head:at - 1])
        return bool(re.search(r"\b(?:let|var|for|inout)\s+" + re.escape(name) + r"\b", scope)
                    or re.search(r"\b(?:guard|if|case)\s+let\s+" + re.escape(name) + r"\b", scope))

    def cases_of(body: str, name: str) -> list[str]:
        """Case names of a nested enum, which are invisible wherever the enum itself is."""
        m = re.search(r"enum\s+" + re.escape(name) + r"\b[^\n{]*\{", body)
        if not m:
            return []
        depth, end = 0, len(body)
        for i in range(m.end() - 1, len(body)):
            depth += (body[i] == "{") - (body[i] == "}")
            if depth == 0:
                end = i
                break
        return re.findall(r"^\s*case\s+(\w+)", body[m.end():end], re.M)

    for _, families in groups.items():
        for _, files in families.items():
            if len(files) < 2:
                continue
            bodies = {p: stripped(p) for p in files}
            declared = {p: members(p) for p in files}
            for owner in files:
                own = bodies[owner]
                for n, raw in enumerate(owner.read_text().splitlines(), 1):
                    m = private_decl.match(raw)
                    if not m:
                        continue
                    access, kind, name = m.group(1), m.group(2), m.group(3)
                    for other in files:
                        if other is owner:
                            continue
                        # The one safe skip: the sibling declares this name as a member of its own,
                        # so the reference over there is to that and cannot be to this.
                        if key_of(kind, name, raw[m.end(3):]) in declared[other]:
                            continue
                        body = bodies[other]
                        if access.endswith("(set)"):
                            # Not just `x = 1`. A setter is equally required by `x.count += 1`,
                            # by `x.reset()` and by `x[i] = y` — `statistics.messagesDecoded += 1`
                            # is exactly the shape that reached the user as "setter is
                            # inaccessible" after a name-only assignment pattern found nothing.
                            escaped = re.escape(name)
                            head = r"^\s*(?:self\.)?" + escaped + r"\b"
                            patterns = [(name, head + r"[^\n=]*[-+*/&|^%]?=(?!=)"),
                                        (name, head + r"(?:\.\w+|\[[^\n]*\])*\.\w+\(")]
                            what = "assigned to"
                        else:
                            # `(` and `,` are deliberately **not** in the lookbehind: an argument
                            # position is an ordinary use, and excluding it is what hid
                            # `hairline(displayScale)`. A leading `.` still is, so `format.codec`
                            # does not count as a use of some other type's `codec` — except for a
                            # call, where `rollup.adopt(…)` is exactly how a sibling reaches a
                            # private method on a value of the type declared next door.
                            patterns = [(name, r"(?<![\w.])" + re.escape(name) + r"\b(?!\s*:)"),
                                        (name, r"(?:self|Self)\." + re.escape(name) + r"\b")]
                            if kind == "func":
                                patterns.append((name, r"\.\s*" + re.escape(name) + r"\s*\("))
                            if kind == "enum":
                                patterns += [(c, r"(?<![\w])\." + re.escape(c) + r"\b")
                                             for c in cases_of(own, name)]
                            what = "used"
                        where = None
                        for bound, pattern in patterns:
                            for found in re.finditer(pattern, body, re.M):
                                line = body.count("\n", 0, found.start()) + 1
                                if shadows(body, bound, line):
                                    continue
                                where = line
                                break
                            if where:
                                break
                        if where:
                            out.append((str(owner.relative_to(ROOT)), n, "split-access",
                                        f"{name!r} is {access} in {owner.name} but {what} in "
                                        f"{other.name}:{where} — Swift scopes {access} to one "
                                        f"file, so the other half of this type cannot see it"))
                            break

    # Shape 4: a private nested type in the signature of a non-private member of the same file.
    # Anchored at exactly four spaces of indent: a `let` eight spaces in is a local, and a local may
    # name a private type freely — it is only a *member* whose visibility has to be justified.
    top_member = re.compile(
        r"^    (?! )(?:@\w+(?:\([^)]*\))?\s+)*"
        + r"(?:(?:public|package|open|internal|private|fileprivate)(?:\(set\))?\s+)*"
        + MODIFIERS + r"(" + KIND + r")\s+(\w+)")
    for path in swift_files("Sources"):
        lines = path.read_text().splitlines()
        nested: dict[str, int] = {}
        for n, raw in enumerate(lines, 1):
            m = private_decl.match(raw)
            if m and m.group(2) in {"struct", "enum", "class", "actor", "typealias"}:
                nested[m.group(3)] = n
        if not nested:
            continue
        for raw in lines:
            m = top_member.match(raw)
            if not m or private_decl.match(raw):
                continue
            signature = re.sub(r'"(?:[^"\\]|\\.)*"', '""', raw[m.end(2):])
            for name, n in nested.items():
                if re.search(r"(?<![\w.])" + re.escape(name) + r"\b", signature):
                    out.append((str(path.relative_to(ROOT)), n, "split-access",
                                f"{name!r} is private but appears in the signature of "
                                f"{m.group(2)!r}, which is not — Swift rejects a member whose type "
                                f"is less visible than the member itself"))
                    break

    # Shape 5: a *top-level* private declaration used by another file of the same target.
    #
    # Everything above keys off the `Foo.swift` / `Foo+Bar.swift` convention, and not every split in
    # this tree followed it: `VToolbarView.swift`'s three controls moved to
    # `VToolbarSearchField.swift`, a name that shares no prefix with the file still calling them, so
    # the family grouping never compared the two and the Mac reported "cannot find
    # 'VToolbarLayoutSwitcher' in scope". Naming is not evidence of a relationship — the whole
    # target has to be the search space.
    top_private = re.compile(
        r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:private|fileprivate)\s+"
        + MODIFIERS + r"(struct|enum|class|actor|func|let|var|typealias|protocol)\s+(\w+)")
    anywhere = re.compile(
        r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
        r"(?:(?:public|package|open|internal|private|fileprivate)(?:\(set\))?\s+)*"
        + MODIFIERS + r"(?:" + KIND + r"|protocol|case)\s+(\w+)")

    by_target: dict[str, list[pathlib.Path]] = defaultdict(list)
    for path in swift_files("Sources"):
        by_target[path.relative_to(ROOT / "Sources").parts[0]].append(path)

    for _, files in sorted(by_target.items()):
        bodies = {p: stripped(p) for p in files}
        # Any declaration at any depth: a `static var previewCamera` on a type in the other file is
        # a different entity from a top-level `private let previewCamera` here, and the reference
        # over there resolves to its own.
        names = {p: {m.group(1) for m in map(anywhere.match, bodies[p].splitlines()) if m}
                 for p in files}
        for path in files:
            lines = path.read_text().splitlines()
            # `private extension String { … }` makes every member fileprivate without the word
            # `private` appearing on any of them, so the members are collected here rather than by
            # the pattern above. The extension runs to the first `}` in column zero.
            in_private_extension = False
            extension_members: list[tuple[str, int]] = []
            for n, raw in enumerate(lines, 1):
                if re.match(r"^(?:private|fileprivate)\s+extension\b", raw):
                    in_private_extension = True
                    continue
                if in_private_extension:
                    if raw.startswith("}"):
                        in_private_extension = False
                    elif (found := anywhere.match(raw)):
                        extension_members.append((found.group(1), n))

            candidates = [(m.group(2), n, False) for n, raw in enumerate(lines, 1)
                          if (m := top_private.match(raw))]
            candidates += [(name, n, True) for name, n in extension_members]
            for name, n, is_extension_member in candidates:
                # A member added by an extension is only ever reached through a value, so for those
                # the dot is required rather than forbidden — the opposite of a top-level type.
                pattern = (r"\.\s*" + re.escape(name) + r"\b" if is_extension_member
                           else r"(?<![\w.])" + re.escape(name) + r"\b")
                for other in files:
                    if other is path or name in names[other]:
                        continue
                    found = re.search(pattern, bodies[other])
                    if not found:
                        continue
                    line = bodies[other].count("\n", 0, found.start()) + 1
                    out.append((str(path.relative_to(ROOT)), n, "split-access",
                                f"top-level {name!r} is private in {path.name} but used in "
                                f"{other.name}:{line} — `private` at file scope means one file, "
                                f"whatever the two files are called"))
                    break
    return out


def check_undeclared_v_types() -> list[Violation]:
    """A `V`-prefixed type that is used but declared nowhere in the tree.

    `VLibraryScreen`'s three previews called `VLibrarySample.emptyState()` and
    `VLibrarySample.populatedState()` for weeks. The type had never been written — it arrived with a
    commit whose own message said it did not build — and nothing noticed, because a `#Preview` lives
    inside `#if DEBUG` and **the app is built `-c release`**. `Scripts/build-app.sh` compiles the
    release configuration, so every `#if DEBUG` block is stripped before the compiler sees it; the
    Linux CI cannot help either, since these files are macOS-only. Debug-only code in a macOS-only
    target is the one place in this repo where nothing is checked at all.

    The rule is narrow on purpose: it looks only at the `V`-prefixed UI convention, which is this
    project's own namespace, so a missing name is certainly a missing name rather than something
    from a framework. `VStack` and `VSplitView` are SwiftUI's and are the whole exception list.
    """
    # `V[A-Z][a-z]`, not `V[A-Z]`: the third character being lowercase is what separates this
    # project's `VTheme` and `VTimelineView` from Apple's screaming-case C symbols such as
    # `VTCreateCGImageFromCVPixelBuffer`, which are declared in a framework rather than here.
    swiftui = {"VStack", "VSplitView"}
    declared: set[str] = set()
    uses: dict[str, tuple[str, int]] = {}

    for directory in ("Sources", "Tests"):
        for path in swift_files(directory):
            for n, raw in enumerate(path.read_text().splitlines(), 1):
                if raw.lstrip().startswith("//"):
                    continue
                code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', raw)
                for name in re.findall(
                        r"\b(?:struct|enum|class|actor|protocol|typealias)\s+(V[A-Z][a-z]\w*)", code):
                    declared.add(name)
                # A use is a member access or a construction, not a mention in prose.
                for name in re.findall(r"(?<![\w.])(V[A-Z][a-z]\w*)\s*[.(]", code):
                    uses.setdefault(name, (str(path.relative_to(ROOT)), n))

    out: list[Violation] = []
    for name, (where, line) in sorted(uses.items()):
        if name in declared or name in swiftui:
            continue
        out.append((where, line, "undeclared-type",
                    f"{name!r} is used here but declared nowhere in Sources or Tests — if it only "
                    f"appears inside `#if DEBUG`, nothing compiles it: the app is built "
                    f"`-c release` and the Linux CI skips macOS-only files"))
    return out


def check_expect_key_path(path: pathlib.Path, lines: list[str]) -> list[Violation]:
    """A key path handed to a `rethrows` method as the *whole* of an `#expect(...)`.

    `#expect(options.allSatisfy(\\.isWellFormed))` does not compile. The macro decomposes a bare
    call into `__checkFunctionCall(_:calling:)` so it can print each argument when the assertion
    fails, and that passes the key path to `allSatisfy` as an *argument function* — which `rethrows`
    then treats as possibly throwing, so the expansion needs a `try` the macro never writes. The
    error is reported against the expansion rather than the source line, once per test target that
    happens to be compiling at the time, so the copies in the log name a file that is not the one to
    edit.

    ⚠️ Only a *bare* call is affected, and the difference is the whole rule. `#expect(Set(xs.map(
    \\.id)).count == xs.count)` decomposes as a comparison, leaves the `map` alone and compiles —
    eleven of those are in this tree, and a first version of this check that matched on the text
    `.map(\\.` alone reported every one of them. So the `#expect` argument is extracted by
    balancing parentheses and the call has to be the entire expression.
    """
    rethrowing = ("allSatisfy", "contains", "first", "firstIndex", "filter", "map", "compactMap",
                  "flatMap", "drop", "dropFirst", "dropLast", "prefix", "reduce", "sorted",
                  "min", "max", "partition", "forEach")
    whole_call = re.compile(r"^[\w.\[\]]+\.(" + "|".join(rethrowing)
                            + r")\(\s*\\\.\w+\s*\)$")

    def argument(text: str, opening: int) -> str | None:
        """The text between `#expect(` and its matching `)`, or None when it is not closed here."""
        depth = 0
        for i in range(opening, len(text)):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    return text[opening + 1:i]
        return None

    out: list[Violation] = []
    rel = str(path.relative_to(ROOT))
    for n, raw in enumerate(lines, 1):
        for m in re.finditer(r"#expect(?:\(|\s)", raw):
            opening = raw.find("(", m.start())
            if opening < 0:
                continue
            inner = argument(raw, opening)
            if inner is None:
                continue
            call = whole_call.match(inner.strip())
            if not call:
                continue
            out.append((rel, n, "expect-key-path",
                        f"#expect over a bare `.{call.group(1)}(\\.keyPath)` call does not "
                        f"compile: the macro hands the key path to a rethrows method as an "
                        f"argument function, and its expansion then needs a `try` it does not "
                        f"write. Use a closure — `{{ $0.someProperty }}` — or compare the result "
                        f"to something, which decomposes differently and is fine"))
    return out


def check_scaffold_tests() -> list[Violation]:
    """A `@Test` that records an issue *unconditionally*, and so fails by construction.

    `ZZDebugClock.swift` held one test whose entire body was `Issue.record("reason=… adv=…")` — a
    diagnostic someone left in to print the virtual clock's schedule while chasing a bug. It asserts
    nothing and always fails, so it was the single red mark in a run of 2 700 tests, and it survived
    in the tree for weeks because nothing had ever executed the suite. What it printed is asserted
    by `discoveryCoordinatorSequencesPhasesOnTheSpecTimetable`, which passes.

    ⚠️ The test is the *indentation*, not the presence of `Issue.record`. Recording inside a branch
    is this codebase's normal way to assert a pattern match —

        guard case .notSOAP = decode(datagram) else {
            Issue.record("a SADP ProbeMatch is not a SOAP envelope")
            return
        }

    — and a first version of this rule that fired on "records an issue and has no `#expect`"
    reported two of those. Only a call at the body's own indent level runs every time.
    """
    out: list[Violation] = []
    for path in swift_files("Tests"):
        lines = path.read_text().splitlines()
        for n, raw in enumerate(lines, 1):
            m = re.match(r"(\s*)@Test\b", raw)
            if not m:
                continue
            body_indent = len(m.group(1)) + 4
            depth, started = 0, False
            for line in lines[n - 1:]:
                depth += line.count("{") - line.count("}")
                if "{" in line:
                    started = True
                stripped = line.lstrip()
                if (started and stripped.startswith("Issue.record(")
                        and len(line) - len(stripped) == body_indent):
                    out.append((str(path.relative_to(ROOT)), n, "scaffold-test",
                                "this @Test records an issue unconditionally, so it fails every "
                                "run whatever the code does — it is a diagnostic someone left "
                                "behind. Delete it, or turn what it prints into an #expect"))
                    break
                if started and depth <= 0:
                    break
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

    `.stringsdict` is in the glob because it is the file class where an XML error is *least* visible:
    a malformed one does not fail the build at all, it simply stops resolving, and the app renders
    raw `%#@frames@` text at runtime. It was originally missed — the rule covered the two extensions
    whose breakage is loud and not the one whose breakage is silent.
    """
    import plistlib

    out: list[Violation] = []
    for directory in ("Resources", "Sources"):
        base = ROOT / directory
        if not base.exists():
            continue
        for path in sorted(list(base.rglob("*.plist"))
                           + list(base.rglob("*.entitlements"))
                           + list(base.rglob("*.stringsdict"))):
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


def check_bonjour_declarations() -> list[Violation]:
    """Every Bonjour service type the code browses must be declared in Info.plist.

    macOS enforces `NSBonjourServices` on `NWBrowser`, and it enforces it the worst possible way:
    a browse for an undeclared type does not fail, does not warn and does not log. It returns
    nothing, forever. On screen that is indistinguishable from a network with no cameras on it —
    the "no video, no error" shape this project exists to refuse, applied to discovery.

    Only that direction is checked. A declared type nobody browses costs nothing but a line in a
    plist, and the list is deliberately a superset: `_onvif._tcp` is declared against the day the
    browse list grows, which is a change in one file rather than two.
    """
    import plistlib

    plist = ROOT / "Resources/Info.plist"
    source = ROOT / "Sources/VigilDiscovery/Coordinator/DiscoveryCoordinator.swift"
    if not plist.exists() or not source.exists():
        return []

    try:
        declared = set(plistlib.loads(plist.read_bytes()).get("NSBonjourServices", []))
    except Exception:
        return []   # check_plists already reports a malformed plist; one complaint is enough.

    text = source.read_text()
    match = re.search(r"bonjourServiceTypes\s*(?::[^=]+)?=\s*\[([^\]]*)\]", text)
    if not match:
        return []

    rel = str(source.relative_to(ROOT))
    line = text[:match.start()].count("\n") + 1
    return [(rel, line, "bonjour",
             f'"{service}" is browsed but not in NSBonjourServices in Resources/Info.plist — '
             "macOS answers an undeclared browse with silence, not an error, so this reads on "
             "screen as a network with no cameras on it")
            for service in sorted(set(STRING_LITERAL.findall(match.group(1))) - declared)]


STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*"\s*;\s*$')

# `vigilUIString("…")` / `Self.localized("…")`, capturing everything up to the closing paren so a
# key assembled from adjacent literals with `+` is recovered whole.
LOOKUP_CALL = re.compile(r"(?:vigilUIString|(?:Self\.)?localized)\(\s*((?:[^()]|\([^()]*\))*?)\)",
                         re.S)

# A `Text` whose key is a bare literal and whose bundle is ours. Only this shape is checked: a key
# that arrives as a variable cannot be resolved by reading the file, and guessing would either miss
# it or invent a violation.
TEXT_KEY = re.compile(r'Text\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*bundle:\s*\.vigilUI\s*\)')

STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')


def parse_strings_table(path: pathlib.Path) -> set[str]:
    """The keys defined in a .strings file.

    ⚠️ Deliberately forgiving, and deliberately silent. A line this cannot parse is skipped rather
    than reported, because `Scripts/check-localizations.py` owns the *shape* of these files — it has
    a real character-level parser where this has a line regex, and it already checks malformed
    entries, duplicate keys, en/ru parity, format specifiers and plural categories. Two
    implementations of the same rule is one more than can be kept in agreement, and the weaker one
    would be the one to disagree.

    What this reads the table for is the one direction that script cannot check: it scans *every*
    literal in the source, which is the right over-approximation for finding orphaned keys and the
    wrong one for finding missing ones. Deciding which literals are keys is what `check_localization_
    tables` does, and it needs the key set to compare against.
    """
    # Block comments are the documentation style this repo uses in .strings files, and they run to
    # many lines.
    body = re.sub(r"/\*.*?\*/", "", path.read_text(), flags=re.S)
    return {match.group(1) for line in body.splitlines()
            if (match := STRINGS_ENTRY.match(line))}


def _segments_in_parens(text: str, open_index: int) -> list[str] | None:
    """The depth-1 comma-separated segments of the parenthesis starting at `open_index`.

    `_labels_in_parens` above answers what the labels *are*; this answers what was written against
    each of them, which is what a rule about literal values needs. `None` when the parenthesis does
    not close, same contract as its sibling.
    """
    depth, i, n = 0, open_index, len(text)
    out: list[str] = []
    start = open_index + 1
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            if c == "\\":
                i += 2
                continue
            if c == '"':
                in_string = False
        elif c == '"':
            in_string = True
        elif c in "([{":
            depth += 1
            if depth == 1:
                start = i + 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                out.append(text[start:i])
                return out
        elif c == "," and depth == 1:
            out.append(text[start:i])
            start = i + 1
        i += 1
    return None


# A parameter declaration, split far enough to see its type: attributes, external label, optional
# internal name, then everything up to a default value.
PARAM_WITH_TYPE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(\w+)(?:\s+(\w+))?\s*:\s*([^=]+)")

KEY_TYPE = re.compile(r"\bLocalizedStringKey\b")

# `identifier(` inside an argument — the marker of a nested call, whose literals are its own
# business and not keys of the parameter being checked.
NESTED_CALL = re.compile(r"\w\s*\(")


def strip_debug_only(text: str) -> str:
    """Blanks every `#if DEBUG` region, keeping the line count so numbers still point at the source.

    Previews are not the shipping interface. `VLibraryEmptyState(title: "No recordings yet.", …)` in
    a `#Preview` is a fixture written to make a canvas look right, and the screen it stands in for
    says "No recordings yet" without the full stop — a *different* key. Demanding a translation for
    the fixture would put a string in the tables that no user will ever read and ask a translator to
    render it.
    """
    out: list[str] = []
    conditionals: list[bool] = []   # one entry per open #if; True when it is a DEBUG block
    suppressing = 0
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("#if"):
            is_debug = re.search(r"#if\s+DEBUG\b", stripped) is not None
            conditionals.append(is_debug)
            if is_debug:
                suppressing += 1
            out.append("")
            continue
        if stripped.startswith("#endif"):
            if conditionals and conditionals.pop():
                suppressing -= 1
            out.append("")
            continue
        out.append("" if suppressing else line)
    return "\n".join(out)


def localized_key_parameters() -> dict[str, tuple[set[str], set[int]]]:
    """Which initialiser parameters of our own types are `LocalizedStringKey`.

    Returned per type as `(labels, positions)`: labels a caller writes by name, and the indices of
    parameters declared `_ title:`, which a caller writes positionally. Both are needed — `VButton`
    takes its title as the unlabelled first argument and `VLibraryEmptyState` takes three by name.
    """
    out: dict[str, tuple[set[str], set[int]]] = {}
    for path in swift_files("Sources"):
        text = path.read_text()
        lines = text.split("\n")
        stack: list[tuple[str, int]] = []
        depth = 0
        for n, raw in enumerate(lines):
            code = strip_comments_and_strings(raw)
            decl = TYPE_DECL.match(raw)
            if decl and "{" in code:
                stack.append((decl.group(1), depth))
            if stack and INIT_DECL.match(raw):
                offset = sum(len(l) + 1 for l in lines[:n]) + raw.index("(")
                segments = _segments_in_parens(text, offset)
                if segments is not None:
                    labels, positions = out.setdefault(stack[-1][0], (set(), set()))
                    for index, segment in enumerate(segments):
                        match = PARAM_WITH_TYPE.match(segment)
                        if not match or not KEY_TYPE.search(match.group(3)):
                            continue
                        if match.group(1) == "_":
                            positions.add(index)
                        else:
                            labels.add(match.group(1))
            depth += code.count("{") - code.count("}")
            while stack and depth <= stack[-1][1]:
                stack.pop()
    return {name: value for name, value in out.items() if value[0] or value[1]}


def _keys_written_at_call_sites(text: str,
                                parameters: dict[str, tuple[set[str], set[int]]]) -> list[str]:
    """Every string literal written against a `LocalizedStringKey` parameter of one of our types."""
    found: list[str] = []
    for match in CALL_START.finditer(text):
        entry = parameters.get(match.group(1))
        if entry is None:
            continue
        labels, positions = entry
        segments = _segments_in_parens(text, match.end() - 1)
        if segments is None:
            continue
        for index, segment in enumerate(segments):
            label = ARG_LABEL.match(segment)
            value = segment[label.end():] if label else segment
            if label:
                if label.group(1) not in labels:
                    continue
            elif index not in positions:
                continue
            literals = STRING_LITERAL.findall(value)
            # Accept a bare literal and a ternary between two of them — `isScanning ? "Stop" :
            # "Scan Again"` is two keys, and both must exist. Reject anything with a call in it: a
            # literal inside `formatter("x")` is that call's argument, not a key.
            remainder = STRING_LITERAL.sub("", value)
            if literals and not NESTED_CALL.search(remainder):
                found += literals
    return found


# A declaration that *produces* a key: `var title: LocalizedStringKey {` or
# `func label(for: X) -> LocalizedStringKey {`. Every bare literal in its body is a key.
KEY_PRODUCER = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:package |public |private |internal |fileprivate |nonisolated |static |var |let |func )*"
    r"[\w.]+\s*(?:\([^)]*\))?\s*(?::|->)\s*LocalizedStringKey\??\s*\{",
    re.M)   # ⚠️ Without this `^` anchors to the start of the *file* and the rule matches nothing.


def _keys_produced_by_declarations(text: str) -> list[str]:
    """Literals inside declarations whose type is `LocalizedStringKey`.

    The third shape, and the one that hid `"Cameras appear here as they answer."`: the sheet passes
    `message: emptyMessage` — a computed property, not a literal — so nothing at the call site names
    the key. A `switch` returning one key per case is the same shape and by far the commonest.
    """
    found: list[str] = []
    for match in KEY_PRODUCER.finditer(text):
        depth, i, n = 0, match.end() - 1, len(text)
        start = i
        while i < n:
            c = text[i]
            if c == '"':
                # Skip the literal wholesale so a brace inside a string cannot unbalance the body.
                i += 1
                while i < n and text[i] != '"':
                    i += 2 if text[i] == "\\" else 1
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[start:i]
        # The empty key is `return ""` — the calendar's blank cells, which deliberately have no
        # label. There is nothing to translate and no entry to demand.
        found += [key for key in STRING_LITERAL.findall(body) if key and "\\(" not in key]
    return found


def check_localization_tables() -> list[Violation]:
    """Every key the code looks up must exist in a .strings table.

    ⚠️ ONE DIRECTION ONLY, AND ON PURPOSE. `Scripts/check-localizations.py` checks the other —
    every key in a table resolves to a literal in the source — plus malformed entries, duplicate
    keys, en/ru parity, format specifiers and plural categories. It is the authority on all of
    those; this rule does not repeat any of them, because two implementations of one rule is one
    more than can be kept in agreement.

    The split is not arbitrary. That script scans *every* string literal in the source, which is
    the correct over-approximation for finding orphaned keys — a key is fine if any literal
    anywhere matches it — and exactly the wrong one for finding missing keys, since most literals
    in a Swift file are not keys at all. Answering "is this literal a key?" is the work below, and
    it is why this lives here rather than there.

    The failure it catches is invisible to everything else: `LocalizedStringKey` falls back to the
    key itself, which in this module *is* the English text. So a missing key is not a compile
    error, not a test failure, and renders perfectly for anyone reading in English. It is a line of
    English in the middle of a Russian window, and nothing but this reports it. The discovery sheet
    shipped eleven; the rule then found nine older ones.

    A key is *used* in three shapes, and all three are read, because the rule was worth only as much
    as its narrowest one. The first version knew only shape 1 and reported the tree clean while
    `VButton("Scan Again", …)` was missing from both tables:

    1. `Text("…", bundle: .vigilUI)` — the explicit spelling.
    2. A literal written against a parameter our own types declare `LocalizedStringKey`, by label
       (`VLibraryEmptyState(message: "…")`) or by position (`VButton("…", style:)`). The declared
       types are scanned to find which parameters those are, so the rule follows the code rather
       than a hand-kept list. A ternary counts as two keys; a literal inside a nested call counts as
       none, because it belongs to that call.
    3. A declaration that *produces* one — `var title: LocalizedStringKey { … }`, usually a `switch`
       returning a key per case. This is where the sheet's empty-state message hid: the call site
       passes `message: emptyMessage` and names no key at all.

    Plus `vigilUIString("…")`, whose key may be assembled from adjacent literals with `+`, and is
    recovered whole.

    Three things are deliberately out of reach. A key held in a variable cannot be resolved by
    reading source. `#if DEBUG` is skipped, because a `#Preview` fixture is not the shipping
    interface and translating it would put strings in the tables that no user reads. And an
    **interpolated** key — `Text("Looking up \\(host)…")` — is not its own text: SwiftUI rewrites it
    into a key carrying format specifiers, and which specifier depends on the interpolated value's
    *type*, `%@` for a String and `%lld` for an Int. Deciding that needs the type checker, so a rule
    at this level would have to guess, and a lint rule that guesses either misses real breakage or
    invents violations for correct code. Both are worse than an honestly narrower rule.

    What that leaves: roughly three quarters of the table is checked, and the quarter that is not is
    almost entirely the interpolated keys.
    """
    localizations = ROOT / "Sources/VigilUI/Localizations"
    if not localizations.exists():
        return []

    out: list[Violation] = []
    # Every language, not just en: a key present in *any* table is defined, and reporting a key as
    # undefined because only the translation has it would be a lie in the other direction.
    # `check-localizations.py` is what insists the tables agree with each other.
    base: set[str] = set()
    for table in sorted(localizations.glob("*.lproj/Localizable.strings")):
        base |= parse_strings_table(table)
    for table in sorted(localizations.glob("*.lproj/Localizable.stringsdict")):
        with table.open("rb") as handle:
            base |= set(plistlib.load(handle))
    if not base:
        return out
    base_rel = "Sources/VigilUI/Localizations/en.lproj/Localizable.strings"

    # Keys the code asks for, in all three spellings, across the UI module and the app target.
    parameters = localized_key_parameters()
    for path in swift_files("Sources"):
        rel = str(path.relative_to(ROOT))
        text = strip_debug_only(path.read_text())
        wanted: list[str] = _keys_written_at_call_sites(text, parameters)
        wanted += _keys_produced_by_declarations(text)
        for call in LOOKUP_CALL.finditer(text):
            argument = call.group(1)
            pieces = STRING_LITERAL.findall(argument)
            # Only when the argument is *entirely* literals joined by `+`. Anything else — an
            # interpolation, a variable, a format call — is not a key this rule can resolve.
            if pieces and not STRING_LITERAL.sub("", argument).strip(" +\n\t"):
                wanted.append("".join(pieces))
        wanted += TEXT_KEY.findall(text)

        for key in wanted:
            # See the docstring: an interpolated key is not its own text, and resolving it needs a
            # type checker. Skipped rather than guessed at.
            if "\\(" in key or key in base:
                continue
            line = next((n for n, raw in enumerate(text.splitlines(), 1)
                         if key.split("\\n")[0][:40] in raw), 1)
            out.append((rel, line, "l10n",
                        f'"{key}" is looked up but is in no .strings table — add it to {base_rel} '
                        "and to every translation"))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--summary", action="store_true", help="print counts only")
    args = parser.parse_args()

    violations: list[Violation] = []

    # Built once and shared: the scan reads every source file, and doing it per file would make the
    # whole lint quadratic in the size of the tree.
    initialisers = declared_initialiser_labels()

    for path in swift_files("Sources"):
        text = path.read_text()
        lines = text.splitlines()
        violations += check_imports(path, lines)
        violations += check_macos_guard(path, text)
        violations += check_banned(path, lines)
        violations += check_line_length(path, lines)
        violations += check_file_length(path, lines)
        violations += check_trailing_whitespace(path, lines)
        violations += check_file_header(path, lines)
        violations += check_static_stored_in_generic(path, lines)
        violations += check_environment_key_isolation(path, lines)
        violations += check_theme_isolation(path, lines)
        violations += check_argument_order(path, text, initialisers)

    for path in swift_files("Tests"):
        lines = path.read_text().splitlines()
        violations += check_line_length(path, lines)
        violations += check_file_length(path, lines)
        violations += check_expect_key_path(path, lines)
        violations += check_trailing_whitespace(path, lines)
        violations += check_static_stored_in_generic(path, lines)
        violations += check_environment_key_isolation(path, lines)
        violations += check_theme_isolation(path, lines)

    violations += check_duplicate_test_names()
    violations += check_mutating_in_expect()
    violations += check_split_file_access()
    violations += check_undeclared_v_types()
    violations += check_scaffold_tests()
    violations += check_plists()
    violations += check_localization_tables()
    violations += check_bonjour_declarations()

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
