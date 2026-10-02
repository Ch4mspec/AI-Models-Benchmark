# Baseline results — AI-Models-Benchmark

Reference measurements for reproducibility. Anyone can re-run the harness
on comparable hardware and check whether these numbers hold.

## Environment

Full detail, so a reader can reproduce or contest these numbers.

| Component | Value |
|---|---|
| OS | Windows 11 Home, build 26300 |
| GPU | NVIDIA GeForce RTX 5070 Ti, 16303 MiB |
| Driver | 617.14 |
| CPU | AMD Ryzen 7 9800X3D, 8 cores / 16 threads |
| RAM | 31.7 GiB |
| Ollama | 0.35.0 |
| Quantization | Q4_K_M (all models) |
| Date | 2026-10-01 |
| Context | 8192 |
| Repeats | 2, median reported |
| Seed | 0, Ollama default |

`nvidia-smi --query-gpu=driver_version,name,memory.total,utilization.gpu --format=csv`
returns the GPU rows above. The harness prints free VRAM on every launch; this
run started with 9.0 GB free of 15.9 GB, with a browser resident but not
computing on the GPU.

## Models

| Model | Params | Quant | Thinking | Default think | Max context |
|---|---|---|---|---|---|
| `llama3.1:8b` | 8.0B | Q4_K_M | no | — | 131072 |
| `qwen3:14b` | 14.8B | Q4_K_M | yes | true | 40960 |
| `devstral:24b` | 23.6B | Q4_K_M | no | — | 131072 |
| `qwen3:30b-a3b` | 30.5B | Q4_K_M | yes | true | 262144 |

## Code verification

Every case run twice, so 8 responses per model on the code cases. `PROSE`
counts a response that contained no code fence at all. `Behaviour` counts
responses that were actually executed against `tests/*.verify.*`.

| Model | Compiled | `PROSE` | Behaviour |
|---|---|---|---|
| `qwen3:14b` | 8/8 | 0 | 6/6 |
| `devstral:24b` | 8/8 | 0 | 6/6 |
| `llama3.1:8b` | 7/8 | 0 | 4/4 |
| `qwen3:30b-a3b` | 1/5 | 4 | 2/2 |
| **Total** | **24/31** | **5** | **20/20** |

The three results that matter:

**Every response that was runnable was correct.** 20 out of 20. Not one model
produced code that compiled and then returned wrong values on a case where the
expected behaviour was stated in the prompt as literal input/output pairs.

**The 30B's failures are all format failures.** Four of its five non-passing
responses contained no code fence. The fifth contained real type errors
(`TS2352`, unsound cast). On the two responses where it did emit a fenced
block, the code ran and returned correct values. It is not a capability
problem; it is an instruction-compliance problem, and it is the fastest model
in the set.

**Compilation and behaviour fail independently, but not in this run.** The
two `FAIL`s on compilation — `llama3.1:8b` `TS2556` spread argument, the 30B
`TS2352` cast — both produced correct runtime results. The opposite case,
compiling cleanly and then behaving wrongly, was constructed by hand while
developing the verifier and has not yet been produced by a model on these
cases.

## Throughput

Median of 2. Decode ranges span the six cases; prefill varies with prompt
length.

| Model | Decode tok/s | Prefill tok/s | VRAM fit |
|---|---|---|---|
| `llama3.1:8b` | 143–181 | 3261–18546 | fits, 4.9 GB |
| `qwen3:30b-a3b` | 103–112 | 1195–5204 | overflows, 17.3 GB |
| `qwen3:14b` | 77–101 | 2080–6585 | fits, 8.6 GB |
| `devstral:24b` | 29–38 | 17985–27550 | fits, 13.3 GB |

The 30B overflows a 16 GB card. Its prefill floor of 1195 tok/s is the
signature of partial residency: the model does not fit in VRAM, and the
residency penalty is being paid on the context processing.

## Instruction following

`instruction-following` asks for exactly the word `BANANA`, nothing else.

| Model | Response chars | Verdict |
|---|---|---|
| `qwen3:14b` | 6 | pass |
| `devstral:24b` | 6 | pass |
| `llama3.1:8b` | 6 | pass |
| `qwen3:30b-a3b` | 1039–1150 | **fail** |

The three compliant models return `BANANA` and stop. The 30B returns 1039 to
1150 characters of deliberation about a one-word request.

## Reasoning

`reasoning-loadbalancer` asks a multi-constraint latency question, with
`think=true` and a 4000-token budget.

| Model | Response chars | Think chars | State |
|---|---|---|---|
| `devstral:24b` | 1833–2047 | 0 | answered |
| `llama3.1:8b` | 1960–2370 | 0 | answered |
| `qwen3:14b` | 0 / 1178 | ~16000 | budget consumed by reflection |
| `qwen3:30b-a3b` | 1675 / 0 | 15000+ | budget consumed by reflection |

`devstral:24b` has no thinking mode and answers every time. Both Qwen3 models
spend the entire `num_predict` budget inside `thinking` and come back with
nothing, or with a truncated fragment. The raw transcripts are in `out/raw/`.

This is the most actionable result in the set. If you are running a
reasoning model on a fixed token budget and you do not check for empty
responses, your agent appears to work and silently returns nothing.

## Reproduce

```powershell
git clone https://github.com/Ch4mspec/AI-Models-Benchmark
cd AI-Models-Benchmark
npm install

.\Invoke-Bench.ps1 -Models llama3.1:8b,qwen3:14b,devstral:24b,qwen3:30b-a3b -Repeat 2
.\check-code.ps1
```

## Caveats

- `Repeat = 2`, median reported. Directional, not statistical. Use 5 or more
  before treating a 10% difference as real.
- Default `seed: 0`. Short generations came back byte-identical across
  repeats — `qwen3:14b` returned the same 848 characters with the same prose
  ratio both times. Long ones did not: `qwen3:14b` returned 0 characters on
  one repeat of the reasoning case and 1178 on the next, at the same seed.
  Determinism in Ollama holds per token given identical batch and KV-cache
  state; a long generation crosses enough unstable boundaries to break it.
  Add `-RandomSeed` to vary deliberately.
- Six hand-authored cases, four of them judged by assertions this repository
  wrote. Not a standard, and the author is not neutral.
- `code-auth` is only compiled. Its semantic quality is a human judgement and
  is labelled as one.
- Single machine, single session. These numbers do not transfer. A 24 GB card
  changes the ranking, because the 30B stops overflowing.
- Throughput was recorded with a browser resident but idle on the GPU. Active
  GPU load is what moves the numbers: an earlier session with a browser and a
  game client both computing measured `qwen3:14b` prefill at 869–2366 tok/s
  against 3063–6585 here. Occupied VRAM alone did not.