[CmdletBinding()]
param(
  [string]$CacheDir = ".cache/belgi",
  [string]$OutDirBase = "_out"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Assert-CleanWorktree {
  param(
    [Parameter(Mandatory=$true)][string]$Label
  )

  $null = Get-Command git -ErrorAction Stop
  $status = & git status --porcelain
  if ($LASTEXITCODE -ne 0) { throw "git status failed ($Label)" }

  if ($status -and $status.Count -gt 0) {
    Write-Host "ERROR: Git working tree is not clean ($Label)." -ForegroundColor Red
    Write-Host "These changes will cause Gate R to fail with FR-SUPPLYCHAIN-CHANGE-UNACCOUNTED." -ForegroundColor Red
    $status | ForEach-Object { Write-Host "  $_" }
    throw "Refusing to run repro with a dirty working tree. Commit/stash changes and retry."
  }
}

Assert-CleanWorktree -Label 'before bootstrap'

& (Join-Path $repoRoot "scripts/bootstrap.ps1") -CacheDir $CacheDir
if ($LASTEXITCODE -ne 0) { throw 'bootstrap failed' }

Assert-CleanWorktree -Label 'after bootstrap'

$here = Join-Path $repoRoot "scripts"
. (Join-Path $here "src/Classes.ps1")
. (Join-Path $here "src/Config.ps1")
. (Join-Path $here "src/Engine.ps1")
. (Join-Path $here "src/Steps.ps1")

$argsHash = @{
  CacheDir=$CacheDir; OutDirBase=$OutDirBase; RunDirName=''; SealedAtUtc=''
  SkipDemo=$true; AllowNoGo=$true; ForceCleanRun=$true
  Resume=$false; NewRun=$false; Auto=$false; Interactive=$false
  RunId=''; RepoRef=''
}

$config = Get-BelgiConfig
$ctx = New-RunContext -Args $argsHash -Config $config -ScriptRoot $here
Initialize-RunContext -Context $ctx -Args $argsHash
$ctx.StepPlan = @($config.Steps)

Invoke-Repro -Context $ctx

Write-Host "Repro test complete." -ForegroundColor Green
