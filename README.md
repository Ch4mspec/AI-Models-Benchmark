# AI-Models-Benchmark

**Benchmark harness for local LLMs. Measures what the model actually
produced, not what it claims.**

Findings are backed by real compilation and real execution of the generated
code, not impressions. Reference numbers live in [`BASELINE.md`](BASELINE.md).
The method, written for a technical audience, is in
[`METHODOLOGY.md`](METHODOLOGY.md).

The point: produce **verifiable** numbers on a given machine that anyone can
reproduce. No estimates, no table copied from a review — measurements taken
from the machine, with the reasoning recorded alongside.

On the reference machine, the fastest model turned out to be the only one that
failed to comply with the output format — it wrote no code block at all on four
of its five code responses. Every response from every model that could actually
be executed returned correct values. Speed, and even correctness, do not
predict instruction compliance.

## Requirements

- PowerShell 5.1+
- [Ollama](https://ollama.com) running
- Node.js
- For TypeScript verification: `npm install` (installs `typescript` and
  `@types/node`)
- For Python verification: Python 3 on `PATH`, or installed per user at
  `%LOCALAPPDATA%\Programs\Python\Python3*\python.exe`

No other dependencies. Missing a verifier degrades that check to `N/A` and
leaves the rest working.

## Usage

```powershell
# Everything installed, every test case
.\Invoke-Bench.ps1

# Then score the responses
.\check-code.ps1

# A selection of models and cases
.\Invoke-Bench.ps1 -Models qwen3:14b,devstral:24b -Tests code-utility,reasoning-loadbalancer

# More reliable numbers (median over 3 runs)
.\Invoke-Bench.ps1 -Repeat 3
```

| Parameter | Default | Purpose |
|---|---|---|
| `-Models` | all installed | models to test |
| `-Tests` | all | test cases |
| `-Repeat` | 2 | runs per case, median reported |
| `-Context` | 8192 | context window |
| `-OutDir` | `.\out` | output directory |
| `-SkipWarmup` | off | skip pre-loading the model |
| `-KeepRaw` | off | keep previous `out\raw` instead of clearing it |
| `-RandomSeed` | off | vary the seed on each repeat |

### A note on repeats

Ollama defaults to `seed: 0`, so most generations are byte-identical across
repeats. In the reference run `qwen3:14b` returned the same 848 characters
with the same prose ratio twice on `code-utility`.

It is not guaranteed. On the same seed and the same prompt,
`qwen3:14b` returned 0 characters on one repeat of the reasoning test and 1178
on the next. Determinism in Ollama holds per token given identical batch and
KV-cache state, and a long enough generation crosses enough unstable boundaries
to break it.

So the default median mostly measures clock and VRAM state, not generation
variance. That is the right default for throughput comparison, where you want
the same work timed several times. Use `-RandomSeed` when the question is
whether a code result is *stable across samples* rather than reproducible for
one.

## Test cases

| Case | Category | Language | Executes |
|---|---|---|---|
| `code-auth` | code | TypeScript | no |
| `code-utility` | code | TypeScript | yes |
| `code-python` | code | Python | yes |
| `debug-chunk` | debug | Python | yes |
| `reasoning-loadbalancer` | reasoning | prose | n/a |
| `instruction-following` | obedience | prose | n/a |

Each case is independent. Two measurements are never mixed into one run.

## Verifying the code

Throughput and prose ratios say nothing about correctness. This second script
extracts code blocks from the responses and checks them two ways.

```powershell
npm install
.\check-code.ps1
```

**Compilation.** TypeScript and JavaScript go through `tsc --strict`. Python
goes through `py_compile`.

**Execution.** When a file named after the test case exists in `tests/`, its
contents are appended to the model's output and the result is actually run.
The expected behaviour is stated exactly in the prompt, so a failure is
attributable to the model rather than to an ambiguous spec.

| Status | Meaning |
|---|---|
| `PASS` | compiles under strict checking |
| `FAIL` | real type or syntax errors |
| `PROSE` | produced no code block at all, response entirely discursive |
| `N/A` | nothing verifiable in the response |

The two checks disagree, and that is the point. In the reference run,
`llama3.1:8b` produced a `chunk` implementation that fails `tsc --strict`
(`Array(n).fill()` takes no zero-argument overload) while returning correct
results at runtime — `FAIL` on compilation, `OK` on execution. The 30B's other
failure was an unsound cast, `TS2352`, again with correct runtime results.

20 of 20 executed responses passed their assertions. Compilation caught real
type errors that execution did not; nobody has yet produced the reverse here.

`PROSE` is the most informative status in this dataset: it flags a model that
talks instead of producing, which no throughput number reveals.

### Adding a test case

1. Add the case to `$TestCases` in `Invoke-Bench.ps1`.
2. If the case can be judged by running it, create
   `tests\<case-name>.verify.py` or `.verify.ts` with the assertions.

The file is matched to responses by suffix, so `qwen3_14b_code-python.run1.out.txt`
picks up `tests/code-python.verify.py`. Without a verifier file the case is
only compiled.

## Output

```
out/
  report-latest.md      readable report, timestamped plus a copy
  results-latest.csv    usable data
  results-latest.json   same, structured
  tsc-latest.csv        compilation and execution results
  raw/                  full responses, one file per model per case per repeat
  verify/               extracted candidates, compiled and executed
```

`raw/` matters as much as the numbers. It lets you judge what was actually
produced, which no automatic score replaces.

`out\raw` is emptied at the start of every run. Without that, responses from
an earlier run stay on disk and get scored next to the new ones with no way
to tell them apart. Use `-KeepRaw` when you want both.

## Three pitfalls the harness measures explicitly

**1. The token budget is shared.** `num_predict` covers thinking *and*
response. In think mode, a 1200-token budget can be consumed entirely by
reflection and return zero characters. Marked `EMPTY`.

**2. `done_reason = length` means truncated**, not finished. Measuring a cut
response gives you a throughput number and no usable code. Marked `TRUNCATED`.

**3. Forcing an unsupported mode degrades the model.** `qwen3:30b-a3b`
accepts only `think=true`; sending `think=false` puts it in an unintended
state and produces rambling. The harness reads `/api/show` and omits the
parameter when unsupported.

## Reference machine

| Component | Value |
|---|---|
| OS | Windows 11 Home, build 26300 |
| GPU | NVIDIA GeForce RTX 5070 Ti, 16303 MiB |
| Driver | 617.14 |
| CPU | AMD Ryzen 7 9800X3D, 8 cores / 16 threads |
| RAM | 31.7 GiB |
| Ollama | 0.35.0 |

The harness prints free VRAM on launch, and so should you.

Occupied VRAM on its own does not distort throughput. The reference run
started with 9.0 GB free of 15.9 GB, a browser resident but not computing on
the GPU, and `qwen3:14b` measured 3063–6585 tok/s prefill. An earlier session
with a browser and a game client both computing measured 869–2366 tok/s on the
same model. What moves the number is another process actually using the GPU,
not VRAM occupancy.

Free VRAM still decides one thing, and it is the thing that matters for a
model larger than the card: whether the model fits at all.

## Reading the results

**Decode tok/s** — generation speed. A good feel for responsiveness, but
misleading alone: a model that rambles is fast and useless.

**Prefill tok/s** — context processing speed. A high figure means the model
sits entirely in VRAM.

**Prose** — share of non-code lines in the response. Above 0.3, the model is
narrating instead of producing.

**VRAM free** — printed at launch. Below 8 GB at startup means an oversized
model will overflow to system RAM and throughput will collapse.

## Limitations

- The test cases are author judgement, not a standard. A model can pass all
  of them and still fail in real use.
- Assertions are hand-written and cover the behaviour named in the prompt.
  They do not cover performance, security, resource leaks, or anything about
  code style.
- A wrong status code in a correct handler still passes `code-auth`: there is
  no verifier for that case because it would require standing up Express,
  Prisma and a database.
- Generated code is **executed** on your machine to check behaviour. It comes
  from a language model and should be treated accordingly. The checked cases
  are pure functions with no I/O, but the mechanism is general.
- `Repeat` defaults to 2 as a compromise. Use 3 or 5 to compare closely, and
  add `-RandomSeed` if you want repeats to differ at all.
- Throughput varies with machine load. The same model measured 869–2366 tok/s
  prefill with a browser and a game client both computing on the GPU, and
  3063–6585 tok/s with a browser resident but idle. Active GPU load is the
  variable, not VRAM occupancy.