Set-StrictMode -Version Latest

function Pause-IfInteractive {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [string]$Prompt = 'Press Enter to continue'
  )
  if (-not $Context.Interactive) { return }
  [void](Read-Host $Prompt)
}

function Read-EnterOnly {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$Prompt)

  while ($true) {
    $ans = Read-Host $Prompt
    if ([string]::IsNullOrEmpty($ans)) { return }
    $t = $ans.Trim().ToLowerInvariant()
    if ($t -eq 'quit' -or $t -eq 'exit' -or $t -eq 'q') { exit 0 }
    Write-Host "(Just press Enter here — or type 'quit' to exit.)" -ForegroundColor Yellow
  }
}

function Ensure-GitIdentityConfigured {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$RepoRootAbs)

  $name = ''
  $email = ''
  try { $name = (& git -C $RepoRootAbs config user.name 2>$null).Trim() } catch { $name = '' }
  try { $email = (& git -C $RepoRootAbs config user.email 2>$null).Trim() } catch { $email = '' }

  if (-not [string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($email)) { return }

  $gn = ''
  $ge = ''
  try { $gn = (& git config --global user.name 2>$null).Trim() } catch { $gn = '' }
  try { $ge = (& git config --global user.email 2>$null).Trim() } catch { $ge = '' }

  if (-not [string]::IsNullOrWhiteSpace($gn) -and -not [string]::IsNullOrWhiteSpace($ge)) {
    & git -C $RepoRootAbs config user.name $gn | Out-Null
    & git -C $RepoRootAbs config user.email $ge | Out-Null
    return
  }

  throw "Git identity not configured (user.name/user.email). Configure it, then retry."
}

function Invoke-GitAddCommit {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][string]$Message,
    [switch]$AllowEmpty
  )

  if ([string]::IsNullOrWhiteSpace($Message)) {
    throw 'Commit message must be non-empty.'
  }

  $gitRoot = $Context.PlaygroundRoot
  if ([string]::IsNullOrWhiteSpace($gitRoot)) { $gitRoot = $Context.RepoRoot }

  Ensure-GitIdentityConfigured -RepoRootAbs $gitRoot

  & git -C $gitRoot add -A | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git add -A failed.' }

  $commitArgs = @('-C', $gitRoot, 'commit')
  if ($AllowEmpty) { $commitArgs += '--allow-empty' }
  $commitArgs += @('-m', $Message)

  & git @commitArgs | Out-Null
  if ($LASTEXITCODE -ne 0) {
    $status = ''
    try { $status = (& git -C $gitRoot status --porcelain 2>$null) } catch { $status = '' }
    if ([string]::IsNullOrWhiteSpace($status) -and -not $AllowEmpty) {
      throw 'git commit failed (nothing to commit). Make a change first, or re-run with allow-empty.'
    }
    throw 'git commit failed.'
  }
}

function Get-GitRootAbs {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  if (-not [string]::IsNullOrWhiteSpace($Context.PlaygroundRoot)) { return $Context.PlaygroundRoot }
  return $Context.RepoRoot
}

function Ensure-ForbiddenPrivateChangeCommitted {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $demoRel = 'private/DEMO_FORBIDDEN_CHANGE.txt'
  $demoAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $demoRel)
  $dirAbs = Split-Path -Parent $demoAbs
  if (!(Test-Path $dirAbs)) { New-Item -ItemType Directory -Force -Path $dirAbs | Out-Null }

  $content = @(
    'FORBIDDEN: demo mutation under target_service/private/'
    ('run_id: ' + $Context.RunId)
    ('utc: ' + (Get-Date).ToUniversalTime().ToString('o'))
  ) -join "`n"

  Write-Utf8NoBomLf -Path $demoAbs -Text $content
  Invoke-GitAddCommit -Context $Context -Message 'DEMO: forbidden private/ change' | Out-Null
}

function Invoke-TamperAndSVerifyDemo {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $manifestAbs = $Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)
  $sealAbs = $Context.RepoRelToAbs($Context.Rel.SealManifest)
  Ensure-File -Path $manifestAbs -Label 'C3 (Final EvidenceManifest)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path $sealAbs -Label 'SEAL (SealManifest)' -RunDirAbs $Context.BelgiRunAbs

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host 'DEMO 3: Gate S Integrity Check' -ForegroundColor Yellow
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Gate S verifies that SealManifest hashes match the actual artifact bytes.' -ForegroundColor Cyan
  Write-Host 'We will now TAMPER with EvidenceManifest.final.json (add whitespace).' -ForegroundColor Cyan
  Write-Host 'This will cause a hash mismatch and Gate S should return NO-GO.' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Files involved:' -ForegroundColor DarkGray
  Write-Host "  SealManifest:      $sealAbs" -ForegroundColor DarkGray
  Write-Host "  EvidenceManifest:  $manifestAbs (will be tampered)" -ForegroundColor DarkGray
  Write-Host ''
  
  if ($Context.Interactive) { Read-EnterOnly -Prompt 'Press Enter to tamper EvidenceManifest and run S-verify' }

  $origBytes = [System.IO.File]::ReadAllBytes($manifestAbs)
  try {
    $text = ''
    try { $text = [System.Text.Encoding]::UTF8.GetString($origBytes) } catch { $text = (Get-Content -LiteralPath $manifestAbs -Raw -ErrorAction Stop) }
    $mutated = $text
    if ($mutated.EndsWith("`n")) { $mutated = $mutated + ' ' } else { $mutated = $mutated + "`n" }
    Write-Utf8NoBomLf -Path $manifestAbs -Text $mutated
    
    Write-Host ''
    Write-Host 'TAMPERED: Added whitespace to EvidenceManifest.final.json' -ForegroundColor Red
    Write-Host 'Running Gate S verify-only...' -ForegroundColor Yellow
    Write-Host ''

    try {
      Invoke-StepS -Context $Context -VerifyOnly
      Write-Host ''
      Write-Host 'UNEXPECTED: Gate S verify-only returned GO after tamper.' -ForegroundColor Red
    } catch {
      Write-Host ''
      Write-Host 'OK: Gate S verify-only produced NO-GO as expected!' -ForegroundColor Green
      Write-Host 'The hash in SealManifest no longer matches the tampered file bytes.' -ForegroundColor Green
    }
  } finally {
    [System.IO.File]::WriteAllBytes($manifestAbs, $origBytes)
    Write-Host ''
    Write-Host 'RESTORED: EvidenceManifest.final.json reverted to original.' -ForegroundColor Cyan
  }
  
  if ($Context.Interactive) { Read-EnterOnly -Prompt 'Press Enter to continue' }
}

function Ensure-GovernedRepoIsStandaloneGitRepo {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  # Single-repo workflow is allowed. Only require that git is usable from target_service.
  try {
    & git -C $Context.RepoRoot rev-parse --is-inside-work-tree 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) { return }
  } catch {}

  throw 'Git repo not detected. Initialize git at the repo root, then retry.'
}

function Assert-EngineProtocolPackPresent {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $canon = Join-Path $Context.EngineRoot 'CANONICALS.md'
  $schemas = Join-Path $Context.EngineRoot 'schemas'
  if (!(Test-Path $canon) -or !(Test-Path $schemas)) {
    throw 'Run scripts/bootstrap.ps1 first; ENGINE cache missing protocol pack files.'
  }
  $anySchema = Get-ChildItem -Path $schemas -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $anySchema) {
    throw 'Run scripts/bootstrap.ps1 first; ENGINE cache missing protocol pack schema files.'
  }
}

function Assert-ManifestNoDuplicateStorageRefs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][string]$ManifestAbs,
    [Parameter(Mandatory=$true)][string]$Label
  )

  $m = Read-Json -Path $ManifestAbs
  if ($null -eq $m) { throw "Fail-closed: unable to read manifest JSON for duplicate check: $ManifestAbs" }
  $artsProp = $m.PSObject.Properties['artifacts']
  $arts = if ($artsProp) { $artsProp.Value } else { $null }
  if (!($arts -is [System.Collections.IEnumerable])) { return }

  $seen = @{}
  $dups = @{}
  foreach ($a in $arts) {
    if ($null -eq $a) { continue }
    $sr = $a.storage_ref
    if ([string]::IsNullOrWhiteSpace([string]$sr)) { continue }
    $key = [string]$sr
    if ($seen.ContainsKey($key)) { $dups[$key] = $true } else { $seen[$key] = $true }
  }

  if ($dups.Keys.Count -gt 0) {
    $list = ($dups.Keys | Sort-Object) -join '; '
    throw "Fail-closed: ${Label} duplicate artifacts[].storage_ref detected: ${list}"
  }
}

function Get-JsonPropValue {
  [CmdletBinding()]
  param(
    [AllowNull()]$Obj,
    [Parameter(Mandatory=$true)][string]$Name
  )
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Get-GateVerdictStatus {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$VerdictPath)

  if (!(Test-Path $VerdictPath)) { return 'missing' }
  $obj = Read-Json -Path $VerdictPath
  if ($null -eq $obj) { return 'missing' }
  $v = [string](Get-JsonPropValue -Obj $obj -Name 'verdict')
  if ($v -eq 'GO') { return 'ok' }
  if ($v) { return 'fail' }
  return 'missing'
}

function Show-GateVerdictSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$AbsPath
  )

  if (!(Test-Path $AbsPath)) { return }
  $obj = Read-Json -Path $AbsPath
  if ($null -eq $obj) { return }
  $verdict = [string](Get-JsonPropValue -Obj $obj -Name 'verdict')
  $category = [string](Get-JsonPropValue -Obj $obj -Name 'failure_category')
  $first = $null
  $failures = Get-JsonPropValue -Obj $obj -Name 'failures'
  if ($failures -is [System.Collections.IList] -and $failures.Count -gt 0) { $first = $failures[0] }

  Write-Host ''
  Write-Host ("Gate result (" + $Label + "): " + $verdict) -ForegroundColor Cyan
  if ($category) { Write-Host ("  category: " + $category) -ForegroundColor Yellow }
  if ($null -ne $first) {
    $ruleId = Get-JsonPropValue -Obj $first -Name 'rule_id'
    $msg = Get-JsonPropValue -Obj $first -Name 'message'
    if ($ruleId) { Write-Host ("  rule:     " + $ruleId) -ForegroundColor Yellow }
    if ($msg) { Write-Host ("  message:  " + $msg) -ForegroundColor Yellow }
  }
  $rem = Get-JsonPropValue -Obj $obj -Name 'remediation'
  if ($null -ne $rem) {
    $next = Get-JsonPropValue -Obj $rem -Name 'next_instruction'
    if ($next) { Write-Host ("  fix:      " + $next) -ForegroundColor Yellow }
  }
}

