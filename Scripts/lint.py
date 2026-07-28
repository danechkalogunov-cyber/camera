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
        """The file with comments gone and string *literals* blanked — but interpolations kept.

        A literal with an interpolation in it contains real code: `"\(Self.premigrationPrefix)v"`
        is a use of `premigrationPrefix`, and blanking the whole literal is what hid it. Those are
        left intact — a stray word inside one can only ever cost a false alarm, and the balance
        this rule needs is the other way round.
        """
        body = "\n".join("" if l.lstrip().startswith("//") else l
                         for l in path.read_text().splitlines())
        return re.sub(r'"(?:[^"\\]|\\.)*"',
                      lambda m: m.group(0) if r"\(" in m.group(0) else '""',
                      body)

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
        violations += check_trailing_whitespace(path, lines)
        violations += check_file_header(path, lines)
        violations += check_static_stored_in_generic(path, lines)
        violations += check_environment_key_isolation(path, lines)
        violations += check_theme_isolation(path, lines)
        violations += check_argument_order(path, text, initialisers)

    for path in swift_files("Tests"):
        lines = path.read_text().splitlines()
        violations += check_line_length(path, lines)
        violations += check_trailing_whitespace(path, lines)
        violations += check_static_stored_in_generic(path, lines)
        violations += check_environment_key_isolation(path, lines)
        violations += check_theme_isolation(path, lines)

    violations += check_duplicate_test_names()
    violations += check_split_file_access()
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
