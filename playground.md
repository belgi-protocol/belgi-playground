# BELGI Playground Playbook

This is the detailed walkthrough and reference for running the BELGI demo harness.

> **Reminder:** This is a demo harness, not the BELGI protocol engine.
> For canonical protocol definitions, see the engine repo pinned in `pins/belgi_repo_url.txt`.

---

## Table of Contents

1. [Before you start](#before-you-start)
2. [Demo walkthrough (narrated)](#demo-walkthrough-narrated)
3. [Tampering matrix](#tampering-matrix)
4. [Recovery playbook](#recovery-playbook)
5. [Command reference](#command-reference)
6. [Artifact reference](#artifact-reference)

---

## Before you start

### Prerequisites

- Git
- Python 3.10–3.13
- Windows (primary), or Unix with PowerShell Core

### Bootstrap

```cmd
.\scripts\bootstrap.cmd
```

This clones the pinned BELGI engine version into `.cache/belgi/`.

### Start the runner

```cmd
.\scripts\run_chain.cmd
```

You'll see the interactive HUD. Type `demo` to begin.

---

## Demo walkthrough (narrated)

The `demo` command runs 4 parts. Each part demonstrates a specific failure mode and its recovery.

### PART 1: Gate Q — LockedSpec Tampering Detection

**What Q checks:** LockedSpec must match a deterministic mapping from IntentSpec.

**Narrative:**

1. **C1 compiles intent.** The runner reads `target_service/belgi_specs/IntentSpec.core.md` and produces `LockedSpec.json`.

2. **Q verifies.** Gate Q checks that LockedSpec fields match what IntentSpec specifies. Should pass.

3. **You tamper.** The demo prompts you to edit `LockedSpec.json`:
   ```
   Open: target_service/_out/run_<stamp>/LockedSpec.json
   Change: "max_loc_delta": 500 → "max_loc_delta": 9999
   ```

4. **Q re-runs.** Gate Q detects the mismatch and returns **NO-GO**.

5. **Recovery.** Re-run C1 to regenerate LockedSpec from intent.

**Key insight:** Q catches *intent-derived* tampering. If you edit a field not derived from intent (e.g., a hash field), Q may pass — but later gates (R/S) will catch it.

---

### PART 2: Gate R — Forbidden Path Detection

**What R checks:** Committed diffs must only touch allowed paths; forbidden paths must not appear.

**Narrative:**

1. **Forbidden change.** The demo creates a file under `target_service/private/` and commits it.

2. **R runs.** Gate R computes `diff.patch` (from `upstream_state.commit_sha` to HEAD) and checks each path.

3. **NO-GO.** The path `target_service/private/...` is forbidden by IntentSpec. Gate R returns **NO-GO**.

4. **Inspect diff.patch.** The demo shows the diff content with syntax highlighting:
   ```diff
   diff --git a/target_service/private/DEMO_FORBIDDEN_CHANGE.txt ...
   +++ b/target_service/private/DEMO_FORBIDDEN_CHANGE.txt
   +FORBIDDEN: demo mutation under target_service/private/
   ```

**Key insight:** R only sees *committed* changes. Uncommitted edits are invisible.

---

### PART 3: Gate R — Valid Change Recovery

**What this shows:** How to recover from a forbidden path failure.

**Narrative:**

1. **Revert forbidden change.**
   ```cmd
   git revert HEAD --no-edit
   ```

2. **Make valid change.** Edit a file under `target_service/src/`:
   ```cmd
   echo "# valid change" >> target_service/src/service.py
   git add -A
   git commit -m "valid change"
   ```

3. **R re-runs.** Now the diff only contains allowed paths. Gate R returns **GO**.

4. **Inspect diff.patch.** The demo shows the valid diff:
   ```diff
   diff --git a/target_service/src/service.py ...
   +# valid change
   ```

**Key insight:** The LockedSpec's `upstream_state.commit_sha` is set at C1 time. All commits since then are in the diff.

---

### PART 4: Gate S — Post-Seal Integrity

**What S checks:** SealManifest object references must hash-match the actual artifact bytes.

**Narrative:**

1. **Complete the chain.** C3 → SEAL → S all pass.

2. **Tamper after seal.** The demo edits `EvidenceManifest.final.json` (adds whitespace).

3. **S verify-only.** Gate S recomputes the hash and compares to SealManifest. **NO-GO** — hash mismatch.

4. **Restore.** The demo reverts the file to original bytes.

**Key insight:** S catches *any* byte change to sealed artifacts, even whitespace.

---

## Tampering matrix

| Tampering action | Expected gate | Verdict | Why | Recovery |
|------------------|---------------|---------|-----|----------|
| Remove `goal:` from IntentSpec | C1 | Fails | Intent YAML invalid | Restore valid YAML |
| Remove required field from IntentSpec | C1 | Fails | Schema validation | Restore field |
| Change `max_loc_delta` in LockedSpec | Q | NO-GO | Intent-derived constraint mismatch | Re-run C1 |
| Change `allowed_paths` in LockedSpec | Q | NO-GO | Intent-derived scope mismatch | Re-run C1 |
| Edit hash field not from intent | Q | May pass | Q checks intent mapping only | R or S catches |
| Edit `produced_by` field | Q | May pass | Not intent-derived | R or S catches |
| Commit under `private/` | R | NO-GO | Forbidden path in diff | Revert, commit elsewhere |
| Commit under `src/` | R | GO | Allowed path | — |
| Uncommitted edit anywhere | R | Not caught | R only sees committed diff | Commit first |
| Edit command_log.txt after R | R (verify) | NO-GO | bytes→hash mismatch | Re-run R |
| Edit EvidenceManifest after seal | S | NO-GO | ObjectRef hash mismatch | Re-run C3 → SEAL → S |
| Add whitespace to sealed artifact | S | NO-GO | Any byte change breaks hash | Re-run seal |
| Edit field no gate binds | **All gates** | **May pass** | Limitation: not all fields hash-bound | None — known gap |

**Limitation:** Not every field in every artifact is hash-bound by a gate. Editing such a field may pass all gates. This is a protocol limitation documented in the engine repo.

---

## Recovery playbook

### If C1 fails (intent validation)

**Symptom:** "Intent validation failed" or missing required fields.

**Fix:**
1. Edit `target_service/belgi_specs/IntentSpec.core.md`
2. Ensure valid YAML with required fields (`goal:`, `scope:`, etc.)
3. Re-run `c1`

---

### If Gate Q fails (NO-GO)

**Symptom:** "Gate Q NO-GO" after editing LockedSpec.

**Fix:**
1. Do NOT manually fix LockedSpec
2. Re-run `c1` to regenerate from intent
3. Re-run `q`

---

### If Gate R fails (NO-GO)

**Symptom:** "Changed path is not under any allowed_paths prefix"

**Diagnosis:**
1. Check `target_service/_out/run_<stamp>/diff.patch`
2. Identify the forbidden path

**Fix:**
1. Revert the forbidden commit: `git revert HEAD --no-edit`
2. Make changes only under allowed paths
3. Re-run `r`

---

### If Gate S fails (NO-GO)

**Symptom:** "ObjectRef hash mismatch" or "seal verification failed"

**Fix:**
1. Do NOT manually fix manifests
2. Re-run the full seal: `c3` then `seal` then `s`

---

### If you see WinError 5 / WinError 32

**Symptom:** "PermissionError: [WinError 5] Access is denied" during file write.

**Cause:** Windows antivirus, indexers, or editors locking files.

**Fix:**
1. Re-run the exact failed step (runner has retry logic: `scripts/src/Engine.ps1`, `Invoke-BelgiTool`, up to 6 retries)
2. Close VSCode preview panes that might lock JSON files
3. Close File Explorer if it's showing `_out/`
4. Temporarily disable real-time AV scanning on `_out/`
5. If still failing: `.\scripts\run_chain.cmd -ForceCleanRun`

---

### If diff.patch is empty

**Symptom:** Gate R passes but you expected it to see your changes.

**Cause:** Changes not committed, or C1 was re-run after committing (resetting upstream).

**Fix:**
1. Check: `git log --oneline -5`
2. Ensure your changes are committed
3. Do NOT re-run C1 after committing (it resets upstream_state)

---

## Command reference

### Workflows

| Command | Description |
|---------|-------------|
| `demo` | Guided 4-part walkthrough (recommended for learning) |
| `repro` | Run chain twice, compare artifacts for determinism |
| `all` | Run complete chain automatically (no pauses) |
| `resume` | Continue from next incomplete step |

### Individual steps

| Command | Step | Description |
|---------|------|-------------|
| `c1` | C1 | Compile intent → LockedSpec |
| `q` | Q | Verify LockedSpec against intent |
| `r` | R | Produce evidence, verify diff against scope |
| `c3` | C3 | Compile final evidence manifest |
| `seal` | SEAL | Create SealManifest |
| `s` | S | Verify seal integrity |

### Utilities

| Command | Description |
|---------|-------------|
| `help` | Show full command reference |
| `status` | Show chain progress and next step |
| `paths` | Show all relevant file paths |
| `commit` | Commit changes in target_service |
| `quit` | Exit the runner |

**Hidden commands** (not shown in HUD, but functional):
- `rverify` — Gate R verify-only (re-verify existing evidence)
- `sverify` — Gate S verify-only (re-verify existing seal)
- `qtamper` — Prompt for Q tampering demo
- `c2` — C2 change/commit helper

*(See: `scripts/src/UI.ps1`, switch statement in `Start-BelgiChain`)*

---

## Artifact reference

### LockedSpec.json

**Produced by:** C1

**Contains:**
- `upstream_state.commit_sha` — baseline commit for diff
- `constraints` — intent-derived limits (max_loc_delta, etc.)
- `scope.allowed_dirs` — paths that may be changed
- `scope.forbidden_dirs` — paths that must not be changed

**Verified by:** Gate Q

---

### GateVerdict.Q.json

**Produced by:** Gate Q

**Contains:**
- `verdict` — "GO" or "NO-GO"
- `checks` — list of Q checks and their pass/fail status

---

### diff.patch

**Produced by:** Gate R (evidence production)

**Contains:** Unified diff from `upstream_state.commit_sha` to HEAD

**Used by:** Gate R to check path scope

---

### EvidenceManifest.R.json

**Produced by:** Gate R

**Contains:** Evidence records with storage refs and hashes

**Verified by:** Gate R (bytes→hash binding)

---

### GateVerdict.R.json / GateReport.R.json

**Produced by:** Gate R

**Contains:**
- `verdict` — "GO" or "NO-GO"
- `checks` — detailed check results including path violations

---

### EvidenceManifest.final.json

**Produced by:** C3

**Contains:** Complete evidence manifest after all compilations

**Verified by:** Gate S (via SealManifest)

---

### SealManifest.json

**Produced by:** SEAL

**Contains:**
- `sealed_at` — timestamp
- `object_refs` — references to artifacts with their hashes
- `seal_hash` — cryptographic hash of the seal

**Verified by:** Gate S

---

### GateVerdict.S.json

**Produced by:** Gate S

**Contains:**
- `verdict` — "GO" or "NO-GO"
- `checks` — objectref binding checks, seal hash verification

---

## See also

- [README.md](README.md) — Overview and quick reference
- Engine source: see `pins/belgi_repo_url.txt` and `pins/belgi_ref.txt`
