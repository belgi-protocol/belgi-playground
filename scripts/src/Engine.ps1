Set-StrictMode -Version Latest

function Get-RepoRoot {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$ScriptRoot)
  Split-Path -Parent $ScriptRoot
}

function Convert-PosixPathToNative {
  [CmdletBinding()]
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  $sep = [string][System.IO.Path]::DirectorySeparatorChar
  return ($Path -replace '[\\/]', $sep)
}

function Get-LeafFromPosixPath {
  [CmdletBinding()]
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  $parts = $Path -split '/'
  return $parts[$parts.Length - 1]
}

function Assert-NoDriveQualifiedArgs {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$CommandLine
  )
  if ($CommandLine -match '(?i)(^|\s)[a-z]:[\\/]') {
    throw "Bug: drive-qualified paths are not allowed in CLI args ($Label)."
  }
}

function Get-RelativePathFailClosed {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$FromDir,
    [Parameter(Mandatory=$true)][string]$ToPath
  )

  $fromFull = (Resolve-Path -LiteralPath $FromDir).Path.TrimEnd([char]'\',[char]'/')
  $toFull = (Resolve-Path -LiteralPath $ToPath).Path.TrimEnd([char]'\',[char]'/')

  # On Windows, ensure we don't cross drives (would force drive-qualified paths).
  # On macOS/Linux, Split-Path -Qualifier is not applicable and will error.
  if ($env:OS -eq 'Windows_NT') {
    $fromQual = (Split-Path -Qualifier $fromFull)
    $toQual = (Split-Path -Qualifier $toFull)
    if ($fromQual -and $toQual -and ($fromQual.ToLowerInvariant() -ne $toQual.ToLowerInvariant())) {
      throw "Fail-closed: unable to compute a drive-qualified-free relative path from '$FromDir' to '$ToPath'. Ensure the repo and venv are on the same drive."
    }
  }

  $fromParts = ($fromFull -split '[\\/]+')
  $toParts = ($toFull -split '[\\/]+')

  $commonLen = 0
  $maxCommon = [Math]::Min($fromParts.Length, $toParts.Length)
  for ($i = 0; $i -lt $maxCommon; $i++) {
    if ($fromParts[$i].ToLowerInvariant() -ne $toParts[$i].ToLowerInvariant()) { break }
    $commonLen++
  }

  $relParts = @()
  for ($i = $commonLen; $i -lt $fromParts.Length; $i++) { $relParts += '..' }
  for ($i = $commonLen; $i -lt $toParts.Length; $i++) { $relParts += $toParts[$i] }

  if ($relParts.Count -eq 0) { $relParts = @('.') }
  $sep = [string][System.IO.Path]::DirectorySeparatorChar
  $rel = ($relParts -join $sep)
  if ($rel -match '(?i)^[a-z]:[\\/]') {
    throw "Fail-closed: unable to compute a drive-qualified-free relative path from '$FromDir' to '$ToPath'. Ensure the repo and venv are on the same drive."
  }
  return $rel
}

function Resolve-PythonCommand {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$PlaygroundRoot)

  # IMPORTANT: do not return an absolute path; command lines must not contain drive-qualified paths.
  $venvPyWin = Join-Path $PlaygroundRoot (Convert-PosixPathToNative '.venv/Scripts/python.exe')
  if (Test-Path $venvPyWin) {
    # Caller runs steps with cwd = target_service, so the venv is one directory up.
    return (Convert-PosixPathToNative '../.venv/Scripts/python.exe')
  }

  $venvPyUnix = Join-Path $PlaygroundRoot (Convert-PosixPathToNative '.venv/bin/python')
  if (Test-Path $venvPyUnix) {
    return (Convert-PosixPathToNative '../.venv/bin/python')
  }

  try { & py -3.13 -c "print(1)" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return 'py -3.13' } } catch {}
  try { & py -3 -c "print(1)" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return 'py -3' } } catch {}
  try { & python3 -c "print(1)" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return 'python3' } } catch {}
  try { & python -c "print(1)" 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return 'python' } } catch {}
  throw 'No Python found. Run scripts/bootstrap.ps1 first (it creates .venv).'
}

function Write-Utf8NoBomLf {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [AllowNull()][string]$Text
  )

  $dir = Split-Path -Parent $Path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  if ($null -eq $Text) { $Text = '' }
  $norm = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
  if ($norm.Length -gt 0 -and -not $norm.EndsWith("`n")) { $norm = $norm + "`n" }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $norm, $utf8NoBom)
}

