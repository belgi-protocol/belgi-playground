#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

if command -v pwsh >/dev/null 2>&1; then
  exec pwsh -NoProfile -File "$repo_root/scripts/smoke_test.ps1" "$@"
elif command -v powershell >/dev/null 2>&1; then
  exec powershell -NoProfile -File "$repo_root/scripts/smoke_test.ps1" "$@"
else
  echo "PowerShell (pwsh) not found. Install PowerShell to run the demo scripts on macOS/Linux." >&2
  echo "See: https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
  exit 127
fi
