#!/usr/bin/env python3
"""Validate the four localisation files the way a broken build would.

Checks, in order of how expensively they fail on a real Mac:
  1. every .stringsdict is a loadable plist (silent failure otherwise);
  2. every .strings line is `"key" = "value";` with balanced escaped quotes;
  3. every value's format specifiers are a legal rearrangement of its key's — same count,
     same type at each position, positional-or-sequential but never mixed;
  4. no key appears in both the .strings and the .stringsdict of one locale;
  5. en and ru cover exactly the same key set;
  6. every key resolves to a real LocalizedStringKey literal in Sources/VigilUI;
  7. every plural entry has the categories its language needs and a value type that agrees
     with the specifier in the key.
"""
import plistlib, pathlib, re, sys

# Repo-relative, so this runs from any clone. Was hard-coded to one absolute path when it
# lived in a scratch directory.
ROOT = pathlib.Path(__file__).resolve().parent.parent
BASE = ROOT / "Sources/VigilUI/Localizations"
SRC = ROOT / "Sources/VigilUI"
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
            buf.append(text[i + 1])
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
            "stamp": "%@", "track.name": "%@", "primaryName": "%@"}


def join_multiline(lines):
    indents = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    base = min(indents) if indents else 0
    out = []
    for l in lines:
        body = l[base:] if len(l) > base else l.lstrip()
        out.append(body[:-1] if body.endswith("\\") else body + "\n")
    return "".join(out).rstrip("\n")


for path in sorted(SRC.rglob("*.swift")):
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
source_keys = {re.sub(r"\\\((.*?)\)", lambda m: SPEC_MAP.get(m.group(1), "%?"), k)
               for k in source_keys}

# --- run --------------------------------------------------------------------------------
tables = {}
for lang in ("en", "ru"):
    s_path = BASE / f"{lang}.lproj" / "Localizable.strings"
    d_path = BASE / f"{lang}.lproj" / "Localizable.stringsdict"
    strings = parse_strings(s_path)
    for key, value in strings.items():
        check_value_specs(f"{lang}/strings", key, value)
    sdict = check_stringsdict(d_path, lang)
    both = set(strings) & set(sdict)
    if both:
        problems.append(f"{lang}: {len(both)} key(s) in BOTH tables: {sorted(both)[:2]}")
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
}
for key in sorted(en_keys):
    if key not in source_keys and key not in PENDING_OK:
        problems.append(f"key not found in Sources/VigilUI: {key!r}")

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