function Initialize-RunContext {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][hashtable]$Args
  )

  Ensure-GovernedRepoIsStandaloneGitRepo -Context $Context

  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $outBaseRelPosix = $Context.OutDirBaseRelPosix

  $baseAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $outBaseRelPosix)
  if (!(Test-Path $baseAbs)) { New-Item -ItemType Directory -Force -Path $baseAbs | Out-Null }

  function Get-LatestRunRelPosix {
    param([string]$BaseRelPosix)
    $bAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $BaseRelPosix)
    if (!(Test-Path $bAbs)) { return $null }
    $runs = @()
    try {
      $runs = @(Get-ChildItem -LiteralPath $bAbs -Directory -Filter 'run_*' -ErrorAction Stop | Sort-Object Name -Descending)
    } catch { $runs = @() }
    if ($runs.Count -lt 1) { return $null }
    return ("${BaseRelPosix}/" + $runs[0].Name)
  }

  $latestRunRelPosix = Get-LatestRunRelPosix $outBaseRelPosix
  $useResume = $false

  if ([bool]$Args.Auto) {
    $useResume = $false
  } elseif ([bool]$Args.NewRun) {
    $useResume = $false
  } elseif ([bool]$Args.Resume) {
    $useResume = $true
  } elseif ($Context.Interactive -and $latestRunRelPosix) {
    Write-Host ''
    Write-Host 'Found an existing run folder:' -ForegroundColor Cyan
    Write-Host ('  ' + (Join-Path $Context.RepoRoot (Convert-PosixPathToNative $latestRunRelPosix))) -ForegroundColor DarkGray
    $ans = (Read-Host 'Resume this run (recommended)? (Y/n)').Trim().ToLowerInvariant()
    if ($ans -eq '' -or $ans -eq 'y' -or $ans -eq 'yes') { $useResume = $true }
  }

  if ($useResume) {
    if (-not $latestRunRelPosix) {
      throw "Resume requested, but no prior run_* folders exist under '${outBaseRelPosix}/'."
    }
    $Context.BelgiRunRelPosix = $latestRunRelPosix
    $Context.RunDirName = Get-LeafFromPosixPath $latestRunRelPosix
  } else {
    $runName = ('run_' + $stamp)
    if (-not [string]::IsNullOrWhiteSpace([string]$Args.RunDirName)) {
      $runName = [string]$Args.RunDirName
      $runName = $runName.Trim()
    }
    if ($runName -notmatch '^run_[A-Za-z0-9_.-]+$') {
      throw "RunDirName must match ^run_[A-Za-z0-9_.-]+$ (got '${runName}')."
    }
    $Context.RunDirName = $runName
    $Context.BelgiRunRelPosix = ("${outBaseRelPosix}/" + $runName)
  }

  $Context.BelgiRunAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $Context.BelgiRunRelPosix)

  if (-not $useResume) {
    if ([bool]$Args.ForceCleanRun -and (Test-Path $Context.BelgiRunAbs)) {
      Remove-Item -Recurse -Force -LiteralPath $Context.BelgiRunAbs -ErrorAction Stop
    }
    New-Item -ItemType Directory -Force -Path $Context.BelgiRunAbs | Out-Null
  } else {
    if (!(Test-Path $Context.BelgiRunAbs)) { throw "Resume selected, but run folder does not exist: $($Context.BelgiRunAbs)" }
  }

  foreach ($d in @('bundle','policy','docs')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Context.BelgiRunAbs $d) | Out-Null
  }

  # Verify belgi_specs inputs exist
  $repoRoot = $Context.RepoRoot
  foreach ($p in @('belgi_specs/IntentSpec.core.md','belgi_specs/tolerances.json','belgi_specs/toolchain.json')) {
    $abs = Join-Path $repoRoot (Convert-PosixPathToNative $p)
    if (!(Test-Path $abs)) { throw "Missing target_service/${p}" }
  }

  # Canonical repo-relative artifact locations (relative to target_service)
  $intentRel = 'belgi_specs/IntentSpec.core.md'
  $tolRel = 'belgi_specs/tolerances.json'
  $tcRel = 'belgi_specs/toolchain.json'

  $lockedRel = "$($Context.BelgiRunRelPosix)/LockedSpec.json"
  $pbHashesRel = "$($Context.BelgiRunRelPosix)/prompt_block_hashes.json"
  $promptBundleRel = "$($Context.BelgiRunRelPosix)/bundle/prompt_bundle.bin"
  $pbPolicyRel = "$($Context.BelgiRunRelPosix)/bundle/policy.prompt_bundle.json"

  $cmdLogLiveRel = "$($Context.BelgiRunRelPosix)/command_log.live.txt"
  $cmdLogRel = "$($Context.BelgiRunRelPosix)/command_log.txt"
  $envAttRel = "$($Context.BelgiRunRelPosix)/env_attestation.json"

  $qSeedManifestRel = "$($Context.BelgiRunRelPosix)/EvidenceManifest.Q.seed.json"
  $qVerdictRel = "$($Context.BelgiRunRelPosix)/GateVerdict.Q.json"

  $rVerdictRel = "$($Context.BelgiRunRelPosix)/GateVerdict.R.json"
  $rSnapRel = "$($Context.BelgiRunRelPosix)/EvidenceManifest.R.json"
  $rReportRel = "$($Context.BelgiRunRelPosix)/GateReport.R.json"

  $rVerdictVerifyRel = "$($Context.BelgiRunRelPosix)/GateVerdict.R.verify.json"
  $rSnapVerifyRel = "$($Context.BelgiRunRelPosix)/EvidenceManifest.R.verify.json"
  $rReportVerifyRel = "$($Context.BelgiRunRelPosix)/GateReport.R.verify.json"

  $diffRel = "$($Context.BelgiRunRelPosix)/diff.patch"

  $policyDirRel = "$($Context.BelgiRunRelPosix)/policy"
  $policyInvRel = "$policyDirRel/policy.invariant_eval.json"
  $policySupplychainRel = "$policyDirRel/policy.supplychain.json"
  $policyAdversarialRel = "$policyDirRel/policy.adversarial_scan.json"

  $c3FinalManifestRel = "$($Context.BelgiRunRelPosix)/EvidenceManifest.final.json"
  $c3DocsRel = "$($Context.BelgiRunRelPosix)/docs/Docs.md"
  $c3BundleDirRel = "$($Context.BelgiRunRelPosix)/docs/bundle"
  $c3BundleRootShaRel = "$($Context.BelgiRunRelPosix)/docs/bundle_root_sha256.txt"
  $c3BundleManifestRel = "$c3BundleDirRel/docs_bundle_manifest.json"
  $c3DocsLogRel = 'docs/docs_compilation_log.json'
  $c3DocsLogMirrorRel = "$($Context.BelgiRunRelPosix)/docs/docs_compilation_log.json"

  $sealManifestRel = "$($Context.BelgiRunRelPosix)/SealManifest.json"
  $sVerdictRel = "$($Context.BelgiRunRelPosix)/GateVerdict.S.json"
  $sVerdictVerifyRel = "$($Context.BelgiRunRelPosix)/GateVerdict.S.verify.json"

  $Context.Rel.IntentSpec = $intentRel
  $Context.Rel.Tolerances = $tolRel
  $Context.Rel.Toolchain = $tcRel

  $Context.Rel.LockedSpec = $lockedRel
  $Context.Rel.PromptBlockHashes = $pbHashesRel
  $Context.Rel.PromptBundle = $promptBundleRel
  $Context.Rel.PromptBundlePolicy = $pbPolicyRel
  $Context.Rel.CommandLogLive = $cmdLogLiveRel
  $Context.Rel.CommandLogEvidence = $cmdLogRel
  $Context.Rel.EnvAttestation = $envAttRel

  $Context.Rel.EvidenceManifestQSeed = $qSeedManifestRel
  $Context.Rel.GateVerdictQ = $qVerdictRel
  $Context.Rel.GateVerdictR = $rVerdictRel
  $Context.Rel.EvidenceManifestR = $rSnapRel
  $Context.Rel.GateReportR = $rReportRel
  $Context.Rel.GateVerdictRVerify = $rVerdictVerifyRel
  $Context.Rel.EvidenceManifestRVerify = $rSnapVerifyRel
  $Context.Rel.GateReportRVerify = $rReportVerifyRel
  $Context.Rel.DiffPatch = $diffRel
  $Context.Rel.PolicyInvariantEval = $policyInvRel
  $Context.Rel.PolicySupplychain = $policySupplychainRel
  $Context.Rel.PolicyAdversarialScan = $policyAdversarialRel
  $Context.Rel.EvidenceManifestFinal = $c3FinalManifestRel
  $Context.Rel.DocsMd = $c3DocsRel
  $Context.Rel.DocsBundleDir = $c3BundleDirRel
  $Context.Rel.DocsBundleRootSha = $c3BundleRootShaRel
  $Context.Rel.DocsBundleManifest = $c3BundleManifestRel
  $Context.Rel.DocsCompilationLogCanonical = $c3DocsLogRel
  $Context.Rel.DocsCompilationLogMirror = $c3DocsLogMirrorRel
  $Context.Rel.SealManifest = $sealManifestRel
  $Context.Rel.GateVerdictS = $sVerdictRel
  $Context.Rel.GateVerdictSVerify = $sVerdictVerifyRel

  $cmdLogLiveAbs = $Context.RepoRelToAbs($Context.Rel.CommandLogLive)
  Ensure-TextFileExists -Path $cmdLogLiveAbs -Label 'command_log LIVE'

  # Commands (drive-qualified-free)
  $belgiToolsPyAbs = Join-Path $Context.BelgiRoot (Convert-PosixPathToNative 'tools/belgi_tools.py')
  if (!(Test-Path $belgiToolsPyAbs)) { throw "Missing ENGINE wrapper: $belgiToolsPyAbs. Run scripts/bootstrap.ps1 first." }

  # IMPORTANT: args must not contain drive-qualified paths; belgi_tools.py is referenced repo-rel.
  $cacheDirFromPlayground = [string]$Args.CacheDir
  if ([string]::IsNullOrWhiteSpace($cacheDirFromPlayground)) { $cacheDirFromPlayground = [string]$Context.Config.Defaults.CacheDir }
  $belgiToolsPyRel = (Join-Path '..' (Join-Path (Join-Path $cacheDirFromPlayground 'tools') 'belgi_tools.py'))
  $belgiToolsPyRel = $belgiToolsPyRel.Replace('\\','/')
  $Context.Commands._BelgiToolsPyRel = $belgiToolsPyRel

  $Context.Commands.C1 = @(
    '-m','chain.compiler_c1_intent',
    '--repo','.',
    '--intent-spec',$Context.Rel.IntentSpec,
    '--tolerances',('tol-001=' + $Context.Rel.Tolerances),
    '--toolchain-ref',('tc-001=' + $Context.Rel.Toolchain),
    '--out',$Context.Rel.LockedSpec,
    '--run-id',$Context.RunId,
    '--repo-ref',$Context.RepoRef,
    '--prompt-bundle-out',$Context.Rel.PromptBundle,
    '--prompt-block-hashes-out',$Context.Rel.PromptBlockHashes,
    '--prompt-bundle-policy-out',$Context.Rel.PromptBundlePolicy,
    '--envelope-id',$Context.EnvelopeId,
    '--envelope-description',$Context.EnvelopeDescription,
    '--expected-runner',$Context.ExpectedRunner
  )

  $Context.Commands.Q = @(
    '-m','chain.gate_q_verify',
    '--repo','.',
    '--intent-spec',$Context.Rel.IntentSpec,
    '--locked-spec',$Context.Rel.LockedSpec,
    '--evidence-manifest',$Context.Rel.EvidenceManifestQSeed,
    '--out',$Context.Rel.GateVerdictQ
  )

  $Context.Commands.INV = @(
    $belgiToolsPyRel,'invariant-eval',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--run-id',$Context.RunId,
    '--out',$Context.Rel.PolicyInvariantEval,
    '--deterministic'
  )

  $Context.Commands.MANIFEST_INV = @(
    $belgiToolsPyRel,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--artifact',$Context.Rel.PolicyInvariantEval,
    '--kind','policy_report',
    '--id','policy.invariant_eval',
    '--produced-by','R'
  )

  $Context.Commands.ATTEST = @(
    $belgiToolsPyRel,'verify-attestation',
    '--repo','.',
    '--run-id',$Context.RunId,
    '--command-log',$Context.Rel.CommandLogEvidence,
    '--locked-spec',$Context.Rel.LockedSpec,
    '--out',$Context.Rel.EnvAttestation,
    '--deterministic'
  )

  $Context.Commands.SUPPLYCHAIN = @(
    '-m','belgi.cli','supplychain-scan',
    '--repo','.',
    '--run-id',$Context.RunId,
    '--out',$Context.Rel.PolicySupplychain,
    '--deterministic'
  )

  $Context.Commands.ADVERSARIAL = @(
    '-m','belgi.cli','adversarial-scan',
    '--repo','.',
    '--run-id',$Context.RunId,
    '--out',$Context.Rel.PolicyAdversarialScan,
    '--deterministic'
  )

  $Context.Commands.R = @(
    '-m','chain.gate_r_verify',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--gate-q-verdict',$Context.Rel.GateVerdictQ,
    '--evidence-manifest',$Context.Rel.EvidenceManifestR,
    '--r-snapshot-manifest-out',$Context.Rel.EvidenceManifestR,
    '--out',$Context.Rel.GateReportR,
    '--gate-verdict-out',$Context.Rel.GateVerdictR,
    '--required-policy-report-ids','policy.invariant_eval'
  )

  $Context.Commands.RVERIFY = @(
    '-m','chain.gate_r_verify',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--gate-q-verdict',$Context.Rel.GateVerdictQ,
    '--evidence-manifest',$Context.Rel.EvidenceManifestR,
    '--r-snapshot-manifest-out',$Context.Rel.EvidenceManifestRVerify,
    '--out',$Context.Rel.GateReportRVerify,
    '--gate-verdict-out',$Context.Rel.GateVerdictRVerify,
    '--required-policy-report-ids','policy.invariant_eval'
  )

  $Context.Commands.S = @(
    '-m','chain.gate_s_verify',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--seal-manifest',$Context.Rel.SealManifest,
    '--evidence-manifest',$Context.Rel.EvidenceManifestFinal,
    '--out',$Context.Rel.GateVerdictS
  )

  $Context.Commands.SVERIFY = @(
    '-m','chain.gate_s_verify',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--seal-manifest',$Context.Rel.SealManifest,
    '--evidence-manifest',$Context.Rel.EvidenceManifestFinal,
    '--out',$Context.Rel.GateVerdictSVerify
  )
}

