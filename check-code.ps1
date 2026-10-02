#Requires -Version 5.1
<#
.SYNOPSIS
    Compilation and behaviour checker for LLM output.

.DESCRIPTION
    A throughput figure and a prose ratio say nothing about correctness.
    This script extracts code blocks from an LLM response and verifies them
    for real:

      - TypeScript / JavaScript -> tsc --strict
      - Python                 -> py_compile
      - either                 -> EXECUTED against assertions, if a
                                   matching file exists in tests\

    The execution step is the one that matters. A type-correct endpoint
    returning the wrong status code compiles perfectly. A Python function
    with an off-by-one error compiles perfectly. Only running it catches
    that.

    Behaviour files are matched by test-case name. A raw response named
    qwen3_14b_code-python.run1.out.txt looks for tests\code-python.verify.py.
    If no such file exists the response is only compiled, not executed, and
    the Behaviour column reads "-".

    A model that writes code as free text with no code fence is reported as
    PROSE, not as a syntax error. Counting those as failures measures the
    model's formatting habits, not its ability to write code.

.EXAMPLE
    .\check-code.ps1
    .\check-code.ps1 .\out\raw\qwen3_14b_code-python.run1.out.txt
    .\check-code.ps1 .\out\raw\*.out.txt
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$File,
    [string]$TscPath = "node_modules\typescript\bin\tsc",
    [string]$TestsDir = "tests",
    [switch]$NoExec
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Language families
# ---------------------------------------------------------------------------
$TsLangs = @("typescript", "ts", "tsx", "javascript", "js", "jsx", "mjs", "cjs", "inferred")
$PyLangs = @("python", "py", "python3", "py3")

# ---------------------------------------------------------------------------
# Extraction des blocs de code
# ---------------------------------------------------------------------------
function Get-CodeBlocks {
    param([string]$Text)

    $blocks = [System.Collections.Generic.List[object]]::new()
    # return @(...) : sous StrictMode, une collection a un seul element est
    # renvoyee comme scalaire par le pipeline et .Count leve une exception.
    if ([string]::IsNullOrWhiteSpace($Text)) { return @($blocks) }

    # Bloc protege (le plus fiable) ou simple, avec ou sans lang.
    $rx = '(?ms)^```[ \t]*(?<lang>[\w+#-]*)[ \t]*\r?\n(?<code>.*?)^```'
    foreach ($m in [regex]::Matches($Text, $rx)) {
        $blocks.Add([PSCustomObject]@{
            Lang = $m.Groups['lang'].Value.ToLower()
            Code = $m.Groups['code'].Value
        })
    }

    # Modeles qui n'imitent pas les fences mais balisent par ``` inline partout :
    # on isole le premier bloc s'il n'y en a aucun.
    if ($blocks.Count -eq 0 -and $Text -match '(?m)^\s*(import|from|const|function|export|#include|package|def |class )') {
        $blocks.Add([PSCustomObject]@{ Lang = "inferred"; Code = $Text })
    }
    return @($blocks)
}

# Regroupe les blocs d'une famille de langages en une seule unite : on veut
# "le fichier compile-t-il", pas "chaque bloc compile-t-il isolement"
# (trop strict, fausse negatif quand un modele repartit une classe en deux
# fences).
function Get-LangSource {
    param([object[]]$Blocks, [string[]]$Langs)
    $sel = @($Blocks | Where-Object { $Langs -contains $_.Lang })
    if ($sel.Count -eq 0) { return $null }
    return ($sel | ForEach-Object { $_.Code }) -join "`n"
}