function Ensure-TextFileExists {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Label
  )

  $dir = Split-Path -Parent $Path
  if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  if (!(Test-Path $Path)) { Write-Utf8NoBomLf -Path $Path -Text '' }
  if (!(Test-Path $Path)) { throw "Fail-closed: unable to create $Label at: $Path" }

  $raw = ''
  try { $raw = (Get-Content -Path $Path -Raw -ErrorAction Stop) } catch { throw "Fail-closed: unable to read $Label at: $Path" }
  $rawText = if ($raw -is [System.Array]) { ($raw -join "`n") } else { [string]$raw }
  $trim = [string]($rawText -replace '^\s+', '')
  if ($trim.StartsWith('{') -or $trim.StartsWith('[')) {
    throw "Fail-closed: $Label must be text/plain (not JSON-y): $Path"
  }
}

function Append-LineUtf8NoBomLf {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$Line
  )

  Ensure-TextFileExists -Path $Path -Label $Label
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $norm = ($Line -replace "`r`n", "`n") -replace "`r", "`n"
  if (!$norm.EndsWith("`n")) { $norm = $norm + "`n" }
  try {
    [System.IO.File]::AppendAllText($Path, $norm, $utf8NoBom)
  } catch {
    throw "Fail-closed: unable to append to ${Label}: ${Path}"
  }
}

function Read-Json {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$Path)
  try { return (Get-Content -Path $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Ensure-File {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$RunDirAbs
  )

  if (Test-Path $Path) { return }

  Write-Host ''
  Write-Host "BLOCKER: expected file missing after ${Label}:" -ForegroundColor Red
  Write-Host ("  " + $Path) -ForegroundColor Red
  Write-Host ''
  Write-Host 'Directory dump (run dir):' -ForegroundColor Yellow
  if (Test-Path $RunDirAbs) {
    Get-ChildItem -Recurse -File $RunDirAbs | ForEach-Object { Write-Host ("  " + $_.FullName) }
  } else {
    Write-Host '  (run dir does not exist)'
  }
  throw "Missing output: $Label"
}

function Get-BelgiCommitSha {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$RepoRootAbs)

  try {
    $sha = (& git -C $RepoRootAbs rev-parse HEAD 2>$null).Trim()
    if ($sha -match '^[0-9a-f]{40}$') { return $sha }
  } catch {}

  $headPath = Join-Path (Join-Path $RepoRootAbs '.git') 'HEAD'
  if (Test-Path $headPath) {
    $head = (Get-Content -Path $headPath -TotalCount 1).Trim()
    if ($head -match '^ref: (.+)$') {
      $refRel = Convert-PosixPathToNative $Matches[1]
      $refPath = Join-Path (Join-Path $RepoRootAbs '.git') $refRel
      if (Test-Path $refPath) {
        $sha = (Get-Content -Path $refPath -TotalCount 1).Trim()
        if ($sha -match '^[0-9a-f]{40}$') { return $sha }
      }
    } elseif ($head -match '^[0-9a-f]{40}$') {
      return $head
    }
  }

  throw 'Unable to determine commit SHA.'
}

