# belgi-playground

> **This repo is a demo harness, not the BELGI protocol engine.**
> It demonstrates mechanics and failure modes — it does not prove general security.

---

## What this repo is

A local, interactive demo harness for running a BELGI chain against a sample governed repo (`target_service/`).

**Purpose:**
- Teach the interaction model: fail → remediation → rerun
- Show artifact outputs (LockedSpec, EvidenceManifest, GateVerdict, SealManifest)
- Demonstrate determinism via the `repro` command

**Key components:**

| Component | Location | Description |
|-----------|----------|-------------|
| Governed repo | `target_service/` | The sample project being evaluated |
| Runner scripts | `scripts/run_chain.ps1`, `scripts/src/` | Demo harness (PowerShell) |
| Output artifacts | `target_service/_out/run_<stamp>/` | Per-run evidence and verdicts |

---

## What this repo is not

- **Not the BELGI protocol engine.** The engine is a separate project; this repo merely consumes it.
- **Not the authoritative source** for schemas, templates, or gate semantics.
- **Not a security product.** It is a walkthrough harness for learning BELGI mechanics.
- **Not trustless.** If you control the runner, you can fabricate artifacts. The value is making tampering *detectable*, not *impossible*.

---

## Where the real protocol lives

All canonical schemas, gate semantics, and tooling live in the **BELGI engine repo** (source of truth).

This playground pins a specific engine version. To find the engine source:

```cmd
Get-Content pins\belgi_repo_url.txt   # repo URL
Get-Content pins\belgi_ref.txt        # commit SHA
```

macOS/Linux:

```bash
cat pins/belgi_repo_url.txt   # repo URL
cat pins/belgi_ref.txt        # commit SHA
```

The local `.cache/belgi/` directory is a clone of that pinned version, used by the harness to run gates. It is **not** the source of truth — the engine repo is.

The protocol definitions, gate logic, and schemas belong to the engine repo — not this playground.

---

## Quickstart

### Prerequisites
- Git
- Python 3.10–3.13
- PowerShell 7 (`pwsh`) (required on macOS/Linux)

**Compatibility:** The demo harness is validated on Python 3.10–3.13. Other versions are not guaranteed.

### Windows

```cmd
.\scripts\bootstrap.cmd
.\scripts\run_chain.cmd
```

### macOS / Linux

1) Install PowerShell 7 (`pwsh`) and ensure it’s on your `PATH`.
2) Run the wrapper scripts:

```bash
chmod +x scripts/wrappers/*.sh
./scripts/wrappers/bootstrap.sh
./scripts/wrappers/run_chain.sh
```

If you prefer running PowerShell directly:

```bash
pwsh -File scripts/bootstrap.ps1
pwsh -File scripts/run_chain.ps1
```

### What you'll see

The interactive shell displays:

```
╔══════════════════════════════════════════════════════════════╗
║                    BELGI Chain Runner                        ║
╚══════════════════════════════════════════════════════════════╝

  Commands:
    demo     - Guided interactive walkthrough (recommended!)
    repro    - Run twice and verify determinism
    all      - Run complete chain automatically
    resume   - Continue from last successful step

  Individual Steps:
    c1 | q | r | c3 | seal | s

  Other: help | status | paths | quit
```

Type `demo` to start the guided walkthrough.

### Non-interactive (CI-style)

```cmd
.\scripts\run_chain.cmd -Auto -ForceCleanRun
```

### Smoke test (non-interactive)

Windows:

```cmd
.\scripts\wrappers\smoke_test.cmd
```

macOS / Linux:

```bash
./scripts/wrappers/smoke_test.sh
```

### Output location

All artifacts land in: `target_service/_out/run_<timestamp>/`

---

## Demo walkthrough (interactive)

The `demo` command walks you through 4 parts:

| Part | Gate | What it demonstrates |
|------|------|---------------------|
| 1 | Q | LockedSpec tampering detection |
| 2 | R | Forbidden path change detection |
| 3 | R | Valid changes pass (recovery) |
| 4 | S | Post-seal artifact tampering detection |

### PART 1: Gate Q (LockedSpec tampering)

1. Runs C1 (compile intent) → Q (verify) — should pass
2. Prompts you to tamper with `LockedSpec.json` (e.g., change `max_loc_delta`)
3. Re-runs Q — should fail (NO-GO)
4. Recovers by re-running C1

### PART 2: Gate R (forbidden path)

1. Creates a change under `target_service/private/` (forbidden path)
2. Commits it
3. Runs R — should fail (NO-GO)
4. Shows `diff.patch` with the forbidden path

### PART 3: Gate R (valid change recovery)

1. Reverts the forbidden change
2. Makes a valid change under `target_service/src/`
3. Runs R — should pass (GO)
4. Shows `diff.patch` with the valid path

### PART 4: Gate S (post-seal integrity)

1. Completes the chain: C3 → SEAL → S
2. Tampers with `EvidenceManifest.final.json` after sealing
3. Runs S verify-only — should fail (NO-GO)
4. Restores the original file

### After the demo: `repro`

Run `repro` to verify deterministic reproducibility:
- Runs the chain twice with a fixed timestamp (`2000-01-01T00:00:00Z`)
- Compares artifact hashes byte-for-byte

---

## Outputs and artifacts

Each run produces these artifacts in `target_service/_out/run_<stamp>/`:

