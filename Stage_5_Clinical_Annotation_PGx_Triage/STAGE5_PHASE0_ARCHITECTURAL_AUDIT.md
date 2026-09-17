# Stage 5 Phase 0 Architectural Audit

Scope: `/media/drive_c/nf_pipes/nf_Gen_Var_Pipe/Stage_5_Clinical_Annotation_PGx_Triage`
Date: 2026-09-15

## Critical Findings

1. Legacy entanglement still present in active top-level entrypoint.
- File: `main.nf`
- Evidence: top-level flow executes `STAGE5_ANNOTATION_PGX`, `STAGE5_COMPAT_EXPORT`, and legacy `ASSEMBLE_STAGE5_BANKED_MANIFEST`.
- Risk: branch isolation is not guaranteed at orchestration level, and output contracts are mixed with compatibility exports.

2. Isolated branch workflows existed but were not fully elevated to canonical top-level orchestration.
- Files: `workflows/stage5_germline.nf`, `workflows/stage5_pgx.nf`, `workflows/stage5_sf.nf`, `workflows/stage5_prs.nf`, `workflows/stage5_somatic.nf`
- Risk: architecture remained partially deployed without single isolated aggregator workflow.

3. Cryptographic multi-branch Stage 5 manifest builder script existed without isolated workflow integration.
- File: `bin/stage5_build_stage5_manifest.py`
- Risk: branch manifests could be produced without deterministic assembly into canonical `samples_<sid>_stage5.yaml` under isolated flow.

## Existing Strengths Verified

1. Germline isolation flow is explicitly split into VEP/ClinVar/gnomAD streams + ACMG translation rules + Bayes partition.
- File: `modules/local/stage5_germline_isolated.nf`

2. Rule layer is explicit and separated.
- Files:
  - `bin/stage5_rule_comp_synthesis.py`
  - `bin/stage5_rule_loss_truncation.py`
  - `bin/stage5_rule_freq_check.py`

3. Zero-loss and VUS HGMD triage artifacts are explicit.
- Files:
  - `bin/stage5_zero_loss_audit.py`
  - `bin/stage5_vus_hgmd_triage.py`
  - `bin/stage5_germline_branch_manifest.py`

## Refactor Actions Added

1. Added isolated multi-branch orchestrator workflow.
- File: `workflows/stage5_isolated.nf`
- Behavior: executes Germline/PGx/SF/PRS/Somatic branch workflows as independent lanes, then assembles canonical Stage 5 manifest.

2. Added dedicated isolated manifest builder process for cryptographic assembly.
- File: `modules/local/stage5_isolated_manifest_builder.nf`
- Behavior: uses `bin/stage5_build_stage5_manifest.py` and emits `samples_<sample_id>_stage5.yaml`.

## Compliance Posture After Refactor

1. Branch execution separation is explicit at workflow boundaries.
2. Stage 5 manifest assembly is deterministic and cryptographic per branch manifest SHA-256.
3. Zero-loss checks are represented in germline branch manifest payload and carried into final Stage 5 manifest.

## Remaining Optional Hardening

1. Move top-level `main.nf` default execution path to `STAGE5_ISOLATED_BRANCH_ARCHITECTURE` and retire compatibility export path once downstream consumers are migrated.
2. Add a compile-only CI check (`nextflow run ... -stub-run`) for `workflows/stage5_isolated.nf` orchestration contract integrity.
