[CmdletBinding()]
param(
  [string]$CacheDir = ".cache/belgi",
  [string]$OutDirBase = "_out"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

& (Join-Path $repoRoot "scripts/bootstrap.ps1") -CacheDir $CacheDir
if ($LASTEXITCODE -ne 0) { throw 'bootstrap failed' }

& (Join-Path $repoRoot "scripts/run_chain.ps1") -CacheDir $CacheDir -OutDirBase $OutDirBase -Auto -ForceCleanRun -SkipDemo -Interactive:$false
if ($LASTEXITCODE -ne 0) { throw 'run_chain failed' }

Write-Host "Smoke test complete." -ForegroundColor Green
