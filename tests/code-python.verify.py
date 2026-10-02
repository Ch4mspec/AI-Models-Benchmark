# Appended by check-code.ps1 to the model's code, then executed.
# A passing py_compile is not enough: the function has to be right.

_failures = []


def _check(label, got, want):
    if got != want:
        _failures.append("{0}: expected {1!r}, got {2!r}".format(label, want, got))


_check("empty input", merge_intervals([]), [])
_check("single interval", merge_intervals([(1, 3)]), [(1, 3)])
_check("overlapping", merge_intervals([(1, 3), (2, 6), (8, 10)]), [(1, 6), (8, 10)])
_check("touching merges", merge_intervals([(1, 4), (4, 5)]), [(1, 5)])
_check("unsorted input", merge_intervals([(5, 6), (1, 2)]), [(1, 2), (5, 6)])
_check("interval inside another", merge_intervals([(1, 10), (2, 3), (4, 5)]), [(1, 10)])
_check("all disjoint", merge_intervals([(1, 2), (5, 6), (9, 10)]), [(1, 2), (5, 6), (9, 10)])
_check("adjacent chain", merge_intervals([(1, 2), (2, 3), (3, 4)]), [(1, 4)])

if _failures:
    print("VERIFY_FAIL")
    for _f in _failures:
        print("  - " + _f)
    raise SystemExit(1)

print("VERIFY_OK")