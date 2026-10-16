#!/usr/bin/env python3
"""Check Localization/*.lproj against the String(localized:) keys in Sources.

  Scripts/check_localizations.py

- Every literal key used in the code must be translated in each language's
  Localizable.strings (English is the development language: en.lproj may
  leave keys out, the code's text is used as is).
- Keys with interpolation (counts) must be in each Localizable.stringsdict,
  where the plural rules of every language live.
- Translations must keep the key's format specifiers (%@, %d, %ld, %lld).
Exits non-zero on any problem.
"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOC = os.path.join(ROOT, "Localization")
CALL = re.compile(r'String\(localized: "((?:[^"\\]|\\.)*)"')
SPEC = re.compile(r"%(?:#@\w+@|l{0,2}[d@])")


def swift_unescape(s):
    return s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")


def plist(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"invalid plist: {path}\n{out.stderr}")
    return json.loads(out.stdout)


def specs(s):
    return sorted(m for m in SPEC.findall(s) if not m.startswith("%#@"))


literal, interpolated = set(), set()
for path in glob.glob(os.path.join(ROOT, "Sources", "**", "*.swift"), recursive=True):
    for raw in CALL.findall(open(path, encoding="utf-8").read()):
        if "\\(" in raw:
            # Compare shape only: each interpolation becomes a placeholder.
            interpolated.add(re.sub(r"\\\([^)]*\)+", "%X", swift_unescape(raw)))
        else:
            literal.add(swift_unescape(raw))

problems = []
langs = sorted(os.path.basename(d)[:-6] for d in glob.glob(os.path.join(LOC, "*.lproj")))
for lang in langs:
    d = os.path.join(LOC, f"{lang}.lproj")
    strings = plist(os.path.join(d, "Localizable.strings"))
    if lang != "en":
        for key in sorted(literal - strings.keys()):
            problems.append(f"{lang}: missing {key!r}")
    for key in sorted(strings.keys() - literal):
        problems.append(f"{lang}: unused {key!r}")
    for key, value in strings.items():
        if specs(key) != specs(value):
            problems.append(f"{lang}: specifiers differ in {key!r} -> {value!r}")

    sd_path = os.path.join(d, "Localizable.stringsdict")
    plurals = plist(sd_path) if os.path.exists(sd_path) else {}
    shapes = {re.sub(r"%l{0,2}[d@]", "%X", k): k for k in plurals}
    for shape in sorted(interpolated - shapes.keys()):
        problems.append(f"{lang}: missing plural entry for {shape!r}")
    for shape, key in shapes.items():
        if shape not in interpolated:
            problems.append(f"{lang}: unused plural entry {key!r}")
        rule = plurals[key]
        if "other" not in rule.get("n", {}):
            problems.append(f"{lang}: plural {key!r} has no 'other' form")
        for form, text in rule.get("n", {}).items():
            if form.startswith("NSString"):
                continue
            if "%lld" not in text:
                problems.append(f"{lang}: plural {key!r}/{form} lost its %lld")

for p in problems:
    print(p)
print(f"{len(langs)} languages, {len(literal)} keys, {len(interpolated)} plural keys: "
      + ("FAIL" if problems else "OK"))
sys.exit(1 if problems else 0)
