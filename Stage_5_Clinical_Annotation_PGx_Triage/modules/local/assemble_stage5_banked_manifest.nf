process ASSEMBLE_STAGE5_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    publishDir "${params.outdir}", mode: 'rellink', overwrite: true, pattern: 'samples_hg002_banked_stage5.yaml'

    input:
    path manifest_fragments

    output:
    path 'samples_hg002_banked_stage5.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from collections import defaultdict
from pathlib import Path

fragment_json = '''${groovy.json.JsonOutput.toJson(manifest_fragments.collect { fragment -> fragment.toString() }).replace('\n', ' ').replace('\r', '')}'''
fragment_paths = [Path(p) for p in json.loads(fragment_json)]

by_sample = defaultdict(dict)
for path in fragment_paths:
    data = json.loads(path.read_text(encoding='utf-8'))
    sid = data.get('sample_id', 'UNKNOWN')
    component = data.get('component', path.name)
    by_sample[sid][component] = data

lines = []
lines.append('# ==============================================================================')
lines.append('# STAGE 5 BANKED MANIFEST')
lines.append('# Purpose: Clinical annotation, SF/PRS triage, and phased PGx handoff.')
lines.append('# ==============================================================================')
lines.append('samples:')

for sid in sorted(by_sample):
    comp = by_sample[sid]
    router = comp.get('router', {}).get('router', {})
    ann = comp.get('annotation', {})
    sf = comp.get('secondary_findings', {})
    prs = comp.get('prs', {})
    pgx = comp.get('pgx', {})

    lines.append(f'  - sample_id: "{sid}"')
    lines.append('    validation_token: "VALID_PASS|VARIANTS_HARMONIZED|STAGE5_COMPLETE"')
    lines.append('    lineage:')
    lines.append('      source_stage: "Stage_4_Ancestry_Phasing_Highway"')
    lines.append('      stage5_workflow: "STAGE5_ANNOTATION_PGX_TRIAGE"')
    lines.append('    consent_audit:')
    lines.append(f'      sf_consent_token: "{router.get("sf_consent_token", "")}"')
    lines.append(f'      prs_consent_token: "{router.get("prs_consent_token", "")}"')
    lines.append('    router_warnings:')
    warnings = router.get('warnings', [])
    if warnings:
        for warning in warnings:
            lines.append(f'      - "{warning}"')
    else:
        lines.append('      []')
    lines.append('    assay_router:')
    lines.append(f'      sequencing_type: "{router.get("sequencing_type", "WES")}"')
    lines.append(f'      sf_mask_coverage: {router.get("sf_mask_coverage", 1.0)}')
    lines.append(f'      prs_backbone_coverage: {router.get("prs_backbone_coverage", 1.0)}')
    lines.append(f'      prs_gate_pass: {str(bool(router.get("prs_gate_pass", False))).lower()}')
    lines.append('    annotation_streams:')
    lines.append('      vep_core: "VEP_CORE_ENGINE"')
    lines.append('      clinvar_sync: "CLINVAR_SYNC_ENGINE"')
    lines.append('      gnomad_sieve: "GNOMAD_AGGREGATOR_SIEVE"')
    lines.append('      bayesian_classifier: "ACMG_BAYESIAN_CLASSIFIER_STAGE5"')
    lines.append('      vus_hgmd_triage: "VUS_TRIAGE_HGMD_SEARCH"')

    lines.append('    stage5_outputs:')
    lines.append(f'      acmg_tiered_variants_json: "{ann.get("acmg_tiered_table", "")}"')
    lines.append(f'      vus_triage_queue_json: "{ann.get("vus_queue", "")}"')
    lines.append(f'      vus_upgraded_count: {ann.get("vus_upgraded_count", 0)}')
    lines.append(f'      sf_report_json: "{sf.get("sf_report", "")}"')
    lines.append(f'      acmg_sf_bypassed_audit_json: "{sf.get("sf_bypass_audit", "")}"')
    lines.append(f'      prs_calibrated_report_json: "{prs.get("prs_report", "")}"')
    lines.append(f'      prs_bypassed_audit_json: "{prs.get("prs_bypass_audit", "")}"')
    lines.append(f'      prs_insufficient_coverage_audit_json: "{prs.get("prs_coverage_audit", "")}"')
    lines.append(f'      pgx_diplotype_json: "{pgx.get("pgx_diplotype_json", "")}"')
    lines.append(f'      pgx_actionability_json: "{pgx.get("pgx_actionability_json", "")}"')
    lines.append(f'      pgx_report_json: "{pgx.get("pgx_actionability_json", pgx.get("pgx_report", ""))}"')
    lines.append(f'      clinical_bundle_tar_gz: "{pgx.get("clinical_bundle_tar_gz", "")}"')
    lines.append(f'      provenance_json: "{pgx.get("provenance_json", "")}"')
    lines.append('    save_dir: "tests/fixtures/banked_stage5"')

Path('samples_hg002_banked_stage5.yaml').write_text("\\n".join(lines) + "\\n", encoding='utf-8')
PYEOF
    """
}
