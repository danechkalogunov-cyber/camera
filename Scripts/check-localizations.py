#!/usr/bin/env python3
"""Validate the four localisation files the way a broken build would.

Checks, in order of how expensively they fail on a real Mac:
  1. every .stringsdict is a loadable plist (silent failure otherwise);
  2. every .strings line is `"key" = "value";` with balanced escaped quotes;
  3. every value's format specifiers are a legal rearrangement of its key's — same count,
     same type at each position, positional-or-sequential but never mixed;
  4. no key appears in both the .strings and the .stringsdict of one locale;
  5. en and ru cover exactly the same key set;
  6. every key resolves to a real literal in Sources/VigilUI or Sources/Vigil — the app
     target speaks these keys too, through vigilUIString(_:);
  7. localisation keys contain format specifiers, never Swift interpolation syntax;
  8. every integer-bearing phrase is either a plural rule or an explicitly reviewed
     non-plural phrase;
  9. every plural entry has the categories its language needs and a value type that agrees
     with the specifier in the key.
"""
import plistlib, pathlib, re, sys

# Repo-relative, so this runs from any clone. Was hard-coded to one absolute path when it
# lived in a scratch directory.
ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "Sources/VigilUI/Localizations"
# Both modules, because a VigilUI key is not only spoken from VigilUI. `vigilUIString(_:)` looks up
# this table from the app target — the command palette needs a `String` rather than a
# `LocalizedStringKey` so its ranker can score characters, and `DiscoveryScanModel` *computes* the
# scan's phase line and hands it down as a value. Scanning only VigilUI reported thirteen live keys
# as orphans, which is the failure mode this check is supposed to prevent, pointing the wrong way.
SRC_ROOTS = [ROOT / "Sources/VigilUI", ROOT / "Sources/Vigil"]
problems = []
notes = []

SPEC_RE = re.compile(r"%(?:(\d+)\$)?(@|lld|d|lf|f|#@(\w+)@)")


def specs(text):
    """[(index or None, type, variable or None)] in order of appearance."""
    return [(int(m.group(1)) if m.group(1) else None, m.group(2), m.group(3))
            for m in SPEC_RE.finditer(text)]


def parse_strings(path):
    """A real parser, not a line regex: values may contain '=' , ';' and escaped quotes."""
    text = path.read_text(encoding="utf-8")
    out, i, n = {}, 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                problems.append(f"{path.name}: unterminated /* comment at offset {i}")
                return out
            i = end + 2
            continue
        if text.startswith("//", i):
            i = text.find("\n", i) + 1 or n
            continue
        if c != '"':
            problems.append(f"{path.name}: expected a quoted key at offset {i}, found {c!r}")
            return out
        key, i = read_quoted(text, i, path)
        while i < n and text[i] in " \t":
            i += 1
        if i >= n or text[i] != "=":
            problems.append(f"{path.name}: no '=' after key {key!r}")
            return out
        i += 1
        while i < n and text[i] in " \t":
            i += 1
        if i >= n or text[i] != '"':
            problems.append(f"{path.name}: no quoted value for key {key!r}")
            return out
        value, i = read_quoted(text, i, path)
        while i < n and text[i] in " \t":
            i += 1
        if i >= n or text[i] != ";":
            problems.append(f"{path.name}: missing ';' after key {key!r}")
            return out
        i += 1
        if key in out:
            problems.append(f"{path.name}: duplicate key {key!r}")
        out[key] = value
    return out


def read_quoted(text, i, path):
    assert text[i] == '"'
    i += 1
    buf = []
    while i < len(text):
        c = text[i]
        if c == "\\":
            # .strings only needs quote/backslash decoding for this validator. Preserve unknown
            # escapes so a mistaken Swift `\\(value)` key remains detectable below.
            escaped = text[i + 1]
            buf.append(escaped if escaped in '"\\' else "\\" + escaped)
            i += 2
            continue
        if c == '"':
            return "".join(buf), i + 1
        if c == "\n":
            problems.append(f"{path.name}: newline inside a literal near {''.join(buf)[:40]!r}")
            return "".join(buf), i
        buf.append(c)
        i += 1
    problems.append(f"{path.name}: unterminated string literal")
    return "".join(buf), i


