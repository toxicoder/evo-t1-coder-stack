#!/usr/bin/env python3
"""Copy one JSON string/scalar key from a current file into a dest file.

Usage: json_copy_key.py DEST CURRENT KEY

Exits 0 when KEY is absent from CURRENT (nothing to copy) or after a
successful write. Exits 1 on missing arguments, unreadable files, or
invalid JSON. Indent 2, trailing newline, matching the previous inline
copy in scripts/lib/config_seed.sh.
"""

import json
import sys


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: json_copy_key.py DEST CURRENT KEY\n")
        return 1
    dest, current, key = argv[1], argv[2], argv[3]
    try:
        with open(current, encoding="utf-8") as fh:
            old = json.load(fh)
        if key not in old:
            return 0
        with open(dest, encoding="utf-8") as fh:
            new = json.load(fh)
        new[key] = old[key]
        with open(dest, "w", encoding="utf-8") as fh:
            json.dump(new, fh, indent=2)
            fh.write("\n")
    except (OSError, json.JSONDecodeError, TypeError) as exc:
        sys.stderr.write(f"json_copy_key: {exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