function Show-RunPaths {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host ''
  Write-Host 'BELGI engine cache:' -ForegroundColor Cyan
  Write-Host ('  ' + $Context.BelgiRoot) -ForegroundColor Gray
  Write-Host 'Governed repo root:' -ForegroundColor Cyan
  Write-Host ('  ' + $Context.RepoRoot) -ForegroundColor Gray
  Write-Host 'Run base (repo-rel):' -ForegroundColor Cyan
  Write-Host ('  ' + $Context.BelgiRunRelPosix + '/') -ForegroundColor Gray
  Write-Host 'Run base (abs):' -ForegroundColor Cyan
  Write-Host ('  ' + $Context.BelgiRunAbs) -ForegroundColor Gray
  Write-Host 'Key outputs (repo-rel):' -ForegroundColor Cyan
  Write-Host ('  LockedSpec:          ' + $Context.Rel.LockedSpec) -ForegroundColor Gray
  Write-Host ('  command_log LIVE:    ' + $Context.Rel.CommandLogLive) -ForegroundColor Gray
  Write-Host ('  command_log EVIDENCE:' + $Context.Rel.CommandLogEvidence) -ForegroundColor Gray
  Write-Host ('  GateVerdict.Q:       ' + $Context.Rel.GateVerdictQ) -ForegroundColor Gray
  Write-Host ('  EvidenceManifest.Q:  ' + $Context.Rel.EvidenceManifestQSeed) -ForegroundColor Gray
  Write-Host ('  GateVerdict.R:       ' + $Context.Rel.GateVerdictR) -ForegroundColor Gray
  Write-Host ('  EvidenceManifest.R:  ' + $Context.Rel.EvidenceManifestR) -ForegroundColor Gray
  Write-Host ('  Final manifest:      ' + $Context.Rel.EvidenceManifestFinal) -ForegroundColor Gray
  Write-Host ('  SealManifest:        ' + $Context.Rel.SealManifest) -ForegroundColor Gray
  Write-Host ('  GateVerdict.S:       ' + $Context.Rel.GateVerdictS) -ForegroundColor Gray
  Write-Host ''
}

function Get-TierIdFromLockedSpec {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)
  $lockedAbs = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  $locked = Read-Json -Path $lockedAbs
  if ($null -eq $locked) { return $null }
  $tier = Get-JsonPropValue -Obj $locked -Name 'tier'
  if ($tier -ne $null) {
    $tierId = Get-JsonPropValue -Obj $tier -Name 'tier_id'
    $tid = [string]$tierId
    if (-not [string]::IsNullOrWhiteSpace($tid)) { return $tid.Trim() }
  }
  return $null
}

function Get-CommandLogModeForTier {
  [CmdletBinding()]
  param([AllowNull()][string]$TierId)
  if ([string]::IsNullOrWhiteSpace($TierId)) { return 'strings' }
  if ($TierId -eq 'tier-0') { return 'strings' }
  return 'structured'
}

function Get-UpstreamCommitShaFromLockedSpec {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)
  $lockedAbs = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  $locked = Read-Json -Path $lockedAbs
  if ($null -eq $locked) { return $null }
  $up = Get-JsonPropValue -Obj $locked -Name 'upstream_state'
  if ($up -ne $null) {
    $shaVal = Get-JsonPropValue -Obj $up -Name 'commit_sha'
    $sha = [string]$shaVal
    if (-not [string]::IsNullOrWhiteSpace($sha)) { return $sha.Trim() }
  }
  return $null
}

function Get-EvaluatedRevision {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)
  return (Get-BelgiCommitSha -RepoRootAbs (Get-GitRootAbs -Context $Context))
}

function Get-PythonForCwd {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][string]$Cwd
  )

  $venvCandidates = @(
    (Join-Path $Context.PlaygroundRoot (Convert-PosixPathToNative '.venv/Scripts/python.exe')),
    (Join-Path $Context.PlaygroundRoot (Convert-PosixPathToNative '.venv/bin/python'))
  )
  foreach ($venvAbs in $venvCandidates) {
    if (Test-Path $venvAbs) {
      $rel = Get-RelativePathFailClosed -FromDir $Cwd -ToPath $venvAbs
      if (Test-Path (Join-Path $Cwd $rel)) { return $rel }
    }
  }
  return $Context.PythonCmd
}

function Freeze-CommandLogEvidenceFromLive {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $liveAbs = $Context.RepoRelToAbs($Context.Rel.CommandLogLive)
  $evidenceAbs = $Context.RepoRelToAbs($Context.Rel.CommandLogEvidence)
  Ensure-TextFileExists -Path $liveAbs -Label 'command_log LIVE'
  $raw = ''
  try { $raw = (Get-Content -Path $liveAbs -Raw -ErrorAction Stop) } catch { throw "Fail-closed: unable to read LIVE command log: $liveAbs" }
  Write-Utf8NoBomLf -Path $evidenceAbs -Text $raw
  Ensure-TextFileExists -Path $evidenceAbs -Label 'command_log EVIDENCE'
}

function Ensure-QSeedManifestFresh {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $lockedAbs = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  $pbPolicyAbs = $Context.RepoRelToAbs($Context.Rel.PromptBundlePolicy)
  Ensure-File -Path $lockedAbs -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path $pbPolicyAbs -Label 'C1 (policy.prompt_bundle)' -RunDirAbs $Context.BelgiRunAbs

  Freeze-CommandLogEvidenceFromLive -Context $Context

  $tierId = Get-TierIdFromLockedSpec -Context $Context
  $mode = Get-CommandLogModeForTier -TierId $tierId

  $belgiTools = [string]$Context.Commands._BelgiToolsPyRel
  $qSeedArgs = @(
    $belgiTools,'manifest-init',
    '--repo','.',
    '--out',$Context.Rel.EvidenceManifestQSeed,
    '--locked-spec',$Context.Rel.LockedSpec,
    '--overwrite',
    '--command-log-mode',$mode,
    '--add',('schema_validation:locked_spec:' + $Context.Rel.LockedSpec + ':application/json:C1'),
    '--add',('policy_report:policy.prompt_bundle:' + $Context.Rel.PromptBundlePolicy + ':application/json:C1'),
    '--add',('command_log:command.log:' + $Context.Rel.CommandLogEvidence + ':text/plain:C1')
  )
  Invoke-BelgiTool -Context $Context -Label 'Q-ManifestInit' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $qSeedArgs | Out-Null

  $qSeedAbs = $Context.RepoRelToAbs($Context.Rel.EvidenceManifestQSeed)
  Ensure-File -Path $qSeedAbs -Label 'Q (EvidenceManifest.Q seed)' -RunDirAbs $Context.BelgiRunAbs

  Freeze-CommandLogEvidenceFromLive -Context $Context
  $qCmdLogUpdateArgs = @(
    $belgiTools,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestQSeed,
    '--artifact',$Context.Rel.CommandLogEvidence,
    '--kind','command_log',
    '--id','command.log',
    '--media-type','text/plain',
    '--produced-by','C1'
  )
  Invoke-BelgiTool -Context $Context -Label 'Q-ManifestUpdate-CommandLog' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $qCmdLogUpdateArgs | Out-Null
  Assert-ManifestNoDuplicateStorageRefs -Context $Context -ManifestAbs $qSeedAbs -Label 'EvidenceManifest.Q.seed'
}