def check_value_specs(where, key, value):
    ks, vs = specs(key), specs(value)
    if not ks and not vs:
        return
    if len(vs) != len(ks):
        problems.append(f"{where}: key has {len(ks)} specifier(s) {[k[1] for k in ks]} but the "
                        f"value has {len(vs)} {[v[1] for v in vs]} — key {key[:60]!r}")
        return
    positional = [v for v in vs if v[0] is not None]
    if positional and len(positional) != len(vs):
        problems.append(f"{where}: value mixes positional and sequential specifiers, which "
                        f"CFString cannot format — key {key[:60]!r}")
        return
    if positional:
        for index, kind, _ in vs:
            if not 1 <= index <= len(ks):
                problems.append(f"{where}: value references argument {index} but the key has "
                                f"only {len(ks)} — key {key[:60]!r}")
                continue
            if ks[index - 1][1] != kind:
                problems.append(f"{where}: value reads argument {index} as %{kind} but the key "
                                f"declares %{ks[index - 1][1]} — key {key[:60]!r}")
        if sorted(v[0] for v in vs) != list(range(1, len(ks) + 1)):
            problems.append(f"{where}: positional arguments are not exactly 1…{len(ks)} — "
                            f"key {key[:60]!r}")
    else:
        if [v[1] for v in vs] != [k[1] for k in ks]:
            problems.append(f"{where}: sequential specifiers {[v[1] for v in vs]} do not match "
                            f"the key's {[k[1] for k in ks]} — key {key[:60]!r}")


CATEGORIES = {"ru": {"one", "few", "many", "other"}, "en": {"one", "other"}}

# Integer-bearing UI phrases which deliberately do not inflect. Keeping this list explicit makes
# the plural audit fail closed: a new phrase containing an integer must either be moved to the
# stringsdict or receive a reviewed explanation here.
NON_PLURAL_INTEGER_KEYS = {
    # Snapshot sets (F-CAP-02). Both counts are written *after* the noun — "Cameras captured: 14 of
    # 16", "Снято камер: 14 из 16" — which is the construction both languages use precisely so the
    # noun does not have to agree with the number. Identical at 1, at 4 and at 16.
    "Cameras captured: %lld of %lld",
    "Stopped — cameras captured: %lld",
    # Network endpoint numbers and the fixed protocol name do not inflect.
    "Vigil reached %@ on port %lld, but RTSP port %lld refused the connection.",
    # Abbreviated SI unit and parenthesised attempt metadata are intentionally noun-free.
    "Reconnecting in %lld s (attempt %lld).",
    # Timeline hour labels: the text after the colon describes the interval, not the number.
    "%lld: footage",
    "%lld: nothing recorded",
    "%lld: unknown",
    # CSV import and configuration export (UX.md §8.5). Every number here is either a row position
    # — an address in a file, which inflects in no language — or a count written *after* its noun,
    # which is the construction both English and Russian use precisely to avoid agreeing with it:
    # "Exported cameras: 1" and "Экспортировано камер: 1" are as correct as they are at 18.
    # Phrased that way on purpose rather than sent to the stringsdict, because a two-count sentence
    # needs two plural variables and reads worse in both languages than the colon form.
    "Import finished — added %lld, already here %lld",
    "Exported cameras: %lld",
    "row %lld has the wrong number of columns",
    "row %lld, column %@ is not a number",
    "row %lld, column %@ is not yes or no",
}


