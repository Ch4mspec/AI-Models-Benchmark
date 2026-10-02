// Appended by check-code.ps1 to the model's code, then compiled and executed.
//
// `typeof x !== "undefined"` is deliberate: it is legal JavaScript on an
// undeclared identifier and throws nothing, so a model that forgot the
// function produces a readable "chunk is not defined" failure at run time
// instead of a TS2304 that says nothing about behaviour.

const _failures: string[] = [];

function _check(label: string, got: unknown, want: unknown): void {
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    _failures.push(`${label}: expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
  }
}

// --- chunk ---
const _chunk: any = typeof chunk !== "undefined" ? chunk : null;
if (_chunk === null) {
  _failures.push("chunk is not defined");
} else {
  _check("even split", _chunk([1, 2, 3, 4], 2), [[1, 2], [3, 4]]);
  _check("remainder", _chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]]);
  _check("empty input", _chunk([], 3), []);
  _check("size larger than input", _chunk([1, 2], 9), [[1, 2]]);
  _check("does not mutate input", (() => {
    const src = [1, 2, 3];
    _chunk(src, 2);
    return src;
  })(), [1, 2, 3]);
}

// --- memoize ---
const _memoize: any = typeof memoize !== "undefined" ? memoize : null;
if (_memoize === null) {
  _failures.push("memoize is not defined");
} else {
  let calls = 0;
  const double = (x: number): number => { calls += 1; return x * 2; };
  const memo = _memoize(double);
  _check("memoize computes", memo(4), 8);
  _check("memoize repeats value", memo(4), 8);
  _check("memoize hit avoids recompute", calls, 1);
  _check("memoize new argument", memo(5), 10);
  _check("memoize new argument recomputes", calls, 2);
}

if (_failures.length > 0) {
  console.log("VERIFY_FAIL");
  for (const _f of _failures) { console.log("  - " + _f); }
  process.exit(1);
}

console.log("VERIFY_OK");