Set-StrictMode -Version Latest

class StepResult {
  [string]$Id
  [string]$Label
  [int]$ExitCode
  [bool]$Succeeded
  [string]$LogPath
  [string]$ErrorMessage
  [datetime]$StartedAt
  [datetime]$EndedAt

  StepResult() {}

  StepResult([string]$id, [string]$label) {
    $this.Id = $id
    $this.Label = $label
    $this.ExitCode = 0
    $this.Succeeded = $false
  }
}

class RunContext {
  # Identity + metadata
  [string]$RunId
  [string]$RepoRef
  [string]$EnvelopeId
  [string]$EnvelopeDescription
  [string]$ExpectedRunner
  [string]$PublicationProfile
  [string]$SealSigner
  [string]$SealedAtUtc

  # Roots
  [string]$PlaygroundRoot
  [string]$RepoRoot
  [string]$BelgiRoot
  [string]$EngineRoot

  # Run foldering
  [string]$OutDirBaseRelPosix
  [string]$RunDirName
  [string]$BelgiRunRelPosix
  [string]$BelgiRunAbs

  # Execution
  [string]$PythonCmd
  [bool]$Interactive
  [bool]$Auto
  [bool]$AllowNoGo
  [bool]$SkipDemo

  # Config + orchestration
  [hashtable]$Config
  [hashtable]$Commands
  [object[]]$StepPlan

  # Canonical repo-relative artifact paths
  [hashtable]$Rel

  RunContext() {
    $this.Config = @{}
    $this.Commands = @{}
    $this.Rel = @{}
    $this.StepPlan = @()
  }

  [string] RepoRelToAbs([string]$repoRel) {
    if ([string]::IsNullOrWhiteSpace($repoRel)) { throw 'repoRel is empty' }
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $nativeRel = ($repoRel -replace '[\\/]', $sep)
    return (Join-Path $this.RepoRoot $nativeRel)
  }
}
