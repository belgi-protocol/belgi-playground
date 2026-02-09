# maintainer marker: bk_ycanary_demo_5e2ad0c1
[CmdletBinding()]
param(
  [string]$CacheDir = ".cache/belgi",
  [string]$OutDirBase = "_out",
  [string]$RunDirName = "",
  [string]$SealedAtUtc = "",
  [switch]$SkipDemo,
  [switch]$AllowNoGo,
  [switch]$ForceCleanRun,
  [switch]$Resume,
  [switch]$NewRun,
  [switch]$Auto,
  [bool]$Interactive = $true
)

$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
. (Join-Path $here "src/Classes.ps1")
. (Join-Path $here "src/Config.ps1")
. (Join-Path $here "src/Engine.ps1")
. (Join-Path $here "src/Steps.ps1")
. (Join-Path $here "src/UI.ps1")

Start-BelgiChain -Args @{
  CacheDir=$CacheDir; OutDirBase=$OutDirBase; RunDirName=$RunDirName; SealedAtUtc=$SealedAtUtc
  SkipDemo=[bool]$SkipDemo; AllowNoGo=[bool]$AllowNoGo; ForceCleanRun=[bool]$ForceCleanRun
  Resume=[bool]$Resume; NewRun=[bool]$NewRun; Auto=[bool]$Auto; Interactive=[bool]$Interactive
  RunId=''; RepoRef=''
} -ScriptRoot $here