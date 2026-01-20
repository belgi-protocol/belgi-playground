# Intent
```yaml
intent_id: "intent-q-pass-tier0"
title: "Fixture intent"
goal: "Fixture goal"
scope:
  allowed_dirs:
    - target_service/belgi_specs/
    - target_service/_out/
    - target_service/src/
    - target_service/docs/
  forbidden_dirs:
    - target_service/private/
  max_touched_files: 50
  max_loc_delta: 500
acceptance:

  success_criteria:
    - "Criteria 1"
tier:
  tier_pack_id: "tier-0"
doc_impact:
  required_paths: []
  note_on_empty: "No doc updates required."
```