function Invoke-BelgiTool {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][RunContext]$Context,
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$Cwd,
    [Parameter(Mandatory=$true)][string]$PyCmd,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [int[]]$AllowExitCodes = @(),
    [int]$WinFileLockRetries = 6,
    [int]$WinFileLockBaseDelayMs = 120
  )

  if (!$Arguments -or $Arguments.Count -eq 0) { throw "Internal error: empty argument list for $Label" }

  # Resolve venv python relative to cwd when possible.
  $effectivePyCmd = $PyCmd
  if (
    $PyCmd -match '^\.\.[\\/]\.venv[\\/]Scripts[\\/]python\.exe$' -or
    $PyCmd -match '^\.\.[\\/]\.venv[\\/]bin[\\/]python$'
  ) {
    $venvAbsWin = Join-Path $Context.PlaygroundRoot (Convert-PosixPathToNative '.venv/Scripts/python.exe')
    $venvAbsUnix = Join-Path $Context.PlaygroundRoot (Convert-PosixPathToNative '.venv/bin/python')
    $venvAbs = if (Test-Path $venvAbsWin) { $venvAbsWin } else { $venvAbsUnix }
    if (Test-Path $venvAbs) {
      $effectivePyCmd = Get-RelativePathFailClosed -FromDir $Cwd -ToPath $venvAbs
    }
  }

  $fullCmd = ($effectivePyCmd + ' ' + ($Arguments -join ' ')).Trim()
  Assert-NoDriveQualifiedArgs -Label $Label -CommandLine $fullCmd

  Write-Host ''
  Write-Host "Step: $Label" -ForegroundColor Cyan
  Write-Host ("[cwd] " + $Cwd) -ForegroundColor DarkGray
  Write-Host ("[cmd] " + $fullCmd) -ForegroundColor DarkGray

  $logDirAbs = Join-Path $Context.BelgiRunAbs 'logs'
  if (!(Test-Path $logDirAbs)) { New-Item -ItemType Directory -Force -Path $logDirAbs | Out-Null }
  $safeLabel = ($Label -replace '[^A-Za-z0-9_.-]+','_')
  $logAbs = Join-Path $logDirAbs ($safeLabel + '.log')
  New-Item -ItemType File -Force -Path $logAbs | Out-Null

  Push-Location $Cwd
  $oldPyPath = $env:PYTHONPATH
  $env:PYTHONPATH = $Context.BelgiRoot

  $oldEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'

  try {
    $exitCode = 0
    $attempt = 0
    $maxAttempts = [Math]::Max(1, ($WinFileLockRetries + 1))

    while ($attempt -lt $maxAttempts) {
      $attempt += 1

      $startedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
      @(
        '# --- RUN_CHAIN STEP LOG ---',
        ('# label:   ' + $Label),
        ('# attempt: ' + $attempt + '/' + $maxAttempts),
        ('# started: ' + $startedAt),
        ('# cwd:     ' + $Cwd),
        ('# cmd:     ' + $fullCmd),
        '# --------------------------',
        ''
      ) | Out-File -FilePath $logAbs -Encoding utf8

      if ($attempt -gt 1) {
        $delay = [Math]::Min(1500, ($WinFileLockBaseDelayMs * $attempt))
        Write-Host ("  Retrying (Windows file lock) attempt ${attempt}/${maxAttempts} after ${delay}ms...") -ForegroundColor Yellow
        Start-Sleep -Milliseconds $delay
      }

      if ($effectivePyCmd -like 'py *') {
        $parts = $effectivePyCmd.Split(' ', 2)
        & $parts[0] $parts[1] @Arguments 2>&1 | Out-File -FilePath $logAbs -Encoding utf8 -Append
      } else {
        & $effectivePyCmd @Arguments 2>&1 | Out-File -FilePath $logAbs -Encoding utf8 -Append
      }

      $exitCode = $LASTEXITCODE

      $endedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
      @(
        '',
        '# --------------------------',
        ('# ended:   ' + $endedAt),
        ('# exit:    ' + $exitCode)
      ) | Out-File -FilePath $logAbs -Encoding utf8 -Append

      if ($exitCode -eq 0 -or ($AllowExitCodes -contains $exitCode)) { break }

      $tail = ''
      try { $tail = (Get-Content -Path $logAbs -Tail 120 -Raw -ErrorAction Stop) } catch { $tail = '' }
      $isWinLock = ($tail -match 'PermissionError: \[WinError (5|32)\]' -or $tail -match 'Access is denied' -or $tail -match 'os\.replace\(')
      if (-not $isWinLock) { break }

      $tmpPaths = @()
      foreach ($m in [regex]::Matches($tail, "'([^']+\\.tmp)'\\s*->\\s*'([^']+)'")) { $tmpPaths += $m.Groups[1].Value }
      $tmpPaths = @($tmpPaths | Sort-Object -Unique)
      foreach ($p in $tmpPaths) {
        try { if (Test-Path $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } } catch {}
      }

      if ($attempt -ge $maxAttempts) { break }
    }

    # Append to LIVE command log once.
    $clLine = ($Label + "`t" + $Cwd + "`t" + $fullCmd + "`texit=" + $exitCode)
    $cmdLogLiveAbs = $Context.RepoRelToAbs($Context.Rel.CommandLogLive)
    Append-LineUtf8NoBomLf -Path $cmdLogLiveAbs -Label 'command_log LIVE' -Line $clLine

    if ($exitCode -ne 0 -and ($AllowExitCodes -notcontains $exitCode)) {
      Write-Host '  FAILED' -ForegroundColor Red
      Write-Host '  Log tail (last 80 lines):' -ForegroundColor Yellow
      Get-Content -Path $logAbs -Tail 80 | ForEach-Object { Write-Host ("  " + $_) }
      throw "FAILED ($Label) exit=$exitCode"
    }

    if ($exitCode -eq 0) { Write-Host '  OK' -ForegroundColor Green }
    else { Write-Host ("  EXIT " + $exitCode) -ForegroundColor Yellow }

    return $exitCode
  } finally {
    $env:PYTHONPATH = $oldPyPath
    Pop-Location
    $ErrorActionPreference = $oldEap
  }
}

