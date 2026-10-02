# Methodology

**How to benchmark a local LLM without lying to yourself**

This document is the method behind [`AI-Models-Benchmark`](https://github.com/Ch4mspec/AI-Models-Benchmark).
It exists because most published LLM comparisons are wrong in ways that
favour whoever ran them. The purpose here is to make the results impossible
to argue with, including by you.

Audience: engineers and technical leads choosing a model for deployment on
specific hardware.

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

The harness ships with four. Each isolates one property, so a failure
points at a cause rather than at "the model".

| Test | Property | Pass condition |
|---|---|---|
| `code-auth` | sustained instruction following | produces a fenced code block, compiles strict |
| `code-utility` | code correctness | produces a fenced code block, compiles strict |
| `reasoning-loadbalancer` | multi-step reasoning | returns a non-empty answer |
| `instruction-following` | format obedience | output is exactly `BANANA` |

`instruction-following` is deliberately trivial. It exists to catch a model
that cannot suppress its own reasoning, which is the failure most likely to
wreck a real workflow and the one a human reviewer is least likely to notice
because the output still *looks* like an answer.

### Writing your own

A good test has these properties:

- **One property.** If it measures speed and correctness, a failure is
  ambiguous.
- **A binary outcome.** Compiles or does not. Never "quality 7/10".
- **Short output.** Under 1500 tokens, so truncation is visible rather than
  silent.
- **Prose in the failure case is itself the result.** A model that narrates
  instead of producing has failed, and the transcript is the evidence.

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
| `PASS` | compiles under `tsc --strict` |
| `FAIL` | real type or syntax errors |
| `PROSE` | no code block produced at all |
| `N/A` | no code expected for this test |

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

Free VRAM at launch is the field most often omitted and the one that explains
most discrepancies. A run started with 1 GB free and a run started with 15 GB
free are not the same experiment.

Run on an idle machine. Close the browser. On the reference machine, one
browser tab was holding 4 GB of VRAM.

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
.\check-code.ps1 -File .\out\raw\*.out.txt
```

`tsc --strict` with `--typeRoots` pointed at `node_modules/@types` and
`--types node`. Two details that matter:

- **`@types/node` is not optional.** Without it, every legitimate use of
  `process` or `require` raises TS2591 and valid code fails. That is an
  environment defect, not a model defect.
- **TS2307 (`Cannot find module`) is excluded.** The LLM's output imports
  packages that are not installed. Reporting those as errors fails everything
  and distinguishes nothing.

What compilation proves: the output is syntactically valid and type-correct.

What it does **not** prove: that the logic is right. A handler that returns
`400` where the spec says `409` compiles perfectly. Compilation is a
necessary condition, not a sufficient one. Pair it with a human reading the
raw output, and say so in your report.

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

State the limitation nearest to the claim it limits. "qwen3:14b compiled 2/2
on two hand-authored test cases" is honest. "qwen3:14b produces correct
code" is not supported by that evidence.

---

## 8. Reference results

Full data in [`BASELINE.md`](BASELINE.md). Machine: RTX 5070 Ti 16 GB,
Ryzen 7 9800X3D, 31.7 GB RAM, Ollama 0.35.0.

| Model | Compiles | Decode tok/s | Prose (utility) | One-word obedience |
|---|---|---|---|---|
| qwen3:14b | 2/2 | 80 | 0.07 | pass |
| devstral:24b | 2/2 | 28 | 0.14 | pass |
| qwen3:30b-a3b | **0/2** | 105 | 0.38 | **fail** |

Three observations worth carrying to your own hardware:

**The fastest model produced no code.** 105 tok/s, 18 GB, no fenced block on
either code test. It answered a request for one word with 1307 characters of
deliberation. Speed here measures verbosity.

**Throughput inverted against capability.** The 30B is 31% faster than the
14B and 3.7× faster than devstral, and the least useful of the three on
these tests. If a comparison leads with tok/s it will lead with the wrong
answer.

**Code quality and speed were independent.** devstral is 2.8× slower than the
14B and produced the more semantically correct output: `409 Conflict` where
the 14B returned `400`, `express-validator` instead of a hand-rolled regex,
separate secrets for access and refresh tokens. A throughput-led ranking
would rank it last.

---

## 9. Limits of this method

Stated plainly, because a method document that hides its weaknesses is an
advertisement.

- **Four hand-authored cases.** A model can pass all four and fail real work.
  Extend the set before drawing a general conclusion.
- **`Repeat = 2` default.** Enough to catch a gross error, not enough to
  resolve a 10% difference. Use 3–5.
- **Compilation is necessary, not sufficient.** A type-correct endpoint with
  the wrong status code passes.
- **Prose ratio is a heuristic.** It counts lines, not meaning. It is
  consistent across models, which is what matters, but it is not a quality
  measure.
- **No test execution.** Generated code is compiled, never run against a
  spec. This is the largest gap.
- **Single machine, single session.** The reference numbers do not transfer.
  A 24 GB card changes the ranking, because the 30B stops overflowing.

The harness is a measurement tool, not a benchmark suite. It reports what
happened on your hardware. Drawing conclusions about models in general
requires re-running elsewhere, which is the point.