| Artifact | Description |
|----------|-------------|
| `LockedSpec.json` | Compiled intent specification |
| `GateVerdict.Q.json` | Gate Q pass/fail verdict |
| `diff.patch` | Committed changes R evaluates |
| `EvidenceManifest.R.json` | Evidence snapshot at Gate R |
| `GateVerdict.R.json` | Gate R pass/fail verdict |
| `GateReport.R.json` | Detailed R check results |
| `EvidenceManifest.final.json` | Final evidence after C3 |
| `SealManifest.json` | Cryptographic seal |
| `GateVerdict.S.json` | Gate S pass/fail verdict |

---

## Common misunderstandings

### 1. Gate R evaluates committed diffs only

R compares `LockedSpec.upstream_state.commit_sha` vs current HEAD.

**Uncommitted edits are invisible to Gate R.**

To make a change visible:
```cmd
git add -A
git commit -m "my change"
```

### 2. Some tampering passes Gate Q on purpose

Gate Q checks **intent-derived mapping**, not full artifact integrity.

| Q catches | Q may not catch (later gates catch) |
|-----------|-------------------------------------|
| Changing `max_loc_delta` value | Editing a hash-looking field not derived from intent |
| Removing an allowed path | Adding whitespace to a manifest |
| Invalid constraint structure | Modifying `produced_by` fields |

Non-intent-derived integrity is caught by Gate R (evidence hashes) or Gate S (seal binding).

### 3. `produced_by` quirks

Some artifacts are recorded as `produced_by=C1` due to engine schema allowlists.

This is a **known constraint** in the current engine, not "gaming" — it's tracked as an upstream engine issue.

### 4. Path prefixes depend on git root

If `target_service/` is part of the parent repo (not standalone), diff paths will be:
- `target_service/src/service.py` (prefixed)

The `IntentSpec.core.md` must list paths accordingly (its `allowed_dirs`/`forbidden_dirs` must match the diff path prefixes).

The bootstrap script auto-adjusts this based on whether `target_service/.git` exists:
- standalone `target_service` repo → unprefixed paths like `src/`
- nested under parent repo → prefixed paths like `target_service/src/`

---

## Known issues and remediation

### WinError 5 / WinError 32 (file locked)

**Cause:** Windows antivirus, file indexers, or editors holding file handles during atomic replace.

**Recovery:**

1. Re-run the exact failed step (do not delete run dir yet)
2. Close editors that may lock files (VSCode preview, Explorer)
3. Temporarily exclude `_out/` from antivirus real-time scanning
4. If still failing: start a fresh run (`-ForceCleanRun`)

The runner has built-in retry logic (up to 6 retries with backoff) for these errors.  
*(See: `scripts/src/Engine.ps1`, function `Invoke-BelgiTool`, parameter `WinFileLockRetries`)*

### "scope escape" / "missing path in scope"

**Cause:** The harness stages protocol pack files into a sandbox for C3.

**Recovery:** This is expected behavior for the demo. For canonical scope rules, see the BELGI engine repo.

### Empty diff.patch

**Cause:** No commits between `upstream_state.commit_sha` and HEAD.

**Recovery:** Make sure to commit your changes before running Gate R.

---

## Limitations (explicit)

| Limitation | Explanation |
|------------|-------------|
| Runner trust | If you control `scripts/run_chain.ps1`, you can fabricate artifacts. |
| Demo-only scaffolding | Protocol-pack staging, placeholder hashes, and timestamped dirs are demo conveniences. |
| No external verifier | This repo doesn't provide a standalone verifier that works without the runner. |
| Schema constraints | Some `produced_by` assignments exist to satisfy current allowlists, not ideal semantics. |

**What this demo proves:** Artifact structure and failure modes.

**What this demo does NOT prove:** General security or tamper-resistance.

---

## Tampering matrix (reference)

| Tampering action | Expected to fail at | Why | How to recover |
|------------------|---------------------|-----|----------------|
| Remove `goal:` from IntentSpec | C1 | Intent validation fails | Restore valid intent YAML |
| Change `max_loc_delta` in LockedSpec | Q | Intent-derived constraint mismatch | Re-run C1 to regenerate |
| Edit hash-looking field not from intent | Q may pass | Q checks intent mapping only | R or S may catch via bytes→hash |
| Commit under `private/` | R | Forbidden path in diff | Revert commit, make allowed change |
| Uncommitted edit | **Not caught** | R only sees committed diff | Commit the change |
| Edit EvidenceManifest after seal | S | ObjectRef hash mismatch | Re-run C3 → SEAL → S |
| Edit field no gate binds | **May pass all gates** | Limitation: not all fields are hash-bound | None — this is a known gap |

**Limitation:** If you edit a field that no gate explicitly binds (neither intent-derived nor hash-verified), tampering may pass undetected. This is a protocol limitation, not a harness bug.

---

## FAQ

### Isn't this just a scripted success?

It can be, if you trust the runner. The point is to produce artifacts and show where tampering *would* be caught by an independent verifier.

### Can you bypass it by editing the runner?

Yes. That's why this is a demo harness, not a security proof.

### What prevents cheating?

Nothing, inside this repo alone. The value is making evidence explicit and showing failure modes.

### Why does Gate Q not catch some edits?

Q is about deterministic semantic mapping from IntentSpec. Some integrity checks use allowlists, not byte hashes. Later gates (R/S) do stronger binding.

---

## See also

- [playground.md](playground.md) — Detailed playbook with narrated walkthrough
- Engine source: see `pins/belgi_repo_url.txt` and `pins/belgi_ref.txt`

