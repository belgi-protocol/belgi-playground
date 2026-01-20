Set-StrictMode -Version Latest

function Get-BelgiConfig {
  [CmdletBinding()]
  param()

  # Centralized defaults for paths + chain structure.
  # NOTE: run_chain.ps1 provides user-overrides; controller merges them.
  return [ordered]@{
    Defaults = [ordered]@{
      CacheDir = '.cache/belgi'
      OutDirBase = '_out'
      IntentRel = 'belgi_specs/IntentSpec.core.md'
      TolerancesRel = 'belgi_specs/tolerances.json'
      ToolchainRel = 'belgi_specs/toolchain.json'
      RunId = 'demo-run-001'
      RepoRef = 'local/belgi-playground'
      EnvelopeId = 'env-001'
      EnvelopeDescription = 'Pinned toolchain for run'
      ExpectedRunner = 'auto'
      PublicationProfile = 'internal'
      SealSigner = 'playground'
    }

    # Data-driven orchestration: ordered chain + dependencies + artifact checks.
    # Each step handler is implemented in Steps.ps1.
    Steps = @(
      [ordered]@{ Id='C1'; Display='C1'; DependsOn=@();     Handler='Invoke-StepC1'; Artifacts=@('LockedSpec','PromptBundle','PromptBlockHashes','PromptBundlePolicy') },
      [ordered]@{ Id='Q';  Display='Q';  DependsOn=@('C1'); Handler='Invoke-StepQ';  Artifacts=@('GateVerdictQ','EvidenceManifestQSeed') },
      [ordered]@{ Id='R';  Display='R';  DependsOn=@('Q');  Handler='Invoke-StepR';  Artifacts=@('GateVerdictR','EvidenceManifestR') },
      [ordered]@{ Id='C3'; Display='C3'; DependsOn=@('R');  Handler='Invoke-StepC3'; Artifacts=@('EvidenceManifestFinal','DocsMd','DocsBundleRootSha','DocsBundleManifest') },
      [ordered]@{ Id='SEAL';Display='SEAL';DependsOn=@('C3');Handler='Invoke-StepSeal';Artifacts=@('SealManifest') },
      [ordered]@{ Id='S';  Display='S';  DependsOn=@('SEAL');Handler='Invoke-StepS';  Artifacts=@('GateVerdictS') }
    )
  }
}
