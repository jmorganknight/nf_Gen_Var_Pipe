process ASSEMBLE_STAGE4_BANKED_MANIFEST {

    label 'process_low'
    container 'wes-onco-core:1.0.0'
    stageInMode 'symlink'

    publishDir "${params.outdir}", mode: 'rellink', overwrite: true, pattern: 'samples_hg002_banked_stage4.yaml'

    input:
    path manifest_fragments

    output:
    path 'samples_hg002_banked_stage4.yaml', emit: banked_manifest

    script:
    """
    set -euo pipefail

    python3 - <<'PYEOF'
import json
from pathlib import Path

fragment_json = '''${groovy.json.JsonOutput.toJson(manifest_fragments.collect { fragment -> fragment.toString() }).replace('\n', ' ').replace('\r', '')}'''
fragment_paths = [Path(p) for p in json.loads(fragment_json)]
samples = [json.loads(path.read_text(encoding='utf-8')) for path in fragment_paths]

lines = []
lines.append('# ==============================================================================' )
lines.append('# STAGE 4 BANKED MANIFEST')
lines.append('# Purpose: Immutable ancestry-projected and phased handoff for Stage 5.')
lines.append('# ==============================================================================' )
lines.append('samples:')
for rec in samples:
    lines.append(f'  - sample_id: "{rec["sample_id"]}"')
    lines.append(f'    run_mode: "{rec.get("run_mode", "production")}"')
    lines.append(f'    validation_token: "{rec.get("validation_token", "")}"')
    lines.append(f'    stage2_contamination_status: "{rec.get("stage2_contamination_status", "")}"')
    lines.append(f'    stage2_contamination_policy_action: "{rec.get("stage2_contamination_policy_action", "")}"')
    lines.append('    consent_tokens:')
    for key, value in (rec.get('consent_tokens') or {}).items():
        lines.append(f'      {key}: "{value}"')
    lines.append('    stage0_consent_tokens:')
    for key, value in (rec.get('stage0_consent_tokens') or {}).items():
        lines.append(f'      {key}: "{value}"')
    lines.append('    variant_branches:')
    for key, value in (rec.get('variant_branches') or {}).items():
        lines.append(f'      {key}: {str(bool(value)).lower()}')
    lines.append('    active_branches:')
    active = rec.get('active_branches') or []
    if active:
        for item in active:
            lines.append(f'      - "{item}"')
    else:
        lines.append('      []')
    lines.append(f'    sorted_bam: "{rec.get("sorted_bam", "")}"')
    lines.append(f'    sorted_bai: "{rec.get("sorted_bai", "")}"')
    lines.append(f'    normalized_vcf: "{rec.get("normalized_vcf", "")}"')
    lines.append(f'    normalized_vcf_tbi: "{rec.get("normalized_vcf_tbi", "")}"')
    lines.append(f'    phased_vcf: "{rec.get("phased_vcf", "")}"')
    lines.append(f'    phased_vcf_tbi: "{rec.get("phased_vcf_tbi", "")}"')
    lines.append(f'    ancestry_metrics_json: "{rec.get("ancestry_metrics_json", "")}"')
    lines.append(f'    phasing_audit_json: "{rec.get("phasing_audit_json", "")}"')
    lines.append(f'    ancestry_label: "{rec.get("ancestry_label", "")}"')
    lines.append(f'    superpopulation: "{rec.get("superpopulation", "")}"')
    lines.append(f'    subpopulation: "{rec.get("subpopulation", "")}"')
    lines.append('    pc_coordinates:')
    for key, value in (rec.get('pc_coordinates') or {}).items():
        lines.append(f'      {key}: {value}')
    lines.append('    reference_build:')
    for key, value in (rec.get('reference_build') or {}).items():
        lines.append(f'      {key}: "{value}"')
    lines.append(f'    stage4_handoff_note: "{rec.get("stage4_handoff_note", "")}"')
    lines.append(f'    save_dir: "{rec.get("save_dir", "")}"')

Path('samples_hg002_banked_stage4.yaml').write_text("\\n".join(lines) + "\\n", encoding='utf-8')
PYEOF
    """
}