function Ensure-EnvAttestationEvidence {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $lockedAbs = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  Ensure-File -Path $lockedAbs -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Freeze-CommandLogEvidenceFromLive -Context $Context

  Invoke-BelgiTool -Context $Context -Label 'R-VerifyAttestation' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.ATTEST | Out-Null
  $envAttAbs = $Context.RepoRelToAbs($Context.Rel.EnvAttestation)
  Ensure-File -Path $envAttAbs -Label 'R (env_attestation)' -RunDirAbs $Context.BelgiRunAbs
}

function Ensure-DiffEvidence {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $lockedAbs = $Context.RepoRelToAbs($Context.Rel.LockedSpec)
  Ensure-File -Path $lockedAbs -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  $upstreamSha = Get-UpstreamCommitShaFromLockedSpec -Context $Context
  if ([string]::IsNullOrWhiteSpace($upstreamSha)) {
    throw 'LockedSpec.upstream_state.commit_sha missing/invalid; cannot generate diff evidence.'
  }
  $evaluatedSha = Get-EvaluatedRevision -Context $Context

  $belgiTools = [string]$Context.Commands._BelgiToolsPyRel
  $diffArgs = @(
    $belgiTools,'diff-capture',
    '--repo','.',
    '--upstream',$upstreamSha,
    '--evaluated',$evaluatedSha,
    '--out',$Context.Rel.DiffPatch
  )
  Invoke-BelgiTool -Context $Context -Label 'R-DiffCapture' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $diffArgs | Out-Null
  $diffAbs = $Context.RepoRelToAbs($Context.Rel.DiffPatch)
  Ensure-File -Path $diffAbs -Label 'diff (artifact bytes)' -RunDirAbs $Context.BelgiRunAbs
}

function Ensure-SupplychainPolicyReport {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  $evaluatedSha = Get-EvaluatedRevision -Context $Context
  $args = @($Context.Commands.SUPPLYCHAIN + @('--evaluated-revision', $evaluatedSha))
  $exitCode = Invoke-BelgiTool -Context $Context -Label 'R-SupplychainScan' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $args -AllowExitCodes @(2)

  $abs = $Context.RepoRelToAbs($Context.Rel.PolicySupplychain)
  Ensure-File -Path $abs -Label 'R (policy.supplychain)' -RunDirAbs $Context.BelgiRunAbs
  try {
    $len = (Get-Item -LiteralPath $abs -ErrorAction Stop).Length
    if ($len -le 0) { throw 'empty' }
  } catch {
    throw "R-SupplychainScan did not produce a usable report (exit=$exitCode)."
  }
  if ($exitCode -eq 2) {
    Write-Host '  Note: supplychain-scan returned exit=2 (continuing because report exists).' -ForegroundColor Yellow
  }
  return $exitCode
}

function Ensure-AdversarialPolicyReport {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Invoke-BelgiTool -Context $Context -Label 'R-AdversarialScan' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.ADVERSARIAL | Out-Null
  $abs = $Context.RepoRelToAbs($Context.Rel.PolicyAdversarialScan)
  Ensure-File -Path $abs -Label 'R (policy.adversarial_scan)' -RunDirAbs $Context.BelgiRunAbs
}

function Invoke-StepC1 {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host 'C1: compile intent -> LockedSpec + prompt bundle + hashes.' -ForegroundColor Cyan
  Invoke-BelgiTool -Context $Context -Label 'C1-IntentCompiler' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.C1 | Out-Null

  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.LockedSpec)) -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.PromptBundle)) -Label 'C1 (PromptBundle)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.PromptBlockHashes)) -Label 'C1 (prompt_block_hashes)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.PromptBundlePolicy)) -Label 'C1 (policy.prompt_bundle)' -RunDirAbs $Context.BelgiRunAbs

  # Normalize prompt_block_hashes.json to include ALL canonical block_ids.
  $pbHashesRel = $Context.Rel.PromptBlockHashes
  $cacheDirFromPlayground = $Context.Config.Defaults.CacheDir
  $registryRel = (Join-Path '..' (Join-Path (Join-Path (Join-Path $cacheDirFromPlayground 'belgi') 'templates') 'PromptBundle.blocks.md')).Replace('\\','/')

  $normalizePbHashesCode = @"
import json, hashlib
from pathlib import Path
hashes_path = Path(r'${pbHashesRel}')
registry_path = Path(r'${registryRel}')
registry_bytes = registry_path.read_bytes()
registry_sha256 = hashlib.sha256(registry_bytes).hexdigest()
text = registry_bytes.decode('utf-8', errors='strict')
lines = text.splitlines()

existing = {}
try:
  existing = json.loads(hashes_path.read_text(encoding='utf-8'))
except Exception:
  existing = {}
if not isinstance(existing, dict):
  existing = {}

def is_sha256_hex(s: object) -> bool:
  if not isinstance(s, str) or len(s) != 64:
    return False
  h = s.lower()
  return all(c in '0123456789abcdef' for c in h)

header_idx = None
for i, line in enumerate(lines):
  if line.strip().startswith('| block_id |'):
    header_idx = i
    break
if header_idx is None:
  raise SystemExit('Prompt block registry table header not found')

i = header_idx + 1
while i < len(lines) and '|---' not in lines[i]:
  i += 1
i += 1

block_ids = []
while i < len(lines):
  line = lines[i].strip()
  if not line.startswith('|'):
    break
  parts = [p.strip() for p in line.split('|')]
  if len(parts) >= 8:
    bid = parts[1]
    if bid:
      block_ids.append(bid)
  i += 1

out = {}
for bid in sorted(set(block_ids)):
  v = existing.get(bid)
  if is_sha256_hex(v):
    out[bid] = v.lower()
  else:
    payload = f'MISSING_PROMPT_BLOCK_BYTES\nblock_id:{bid}\nregistry_sha256:{registry_sha256}\n'.encode('utf-8', errors='strict')
    out[bid] = hashlib.sha256(payload).hexdigest()

hashes_path.write_text(
  json.dumps(out, indent=2, sort_keys=True, ensure_ascii=False) + '\n',
  encoding='utf-8',
)
"@

  Invoke-BelgiTool -Context $Context -Label 'C1-NormalizePromptBlockHashes' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments @('-c', $normalizePbHashesCode) | Out-Null
}

function Invoke-StepQ {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host 'Q: verify LockedSpec against IntentSpec using evidence manifest.' -ForegroundColor Cyan
  Ensure-QSeedManifestFresh -Context $Context
  $exitCode = Invoke-BelgiTool -Context $Context -Label 'GateQ' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.Q -AllowExitCodes @(2)
  $qVerdictAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictQ)
  Ensure-File -Path $qVerdictAbs -Label 'Q (GateVerdict.Q)' -RunDirAbs $Context.BelgiRunAbs
  Show-GateVerdictSummary -Label 'Q' -AbsPath $qVerdictAbs
  if ($exitCode -ne 0) {
    throw 'Gate Q NO-GO.'
  }
}

function Invoke-QTamper {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [switch]$Pause
  )

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host 'TAMPER: LockedSpec.json' -ForegroundColor Yellow
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Gate Q verifies that LockedSpec matches the IntentSpec.' -ForegroundColor Cyan
  Write-Host 'If you manually edit LockedSpec (e.g., change allowed_paths),' -ForegroundColor Cyan
  Write-Host 'Gate Q will detect the inconsistency and return NO-GO.' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Try this: Open the file below and remove private from forbidden to allowed or change "max_loc_delta" from 500 to 9999 or any coverage of Q' -ForegroundColor Green
  Write-Host ''
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.LockedSpec)) -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Write-Host ('  FILE: ' + $Context.RepoRelToAbs($Context.Rel.LockedSpec)) -ForegroundColor White
  Write-Host ''
  if ($Pause) { Read-EnterOnly -Prompt 'Press Enter after editing LockedSpec.json' }
}

function Invoke-C2 {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [switch]$Pause
  )

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host 'C2: Make Code Changes & Commit' -ForegroundColor Yellow
  Write-Host '========================================' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Gate R checks:' -ForegroundColor Cyan
  Write-Host '  - Changed files must be under allowed_paths (e.g., target_service/src/)' -ForegroundColor Gray
  Write-Host '  - Changed files must NOT be under forbidden_paths (e.g., target_service/private/)' -ForegroundColor Gray
  Write-Host '  - Changes must be COMMITTED (uncommitted changes are ignored)' -ForegroundColor Gray
  Write-Host ''
  Write-Host 'Quick commands (run from repo root):' -ForegroundColor DarkGray
  Write-Host '  git add -A ; git commit -m "my changes"' -ForegroundColor DarkGray
  Write-Host ''

  $upstreamSha = Get-UpstreamCommitShaFromLockedSpec -Context $Context
  if ([string]::IsNullOrWhiteSpace($upstreamSha)) { throw 'LockedSpec.upstream_state.commit_sha missing/invalid; cannot run C2 checks.' }

  while ($true) {
    $statusLines = @()
    try { $statusLines = @(git -C $Context.PlaygroundRoot status --porcelain -- target_service) } catch { $statusLines = @() }
    $relevant = @($statusLines | Where-Object { $_ -notmatch '^..\s+target_service/_out/' })
    if ($relevant.Count -gt 0) {
      Write-Host ''
      Write-Host 'BLOCKER: uncommitted changes detected (outside _out/).' -ForegroundColor Yellow
      foreach ($l in $relevant) { Write-Host ('  ' + $l) -ForegroundColor Yellow }
      if ($Pause) { Read-EnterOnly -Prompt 'Press Enter after you have committed/stashed/discarded' ; continue }
      throw 'C2 blocked: working tree is dirty outside _out/.'
    }

    $headSha = ''
    try { $headSha = (& git -C $Context.PlaygroundRoot rev-parse HEAD).Trim() } catch { $headSha = '' }
    if ([string]::IsNullOrWhiteSpace($headSha)) { throw 'Could not determine HEAD commit in target_service.' }

    if ($headSha -eq $upstreamSha) {
      Write-Host ''
      Write-Host 'BLOCKER: no commits since upstream.' -ForegroundColor Yellow
      Write-Host ('  upstream: ' + $upstreamSha) -ForegroundColor Gray
      Write-Host ('  head:     ' + $headSha) -ForegroundColor Gray
      if ($Pause) { Read-EnterOnly -Prompt 'Press Enter after you have committed'; continue }
      throw 'C2 blocked: no commits since upstream.'
    }

    Write-Host ''
    Write-Host 'C2 OK.' -ForegroundColor Green
    Write-Host ('  upstream:  ' + $upstreamSha) -ForegroundColor Gray
    Write-Host ('  evaluated: ' + $headSha) -ForegroundColor Gray
    return
  }
}