# Un fichier de reponse s'appelle <modele>_<cas>.run<N>.out.txt. Le modele
# change, le cas ne change pas, mais PowerShell ne donne pas le moyen de
# separer les deux a coup sur : BaseName vaut par exemple
# "qwen3_14b_code-python.run1.out". On retrouve donc le cas en cherchant quel
# nom de test est un SUFFIX de BaseName. Ca evite d'avoir a maintenir un
# manifeste a jour, et ca marche aussi sur des fichiers fournis a la main.
function Resolve-Verifier {
    param([string]$BaseName, [string]$TestsPath, [string]$Ext)

    if (-not (Test-Path $TestsPath)) { return $null }

    $candidates = @(Get-ChildItem -Path $TestsPath -Filter "*.$Ext" -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '\.verify\.' })
    if ($candidates.Count -eq 0) { return $null }

    # "qwen3_14b_code-python.run1.out" -> "qwen3_14b_code-python"
    $core = $BaseName -replace '\.run\d+\.out$', ''

    # Correspondance exacte d'abord.
    $exact = $candidates | Where-Object { ($_.Name -replace '\.verify\.\w+$', '') -eq $core }
    if ($exact) { return @($exact)[0] }

    # Puis suffixe, du nom de test le plus long au plus court, pour que
    # "code-python" l'emporte sur un eventual "python" plus generique.
    foreach ($c in ($candidates | Sort-Object { $_.Name.Length } -Descending)) {
        $stem = $c.Name -replace '\.verify\.\w+$', ''
        if ($core -match ("(^|_)" + [regex]::Escape($stem) + "$")) { return $c }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Localisation de l'interpreteur Python
# ---------------------------------------------------------------------------
function Test-PyRuns {
    param([string]$Exe, [string[]]$PreArgs = @())
    # Le stub python.exe du Microsoft Store ecrit sur stderr et sort en erreur.
    # Sous $ErrorActionPreference = "Stop", cela devient une exception
    # terminante avant meme qu'on ait pu lire le code de sortie : la sonde
    # doit donc neutraliser la preference le temps du test.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @PreArgs -c "import sys" 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-PythonExe {
    $found = @()
    foreach ($n in @("python.exe", "python3.exe", "py.exe")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { $found += $c }
    }
    foreach ($c in $found) {
        # On ignore le alias du Store : il "existe" mais n'est pas un Python.
        if ($c.Source -match "WindowsApps") { continue }
        if ($c.Name -eq "py.exe") {
            if (Test-PyRuns -Exe $c.Source -PreArgs @("-3")) { return "$($c.Source) -3" }
        } elseif (Test-PyRuns -Exe $c.Source) {
            return $c.Source
        }
    }

    # winget --scope user installe ici sans toucher au PATH de la session.
    $guess = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" `
                           -ErrorAction SilentlyContinue |
               Sort-Object FullName -Descending | Select-Object -First 1
    if ($guess -and (Test-PyRuns -Exe $guess.FullName)) { return $guess.FullName }

    return $null
}

$PythonExe = $null
$PythonProbed = $false

function Get-Py {
    if (-not $PythonProbed) {
        $script:PythonExe = Get-PythonExe
        $script:PythonProbed = $true
        if ($PythonExe) {
            Write-Host "Python: $PythonExe" -ForegroundColor DarkGray
        } else {
            Write-Warning "Python not found. Python cases will report N/A. Install with: winget install Python.Python.3.12"
        }
    }
    return $PythonExe
}

# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------
function Test-TsCompile {
    param([string]$Source, [string]$WorkDir)

    if (-not (Test-Path $TscPath)) {
        return [PSCustomObject]@{
            Ok = $null; Errors = 0
            Notes = "typescript absent: run npm install in the project folder"
            Diagnostics = @()
        }
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $srcPath = Join-Path $WorkDir "candidate.ts"
    $Source | Out-File $srcPath -Encoding utf8

    # Chemins ABSOLUS : tsc resout "candidate.ts" depuis le repertoire courant
    # du processus, pas depuis $WorkDir, et le fichier n'est alors pas trouve
    # (TS6053) meme si l'ecriture a reussi.
    $absTsc = (Resolve-Path $TscPath).Path
    $absSrc = (Resolve-Path $srcPath).Path

    # @types/node est requis : sans lui, tout usage de `process` ou
    # `require` remonte TS2591 et ferait echouer du code parfaitement
    # correct. Ce n'est pas un defaut du modele, c'est un manque d'ambiance.
    $opts = @(
        "--noEmit", "--strict", "--target", "es2022",
        "--module", "esnext", "--moduleResolution", "bundler",
        "--skipLibCheck", "--esModuleInterop",
        "--typeRoots", (Join-Path $PSScriptRoot "node_modules\@types"),
        "--types", "node",
        $absSrc
    )

    $out = & node $absTsc @opts 2>&1 | Out-String
    $code = $LASTEXITCODE

    $diags = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match "error TS\d+" -or $line -match "^\s*\d+:" -or $line -match ":[0-9]+:[0-9]+") {
            $diags += $line.Trim()
        }
    }
    # tsc compte TS2307 (module absent) comme erreur : on l'ecarte, sinon
    # tout echoue puisque les dependances npm ne sont pas installees.
    $real = @($diags | Where-Object { $_ -notmatch "TS2307" -and $_ -notmatch "Cannot find module" })

    return [PSCustomObject]@{
        Ok         = ($code -eq 0 -or $real.Count -eq 0)
        Errors     = $real.Count
        Notes      = if ($code -eq 0) { "compiles" } else { "errors excluding dependencies: $($real.Count)" }
        Diagnostics = @($real | Select-Object -First 8)
    }
}