def check_stringsdict(path, lang):
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception as error:
        problems.append(f"{path.name}: not a loadable plist: {error}")
        return {}
    for key, entry in data.items():
        where = f"{lang}/stringsdict[{key[:40]}…]"
        fmt = entry.get("NSStringLocalizedFormatKey")
        if not isinstance(fmt, str):
            problems.append(f"{where}: no NSStringLocalizedFormatKey")
            continue
        variables = [k for k in entry if k != "NSStringLocalizedFormatKey"]
        referenced = {v for _, kind, v in specs(fmt) if v}
        for name in variables:
            if name not in referenced:
                problems.append(f"{where}: variable {name!r} is declared but never referenced "
                                f"as %#@{name}@ in the format")
        for name in referenced:
            if name not in variables:
                problems.append(f"{where}: format references %#@{name}@ with no such variable")
        # The composite format the runtime ends up with: substitute each variable's `other`.
        composite = fmt
        for name in variables:
            rule = entry[name]
            if rule.get("NSStringFormatSpecTypeKey") != "NSStringPluralRuleType":
                problems.append(f"{where}: {name} is not NSStringPluralRuleType")
            value_type = rule.get("NSStringFormatValueTypeKey")
            missing = CATEGORIES[lang] - set(rule)
            if missing:
                problems.append(f"{where}: {name} is missing {sorted(missing)}")
            for category in CATEGORIES[lang]:
                form = rule.get(category)
                if form is None:
                    continue
                for _, kind, _ in specs(form):
                    if kind != value_type:
                        problems.append(f"{where}: {name}/{category} uses %{kind} but "
                                        f"NSStringFormatValueTypeKey is {value_type!r}")
            composite = composite.replace(f"%#@{name}@", rule.get("other", ""))
            composite = re.sub(r"%(\d+)\$#@" + re.escape(name) + r"@",
                               lambda m: rule.get("other", ""), composite)
        check_value_specs(where, key, composite)
    return data


# --- source-derived key set --------------------------------------------------------------
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import importlib.util
spec = importlib.util.spec_from_file_location("gen", pathlib.Path(__file__).parent / "gen.py")

source_keys = set()
SPEC_MAP = {"host": "%@", "minutes": "%lld", "httpPort": "%lld", "rtspPort": "%lld",
            "codec": "%@", "camera.name": "%@", "value": "%@", "frames": "%lld",
            "shown": "%@", "expected": "%@", "seconds": "%lld", "detail.attempt": "%lld",
            "stamp": "%@", "track.name": "%@", "primaryName": "%@", "day": "%lld",
            "cluster.count": "%lld"}


def join_multiline(lines):
    indents = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    base = min(indents) if indents else 0
    out = []
    for l in lines:
        body = l[base:] if len(l) > base else l.lstrip()
        out.append(body[:-1] if body.endswith("\\") else body + "\n")
    return "".join(out).rstrip("\n")


for path in sorted(q for root in SRC_ROOTS for q in root.rglob("*.swift")):
    lines = path.read_text().split("\n")
    for n, line in enumerate(lines):
        if '"""' in line:
            body, j = [], n + 1
            while j < len(lines) and '"""' not in lines[j]:
                body.append(lines[j])
                j += 1
            source_keys.add(join_multiline(body))
            continue
        for m in re.finditer(r'"((?:[^"\\]|\\.)*)"', line):
            source_keys.add(m.group(1))
    # `+`-joined literal runs, which are one key and not several. A LocalizedStringKey may never be
    # built this way — it is looked up whole — but `vigilUIString(_:)` takes a String, where Swift
    # folds adjacent literals at compile time. That is how a key longer than the 110-column limit
    # gets written at all, and reading each half separately reports the real key as an orphan.
    for m in re.finditer(r'"(?:[^"\\]|\\.)*"(?:\s*\+\s*"(?:[^"\\]|\\.)*")+',
                         path.read_text(), re.S):
        source_keys.add("".join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(0))))
source_keys = {re.sub(r"\\\((.*?)\)", lambda m: SPEC_MAP.get(m.group(1), "%?"), k)
               for k in source_keys}

