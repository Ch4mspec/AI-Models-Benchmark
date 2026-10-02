#Requires -Version 5.1
<#
.SYNOPSIS
    Reproducible benchmark harness for local LLMs (Ollama).

.DESCRIPTION
    Measures throughput, instruction obedience and token cost across a set of
    models on a given machine, then produces a Markdown report plus
    JSON/CSV data.

    Caveats drawn from real measurements:
      - The num_predict budget is SHARED between reflection (thinking) and
        response. A budget set too low can return an empty response.
      - done_reason = "length" means TRUNCATED output, not finished.
      - Some models accept think=true only; forcing think=false puts them
        in an unsupported state and degrades output.
      - A model larger than available VRAM overflows into system RAM.

.PARAMETER Models
    Models to test. Defaults to all installed Ollama models.

.PARAMETER Tests
    Subset of test cases to run. Defaults to all.

.PARAMETER Repeat
    Runs per test case. The median is reported. Every repeat is written to
    disk under out\raw with its index, so check-code.ps1 scores all of them
    and not just one sample.

.PARAMETER KeepRaw
    Keep the previous contents of out\raw instead of clearing it. Useful to
    compare two configurations side by side. Without it, stale responses from
    an earlier run would be scored together with the new ones.

.PARAMETER RandomSeed
    Send a different seed on each repeat. Ollama defaults to seed 0, which
    makes generation deterministic: without this, every repeat returns the
    identical response and -Repeat only measures clock and VRAM noise. Turn
    it on when you want to know whether a result is stable across samples
    rather than reproducible for a single one.

.EXAMPLE
    .\Invoke-Bench.ps1
    .\Invoke-Bench.ps1 -Models qwen3:14b,devstral:24b -Repeat 3
    .\Invoke-Bench.ps1 -Tests code-python,debug-chunk -KeepRaw
    .\Invoke-Bench.ps1 -Repeat 5 -RandomSeed
#>