function Invoke-StepR {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [switch]$AllowNoGo
  )

  Write-Host 'R: evidence production + Gate R verify.' -ForegroundColor Cyan
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictQ)) -Label 'Q (GateVerdict.Q)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-QSeedManifestFresh -Context $Context

  $tierId = Get-TierIdFromLockedSpec -Context $Context
  $mode = Get-CommandLogModeForTier -TierId $tierId

  Ensure-EnvAttestationEvidence -Context $Context
  Freeze-CommandLogEvidenceFromLive -Context $Context

  $belgiTools = [string]$Context.Commands._BelgiToolsPyRel
  $rInitArgs = @(
    $belgiTools,'manifest-init',
    '--repo','.',
    '--out',$Context.Rel.EvidenceManifestR,
    '--locked-spec',$Context.Rel.LockedSpec,
    '--overwrite',
    '--command-log-mode',$mode,
    '--envelope-attestation',('env.attestation:' + $Context.Rel.EnvAttestation),
    '--add',('schema_validation:locked_spec:' + $Context.Rel.LockedSpec + ':application/json:C1'),
    '--add',('policy_report:policy.prompt_bundle:' + $Context.Rel.PromptBundlePolicy + ':application/json:C1'),
    '--add',('command_log:command.log:' + $Context.Rel.CommandLogEvidence + ':text/plain:C1'),
    '--add',('env_attestation:env.attestation:' + $Context.Rel.EnvAttestation + ':application/json:C1')
  )
  Invoke-BelgiTool -Context $Context -Label 'R-ManifestInit' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $rInitArgs | Out-Null
  $rSnapAbs = $Context.RepoRelToAbs($Context.Rel.EvidenceManifestR)
  Ensure-File -Path $rSnapAbs -Label 'R (EvidenceManifest.R init)' -RunDirAbs $Context.BelgiRunAbs
  Assert-ManifestNoDuplicateStorageRefs -Context $Context -ManifestAbs $rSnapAbs -Label 'EvidenceManifest.R (post-init)'

  $cmdRecAttArgs = @(
    $belgiTools,'command-record',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--subcommand','verify-attestation',
    '--exit-code','0',
    '--mode',$mode,
    '--deterministic'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-CommandRecord-Attestation' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $cmdRecAttArgs | Out-Null

  Ensure-DiffEvidence -Context $Context
  $manifestDiffArgs = @(
    $belgiTools,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--artifact',$Context.Rel.DiffPatch,
    '--kind','diff',
    '--id','diff.upstream',
    '--media-type','text/x-diff',
    '--produced-by','C2'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-ManifestUpdate-Diff' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $manifestDiffArgs | Out-Null

  $cmdRecDiffArgs = @(
    $belgiTools,'command-record',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--subcommand','diff-capture',
    '--exit-code','0',
    '--mode',$mode,
    '--deterministic'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-CommandRecord-DiffCapture' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $cmdRecDiffArgs | Out-Null

  $supplychainExit = Ensure-SupplychainPolicyReport -Context $Context
  $cmdRecSupplychainArgs = @(
    $belgiTools,'command-record',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--subcommand','supplychain-scan',
    '--exit-code',([string]$supplychainExit),
    '--mode',$mode,
    '--deterministic'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-CommandRecord-SupplychainScan' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $cmdRecSupplychainArgs | Out-Null

  $manifestSupplychainArgs = @(
    $belgiTools,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--artifact',$Context.Rel.PolicySupplychain,
    '--kind','policy_report',
    '--id','policy.supplychain',
    '--produced-by','R'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-ManifestUpdate-Supplychain' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $manifestSupplychainArgs | Out-Null

  Ensure-AdversarialPolicyReport -Context $Context
  $cmdRecAdvArgs = @(
    $belgiTools,'command-record',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--subcommand','adversarial-scan',
    '--exit-code','0',
    '--mode',$mode,
    '--deterministic'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-CommandRecord-AdversarialScan' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $cmdRecAdvArgs | Out-Null

  $manifestAdvArgs = @(
    $belgiTools,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--artifact',$Context.Rel.PolicyAdversarialScan,
    '--kind','policy_report',
    '--id','policy.adversarial_scan',
    '--produced-by','R'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-ManifestUpdate-Adversarial' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $manifestAdvArgs | Out-Null

  Invoke-BelgiTool -Context $Context -Label 'R-InvariantEval' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.INV | Out-Null
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.PolicyInvariantEval)) -Label 'R (policy.invariant_eval)' -RunDirAbs $Context.BelgiRunAbs

  $cmdRecInvArgs = @(
    $belgiTools,'command-record',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--subcommand','invariant-eval',
    '--exit-code','0',
    '--mode',$mode,
    '--deterministic'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-CommandRecord-InvariantEval' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $cmdRecInvArgs | Out-Null

  Invoke-BelgiTool -Context $Context -Label 'R-ManifestUpdate-InvariantEval' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.MANIFEST_INV | Out-Null

  Freeze-CommandLogEvidenceFromLive -Context $Context
  $rCmdLogUpdateArgs = @(
    $belgiTools,'manifest-update',
    '--repo','.',
    '--manifest',$Context.Rel.EvidenceManifestR,
    '--artifact',$Context.Rel.CommandLogEvidence,
    '--kind','command_log',
    '--id','command.log',
    '--media-type','text/plain',
    '--produced-by','C1'
  )
  Invoke-BelgiTool -Context $Context -Label 'R-ManifestUpdate-CommandLog' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $rCmdLogUpdateArgs | Out-Null

  Assert-ManifestNoDuplicateStorageRefs -Context $Context -ManifestAbs $rSnapAbs -Label 'EvidenceManifest.R (pre-gate)'

  $evaluatedSha = Get-EvaluatedRevision -Context $Context
  $rGateArgs = @($Context.Commands.R + @('--evaluated-revision', $evaluatedSha))
  $exitCode = Invoke-BelgiTool -Context $Context -Label 'R-GateVerify' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $rGateArgs -AllowExitCodes @(2)

  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateReportR)) -Label 'R (GateReport.R)' -RunDirAbs $Context.BelgiRunAbs
  $rVerdictAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictR)
  Ensure-File -Path $rVerdictAbs -Label 'R (GateVerdict.R)' -RunDirAbs $Context.BelgiRunAbs
  Show-GateVerdictSummary -Label 'R' -AbsPath $rVerdictAbs

  if ($exitCode -ne 0) {
    if ($AllowNoGo) {
      Write-Host 'Continuing despite Gate R NO-GO (AllowNoGo enabled).' -ForegroundColor Yellow
      return
    }
    throw 'Gate R NO-GO.'
  }
}

function Invoke-StepRVerifyOnly {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host 'R-VERIFY: verify-only (uses existing EvidenceManifest.R).' -ForegroundColor Cyan
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.LockedSpec)) -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictQ)) -Label 'Q (GateVerdict.Q)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestR)) -Label 'R (EvidenceManifest.R)' -RunDirAbs $Context.BelgiRunAbs

  $evaluatedSha = Get-EvaluatedRevision -Context $Context
  $rGateArgs = @($Context.Commands.RVERIFY + @('--evaluated-revision', $evaluatedSha))
  $exitCode = Invoke-BelgiTool -Context $Context -Label 'R-GateVerify-Only' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $rGateArgs -AllowExitCodes @(2)
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateReportRVerify)) -Label 'R-VERIFY (GateReport.R)' -RunDirAbs $Context.BelgiRunAbs
  $rVerdictVerifyAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictRVerify)
  Ensure-File -Path $rVerdictVerifyAbs -Label 'R-VERIFY (GateVerdict.R)' -RunDirAbs $Context.BelgiRunAbs
  Show-GateVerdictSummary -Label 'R (verify-only)' -AbsPath $rVerdictVerifyAbs
  if ($exitCode -ne 0) { throw 'Gate R NO-GO (verify-only).' }
}

