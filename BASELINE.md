# Baseline results — AI-Models-Benchmark

Reference measurements for reproducibility. Anyone can re-run the harness
on comparable hardware and check whether these numbers hold.

**Machine**: NVIDIA GeForce RTX 5070 Ti (16 GB VRAM) · AMD Ryzen 7 9800X3D · 31.7 GB RAM
**Ollama**: 0.35.0
**Date**: 2026-10-01
**Context**: 8192 · **Repeats**: 1 (directional, not statistical)

Reproduce with:

```powershell
.\Invoke-Bench.ps1 -Models qwen3:30b-a3b,qwen3:14b,devstral:24b `
    -Tests code-auth,code-utility,reasoning-loadbalancer,instruction-following
.\check-code.ps1 -File .\out\raw\*.out.txt
```

## Speed

| Model | Decode tok/s | Prefill tok/s | Family | Context | Quant |
|---|---|---|---|---|---|
| qwen3:30b-a3b | 98–106 | 363–750 | qwen3moe | 262 144 | Q4_K_M |
| qwen3:14b | 76–100 | 869–2 366 | qwen3 | 40 960 | Q4_K_M |
| devstral:24b | 28–34 | 1 967–20 854 | llama | 131 072 | Q4_K_M |

Decode speed is measured after prefill. The 30B generates fastest
(its 3B active-parameter MoE architecture) but prefills slowest: it exceeds
16 GB VRAM and spills into system RAM, which caps prefill around 700 tok/s
versus 2 000+ for models that fit.

## Code correctness

| Model | code-auth | code-utility | Compiles |
|---|---|---|---|
| qwen3:14b | 93 lines | 29 lines | 2/2 |
| devstral:24b | 87 lines | 35 lines | 2/2 |
| qwen3:30b-a3b | 107 lines, no fence | 103 lines, no fence | **0/2** |

Both qwen3:14b and devstral:24b produce valid strict-mode TypeScript for
both code tasks. The 30B emits no fenced code block at all on either.

## Instruction following

Prompt: reply with exactly `BANANA`, nothing else.

| Model | Output | Verdict |
|---|---|---|
| qwen3:14b | 6 chars | exact |
| devstral:24b | 6 chars | exact |
| qwen3:30b-a3b | 1 307 chars | fails |

The 30B writes 1 307 characters of deliberation about how to answer a
one-word request.

## Prose ratio

Share of non-code lines in the response.

| Model | code-auth | code-utility | reasoning | instruction |
|---|---|---|---|---|
| qwen3:14b | 0.266 | 0.067 | — (empty) | 0.000 |
| devstral:24b | 0.170 | 0.139 | 0.543 | 0.000 |
| qwen3:30b-a3b | 0.302 | 0.382 | 0.370 | 0.611 |

## Three failure modes measured

**Shared token budget.** `num_predict` covers thinking and response alike.
qwen3:14b on `reasoning-loadbalancer` with 4000 predicted tokens returned
0 characters of answer: the entire budget went to reflection. Marked `EMPTY`.

**Truncated output.** `done_reason = length` means the response was cut.
The 30B hit the cap on both code tasks (`TRUNCATED`). Speed numbers from a
truncated run are valid; the code is incomplete.

**Unsupported mode forced.** `qwen3:30b-a3b` reports `thinking.values = [true]`
only. Sending `think=false` places it in an unsupported state. The harness
reads `/api/show` and omits the parameter entirely when unsupported.

## Recommendation for this machine

**qwen3:14b** as default. Both code tasks compile, exact instruction
following, 0.07 prose ratio, and the reasoning budget trap only appears when
thinking is enabled.

**devstral:24b** for backend work where semantics matter. It is the only
model here that returns `409 Conflict` correctly and uses
`express-validator` over hand-rolled regex. Cost is 3× lower decode speed.

**qwen3:30b-a3b** is the fastest and least reliable of the three. Do not
default to it on a 16 GB card. Worth revisiting only as a smaller
quantization that fits entirely in VRAM.

## Caveats

- `Repeat = 1`. Directional, not statistical. Use 3–5 to compare closely.
- A single browser and background processes were consuming 1–15 GB VRAM
  during these runs. Measure on an idle machine for comparable numbers.
- Four hand-authored test cases. A model can pass all of them and still
  fail real use.
- Compilation verifies syntax and types only. No test suite is run against
  the generated code, so a logically wrong endpoint still compiles.
