#!/usr/bin/env python3
"""Parse YAML files with yaml.safe_load; exit 1 on the first failure.

Usage: parse_yaml.py FILE [FILE...]

Used by scripts/validate.sh so the YAML check is not an inline python -c.
Requires PyYAML. Prints nothing on success.
"""

import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("parse_yaml: PyYAML is not installed\n")
    sys.exit(1)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: parse_yaml.py FILE [FILE...]\n")
        return 1
    for path in argv[1:]:
        try:
            with open(path, encoding="utf-8") as fh:
                yaml.safe_load(fh)
        except (OSError, yaml.YAMLError) as exc:
            sys.stderr.write(f"parse_yaml: {path}: {exc}\n")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
