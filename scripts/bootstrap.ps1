param(
  [string]$BelgiRemote = '',
  [string]$BelgiRef = '',
  [string]$CacheDir = '.cache/belgi',
  [switch]$ForceFresh
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# belgi-playground bootstrap: clone-based deterministic setup
# ============================================================================
# This script:
# 1) Clones BELGI at a pinned ref (default from pins/)
# 2) Verifies required template files exist in the clone
# 3) Sets up a Python venv with the cloned BELGI installed in editable mode
# 4) Generates target_service/belgi_specs/ and rewrites IntentSpec scope for playground execution
# ============================================================================

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

function Convert-PosixPathToNative {
  [CmdletBinding()]
  param([Parameter(Mandatory=$true)][string]$Path)
  $sep = [string][System.IO.Path]::DirectorySeparatorChar
  return ($Path -replace '[\\/]', $sep)
}

Write-Host "belgi-playground bootstrap" -ForegroundColor Cyan
Write-Host "==========================" -ForegroundColor Cyan

# Read pins
$pinsDir = Join-Path $repoRoot 'pins'
$repoUrlPath = Join-Path $pinsDir 'belgi_repo_url.txt'
$refPath = Join-Path $pinsDir 'belgi_ref.txt'

if (!(Test-Path $repoUrlPath)) { throw 'Missing pins/belgi_repo_url.txt' }
if (!(Test-Path $refPath)) { throw 'Missing pins/belgi_ref.txt' }

if (-not $BelgiRemote) {
  $BelgiRemote = (Get-Content $repoUrlPath -Raw).Trim()
}
if (-not $BelgiRef) {
  $BelgiRef = (Get-Content $refPath -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($BelgiRemote)) { throw 'BELGI remote URL is empty' }
if ($BelgiRef -notmatch '^[0-9a-fA-F]{40}$') { throw 'BELGI ref must be a 40-hex SHA' }

Write-Host "Remote: $BelgiRemote" -ForegroundColor Gray
Write-Host "Ref:    $BelgiRef" -ForegroundColor Gray

# Ensure git exists
try { git --version | Out-Null } catch { throw 'git not found. Install git and ensure it is on PATH.' }

# Clone or refresh cache
$cacheFullPath = Join-Path $repoRoot $CacheDir
$gitDir = Join-Path $cacheFullPath '.git'

if ($ForceFresh -and (Test-Path $cacheFullPath)) {
  Write-Host "Force fresh: removing existing cache..." -ForegroundColor Yellow
  Remove-Item -Path $cacheFullPath -Recurse -Force
}

if (!(Test-Path $gitDir)) {
  Write-Host "Cloning BELGI..." -ForegroundColor Cyan
  New-Item -ItemType Directory -Path (Split-Path -Parent $cacheFullPath) -Force | Out-Null
  git clone --no-checkout $BelgiRemote $cacheFullPath
  if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE). Check pins/belgi_repo_url.txt" }
} else {
  Write-Host "Cache exists. Fetching updates..." -ForegroundColor Cyan
  git -C $cacheFullPath fetch origin
  if ($LASTEXITCODE -ne 0) { Write-Warning "git fetch failed. Continuing with cached state." }
}

# Checkout pinned ref (detached HEAD)
Write-Host "Checking out ref $BelgiRef..." -ForegroundColor Cyan
git -C $cacheFullPath checkout --detach $BelgiRef
if ($LASTEXITCODE -ne 0) {
  throw "git checkout failed. Ref $BelgiRef not found. Run with -ForceFresh or check pins/belgi_ref.txt"
}

# Verify required template paths exist
Write-Host "Verifying required template files..." -ForegroundColor Cyan
$requiredPaths = @(
  'belgi/templates/PromptBundle.blocks.md',
  'belgi/templates/DocsCompiler.template.md'
)
foreach ($relPath in $requiredPaths) {
  $fullPath = Join-Path $cacheFullPath $relPath
  if (!(Test-Path $fullPath)) {
    throw "BLOCKER: Required path missing in BELGI checkout: $relPath`nPinned ref is incompatible with playground."
  }
  Write-Host "  OK: $relPath" -ForegroundColor Green
}

# Python venv setup
Write-Host "Setting up Python venv..." -ForegroundColor Cyan

function Get-PythonBootstrap {
  $minVersionCheck = "import sys; sys.exit(0 if sys.version_info >= (3,13) else 1)"
  try { & py -3.13 -c $minVersionCheck 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return @{Exe='py'; Args=@('-3.13')} } } catch {}
  try { & py -3 -c $minVersionCheck 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return @{Exe='py'; Args=@('-3')} } } catch {}
  try { & python3 -c $minVersionCheck 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return @{Exe='python3'; Args=@()} } } catch {}
  try { & python -c $minVersionCheck 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return @{Exe='python'; Args=@()} } } catch {}
  throw 'Python not found (or < 3.13). Install Python 3.13+ and ensure python3/python is on PATH.'
}

$py = Get-PythonBootstrap
$venvDir = Join-Path $repoRoot '.venv'

$venvPythonCandidates = @(
  (Join-Path $venvDir (Convert-PosixPathToNative 'Scripts/python.exe')),
  (Join-Path $venvDir (Convert-PosixPathToNative 'bin/python'))
)
$venvPython = $venvPythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if ([string]::IsNullOrWhiteSpace([string]$venvPython) -or !(Test-Path $venvPython)) {
  Write-Host "Creating venv..." -ForegroundColor Cyan
  & $py.Exe @($py.Args) -m venv $venvDir
  if ($LASTEXITCODE -ne 0) { throw 'Failed to create venv' }

  $venvPython = $venvPythonCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace([string]$venvPython) -or !(Test-Path $venvPython)) {
    throw "Venv created but python not found under: $venvDir"
  }
}

