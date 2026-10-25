#!/usr/bin/env python3
"""Succeed when the host resolver returns at least one address for a name.

Usage: host_resolve.py HOSTNAME

Exit 0 on success, 1 on a failed lookup or missing argument. No output.
Fallback for scripts/lib/host_state.sh when getent is absent.
"""

import socket
import sys


def main(argv):
    if len(argv) != 2 or not argv[1]:
        sys.stderr.write("usage: host_resolve.py HOSTNAME\n")
        return 1
    try:
        socket.getaddrinfo(argv[1], None)
    except OSError:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
