Set-StrictMode -Version Latest

function Write-UiLine {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Text,
    [ConsoleColor]$Color = [ConsoleColor]::Gray
  )
  Write-Host $Text -ForegroundColor $Color
}

function Show-Hud {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [string]$Hint
  )

  Clear-Host

  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
  Write-Host '║                    BELGI Chain Runner                        ║' -ForegroundColor Cyan
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
  Write-Host ''
  Write-UiLine ('  RunId: ' + $Context.RunId) DarkGray
  Write-UiLine ('  Repo:  ' + $Context.RepoRoot) DarkGray
  Write-UiLine ('  Run:   ' + $Context.BelgiRunRelPosix) DarkGray
  if ($Hint) { Write-Host ''; Write-UiLine ('  Hint:  ' + $Hint) Yellow }

  Write-Host ''
  Write-Host '  Chain Progress:' -ForegroundColor Cyan
  $parts = @()
  $progress = Get-ChainProgress -Context $Context
  foreach ($s in $Context.StepPlan) {
    $st = $progress.status[$s.Id]
    if ($st -eq 'ok') { $parts += ('[✓ ' + $s.Display + ']') }
    elseif ($st -eq 'fail') { $parts += ('[✗ ' + $s.Display + ']') }
    else { $parts += ('[ ] ' + $s.Display) }
  }
  Write-Host ('  ' + ($parts -join ' -> ')) -ForegroundColor Gray

  Write-Host ''
  Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
  Write-Host '  Commands:' -ForegroundColor Yellow
  Write-Host '    demo     - Guided interactive walkthrough (recommended!)' -ForegroundColor Gray
  Write-Host '    repro    - Run twice and verify determinism' -ForegroundColor Gray
  Write-Host '    all      - Run complete chain automatically' -ForegroundColor Gray
  Write-Host '    resume   - Continue from last successful step' -ForegroundColor Gray
  Write-Host ''
  Write-Host '  Individual Steps:' -ForegroundColor DarkGray
  Write-Host '    c1 | q | r | c3 | seal | s' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '  Other: help | status | paths | quit' -ForegroundColor DarkGray
  Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
  Write-Host ''
}

function Invoke-UiAction {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][scriptblock]$Action
  )

  try {
    & $Action
    return $true
  } catch {
    Write-Host ''
    Write-UiLine ("FAIL: " + $Label) Red
    $msg = $_.Exception.Message
    if ($msg) { Write-UiLine ("  " + $msg) Yellow }
    if ($Context.Interactive) {
      Write-Host ''
      [void](Read-Host 'Press Enter to return to HUD')
    }
    return $false
  }
}

function Get-ChainProgress {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $status = @{}
  $next = '(done)'

  foreach ($s in $Context.StepPlan) { $status[$s.Id] = 'missing' }

  $locked = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  $qv = $Context.RepoRelToAbs($Context.Rel.GateVerdictQ)
  $rv = $Context.RepoRelToAbs($Context.Rel.GateVerdictR)
  $final = $Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)
  $seal = $Context.RepoRelToAbs($Context.Rel.SealManifest)
  $sv = $Context.RepoRelToAbs($Context.Rel.GateVerdictS)

  if (Test-Path $locked) { $status['C1'] = 'ok' } else { $next = 'c1'; return [pscustomobject]@{ status=$status; next=$next } }
  if (Test-Path $qv) { $status['Q'] = (Get-GateVerdictStatus -VerdictPath $qv) } else { $next = 'q'; return [pscustomobject]@{ status=$status; next=$next } }
  if (Test-Path $rv) { $status['R'] = (Get-GateVerdictStatus -VerdictPath $rv) } else { $next = 'r'; return [pscustomobject]@{ status=$status; next=$next } }
  if (Test-Path $final) { $status['C3'] = 'ok' } else { $next = 'c3'; return [pscustomobject]@{ status=$status; next=$next } }
  if (Test-Path $seal) { $status['SEAL'] = 'ok' } else { $next = 'seal'; return [pscustomobject]@{ status=$status; next=$next } }
  if (Test-Path $sv) { $status['S'] = (Get-GateVerdictStatus -VerdictPath $sv) } else { $next = 's'; return [pscustomobject]@{ status=$status; next=$next } }

  return [pscustomobject]@{ status=$status; next=$next }
}