function Invoke-StepC3 {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host 'C3: docs compiler -> docs bundle + final EvidenceManifest.' -ForegroundColor Cyan
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.LockedSpec)) -Label 'C1 (LockedSpec)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictQ)) -Label 'Q (GateVerdict.Q)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictR)) -Label 'R (GateVerdict.R)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestR)) -Label 'R (EvidenceManifest.R)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.PromptBlockHashes)) -Label 'C1 (prompt_block_hashes)' -RunDirAbs $Context.BelgiRunAbs

  $tmplAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative 'docs/DocsCompiler.template.md')
  Ensure-File -Path $tmplAbs -Label 'C3 (DocsCompiler template)' -RunDirAbs $Context.BelgiRunAbs

  $c3SandboxAbs = Join-Path $Context.BelgiRunAbs '_c3_sandbox'

  $C3_PROTOCOL_PACK_FILES = @('CANONICALS.md','terminology.md','trust-model.md')
  $C3_PROTOCOL_PACK_DIRS = @('gates','schemas','tiers','docs/operations','docs/research','belgi/templates')

  $cleanupErr = $null
  try {
    if (Test-Path $c3SandboxAbs) { Remove-Item -LiteralPath $c3SandboxAbs -Recurse -Force -Confirm:$false -ErrorAction Stop }
    New-Item -ItemType Directory -Force -Path $c3SandboxAbs | Out-Null

    Assert-EngineProtocolPackPresent -Context $Context
    foreach ($relDir in $C3_PROTOCOL_PACK_DIRS) {
      $relNative = Convert-PosixPathToNative $relDir
      $srcDir = Join-Path $Context.EngineRoot $relNative
      if (!(Test-Path $srcDir)) { throw "Fail-closed: missing protocol-pack dir in ENGINE cache: ${srcDir}" }

      $dstDir = Join-Path $c3SandboxAbs $relNative
      if (Test-Path $dstDir) { Remove-Item -LiteralPath $dstDir -Recurse -Force -Confirm:$false -ErrorAction Stop }
      New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
      Copy-Item -Path (Join-Path $srcDir '*') -Destination $dstDir -Recurse -Force -ErrorAction Stop
    }

    foreach ($rel in $C3_PROTOCOL_PACK_FILES) {
      $src = Join-Path $Context.EngineRoot (Convert-PosixPathToNative $rel)
      if (Test-Path $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $rel)) -Force -ErrorAction Stop
      }
    }

    # Run artifacts from THIS run, preserving storage_ref paths
    foreach ($dst in @(
      (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.LockedSpec)),
      (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.GateVerdictQ)),
      (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.GateVerdictR)),
      (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.EvidenceManifestR)),
      (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.PromptBlockHashes))
    )) {
      $dstDir = Split-Path -Parent $dst
      if (!(Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    }

    Copy-Item -LiteralPath ($Context.RepoRelToAbs($Context.Rel.LockedSpec)) -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.LockedSpec)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath ($Context.RepoRelToAbs($Context.Rel.GateVerdictQ)) -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.GateVerdictQ)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath ($Context.RepoRelToAbs($Context.Rel.GateVerdictR)) -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.GateVerdictR)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestR)) -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.EvidenceManifestR)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath ($Context.RepoRelToAbs($Context.Rel.PromptBlockHashes)) -Destination (Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.PromptBlockHashes)) -Force -ErrorAction Stop

    $sandboxDocsAbs = Join-Path $c3SandboxAbs 'docs'
    New-Item -ItemType Directory -Force -Path $sandboxDocsAbs | Out-Null
    Copy-Item -LiteralPath $tmplAbs -Destination (Join-Path $sandboxDocsAbs 'DocsCompiler.template.md') -Force -ErrorAction Stop

    $pyForSandbox = Get-PythonForCwd -Context $Context -Cwd $c3SandboxAbs

    $c3Args = @(
      '-m','chain.compiler_c3_docs',
      '--repo','.',
      '--locked-spec',$Context.Rel.LockedSpec,
      '--gate-q-verdict',$Context.Rel.GateVerdictQ,
      '--gate-r-verdict',$Context.Rel.GateVerdictR,
      '--r-snapshot-manifest',$Context.Rel.EvidenceManifestR,
      '--out-final-manifest',$Context.Rel.EvidenceManifestFinal,
      '--out-log',$Context.Rel.DocsCompilationLogCanonical,
      '--out-docs',$Context.Rel.DocsMd,
      '--out-bundle-dir',$Context.Rel.DocsBundleDir,
      '--out-bundle-root-sha',$Context.Rel.DocsBundleRootSha,
      '--profile',$Context.PublicationProfile,
      '--prompt-block-hashes',$Context.Rel.PromptBlockHashes,
      '--template','docs/DocsCompiler.template.md'
    )
    Invoke-BelgiTool -Context $Context -Label 'C3-DocsCompiler' -Cwd $c3SandboxAbs -PyCmd $pyForSandbox -Arguments $c3Args | Out-Null

    # Copy outputs back
    $sandboxFinalManifestAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.EvidenceManifestFinal)
    $sandboxDocsMdAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.DocsMd)
    $sandboxBundleDirAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.DocsBundleDir)
    $sandboxBundleRootShaAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.DocsBundleRootSha)
    $sandboxBundleManifestAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.DocsBundleManifest)
    $sandboxDocsLogAbs = Join-Path $c3SandboxAbs (Convert-PosixPathToNative $Context.Rel.DocsCompilationLogCanonical)

    Ensure-File -Path $sandboxFinalManifestAbs -Label 'C3 (sandbox final manifest)' -RunDirAbs (Split-Path -Parent $sandboxFinalManifestAbs)
    Ensure-File -Path $sandboxDocsMdAbs -Label 'C3 (sandbox docs markdown)' -RunDirAbs (Split-Path -Parent $sandboxDocsMdAbs)
    Ensure-File -Path $sandboxBundleRootShaAbs -Label 'C3 (sandbox bundle_root_sha256)' -RunDirAbs (Split-Path -Parent $sandboxBundleRootShaAbs)
    Ensure-File -Path $sandboxBundleManifestAbs -Label 'C3 (sandbox docs bundle manifest)' -RunDirAbs (Split-Path -Parent $sandboxBundleManifestAbs)
    Ensure-File -Path $sandboxDocsLogAbs -Label 'C3 (sandbox docs_compilation_log)' -RunDirAbs (Split-Path -Parent $sandboxDocsLogAbs)

    foreach ($dstAbs in @(
      $Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal),
      $Context.RepoRelToAbs($Context.Rel.DocsMd),
      $Context.RepoRelToAbs($Context.Rel.DocsBundleRootSha),
      $Context.RepoRelToAbs($Context.Rel.DocsBundleManifest),
      (Join-Path $Context.RepoRoot (Convert-PosixPathToNative $Context.Rel.DocsCompilationLogCanonical)),
      $Context.RepoRelToAbs($Context.Rel.DocsCompilationLogMirror)
    )) {
      $dstDir = Split-Path -Parent $dstAbs
      if ($dstDir -and !(Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    }

    Copy-Item -LiteralPath $sandboxFinalManifestAbs -Destination ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath $sandboxDocsMdAbs -Destination ($Context.RepoRelToAbs($Context.Rel.DocsMd)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath $sandboxBundleRootShaAbs -Destination ($Context.RepoRelToAbs($Context.Rel.DocsBundleRootSha)) -Force -ErrorAction Stop
    Copy-Item -LiteralPath $sandboxBundleManifestAbs -Destination ($Context.RepoRelToAbs($Context.Rel.DocsBundleManifest)) -Force -ErrorAction Stop

    $runBundleAbs = $Context.RepoRelToAbs($Context.Rel.DocsBundleDir)
    if (Test-Path $runBundleAbs) { Remove-Item -LiteralPath $runBundleAbs -Recurse -Force -Confirm:$false -ErrorAction Stop }
    New-Item -ItemType Directory -Force -Path $runBundleAbs | Out-Null
    Copy-Item -Path (Join-Path $sandboxBundleDirAbs '*') -Destination $runBundleAbs -Recurse -Force -ErrorAction Stop

    $canonAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $Context.Rel.DocsCompilationLogCanonical)
    Copy-Item -LiteralPath $sandboxDocsLogAbs -Destination $canonAbs -Force -ErrorAction Stop
    Copy-Item -LiteralPath $sandboxDocsLogAbs -Destination ($Context.RepoRelToAbs($Context.Rel.DocsCompilationLogMirror)) -Force -ErrorAction Stop

    Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)) -Label 'C3 (Final EvidenceManifest)' -RunDirAbs $Context.BelgiRunAbs
  } finally {
    try {
      if (Test-Path $c3SandboxAbs) { Remove-Item -LiteralPath $c3SandboxAbs -Recurse -Force -Confirm:$false -ErrorAction Stop }
    } catch { $cleanupErr = $_ }
    if ($null -ne $cleanupErr) {
      throw ("Fail-closed: C3 sandbox cleanup failed: " + $cleanupErr.Exception.Message)
    }
  }
}

function Invoke-StepSeal {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host 'SEAL: seal bundle -> SealManifest.' -ForegroundColor Cyan
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)) -Label 'C3 (Final EvidenceManifest)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictQ)) -Label 'Q (GateVerdict.Q)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.GateVerdictR)) -Label 'R (GateVerdict.R)' -RunDirAbs $Context.BelgiRunAbs

  $finalCommitSha = Get-BelgiCommitSha -RepoRootAbs (Get-GitRootAbs -Context $Context)
  $sealCmd = @(
    '-m','chain.seal_bundle',
    '--repo','.',
    '--locked-spec',$Context.Rel.LockedSpec,
    '--gate-q-verdict',$Context.Rel.GateVerdictQ,
    '--gate-r-verdict',$Context.Rel.GateVerdictR,
    '--evidence-manifest',$Context.Rel.EvidenceManifestFinal,
    '--final-commit-sha',$finalCommitSha,
    '--sealed-at',$Context.SealedAtUtc,
    '--signer',$Context.SealSigner,
    '--out',$Context.Rel.SealManifest
  )
  Invoke-BelgiTool -Context $Context -Label 'SEAL-Bundle' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $sealCmd | Out-Null
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.SealManifest)) -Label 'SEAL (SealManifest)' -RunDirAbs $Context.BelgiRunAbs
}

function Invoke-StepS {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [switch]$AllowNoGo,
    [switch]$VerifyOnly
  )

  if ($VerifyOnly) {
    Write-Host 'S-VERIFY: verify-only (uses existing SealManifest + final EvidenceManifest).' -ForegroundColor Cyan
    Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.SealManifest)) -Label 'SEAL (SealManifest)' -RunDirAbs $Context.BelgiRunAbs
    Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)) -Label 'C3 (Final EvidenceManifest)' -RunDirAbs $Context.BelgiRunAbs
    $exitCode = Invoke-BelgiTool -Context $Context -Label 'GateS-Only' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.SVERIFY -AllowExitCodes @(2)
    $svAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictSVerify)
    Ensure-File -Path $svAbs -Label 'S-VERIFY (GateVerdict.S)' -RunDirAbs $Context.BelgiRunAbs
    Show-GateVerdictSummary -Label 'S (verify-only)' -AbsPath $svAbs
    if ($exitCode -ne 0) { throw 'Gate S NO-GO (verify-only).' }
    return
  }

  Write-Host 'S: verify seal integrity -> GateVerdict.S.' -ForegroundColor Cyan
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.SealManifest)) -Label 'SEAL (SealManifest)' -RunDirAbs $Context.BelgiRunAbs
  Ensure-File -Path ($Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)) -Label 'C3 (Final EvidenceManifest)' -RunDirAbs $Context.BelgiRunAbs
  $exitCode = Invoke-BelgiTool -Context $Context -Label 'GateS' -Cwd $Context.RepoRoot -PyCmd $Context.PythonCmd -Arguments $Context.Commands.S -AllowExitCodes @(2)
  $sAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictS)
  Ensure-File -Path $sAbs -Label 'S (GateVerdict.S)' -RunDirAbs $Context.BelgiRunAbs
  Show-GateVerdictSummary -Label 'S' -AbsPath $sAbs
  if ($exitCode -ne 0) {
    if ($AllowNoGo) {
      Write-Host 'Continuing despite Gate S NO-GO (AllowNoGo enabled).' -ForegroundColor Yellow
      return
    }
    throw 'Gate S NO-GO.'
  }
}

function Invoke-ChainAll {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [switch]$AllowNoGo
  )

  Invoke-StepC1 -Context $Context
  Invoke-StepQ -Context $Context
  Invoke-StepR -Context $Context -AllowNoGo:$AllowNoGo
  Invoke-StepC3 -Context $Context
  Invoke-StepSeal -Context $Context
  Invoke-StepS -Context $Context -AllowNoGo:$AllowNoGo
  Write-Host "`nOK: all steps completed." -ForegroundColor Green
}

