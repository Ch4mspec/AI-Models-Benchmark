# Chemspec

**Benchmark harness for local LLMs. Measures what the model actually
produced, not what it claims.**

Findings are backed by real `tsc --strict` compilation, not impressions.
Reference numbers live in [`BASELINE.md`](BASELINE.md). The method, written
for a technical audience, is in [`METHODOLOGY.md`](METHODOLOGY.md).

The point: produce **verifiable** numbers on a given machine that anyone can
reproduce. No estimates, no table copied from a review — measurements taken
from the machine, with the reasoning recorded alongside.

On the reference machine, the fastest model turned out to be the only one
that produced no code at all. Speed and capability do not travel together.

## Requirements

- PowerShell 5.1+
- [Ollama](https://ollama.com) running
- For code verification only: `npm install` (installs `typescript` and
  `@types/node`)

No other dependencies.

## Usage

```powershell
# Everything installed, every test case
.\Invoke-Bench.ps1

# A selection of models and cases
.\Invoke-Bench.ps1 -Models qwen3:14b,devstral:24b -Tests code-utility,reasoning

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

## Test cases

| Case | Category | Measures |
|---|---|---|
| `code-auth` | code | complete Express/Prisma endpoint against 6 requirements |
| `code-utility` | code | three TypeScript utilities in one block |
| `reasoning-loadbalancer` | reasoning | multi-constraint latency calculation |
| `instruction-following` | obedience | output must be exactly one word |

## Verifying the code compiles

Throughput and prose ratios say nothing about correctness. This second script
extracts code blocks from the responses and compiles them for real with
`tsc --strict`.

```powershell
npm install
.\check-code.ps1 -File .\out\raw\*.out.txt
```

Three possible outcomes:

| Status | Meaning |
|---|---|
| `OUI` | compiles in strict mode |
| `NON` | real type or syntax errors |
| `PROSE` | produced no code block at all, response entirely discursive |

`PROSE` is the most informative status: it flags a model that talks instead
of producing, which no throughput number reveals.

## Output

```
out/
  report-latest.md      readable report, timestamped plus a copy
  results-latest.csv    usable data
  results-latest.json   same, structured
  tsc-latest.csv        compilation results
  raw/                  full responses and reasoning traces
  tsc/                  extracted candidate files
```

`raw/` matters as much as the numbers. It lets you judge what was actually
produced, which no automatic score replaces.

## Three pitfalls the harness measures explicitly

**1. The token budget is shared.** `num_predict` covers thinking *and*
response. In think mode, a 1200-token budget can be consumed entirely by
reflection and return zero characters. Marked `VIDE`.

**2. `done_reason = length` means truncated**, not finished. Measuring a cut
response gives you a throughput number and no usable code. Marked `COUPE`.

**3. Forcing an unsupported mode degrades the model.** `qwen3:30b-a3b`
accepts only `think=true`; sending `think=false` puts it in an unintended
state and produces rambling. The harness reads `/api/show` and omits the
parameter when unsupported.

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
- `Repeat` defaults to 2 as a compromise. Use 3 or 5 to compare closely.
- Throughput varies with machine load. On the reference machine, a browser
  and background processes were holding 1–15 GB of VRAM during runs.
  Measuring on an idle machine makes results comparable.
- Compilation checks syntax and types only. No test suite runs against the
  generated code, so a logically wrong endpoint still compiles.
