# Appended by check-code.ps1 to the model's code, then executed.
# The off-by-one in the original is the whole point: it returns
# [[1,2,3],[4,5]] for the first case, so an unfixed copy fails here.

_failures = []


def _check(label, got, want):
    if got != want:
        _failures.append("{0}: expected {1!r}, got {2!r}".format(label, want, got))


_check("basic split", chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]])
_check("empty input", chunk([], 3), [])
_check("size larger than input", chunk([1, 2], 5), [[1, 2]])
_check("exact multiple", chunk([1, 2, 3, 4], 2), [[1, 2], [3, 4]])
_check("size of 1", chunk([1, 2, 3], 1), [[1], [2], [3]])

try:
    chunk([1, 2], 0)
    _failures.append("size=0 returned normally, expected ValueError")
except ValueError:
    pass
except Exception as exc:  # wrong exception type
    _failures.append("size=0 raised {0}, expected ValueError".format(type(exc).__name__))

if _failures:
    print("VERIFY_FAIL")
    for _f in _failures:
        print("  - " + _f)
    raise SystemExit(1)

print("VERIFY_OK")