function Invoke-GuidedDemo {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  if (-not $Context.Interactive) { throw 'demo requires interactive mode.' }

  # ============================================================
  # WELCOME
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Cyan
  Write-Host '║           BELGI GUIDED DEMO (Interactive)                    ║' -ForegroundColor Cyan
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'This demo walks you through the BELGI chain and shows how each' -ForegroundColor Gray
  Write-Host 'gate catches different types of violations.' -ForegroundColor Gray
  Write-Host ''
  Write-Host 'Demo structure:' -ForegroundColor Yellow
  Write-Host '  PART 1: Gate Q - Detects LockedSpec tampering' -ForegroundColor Gray
  Write-Host '  PART 2: Gate R - Detects forbidden path changes' -ForegroundColor Gray
  Write-Host '  PART 3: Gate R - Allows valid changes (recovery)' -ForegroundColor Gray
  Write-Host '  PART 4: Gate S - Detects post-seal tampering' -ForegroundColor Gray
  Write-Host ''
  Show-RunPaths -Context $Context
  Read-EnterOnly -Prompt 'Press Enter to begin the demo'

  # ============================================================
  # PART 1: GATE Q - TAMPERING DETECTION
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
  Write-Host '║  PART 1: Gate Q - LockedSpec Tampering Detection             ║' -ForegroundColor Yellow
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'First, we run C1 (compile intent) and Q (verify) normally.' -ForegroundColor Cyan
  Write-Host 'This should PASS because nothing has been tampered.' -ForegroundColor Cyan
  Write-Host ''
  Read-EnterOnly -Prompt 'Press Enter to run C1 and Q'
  
  Invoke-StepC1 -Context $Context
  Invoke-StepQ -Context $Context
  
  Write-Host ''
  Write-Host 'Gate Q passed. Now lets TAMPER with LockedSpec.json!' -ForegroundColor Green
  Write-Host ''
  Invoke-QTamper -Context $Context -Pause
  
  Write-Host ''
  Write-Host 'Running Gate Q again (should FAIL due to tampering)...' -ForegroundColor Yellow
  Write-Host ''
  try { 
    Invoke-StepQ -Context $Context 
    Write-Host 'UNEXPECTED: Gate Q passed after tampering!' -ForegroundColor Red
  } catch { 
    Write-Host ''
    Write-Host 'SUCCESS: Gate Q detected the tampering and returned NO-GO!' -ForegroundColor Green
  }
  
  Write-Host ''
  Write-Host 'Recovery: Re-running C1 to regenerate a clean LockedSpec...' -ForegroundColor Cyan
  Read-EnterOnly -Prompt 'Press Enter to regenerate'
  Invoke-StepC1 -Context $Context
  Invoke-StepQ -Context $Context
  Write-Host ''
  Write-Host 'Clean state restored.' -ForegroundColor Green

  # ============================================================
  # PART 2: GATE R - FORBIDDEN PATH VIOLATION
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
  Write-Host '║  PART 2: Gate R - Forbidden Path Detection                   ║' -ForegroundColor Yellow
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Gate R checks that code changes are only in allowed directories.' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Allowed paths:     target_service/src/, target_service/docs/' -ForegroundColor Green
  Write-Host 'Forbidden paths:   target_service/private/' -ForegroundColor Red
  Write-Host ''
  Write-Host 'We need to create a change in the FORBIDDEN private/ directory' -ForegroundColor Yellow
  Write-Host 'and commit it. Gate R should detect this and return NO-GO.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Steps (if manual):' -ForegroundColor DarkGray
  Write-Host '  1. Create/edit a file under target_service/private/' -ForegroundColor DarkGray
  Write-Host '  2. git add -A ; git commit -m "forbidden change"' -ForegroundColor DarkGray
  Write-Host ''
  Write-Host 'Or we can auto-create the forbidden change for you.' -ForegroundColor DarkGray
  Write-Host ''
  
  $choice = Read-Host 'Auto-create forbidden change? (Y/n)'
  if ($choice -ne 'n' -and $choice -ne 'N') {
    Ensure-ForbiddenPrivateChangeCommitted -Context $Context
    Write-Host ''
    Write-Host 'Forbidden change auto-created and committed.' -ForegroundColor Cyan
  } else {
    Write-Host ''
    Write-Host 'Manual mode: Create a file under target_service/private/ and commit it.' -ForegroundColor Yellow
    Read-EnterOnly -Prompt 'Press Enter after you have committed the forbidden change'
  }
  
  Write-Host ''
  Write-Host 'Running Gate R...' -ForegroundColor Yellow
  Write-Host ''
  
  Invoke-StepR -Context $Context -AllowNoGo
  $rAbs = $Context.RepoRelToAbs($Context.Rel.GateVerdictR)
  $rStatus = Get-GateVerdictStatus -VerdictPath $rAbs
  
  # Show the diff.patch that R evaluated
  $diffAbs = $Context.RepoRelToAbs($Context.Rel.DiffPatch)
  if (Test-Path $diffAbs) {
    Write-Host ''
    Write-Host 'diff.patch (what Gate R evaluated):' -ForegroundColor DarkGray
    Write-Host ('  ' + $diffAbs) -ForegroundColor DarkGray
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
    $diffContent = Get-Content $diffAbs -Raw -ErrorAction SilentlyContinue
    if ($diffContent) {
      $lines = $diffContent -split "`n" | Select-Object -First 30
      foreach ($line in $lines) {
        $color = 'Gray'
        if ($line -match '^\+') { $color = 'Green' }
        elseif ($line -match '^-') { $color = 'Red' }
        elseif ($line -match '^@@') { $color = 'Cyan' }
        elseif ($line -match '^diff ') { $color = 'Yellow' }
        Write-Host ('  ' + $line) -ForegroundColor $color
      }
      if (($diffContent -split "`n").Count -gt 30) {
        Write-Host '  ... (truncated, see full file)' -ForegroundColor DarkGray
      }
    }
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
  }
  
  if ($rStatus -eq 'ok') {
    Write-Host ''
    Write-Host 'UNEXPECTED: Gate R passed! Check your IntentSpec allowed_paths.' -ForegroundColor Red
  } else {
    Write-Host ''
    Write-Host 'SUCCESS: Gate R detected the forbidden path change!' -ForegroundColor Green
  }

  # ============================================================
  # PART 3: GATE R - VALID CHANGE (RECOVERY)
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
  Write-Host '║  PART 3: Gate R - Valid Change (Recovery)                    ║' -ForegroundColor Yellow
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'Now lets revert the forbidden change and make a VALID change' -ForegroundColor Cyan
  Write-Host 'under target_service/src/ instead.' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Steps:' -ForegroundColor Yellow
  Write-Host '  1. git revert HEAD --no-edit     (undo forbidden change)' -ForegroundColor Gray
  Write-Host '  2. Edit target_service/src/service.py (add a comment)' -ForegroundColor Gray
  Write-Host '  3. git add -A ; git commit -m "valid change"' -ForegroundColor Gray
  Write-Host ''
  Write-Host 'Or skip manually - we can auto-create a valid change for you.' -ForegroundColor DarkGray
  Write-Host ''
  
  $choice = Read-Host 'Auto-create valid change? (Y/n)'
  if ($choice -ne 'n' -and $choice -ne 'N') {
    # Revert forbidden change
    Write-Host ''
    Write-Host 'Reverting forbidden change...' -ForegroundColor Cyan
    & git -C $Context.PlaygroundRoot revert HEAD --no-edit 2>$null
    
    # Make valid change
    $serviceFile = Join-Path $Context.RepoRoot 'src\service.py'
    if (Test-Path $serviceFile) {
      $content = Get-Content $serviceFile -Raw
      $content = $content + "`n# Demo: valid change under allowed path`n"
      Set-Content -Path $serviceFile -Value $content -NoNewline
      & git -C $Context.PlaygroundRoot add -A
      & git -C $Context.PlaygroundRoot commit -m "demo: valid change under src/"
      Write-Host 'Valid change committed.' -ForegroundColor Green
    } else {
      Write-Host 'Could not find service.py - please make a manual change.' -ForegroundColor Yellow
      Read-EnterOnly -Prompt 'Press Enter after committing your change'
    }
  } else {
    Read-EnterOnly -Prompt 'Press Enter after you have reverted and made a valid commit'
  }
  
  Write-Host ''
  Write-Host 'Re-running Gate R (Q already passed, LockedSpec unchanged)...' -ForegroundColor Cyan
  Write-Host ''
  Invoke-StepR -Context $Context -AllowNoGo
  
  # Show the diff.patch that R evaluated
  $diffAbs = $Context.RepoRelToAbs($Context.Rel.DiffPatch)
  if (Test-Path $diffAbs) {
    Write-Host ''
    Write-Host 'diff.patch (what Gate R evaluated):' -ForegroundColor DarkGray
    Write-Host ('  ' + $diffAbs) -ForegroundColor DarkGray
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
    $diffContent = Get-Content $diffAbs -Raw -ErrorAction SilentlyContinue
    if ($diffContent) {
      $lines = $diffContent -split "`n" | Select-Object -First 30
      foreach ($line in $lines) {
        $color = 'Gray'
        if ($line -match '^\+') { $color = 'Green' }
        elseif ($line -match '^-') { $color = 'Red' }
        elseif ($line -match '^@@') { $color = 'Cyan' }
        elseif ($line -match '^diff ') { $color = 'Yellow' }
        Write-Host ('  ' + $line) -ForegroundColor $color
      }
      if (($diffContent -split "`n").Count -gt 30) {
        Write-Host '  ... (truncated, see full file)' -ForegroundColor DarkGray
      }
    }
    Write-Host '  ─────────────────────────────────────────' -ForegroundColor DarkGray
  }
  
  $rStatus2 = Get-GateVerdictStatus -VerdictPath $rAbs
  if ($rStatus2 -eq 'ok') {
    Write-Host ''
    Write-Host 'SUCCESS: Gate R passed with valid changes!' -ForegroundColor Green
  } else {
    Write-Host ''
    Write-Host 'Gate R still failing - check the GateReport for details.' -ForegroundColor Yellow
  }

  # ============================================================
  # PART 4: GATE S - POST-SEAL INTEGRITY
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Yellow
  Write-Host '║  PART 4: Gate S - Post-Seal Integrity Check                  ║' -ForegroundColor Yellow
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Yellow
  Write-Host ''
  Write-Host 'First, we complete the chain: C3 (docs) -> SEAL -> S (verify)' -ForegroundColor Cyan
  Write-Host ''
  Read-EnterOnly -Prompt 'Press Enter to run C3, SEAL, and S'
  
  Invoke-StepC3 -Context $Context
  Invoke-StepSeal -Context $Context
  Invoke-StepS -Context $Context
  
  Write-Host ''
  Write-Host 'Chain completed successfully!' -ForegroundColor Green
  Write-Host ''
  Write-Host 'Now lets test Gate S integrity by TAMPERING with a sealed artifact.' -ForegroundColor Cyan
  Write-Host 'Gate S verifies that SealManifest hashes match actual artifact bytes.' -ForegroundColor Cyan
  Write-Host ''
  Write-Host 'Files you can tamper (add/remove whitespace, change a value):' -ForegroundColor Yellow
  $manifestAbs = $Context.RepoRelToAbs($Context.Rel.EvidenceManifestFinal)
  $sealAbs = $Context.RepoRelToAbs($Context.Rel.SealManifest)
  Write-Host "  EvidenceManifest: $manifestAbs" -ForegroundColor DarkGray
  Write-Host "  (Do NOT edit SealManifest - that's what we verify against)" -ForegroundColor DarkGray
  Write-Host ''
  Write-Host 'Or we can auto-tamper EvidenceManifest.final.json for you.' -ForegroundColor DarkGray
  Write-Host ''
  
  $choice = Read-Host 'Auto-tamper and verify? (Y/n)'
  if ($choice -ne 'n' -and $choice -ne 'N') {
    Invoke-TamperAndSVerifyDemo -Context $Context
  } else {
    Write-Host ''
    Write-Host 'Manual mode: Edit the EvidenceManifest file above, then we will run S-verify.' -ForegroundColor Yellow
    Read-EnterOnly -Prompt 'Press Enter after you have tampered with the file'
    Write-Host ''
    Write-Host 'Running Gate S verify-only...' -ForegroundColor Yellow
    try {
      Invoke-StepS -Context $Context -VerifyOnly
      Write-Host ''
      Write-Host 'Gate S verify-only returned GO - your tampering was not detected!' -ForegroundColor Yellow
      Write-Host 'Try a more obvious change (add whitespace at end of file).' -ForegroundColor Yellow
    } catch {
      Write-Host ''
      Write-Host 'SUCCESS: Gate S verify-only produced NO-GO!' -ForegroundColor Green
      Write-Host 'Your tampering was detected.' -ForegroundColor Green
    }
  }

  # ============================================================
  # DEMO COMPLETE
  # ============================================================
  Write-Host ''
  Write-Host '╔══════════════════════════════════════════════════════════════╗' -ForegroundColor Green
  Write-Host '║                    DEMO COMPLETE!                            ║' -ForegroundColor Green
  Write-Host '╚══════════════════════════════════════════════════════════════╝' -ForegroundColor Green
  Write-Host ''
  Write-Host 'You have seen how BELGI gates catch:' -ForegroundColor Cyan
  Write-Host '  - Gate Q: LockedSpec tampering (intent mismatch)' -ForegroundColor Gray
  Write-Host '  - Gate R: Forbidden path changes' -ForegroundColor Gray
  Write-Host '  - Gate R: Validates allowed path changes' -ForegroundColor Gray
  Write-Host '  - Gate S: Post-seal artifact tampering' -ForegroundColor Gray
  Write-Host ''
  Write-Host 'NEXT STEP: Run "repro" to verify deterministic reproducibility.' -ForegroundColor Yellow
  Write-Host ''
  Read-EnterOnly -Prompt 'Press Enter to return to HUD'
}