function Test-PyCompile {
    param([string]$Source, [string]$WorkDir)

    $py = Get-Py
    if (-not $py) {
        return [PSCustomObject]@{
            Ok = $null; Errors = 0; Notes = "python interpreter not found"
            Diagnostics = @()
        }
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $srcPath = Join-Path $WorkDir "candidate.py"
    $Source | Out-File $srcPath -Encoding utf8

    $out = Invoke-Expression "$py -m py_compile `"$srcPath`"" 2>&1 | Out-String
    $code = $LASTEXITCODE

    $diags = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { $diags += $line.Trim() }
    }

    return [PSCustomObject]@{
        Ok         = ($code -eq 0)
        Errors     = if ($code -eq 0) { 0 } else { @($diags).Count }
        Notes      = if ($code -eq 0) { "compiles" } else { "syntax error" }
        Diagnostics = @($diags | Select-Object -First 8)
    }
}

# ---------------------------------------------------------------------------
# Execution contre les assertions
# ---------------------------------------------------------------------------
# On colle le code du modele et les assertions dans un seul fichier, puis on
# l'execute. Le code de verification sort avec 0 si tout passe, 1 sinon, en
# imprimant le detail des echecs.
function Test-PyBehaviour {
    param([string]$Source, [string]$Verify, [string]$WorkDir)

    $py = Get-Py
    if (-not $py) {
        return [PSCustomObject]@{ Ok = $null; Notes = "python interpreter not found"; Diagnostics = @() }
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $srcPath = Join-Path $WorkDir "candidate.py"
    ($Source + "`n`n" + $Verify) | Out-File $srcPath -Encoding utf8

    $out = Invoke-Expression "$py `"$srcPath`"" 2>&1 | Out-String
    $code = $LASTEXITCODE

    $diags = @()
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { $diags += $line.TrimEnd() }
    }

    # Exit 0 sans VERIFY_OK : le code du modele a pu appeler sys.exit()
    # avant d'atteindre les assertions. Traite comme un echec, pas un passe.
    if ($code -eq 0 -and ($out -notmatch "VERIFY_OK")) {
        return [PSCustomObject]@{
            Ok = $false
            Notes = "exited before assertions ran"
            Diagnostics = @($diags | Select-Object -First 8)
        }
    }

    return [PSCustomObject]@{
        Ok         = ($code -eq 0)
        Notes      = if ($code -eq 0) { "all assertions passed" } else { "assertions failed" }
        Diagnostics = @($diags | Select-Object -First 12)
    }
}