function Start-BelgiChain {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][hashtable]$Args,
    [Parameter(Mandatory=$true)][string]$ScriptRoot
  )

  $config = Get-BelgiConfig

  # PowerShell 7+ treats native STDERR as non-terminating errors; with 'Stop' this becomes a hard fail.
  if ($PSVersionTable -and $PSVersionTable.PSVersion.Major -ge 7) {
    $global:PSNativeCommandUseErrorActionPreference = $false
  }

  if ($Args.Auto) { $Args.Interactive = $false }

  $ctx = New-RunContext -Args $Args -Config $config -ScriptRoot $ScriptRoot

  Initialize-RunContext -Context $ctx -Args $Args
  $ctx.StepPlan = @($config.Steps)

  if ($Args.Auto) {
    Invoke-ChainAll -Context $ctx -AllowNoGo:$ctx.AllowNoGo
    exit 0
  }

  if (-not $ctx.Interactive) {
    Write-UiLine 'Non-interactive mode requires -Auto.' Yellow
    exit 1
  }

  Show-Hud -Context $ctx

  while ($true) {
    $cmd = (Read-Host '>').Trim().ToLowerInvariant()
    switch ($cmd) {
      'quit' { return }
      'help' { 
        Show-Hud -Context $ctx 
        Write-Host '  COMMAND REFERENCE:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Workflows:' -ForegroundColor Cyan
        Write-Host '    demo     Run guided interactive demo (recommended for learning)' -ForegroundColor Gray
        Write-Host '    repro    Run chain twice, verify identical outputs (determinism check)' -ForegroundColor Gray
        Write-Host '    all      Run full chain automatically (no pauses)' -ForegroundColor Gray
        Write-Host '    resume   Continue from next incomplete step' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Chain Steps (in order):' -ForegroundColor Cyan
        Write-Host '    c1       Compile docs and create PromptBundle' -ForegroundColor Gray
        Write-Host '    q        Gate Q: Validate pre-run integrity' -ForegroundColor Gray
        Write-Host '    r        Gate R: Validate diff against allowed paths' -ForegroundColor Gray
        Write-Host '    c3       Compile C3 manifest' -ForegroundColor Gray
        Write-Host '    seal     Create SealManifest (cryptographic seal)' -ForegroundColor Gray
        Write-Host '    s        Gate S: Verify seal integrity' -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Utilities:' -ForegroundColor Cyan
        Write-Host '    status   Show current chain progress' -ForegroundColor Gray
        Write-Host '    paths    Show all relevant file paths' -ForegroundColor Gray
        Write-Host '    commit   Commit changes in target_service' -ForegroundColor Gray
        Write-Host '    quit     Exit the runner' -ForegroundColor Gray
        Write-Host ''
        Pause-IfInteractive -Context $ctx
      }
      'status' {
        $p = Get-ChainProgress -Context $ctx
        Show-Hud -Context $ctx -Hint ("Next: " + $p.next)
      }
      'paths' { Show-RunPaths -Context $ctx; Pause-IfInteractive -Context $ctx }
      'commit' {
        Invoke-UiAction -Context $ctx -Label 'COMMIT' -Action {
          Write-Host ''
          Write-UiLine 'This will run inside target_service:' Cyan
          Write-UiLine '  git -C target_service add -A ; git -C target_service commit -m "..."' DarkGray
          $msg = (Read-Host 'Commit message (default: "forbidden change")').Trim()
          if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'forbidden change' }

          $dirty = $false
          try {
            $porc = @(git -C $ctx.RepoRoot status --porcelain)
            $dirty = ($porc.Count -gt 0)
          } catch { $dirty = $true }

          $allowEmpty = $false
          if (-not $dirty) {
            $ans = (Read-Host 'Nothing to commit. Create an empty commit anyway? (y/N)').Trim().ToLowerInvariant()
            if ($ans -eq 'y' -or $ans -eq 'yes') { $allowEmpty = $true } else { return }
          }

          Invoke-GitAddCommit -Context $ctx -Message $msg -AllowEmpty:$allowEmpty
          $last = ''
          try { $last = (& git -C $ctx.RepoRoot log -1 --oneline 2>$null).Trim() } catch { $last = '' }
          if ($last) { Write-UiLine ("Committed: " + $last) Green }
        } | Out-Null
        Show-Hud -Context $ctx
      }
      'resume' {
        Invoke-UiAction -Context $ctx -Label 'RESUME' -Action {
          $p = Get-ChainProgress -Context $ctx
          switch ($p.next) {
            'c1' { Invoke-StepC1 -Context $ctx }
            'q' { Invoke-StepQ -Context $ctx }
            'r' { Invoke-StepR -Context $ctx -AllowNoGo:$ctx.AllowNoGo }
            'c3' { Invoke-StepC3 -Context $ctx }
            'seal' { Invoke-StepSeal -Context $ctx }
            's' { Invoke-StepS -Context $ctx -AllowNoGo:$ctx.AllowNoGo }
            default { Write-UiLine 'Nothing to resume; chain looks complete for this run.' Green }
          }
        } | Out-Null
        Show-Hud -Context $ctx
      }
      'c1' { Invoke-UiAction -Context $ctx -Label 'C1' -Action { Invoke-StepC1 -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'q' { Invoke-UiAction -Context $ctx -Label 'Q' -Action { Invoke-StepQ -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'r' { Invoke-UiAction -Context $ctx -Label 'R' -Action { Invoke-StepR -Context $ctx -AllowNoGo:$ctx.AllowNoGo } | Out-Null; Show-Hud -Context $ctx }
      'rverify' { Invoke-UiAction -Context $ctx -Label 'RVERIFY' -Action { Invoke-StepRVerifyOnly -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'c3' { Invoke-UiAction -Context $ctx -Label 'C3' -Action { Invoke-StepC3 -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'seal' { Invoke-UiAction -Context $ctx -Label 'SEAL' -Action { Invoke-StepSeal -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      's' { Invoke-UiAction -Context $ctx -Label 'S' -Action { Invoke-StepS -Context $ctx -AllowNoGo:$ctx.AllowNoGo } | Out-Null; Show-Hud -Context $ctx }
      'sverify' { Invoke-UiAction -Context $ctx -Label 'SVERIFY' -Action { Invoke-StepS -Context $ctx -VerifyOnly } | Out-Null; Show-Hud -Context $ctx }
      'all' { Invoke-UiAction -Context $ctx -Label 'ALL' -Action { Invoke-ChainAll -Context $ctx -AllowNoGo:$ctx.AllowNoGo } | Out-Null; Show-Hud -Context $ctx }
      'demo' { Invoke-UiAction -Context $ctx -Label 'DEMO' -Action { Invoke-GuidedDemo -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'repro' { Invoke-UiAction -Context $ctx -Label 'REPRO' -Action { Invoke-Repro -Context $ctx } | Out-Null; Show-Hud -Context $ctx }
      'qtamper' { Invoke-UiAction -Context $ctx -Label 'QTAMPER' -Action { Invoke-QTamper -Context $ctx -Pause } | Out-Null; Show-Hud -Context $ctx }
      'c2' { Invoke-UiAction -Context $ctx -Label 'C2' -Action { Invoke-C2 -Context $ctx -Pause } | Out-Null; Show-Hud -Context $ctx }
      '' { }
      default {
        Write-Host ''
        Write-Host "  Unknown command: '$cmd'" -ForegroundColor Red
        Write-Host '  Type "help" for a list of commands, or use one of:' -ForegroundColor Yellow
        Write-Host '    demo | repro | all | resume | help | quit' -ForegroundColor Gray
        Write-Host ''
      }
    }
  }
}
