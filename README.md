# nf_Gen_Var_Pipe

## Status

This repository is **Under Construction and Being Refactored**.

The pipeline is being actively expanded and restructured into stage-scoped Nextflow DSL2 modules to dynamically support multi-platform sequencing data and multi-modal variant discovery with clinical-grade auditability.

## What This Repository Contains

`nf_Gen_Var_Pipe` is a staged WES processing framework organized into independent gates from sample intake through clinical reporting.

Current top-level stages:

- `Stage_0_Preflight_Ingest_Gate`
- `Stage_1_Alignment_Read_Processing`
- `Stage_2_PostAlign_Sample_Validation_Gate`
- `Stage_3_Variant_Discovery_Engine`
- `Stage_4_Ancestry_Phasing_Highway`
- `Stage_5_Clinical_Annotation_PGx_Triage`
- `Stage_6_Clinical_Reporting_Workbench_Gateway`

## Stage Overview (0 to 6)

### Stage 0: Preflight Ingest Gate

Purpose:
- Intake schema checks and route determination.
- Hard precondition validation for references and sample fields.
- Emit Stage 0 banked manifest and intake validation token artifacts.

Outputs (representative):
- Stage 0 banked samples manifest
- Intake validation token(s)
- Intake/route audit JSON artifacts

### Stage 1: Alignment Read Processing

Purpose:
- Execute alignment and post-processing.
- Produce mapped/sorted BAM + BAI and identity audits.
- Bank immutable Stage 1 handoff contract.

Outputs (representative):
- `mapped_bam`, `mapped_bai`
- Stage 1 banked samples manifest
- Stage 1 audit sink artifacts

### Stage 2: Post-Align Sample Validation Gate

Purpose:
- Validate Stage 1 contract integrity.
- Perform chromosomal sex and purity checks.
- Route assay/branch targets for variant discovery.

Outputs (representative):
- Stage 2 banked samples manifest
- precondition/purity/router audits

### Stage 3: Variant Discovery Engine

Purpose:
- Branch-aware variant discovery on Stage 2 validated samples.
- Emit discovery artifacts aligned to downstream annotation/reporting.

Outputs (representative):
- Stage 3 banked samples manifest
- branch-specific call artifacts and audits

### Stage 4: Ancestry Phasing Highway

Purpose:
- Execute ancestry and phasing related computations.
- Provide phasing-informed assets for Stage 5 interpretation.

Outputs (representative):
- Stage 4 banked samples manifest
- ancestry/phasing artifacts and audit summaries

### Stage 5: Clinical Annotation + PGx Triage

Purpose:
- Clinical annotation and interpretation routing.
- Candidate VUS triage, SF/PRS/PGx branch materialization.
- Build Stage 5 contract consumed by reporting gateway.

Outputs (representative):
- Stage 5 banked samples manifest
- annotation payloads, VUS queues, SF/PRS/PGx artifacts

### Stage 6: Clinical Reporting Workbench Gateway

Purpose:
- Final integrity reconciliation and fail-closed gate checks.
- FHIR/report generation and medical director workflow integration.
- Assemble Stage 6 manifest + reporting provenance artifacts.

Outputs (representative):
- Stage 6 banked samples manifest
- FHIR JSON, HTML/PDF report artifacts
- provenance and audit sink outputs

## Local FMEA Testing

Each stage includes local FMEA-style negative and nominal scenario runners under `tests/fmea`.

Typical pattern:
- run a stage-specific suite (for example `run_stage0_fmea_suite.py`, `run_stage1_fmea_suite.py`, etc.)
- verify that nominal scenarios pass
- verify fail-closed behavior for corrupted/missing token, reference, or contract cases

Notes:
- FMEA run directories under `tests/fmea/runs/` are treated as transient local outputs.
- They are intentionally ignored by `.gitignore` and should not be committed.

## Development Notes

- Nextflow runtime caches and work directories (`.nextflow/`, `work/`, `/scratch/nextflow_work`) are local and disposable.
- Large genomic binaries (`.bam`, `.cram`, `.vcf.gz`, etc.) are excluded from version control.
- Keep manifests, modules, scripts, and configuration files under version control; keep generated artifacts out.

## Branching and Commit Hygiene

Recommended workflow during refactor:
- Keep changes scoped by stage.
- Commit module/config changes with short, explicit messages.
- Validate with stage-local FMEA before promoting changes downstream.

## Disclaimer

This codebase is in active refactor and should be treated as a moving target until a formal release tag and validation baseline are published.