# --- run --------------------------------------------------------------------------------
tables = {}
for lang in ("en", "ru"):
    s_path = BASE / f"{lang}.lproj" / "Localizable.strings"
    d_path = BASE / f"{lang}.lproj" / "Localizable.stringsdict"
    strings = parse_strings(s_path)
    for key in strings:
        if "\\(" in key:
            problems.append(f"{lang}/strings: Swift interpolation syntax leaked into key {key!r}")
        if "%?" in key:
            problems.append(f"{lang}/strings: unresolved interpolation in key {key!r}")
    for key, value in strings.items():
        check_value_specs(f"{lang}/strings", key, value)
    sdict = check_stringsdict(d_path, lang)
    for key in sdict:
        if "\\(" in key:
            problems.append(f"{lang}/stringsdict: Swift interpolation syntax leaked into key "
                            f"{key!r}")
        if "%?" in key:
            problems.append(f"{lang}/stringsdict: unresolved interpolation in key {key!r}")
    both = set(strings) & set(sdict)
    if both:
        problems.append(f"{lang}: {len(both)} key(s) in BOTH tables: {sorted(both)[:2]}")
    integer_strings = {key for key in strings if any(kind in {"d", "lld"}
                                                       for _, kind, _ in specs(key))}
    unexpected_integer = integer_strings - NON_PLURAL_INTEGER_KEYS
    stale_exemptions = NON_PLURAL_INTEGER_KEYS - integer_strings
    if unexpected_integer:
        problems.append(f"{lang}: integer-bearing phrase(s) bypass stringsdict without a reviewed "
                        f"exemption: {sorted(unexpected_integer)}")
    if stale_exemptions:
        problems.append(f"{lang}: stale non-plural integer exemption(s): {sorted(stale_exemptions)}")
    tables[lang] = (strings, sdict)

en_keys = set(tables["en"][0]) | set(tables["en"][1])
ru_keys = set(tables["ru"][0]) | set(tables["ru"][1])
if en_keys != ru_keys:
    problems.append(f"en-only keys: {sorted(en_keys - ru_keys)}")
    problems.append(f"ru-only keys: {sorted(ru_keys - en_keys)}")

# Keys the app target owns. `source_keys` only scans `Sources/VigilUI`, so a string the window
# raises — a toast naming the outcome of an ISAPI write, say — has no literal in this module and
# would otherwise be reported as unused. They are still required to exist in both languages.
PENDING_OK = {
    "Waiting before trying again",
    "Vigil stopped signing in to %@ so the camera's account cannot be locked out. "
    "It will try again in about %lld minutes. Nothing is wrong with the camera.",
    "Picture settings reset",
    "The camera accepted the reset and reported the same settings — its picture was already "
    "at the defaults.",
    "The camera refused to reset its picture settings: %@",
    "Connect a camera first",
    "This camera has no reset command, so Vigil wrote the standard picture values instead.",
    "Camera Settings",
    "Save",
    "Cancel",
    "Name",
    "Group",
    "None",
    "Rename Group",
    "Create",
    "Rename",
    "Bookmark This Moment",
    "Edit Bookmark",
    "Add",
    "Title (optional)",
    "Rename…",
    "Add to Group",
    "Bookmark This Moment…",
    "Copy Address",
    "Copy Serial Number",
    "Open in Browser",
    "Camera Settings…",
    "New Group…",
    "Delete Group",
    "Snapshot saved",
    "The snapshot could not be taken: %@",
    "Diagnostics copied",
    "Nothing was recorded at that moment",
    "Show overlay on video",
    "The camera's name, the connection chip and the statistics readout. Warnings about a stream that is failing are always shown.",
    "Close",
    "Previous day",
    "Next day",
    "Go to date",
    "The camera did not list any recordings it can play back, so there is no timeline to scrub.",
    "The camera would not list its recordings: %@",
    "Switching to the sub-stream — the picture will reconnect",
    "Switching to the main stream — the picture will reconnect",
    "This day holds more recordings than Vigil could read. The timeline is complete up to "
    "%@ and unknown after it.",
}
for key in sorted(en_keys):
    if key not in source_keys and key not in PENDING_OK:
        problems.append(f"key not found in Sources/VigilUI or Sources/Vigil: {key!r}")

# Untranslated identical pairs are legitimate for values, not prose — report, do not fail.
for key, value in tables["ru"][0].items():
    if key == value and not re.fullmatch(r"[\d.:]+|admin", key):
        notes.append(f"ru value identical to the English key: {key!r}")

print(f"source literals seen: {len(source_keys)}")
print(f"en keys: {len(en_keys)}   ru keys: {len(ru_keys)}   "
      f"(strings {len(tables['en'][0])} + stringsdict {len(tables['en'][1])})")
for note in notes:
    print(f"note: {note}")
if problems:
    print()
    for problem in problems:
        print(f"FAIL {problem}")
    sys.exit(1)
print("validate: clean")
