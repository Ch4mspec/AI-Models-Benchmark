#Requires -Version 5.1
<#
.SYNOPSIS
    Verificateur de compilation TypeScript pour sorties de LLM.

.DESCRIPTION
    Un taux de debit et un ratio de prose ne disent rien de la correction
    du code. Ce script extrait les blocs de code d'une reponse de LLM et
    les compile reellement avec tsc, en mode strict.

    C'est la seule mesure qui tranche : un modele qui bavarde peut produire
    du code valide, un modele rapide peut produire du code qui ne compile pas.

    Detection automatique du langage pour ne compiler que ce qui est
    pertinent : TypeScript/JavaScript sont verifies, Python/Go/Rust sont
    simplement comptes comme "produits".

.EXAMPLE
    .\check-code.ps1 -File .\out\raw\qwen3_14b_code-utility.out.txt
    .\check-code.ps1 -File .\out\raw\*.out.txt
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$File,
    [string]$TscPath = "node_modules\typescript\bin\tsc"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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
    if ($blocks.Count -eq 0 -and $Text -match '(?m)^\s*(import|const|function|export|#include|package|def )') {
        $blocks.Add([PSCustomObject]@{ Lang = "inferred"; Code = $Text })
    }
    return @($blocks)
}

function Get-TsBlocks {
    param([object[]]$Blocks)
    $ts = @($Blocks | Where-Object {
        $_.Lang -in @("typescript", "ts", "tsx", "javascript", "js", "jsx", "inferred")
    })
    # Regroupe en un seul unite : on veut "le fichier compile-t-il", pas
    # "chaque bloc compile-t-il isolement" (trop strict, fausse negatif).
    if ($ts.Count -eq 0) { return $null }
    return ($ts | ForEach-Object { $_.Code }) -join "`n"
}

# ---------------------------------------------------------------------------
# Compilation stricte
# ---------------------------------------------------------------------------
function Test-Compile {
    param([string]$Source, [string]$WorkDir)

    if (-not (Test-Path $TscPath)) {
        return [PSCustomObject]@{
            Ok        = $null
            Errors    = 0
            Notes     = "typescript absent : lancer npm install dans le dossier du projet"
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
        Notes      = if ($code -eq 0) { "compile" } else { "erreurs hors dependances : $($real.Count)" }
        Diagnostics = $real | Select-Object -First 8
    }
}

# ---------------------------------------------------------------------------
# Execution
# ---------------------------------------------------------------------------
$files = @(Get-ChildItem -Path $File -File)
if ($files.Count -eq 0) { throw "Aucun fichier : $File" }

$workRoot = Join-Path $PSScriptRoot "out\tsc"
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

$rows = @()
foreach ($f in $files) {
    $text = Get-Content $f.FullName -Raw
    $blocks = @(Get-CodeBlocks $text)
    $tsSource = Get-TsBlocks $blocks

    $langs = @($blocks | ForEach-Object { $_.Lang } | Where-Object { $_ } |
               Select-Object -Unique) -join "+"

    # Un bloc "inferred" signifie qu'aucun fence ``` n'a ete trouve et qu'on
    # a suppose le code dans le texte libre. Dans ce cas compiler n'a aucun
    # sens : on mesure du monologue. On le signale au lieu de compter
    # des centaines d'erreurs de syntaxe qui ne disent rien du modele.
    $noFence = ($blocks.Count -gt 0 -and $blocks[0].Lang -eq "inferred")

    $result = if ($noFence) {
        [PSCustomObject]@{
            Ok = $false; Errors = 0
            Notes = "AUCUN BLOC DE CODE : reponse entierement en prose"
            Diagnostics = @()
        }
    } elseif ($tsSource) {
        Test-Compile -Source $tsSource -WorkDir (Join-Path $workRoot $f.BaseName)
    } else {
        [PSCustomObject]@{
            Ok = $null; Errors = 0
            Notes = "pas de bloc TS/JS detecte"
            Diagnostics = @()
        }
    }

    $rows += [PSCustomObject]@{
        Fichier  = $f.Name
        Langs    = if ($langs) { $langs } else { "-" }
        Blocs    = $blocks.Count
        Lignes   = if ($tsSource) { ($tsSource -split "`n").Count } else { 0 }
        Compile  = if ($noFence) { "PROSE" }
                   else { switch ($result.Ok) { $true { "OUI" } $false { "NON" } $null { "N/A" } } }
        Erreurs  = $result.Errors
        Note     = $result.Notes
    }

    # @() : un tableau a un seul element est renvoye comme scalaire, donc
    # .Count leverait une exception sous StrictMode.
    $diag = @($result.Diagnostics)
    if ($diag.Count -gt 0) {
        Write-Host "  [$($f.Name)]" -ForegroundColor DarkGray
        $diag | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

$rows | Format-Table -AutoSize

$tsChecked = @($rows | Where-Object { $_.Compile -ne "N/A" })
if ($tsChecked.Count -gt 0) {
    $ok = @($tsChecked | Where-Object { $_.Compile -eq "OUI" }).Count
    Write-Host ""
    Write-Host "Compilation : $ok / $($tsChecked.Count) fichiers TS/JS valides" -ForegroundColor Cyan
}

$rows | Export-Csv -NoTypeInformation `
    -Path (Join-Path $PSScriptRoot "out\tsc-latest.csv") -Encoding utf8
