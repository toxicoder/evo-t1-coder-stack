"""Package purpose: unittest suites for the standalone Python helpers under scripts/lib.

The marker exists because `unittest discover -s tests/python -t .` (tests/coverage/py_cov.sh)
only descends into a start directory that is a real package; the suites themselves import
nothing from here.
"""
