# Methodology

**How to benchmark a local LLM without lying to yourself**

This document is the method behind [`AI-Models-Benchmark`](https://github.com/Ch4mspec/AI-Models-Benchmark).
It exists because most published LLM comparisons are wrong in ways that
favour whoever ran them. The purpose here is to make the results impossible
to argue with, including by you.

Audience: engineers and technical leads choosing a model for deployment on
specific hardware.

---

## 0. Reference environment

Every number in section 8 comes from this machine, measured idle.

| Component | Value |
|---|---|
| OS | Windows 11 Home, build 26300 |
| GPU | NVIDIA GeForce RTX 5070 Ti, 16303 MiB |
| Driver | 617.14 |
| CPU | AMD Ryzen 7 9800X3D, 8 cores / 16 threads |
| RAM | 31.7 GiB |
| Ollama | 0.35.0 |
| Quantization | Q4_K_M, all three models |

Reproduce the environment check with one command:

```powershell
nvidia-smi --query-gpu=driver_version,name,memory.total,utilization.gpu --format=csv
```

Check GPU *utilisation*, not VRAM occupancy. The reference run started with
9.0 GB of 15.9 GB free, a browser resident but not computing, and the 14B
measured 3 063-6 585 tok/s prefill. An earlier session with a browser and a
game client both computing measured 869-2 366 tok/s on the same model, close
to a 2× penalty.

So the rule is narrower than "close everything": free VRAM does not affect
throughput much, but an active GPU workload does. Free VRAM decides something
else and more fundamental — whether a model larger than the card can fit at
all. Both are recorded.

---

## 1. Why published comparisons mislead

A benchmark that cannot be reproduced is an opinion with a table.

Three failure modes are common and all of them inflate results:

**Vendor benchmarks run on hardware nobody owns.** A 30B model at 110
tokens/s is a number from an 80 GB cluster. On a 16 GB consumer card the
same model spills to system RAM and the figure collapses. Throughput without
a VRAM budget is meaningless.

**Speed is reported instead of correctness.** A model that generates 105
tokens/s of monologue is not fast, it is verbose. Nothing in a tok/s number
tells you whether the code compiles.

**Single-run samples.** Local inference varies 2–3× with machine load. One
run measures the browser that happened to be open.

The corrections, in order of importance:

1. **Compile the output.** Syntax and types are objective. Taste is not.
2. **Report the VRAM budget and whether the model fit.**
3. **Take a median over at least 3 runs on an idle machine.**
4. **Keep the raw responses.** Always.

---

## 2. Test design

A test is a task with a pass condition that does not involve your opinion.

The harness ships with six. Each isolates one property, so a failure
points at a cause rather than at "the model".

| Test | Property | Pass condition |
|---|---|---|
| `code-auth` | sustained instruction following | produces a fenced code block, compiles strict |
| `code-utility` | code correctness | fenced block, compiles strict, `chunk` and `memoize` return the right values |
| `code-python` | code correctness | fenced block, compiles, `merge_intervals` returns the right values |
| `debug-chunk` | bug identification | fixed function returns the right values and rejects `size <= 0` |
| `reasoning-loadbalancer` | multi-step reasoning | returns a non-empty answer |
| `instruction-following` | format obedience | output is exactly `BANANA` |

`instruction-following` is deliberately trivial. It exists to catch a model
that cannot suppress its own reasoning, which is the failure most likely to
wreck a real workflow and the one a human reviewer is least likely to notice
because the output still *looks* like an answer.

`debug-chunk` exists because the other cases ask for code the model is good
at. Passing a request to write a utility is not the same skill as spotting
the `size - 1` in someone else's working function. The prompt states the
required behaviour exactly, so the test measures diagnosis and not guessing.

### Pass conditions

Four of the six cases are judged by **execution**, not by inspection. The
expected behaviour is written out in the prompt as literal input/output pairs,
and `check-code.ps1` appends those assertions to the model's own code and runs
it.

This matters because the two checks fail independently, and in both
directions. `llama3.1:8b` wrote a `chunk` using `Array(n).fill()`, which
violates the zero-argument rule for `fill` and fails `tsc --strict`, while
returning correct results at runtime. A different model wrote a
`merge_intervals` that compiled without a single diagnostic and silently
dropped every interval after the first when the input was unsorted.

Neither check subsumes the other, so the harness reports both.

### Writing your own

A good test has these properties:

- **One property.** If it measures speed and correctness, a failure is
  ambiguous.
- **A binary outcome.** Compiles or does not. Never "quality 7/10".
- **Short output.** Under 1500 tokens, so truncation is visible rather than
  silent.
- **Prose in the failure case is itself the result.** A model that narrates
  instead of producing has failed, and the transcript is the evidence.
- **A pass condition that needs no opinion.** If you have to read the output
  and decide whether it is right, write an assertion instead. The human
  reading of "returns `409` where `400` was expected" is a real finding, but
  it is a finding you cannot reproduce.

---

## 3. Measurement definitions

Predefined, so two people running this get comparable numbers.

**Decode throughput (tok/s)** — `eval_count / eval_duration`, from the
generation phase only, excluding prefill. The felt-responsiveness number.
Misleading alone: verbose models score high.

**Prefill throughput (tok/s)** — `prompt_eval_count / prompt_eval_duration`.
A high figure means the model sits entirely in VRAM. Below ~700 tok/s on a
16 GB card, expect overflow.

**Prose ratio** — share of response lines that are neither blank, nor
comments, nor code. Above 0.3, the model is narrating. Computed
heuristically, not by an LLM judge, so it does not inherit that judge's
bias.

**Compile status** — four outcomes:

| Status | Meaning |
|---|---|
| `PASS` | compiles under `tsc --strict`, or `py_compile` for Python |
| `FAIL` | real type or syntax errors |
| `PROSE` | no code block produced at all |
| `N/A` | no code expected for this test |

**Execution status** — a separate axis, reported alongside compilation:

| Status | Meaning |
|---|---|
| `OK` | every assertion in `tests\<case>.verify.*` passed |
| `FAIL` | at least one assertion failed |
| `-` | no verifier exists for this case, code was only compiled |

The two are independent by design. See section 6.

**Repeat semantics** — with the default `seed: 0`, Ollama generation is
deterministic and every repeat returns the identical response. Confirmed on
`qwen3:14b`: both repeats of `code-utility` produced 848 characters with an
identical prose ratio. So the default median measures clock and VRAM state, not
generation variance.

That is the right default when comparing throughput, where you want identical
work timed several times. It is the wrong default when asking whether a code
result is stable, because a deterministic pass says nothing about the other
samples. `-RandomSeed` varies the seed per repeat for that question.

**Prose is a compile failure**, not a syntax curiosity. Compiling a
monologue produces hundreds of meaningless errors. Distinguishing them is the
difference between "this model is bad" and "this model is a chat model".

**Truncation** — `done_reason == "length"`. Throughput from a truncated run
is valid, the code is not. Report both or neither.

**Empty response** — a non-empty `thinking` with an empty `response`. The
budget was consumed by reflection. Always a configuration error, never a
model failure.

---

## 4. Environment capture

Record before you measure, publish with the results.

- GPU model and **total VRAM**, plus **free VRAM at launch**
- CPU model, core count
- System RAM
- Ollama version
- Quantization level and parameter count per model
- Context window used
- Number of repeats, and the aggregation (median, not mean)

Free VRAM at launch is the field most often omitted. A run started with 1 GB
free and a run started with 15 GB free are not the same experiment, because
one of them fits the model and the other does not.

Do not over-correct, though. VRAM occupancy is not throughput. Close what is
*computing* — a game client, a video, a second inference server. A browser
holding 4 GB of VRAM while idle cost nothing measurable in the reference run.

---

## 5. Controlling for the thinking trap

Hybrid reasoning models accept a `think` parameter. It is the largest source
of misleading results in local benchmarking.

**The token budget is shared.** `num_predict` covers reflection *and*
response. Measured: a 14B model given 4000 predicted tokens on a
multi-step problem produced 0 characters of answer. All 4000 went to
reflection. If you cap the budget low, the model appears to fail when it
did not.

**Send the parameter explicitly.** Omitting `think` leaves the model default
in effect, and Qwen3 defaults to `true`. A benchmark written to "test code
generation" that never sets `think=false` is measuring a reasoning model
writing essays.

**Check what the model accepts.** `qwen3:30b-a3b` reports
`thinking.values = [true]` only. Sending `think=false` is not a valid
configuration, and the model's output degrades accordingly. Read
`/api/show` before assuming a parameter is honoured.

The harness reads `/api/show` and omits `think` when unsupported. It also
flags empty responses and truncation so the failure is attributed correctly
instead of being scored as a model defect.

---

## 6. Compilation as ground truth

This is what separates a measurement from an opinion.

```powershell
npm install
.\check-code.ps1
```

Two independent gates, in this order.

**1. Compilation.** `tsc --strict` with `--typeRoots` pointed at
`node_modules/@types` and `--types node`. Python goes through `py_compile`.
Three details that matter:

- **`@types/node` is not optional.** Without it, every legitimate use of
  `process` or `require` raises TS2591 and valid code fails. That is an
  environment defect, not a model defect.
- **TS2307 (`Cannot find module`) is excluded.** The LLM's output imports
  packages that are not installed. Reporting those as errors fails everything
  and distinguishes nothing.
- **`PROSE` is not a failure.** When no code fence is found and the language
  was inferred from free text, compilation is meaningless — one is scoring
  monologue. It is reported as its own status instead of being counted as
  hundreds of syntax errors.

**2. Execution.** When `tests\<case>.verify.{py,ts}` exists, its assertions
are appended to the model's own code and the result is run. For TypeScript the
combined file is compiled with emit, then run under `node`; for Python it is
run directly.

Two details that matter:

- **Type errors in the assertions are not the model's fault.** `typeof chunk`
  is legal JavaScript on an undeclared identifier and throws nothing, but
  raises TS2304 in TypeScript. So the emit step ignores `tsc`'s exit code and
  lets the run decide. Type errors in the *model's* code are already caught by
  gate 1.
- **An exit code of 0 is not enough.** The file must also print `VERIFY_OK`. A
  model whose code calls `sys.exit()` before the assertions run would otherwise
  be recorded as a pass.

What the two gates together prove: the output parses, type-checks under strict
rules where the language has them, and returns the specified values.

What they still do **not** prove: anything about performance, security,
resource handling, or whether the code is the right shape for the job. A
handler that returns `400` where the spec says `409` still passes `code-auth`,
because judging that would mean standing up Express, Prisma and a database. Say
so in your report.

---

## 6b. Executing model output

Running generated code is the only way to judge it, and it deserves an honest
framing.

The check executes whatever the model produced, on the machine running the
harness. There is no sandbox. That is a real limitation and it belongs in the
limitations section, not in a footnote.

What makes it tolerable here: the verified cases are pure functions over lists
and numbers, with no filesystem, network or subprocess access. The exposure is
whatever a model wrote, not whatever the test intended.

If you extend this to cases that touch I/O, put them in a container or a VM
first. The mechanism does not change, the boundary does.

---

## 7. Reporting

A result is publishable when a reader can reproduce it and a reader can
disagree with it.

Minimum for a defensible claim:

1. Machine specs, Ollama version, quantization, context, repeat count
2. The table of numbers
3. Raw outputs for every claim
4. The failure cases, especially your own harness's

Point 4 is where most published benchmarks are weakest. A comparison that
reports only wins is not a measurement.

State the limitation nearest to the claim it limits. "qwen3:14b passed 6/6
assertions on three hand-authored cases" is honest. "qwen3:14b produces correct
code" is not supported by that evidence.

---

## 8. Reference results

Full data in [`BASELINE.md`](BASELINE.md). Machine: RTX 5070 Ti 16 GB,
Ryzen 7 9800X3D, 31.7 GiB RAM, Ollama 0.35.0. Six cases, two repeats each,
median reported.

| Model | Compiled | `PROSE` | Behaviour | Decode tok/s | One-word obedience |
|---|---|---|---|---|---|
| `qwen3:14b` | 8/8 | 0 | 6/6 | 77–101 | pass |
| `devstral:24b` | 8/8 | 0 | 6/6 | 29–38 | pass |
| `llama3.1:8b` | 7/8 | 0 | 4/4 | 143–181 | pass |
| `qwen3:30b-a3b` | 1/5 | 4 | 2/2 | 103–112 | **fail** |

Four observations worth carrying to your own hardware:

**Every response that could be executed was correct.** 20 of 20, across four
models and three code cases. On cases where the expected behaviour is written
out as literal input/output pairs, none of these models produced code that ran
and then got the answer wrong.

**So the interesting failures are all about format, not capability.** The 30B
is the fastest model in the set and the only one that failed to comply. Four
of its five non-passing code responses contained no code fence at all; the
prompt asked for one, in bold. The fifth contained genuine type errors. On the
two responses where it did emit a fence, the code ran correctly.

This is the distinction that matters and that throughput charts cannot show.
The model knows what the code should be. It does not reliably deliver it in the
shape you asked for. If your pipeline parses fences, that gap is a failure; if
it scrapes whatever comes back, it is invisible.

**Reasoning models spent the budget and returned nothing.** With a
4000-token budget and `think=true`, both Qwen3 models came back with an empty
response — 15 000 to 16 000 characters of reflection and no answer. The two
models without a thinking mode answered every time. A harness that does not
check for empty output will report a working model.

**Compilation and execution caught different things.** Both `FAIL`s on
compilation were real type errors that runtime behaviour did not expose. The
reverse — clean compile, wrong answer — was produced by hand while building
the verifier and has not come from a model on these cases yet. Report both
columns; neither subsumes the other.

---

## 9. Limits of this method

Stated plainly, because a method document that hides its weaknesses is an
advertisement.

- **Six hand-authored cases.** A model can pass all six and fail real work.
  Extend the set before drawing a general conclusion.
- **`Repeat = 2` default.** Enough to catch a gross error, not enough to
  resolve a 10% difference. Use 3–5.
- **Assertions cover only what the prompt states.** They test the behaviour
  named in the spec and nothing else: no performance, no security, no
  resource leaks, no style. A correct `merge_intervals` that is O(n²) passes.
- **Execution has no sandbox.** Model output runs on your machine. Safe for
  pure functions, not for anything else. See section 6b.
- **`code-auth` is only compiled, never run.** Judging it means standing up
  Express, Prisma and a database. Its semantic quality is a human judgement
  and is labelled as one.
- **Prose ratio is a heuristic.** It counts lines, not meaning. It is
  consistent across models, which is what matters, but it is not a quality
  measure.
- **Four models, two of them from the same family.** Enough to show the
  harness is not Qwen-specific, not enough to claim it is unbiased.
- **The verifier and the prompts share an author.** The same person wrote the
  specification and the assertions, which is exactly the situation where a
  spec can be read charitably by its author and strictly by a competitor. The
  mitigations are that the expected behaviour is stated literally in the
  prompt, and that the assertions are readable in `tests/`.
- **Execution correctness has never once been the failing gate.** 20/20
  passed, so this axis has not yet discriminated between models. Treat the
  `Behaviour` column as unproven infrastructure rather than as a result.
- **Single machine, single session.** The reference numbers do not transfer.
  A 24 GB card changes the ranking, because the 30B stops overflowing.

The harness is a measurement tool, not a benchmark suite. It reports what
happened on your hardware. Drawing conclusions about models in general
requires re-running elsewhere, which is the point.