[CmdletBinding()]
param(
    [string[]]$Models,
    [string[]]$Tests,
    [int]$Repeat = 2,
    [int]$Context = 8192,
    [string]$OutDir = ".\out",
    [switch]$SkipWarmup,
    [switch]$KeepRaw,
    [switch]$RandomSeed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Test cases. Each case is independent: that is what makes a report
# interpretable. Two measurements are never mixed into one run.
# ---------------------------------------------------------------------------
$TestCases = @(
    @{
        Name       = "code-auth"
        Category   = "code"
        NumPredict = 1200
        Think      = $false
        Prompt     = @"
Write a complete, production-ready TypeScript + Express endpoint implementing
POST /auth/register with:
- strict input validation (email format, password >= 12 chars)
- bcrypt hashing (cost 12)
- JWT access token (15 min) + refresh token (httpOnly cookie, 7 days)
- persistence via Prisma
- rate limiting per IP
- proper status codes and a uniform JSON error envelope
Return ONLY the code inside a single code block. No prose before or after.
Start your reply with an import statement.
"@
    }
    @{
        Name       = "code-utility"
        Category   = "code"
        NumPredict = 800
        Think      = $false
        Prompt     = @"
Implement a TypeScript function `chunk<T>(items: T[], size: number): T[][]` that
splits an array into chunks, plus `debounce` and `memoize` utilities.
Return ONLY code inside a single code block. No prose before or after.
"@
    }
    @{
        Name       = "code-python"
        Category   = "code"
        NumPredict = 900
        Think      = $false
        Prompt     = @"
Implement this function in Python:

    def merge_intervals(intervals):
        \"\"\"Merge overlapping OR touching intervals and return them sorted.\"\"\"

intervals is a list of (start, end) integer tuples. Touching means
[(1, 4), (4, 5)] merges into [(1, 5)]. Input may be unsorted. An empty
list returns an empty list.

Return ONLY code inside a single code block. No prose before or after.
"@
    }
    @{
        Name       = "debug-chunk"
        Category   = "debug"
        NumPredict = 900
        Think      = $false
        Prompt     = @"
This Python function has bugs. Fix it.

    def chunk(items, size):
        return [items[i:i + size - 1] for i in range(0, len(items), size)]

Requirements:
- chunk([1,2,3,4,5], 2) must return [[1,2],[3,4],[5]]
- chunk([], 3) must return []
- chunk([1,2], 5) must return [[1,2]]
- size <= 0 must raise ValueError

Return ONLY the complete corrected function inside a single code block.
No prose before or after.
"@
    }
    @{
        Name       = "reasoning-loadbalancer"
        Category   = "reasoning"
        NumPredict = 4000
        Think      = $true
        Prompt     = "I have 3 servers behind a load balancer. Server A: 10ms, Server B: 50ms, Server C: 10ms. One in 1000 requests must go to B. What is the average added latency if the LB is least-connections vs random?"
    }
    @{
        Name       = "instruction-following"
        Category   = "obey"
        NumPredict = 600
        Think      = $false
        Prompt     = "Reply with exactly the word: BANANA. No punctuation, no quotes, no other text."
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Get-OllamaModels {
    try {
        $list = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -Method Get -TimeoutSec 5
        return @($list.models | ForEach-Object { $_.name })
    } catch {
        throw "Serveur Ollama injoignable sur localhost:11434. Lancez 'ollama serve'."
    }
}

function Get-GpuProfile {
    $profile = [ordered]@{
        GpuName    = "aucun (CPU/RAM uniquement)"
        VramTotalGB = 0.0
        VramFreeGB  = 0.0
        Cuda        = $false
    }
    try {
        $smi = & nvidia-smi `
            --query-gpu=name,memory.total,memory.used,memory.free `
            --format=csv,noheader,nounits 2>$null
        if ($smi) {
            $parts = ($smi | Select-Object -First 1) -split ',\s*'
            $profile.GpuName    = $parts[0].Trim()
            $profile.VramTotalGB = [math]::Round([double]$parts[1] / 1024, 1)
            $profile.VramFreeGB  = [math]::Round([double]$parts[3] / 1024, 1)
            $profile.Cuda        = $true
        }
    } catch { }
    return [PSCustomObject]$profile
}

function Get-ModelMeta {
    param([string]$Name)
    $r = Invoke-RestMethod -Uri "http://localhost:11434/api/show" -Method Post `
            -Body (@{ model = $Name } | ConvertTo-Json) `
            -ContentType "application/json"

    $thinkSupported = $false
    $thinkDefault   = $null
    if ($r.PSObject.Properties.Name -contains "thinking") {
        $vals = @($r.thinking.values)
        $thinkSupported = ($vals -contains $false) -or ($vals -contains $true)
        $thinkDefault   = $r.thinking.default
    }

    $ctxProp = $r.model_info.PSObject.Properties |
               Where-Object { $_.Name -like "*context_length*" } | Select-Object -First 1

    return [PSCustomObject]@{
        Name          = $Name
        Family        = $r.details.family
        Params        = $r.details.parameter_size
        Quant         = $r.details.quantization_level
        Capabilities  = @($r.capabilities)
        ThinkSupport  = $thinkSupported
        ThinkDefault  = $thinkDefault
        MaxContext    = if ($ctxProp) { [int64]$ctxProp.Value } else { 0 }
        SizeBytes     = 0
    }
}

# Mesure la part de prose dans une reponse : un modele qui bavarde avant de
# coder est un modele qui coute des tokens sans produire de valeur.
function Get-ProseRatio {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 1.0 }
    $lines = $Text -split "`n"
    $code = @($lines | Where-Object {
        $_ -match '\S' -and $_ -notmatch '^\s*(//|\*|/\*|#)' -and
        $_ -notmatch '^(We|Now|Let|Here|This|The|However|Note|But|So|First|Step)'
    }).Count
    return [math]::Round(1.0 - ($code / [math]::Max($lines.Count, 1)), 3)
}

function Invoke-Measured {
    param(
        [string]$Model,
        [hashtable]$Case,
        [int]$Context,
        [bool]$SupportsThink = $true,
        [int]$Seed = 0
    )

    $body = @{
        model   = $Model
        prompt  = $Case.Prompt
        stream  = $false
        options = @{
            num_predict = $Case.NumPredict
            num_ctx     = $Context
            temperature = 0.2
            seed        = $Seed
        }
    }
    # Always send think explicitly when the model supports it. Omitting it
    # leaves the model default in effect (Qwen3 defaults to true), which sends
    # the whole num_predict budget into reflection and returns an empty
    # response. Cf. qwen3:30b-a3b, which accepts only true: there we send
    # nothing, because the default is the only valid state.
    $body["think"] = if ($SupportsThink) { [bool]$Case.Think } else { $null }
    if ($null -eq $body["think"]) { $body.Remove("think") }

    $json = $body | ConvertTo-Json -Depth 8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post `
            -Body $json -ContentType "application/json" -TimeoutSec 1800
    $sw.Stop()

    $thinkChars = 0
    if (($r.PSObject.Properties.Name -contains "thinking") -and $r.thinking) {
        $thinkChars = $r.thinking.Length
    }
    $evalSec = if ($r.eval_duration -gt 0) { $r.eval_duration / 1e9 } else { 0 }

    return [PSCustomObject]@{
        Model        = $Model
        Test         = $Case.Name
        Category     = $Case.Category
        WallSec      = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        PromptTokens = $r.prompt_eval_count
        PrefillTps   = if ($r.prompt_eval_duration -gt 0) {
                            [math]::Round($r.prompt_eval_count / ($r.prompt_eval_duration / 1e9), 1)
                        } else { 0 }
        DecodeTps    = if ($evalSec -gt 0) { [math]::Round($r.eval_count / $evalSec, 2) } else { 0 }
        OutTokens    = $r.eval_count
        ThinkChars   = $thinkChars
        ResponseChars= $r.response.Length
        ProseRatio   = Get-ProseRatio $r.response
        Truncated    = ($r.done_reason -eq "length")
        EmptyOutput  = [string]::IsNullOrWhiteSpace($r.response)
        Output       = $r.response
        # Sous StrictMode, toucher une propriete absente leve une exception :
        # on teste l'existence avant d'acceder a .thinking.
        Thinking     = if (($r.PSObject.Properties.Name -contains "thinking") -and $r.thinking) { $r.thinking } else { "" }
    }
}

function Get-Median {
    param([double[]]$Values)
    # @() : sous StrictMode, un pipeline a un seul element renvoie un scalaire
    # sans propriete .Count, ce qui fait echouer le script.
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return 0 }
    $m = [math]::Floor($s.Count / 2)
    if ($s.Count % 2 -eq 1) { return $s[$m] }
    return ($s[$m - 1] + $s[$m]) / 2
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
if (-not $Models) { $Models = Get-OllamaModels }
if ($Tests) {
    $TestCases = $TestCases | Where-Object { $Tests -contains $_.Name }
    if (-not $TestCases) { throw "Aucun cas ne correspond a -Tests. Disponibles : $((Get-OllamaModels) -join ', ')" }
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$gpu = Get-GpuProfile
Write-Host "`n=== ENVIRONMENT ===" -ForegroundColor Cyan
Write-Host "GPU    : $($gpu.GpuName)"
Write-Host "VRAM   : $($gpu.VramFreeGB) GB free / $($gpu.VramTotalGB) GB total"
Write-Host "Models : $($Models -join ', ')"
Write-Host "Repeats: $Repeat   Context: $Context`n"

$metas = @{}
foreach ($m in $Models) {
    try { $metas[$m] = Get-ModelMeta -Name $m }
    catch { Write-Warning "Unreadable metadata for $m : $_" }
}

$all = @()
$rawRuns = [ordered]@{}
foreach ($m in $Models) {
    $meta = $metas[$m]
    if ($meta) {
        $fit = if ($meta.Params -and $gpu.VramTotalGB -gt 0) {
            "OK" } else { "?" }
        Write-Host "--- $m --- [$fit]" -ForegroundColor Yellow
        Write-Host "    thinking=$($meta.ThinkSupport) default=$($meta.ThinkDefault) ctx=$($meta.MaxContext) q=$($meta.Quant)"
    }

    foreach ($case in $TestCases) {
        if (-not $SkipWarmup -and -not $meta) {
            Invoke-RestMethod -Uri "http://localhost:11434/api/generate" -Method Post `
                -Body (@{ model = $m; prompt = "ok"; stream = $false; options = @{ num_predict = 1 } } | ConvertTo-Json) `
                -ContentType "application/json" | Out-Null
        }

        $runs = @()
        for ($i = 1; $i -le $Repeat; $i++) {
            try {
                # Ollama uses seed 0 by default, which makes generation
                # deterministic: with -Repeat 2 and no seed, both runs return
                # the identical response and -Repeat only measures clock and
                # VRAM noise, not generation variance. -RandomSeed varies it.
                $seed = if ($RandomSeed) { Get-Random -Minimum 1 -Maximum 2147483647 } else { 0 }
                $runs += Invoke-Measured -Model $m -Case $case -Context $Context `
                            -SupportsThink $(if ($meta) { $meta.ThinkSupport } else { $true }) `
                            -Seed $seed
                $r = $runs[-1]
                # The repeat index is part of the key. Without it every run of
                # the same case overwrote the previous one on disk, so
                # check-code.ps1 only ever saw a single sample per case no
                # matter how high -Repeat was set.
                $rawRuns["$m/$($case.Name).run$i"] = $r
                $flag = if ($r.EmptyOutput) { " [EMPTY]" }
                        elseif ($r.Truncated) { " [TRUNCATED]" }
                        else { "" }
                Write-Host ("    {0} #{1}: {2} tok/s  {3}s  out={4}car  prose={5}{6}" -f `
                    $case.Name, $i, $r.DecodeTps, $r.WallSec, $r.ResponseChars, $r.ProseRatio, $flag)
            } catch {
                Write-Warning "    $($case.Name) #$i echoue : $_"
            }
        }

        if ($runs.Count -gt 0) {
            $all += [PSCustomObject]@{
                Model         = $m
                Test          = $case.Name
                Category      = $case.Category
                ThinkRequested= $case.Think
                DecodeTps     = Get-Median ($runs | ForEach-Object { $_.DecodeTps })
                PrefillTps    = Get-Median ($runs | ForEach-Object { $_.PrefillTps })
                WallSec       = Get-Median ($runs | ForEach-Object { $_.WallSec })
                OutTokens     = Get-Median ($runs | ForEach-Object { $_.OutTokens })
                ThinkChars    = Get-Median ($runs | ForEach-Object { $_.ThinkChars })
                ResponseChars = Get-Median ($runs | ForEach-Object { $_.ResponseChars })
                ProseRatio    = Get-Median ($runs | ForEach-Object { $_.ProseRatio })
                # A failure on any repeat is a failure of the model, not of
                # one unlucky sample. Reporting only run 1 would let a model
                # score 2/2 on a case it produces correctly half the time.
                Truncated     = [bool](@($runs | Where-Object { $_.Truncated }).Count)
                EmptyOutput   = [bool](@($runs | Where-Object { $_.EmptyOutput }).Count)
                Runs          = $runs.Count
            }
        }
    }
    Write-Host ""
}

# Ecriture des sorties completes pour inspection qualitative.
# Indispensable : les chiffres ne suffisent pas a juger la qualite du code.
$rawDir = Join-Path $OutDir "raw"
New-Item -ItemType Directory -Force -Path $rawDir | Out-Null

# Le dossier brut est vide auDepart de chaque execution. Sans cela, un fichier
# d'une execution precedente reste sur disque et se retrouve note par
# check-code.ps1 a cote des nouveaux : le tableau affiche alors un melange de
# deux series de mesures, sans aucun moyen de les distinguer. -KeepRaw permet
# de conserver l'historique quand on veut comparer deux configurations.
if ($KeepRaw) {
    Write-Host "Keeping existing raw output (-KeepRaw)." -ForegroundColor DarkGray
} else {
    Get-ChildItem -Path $rawDir -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force }
}

foreach ($pair in $rawRuns.GetEnumerator()) {
    $slug = ($pair.Key -replace '[^A-Za-z0-9._-]', '_')
    $pair.Value.Output     | Out-File (Join-Path $rawDir "$slug.out.txt")  -Encoding utf8
    $pair.Value.Thinking  | Out-File (Join-Path $rawDir "$slug.think.txt") -Encoding utf8
}

$stamp = Get-Date -Format "yyyyMMdd-HHmm"
$all | Export-Csv -NoTypeInformation -Path (Join-Path $OutDir "results-$stamp.csv") -Encoding utf8
$all | Export-Csv -NoTypeInformation -Path (Join-Path $OutDir "results-latest.csv") -Encoding utf8

$all | ConvertTo-Json -Depth 5 |
    Out-File (Join-Path $OutDir "results-latest.json") -Encoding utf8

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$report = @()
$report += "# Benchmark report"
$report += ""
$report += "- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$report += "- Machine: $($gpu.GpuName), $($gpu.VramTotalGB) GB VRAM"
$report += "- Context: $Context tokens   |   Repeats: $Repeat (median reported)"
$report += ""
$report += "## Capabilities"
$report += ""
$report += "| Model | Params | Quant | Thinking | Default | Max context |"
$report += "|---|---|---|---|---|---|"
foreach ($m in $Models) {
    if (-not $metas[$m]) { continue }
    $x = $metas[$m]
    $report += "| ``$($m)`` | $($x.Params) | $($x.Quant) | $($x.ThinkSupport) | $($x.ThinkDefault) | $($x.MaxContext) |"
}
$report += ""
$report += "## Measurements"
$report += ""
$report += "| Model | Test | Decode tok/s | Prefill tok/s | Wall | Out tokens | Think chars | Response chars | Prose | State |"
$report += "|---|---|---|---|---|---|---|---|---|---|"
foreach ($r in $all) {
    $state = if ($r.EmptyOutput) { "**EMPTY**" }
             elseif ($r.Truncated) { "**TRUNCATED**" }
             else { "ok" }
    $report += "| ``$($r.Model)`` | $($r.Test) | $($r.DecodeTps) | $($r.PrefillTps) | $($r.WallSec)s | $($r.OutTokens) | $($r.ThinkChars) | $($r.ResponseChars) | $($r.ProseRatio) | $state |"
}
$report += ""
$report += "## Reading"
$report += ""
$report += "- **EMPTY** : the num_predict budget was consumed entirely by reflection, or the model refused to produce. Increase the budget."
$report += "- **TRUNCATED** : `done_reason = length`. The response is incomplete, so the measurement is not usable as-is."
$report += "- **Prose** : share of non-code lines in the response. Higher means the model narrates before producing."

$report | Out-File (Join-Path $OutDir "report-$stamp.md") -Encoding utf8
Copy-Item (Join-Path $OutDir "report-$stamp.md") (Join-Path $OutDir "report-latest.md") -Force

Write-Host "=== RESULTS ===" -ForegroundColor Green
$all | Select-Object Model, Test, DecodeTps, PrefillTps, WallSec, ProseRatio, Truncated, EmptyOutput |
    Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "Report: $(Join-Path $OutDir 'report-latest.md')" -ForegroundColor Green
