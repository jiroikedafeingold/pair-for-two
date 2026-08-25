#!/usr/bin/env python3
"""Merge translations into a String Catalog, one locale at a time.

Reads {"locale": "xx", "strings": {"<en key>": "<translation>", ...}} from stdin and writes the
values into `Pair for two/Localizable.xcstrings` (or the catalog given as argv[1]).

Rules it enforces, because the catalog is edited by hand here:
  * never overwrite an existing translation for that locale — fill only what's missing;
  * the English key must already exist (a typo'd key is an error, not a new entry);
  * every %@ / %lld / %1$@ specifier in the key must appear in the translation, same multiset;
  * state is set to "translated".

Prints per-locale coverage so a partial pass is obvious.
"""
import json
import pathlib
import re
import sys

SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|@|d|f)")


def specs(text: str) -> list[str]:
    """Specifiers in canonical form, so %1$@ and %@ compare equal."""
    return sorted(s.replace("1$", "").replace("2$", "").replace("3$", "").replace("4$", "")
                  for s in SPEC.findall(text))


def main() -> int:
    payload = json.load(sys.stdin)
    locale = payload["locale"]
    incoming = payload["strings"]

    path = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Pair for two/Localizable.xcstrings")
    catalog = json.loads(path.read_text())
    strings = catalog["strings"]

    unknown, mismatched, added, kept = [], [], 0, 0
    for key, value in incoming.items():
        entry = strings.get(key)
        if entry is None:
            unknown.append(key)
            continue
        if specs(key) != specs(value):
            mismatched.append((key, value))
            continue
        locs = entry.setdefault("localizations", {})
        if locale in locs:
            kept += 1
            continue
        locs[locale] = {"stringUnit": {"state": "translated", "value": value}}
        added += 1

    if unknown:
        print(f"!! {len(unknown)} unknown key(s) — not in the catalog:")
        for key in unknown[:20]:
            print(f"   {key!r}")
    if mismatched:
        print(f"!! {len(mismatched)} translation(s) whose format specifiers don't match the key:")
        for key, value in mismatched[:20]:
            print(f"   {key!r}\n   -> {value!r}")

    catalog["strings"] = dict(sorted(strings.items()))
    path.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n")

    total = len(strings)
    done = sum(1 for v in strings.values() if locale in (v.get("localizations") or {}))
    print(f"{locale}: +{added} added, {kept} already present → {done}/{total} keys "
          f"({done * 100 // max(total, 1)}%)")
    return 1 if unknown or mismatched else 0


if __name__ == "__main__":
    sys.exit(main())