Write-Host "Installing BELGI (editable)..." -ForegroundColor Cyan
& $venvPython -m pip install --quiet --upgrade pip
& $venvPython -m pip install --quiet -e $cacheFullPath
if ($LASTEXITCODE -ne 0) { throw 'pip install failed' }

# Verify import
Write-Host "Verifying BELGI import..." -ForegroundColor Cyan
$importTest = & $venvPython -c "import belgi; print('belgi import ok')" 2>&1
if ($LASTEXITCODE -ne 0) { throw "BELGI import failed: $importTest" }
Write-Host "  belgi import ok" -ForegroundColor Green

# Generate demo_specs with proper scope
Write-Host "Generating target_service/belgi_specs..." -ForegroundColor Cyan

$demoSpecsDir = Join-Path (Join-Path $repoRoot 'target_service') 'belgi_specs'
New-Item -ItemType Directory -Path $demoSpecsDir -Force | Out-Null

# IntentSpec source priority: public fixture > template
$intentSrc = Join-Path $cacheFullPath 'policy/fixtures/public/gate_q/q_pass_tier0/IntentSpec.core.md'
if (!(Test-Path $intentSrc)) { $intentSrc = Join-Path $cacheFullPath 'belgi/templates/IntentSpec.core.template.md' }
if (!(Test-Path $intentSrc)) { throw 'IntentSpec source not found in BELGI checkout' }

$intentDest = Join-Path $demoSpecsDir 'IntentSpec.core.md'
Copy-Item -Path $intentSrc -Destination $intentDest -Force

# Rewrite scope block to match playground strategy (target_service governed repo)
$intentText = Get-Content -Path $intentDest -Raw

$scopePrefix = 'target_service/'
$targetServiceGit = Join-Path $repoRoot (Convert-PosixPathToNative 'target_service/.git')
if (Test-Path $targetServiceGit) {
  # If target_service is a standalone git repo, diffs are typically repo-root relative (unprefixed).
  $scopePrefix = ''
}

$scopeBlock = @(
  'scope:',
  '  allowed_dirs:',
  ('    - ' + $scopePrefix + 'belgi_specs/'),
  ('    - ' + $scopePrefix + '_out/'),
  ('    - ' + $scopePrefix + 'src/'),
  ('    - ' + $scopePrefix + 'docs/'),
  '  forbidden_dirs:',
  ('    - ' + $scopePrefix + 'private/'),
  '  max_touched_files: 50',
  '  max_loc_delta: 500',
  'acceptance:'
) -join "`n"
$scopeBlock += "`n"

$pattern = '(?ms)^scope:\s*\r?\n.*?^acceptance:'
$updated = [regex]::Replace($intentText, $pattern, $scopeBlock)
if ($updated -eq $intentText) { throw 'Failed to update scope block in IntentSpec (pattern mismatch)' }

Set-Content -Path $intentDest -Value $updated -Encoding utf8
Write-Host "  IntentSpec.core.md (scope updated)" -ForegroundColor Green

# Copy tolerances.json
$tolerancesSrc = $null
$tolCandidates = @(
  'policy/fixtures/public/gate_q/q_pass_tier0/tolerances.json',
  'policy/templates/tolerances.json'
)
foreach ($candidate in $tolCandidates) {
  $fullPath = Join-Path $cacheFullPath $candidate
  if (Test-Path $fullPath) { $tolerancesSrc = $fullPath; break }
}
if (-not $tolerancesSrc) {
  $tolSearch = Get-ChildItem -Path $cacheFullPath -Recurse -Filter 'tolerances.json' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($tolSearch) { $tolerancesSrc = $tolSearch.FullName }
}
if (-not $tolerancesSrc) { throw 'No tolerances.json found in BELGI checkout' }

Copy-Item -Path $tolerancesSrc -Destination (Join-Path $demoSpecsDir 'tolerances.json') -Force
Write-Host "  tolerances.json" -ForegroundColor Green

# Copy toolchain.json
$toolchainSrc = $null
$tcCandidates = @(
  'policy/fixtures/public/gate_q/q_pass_tier0/toolchain.json',
  'policy/templates/toolchain.json'
)
foreach ($candidate in $tcCandidates) {
  $fullPath = Join-Path $cacheFullPath $candidate
  if (Test-Path $fullPath) { $toolchainSrc = $fullPath; break }
}
if (-not $toolchainSrc) {
  $tcSearch = Get-ChildItem -Path $cacheFullPath -Recurse -Filter 'toolchain.json' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($tcSearch) { $toolchainSrc = $tcSearch.FullName }
}
if (-not $toolchainSrc) { throw 'No toolchain.json found in BELGI checkout' }

Copy-Item -Path $toolchainSrc -Destination (Join-Path $demoSpecsDir 'toolchain.json') -Force
Write-Host "  toolchain.json" -ForegroundColor Green

Write-Host ""
Write-Host "Bootstrap complete!" -ForegroundColor Green
Write-Host "BELGI ref: $BelgiRef" -ForegroundColor Cyan
Write-Host "Cache:     $CacheDir" -ForegroundColor Cyan
Write-Host ""
$next = if ($env:OS -eq 'Windows_NT') { '.\scripts\run_chain.ps1' } else { './scripts/wrappers/run_chain.sh' }
Write-Host "Next: $next" -ForegroundColor Yellow