function Test-TsBehaviour {
    param([string]$Source, [string]$Verify, [string]$WorkDir)

    if (-not (Test-Path $TscPath)) {
        return [PSCustomObject]@{ Ok = $null; Notes = "typescript absent"; Diagnostics = @() }
    }

    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $srcPath = Join-Path $WorkDir "candidate.ts"
    ($Source + "`n`n" + $Verify) | Out-File $srcPath -Encoding utf8

    $absTsc = (Resolve-Path $TscPath).Path
    $absSrc = (Resolve-Path $srcPath).Path

    # Emission cette fois : on a besoin de JavaScript pour node.
    #
    # Le code de sortie de tsc est ici IGNORE deliberement. On ne verifie pas
    # les types, on verifie le comportement : `typeof chunk` sur un identifiant
    # absent est legal en JavaScript mais remonte TS2304 en TypeScript, et on
    # ne veut pas qu'une assertion trop tysee transforme une vraie erreur
    # d'execution en erreur de compilation. Les erreurs de type du modele, elles,
    # sont deja sanctionnees par l'etape de compilation stricte.
    $opts = @(
        "--target", "es2022", "--module", "esnext", "--moduleResolution", "bundler",
        "--skipLibCheck", "--esModuleInterop", "--outDir", $WorkDir,
        "--typeRoots", (Join-Path $PSScriptRoot "node_modules\@types"),
        "--types", "node",
        $absSrc
    )
    $out = & node $absTsc @opts 2>&1 | Out-String

    $jsPath = Join-Path $WorkDir "candidate.js"
    if (-not (Test-Path $jsPath)) {
        $syntax = @(($out -split "`r?`n") | Where-Object { $_ -match "error TS" } |
                     Select-Object -First 8) | ForEach-Object { $_.Trim() }
        return [PSCustomObject]@{
            Ok = $false; Notes = "no JavaScript emitted, code does not parse"
            Diagnostics = @($syntax)
        }
    }

    # Le module compile en ESM : node refuse un .js avec "type": "module"
    # absent dans le nearest package.json.
    '{ "type": "module" }' | Out-File (Join-Path $WorkDir "package.json") -Encoding utf8

    $run = & node $jsPath 2>&1 | Out-String
    $code = $LASTEXITCODE

    $diags = @()
    foreach ($line in ($run -split "`r?`n")) {
        if ($line.Trim()) { $diags += $line.TrimEnd() }
    }

    if ($code -eq 0 -and ($run -notmatch "VERIFY_OK")) {
        return [PSCustomObject]@{
            Ok = $false; Notes = "exited before assertions ran"
            Diagnostics = @($diags | Select-Object -First 8)
        }
    }

    return [PSCustomObject]@{
        Ok         = ($code -eq 0)
        Notes      = if ($code -eq 0) { "all assertions passed" } else { "assertions failed" }
        Diagnostics = @($diags | Select-Object -First 12)
    }
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
# Sans argument, on regarde par defaut dans le dossier de sortie du harnais.
# Avant, PowerShell affichait une invite interactive et un oubli produisait
# un chemin incomprehensible du genre "check-code.ps1 .\out\raw".
if (-not $File) {
    $File = Join-Path $PSScriptRoot "out\raw\*.out.txt"
    if (-not (Test-Path $File)) {
        throw "No argument given and no output found. Run Invoke-Bench.ps1 first, or pass a path: .\check-code.ps1 .\out\raw\*.out.txt"
    }
    Write-Host "Scanning $File (default)" -ForegroundColor DarkGray
}

$files = @(Get-ChildItem -Path $File -File)
if ($files.Count -eq 0) { throw "No files found: $File" }

$testsPath = if ([System.IO.Path]::IsPathRooted($TestsDir)) { $TestsDir } else { Join-Path $PSScriptRoot $TestsDir }
$workRoot = Join-Path $PSScriptRoot "out\verify"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$rows = @()
foreach ($f in $files) {
    $text = Get-Content $f.FullName -Raw
    $blocks = @(Get-CodeBlocks $text)

    $langs = @($blocks | ForEach-Object { $_.Lang } | Where-Object { $_ } |
               Select-Object -Unique) -join "+"

    # Un bloc "inferred" signifie qu'aucun fence ``` n'a ete trouve et qu'on
    # a suppose le code dans le texte libre. Dans ce cas compiler n'a aucun
    # sens : on mesure du monologue. On le signale au lieu de compter
    # des centaines d'erreurs de syntaxe qui ne disent rien du modele.
    $noFence = ($blocks.Count -gt 0 -and $blocks[0].Lang -eq "inferred")

    $tsSource = Get-LangSource $blocks $TsLangs
    $pySource = Get-LangSource $blocks $PyLangs

    $verifyPy = Resolve-Verifier -BaseName $f.BaseName -TestsPath $testsPath -Ext "py"
    $verifyTs = Resolve-Verifier -BaseName $f.BaseName -TestsPath $testsPath -Ext "ts"
    $case = if ($verifyPy) { $verifyPy.Name -replace '\.verify\.\w+$', '' }
            elseif ($verifyTs) { $verifyTs.Name -replace '\.verify\.\w+$', '' }
            else { ($f.BaseName -replace '\.run\d+\.out$', '') }

    $workDir = Join-Path $workRoot $f.BaseName

    $lang = "none"
    if ($tsSource) { $lang = "typescript" }
    elseif ($pySource) { $lang = "python" }

    $compile = "N/A"
    $behaviour = "-"
    $note = "no verifiable block"
    $diags = @()
    $errors = 0

    if ($noFence) {
        $compile = "PROSE"
        $note = "NO CODE BLOCK: response entirely prose"
    } elseif ($tsSource) {
        $r = Test-TsCompile -Source $tsSource -WorkDir $workDir
        $compile = switch ($r.Ok) { $true { "PASS" } $false { "FAIL" } $null { "N/A" } }
        $note = $r.Notes
        $errors = $r.Errors
        $diags = @($r.Diagnostics)

        if (-not $NoExec -and $verifyTs) {
            $b = Test-TsBehaviour -Source $tsSource -Verify (Get-Content $verifyTs.FullName -Raw) -WorkDir (Join-Path $workDir "exec")
            $behaviour = switch ($b.Ok) { $true { "OK" } $false { "FAIL" } $null { "N/A" } }
            if ($behaviour -ne "OK") { $diags = @($b.Diagnostics) }
            $note = $b.Notes
        }
    } elseif ($pySource) {
        $r = Test-PyCompile -Source $pySource -WorkDir $workDir
        $compile = switch ($r.Ok) { $true { "PASS" } $false { "FAIL" } $null { "N/A" } }
        $note = $r.Notes
        $errors = $r.Errors
        $diags = @($r.Diagnostics)

        if (-not $NoExec -and $verifyPy) {
            $b = Test-PyBehaviour -Source $pySource -Verify (Get-Content $verifyPy.FullName -Raw) -WorkDir (Join-Path $workDir "exec")
            $behaviour = switch ($b.Ok) { $true { "OK" } $false { "FAIL" } $null { "N/A" } }
            if ($behaviour -ne "OK") { $diags = @($b.Diagnostics) }
            $note = $b.Notes
        }
    }

    $source = if ($tsSource) { $tsSource } elseif ($pySource) { $pySource } else { $null }

    $rows += [PSCustomObject]@{
        File      = $f.Name
        Case      = $case
        Lang      = $lang
        Blocks    = $blocks.Count
        Lines     = if ($source) { ($source -split "`n").Count } else { 0 }
        Compile   = $compile
        Behaviour = $behaviour
        Errors    = $errors
        Note      = $note
    }

    if ($diags.Count -gt 0) {
        Write-Host "  [$($f.Name)]" -ForegroundColor DarkGray
        $diags | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

Write-Host ""
$rows | Format-Table -AutoSize | Out-String -Width 220 | Write-Host

$checked = @($rows | Where-Object { $_.Compile -ne "N/A" })
if ($checked.Count -gt 0) {
    $ok = @($checked | Where-Object { $_.Compile -eq "PASS" }).Count
    Write-Host ""
    Write-Host "Compilation: $ok / $($checked.Count) files valid under strict checking" -ForegroundColor Cyan

    $ran = @($rows | Where-Object { $_.Behaviour -ne "-" -and $_.Behaviour -ne "N/A" })
    if ($ran.Count -gt 0) {
        $behaved = @($ran | Where-Object { $_.Behaviour -eq "OK" }).Count
        Write-Host "Behaviour:   $behaved / $($ran.Count) passed the assertions" -ForegroundColor Cyan
    }
}

$rows | Export-Csv -NoTypeInformation `
    -Path (Join-Path $PSScriptRoot "out\tsc-latest.csv") -Encoding utf8