function Invoke-Repro {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][RunContext]$Context)

  Write-Host ''
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Host 'REPRO: Reproducibility Check' -ForegroundColor Cyan
  Write-Host '========================================' -ForegroundColor Cyan
  Write-Host '  Using fixed sealed_at timestamp (2000-01-01T00:00:00Z) for determinism.' -ForegroundColor DarkGray
  Write-Host ''

  $outBase = $Context.OutDirBaseRelPosix
  $runningDir = "${outBase}/repro_running"
  $runADir = "${outBase}/repro_a"
  $runBDir = "${outBase}/repro_b"
  $runName = 'run_repro'

  $runningAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $runningDir)
  $runAAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $runADir)
  $runBAbs = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $runBDir)

  # Clean up any previous repro runs
  foreach ($d in @($runningAbs, $runAAbs, $runBAbs)) {
    if (Test-Path $d) { Remove-Item -LiteralPath $d -Recurse -Force -Confirm:$false -ErrorAction Stop }
  }

  $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'run_chain.ps1'
  $fixedTimestamp = '2000-01-01T00:00:00Z'
  $playgroundRoot = $Context.PlaygroundRoot
  $cacheDir = $Context.Config.Defaults.CacheDir
  $logsDir = Join-Path $Context.RepoRoot (Convert-PosixPathToNative $outBase)
  if (!(Test-Path $logsDir)) { New-Item -ItemType Directory -Force -Path $logsDir | Out-Null }

  # Helper to run a repro subprocess with full isolation
  function Invoke-ReproSubprocess([string]$label, [string]$outDir) {
    $logFile = Join-Path $logsDir "repro_${label}_log.txt"
    $errFile = Join-Path $logsDir "repro_${label}_err.txt"
    
    Write-Host "  [$label] Starting chain run (OutDirBase=${outDir})..." -ForegroundColor Yellow
    
    $psExe = if ($env:OS -eq 'Windows_NT') { 'powershell.exe' } else { 'pwsh' }
    if (!(Get-Command $psExe -ErrorAction SilentlyContinue)) {
      throw "Fail-closed: '${psExe}' not found. Install PowerShell (pwsh) and ensure it's on PATH."
    }
    $psArgs = @('-NoProfile', '-NonInteractive')
    if ($env:OS -eq 'Windows_NT') { $psArgs += @('-ExecutionPolicy', 'Bypass') }
    $psArgs += @(
      '-File', $scriptPath,
      '-CacheDir', $cacheDir,
      '-SealedAtUtc', $fixedTimestamp,
      '-OutDirBase', $outDir,
      '-RunDirName', $runName,
      '-ForceCleanRun', '-AllowNoGo', '-Auto'
    )

    $proc = Start-Process -FilePath $psExe -ArgumentList $psArgs -WorkingDirectory $playgroundRoot -Wait -PassThru -RedirectStandardOutput $logFile -RedirectStandardError $errFile
    
    $exitCode = $proc.ExitCode
    Write-Host "  [$label] Completed with exit code: $exitCode" -ForegroundColor $(if ($exitCode -eq 0) { 'Green' } else { 'Red' })
    
    return $exitCode
  }

  # Run A
  Write-Host ''
  $exitA = Invoke-ReproSubprocess -label 'A' -outDir $runningDir
  if ($exitA -ne 0) {
    Write-Host "  [A] FAILED - check repro_A_log.txt and repro_A_err.txt" -ForegroundColor Red
    throw "Repro run A failed (exit $exitA)."
  }

  # Rename running -> a
  $runAFinal = Join-Path $runningAbs $runName
  if (!(Test-Path $runAFinal)) { throw "Run A folder missing: ${runAFinal}" }
  Rename-Item -LiteralPath $runningAbs -NewName 'repro_a' -Force
  $runAFinal = Join-Path $runAAbs $runName
  Write-Host "  [A] Saved to: repro_a/" -ForegroundColor Green

  # Run B
  Write-Host ''
  $exitB = Invoke-ReproSubprocess -label 'B' -outDir $runningDir
  if ($exitB -ne 0) {
    Write-Host "  [B] FAILED - check repro_B_log.txt and repro_B_err.txt" -ForegroundColor Red
    throw "Repro run B failed (exit $exitB)."
  }

  # Rename running -> b
  $runBFinal = Join-Path $runningAbs $runName
  if (!(Test-Path $runBFinal)) { throw "Run B folder missing: ${runBFinal}" }
  Rename-Item -LiteralPath $runningAbs -NewName 'repro_b' -Force
  $runBFinal = Join-Path $runBAbs $runName
  Write-Host "  [B] Saved to: repro_b/" -ForegroundColor Green

  # Compare
  Write-Host ''
  Write-Host 'Comparing deterministic artifacts:' -ForegroundColor Cyan
  Write-Host "  A: $runAFinal" -ForegroundColor DarkGray
  Write-Host "  B: $runBFinal" -ForegroundColor DarkGray
  Write-Host ''

  function Get-FileSig([string]$absPath) {
    if (!(Test-Path $absPath)) { return @{ hash = '(missing)'; bytes = 0 } }
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $absPath -ErrorAction Stop).Hash.ToLowerInvariant()
    $len = (Get-Item -LiteralPath $absPath -ErrorAction Stop).Length
    return @{ hash = $h; bytes = [int64]$len }
  }

  $artifacts = @(
    'LockedSpec.json',
    'EvidenceManifest.R.json',
    'EvidenceManifest.final.json',
    'docs/bundle_root_sha256.txt',
    'SealManifest.json',
    'GateVerdict.S.json'
  )

  $mismatches = @()
  foreach ($rel in $artifacts) {
    $pathA = Join-Path $runAFinal (Convert-PosixPathToNative $rel)
    $pathB = Join-Path $runBFinal (Convert-PosixPathToNative $rel)
    $sigA = Get-FileSig $pathA
    $sigB = Get-FileSig $pathB
    $match = ($sigA.hash -eq $sigB.hash -and $sigA.bytes -eq $sigB.bytes)
    
    if ($match -and $sigA.hash -ne '(missing)') {
      Write-Host ("  [OK]   " + $rel) -ForegroundColor Green
      Write-Host ("         Hash: " + $sigA.hash.Substring(0,16) + "...") -ForegroundColor DarkGray
    } else {
      Write-Host ("  [FAIL] " + $rel) -ForegroundColor Red
      Write-Host ("         A: " + $sigA.hash) -ForegroundColor Yellow
      Write-Host ("         B: " + $sigB.hash) -ForegroundColor Yellow
      $mismatches += $rel
    }
  }

  Write-Host ''
  if ($mismatches.Count -gt 0) {
    Write-Host '========================================' -ForegroundColor Red
    Write-Host "REPRO FAILED: $($mismatches.Count) artifact(s) differ!" -ForegroundColor Red
    Write-Host '========================================' -ForegroundColor Red
    Write-Host ''
    Write-Host 'Output directories preserved for inspection:' -ForegroundColor Yellow
    Write-Host "  A: $runAFinal" -ForegroundColor DarkGray
    Write-Host "  B: $runBFinal" -ForegroundColor DarkGray
    Write-Host ''
    if ($Context.Interactive) { [void](Read-Host 'Press Enter to continue') }
    throw 'Reproducibility check FAILED.'
  }

  Write-Host '========================================' -ForegroundColor Green
  Write-Host 'REPRO PASSED: All artifacts match!' -ForegroundColor Green
  Write-Host '========================================' -ForegroundColor Green
  Write-Host ''
  Write-Host 'Output directories preserved for inspection:' -ForegroundColor DarkGray
  Write-Host "  A: $runAFinal" -ForegroundColor DarkGray
  Write-Host "  B: $runBFinal" -ForegroundColor DarkGray
  Write-Host ''
  if ($Context.Interactive) { [void](Read-Host 'Press Enter to return to HUD') }
}