function New-RunContext {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][hashtable]$Args,
    [Parameter(Mandatory=$true)][hashtable]$Config,
    [Parameter(Mandatory=$true)][string]$ScriptRoot
  )

  $ctx = [RunContext]::new()

  $ctx.PlaygroundRoot = Get-RepoRoot -ScriptRoot $ScriptRoot
  Set-Location $ctx.PlaygroundRoot

  $ctx.Config = $Config

  $ctx.RunId = [string]($Args.RunId)
  if ([string]::IsNullOrWhiteSpace($ctx.RunId)) { $ctx.RunId = [string]$Config.Defaults.RunId }

  $ctx.RepoRef = [string]($Args.RepoRef)
  if ([string]::IsNullOrWhiteSpace($ctx.RepoRef)) { $ctx.RepoRef = [string]$Config.Defaults.RepoRef }

  $ctx.EnvelopeId = [string]$Config.Defaults.EnvelopeId
  $ctx.EnvelopeDescription = [string]$Config.Defaults.EnvelopeDescription
  $expectedRunner = [string]$Config.Defaults.ExpectedRunner
  if ([string]::IsNullOrWhiteSpace($expectedRunner) -or $expectedRunner.Trim().ToLowerInvariant() -eq 'auto') {
    $os = 'unknown'
    if ($env:OS -eq 'Windows_NT') {
      $os = 'windows'
    } else {
      $osInfo = ''
      try { $osInfo = [string]$PSVersionTable.OS } catch { $osInfo = '' }
      if ($osInfo -match 'Darwin') { $os = 'macos' }
      elseif ($osInfo -match 'Linux') { $os = 'linux' }
      else { $os = 'unix' }
    }

    $archRaw = ''
    if ($env:PROCESSOR_ARCHITECTURE) {
      $archRaw = [string]$env:PROCESSOR_ARCHITECTURE
    } else {
      try { $archRaw = [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { $archRaw = '' }
    }
    $archRaw = $archRaw.Trim().ToLowerInvariant()
    $arch = switch ($archRaw) {
      'amd64' { 'x64' }
      'x64' { 'x64' }
      'arm64' { 'arm64' }
      'aarch64' { 'arm64' }
      default { if ([string]::IsNullOrWhiteSpace($archRaw)) { 'unknown' } else { $archRaw } }
    }

    $expectedRunner = "${os}-${arch}"
  }
  $ctx.ExpectedRunner = $expectedRunner
  $ctx.PublicationProfile = [string]$Config.Defaults.PublicationProfile
  $ctx.SealSigner = [string]$Config.Defaults.SealSigner
  if ([string]::IsNullOrWhiteSpace($Args.SealedAtUtc)) {
    $ctx.SealedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  } else {
    $ctx.SealedAtUtc = [string]$Args.SealedAtUtc
  }

  $ctx.Interactive = [bool]$Args.Interactive
  $ctx.Auto = [bool]$Args.Auto
  $ctx.AllowNoGo = [bool]$Args.AllowNoGo
  $ctx.SkipDemo = [bool]$Args.SkipDemo

  $cacheDir = [string]$Args.CacheDir
  if ([string]::IsNullOrWhiteSpace($cacheDir)) { $cacheDir = [string]$Config.Defaults.CacheDir }

  $outDirBase = [string]$Args.OutDirBase
  if ([string]::IsNullOrWhiteSpace($outDirBase)) { $outDirBase = [string]$Config.Defaults.OutDirBase }

  $ctx.OutDirBaseRelPosix = $outDirBase.Replace('\\','/').Trim().Trim('/')
  if ([string]::IsNullOrWhiteSpace($ctx.OutDirBaseRelPosix)) { throw 'OutDirBase cannot be empty.' }

  $ctx.BelgiRoot = Join-Path $ctx.PlaygroundRoot $cacheDir
  if (!(Test-Path $ctx.BelgiRoot)) { throw "Missing BELGI cache at: $($ctx.BelgiRoot). Run scripts/bootstrap.ps1 first." }

  $ctx.EngineRoot = $ctx.BelgiRoot
  $ctx.RepoRoot = Join-Path $ctx.PlaygroundRoot 'target_service'
  if (!(Test-Path $ctx.RepoRoot)) { throw "Missing target_service at: $($ctx.RepoRoot)." }

  $ctx.PythonCmd = Resolve-PythonCommand -PlaygroundRoot $ctx.PlaygroundRoot

  # Run folder selection remains in UI/controller for now.

  return $ctx
}
